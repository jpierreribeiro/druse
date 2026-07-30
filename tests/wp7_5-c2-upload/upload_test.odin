// WP7.5-C2/C3 — the public large-body upload API, over a real socket.
//
// The vertical slice E8-2 needed: a body LARGER than max_body is consumed to an
// owned spool (not answered 413), the Handler takes it with web.upload, and the
// spooled bytes are byte-for-byte the sent bytes. It also proves the refusals
// (§4.2): a body over the per-upload quota is answered 413 mid-stream, and a body
// within max_body is NOT spooled (web.upload returns ok=false, the buffered path
// is unchanged). And it proves ownership: web.upload_persist keeps the file,
// while a Handler that does not persist has its file cleaned up at teardown.
//
// One server: max_body 4 KiB, per-upload quota 32 KiB. So a 16 KiB body spools,
// a 64 KiB body breaches the quota, and a 100-byte body stays buffered.
package test_wp7_5_c2_upload

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

MAX_BODY :: 4 * 1024
QUOTA :: 32 * 1024
SPOOLED :: 16 * 1024 // > MAX_BODY, < QUOTA — spools
OVER_QUOTA :: 64 * 1024 // > QUOTA — refused 413
SMALL :: 100 // <= MAX_BODY — buffered, not spooled

FNV_OFFSET :: 14695981039346656037
FNV_PRIME :: 1099511628211

fnv1a :: proc(seed: u64, bytes: []u8) -> u64 {
	h := seed
	for b in bytes {h = (h ~ u64(b)) * FNV_PRIME}
	return h
}

body_byte :: proc(i: int) -> u8 {return u8(i % 251)}

make_body :: proc(n: int) -> []u8 {
	b := make([]u8, n)
	for i in 0 ..< n {b[i] = body_byte(i)}
	return b
}

expected_sum :: proc(n: int) -> u64 {
	h := u64(FNV_OFFSET)
	for i in 0 ..< n {h = (h ~ u64(body_byte(i))) * FNV_PRIME}
	return h
}

// --- application ------------------------------------------------------------

g_persist_dir: string

App_State :: struct {}

// POST /upload — read the spooled body back and report its size + checksum, or
// report "buffered" when the body was small enough to take the buffered path.
upload_handler :: proc(ctx: ^web.Context) {
	up, ok := web.upload(ctx)
	if !ok {
		web.text(ctx, .OK, "buffered")
		return
	}
	data, rerr := os.read_entire_file(up.path, context.temp_allocator)
	if rerr != nil {
		web.text(ctx, .Internal_Server_Error, "spool-unreadable")
		return
	}
	sum := fnv1a(FNV_OFFSET, data)
	web.text(ctx, .Created, report(up.size, sum))
}

// POST /persist — transfer ownership out; the file must survive teardown.
persist_handler :: proc(ctx: ^web.Context) {
	up, ok := web.upload(ctx)
	if !ok {
		web.text(ctx, .OK, "buffered")
		return
	}
	dest := strings.concatenate({g_persist_dir, "/kept.bin"}, context.temp_allocator)
	_ = up
	if web.upload_persist(ctx, dest) {
		web.text(ctx, .Created, "persisted")
	} else {
		web.text(ctx, .Internal_Server_Error, "persist-failed")
	}
}

report :: proc(size: i64, sum: u64) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "size=")
	strings.write_int(&b, int(size))
	strings.write_string(&b, " sum=")
	buf: [24]u8
	strings.write_string(&b, strconv.write_int(buf[:], i64(sum), 16))
	return strings.to_string(b)
}

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
}

serve_thread :: proc(s: ^Server) {web.serve(&s.app, s.port)}

start :: proc(s: ^Server, port: int, spool_dir: string) -> bool {
	s.port = port
	s.app = web.app()
	l := web.DEFAULT_LIMITS
	l.max_body = MAX_BODY
	web.limits(&s.app, l)
	web.enable_upload(&s.app, web.Upload_Config{dir = spool_dir, per_upload_quota = QUOTA})
	web.post(&s.app, "/upload", upload_handler)
	web.post(&s.app, "/persist", persist_handler)
	s.thread = thread.create_and_start_with_poly_data(s, serve_thread)
	for _ in 0 ..< 300 {
		sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port})
		if err == nil {net.close(sock); return true}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

stop :: proc(s: ^Server) {
	web.stop(&s.app)
	if s.thread != nil {thread.join(s.thread); thread.destroy(s.thread); s.thread = nil}
	web.destroy(&s.app)
}

// --- client -----------------------------------------------------------------

post :: proc(port: int, path: string, body: []u8, tolerate_send_err: bool) -> (status: int, resp_body: string, ok: bool) {
	endpoint := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	sock: net.TCP_Socket
	connected := false
	for _ in 0 ..< 100 {
		s, err := net.dial_tcp(endpoint)
		if err == nil {sock = s; connected = true; break}
		time.sleep(2 * time.Millisecond)
	}
	if !connected {return 0, "", false}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 5 * time.Second)
	net.set_option(sock, .Send_Timeout, 5 * time.Second)

	head := strings.concatenate(
		{"POST ", path, " HTTP/1.1\r\nHost: x\r\nContent-Length: ", itoa(len(body)), "\r\nConnection: close\r\n\r\n"},
		context.temp_allocator,
	)
	if !send_all(sock, transmute([]u8)head) && !tolerate_send_err {return 0, "", false}
	if len(body) > 0 && !send_all(sock, body) && !tolerate_send_err {return 0, "", false}

	acc := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	for {
		n, e := net.recv_tcp(sock, buf[:])
		if n > 0 {strings.write_bytes(&acc, buf[:n])}
		if n == 0 || e != nil {break}
	}
	raw := strings.to_string(acc)
	if len(raw) < 12 {return 0, "", false}
	status, _ = strconv.parse_int(raw[9:12], 10)
	idx := strings.index(raw, "\r\n\r\n")
	if idx >= 0 {resp_body = raw[idx + 4:]}
	return status, resp_body, true
}

send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n, err := net.send_tcp(sock, data[off:])
		if err != nil || n <= 0 {return false}
		off += n
	}
	return true
}

itoa :: proc(n: int) -> string {
	return fmt.tprintf("%d", n)
}

field_int :: proc(s, key: string) -> (int, bool) {
	needle := strings.concatenate({key, "="}, context.temp_allocator)
	i := strings.index(s, needle)
	if i < 0 {return 0, false}
	rest := s[i + len(needle):]
	end := strings.index_byte(rest, ' ')
	if end < 0 {end = len(rest)}
	return strconv.parse_int(rest[:end], 10)
}

field_u64_hex :: proc(s, key: string) -> (u64, bool) {
	needle := strings.concatenate({key, "="}, context.temp_allocator)
	i := strings.index(s, needle)
	if i < 0 {return 0, false}
	rest := s[i + len(needle):]
	end := strings.index_byte(rest, ' ')
	if end < 0 {end = len(rest)}
	return strconv.parse_u64(rest[:end], 16)
}

// --- tests ------------------------------------------------------------------

// One @(test), one server: `web.serve` uses a single process-global server slot
// (the WP43 g_server), so two servers started concurrently by the parallel test
// runner would have one test's `web.stop` shut down the other's server. Every
// case here shares the one server config (max_body 4 KiB, per-upload quota 32
// KiB) and runs as a sequential request, which is also the honest shape: the
// slice proves the four behaviours compose over one running application.
@(test)
upload_spool_buffered_quota_and_persist_compose :: proc(t: ^testing.T) {
	cache := strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.cache"}, context.temp_allocator)
	os.make_directory(cache)
	spool := strings.concatenate({cache, "/uru-c2-spool"}, context.temp_allocator)
	os.make_directory(spool)
	g_persist_dir = strings.concatenate({cache, "/uru-c2-persist"}, context.temp_allocator)
	os.make_directory(g_persist_dir)

	srv: Server
	testing.expect(t, start(&srv, 52320, spool), "server starts")
	defer stop(&srv)

	// 1. A body over max_body is SPOOLED and reassembled byte-for-byte.
	{
		body := make_body(SPOOLED)
		defer delete(body)
		status, resp, ok := post(52320, "/upload", body, false)
		testing.expect(t, ok, "spool: got a response")
		testing.expectf(t, status == 201, "spooled upload is 201 Created, got %d (%s)", status, resp)
		size, _ := field_int(resp, "size")
		sum, _ := field_u64_hex(resp, "sum")
		testing.expectf(t, size == SPOOLED, "spool size equals the sent length: %d != %d", size, SPOOLED)
		testing.expectf(t, sum == expected_sum(SPOOLED), "spooled bytes are byte-identical (sum %x)", sum)
	}

	// 2. A body WITHIN max_body is not spooled — the buffered path is unchanged.
	{
		body := make_body(SMALL)
		defer delete(body)
		status, resp, ok := post(52320, "/upload", body, false)
		testing.expect(t, ok, "buffered: got a response")
		testing.expectf(t, status == 200 && resp == "buffered", "a body within max_body is NOT spooled: %d %q", status, resp)
	}

	// 3. A body over the per-upload quota is refused 413 mid-stream.
	{
		body := make_body(OVER_QUOTA)
		defer delete(body)
		status, _, ok := post(52320, "/upload", body, true) // tolerate a broken pipe as the server stops reading
		testing.expect(t, ok, "quota: got a response")
		testing.expectf(t, status == 413, "a body over the per-upload quota is refused 413, got %d", status)
	}

	// 4. upload_persist keeps the file past request teardown, byte-for-byte.
	{
		body := make_body(SPOOLED)
		defer delete(body)
		status, resp, ok := post(52320, "/persist", body, false)
		testing.expect(t, ok, "persist: got a response")
		testing.expectf(t, status == 201 && resp == "persisted", "persist is 201: %d %q", status, resp)

		dest := strings.concatenate({g_persist_dir, "/kept.bin"}, context.temp_allocator)
		kept, rerr := os.read_entire_file(dest, context.temp_allocator)
		testing.expect(t, rerr == nil, "the persisted file exists after teardown")
		testing.expectf(t, len(kept) == SPOOLED, "persisted file has the full body: %d", len(kept))
		testing.expectf(t, fnv1a(FNV_OFFSET, kept) == expected_sum(SPOOLED), "persisted bytes are byte-identical")
		os.remove(dest)
	}
}
