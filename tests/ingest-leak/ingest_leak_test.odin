// Ingest audit F1/F2/F3 — ADMISSION SLOTS MUST SURVIVE ABNORMAL ENDINGS.
//
// The upload subsystem reserves a bounded slot (`ingest.admit`) before reading a
// byte and releases it through `ingest.cancel`. Three paths used to reach
// neither `on_upload_done` nor `driver_cleanup`, so the slot was never returned:
//
//   F1  the connection dies mid-body (deadline sweep, shutdown force-close, or a
//       client that simply goes away) — `connection_close`/`connection_abort`
//       call `nbio.remove` on the pending recv, so the chunk callback never
//       fires again and nothing else owned the spool;
//   F2  `ingest.begin` fails to open the spool file — the spool never learns
//       which admission it belongs to, so `cancel` cannot find the slot;
//   F3  the lane refuses dispatch with 503 — `driver_cleanup`, the only caller
//       of `upload_cancel`, runs only after `cfg.dispatch`, which that path
//       returns before.
//
// Every one of them is PERMANENT: after `max_concurrent` occurrences the
// subsystem answers 503 to every upload for the life of the process. F1 is the
// one ordinary traffic reaches — with the default 30 s `max_request_time`, any
// client slower than that is enough, which is a 1 GiB body under ~35 MB/s.
//
// This lives in its own package because `web.serve` binds a process-global
// server slot (R-20): a second server started by the parallel test runner would
// have one test's `web.stop` tear down another's.
//
// THE CONTROL that makes this a test rather than a demonstration: delete the
// `conn.on_teardown = upload_conn_torn_down` registration in `start_upload` and
// the final upload answers 503 instead of 201.
package test_ingest_leak

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
SPOOLED :: 16 * 1024 // > MAX_BODY, < QUOTA — takes the spool path
PORT :: 41_985

// One slot, so a single leak closes the subsystem, and several abandonments, so
// a fix that only sometimes releases still fails.
SLOTS :: 1
ABANDONS :: 3

// The deadline that produces the leak. A client that merely CLOSES its socket is
// not enough: the FIN completes the pending recv, `body_stream` reports
// `.Failed`, and `on_upload_done` cleans up correctly — that path was never
// broken. The leak needs the recv to be REMOVED without completing, which is
// what `connection_abort` does when the sweep fires. So the client here goes
// quiet and stays connected, and the server's own read deadline aborts it.
REQUEST_DEADLINE :: i64(700 * 1_000_000) // 700 ms in nanoseconds


// --- application ------------------------------------------------------------

upload_handler :: proc(ctx: ^web.Context) {
	up, ok := web.upload(ctx)
	if !ok {
		web.text(ctx, .OK, "buffered")
		return
	}
	web.text(ctx, .Created, fmt.tprintf("size=%d", up.size))
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
	l.max_request_time = REQUEST_DEADLINE
	web.limits(&s.app, l)
	web.enable_upload(
		&s.app,
		web.Upload_Config{dir = spool_dir, per_upload_quota = QUOTA, max_concurrent = SLOTS},
	)
	web.post(&s.app, "/upload", upload_handler)
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

send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n, err := net.send_tcp(sock, data[off:])
		if err != nil || n <= 0 {return false}
		off += n
	}
	return true
}

dial :: proc(port: int) -> (net.TCP_Socket, bool) {
	endpoint := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	for _ in 0 ..< 100 {
		s, err := net.dial_tcp(endpoint)
		if err == nil {return s, true}
		time.sleep(2 * time.Millisecond)
	}
	return {}, false
}

body_of :: proc(n: int) -> []u8 {
	b := make([]u8, n)
	for i in 0 ..< n {b[i] = u8(i % 251)}
	return b
}

// post sends a complete upload and returns its status.
post :: proc(port: int, body: []u8) -> (status: int, ok: bool) {
	sock, connected := dial(port)
	if !connected {return 0, false}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 5 * time.Second)
	net.set_option(sock, .Send_Timeout, 5 * time.Second)

	head := strings.concatenate(
		{
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ",
			fmt.tprintf("%d", len(body)),
			"\r\nConnection: close\r\n\r\n",
		},
		context.temp_allocator,
	)
	if !send_all(sock, transmute([]u8)head) {return 0, false}
	if !send_all(sock, body) {return 0, false}

	acc := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	for {
		n, e := net.recv_tcp(sock, buf[:])
		if n > 0 {strings.write_bytes(&acc, buf[:n])}
		if n == 0 || e != nil {break}
	}
	raw := strings.to_string(acc)
	if len(raw) < 12 {return 0, false}
	status, _ = strconv.parse_int(raw[9:12], 10)
	return status, true
}

// stall announces a large body, sends only a prefix, then GOES QUIET while
// staying connected until the server's read deadline aborts the connection.
// `connection_abort` calls `nbio.remove` on the pending recv, so the chunk
// callback never fires again and no upload-owned code runs on this connection
// after this point — which is precisely the state that used to strand the
// admission slot and leave the partial spool file on disk.
stall :: proc(port: int, announced, prefix: int) -> bool {
	sock, connected := dial(port)
	if !connected {return false}
	net.set_option(sock, .Send_Timeout, 5 * time.Second)
	defer net.close(sock)

	head := strings.concatenate(
		{
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ",
			fmt.tprintf("%d", announced),
			"\r\n\r\n",
		},
		context.temp_allocator,
	)
	if !send_all(sock, transmute([]u8)head) {
		return false
	}
	part := body_of(prefix)
	defer delete(part)
	_ = send_all(sock, part)

	// Outlast the server's read deadline without sending the rest.
	time.sleep(time.Duration(REQUEST_DEADLINE) + 500 * time.Millisecond)
	return true
}

// --- test -------------------------------------------------------------------

@(test)
upload_admission_survives_abandoned_bodies :: proc(t: ^testing.T) {
	cache := strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.cache"}, context.temp_allocator)
	os.make_directory(cache)
	spool := strings.concatenate({cache, "/uru-ingest-leak"}, context.temp_allocator)
	os.make_directory(spool)

	srv: Server
	if !start(&srv, PORT, spool) {
		testing.fail_now(t, "server did not start")
	}
	defer stop(&srv)

	// Baseline: the endpoint works before any abandonment, so a later failure
	// cannot be blamed on the fixture.
	{
		body := body_of(SPOOLED)
		defer delete(body)
		status, ok := post(PORT, body)
		testing.expectf(t, ok && status == 201, "baseline upload: ok=%v status=%v", ok, status)
	}

	for i in 0 ..< ABANDONS {
		testing.expectf(t, stall(PORT, SPOOLED, 512), "stall %d could not be issued", i)
		// Let the lane finish the abort and its teardown before the next attempt,
		// so this measures leaked slots and not momentary concurrency.
		time.sleep(150 * time.Millisecond)
	}

	// THE ASSERTION. With slots leaked, admission is exhausted and `start_upload`
	// refuses this with 503. With them released, it spools and dispatches exactly
	// as the baseline did.
	{
		body := body_of(SPOOLED)
		defer delete(body)
		status, ok := post(PORT, body)
		testing.expectf(
			t,
			ok && status == 201,
			"upload after %d abandoned bodies: ok=%v status=%v (503 means admission slots leaked)",
			ABANDONS,
			ok,
			status,
		)
	}
}
