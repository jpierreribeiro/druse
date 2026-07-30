// C-03 — the closed fault-injection campaign: shared harness.
//
// The grid is `planning/closure-fault-campaign.md`; each cell lives beside the
// finding it measures (`rst_flood_test.odin` owns A10, `disconnect_test.odin`
// owns B4/B6/C5/D8/D10). This file is only the plumbing they share.
//
// TWO RULES, both learned the hard way and both load-bearing:
//
//   * ONE SERVER PER PROCESS. `web.serve` holds the WP43 `g_server`, so every
//     test here starts and stops its own server SEQUENTIALLY and the gate runs
//     this directory with `-define:ODIN_TEST_THREADS=1`. Under the parallel
//     runner one test's `web.stop` shuts down another's server.
//   * NEVER `thread.join` A SERVER TO WAIT FOR ITS DRAIN. `join` cannot time
//     out, so a suite built on it can only hang when the thing it tests hangs.
//     Every stop waits on a semaphore posted after `web.serve` returns, with a
//     deadline (the WP58 harness rule).
package test_c03_fault_campaign

import "core:net"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"
import web "druse:web"

// Distinct from every port any other suite binds.
CANDIDATE_PORTS :: [?]int{55027, 55353, 55621, 55897}

// What a stop is given before it is called stuck. Generous rather than tight:
// the flood cell leaves tens of thousands of connections behind it, and a
// deadline that fails on a loaded box tells you about the box. It is still a
// DEADLINE — a stuck drain fails loudly instead of hanging the runner.
STOP_DEADLINE :: 10 * time.Second

// D10's squatter binds a port NO server in this package uses. Sharing one with
// CANDIDATE_PORTS made the cell fail with Address_In_Use whenever an earlier
// test's server was still holding it — a cascade that reports the wrong
// finding.
SQUATTER_PORT :: 55931

// SOL_SOCKET / SO_LINGER on Linux — the only gate-validated platform
// (production-service-bom.md §6). Raw values because the pinned `core:net`
// marshals `.Linger` as a `timeval` where the kernel expects `struct linger`,
// which is the same reason the vendored `connection_abort` sets it by hand.
SOL_SOCKET_ :: 1
SO_LINGER_ :: 13

Linger_Value :: struct {
	l_onoff:  i32,
	l_linger: i32,
}

set_linger :: proc(sock: net.TCP_Socket, lv: Linger_Value) -> linux.Errno {
	value := lv
	return linux.setsockopt_base(linux.Fd(i32(sock)), SOL_SOCKET_, SO_LINGER_, &value)
}

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
	// Posted AFTER `web.serve` returns: the only way to wait on a drain with a
	// deadline instead of forever.
	done:   sync.Sema,
}

ping_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

serve_thread :: proc(s: ^Server) {
	sync.post(&s.ready)
	web.serve(&s.app, s.port)
	sync.post(&s.done)
}

base_limits :: proc() -> web.Limits {
	l := web.DEFAULT_LIMITS
	// Short enough that a phase can afford to hit it. The default is ten
	// seconds, which is a bound worth having and not a bound worth waiting for.
	l.max_drain_time = i64(2 * time.Second)
	return l
}

start_server :: proc(s: ^Server, limits: web.Limits) -> bool {
	for candidate in CANDIDATE_PORTS {
		s.app = web.app()
		web.limits(&s.app, limits)
		web.get(&s.app, "/ping", ping_handler)
		web.get(&s.app, "/slow", slow_handler)
		web.get(&s.app, "/big", big_handler)
		s.port = candidate
		s.thread = thread.create_and_start_with_poly_data(s, serve_thread)
		// Bound the wait: a hung startup must fail loudly, not hang the runner.
		if !sync.sema_wait_with_timeout(&s.ready, 10 * time.Second) {
			thread.join(s.thread)
			thread.destroy(s.thread)
			s.thread = nil
			continue
		}
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

// stop_server returns whether the serve thread came back within the deadline,
// and frees only if it did — freeing behind a live thread turns a diagnostic
// into a second crash.
stop_server :: proc(s: ^Server) -> bool {
	if s.thread == nil {
		return true
	}
	web.stop(&s.app)
	returned := sync.sema_wait_with_timeout(&s.done, STOP_DEADLINE)
	if returned {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
		web.destroy(&s.app)
	}
	return returned
}

dial :: proc(port: int) -> (sock: net.TCP_Socket, ok: bool) {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	err: net.Network_Error
	sock, err = net.dial_tcp(ep)
	return sock, err == nil
}
