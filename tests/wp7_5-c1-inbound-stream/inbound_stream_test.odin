// WP7.5-C1 — the executable corpus for vendored PATCH 23 (streaming inbound
// body). It drives the REAL vendored server over a real socket, so it proves the
// patch the way vendor-policy §3 requires (an executable case, never a grep):
//
//   * a Content-Length body far larger than the window reassembles byte-for-byte
//     (FNV-1a over the received bytes equals the sender's), delivered in pieces
//     no larger than the window;
//   * the scan buffer stays BOUNDED — one window, not the body's length — which
//     is the whole point of the `stream_compact` reclamation; without it the
//     buffer would grow to the full body;
//   * an early `.Stop` from the consumer halts the read: the reader never arms
//     the next recv, so only the first window is delivered;
//   * a chunked body (pieces larger than the window, to exercise intra-chunk
//     windowing) reassembles identically;
//   * a Content-Length over `max_length` is refused before a byte is read.
//
// The handler mirrors the adapter's own shape: it does not respond synchronously;
// it starts `body_stream` and lets the completion callback write the response,
// exactly as `catch_all`/`on_body` do.
package test_wp7_5_c1_inbound_stream

import "core:fmt"
import "core:net"
import "core:nbio"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import http "druse:vendor/odin-http"

WINDOW :: 16 * 1024
BODY :: 2 * 1024 * 1024 // >> WINDOW: 128 windows
CAP_BOUND :: 256 * 1024 // buffer must stay far under BODY
SMALL :: 64 * 1024 // for the early-stop case (fits a socket send buffer)
MAX_UPLOAD :: 8 * 1024 * 1024
CAP_SMALL :: 8 * 1024 // the /upload-cap route's max_length

FNV_OFFSET :: 14695981039346656037
FNV_PRIME :: 1099511628211

fnv1a :: proc(seed: u64, bytes: []u8) -> u64 {
	h := seed
	for b in bytes {
		h = (h ~ u64(b)) * FNV_PRIME
	}
	return h
}

// The deterministic body the client sends and the server checksums.
body_byte :: proc(i: int) -> u8 {return u8(i % 251)}

// --- server -----------------------------------------------------------------

Upload_Ctx :: struct {
	req:        ^http.Request,
	res:        ^http.Response,
	sum:        u64,
	total:      int,
	max_chunk:  int,
	seen:       int,
	stop_after: int,
	buf_cap:    int,
}

up_chunk :: proc(user_data: rawptr, chunk: []u8) -> http.Body_Sink_Result {
	c := (^Upload_Ctx)(user_data)
	c.sum = fnv1a(c.sum, chunk)
	c.total += len(chunk)
	if len(chunk) > c.max_chunk {c.max_chunk = len(chunk)}
	c.seen += 1
	if c.stop_after > 0 && c.seen >= c.stop_after {
		return .Stop
	}
	return .Continue
}

up_done :: proc(user_data: rawptr, outcome: http.Stream_Outcome, err: http.Body_Error) {
	c := (^Upload_Ctx)(user_data)
	c.buf_cap = http.scan_buffer_cap(c.req)
	report := fmt.tprintf(
		"outcome=%d total=%d sum=%x cap=%d maxchunk=%d",
		int(outcome),
		c.total,
		c.sum,
		c.buf_cap,
		c.max_chunk,
	)
	http.headers_set_close(&c.res.headers)
	c.res.status = .OK
	http.body_set(c.res, report)
	http.respond(c.res)
}

Server :: struct {
	backend:   http.Server,
	port:      int,
	thread:    ^thread.Thread,
	ready:     sync.Sema,
	stopped:   sync.Sema,
	listen_ok: bool,
}

handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	path := req.url.path
	if path == "/health" {
		http.headers_set_close(&res.headers)
		res.status = .OK
		http.body_set(res, "ok")
		http.respond(res)
		return
	}

	c := new(Upload_Ctx, context.temp_allocator)
	c.req = req
	c.res = res
	c.sum = FNV_OFFSET
	if path == "/upload-stop" {c.stop_after = 1}

	max_len := MAX_UPLOAD
	if path == "/upload-cap" {max_len = CAP_SMALL}

	// Start the streamed read and RETURN without responding; up_done writes the
	// response once the body has drained (or the read has stopped).
	http.body_stream(req, max_len, WINDOW, c, up_chunk, up_done)
}

server_thread :: proc(s: ^Server) {
	defer sync.sema_post(&s.stopped)
	opts := http.Default_Server_Opts
	opts.thread_count = 2
	opts.max_drain_time = 2 * time.Second
	endpoint := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = s.port,
	}
	err := http.listen(&s.backend, endpoint, opts)
	s.listen_ok = err == nil
	sync.sema_post(&s.ready)
	if err != nil {return}

	h: http.Handler
	h.handle = handler
	http.serve(&s.backend, h)
	nbio.release_thread_event_loop()
}

start :: proc(s: ^Server, port: int) -> bool {
	s^ = {}
	s.port = port
	s.thread = thread.create_and_start_with_poly_data(s, server_thread)
	if !sync.sema_wait_with_timeout(&s.ready, 2 * time.Second) {return false}
	if !s.listen_ok {return false}
	// A completed request is the readiness barrier (the listening socket alone is
	// not evidence every lane entered its loop).
	resp, ok := do_request(port, "GET /health HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", nil, false)
	delete(resp)
	return ok
}

stop :: proc(s: ^Server) {
	if s.listen_ok {http.server_shutdown(&s.backend)}
	sync.sema_wait_with_timeout(&s.stopped, 3 * time.Second)
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}
}

// --- client -----------------------------------------------------------------

dial :: proc(port: int) -> (net.TCP_Socket, bool) {
	endpoint := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	for _ in 0 ..< 200 {
		sock, err := net.dial_tcp(endpoint)
		if err == nil {return sock, true}
		time.sleep(2 * time.Millisecond)
	}
	return {}, false
}

// do_request sends `head` then (optionally) `body`, reads the whole response, and
// returns the response body (after the blank line). `tolerate_send_err` lets the
// early-stop case ignore a broken pipe when the server stops reading.
do_request :: proc(port: int, head: string, body: []u8, tolerate_send_err: bool) -> (resp_body: string, ok: bool) {
	sock, connected := dial(port)
	if !connected {return "", false}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 5 * time.Second)
	net.set_option(sock, .Send_Timeout, 5 * time.Second)

	if !send_all(sock, transmute([]u8)head) && !tolerate_send_err {return "", false}
	if len(body) > 0 {
		if !send_all(sock, body) && !tolerate_send_err {return "", false}
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	buf: [8192]u8
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if n > 0 {strings.write_bytes(&builder, buf[:n])}
		if n == 0 || err != nil {break}
	}
	raw := strings.to_string(builder)
	idx := strings.index(raw, "\r\n\r\n")
	if idx < 0 {return "", false}
	return strings.clone(raw[idx + 4:]), true
}

send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n, err := net.send_tcp(sock, data[off:])
		if err != nil {return false}
		if n <= 0 {return false}
		off += n
	}
	return true
}

// Field parsing over the "k=v k=v" report.
field :: proc(report, key: string) -> (string, bool) {
	needle := strings.concatenate({key, "="}, context.temp_allocator)
	i := strings.index(report, needle)
	if i < 0 {return "", false}
	rest := report[i + len(needle):]
	end := strings.index_byte(rest, ' ')
	if end < 0 {end = len(rest)}
	return rest[:end], true
}

field_int :: proc(report, key: string) -> (int, bool) {
	v, ok := field(report, key)
	if !ok {return 0, false}
	n, pok := strconv.parse_int(v, 10)
	return n, pok
}

expected_sum :: proc(n: int) -> u64 {
	h := u64(FNV_OFFSET)
	for i in 0 ..< n {
		h = (h ~ u64(body_byte(i))) * FNV_PRIME
	}
	return h
}

make_body :: proc(n: int) -> []u8 {
	b := make([]u8, n)
	for i in 0 ..< n {b[i] = body_byte(i)}
	return b
}

// --- tests ------------------------------------------------------------------

@(test)
content_length_streams_reassembles_and_stays_bounded :: proc(t: ^testing.T) {
	srv: Server
	testing.expect(t, start(&srv, 52310), "server starts")
	defer stop(&srv)

	body := make_body(BODY)
	defer delete(body)
	head := fmt.tprintf("POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", BODY)

	report, ok := do_request(52310, head, body, false)
	testing.expect(t, ok, "got a response")
	defer delete(report)

	outcome, _ := field_int(report, "outcome")
	total, _ := field_int(report, "total")
	cap_seen, _ := field_int(report, "cap")
	maxchunk, _ := field_int(report, "maxchunk")
	sum_hex, _ := field(report, "sum")
	got_sum, _ := strconv.parse_u64(sum_hex, 16)

	testing.expectf(t, outcome == 0, "outcome Complete, got %d", outcome)
	testing.expectf(t, total == BODY, "delivered the whole body: %d != %d", total, BODY)
	testing.expectf(t, got_sum == expected_sum(BODY), "reassembled bytes are identical (sum %x)", got_sum)
	testing.expectf(t, maxchunk <= WINDOW, "no delivered chunk exceeds the window: %d > %d", maxchunk, WINDOW)
	testing.expectf(
		t,
		cap_seen <= CAP_BOUND,
		"scan buffer stayed bounded: %d must be << body %d (compaction proof)",
		cap_seen,
		BODY,
	)
}

@(test)
early_stop_halts_the_read :: proc(t: ^testing.T) {
	srv: Server
	testing.expect(t, start(&srv, 52311), "server starts")
	defer stop(&srv)

	body := make_body(SMALL)
	defer delete(body)
	head := fmt.tprintf("POST /upload-stop HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", SMALL)

	report, ok := do_request(52311, head, body, true)
	testing.expect(t, ok, "got a response")
	defer delete(report)

	outcome, _ := field_int(report, "outcome")
	total, _ := field_int(report, "total")

	testing.expectf(t, outcome == 1, "outcome Stopped, got %d", outcome)
	testing.expectf(t, total > 0 && total <= WINDOW, "only the first window was read: %d", total)
	testing.expectf(t, total < SMALL, "the read stopped before the whole body: %d >= %d", total, SMALL)
}

@(test)
chunked_streams_reassembles :: proc(t: ^testing.T) {
	srv: Server
	testing.expect(t, start(&srv, 52312), "server starts")
	defer stop(&srv)

	// Build a chunked body: 40 KiB pieces (> WINDOW, so intra-chunk windowing runs).
	piece := 40 * 1024
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	sent := 0
	for sent < BODY {
		this := min(piece, BODY - sent)
		fmt.sbprintf(&b, "%x\r\n", this)
		for i in 0 ..< this {strings.write_byte(&b, body_byte(sent + i))}
		strings.write_string(&b, "\r\n")
		sent += this
	}
	strings.write_string(&b, "0\r\n\r\n")

	head := "POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
	report, ok := do_request(52312, head, transmute([]u8)strings.to_string(b), false)
	testing.expect(t, ok, "got a response")
	defer delete(report)

	outcome, _ := field_int(report, "outcome")
	total, _ := field_int(report, "total")
	sum_hex, _ := field(report, "sum")
	got_sum, _ := strconv.parse_u64(sum_hex, 16)
	cap_seen, _ := field_int(report, "cap")

	testing.expectf(t, outcome == 0, "outcome Complete, got %d", outcome)
	testing.expectf(t, total == BODY, "reassembled the whole chunked body: %d != %d", total, BODY)
	testing.expectf(t, got_sum == expected_sum(BODY), "chunked reassembly is identical (sum %x)", got_sum)
	testing.expectf(t, cap_seen <= CAP_BOUND, "chunked scan buffer stayed bounded: %d", cap_seen)
}

@(test)
content_length_over_max_refuses :: proc(t: ^testing.T) {
	srv: Server
	testing.expect(t, start(&srv, 52313), "server starts")
	defer stop(&srv)

	body := make_body(SMALL) // SMALL (64 KiB) > CAP_SMALL (8 KiB)
	defer delete(body)
	head := fmt.tprintf("POST /upload-cap HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", SMALL)

	report, ok := do_request(52313, head, body, true)
	testing.expect(t, ok, "got a response")
	defer delete(report)

	outcome, _ := field_int(report, "outcome")
	total, _ := field_int(report, "total")
	testing.expectf(t, outcome == 2, "outcome Failed (refused), got %d", outcome)
	testing.expectf(t, total == 0, "not a byte was delivered past the cap: %d", total)
}
