// STREAM-001 — a detached stream must not be killed by the PREVIOUS stream's
// connection teardown.
//
// THE DEFECT. `runtime.links` is indexed by registry slot, and `retire` puts the
// slot straight back on the free list, so the next `web.stream` on the same
// server takes the same slot and overwrites the same `Stream_Link` — resetting
// `terminated` to false and installing its own token and connection. The
// finished stream's connection is torn down asynchronously, and it still carried
// `on_teardown = stream_conn_torn_down` pointing at that recycled link. A
// teardown landing after the next stream opened sailed through the
// `link.terminated` guard and closed and retired THE NEW STREAM'S token — which
// passed the generation check, because the link was holding the new token.
//
// The application saw `Stream_Send.Closed` partway through, the client got a
// `200` and a clean close with frames missing off the end, and the server logged
// nothing at all.
//
// WHY THE COUNT AND NOT THE STATUS. Measured on a campaign host before the fix,
// two servers, requests back to back:
//
//	ops/soak/smoke-server (10 frames)        10, 7, 10, 7, 10, 7
//	tests/r1-real-proxy/server (10 frames)   10, 1, 10, 1
//
// Every one of those was `HTTP/1.1 200` with a well-formed close. Nothing but
// counting the frames can tell the truncated responses from the whole ones, so
// that is what this test does. Three seconds of idle between requests made it
// disappear, which is why the requests here are deliberately back to back.
package test_stream001_slot_reuse

import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

PORT :: 18771
FRAMES :: 10
FRAME_GAP :: 20 * time.Millisecond

// Deliberately below Linux's default ephemeral range, for the reason
// tests/wp90-streaming records: an established wildcard-conflicting socket is
// enough to make a bind fail on a port nobody is listening on.

Job :: struct {
	stream: web.Stream,
}

// The producer keeps the LAST non-Sent outcome, rather than discarding it the
// way both fixtures that found this defect did. `Full` and `Closed` are
// different facts: one is a bounded queue refusing, the other is the stream
// being gone. A test that cannot tell them apart cannot say what it proved.
g_last_refusal: web.Stream_Send
g_refusals: int

@(private)
producer :: proc(job: ^Job) {
	for i in 1 ..= FRAMES {
		time.sleep(FRAME_GAP)
		frame := fmt.tprintf("data: frame-%d\n\n", i)
		result := web.stream_send(job.stream, transmute([]u8)frame)
		if result != .Sent {
			g_last_refusal = result
			g_refusals += 1
			break
		}
	}
	web.stream_close(job.stream)
	free(job)
}

@(private)
stream_handler :: proc(ctx: ^web.Context) {
	s, ok := web.stream(ctx, "text/event-stream")
	if !ok {
		web.text(ctx, .Service_Unavailable, "stream-refused")
		return
	}
	job := new(Job)
	job.stream = s
	_ = thread.create_and_start_with_poly_data(job, producer, self_cleanup = true)
}

@(private)
plain_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
}

@(private)
serve_thread :: proc(s: ^Server) {web.serve(&s.app, s.port)}

@(private)
start :: proc(s: ^Server, port: int) -> bool {
	s.port = port
	s.app = web.app()
	web.get(&s.app, "/stream", stream_handler)
	web.get(&s.app, "/plain", plain_handler)
	s.thread = thread.create_and_start_with_poly_data(s, serve_thread)
	for _ in 0 ..< 400 {
		if body, ok := fetch(port, "/plain"); ok && strings.contains(body, "ok") {
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

// fetch reads one response to completion and returns the whole raw exchange.
// `Connection: close` so the read ends at EOF rather than on a parse of the
// framing — the point of the test is what arrived, not how it was framed.
@(private)
fetch :: proc(port: int, path: string) -> (raw: string, ok: bool) {
	endpoint := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	sock, derr := net.dial_tcp(endpoint)
	if derr != nil {
		return "", false
	}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 5 * time.Second)
	req, _ := strings.concatenate(
		{"GET ", path, " HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"},
		context.temp_allocator,
	)
	if _, serr := net.send_tcp(sock, transmute([]u8)req); serr != nil {
		return "", false
	}
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	buf: [4096]u8
	for {
		n, e := net.recv_tcp(sock, buf[:])
		if n > 0 {strings.write_bytes(&b, buf[:n])}
		if n == 0 || e != nil {break}
	}
	return strings.to_string(b), true
}

@(private)
count_frames :: proc(raw: string) -> int {
	n := 0
	for i in 1 ..= FRAMES {
		if strings.contains(raw, fmt.tprintf("frame-%d\n", i)) {
			n += 1
		}
	}
	return n
}

// THE REGRESSION. Streams requested back to back, on one server, each one
// complete.
//
// Six rather than two: the defect alternated, so a two-request test passes half
// the time by landing on the good phase. Six makes a phase-dependent pass
// impossible and still runs in about a second and a half.
@(test)
back_to_back_streams_are_not_truncated :: proc(t: ^testing.T) {
	g_last_refusal = .Sent
	g_refusals = 0

	server: Server
	if !testing.expect(t, start(&server, PORT), "the test server never became ready") {
		return
	}
	defer stop(&server)

	counts: [6]int
	for i in 0 ..< 6 {
		raw, ok := fetch(PORT, "/stream")
		if !testing.expectf(t, ok, "request %d could not be made", i + 1) {
			return
		}
		testing.expectf(
			t,
			strings.has_prefix(raw, "HTTP/1.1 200"),
			"request %d did not answer 200: %q",
			i + 1,
			raw[:min(len(raw), 40)],
		)
		counts[i] = count_frames(raw)
	}

	for count, i in counts {
		testing.expectf(
			t,
			count == FRAMES,
			"stream %d delivered %d of %d frames (all six: %v). A stream truncated by the PREVIOUS stream's connection teardown answers 200 and closes cleanly, so the frame count is the only thing that can see it. Last send refusal: %v.",
			i + 1,
			count,
			FRAMES,
			counts,
			g_last_refusal,
		)
	}

	// The producer side of the same fact. Before the fix this was `Closed`
	// partway through the second stream, and asserting it here is what keeps the
	// test honest about WHICH failure it is guarding: a `Full` would mean a
	// bounded queue refusing, which is a different defect and must not pass as
	// this one.
	testing.expectf(
		t,
		g_refusals == 0,
		"a producer was refused %d time(s), last outcome %v; with one stream at a time and a 20 ms gap, no send should be refused at all",
		g_refusals,
		g_last_refusal,
	)
}
