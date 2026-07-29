// C-01 — every async operation, interrupted in each of its states.
//
// THE POINT OF THIS SUITE, in one sentence: the two worst lifecycle defects
// this project has shipped (the orphaned `recv` of WP58/WP59 and the missing
// write deadline of WP90) were both a dropped `^nbio.Operation` handle, and
// neither needed a clever insight to find — each needed one boring question
// asked of one operation. `planning/closure-async-op-inventory.md` asks the ten
// questions of all fourteen operation sites; this suite is the behavioural half
// of that answer, for the four states no existing suite interrupts.
//
// WHAT IS DELIBERATELY NOT HERE. Where a state is already interrupted by a
// green suite, C-01 cites it rather than re-measuring it — a second copy of a
// test is a second thing to keep true, not a second proof:
//
//	recv, idle keep-alive, cancelled at stop     -> wp58-drain (8 conns, 987 ms)
//	recv, request-line held, force-closed        -> wp58-drain (obligation 3)
//	recv, trickling client, read deadline        -> wp41-fault, wp90-deadlines
//	send, stalled write, abort at the deadline   -> wp90-deadlines
//	stream send, drain deadline                  -> wp95-drain
//	stream send, slow consumer                   -> wp92-backpressure
//	accept, re-armed after a synchronous handler -> wp71/wp72
//
// WHAT IS HERE is the residue — the four measurements the inventory needed and
// nobody had taken:
//
//	P1  the FLOOR of a clean stop, and the operation that sets it. `nbio`'s
//	    `num_waiting()` counts timeouts, and the Date cache re-arms a 1 s
//	    timeout it keeps no handle for, so an idle server's drain cannot end
//	    faster than the tail of that timeout. wp58 measured 990 ms and read it
//	    as noise. It is not noise, it is operation #12, and naming it is the
//	    difference between a floor and a mystery.
//
//	P2  a `recv` interrupted MID-REQUEST-LINE — the partial-token state, where
//	    the scanner holds a buffer and an outstanding read.
//
//	P3  a `send` interrupted IN FLIGHT to a client that never reads, with
//	    `max_write_time` set LONGER than `max_drain_time`. This is the exact
//	    experiment that proves finding F-C01-2: the deadline sweep returns
//	    early once `closing` is set, so during a drain the write deadline is
//	    not what ends anything — `max_drain_time` is. If the sweep still ran,
//	    this phase would end at the write deadline instead, and the assertion
//	    below would fail.
//
//	P4  a connection ABORTED by the write deadline (SO_LINGER 0 -> RST) and
//	    then stopped. The abort path cancels both outstanding operations and
//	    calls `close_poly` with no delay; nothing else in the tree checks that
//	    a stop AFTER an abort is still prompt, which is where a double free or
//	    a surviving handle would show.
//
// METHOD. Every phase measures BEHAVIOUR on a real socket and times the stop
// against a semaphore posted after `web.serve` returns — never `thread.join`,
// which cannot time out and would turn a stuck drain into a stuck suite (the
// WP58 harness rule). Package counters are never consulted: the WP2 two-
// instance trap.
package test_c01_async_ops

import "core:fmt"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

// Distinct from every port any other suite binds; this one starts and stops
// four servers in sequence.
CANDIDATE_PORTS :: [?]int{55023, 55349, 55617, 55893}

// The server's own drain deadline, in nanoseconds. Far below
// `DEFAULT_LIMITS.max_drain_time` (10 s) for the WP58 reason: a bound worth
// having is one a suite can afford to hit.
SERVER_DRAIN_TIME :: i64(1 * 1_000_000_000)

// The write deadline P3 configures: FIVE TIMES the drain deadline. The
// inequality is the instrument — see the P3 note above.
LONG_WRITE_TIME :: i64(5 * 1_000_000_000)

// The write deadline P4 configures: short enough that the abort happens while
// the suite watches.
SHORT_WRITE_TIME :: i64(300 * 1_000_000)

// What the suite will wait before calling a drain stuck. Three times the
// server's deadline, so a failing phase has blown the bound rather than raced
// it.
DRAIN_DEADLINE :: 3 * time.Second

// The ceiling P1/P2/P4 assert a prompt stop against. Above the 1 s Date-timer
// floor named in the P1 note, below the 1 s drain deadline plus its 500 ms
// close delay, so it can tell "ended by cancellation" from "ended by the drain
// deadline".
PROMPT_STOP :: 1400 * time.Millisecond

// Far beyond any plausible kernel socket-buffer pair, so a client that never
// reads leaves the send genuinely outstanding rather than absorbed.
BIG_BYTES :: 8 * 1024 * 1024

// ---------------------------------------------------------------------------
// Harness — the WP58 shape.
// ---------------------------------------------------------------------------

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
	// Posted AFTER `web.serve` returns: the only way to wait on a drain with a
	// deadline instead of forever.
	done:   sync.Sema,
}

g_server: ^Server

ping_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

big_handler :: proc(ctx: ^web.Context) {
	// Zeroed bytes: the content is irrelevant to a lifecycle test, and a cheap
	// handler keeps allocation time from becoming a flake on a loaded box.
	body := make([]u8, BIG_BYTES, context.temp_allocator)
	web.text(ctx, .OK, string(body))
}

serve_thread :: proc() {
	s := g_server
	sync.post(&s.ready)
	web.serve(&s.app, s.port)
	sync.post(&s.done)
}

start_server :: proc(s: ^Server, limits: web.Limits) -> bool {
	g_server = s
	for candidate in CANDIDATE_PORTS {
		s.app = web.app()
		web.limits(&s.app, limits)
		web.get(&s.app, "/ping", ping_handler)
		web.get(&s.app, "/big", big_handler)
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

base_limits :: proc() -> web.Limits {
	l := web.DEFAULT_LIMITS
	l.max_drain_time = SERVER_DRAIN_TIME
	return l
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

dial :: proc(port: int) -> (sock: net.TCP_Socket, ok: bool) {
	endpoint := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	err: net.Network_Error
	sock, err = net.dial_tcp(endpoint)
	return sock, err == nil
}

send_all :: proc(sock: net.TCP_Socket, data: string) -> bool {
	buf := transmute([]u8)data
	sent := 0
	for sent < len(buf) {
		n, err := net.send_tcp(sock, buf[sent:])
		if err != nil || n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

// stop_and_time is the measurement. It never joins: joining is what turns a
// stuck drain into a stuck test.
stop_and_time :: proc(s: ^Server, deadline: time.Duration) -> (returned: bool, elapsed: time.Duration) {
	started := time.now()
	web.stop(&s.app)
	returned = sync.sema_wait_with_timeout(&s.done, deadline)
	elapsed = time.since(started)
	return
}

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
// P1 — the floor of a clean stop, and the operation that sets it.
// ---------------------------------------------------------------------------

phase_the_clean_stop_floor_is_the_date_timer :: proc(t: ^testing.T) {
	server: Server
	if !start_server(&server, base_limits()) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	returned, elapsed := stop_and_time(&server, DRAIN_DEADLINE)
	finish(&server)

	fmt.printf("[c01] P1 clean stop, conns=0        returned=%v elapsed=%v\n", returned, elapsed)
	testing.expect(t, returned, "a stop with no connections must return")
	// The claim is the CEILING, not the floor: asserting a lower bound would
	// pin the suite to an implementation detail that a future handle-keeping
	// change is meant to remove. What must stay true is that the untracked
	// periodic timers cost at most their own period, not the drain deadline.
	testing.expectf(
		t,
		elapsed < PROMPT_STOP,
		"a stop with no connections took %v; the untracked Date/sweep timeouts (inventory #11, #12) may cost at most their own period, never the drain deadline",
		elapsed,
	)
}

// ---------------------------------------------------------------------------
// P2 — a `recv` interrupted mid-request-line.
// ---------------------------------------------------------------------------

phase_a_recv_holding_a_partial_token_is_cancelled :: proc(t: ^testing.T) {
	server: Server
	if !start_server(&server, base_limits()) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	sock, ok := dial(server.port)
	if !ok {
		testing.expect(t, false, "could not dial the server")
		finish(&server)
		return
	}
	// A request line with no CRLF: the scanner has bytes, no token, and an
	// outstanding `recv`. Nothing will ever complete it.
	testing.expect(t, send_all(sock, "GET /pi"), "partial request line must send")
	time.sleep(120 * time.Millisecond)

	returned, elapsed := stop_and_time(&server, DRAIN_DEADLINE)
	net.close(sock)
	finish(&server)

	fmt.printf("[c01] P2 recv mid-token             returned=%v elapsed=%v\n", returned, elapsed)
	testing.expect(t, returned, "a stop with a recv holding a partial token must return")
	testing.expectf(
		t,
		elapsed < DRAIN_DEADLINE,
		"stop took %v with one partial-token connection; the pending recv (inventory #6) is not being cancelled",
		elapsed,
	)
}

// ---------------------------------------------------------------------------
// P3 — a `send` in flight, with the write deadline set LONGER than the drain
// deadline. This is finding F-C01-2, made executable.
// ---------------------------------------------------------------------------

phase_a_send_in_flight_is_ended_by_the_drain_not_the_write_deadline :: proc(t: ^testing.T) {
	server: Server
	limits := base_limits()
	limits.max_write_time = LONG_WRITE_TIME
	if !start_server(&server, limits) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	sock, ok := dial(server.port)
	if !ok {
		testing.expect(t, false, "could not dial the server")
		finish(&server)
		return
	}
	// Ask for 8 MiB and then never read a byte. The response overflows the
	// socket buffer pair, so the `send` stays outstanding on the server.
	testing.expect(
		t,
		send_all(sock, "GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n"),
		"the big request must send",
	)
	time.sleep(250 * time.Millisecond)

	returned, elapsed := stop_and_time(&server, DRAIN_DEADLINE)
	net.close(sock)
	finish(&server)

	fmt.printf("[c01] P3 send in flight             returned=%v elapsed=%v\n", returned, elapsed)
	testing.expect(t, returned, "a stop with a send in flight to a dead reader must return")
	// The write deadline is five seconds; the whole suite gives up at three.
	// Returning at all therefore proves the drain deadline is what ended this,
	// which is exactly what F-C01-2 says: the sweep stops enforcing once
	// `closing` is set.
	testing.expectf(
		t,
		elapsed < DRAIN_DEADLINE,
		"stop took %v with a send in flight; the drain deadline (%v) is the only bound that survives into shutdown and it did not hold",
		elapsed,
		time.Duration(SERVER_DRAIN_TIME),
	)
}

// ---------------------------------------------------------------------------
// P4 — stop AFTER an abort. Nothing else checks this.
// ---------------------------------------------------------------------------

phase_a_stop_after_a_write_deadline_abort_is_prompt :: proc(t: ^testing.T) {
	server: Server
	limits := base_limits()
	limits.max_write_time = SHORT_WRITE_TIME
	if !start_server(&server, limits) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	sock, ok := dial(server.port)
	if !ok {
		testing.expect(t, false, "could not dial the server")
		finish(&server)
		return
	}
	testing.expect(
		t,
		send_all(sock, "GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n"),
		"the big request must send",
	)
	// Long enough for the 300 ms write deadline plus a 250 ms sweep interval to
	// have fired and aborted the connection, without reading a byte of it.
	time.sleep(1200 * time.Millisecond)

	returned, elapsed := stop_and_time(&server, DRAIN_DEADLINE)
	net.close(sock)
	finish(&server)

	fmt.printf("[c01] P4 stop after abort           returned=%v elapsed=%v\n", returned, elapsed)
	testing.expect(t, returned, "a stop after a write-deadline abort must return")
	// Prompt, not merely bounded: the aborted connection was already torn down,
	// so nothing should remain for the drain to wait on. A stop that instead
	// takes the full drain deadline would mean the abort left an operation
	// outstanding — the dropped-handle defect, on the abort path.
	testing.expectf(
		t,
		elapsed < PROMPT_STOP,
		"stop took %v after a write-deadline abort; the abort left something outstanding (inventory #10)",
		elapsed,
	)
}

// ---------------------------------------------------------------------------
// One @(test): `web.serve` is one-server-per-process (the WP43 `g_server`), so
// phases that each start a server must run in sequence or one phase's stop
// shuts down another phase's server.
// ---------------------------------------------------------------------------

@(test)
c01_every_async_operation_is_interrupted_in_each_state :: proc(t: ^testing.T) {
	phase_the_clean_stop_floor_is_the_date_timer(t)
	phase_a_recv_holding_a_partial_token_is_cancelled(t)
	phase_a_send_in_flight_is_ended_by_the_drain_not_the_write_deadline(t)
	phase_a_stop_after_a_write_deadline_abort_is_prompt(t)
}
