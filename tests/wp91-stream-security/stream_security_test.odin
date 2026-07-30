// WP91 — commit, partial-write and failure security for the detached stream.
//
// The Phase-2 recovery lab predicted the response-splitting risk; these cases
// pin its absence on the real wire:
//
//   - after a detached commit there is EXACTLY ONE HTTP envelope — even when
//     a confused dispatch also filled the buffered body, those bytes never
//     reach the wire and no second status line ever appears;
//   - a header value carrying CR/LF cannot become its own header line
//     (vendored patch 17's escaping, proven on the streaming commit path);
//   - a slow consumer receiving many distinct chunks gets every byte exactly
//     once, in order — short writes never duplicate or drop (the nbio send
//     completes fully before the next event's bytes are released).
package test_wp91_stream_security

import "core:fmt"
import "core:net"
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
	open_ok:    bool,
	serve_done: sync.Sema,
	port:       int,
	mode:       string, // selects the dispatch behaviour per test
	thread:     ^thread.Thread,
}

@(private)
lab_dispatch :: proc(user: rawptr, inbound: transport.Inbound, out: ^transport.Outbound, allocator := context.allocator) {
	lab := (^Lab)(user)
	tok, ok := transport.stream_open(inbound.exchange)
	lab.tok = tok
	lab.open_ok = ok
	if !ok {
		out.status = 503
		sync.sema_post(&lab.opened)
		return
	}
	out.status = 200
	switch lab.mode {
	case "confused":
		// The dispatch opened a stream AND filled a buffered body: the body
		// must never reach the wire.
		body := transmute([]u8)string("BUFFERED-BYTES-MUST-NOT-APPEAR")
		transport.copy_response(out, 200, nil, body, allocator)
		out.status = 200
	case "inject":
		headers := make([]transport.Header, 1, allocator)
		headers[0] = transport.Header {
			name  = "x-app",
			value = "safe\r\nx-injected: 1",
		}
		out.headers = headers
	}
	out.detached = true
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
		max_handlers     = 1,
		stream_capacity  = stream.Capacity {
			max_streams       = 2,
			max_events_stream = 8,
			max_bytes_stream  = 8192,
			max_bytes_total   = 8192,
			tick_progress     = 8192,
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
start_lab :: proc(lab: ^Lab, port: int, mode: string) -> bool {
	lab.port = port
	lab.mode = mode
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

@(private)
read_stream :: proc(sock: net.TCP_Socket, builder: ^strings.Builder, until: string, timeout: time.Duration) -> bool {
	net.set_option(sock, .Receive_Timeout, timeout)
	buffer: [2048]u8
	for {
		if strings.contains(strings.to_string(builder^), until) {
			return true
		}
		n, err := net.recv_tcp(sock, buffer[:])
		if n > 0 {
			strings.write_bytes(builder, buffer[:n])
		}
		if n == 0 || err != nil {
			return strings.contains(strings.to_string(builder^), until)
		}
	}
}

@(test)
wp91_exactly_one_envelope_even_for_a_confused_dispatch :: proc(t: ^testing.T) {
	lab: Lab
	testing.expect(t, start_lab(&lab, 51930, "confused"), "transport must start")
	defer stop_lab(&lab)

	sock, ok := dial(51930)
	testing.expect(t, ok)
	defer net.close(sock)
	request := "GET /s HTTP/1.1\r\nHost: localhost\r\n\r\n"
	_, _ = net.send_tcp(sock, transmute([]u8)string(request))
	testing.expect(t, sync.sema_wait_with_timeout(&lab.opened, 3 * time.Second))
	testing.expect(t, lab.open_ok)

	reg := transport.stream_registry_current()
	payload := transmute([]u8)string("only-this")
	testing.expect_value(t, stream.try_send(reg, lab.tok, payload), stream.Send_Result.Sent)

	wire: strings.Builder
	defer strings.builder_destroy(&wire)
	// The chunk is on the wire BEFORE close — close's own policy discards
	// what is still queued, which is not what this test is about.
	testing.expect(t, read_stream(sock, &wire, "only-this", 3 * time.Second), "the stream's chunk must arrive")
	_ = stream.close(reg, lab.tok)
	testing.expect(t, read_stream(sock, &wire, "0\r\n\r\n", 3 * time.Second), "the stream must terminate")
	view := strings.to_string(wire)
	testing.expect_value(t, strings.count(view, "HTTP/1.1"), 1)
	testing.expect(t, !strings.contains(view, "BUFFERED-BYTES-MUST-NOT-APPEAR"), "the confused dispatch's buffered body never reaches the wire")
	testing.expect(t, strings.contains(view, "only-this"), "the stream's own bytes do")
}

@(test)
wp91_a_crlf_header_value_cannot_split_the_commit :: proc(t: ^testing.T) {
	lab: Lab
	testing.expect(t, start_lab(&lab, 51931, "inject"), "transport must start")
	defer stop_lab(&lab)

	sock, ok := dial(51931)
	testing.expect(t, ok)
	defer net.close(sock)
	request := "GET /s HTTP/1.1\r\nHost: localhost\r\n\r\n"
	_, _ = net.send_tcp(sock, transmute([]u8)string(request))
	testing.expect(t, sync.sema_wait_with_timeout(&lab.opened, 3 * time.Second))
	testing.expect(t, lab.open_ok)

	reg := transport.stream_registry_current()
	_ = stream.close(reg, lab.tok)

	wire: strings.Builder
	defer strings.builder_destroy(&wire)
	testing.expect(t, read_stream(sock, &wire, "0\r\n\r\n", 3 * time.Second))
	view := strings.to_string(wire)
	// The vendored sink escapes CR and LF (patches 17 + upstream \n): the
	// injected sequence must not exist as a real header line boundary.
	testing.expect(t, !strings.contains(view, "\r\nx-injected: 1\r\n"), "a CR/LF header value must not become its own header line")
}

@(test)
wp91_a_slow_consumer_receives_every_byte_exactly_once :: proc(t: ^testing.T) {
	lab: Lab
	testing.expect(t, start_lab(&lab, 51932, "plain"), "transport must start")
	defer stop_lab(&lab)

	sock, ok := dial(51932)
	testing.expect(t, ok)
	defer net.close(sock)
	net.set_option(sock, .Receive_Buffer_Size, 512) // force short writes server-side
	request := "GET /s HTTP/1.1\r\nHost: localhost\r\n\r\n"
	_, _ = net.send_tcp(sock, transmute([]u8)string(request))
	testing.expect(t, sync.sema_wait_with_timeout(&lab.opened, 3 * time.Second))
	testing.expect(t, lab.open_ok)

	reg := transport.stream_registry_current()

	// A producer thread pushes 60 distinct 64-byte chunks with retries; the
	// client below reads deliberately slowly with a tiny buffer.
	Producer :: struct {
		reg:    ^stream.Registry,
		tok:    stream.Token,
		sent:   int,
		thread: ^thread.Thread,
	}
	producer_main :: proc(p: ^Producer) {
		chunk: [64]u8
		for i in 0 ..< 60 {
			marker := fmt.bprintf(chunk[:], "chunk-%03d|", i)
			for j in len(marker) ..< len(chunk) {
				chunk[j] = u8('a' + i % 26)
			}
			for {
				switch stream.try_send(p.reg, p.tok, chunk[:]) {
				case .Sent:
					p.sent += 1
				case .Full:
					time.sleep(time.Millisecond)
					continue
				case .Closed, .Stale, .Unimplemented:
				}
				break
			}
		}
	}
	producer := Producer{reg = reg, tok = lab.tok}
	producer.thread = thread.create_and_start_with_poly_data(&producer, producer_main)

	wire: strings.Builder
	defer strings.builder_destroy(&wire)
	net.set_option(sock, .Receive_Timeout, 5 * time.Second)
	buffer: [256]u8 // small reads, slow pace: the short-write laboratory
	deadline := time.tick_now()
	for {
		view := strings.to_string(wire)
		if strings.contains(view, "chunk-059|") {
			break
		}
		if time.tick_since(deadline) > 30 * time.Second {
			break
		}
		n, err := net.recv_tcp(sock, buffer[:])
		if n > 0 {
			strings.write_bytes(&wire, buffer[:n])
		}
		if n == 0 || err != nil {
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	thread.join(producer.thread)
	thread.destroy(producer.thread)
	_ = stream.close(reg, lab.tok)

	testing.expect_value(t, producer.sent, 60)
	view := strings.to_string(wire)
	for i in 0 ..< 60 {
		marker_buf: [16]u8
		marker := fmt.bprintf(marker_buf[:], "chunk-%03d|", i)
		testing.expect_value(t, strings.count(view, marker), 1) // exactly once, never duplicated by a retry
	}
}
