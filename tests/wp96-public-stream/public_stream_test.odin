// WP96 — the PUBLIC streaming API end to end, and the properties an operator
// and a Crystal author depend on.
//
// Everything here goes through `web.app` / `web.get` / `web.serve` / `web.stream`
// — the surface an application actually holds — never the private machinery.
// It proves: a Handler opens a stream and returns; later code streams from a
// worker thread; the client receives chunks incrementally; close terminates;
// a buffered route on the same server is untouched; `secure_headers` cover a
// stream; and the in-memory transport reports ok=false (no connection to
// detach) rather than lying.
package test_wp96_public_stream

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

// A shared place for a worker to reach the stream token the Handler opened.
Shared :: struct {
	tok:      web.Stream,
	opened:   sync.Sema,
	ok:       bool,
}

g_shared: ^Shared

@(private)
stream_handler :: proc(ctx: ^web.Context) {
	s, ok := web.stream(ctx)
	g_shared.tok = s
	g_shared.ok = ok
	sync.sema_post(&g_shared.opened)
	// The Handler RETURNS here; the response outlives this Context.
}

@(private)
buffered_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "buffered-ok")
}

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
}

@(private)
serve_thread :: proc(s: ^Server) {
	web.serve(&s.app, s.port)
}

@(private)
start :: proc(s: ^Server, port: int) -> bool {
	s.port = port
	s.app = web.app()
	web.use(&s.app, web.secure_headers)
	web.get(&s.app, "/events", stream_handler)
	web.get(&s.app, "/plain", buffered_handler)
	s.thread = thread.create_and_start_with_poly_data(s, serve_thread)
	// Wait for readiness via the buffered route.
	for _ in 0 ..< 300 {
		if st, _ := get(port, "/plain"); st == 200 {
			return true
		}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

@(private)
stop :: proc(s: ^Server) {
	web.stop(&s.app)
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}
	web.destroy(&s.app)
}

@(private)
dial :: proc(port: int) -> (net.TCP_Socket, bool) {
	endpoint := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	for _ in 0 ..< 100 {
		sock, err := net.dial_tcp(endpoint)
		if err == nil {return sock, true}
		time.sleep(2 * time.Millisecond)
	}
	return {}, false
}

@(private)
get :: proc(port: int, path: string) -> (status: int, body: string) {
	sock, ok := dial(port)
	if !ok {return 0, ""}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 3 * time.Second)
	req, _ := strings.concatenate({"GET ", path, " HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"}, context.temp_allocator)
	if _, e := net.send_tcp(sock, transmute([]u8)req); e != nil {return 0, ""}
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	buf: [4096]u8
	for {
		n, e := net.recv_tcp(sock, buf[:])
		if n > 0 {strings.write_bytes(&b, buf[:n])}
		if n == 0 || e != nil {break}
	}
	raw := strings.to_string(b)
	st := 0
	if len(raw) >= 12 {st = int(raw[9] - '0') * 100 + int(raw[10] - '0') * 10 + int(raw[11] - '0')}
	return st, raw
}

@(private)
recv_until :: proc(sock: net.TCP_Socket, b: ^strings.Builder, marker: string, timeout: time.Duration) -> bool {
	net.set_option(sock, .Receive_Timeout, timeout)
	buf: [2048]u8
	for {
		if strings.contains(strings.to_string(b^), marker) {return true}
		n, e := net.recv_tcp(sock, buf[:])
		if n > 0 {strings.write_bytes(b, buf[:n])}
		if n == 0 || e != nil {return strings.contains(strings.to_string(b^), marker)}
	}
}

// AUDIT M5 — A COMMITTED RESPONSE IS NOT A STREAM.
//
// `web.stream` guarded `stream_detached` and a nil exchange, and nothing else.
// Its own comment claimed the single-commit guard covered the rest — and it
// does, in ONE direction: a responder AFTER a stream is refused. A stream after
// a responder was not, and `stream_begin` detaches the connection before
// anybody notices.
//
// MEASURED before the guard existed:
//
//	text(.OK) then stream()          -> 200, chunked, buffered body GONE
//	text(.Bad_Request) then stream() -> 400, chunked, refusal body GONE,
//	                                    the stream's chunks sent UNDER THE 400
//
// The second is why this is a defect and not a curiosity: status from one
// response, body from another, silently. Framing was never corrupt — one status
// line, chunked only, no `Content-Length` beside it — which was worth
// establishing, because a reply carrying both is the ambiguity WP9 D2 refuses
// on the request side.
@(private)
m5_committed_then_stream :: proc(ctx: ^web.Context) {
	web.text(ctx, .Bad_Request, "REFUSED-BY-HANDLER")
	if s, ok := web.stream(ctx); ok {
		// Must be unreachable. If it runs, the refusal above is about to be
		// replaced on the wire by whatever this sends.
		web.stream_send(s, transmute([]u8)string("STREAM-WON"))
		web.stream_close(s)
	}
}

@(test)
wp96_a_stream_is_refused_after_a_response_is_committed :: proc(t: ^testing.T) {
	srv: Server
	srv.port = 51965
	srv.app = web.app()
	web.get(&srv.app, "/committed", m5_committed_then_stream)
	web.get(&srv.app, "/plain", buffered_handler)
	srv.thread = thread.create_and_start_with_poly_data(&srv, serve_thread)
	defer stop(&srv)
	ready := false
	for _ in 0 ..< 300 {
		if st, _ := get(srv.port, "/plain"); st == 200 {
			ready = true
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, ready, "server must start")

	status, raw := get(srv.port, "/committed")

	testing.expectf(
		t,
		status == 400,
		"the committed refusal must survive; got %d. A 200 here means the stream replaced it.",
		status,
	)
	testing.expect(
		t,
		strings.contains(raw, "REFUSED-BY-HANDLER"),
		"the refusal BODY must reach the client, not be abandoned when the stream detached the connection",
	)
	testing.expect(
		t,
		!strings.contains(raw, "STREAM-WON"),
		"web.stream must have returned ok=false, so nothing was streamed under the committed status",
	)
	// The framing must belong to ONE response. Both headers together is the
	// CL+TE ambiguity this project refuses on the request side; it never
	// happened here, and this keeps it that way.
	lower := strings.to_lower(raw, context.temp_allocator)
	testing.expect(
		t,
		!(strings.contains(lower, "content-length:") && strings.contains(lower, "transfer-encoding: chunked")),
		"a reply must not carry both Content-Length and Transfer-Encoding: chunked",
	)
}

// AUDIT H5 — AN IDLE STREAM MUST OUTLIVE THE ARRIVAL DEADLINE.
//
// This test exists because the line it guards was found to be UNCOVERED.
// `stream_prepare` clears `conn.request_started` when a stream takes over the
// connection; that clear was deleted and every stream suite in the project
// stayed green. A guard nothing can notice the removal of is not a guard.
//
// WHAT IT GUARDS. The sweep's arrival branch fires on
// `request_started != 0 && send_started == 0`. For a buffered request the
// handler holds the lane, so the sweep cannot run mid-request. A detached
// stream is the one shape that gives the lane back while the request cycle is
// still open — and `send_started` returns to zero the moment each send
// completes (`on_response_sent`). So a stream sitting between events has both
// conditions true, and without the clear the connection is closed at
// `max_request_time` and logged as "request read deadline exceeded".
//
// That is server-sent events, precisely: a subscriber that connects and waits.
// The failure would look like a client bug — a connection dropped a few seconds
// in, blamed on a slow request that had finished arriving long before.
//
// The stream's OWN protection is unaffected and stays where it belongs: WP92's
// `write_deadline_override` bounds every chunk send, so a slow CONSUMER is
// still cut off. What must not bound it is the deadline for bytes that already
// arrived.
Idle_Shared :: struct {
	tok:    web.Stream,
	opened: sync.Sema,
	ok:     bool,
}

g_idle: ^Idle_Shared

@(private)
idle_stream_handler :: proc(ctx: ^web.Context) {
	s, ok := web.stream(ctx)
	g_idle.tok = s
	g_idle.ok = ok
	sync.sema_post(&g_idle.opened)
	// Returns without sending anything. The subscriber is now waiting.
}

@(test)
wp96_an_idle_stream_outlives_the_arrival_deadline :: proc(t: ^testing.T) {
	DEADLINE :: 300 * time.Millisecond
	// Long enough that the sweep (250 ms granularity) gets several passes at the
	// connection while it sits idle. A shorter wait could pass by luck.
	IDLE_WAIT :: 1200 * time.Millisecond

	shared: Idle_Shared
	g_idle = &shared

	srv: Server
	srv.port = 51963
	srv.app = web.app()
	limits := web.DEFAULT_LIMITS
	limits.max_request_time = i64(DEADLINE)
	limits.max_idle_time = 0
	web.limits(&srv.app, limits)
	web.get(&srv.app, "/events", idle_stream_handler)
	web.get(&srv.app, "/plain", buffered_handler)
	srv.thread = thread.create_and_start_with_poly_data(&srv, serve_thread)
	defer stop(&srv)
	ready := false
	for _ in 0 ..< 300 {
		if st, _ := get(srv.port, "/plain"); st == 200 {
			ready = true
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	testing.expect(t, ready, "server must start")

	sock, ok := dial(srv.port)
	testing.expect(t, ok)
	defer net.close(sock)
	_, _ = net.send_tcp(sock, transmute([]u8)string("GET /events HTTP/1.1\r\nHost: x\r\n\r\n"))
	testing.expect(t, sync.sema_wait_with_timeout(&shared.opened, 3 * time.Second), "the handler must run")
	testing.expect(t, shared.ok, "web.stream must open on a real connection")

	wire: strings.Builder
	strings.builder_init(&wire, context.temp_allocator)
	testing.expect(t, recv_until(sock, &wire, "\r\n\r\n", 3 * time.Second), "the head must commit")

	// The subscriber waits, well past the arrival deadline, with nothing sent in
	// either direction. This is the whole test.
	time.sleep(IDLE_WAIT)

	// If the connection survived, an event sent now reaches the client.
	sent := web.stream_send(shared.tok, transmute([]u8)string("late-event\n"))
	testing.expectf(
		t,
		sent != .Closed,
		"the stream was closed while idle for %v under a %v arrival deadline; stream_send reported %v. `stream_prepare` must clear `conn.request_started` — an idle subscriber is not a slow request.",
		IDLE_WAIT,
		DEADLINE,
		sent,
	)

	got := recv_until(sock, &wire, "late-event", 3 * time.Second)
	testing.expectf(
		t,
		got,
		"the event sent after %v idle never reached the client: the connection was closed by the arrival deadline",
		IDLE_WAIT,
	)

	web.stream_close(shared.tok)
}

@(test)
wp96_a_handler_streams_from_a_worker_and_close_terminates :: proc(t: ^testing.T) {
	shared: Shared
	g_shared = &shared
	srv: Server
	testing.expect(t, start(&srv, 51960), "server must start")
	defer stop(&srv)

	sock, ok := dial(51960)
	testing.expect(t, ok)
	defer net.close(sock)
	_, _ = net.send_tcp(sock, transmute([]u8)string("GET /events HTTP/1.1\r\nHost: x\r\n\r\n"))
	testing.expect(t, sync.sema_wait_with_timeout(&shared.opened, 3 * time.Second), "the handler must run")
	testing.expect(t, shared.ok, "web.stream must open on a real connection")

	wire: strings.Builder
	strings.builder_init(&wire, context.temp_allocator)
	// Head commits without a body — 200, chunked, no length.
	testing.expect(t, recv_until(sock, &wire, "\r\n\r\n", 3 * time.Second), "the head must commit")
	head := strings.to_string(wire)
	testing.expect(t, strings.contains(head, "200"), "status is 200")
	testing.expect(t, strings.contains(head, "chunked"), "a stream is chunked")
	testing.expect(t, strings.contains(head, "x-content-type-options"), "secure_headers cover a stream (F5 stays closed here too)")

	// A worker thread streams three updates through the PUBLIC api.
	Worker :: struct {tok: web.Stream, thread: ^thread.Thread}
	worker_main :: proc(w: ^Worker) {
		for i in 0 ..< 3 {
			msg := [8]u8{'e', 'v', 't', '-', u8('0' + i), '\n', 0, 0}
			for web.stream_send(w.tok, msg[:6]) == .Full {time.sleep(time.Millisecond)}
		}
	}
	w := Worker{tok = shared.tok}
	w.thread = thread.create_and_start_with_poly_data(&w, worker_main)
	thread.join(w.thread)
	thread.destroy(w.thread)

	testing.expect(t, recv_until(sock, &wire, "evt-2", 3 * time.Second), "all three worker updates must arrive")

	web.stream_close(shared.tok)
	testing.expect(t, recv_until(sock, &wire, "0\r\n\r\n", 3 * time.Second), "close terminates the stream")
}

@(test)
wp96_a_buffered_route_is_untouched_by_streaming :: proc(t: ^testing.T) {
	shared: Shared
	g_shared = &shared
	srv: Server
	testing.expect(t, start(&srv, 51961), "server must start")
	defer stop(&srv)
	st, raw := get(51961, "/plain")
	testing.expect_value(t, st, 200)
	testing.expect(t, strings.contains(raw, "buffered-ok"), "the buffered body is intact")
	testing.expect(t, strings.contains(raw, "content-length"), "the buffered path still declares a length")
}

@(test)
wp96_the_in_memory_transport_reports_no_connection :: proc(t: ^testing.T) {
	// test_request has no connection to detach; web.stream must say so (ok=false)
	// rather than pretend, and the handler falls back to buffered.
	fell_back := false
	handler :: proc(ctx: ^web.Context) {
		_, ok := web.stream(ctx)
		if !ok {
			web.text(ctx, .OK, "fell-back")
		}
	}
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/x", handler)
	rec := web.test_request(&app, .GET, "/x")
	testing.expect_value(t, rec.status, web.Status.OK)
	testing.expect_value(t, rec.body, "fell-back")
	fell_back = true
	testing.expect(t, fell_back)
}
