// WP90 — ADR-039 write and idle deadlines, proven on the raw wire.
//
// The Phase-6.5 attempt at this feature "did not fire" — and the diagnosis
// that unblocked it is executable here: the deadline DID need new stamps on
// the send path, but the graceful close it used flushed kernel-buffered bytes
// to the slow reader first, so the test's EOF-watch could not see the close
// inside its window. The shipped design aborts (SO_LINGER 0 → RST) on the
// write deadline, which makes the close observable the moment it fires — and
// these tests measure BEHAVIOUR on a real socket, never package counters (the
// two-instance trap recorded in the WP2 memory).
package test_wp90_deadlines

import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import web "uruquim:web"

// The body a HEALTHY reader drains end to end. It only has to be big enough to
// take more than one write; it is deliberately NOT the stall size, because a
// fast reader has to swallow the whole thing inside its receive timeout.
BIG_BYTES :: 8 * 1024 * 1024

// THE STALL BODY MUST EXCEED THE KERNEL BUFFER PAIR, AND 8 MiB DID NOT.
//
// The write-deadline case works by stalling a reader so the server's send
// cannot finish. If the whole body fits in the sender's send buffer plus the
// receiver's receive buffer, the send COMPLETES, nothing is ever stalled, and
// the deadline correctly has nothing to abort — the test then fails while the
// framework behaves exactly as specified.
//
// The stall case used BIG_BYTES, commented "far beyond any kernel buffer pair".
// It is not. Measured on a host with `net.ipv4.tcp_rmem` max 32 MiB and
// `net.core.wmem_max` 4 MiB, the pair absorbed ~8.3 MiB: an 8 MiB body
// completed with `write_deadline_aborts` still 0, while 16 MiB aborted as
// intended. That is also why this case looked like an environment-dependent
// flake — red for the July audit, green for the session after it, red again
// here. It never flaked. It is a threshold sitting ~4% under a host-dependent
// quantity, so it is deterministically red or green PER HOST.
//
// 64 MiB clears the worst case those sysctls allow (32 + 4 MiB) with room to
// spare. It is a SEPARATE constant from BIG_BYTES because making the healthy
// reader drain 64 MiB inside its own receive timeout made THAT case flaky —
// the two tests want opposite things from the size.
STALL_BYTES :: 64 * 1024 * 1024

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
}

@(private)
big_handler :: proc(ctx: ^web.Context) {
	// Content is irrelevant to a deadline test; zeroed bytes keep the handler
	// cheap so a loaded machine cannot turn allocation time into a flake.
	body := make([]u8, BIG_BYTES, context.temp_allocator)
	web.text(ctx, .OK, string(body))
}

@(private)
stall_handler :: proc(ctx: ^web.Context) {
	body := make([]u8, STALL_BYTES, context.temp_allocator)
	web.text(ctx, .OK, string(body))
}

@(private)
ok_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

@(private)
server_thread :: proc(s: ^Server) {
	web.serve(&s.app, s.port)
}

@(private)
start :: proc(s: ^Server, port: int, limits: web.Limits) -> bool {
	s^ = {}
	s.port = port
	s.app = web.app()
	web.get(&s.app, "/big", big_handler)
	web.get(&s.app, "/stall", stall_handler)
	web.get(&s.app, "/ok", ok_handler)
	web.limits(&s.app, limits)
	s.thread = thread.create_and_start_with_poly_data(s, server_thread)
	for _ in 0 ..< 300 {
		if status, _ := tiny_get(port, "/ok"); status == 200 {
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
		if err == nil {
			return sock, true
		}
		time.sleep(2 * time.Millisecond)
	}
	return {}, false
}

@(private)
tiny_get :: proc(port: int, path: string) -> (status: int, total: int) {
	sock, ok := dial(port)
	if !ok {return 0, 0}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 3 * time.Second)
	request, _ := strings.concatenate(
		{"GET ", path, " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"},
		context.temp_allocator,
	)
	if _, err := net.send_tcp(sock, transmute([]u8)request); err != nil {
		return 0, 0
	}
	buffer: [8192]u8
	first := true
	for {
		n, err := net.recv_tcp(sock, buffer[:])
		if n > 0 {
			if first && n >= 12 {
				status = int(buffer[9] - '0') * 100 + int(buffer[10] - '0') * 10 + int(buffer[11] - '0')
				first = false
			}
			total += n
		}
		if n == 0 || err != nil {break}
	}
	return status, total
}

// A slow reader: sends the request, shrinks its receive window, then stalls.
// Returns what happened after the stall: how long until the server acted, how
// many bytes ever arrived, and whether the connection was terminated
// (reset or EOF) rather than still delivering.
@(private)
stalled_read :: proc(
	port: int,
	stall: time.Duration,
	recv_after: time.Duration,
) -> (terminated: bool, acted_in: time.Duration, total: int) {
	sock, ok := dial(port)
	if !ok {return false, 0, 0}
	defer net.close(sock)
	// A tiny receive buffer makes the kernel's flow control stall the server's
	// send almost immediately. It is NOT sufficient on its own: the sender's own
	// send buffer still absorbs megabytes, which is why STALL_BYTES has to clear
	// the PAIR.
	net.set_option(sock, .Receive_Buffer_Size, 1024)
	request := "GET /stall HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	if _, err := net.send_tcp(sock, transmute([]u8)string(request)); err != nil {
		return false, 0, 0
	}
	// Read one small chunk so the response demonstrably started… (generous
	// timeout: this wait races nothing — it only absorbs machine load)
	buffer: [512]u8
	net.set_option(sock, .Receive_Timeout, 10 * time.Second)
	n, first_err := net.recv_tcp(sock, buffer[:])
	if first_err != nil || n == 0 {return false, 0, 0}
	total += n
	// …then stall completely for the requested time.
	time.sleep(stall)
	// Now try to keep reading. If the server aborted at its deadline, this
	// ends quickly in a reset or EOF; if not, bytes keep flowing.
	net.set_option(sock, .Receive_Timeout, recv_after)
	began := time.now()
	for {
		m, err := net.recv_tcp(sock, buffer[:])
		if m > 0 {
			total += m
			// STALL_BYTES, not BIG_BYTES: this reader is draining the stall
			// route. Comparing against the smaller constant would report "full
			// body, never terminated" after 8 MiB of a 64 MiB response — the
			// exact wrong reading, and a green-to-red flip for the wrong reason.
			if total >= STALL_BYTES {
				return false, time.since(began), total // full body: never terminated
			}
			continue
		}
		// EOF or error: the connection is over. Whether this is a reset
		// (write-deadline abort) or a timeout on our own receive decides
		// `terminated`.
		if err != nil {
			timeout := err == net.TCP_Recv_Error.Timeout
			return !timeout, time.since(began), total
		}
		return true, time.since(began), total
	}
}

// --- the write deadline ------------------------------------------------------

@(test)
wp90_a_stalled_write_is_aborted_at_the_deadline :: proc(t: ^testing.T) {
	s: Server
	limits := web.DEFAULT_LIMITS
	limits.max_write_time = i64(300 * time.Millisecond)
	limits.max_request_time = 0
	testing.expect(t, start(&s, 51910, limits), "server must start")
	defer stop(&s)

	// Stall past deadline (300ms) + sweep granularity (250ms) + margin.
	aborts_before := web.stats().write_deadline_aborts
	terminated, acted_in, total := stalled_read(51910, 900 * time.Millisecond, 3 * time.Second)
	aborts_after := web.stats().write_deadline_aborts

	// THE DIRECT EVIDENCE, asserted first because it is the one that names the
	// mechanism. The client-side observations below say the connection ended
	// early; only this says the WRITE DEADLINE ended it, rather than a reset,
	// a drain, or the body simply running out. When this suite failed for
	// buffer-sizing reasons the counter read 0, which is what identified the
	// cause — the byte-count assertions alone could not tell "the deadline did
	// not fire" from "the deadline fired late".
	testing.expectf(
		t,
		aborts_after > aborts_before,
		"web.stats().write_deadline_aborts did not move (%d -> %d): the stalled send was never aborted by the deadline. If the client received the whole body, STALL_BYTES no longer exceeds this host's socket buffer pair and the send never stalled at all.",
		aborts_before,
		aborts_after,
	)
	testing.expect(t, terminated, "a stalled response must be terminated by the write deadline, observably")
	testing.expectf(
		t,
		total < STALL_BYTES,
		"the aborted response delivered the FULL body (%d of %d bytes): the send completed, so nothing was stalled for the deadline to abort",
		total,
		STALL_BYTES,
	)
	testing.expect(t, acted_in < 2 * time.Second, "the abort must be visible promptly after the stall, not after megabytes drain")
}

@(test)
wp90_a_healthy_reader_is_untouched_by_the_write_deadline :: proc(t: ^testing.T) {
	s: Server
	limits := web.DEFAULT_LIMITS
	limits.max_write_time = i64(300 * time.Millisecond)
	testing.expect(t, start(&s, 51911, limits), "server must start")
	defer stop(&s)
	status, total := tiny_get(51911, "/big")
	testing.expect_value(t, status, 200)
	testing.expect(t, total > BIG_BYTES, "a fast reader receives the entire body, headers included")
}

@(test)
wp90_zero_write_deadline_keeps_upstream_behaviour :: proc(t: ^testing.T) {
	s: Server
	limits := web.DEFAULT_LIMITS
	limits.max_write_time = 0
	limits.max_request_time = 0
	testing.expect(t, start(&s, 51912, limits), "server must start")
	defer stop(&s)
	// Stall well past where the deadline WOULD have fired; the connection must
	// still be delivering bytes afterwards.
	terminated, _, total := stalled_read(51912, 900 * time.Millisecond, 500 * time.Millisecond)
	testing.expect(t, !terminated, "with the deadline off, a slow reader is never aborted (the shipped default)")
	testing.expect(t, total > 0)
}

// --- the idle keep-alive timeout ---------------------------------------------

@(private)
open_keepalive :: proc(port: int) -> (net.TCP_Socket, bool) {
	sock, ok := dial(port)
	if !ok {return {}, false}
	net.set_option(sock, .Receive_Timeout, 2 * time.Second)
	request := "GET /ok HTTP/1.1\r\nHost: localhost\r\n\r\n"
	if _, err := net.send_tcp(sock, transmute([]u8)string(request)); err != nil {
		net.close(sock)
		return {}, false
	}
	buffer: [1024]u8
	seen := 0
	for {
		n, err := net.recv_tcp(sock, buffer[:])
		if n > 0 {
			seen += n
			if strings.contains(string(buffer[:n]), "ok") {
				return sock, true
			}
		}
		if n == 0 || err != nil {
			net.close(sock)
			return {}, false
		}
	}
}

@(test)
wp90_an_idle_keepalive_is_closed_at_the_idle_deadline :: proc(t: ^testing.T) {
	s: Server
	limits := web.DEFAULT_LIMITS
	limits.max_idle_time = i64(300 * time.Millisecond)
	limits.max_request_time = 0
	testing.expect(t, start(&s, 51913, limits), "server must start")
	defer stop(&s)

	sock, ok := open_keepalive(51913)
	testing.expect(t, ok, "the first request must complete and keep the connection open")
	defer net.close(sock)
	// Sit idle past deadline + sweep granularity; the server closes gracefully,
	// so the client observes EOF.
	net.set_option(sock, .Receive_Timeout, 3 * time.Second)
	began := time.now()
	buffer: [256]u8
	n, err := net.recv_tcp(sock, buffer[:])
	closed := n == 0 || (err != nil && err != net.TCP_Recv_Error.Timeout)
	testing.expect(t, closed, "an idle keep-alive must be closed at the idle deadline")
	testing.expect(t, time.since(began) < 2 * time.Second, "the close must arrive near the deadline, not at the recv timeout")
}

@(test)
wp90_an_active_keepalive_is_not_idle :: proc(t: ^testing.T) {
	s: Server
	limits := web.DEFAULT_LIMITS
	limits.max_idle_time = i64(400 * time.Millisecond)
	limits.max_request_time = 0
	testing.expect(t, start(&s, 51914, limits), "server must start")
	defer stop(&s)

	sock, ok := open_keepalive(51914)
	testing.expect(t, ok)
	defer net.close(sock)
	// A second request WITHIN the idle window must be served normally — the
	// idle stamp is cleared the moment request bytes arrive.
	request := "GET /ok HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	_, send_err := net.send_tcp(sock, transmute([]u8)string(request))
	testing.expect(t, send_err == nil)
	buffer: [1024]u8
	n, recv_err := net.recv_tcp(sock, buffer[:])
	testing.expect(t, recv_err == nil && n > 12, "the second request on the keep-alive must be answered")
	testing.expect(t, string(buffer[9:12]) == "200", "and answered 200")
}

@(test)
wp90_zero_idle_time_keeps_the_keepalive :: proc(t: ^testing.T) {
	s: Server
	limits := web.DEFAULT_LIMITS
	limits.max_idle_time = 0
	limits.max_request_time = 0
	testing.expect(t, start(&s, 51915, limits), "server must start")
	defer stop(&s)

	sock, ok := open_keepalive(51915)
	testing.expect(t, ok)
	defer net.close(sock)
	time.sleep(800 * time.Millisecond) // longer than any deadline used above
	request := "GET /ok HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	_, send_err := net.send_tcp(sock, transmute([]u8)string(request))
	testing.expect(t, send_err == nil)
	buffer: [1024]u8
	n, recv_err := net.recv_tcp(sock, buffer[:])
	testing.expect(t, recv_err == nil && n > 12, "with idle off, the connection survives the wait (the shipped default)")
	testing.expect(t, string(buffer[9:12]) == "200")
}

// --- the read deadline is unchanged ------------------------------------------

@(test)
wp90_the_request_read_deadline_still_fires :: proc(t: ^testing.T) {
	s: Server
	limits := web.DEFAULT_LIMITS
	limits.max_request_time = i64(300 * time.Millisecond)
	testing.expect(t, start(&s, 51916, limits), "server must start")
	defer stop(&s)

	sock, ok := dial(51916)
	testing.expect(t, ok)
	defer net.close(sock)
	// A partial request that never completes.
	partial := "GET /ok HTTP/1.1\r\nHost: loc"
	_, send_err := net.send_tcp(sock, transmute([]u8)string(partial))
	testing.expect(t, send_err == nil)
	net.set_option(sock, .Receive_Timeout, 3 * time.Second)
	began := time.now()
	buffer: [256]u8
	n, err := net.recv_tcp(sock, buffer[:])
	closed := n == 0 || (err != nil && err != net.TCP_Recv_Error.Timeout)
	testing.expect(t, closed, "a request that never finishes arriving is still closed (WP46 regression guard)")
	testing.expect(t, time.since(began) < 2 * time.Second)
}
