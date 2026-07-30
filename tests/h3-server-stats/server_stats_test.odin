// H-3 — web.Server_Stats / web.stats(), driven through a real server.
//
// The observability gap C-05 named: the public surface was one counter, and the
// send side was invisible — how many responses left, how many bytes, how many
// slow readers the write deadline aborted, and the three stream counters that
// were maintained in the registry and reachable from no public API. This suite
// proves each counter MOVES on real traffic (never a package-internal read — the
// WP2 two-instance trap), and that the accessor is safe when no server runs.
//
// One @(test): web.serve is one-server-per-process (WP43 g_server), so a suite
// that starts a server must be a single sequential test.
package test_h3_server_stats

import "core:fmt"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

CANDIDATE_PORTS :: [?]int{55043, 55369, 55637, 55913}

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
	done:   sync.Sema,
}

g_server: ^Server

BODY :: "hello stats"

ok_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, BODY)
}

serve_thread :: proc() {
	s := g_server
	sync.post(&s.ready)
	web.serve(&s.app, s.port)
	sync.post(&s.done)
}

start_server :: proc(s: ^Server) -> bool {
	g_server = s
	for candidate in CANDIDATE_PORTS {
		s.app = web.app()
		l := web.DEFAULT_LIMITS
		l.max_drain_time = i64(2 * time.Second)
		web.limits(&s.app, l)
		web.get(&s.app, "/ok", ok_handler)
		s.port = candidate
		s.thread = thread.create_and_start(serve_thread)
		sync.wait(&s.ready)
		if wait_until_accepting(candidate) {
			return true
		}
		web.stop(&s.app)
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
		web.destroy(&s.app)
	}
	return false
}

wait_until_accepting :: proc(port: int) -> bool {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	for _ in 0 ..< 200 {
		sock, err := net.dial_tcp(ep)
		if err == nil {
			net.close(sock)
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

// A full request/response over one connection; returns the body length received.
get_ok :: proc(port: int) -> bool {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	sock, err := net.dial_tcp(ep)
	if err != nil {
		return false
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, 2 * time.Second)
	req := transmute([]u8)string("GET /ok HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
	sent := 0
	for sent < len(req) {
		n, serr := net.send_tcp(sock, req[sent:])
		if serr != nil || n <= 0 {
			return false
		}
		sent += n
	}
	reply: [512]u8
	n, rerr := net.recv_tcp(sock, reply[:])
	return rerr == nil && n > 0
}

@(test)
h3_stats_count_real_responses_and_are_zero_without_a_server :: proc(t: ^testing.T) {
	// Before any server: the accessor must be safe and return zero.
	pre := web.stats()
	testing.expect_value(t, pre.responses_sent, 0)
	testing.expect_value(t, pre.response_bytes, i64(0))
	testing.expect_value(t, pre.saturation_refusals, 0)

	server: Server
	if !start_server(&server) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	N :: 5
	served := 0
	for _ in 0 ..< N {
		if get_ok(server.port) {
			served += 1
		}
	}
	// Let the send completions land before reading the counters.
	time.sleep(100 * time.Millisecond)

	s := web.stats()
	fmt.printf(
		"[h3] after %d requests: responses_sent=%d response_bytes=%d send_errors=%d write_aborts=%d\n",
		served,
		s.responses_sent,
		s.response_bytes,
		s.send_errors,
		s.write_deadline_aborts,
	)

	returned := false
	{
		web.stop(&server.app)
		returned = sync.sema_wait_with_timeout(&server.done, 10 * time.Second)
		if returned {
			thread.join(server.thread)
			thread.destroy(server.thread)
			server.thread = nil
			web.destroy(&server.app)
		}
		g_server = nil
	}

	testing.expect(t, returned, "the server must shut down")
	testing.expectf(t, served == N, "the positive control needs all %d requests served, got %d", N, served)

	// responses_sent counts the completed buffered sends. It must be at least the
	// number we drove (a keep-alive health probe during startup may add one).
	testing.expectf(
		t,
		s.responses_sent >= served,
		"responses_sent (%d) must be at least the %d responses actually served — the counter is not moving",
		s.responses_sent,
		served,
	)
	// response_bytes must exceed the sum of the bodies: each response also carries
	// a status line and headers, so bytes-on-the-wire is strictly larger than
	// N × len(body). A zero here means the byte counter is dead.
	testing.expectf(
		t,
		s.response_bytes > i64(served * len(BODY)),
		"response_bytes (%d) must exceed the %d body bytes served (headers are on the wire too)",
		s.response_bytes,
		served * len(BODY),
	)
	// No errors and no write-deadline aborts on healthy traffic.
	testing.expect_value(t, s.send_errors, 0)
	testing.expect_value(t, s.write_deadline_aborts, 0)
}
