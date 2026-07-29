// WP90b — the detached-stream adapter on the raw wire.
//
// The transport boundary is driven directly (the private Dispatch_Proc — the
// same level tests/wp9-wire trusts), because the PUBLIC stream surface does
// not exist yet: names are born from evidence and freeze at WP101. The test
// dispatch stands where the core will stand in WP91; what is proven here is
// the ADAPTER contract of phase-7-plan.md §WP90:
//
//   - status/headers commit without a complete body (chunked, no length);
//   - body chunks are written incrementally on the owner lane — each frame is
//     observed on the wire BEFORE the next send happens, so this cannot be a
//     buffered response in disguise;
//   - a producer on a foreign thread only enqueues (WP89) and the wire still
//     frames correctly;
//   - close ends the stream with a terminating chunk and connection close;
//   - a client disconnect mid-stream refuses the producer and releases the
//     registry slot (proven by reopening under max_streams = 1);
//   - a buffered route on the same server is untouched.
package test_wp90_streaming

import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import stream "druse:web/internal/stream"
import transport "druse:web/internal/transport"

Lab :: struct {
	ready:      sync.Sema,
	opened:     sync.Sema,
	tok:        stream.Token,
	registry:   ^stream.Registry, // captured at open time, valid while serving
	open_ok:    bool,
	serve_done: sync.Sema,
	port:       int,
	thread:     ^thread.Thread,
}

@(private)
lab_dispatch :: proc(user: rawptr, inbound: transport.Inbound, out: ^transport.Outbound, allocator := context.allocator) {
	lab := (^Lab)(user)
	if inbound.path == "/stream" {
		tok, ok := transport.stream_open(inbound.exchange)
		lab.tok = tok
		lab.open_ok = ok
		if ok {
			out.status = 200
			headers := make([]transport.Header, 1, allocator)
			headers[0] = transport.Header{name = "content-type", value = "text/plain"}
			out.headers = headers
			out.detached = true
		} else {
			out.status = 503
		}
		sync.sema_post(&lab.opened)
		return
	}
	out.status = 200
	body := transmute([]u8)string("ok")
	transport.copy_response(out, 200, nil, body, allocator)
}

@(private)
serve_thread :: proc(lab: ^Lab) {
	cfg := transport.Config {
		port             = lab.port,
		max_body         = 64 * 1024,
		max_request_line = 8000,
		max_headers      = 8000,
		max_drain_time   = i64(2 * time.Second),
		max_handlers     = 1,
		stream_capacity  = stream.Capacity {
			max_streams       = 1, // slot release is observable, not assumed
			max_events_stream = 8,
			max_bytes_stream  = 4096,
			max_bytes_total   = 4096,
			tick_progress     = 4096,
		},
		dispatch         = lab_dispatch,
		user             = lab,
		on_ready         = proc(user: rawptr) {
			sync.sema_post(&(^Lab)(user).ready)
		},
	}
	_ = transport.serve(cfg)
	sync.sema_post(&lab.serve_done)
}

@(private)
start_lab :: proc(lab: ^Lab, port: int) -> bool {
	lab.port = port
	lab.thread = thread.create_and_start_with_poly_data(lab, serve_thread)
	return sync.sema_wait_with_timeout(&lab.ready, 5 * time.Second)
}

@(private)
stop_lab :: proc(lab: ^Lab) {
	transport.request_stop()
	_ = sync.sema_wait_with_timeout(&lab.serve_done, 10 * time.Second)
	if lab.thread != nil {
		thread.join(lab.thread)
		thread.destroy(lab.thread)
		lab.thread = nil
	}
}

@(private)
dial :: proc(port: int) -> (net.TCP_Socket, bool) {
	endpoint := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	for _ in 0 ..< 100 {
		sock, err := net.dial_tcp(endpoint)
		if err == nil {
			return sock, true
		}
		time.sleep(2 * time.Millisecond)
	}
	return {}, false
}

// recv_until reads until `marker` is present in the accumulated bytes or the
// timeout passes; returns everything read.
@(private)
recv_until :: proc(sock: net.TCP_Socket, builder: ^strings.Builder, marker: string, timeout: time.Duration) -> bool {
	net.set_option(sock, .Receive_Timeout, timeout)
	buffer: [4096]u8
	deadline := time.tick_now()
	for {
		if strings.contains(strings.to_string(builder^), marker) {
			return true
		}
		if time.tick_since(deadline) > timeout {
			return false
		}
		n, err := net.recv_tcp(sock, buffer[:])
		if n > 0 {
			strings.write_bytes(builder, buffer[:n])
		}
		if n == 0 || (err != nil) {
			return strings.contains(strings.to_string(builder^), marker)
		}
	}
}

@(test)
wp90b_chunks_arrive_incrementally_and_close_terminates :: proc(t: ^testing.T) {
	lab: Lab
	testing.expect(t, start_lab(&lab, 51920), "transport must start")
	defer stop_lab(&lab)

	sock, ok := dial(51920)
	testing.expect(t, ok)
	defer net.close(sock)
	request := "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n"
	_, send_err := net.send_tcp(sock, transmute([]u8)string(request))
	testing.expect(t, send_err == nil)

	testing.expect(t, sync.sema_wait_with_timeout(&lab.opened, 3 * time.Second), "the dispatch must have run")
	testing.expect(t, lab.open_ok, "the stream must open within the registry cap")

	wire: strings.Builder
	defer strings.builder_destroy(&wire)

	// The heading commits without any body byte.
	testing.expect(t, recv_until(sock, &wire, "\r\n\r\n", 3 * time.Second), "status/headers must commit before any chunk")
	head := strings.to_string(wire)
	testing.expect(t, strings.contains(head, "200"), "the committed status is the dispatch's")
	testing.expect(t, strings.contains(head, "transfer-encoding: chunked") || strings.contains(head, "Transfer-Encoding: chunked"), "the stream is chunked")
	testing.expect(t, !strings.contains(head, "content-length"), "a detached stream has no length")

	// Chunk one is observed on the wire BEFORE chunk two is even produced —
	// the definition of incremental.
	reg := transport.stream_registry_current()
	testing.expect(t, reg != nil, "the test hook must expose the registry")
	payload_one := transmute([]u8)string("first-event")
	testing.expect_value(t, stream.try_send(reg, lab.tok, payload_one), stream.Send_Result.Sent)
	testing.expect(t, recv_until(sock, &wire, "first-event", 3 * time.Second), "the first chunk must arrive while the stream is open")
	testing.expect(t, strings.contains(strings.to_string(wire), "b\r\nfirst-event\r\n"), "the chunk is framed with its hex size")

	payload_two := transmute([]u8)string("second")
	testing.expect_value(t, stream.try_send(reg, lab.tok, payload_two), stream.Send_Result.Sent)
	testing.expect(t, recv_until(sock, &wire, "second", 3 * time.Second), "the second chunk follows")

	// Close: terminator, then EOF.
	testing.expect(t, stream.close(reg, lab.tok))
	testing.expect(t, recv_until(sock, &wire, "0\r\n\r\n", 3 * time.Second), "close must write the terminating chunk")
	buffer: [64]u8
	n, _ := net.recv_tcp(sock, buffer[:])
	testing.expect_value(t, n, 0) // EOF: the bridge closes after a stream
}

@(test)
wp90b_a_buffered_route_is_untouched :: proc(t: ^testing.T) {
	lab: Lab
	testing.expect(t, start_lab(&lab, 51921), "transport must start")
	defer stop_lab(&lab)

	sock, ok := dial(51921)
	testing.expect(t, ok)
	defer net.close(sock)
	request := "GET /plain HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	_, send_err := net.send_tcp(sock, transmute([]u8)string(request))
	testing.expect(t, send_err == nil)
	wire: strings.Builder
	defer strings.builder_destroy(&wire)
	testing.expect(t, recv_until(sock, &wire, "ok", 3 * time.Second))
	view := strings.to_string(wire)
	testing.expect(t, strings.contains(view, "200"))
	testing.expect(t, strings.contains(view, "content-length: 2") || strings.contains(view, "Content-Length: 2"), "the buffered path still declares a length")
}

@(test)
wp90b_disconnect_mid_stream_refuses_the_producer_and_frees_the_slot :: proc(t: ^testing.T) {
	lab: Lab
	testing.expect(t, start_lab(&lab, 51922), "transport must start")
	defer stop_lab(&lab)

	sock, ok := dial(51922)
	testing.expect(t, ok)
	request := "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n"
	_, _ = net.send_tcp(sock, transmute([]u8)string(request))
	testing.expect(t, sync.sema_wait_with_timeout(&lab.opened, 3 * time.Second))
	testing.expect(t, lab.open_ok)
	reg := transport.stream_registry_current()

	wire: strings.Builder
	defer strings.builder_destroy(&wire)
	payload := transmute([]u8)string("gone")
	testing.expect_value(t, stream.try_send(reg, lab.tok, payload), stream.Send_Result.Sent)
	testing.expect(t, recv_until(sock, &wire, "gone", 3 * time.Second))

	// The client vanishes. The next writes hit the dead socket; the adapter
	// tears the stream down and the producer is refused from then on.
	net.close(sock)
	first_tok := lab.tok
	refused := false
	for _ in 0 ..< 400 { // sends provoke the write error; refusal follows
		res := stream.try_send(reg, first_tok, payload)
		if res == .Closed || res == .Stale {
			refused = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(t, refused, "after a disconnect the producer must see a terminal refusal, never silence")

	// With max_streams = 1, a NEW stream can only open if the dead one's slot
	// was retired — release is proven, not assumed.
	sock2, ok2 := dial(51922)
	testing.expect(t, ok2)
	defer net.close(sock2)
	_, _ = net.send_tcp(sock2, transmute([]u8)string(request))
	testing.expect(t, sync.sema_wait_with_timeout(&lab.opened, 3 * time.Second), "the second dispatch must run")
	reopened := false
	if lab.open_ok && lab.tok.generation > first_tok.generation {
		reopened = true
	}
	testing.expect(t, reopened, "the slot must be reusable after the disconnect teardown, with a new generation")
	_ = stream.close(reg, lab.tok)
}

@(test)
wp90b_a_final_event_survives_an_immediate_close :: proc(t: ^testing.T) {
	// The graceful-close guarantee: an application may send its LAST event and
	// close immediately; the owner-lane pump flushes the queued event BEFORE
	// the terminating chunk, rather than discarding it. This is what makes
	// web.stream_close usable for a bounded stream that ends with a final
	// message (a job result, a done marker).
	lab: Lab
	testing.expect(t, start_lab(&lab, 51925), "transport must start")
	defer stop_lab(&lab)

	sock, ok := dial(51925)
	testing.expect(t, ok)
	defer net.close(sock)
	_, _ = net.send_tcp(sock, transmute([]u8)string("GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n"))
	testing.expect(t, sync.sema_wait_with_timeout(&lab.opened, 3 * time.Second))
	testing.expect(t, lab.open_ok)

	reg := transport.stream_registry_current()
	// Enqueue the final event, then close in the very next statement.
	testing.expect_value(t, stream.try_send(reg, lab.tok, transmute([]u8)string("FINAL-EVENT")), stream.Send_Result.Sent)
	_ = stream.close(reg, lab.tok)

	wire: strings.Builder
	defer strings.builder_destroy(&wire)
	// The final event must appear, AND before the terminator.
	testing.expect(t, recv_until(sock, &wire, "FINAL-EVENT", 3 * time.Second), "the final queued event is flushed, not discarded")
	testing.expect(t, recv_until(sock, &wire, "0\r\n\r\n", 3 * time.Second), "the terminator follows the final event")
	view := strings.to_string(wire)
	fin := strings.index(view, "FINAL-EVENT")
	term := strings.index(view, "0\r\n\r\n")
	testing.expect(t, fin >= 0 && term > fin, "the terminator comes AFTER the final event on the wire")
}
