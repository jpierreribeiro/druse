// WP92 — response backpressure and slow-consumer policy.
//
// The caps themselves (per-stream events/bytes, process budget, refusal as
// the canonical full result) are the WP88 registry's, proven byte-exact
// there. WP92 pins the POLICY layered on top:
//
//   - refusals and slow-abort are COUNTED, not logged per event (WP47's rule
//     for admission, applied to streams): an operator sizes queues by them;
//   - a detached stream is safe WITHOUT TUNING — with the write deadline left
//     off, a stream connection still resolves to the pre-registered 30 s
//     default, because "off" for a buffered response must not mean unbounded
//     for an infinite one;
//   - one slow consumer does not stop an unrelated fast one: on the raw wire,
//     a fast client completes while a never-reading client sits saturated.
package test_wp92_backpressure

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import http "druse:vendor/odin-http"
import stream "druse:web/internal/stream"
import transport "druse:web/internal/transport"

@(test)
wp92_the_stream_write_deadline_is_safe_without_tuning :: proc(t: ^testing.T) {
	// Pure resolution, so this cannot be a two-instance-counter artifact: with
	// the deadline off, a stream still gets the pre-registered default; with
	// it set, the app's value wins.
	testing.expect_value(t, http.stream_effective_write_deadline(0), http.DRUSE_STREAM_DEFAULT_WRITE_TIMEOUT)
	testing.expect_value(t, http.stream_effective_write_deadline(5 * time.Second), 5 * time.Second)
	testing.expect(t, http.DRUSE_STREAM_DEFAULT_WRITE_TIMEOUT > 0, "the default must actually bound something")
}

@(test)
wp92_refusals_are_counted_not_logged :: proc(t: ^testing.T) {
	r: stream.Registry
	ok := stream.registry_init(&r, stream.Capacity {
		max_streams = 1, max_events_stream = 2, max_bytes_stream = 128,
		max_bytes_total = 128, tick_progress = 128,
	})
	testing.expect(t, ok)
	defer stream.registry_destroy(&r)
	tok, _ := stream.open(&r, 1)

	testing.expect_value(t, stream.counters(&r).refused_stream_full, 0)
	payload := [8]u8{}
	testing.expect_value(t, stream.try_send(&r, tok, payload[:]), stream.Send_Result.Sent)
	testing.expect_value(t, stream.try_send(&r, tok, payload[:]), stream.Send_Result.Sent)
	// Event cap (2) reached: the next several refuse and each is counted once.
	testing.expect_value(t, stream.try_send(&r, tok, payload[:]), stream.Send_Result.Full)
	testing.expect_value(t, stream.try_send(&r, tok, payload[:]), stream.Send_Result.Full)
	testing.expect_value(t, stream.counters(&r).refused_stream_full, 2)
	testing.expect_value(t, stream.counters(&r).refused_budget_full, 0)
}

@(test)
wp92_the_process_budget_refusal_has_its_own_counter :: proc(t: ^testing.T) {
	r: stream.Registry
	_ = stream.registry_init(&r, stream.Capacity {
		max_streams = 2, max_events_stream = 8, max_bytes_stream = 128,
		max_bytes_total = 160, tick_progress = 128,
	})
	defer stream.registry_destroy(&r)
	one, _ := stream.open(&r, 1)
	two, _ := stream.open(&r, 2)
	chunk := make([]u8, 100)
	defer delete(chunk)
	testing.expect_value(t, stream.try_send(&r, one, chunk), stream.Send_Result.Sent)
	// Per-stream cap has room on `two`; the PROCESS budget does not.
	testing.expect_value(t, stream.try_send(&r, two, chunk), stream.Send_Result.Full)
	c := stream.counters(&r)
	testing.expect_value(t, c.refused_budget_full, 1)
	testing.expect_value(t, c.refused_stream_full, 0)
}

// --- raw-wire isolation: a slow consumer does not stall a fast one ----------

Lab :: struct {
	ready:      sync.Sema,
	opened:     sync.Sema,
	toks:       [2]stream.Token,
	oks:        [2]bool,
	next:       int,
	serve_done: sync.Sema,
	port:       int,
	thread:     ^thread.Thread,
}

@(private)
lab_dispatch :: proc(user: rawptr, inbound: transport.Inbound, out: ^transport.Outbound, allocator := context.allocator) {
	lab := (^Lab)(user)
	tok, ok := transport.stream_open(inbound.exchange)
	idx := lab.next
	lab.next += 1
	if idx < 2 {
		lab.toks[idx] = tok
		lab.oks[idx] = ok
	}
	out.status = 200
	out.detached = ok
	if !ok {
		out.status = 503
	}
	sync.sema_post(&lab.opened)
}

@(private)
serve_thread :: proc(lab: ^Lab) {
	cfg := transport.Config {
		port             = lab.port,
		max_body         = 64 * 1024,
		max_request_line = 8000,
		max_headers      = 8000,
		max_drain_time   = i64(2 * time.Second),
		max_handlers     = 2,
		stream_capacity  = stream.Capacity {
			max_streams       = 4,
			max_events_stream = 4,
			max_bytes_stream  = 2048,
			max_bytes_total   = 8192,
			tick_progress     = 2048,
		},
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
wp92_a_slow_consumer_does_not_stall_a_fast_one :: proc(t: ^testing.T) {
	lab: Lab
	lab.port = 51940
	lab.thread = thread.create_and_start_with_poly_data(&lab, serve_thread)
	testing.expect(t, sync.sema_wait_with_timeout(&lab.ready, 5 * time.Second), "transport must start")
	defer {
		transport.request_stop()
		_ = sync.sema_wait_with_timeout(&lab.serve_done, 10 * time.Second)
		thread.join(lab.thread)
		thread.destroy(lab.thread)
	}

	// The SLOW client: opens a stream, shrinks its window, never reads.
	slow, ok_s := dial(51940)
	testing.expect(t, ok_s)
	defer net.close(slow)
	net.set_option(slow, .Receive_Buffer_Size, 512)
	_, _ = net.send_tcp(slow, transmute([]u8)string("GET /slow HTTP/1.1\r\nHost: x\r\n\r\n"))
	testing.expect(t, sync.sema_wait_with_timeout(&lab.opened, 3 * time.Second))

	// The FAST client: opens its own stream and reads promptly.
	fast, ok_f := dial(51940)
	testing.expect(t, ok_f)
	defer net.close(fast)
	_, _ = net.send_tcp(fast, transmute([]u8)string("GET /fast HTTP/1.1\r\nHost: x\r\n\r\n"))
	testing.expect(t, sync.sema_wait_with_timeout(&lab.opened, 3 * time.Second))
	testing.expect(t, lab.oks[0] && lab.oks[1], "both streams open")

	reg := transport.stream_registry_current()

	// Saturate the slow stream (its queue fills because nothing drains it).
	blob := make([]u8, 1500)
	defer delete(blob)
	for _ in 0 ..< 8 {
		_ = stream.try_send(reg, lab.toks[0], blob)
	}

	// The fast stream must still deliver, promptly, while the slow one is stuck.
	fast_payload := transmute([]u8)string("FAST-OK")
	testing.expect_value(t, stream.try_send(reg, lab.toks[1], fast_payload), stream.Send_Result.Sent)

	net.set_option(fast, .Receive_Timeout, 3 * time.Second)
	wire: strings.Builder
	defer strings.builder_destroy(&wire)
	buffer: [1024]u8
	delivered := false
	deadline := time.tick_now()
	for time.tick_since(deadline) < 3 * time.Second {
		n, err := net.recv_tcp(fast, buffer[:])
		if n > 0 {
			strings.write_bytes(&wire, buffer[:n])
			if strings.contains(strings.to_string(wire), "FAST-OK") {
				delivered = true
				break
			}
		}
		if n == 0 || err != nil {break}
	}
	testing.expect(t, delivered, "the fast consumer completes while the slow one is saturated (independent streams)")
	_ = stream.close(reg, lab.toks[1])
}
