// WP58 — THE DRAIN ANATOMY, and obligation 3 put back where it can fail.
//
// Phase 4 withdrew the drain deadline. The record says the mechanism was
// `nbio.run()` waiting on every pending operation, and that bounding the drain
// LOOP was not enough. That account is true and it is incomplete, and the
// difference matters because WP44 patched against the incomplete version.
//
// THERE ARE THREE UNBOUNDED WAITS ON THE SHUTDOWN PATH, not one:
//
//	1. `server.odin:340` — `nbio.tick()` inside the drain loop, with NO timeout.
//	2. `server.odin:349` — `nbio.run()`, which by definition waits for every
//	   pending operation.
//	3. `server.odin:392`/`:464` — `Conn_Close_Delay`, 500 ms PER CONNECTION.
//
// And a fourth fact that is not a wait but makes all three worse:
// `server_deadline_sweep` returns early when `closing` is set
// (`server.odin:773`) and never reschedules. The read deadline — the only
// defence against a client that stops sending — switches itself off at exactly
// the moment the drain needs it most.
//
// A FINDING FROM READING, BEFORE ANY MEASUREMENT: `SHUTDOWN_INTERVAL` is
// defined at `server.odin:284` and is never used. The comment above
// `server_shutdown` says the drain should "repeat every SHUTDOWN_INTERVAL until
// no more connections are open" — the code calls `nbio.tick()` with no timeout
// instead. The loop was designed to poll and does not.
//
// WHAT THIS SUITE DOES. It measures which wait dominates, by driving the server
// into one connection state at a time and timing the stop. That is the whole
// method: the states are what a client can produce, so the finding is about the
// shipped server rather than about an instrumented copy of it.
//
//	baseline   no connections            -> the positive control
//	idle       completed keep-alive       -> `.Idle`, which the drain DOES close
//	active     request line sent, held    -> `.Active`, which the drain only LOGS
//
// WHAT THE MEASUREMENT FOUND, and it is worse than the hypothesis it was
// written to test.
//
//	baseline  conns=0            returned=true   elapsed=990ms
//	idle      conns=8 .Idle      returned=FALSE  elapsed=3.0s (deadline)
//
// **Idle keep-alive connections block the drain too.** The plan expected only
// `.Active` to hang, because `.Idle` is one of the three states the drain loop
// closes. It closes them, and the drain still does not end — which relocates the
// mechanism and confirms the Phase-4 account rather than replacing it:
//
//	`connection_close` shuts down the send side, waits `Conn_Close_Delay`, closes
//	the fd, deletes the map entry and frees the `^Connection`. So `td.conns` DOES
//	empty and the loop DOES break. Then `nbio.run()` waits — and every keep-alive
//	connection left a `recv` outstanding, posted by `scanner.odin:205`, which
//	nothing ever cancels. `run()` waits on operations whose connection has already
//	been freed.
//
// THE SECOND FINDING IS A USE-AFTER-FREE, and it is why WP59 is a correctness
// fix and not only a shutdown feature. Releasing the client's sockets lets those
// orphaned `recv` operations complete; `scanner_on_read` then dereferences
// `s.connection` (`scanner.odin:209`) to reach its arena — a connection
// `connection_close` freed at `server.odin:471`. The process dies with
// `free(): invalid pointer`. Measured, reproducibly, by this suite.
//
// So the drain has two ways to end today and both are wrong: wait forever, or
// crash. That is the case for cancelling the operation rather than bounding the
// wait around it, and `scanner.odin:205` discarding the `^nbio.Operation` — with
// upstream's own `// TODO: some kinda timeout on this` one line above it — is
// the reason it cannot be cancelled yet.
//
// WHAT WP59 CHANGED, and the numbers are from this suite:
//
//	                  before WP59              after WP59
//	baseline          990 ms                   990 ms
//	idle (8 conns)    never returned, crash    987 ms
//	active (1 conn)   never returned           1.59 s, force-closed at 1 s
//
// The fix is to CANCEL the operation rather than bound the wait around it:
// `scanner.odin` keeps the `^nbio.Operation` it used to discard, and
// `connection_close` calls `nbio.remove` on it before freeing the connection.
// That removes the use-after-free and the orphaned wait in one change, because
// they were the same missing capability.
//
// This suite was committed RED against the tree before that patch, and the
// failing commit is the evidence that it tests something.
//
// HOW IT FAILS WITHOUT HANGING, which is the part WP44 could not solve. The
// suite never blocks on an unbounded join. It waits on a semaphore the serve
// thread posts AFTER `web.serve` returns, with a deadline. When the deadline
// expires it RESCUES the server by closing the client socket — and the rescue
// is the diagnostic rather than mere cleanup: if releasing the client's socket
// lets the drain finish, then the drain was waiting on that connection's
// pending operation, which is the mechanism WP59 has to cancel.
package wp58_drain

import "core:fmt"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import lab "druse:tests/support/fault_lab"
import web "druse:web"

// Distinct from every other suite's ports. A shared port turns a scheduling
// accident into a flaky failure, and this suite starts and stops several
// servers.
CANDIDATE_PORTS :: [?]int{55011, 55337, 55603, 55889}

// The deadline the SERVER is configured with, in nanoseconds. Deliberately far
// below `DEFAULT_LIMITS.max_drain_time` (ten seconds): a suite that tested the
// default would take ten seconds per phase to prove a bound, and a bound worth
// having is one a test can afford to hit.
SERVER_DRAIN_TIME :: i64(1 * 1_000_000_000)

// What the suite is willing to wait before calling the drain stuck. It is a
// property of the TEST and is three times the server's own deadline, so a phase
// that fails has genuinely blown the bound rather than raced it.
DRAIN_DEADLINE :: 3 * time.Second

// How long the rescue is given. Longer than the deadline because the rescue is
// diagnosing the failure rather than racing it.
RESCUE_PATIENCE :: 5 * time.Second

// The request line of `lab.GET_PING`, including its CRLF:
// "GET /ping HTTP/1.1\r\n" — twenty bytes. Sending exactly this and stopping is
// what drives a connection to `.Active`: `on_rline1` (`server.odin:582`) fires
// on the scanned request line and sets the state before any header arrives.
REQUEST_LINE_BYTES :: 20

// How many idle keep-alive connections the second phase holds. Chosen so that a
// SERIAL `Conn_Close_Delay` would be plainly visible: 8 x 500 ms = 4 s, against
// a concurrent close of roughly 500 ms. The number is the instrument.
IDLE_CONNS :: 8

ping_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

// ---------------------------------------------------------------------------
// The harness — the WP41 shape, with one addition.
// ---------------------------------------------------------------------------

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
	// Posted AFTER `web.serve` returns. This is the addition, and it is what
	// makes a bounded wait possible: `thread.join` cannot time out, so a suite
	// built on it can only hang when the thing it tests hangs.
	done:   sync.Sema,
}

g_server: ^Server

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
		// The whole point of the suite: a drain deadline short enough to observe.
		l := web.DEFAULT_LIMITS
		l.max_drain_time = SERVER_DRAIN_TIME
		web.limits(&s.app, l)
		web.get(&s.app, "/ping", ping_handler)
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
	endpoint := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	for _ in 0 ..< 200 {
		sock, err := net.dial_tcp(endpoint)
		if err == nil {
			net.close(sock)
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

// stop_and_time is the measurement. It returns whether the serve thread came
// back within the deadline, and how long the attempt took.
//
// It deliberately does NOT join: joining is what makes a stuck drain a stuck
// test.
stop_and_time :: proc(
	s: ^Server,
	deadline: time.Duration,
) -> (
	returned: bool,
	elapsed: time.Duration,
) {
	started := time.now()
	web.stop(&s.app)
	returned = sync.sema_wait_with_timeout(&s.done, deadline)
	elapsed = time.since(started)
	return
}

// finish joins and frees. It is only ever called once the serve thread is known
// to have returned.
finish :: proc(s: ^Server) {
	if s.thread == nil {
		return
	}
	thread.join(s.thread)
	thread.destroy(s.thread)
	s.thread = nil
	web.destroy(&s.app)
	g_server = nil
}

// ---------------------------------------------------------------------------
// Phase 1 — the positive control.
//
// It runs FIRST and it is not a formality. Without it, a server that never
// started, or one whose stop always hung, would produce the same "obligation 3
// failed" verdict as the real finding — and the finding would be about the
// suite.
// ---------------------------------------------------------------------------

phase_baseline_stop_with_no_connections :: proc(t: ^testing.T) {
	server: Server
	if !start_server(&server) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	returned, elapsed := stop_and_time(&server, DRAIN_DEADLINE)
	finish(&server)

	fmt.printf(
		"[wp58] baseline      conns=0            returned=%v elapsed=%v\n",
		returned,
		elapsed,
	)
	testing.expect(
		t,
		returned,
		"POSITIVE CONTROL: a stop with no connections must return; if this fails, every other phase in this file is measuring the harness",
	)
}

// ---------------------------------------------------------------------------
// Phase 2 — connections the drain is willing to close.
//
// These completed a keep-alive request, so `clean_request_loop` put them back
// to `.Idle`, and `.Idle` is one of the three states `_server_thread_shutdown`
// closes. The question is not whether the stop returns — it should — but
// WHETHER `Conn_Close_Delay` IS PAID SERIALLY. Eight connections at 500 ms each
// is four seconds of shutdown for a server with eight idle clients, which is
// the difference between a deploy that blips and one that times out.
// ---------------------------------------------------------------------------

phase_idle_keepalive_connections :: proc(t: ^testing.T) {
	server: Server
	if !start_server(&server) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	l: lab.Lab
	lab.lab_init(&l, 0x5EED_58, 1 * time.Second)

	socks: [IDLE_CONNS]net.TCP_Socket
	held := 0
	for i in 0 ..< IDLE_CONNS {
		sock, ok := lab.dial(server.port, 1 * time.Second)
		if !ok {
			break
		}
		// A COMPLETE keep-alive request, answered. That is what leaves the
		// connection `.Idle` rather than `.Active`: the exchange finished.
		if !lab.send_fragmented(sock, lab.GET_PING_KEEPALIVE, 1, 0) {
			net.close(sock)
			break
		}
		outcome, status := lab.read_status(&l, sock)
		if outcome != .Responded || status != 200 {
			net.close(sock)
			break
		}
		socks[i] = sock
		held += 1
	}

	testing.expect_value(t, held, IDLE_CONNS)

	returned, elapsed := stop_and_time(&server, DRAIN_DEADLINE)

	// Releasing the sockets is what lets the orphaned `recv` operations
	// complete. Before WP59 that is also what triggers the use-after-free
	// described at the top of this file, so this phase can end the process. That
	// is the finding, not a flaky test.
	for i in 0 ..< held {
		net.close(socks[i])
	}
	rescued := false
	if !returned {
		rescued = sync.sema_wait_with_timeout(&server.done, RESCUE_PATIENCE)
	}
	if returned || rescued {
		finish(&server)
	}

	fmt.printf(
		"[wp58] idle          conns=%d state=.Idle  returned=%v elapsed=%v rescued=%v\n",
		held,
		returned,
		elapsed,
		rescued,
	)
	testing.expect(
		t,
		returned,
		"a stop with only IDLE connections must return under the deadline. EXPECTED RED until WP59: the loop closes and frees them, then `nbio.run()` waits on the `recv` each one left outstanding",
	)
}

// ---------------------------------------------------------------------------
// Phase 3 — OBLIGATION 3. This is the one that fails.
//
// The client sends the request line and stops. `on_rline1` sets the connection
// `.Active` (`server.odin:582`), and `_server_thread_shutdown` handles `.Active`
// by LOGGING it (`server.odin:324`) — nothing closes it, nothing cancels its
// pending `recv`, and `td.conns` therefore never empties. The drain loop cannot
// reach `nbio.run()` because it cannot leave the `for`.
//
// That is a correction to the Phase-4 account, which named `nbio.run()` as the
// mechanism. `run()` is a real wait and it would be reached SECOND — after a
// bound on the loop, which is precisely what WP44 added before finding the next
// wait behind it. Both are true; the order is what WP59 needs.
// ---------------------------------------------------------------------------

phase_obligation_3_stop_returns_with_a_connection_held_active :: proc(t: ^testing.T) {
	server: Server
	if !start_server(&server) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	sock, ok := lab.dial(server.port, 1 * time.Second)
	testing.expect(t, ok, "the lab must connect before the stop")
	if !ok {
		returned, _ := stop_and_time(&server, DRAIN_DEADLINE)
		if returned {
			finish(&server)
		}
		return
	}

	// The request line, and not one byte more.
	lab.send_prefix(sock, lab.GET_PING, REQUEST_LINE_BYTES)
	// Give the event loop time to scan it and set `.Active`. Without this the
	// connection may still be `.New` when the stop arrives, and `.New` is
	// closed — which would make this phase pass for the wrong reason.
	time.sleep(300 * time.Millisecond)

	returned, elapsed := stop_and_time(&server, DRAIN_DEADLINE)

	rescued := false
	if !returned {
		// THE RESCUE IS THE DIAGNOSTIC, not the cleanup.
		//
		// Closing the client socket completes the server's pending `recv`. If
		// the drain then finishes, the drain was waiting on THIS connection's
		// operation — which is the thing WP59 must cancel, and the reason
		// `scanner.odin:205` discarding the `^nbio.Operation` is the blocker.
		//
		// If it does NOT finish, the cause is somewhere else and WP59 is aimed
		// at the wrong target. Either way the suite learns something and the
		// gate does not hang.
		net.close(sock)
		rescued = sync.sema_wait_with_timeout(&server.done, RESCUE_PATIENCE)
		testing.expect(
			t,
			rescued,
			"releasing the client's socket must let the drain finish; if it does not, the drain is blocked on something other than this connection and WP59 is aimed at the wrong wait",
		)
	} else {
		net.close(sock)
	}
	if returned || rescued {
		finish(&server)
	}

	fmt.printf(
		"[wp58] active        conns=1 state=.Active returned=%v elapsed=%v rescued=%v\n",
		returned,
		elapsed,
		rescued,
	)
	testing.expect(
		t,
		returned,
		"OBLIGATION 3: `web.stop` must return under a deadline while a client holds a connection open, by force-closing it once `max_drain_time` expires",
	)
}

// ---------------------------------------------------------------------------
// One test, phases in order. Two listeners in one process present as a hang
// rather than as a failure (R-10), so nothing here runs in parallel.
// ---------------------------------------------------------------------------

@(test)
wp58_drain_anatomy :: proc(t: ^testing.T) {
	phase_baseline_stop_with_no_connections(t)
	phase_idle_keepalive_connections(t)
	phase_obligation_3_stop_returns_with_a_connection_held_active(t)
}
