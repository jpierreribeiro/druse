// WP95 — stream/body stop, drain and forced cancellation on the raw wire.
//
// The one honest process deadline is `max_drain_time` (spec §2): open detached
// streams must terminate or be cancelled within it, riding the SAME clock as
// every other in-flight request — no stream-specific second grace field. This
// proves it end to end: several long-lived streams are opened and left open
// (their producers never close them), then `web.stop` is called; every one is
// released and `serve` returns within the deadline. A modest count keeps the
// suite quick on a shared machine; WP96 owns the 3,000-stream scale lab.
package test_wp95_drain

import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import ingest "druse:web/internal/ingest"
import stream "druse:web/internal/stream"
import transport "druse:web/internal/transport"

STREAMS :: 24

Lab :: struct {
	ready:      sync.Sema,
	opened:     sync.Sema,
	toks:       [STREAMS]stream.Token,
	n:          int,
	serve_done: sync.Sema,
	port:       int,
	thread:     ^thread.Thread,
}

@(private)
lab_dispatch :: proc(user: rawptr, inbound: transport.Inbound, out: ^transport.Outbound, allocator := context.allocator) {
	lab := (^Lab)(user)
	tok, ok := transport.stream_open(inbound.exchange)
	if ok && lab.n < STREAMS {
		lab.toks[lab.n] = tok
		lab.n += 1
	}
	out.status = ok ? 200 : 503
	out.detached = ok
	sync.sema_post(&lab.opened)
}

@(private)
serve_thread :: proc(lab: ^Lab) {
	cfg := transport.Config {
		port             = lab.port,
		max_body         = 64 * 1024,
		max_request_line = 8000,
		max_headers      = 8000,
		// The deadline under test: generous enough to be reliable on a loaded
		// machine, tight enough that a broken drain would blow it.
		max_drain_time   = i64(2 * time.Second),
		max_handlers     = 4,
		stream_capacity  = stream.Capacity{max_streams = 64, max_events_stream = 8, max_bytes_stream = 4096, max_bytes_total = 65536, tick_progress = 4096},
		dispatch         = lab_dispatch,
		user             = lab,
		on_ready         = proc(user: rawptr) {sync.sema_post(&(^Lab)(user).ready)},
	}
	_ = transport.serve(cfg)
	sync.sema_post(&lab.serve_done)
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

@(test)
wp95_open_streams_terminate_within_the_drain_deadline :: proc(t: ^testing.T) {
	lab: Lab
	lab.port = 51950
	lab.thread = thread.create_and_start_with_poly_data(&lab, serve_thread)
	testing.expect(t, sync.sema_wait_with_timeout(&lab.ready, 5 * time.Second), "transport must start")

	socks: [STREAMS]net.TCP_Socket
	for i in 0 ..< STREAMS {
		sock, ok := dial(51950)
		testing.expect(t, ok, "each stream client must connect")
		socks[i] = sock
		_, _ = net.send_tcp(sock, transmute([]u8)string("GET /s HTTP/1.1\r\nHost: x\r\n\r\n"))
		testing.expect(t, sync.sema_wait_with_timeout(&lab.opened, 3 * time.Second), "each dispatch must run")
	}
	testing.expect_value(t, lab.n, STREAMS)

	reg := transport.stream_registry_current()
	testing.expect(t, reg != nil)
	testing.expect_value(t, stream.live_streams(reg), STREAMS)

	// Push one event into each so the pump is genuinely mid-stream.
	payload := transmute([]u8)string("tick")
	for i in 0 ..< STREAMS {
		_ = stream.try_send(reg, lab.toks[i], payload)
	}

	// Now drain. The deadline is 2s; `serve` must return well inside a
	// generous ceiling, and every stream slot must be released.
	began := time.tick_now()
	transport.request_stop(transport.server_current())
	returned := sync.sema_wait_with_timeout(&lab.serve_done, 6 * time.Second)
	elapsed := time.tick_since(began)
	testing.expect(t, returned, "serve must return after drain")
	testing.expect(t, elapsed < 5 * time.Second, "drain must complete within a bound tied to max_drain_time, not hang")

	// WP123 — THE ASSERTION THAT NAMES THE MECHANISM, and it was missing.
	//
	// The bound above is satisfied by the WRONG implementation. If the framework
	// never signals the stream registry at all, the backend's own
	// `max_drain_time` force-closes every open stream at 2 s and `serve` returns
	// comfortably inside 5 s — green, with the graceful path unexercised.
	// MEASURED: with the drain call removed this suite stayed fully green.
	//
	// `stream.drain_begin` is what makes the drain GRACEFUL — it wakes every
	// owner lane to flush its queue and write the terminator — and the observable
	// difference is that the drain finishes PROMPTLY instead of at the deadline.
	// So the assertion is a ceiling well below `max_drain_time`, which only the
	// woken path can meet.
	//
	// It is also the control for vendor patch 43: the registry drain now runs
	// from the backend's own shutdown rather than from the caller's thread, which
	// is what makes `web.stop` async-signal-safe. If that hook stops firing, this
	// is the line that says so.
	testing.expectf(
		t,
		elapsed < time.Second,
		"the drain took %v, at or past the %v deadline: the streams were FORCE-CLOSED when the deadline expired rather than woken to terminate. The registry drain (stream.drain_begin, run from the backend shutdown hook) did not fire.",
		elapsed,
		2 * time.Second,
	)

	for i in 0 ..< STREAMS {net.close(socks[i])}
	thread.join(lab.thread)
	thread.destroy(lab.thread)
	// After serve returns, the registry is destroyed; the process-wide global
	// is cleared. The proof is that drain terminated, not a post-hoc count.
}

@(test)
wp95_admission_refuses_new_spools_once_draining :: proc(t: ^testing.T) {
	a: ingest.Admission
	testing.expect(t, ingest.admission_init(&a, ingest.Spool_Config{dir = "/tmp/druse-wp95", max_concurrent = 4}))
	defer ingest.admission_destroy(&a)
	// A slot is available before drain…
	testing.expect_value(t, ingest.admit(&a), ingest.Ingest_Result.Ready)
	// …and refused after it, with the same typed result as a capacity refusal.
	ingest.admission_drain(&a)
	testing.expect_value(t, ingest.admit(&a), ingest.Ingest_Result.Refused_Admission)
}
