// C-03 — cells B4, B6, C5 and D8, D10: the disconnect and lifecycle blanks.
//
// These are the cells the grid (`planning/closure-fault-campaign.md`) found
// empty. Each is a state a client or a shutdown can produce that no existing
// suite drove, and each one is here because "it probably works" is the sentence
// that let the orphaned recv and the write deadline survive.
//
// ONE SERVER PER PROCESS. `web.serve` holds the WP43 `g_server`, so every test
// in this package starts and stops its own server SEQUENTIALLY; the gate runs
// this directory with `-define:ODIN_TEST_THREADS=1`. Under the parallel runner
// one test's `web.stop` would shut down another's server.
//
// The harness (`Server`, `start_server`, `dial`, `send_all`, `abort_close`) is
// shared with `rst_flood_test.odin`, which owns cell A10.
package test_c03_fault_campaign

import "core:fmt"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

// The slow handler's dwell: long enough to hold a lane across another client's
// whole request, short enough that a phase costs a fraction of a second.
SLOW_DWELL :: 300 * time.Millisecond

// How many clients race the contended lane in B4.
CONTENDERS :: 8

slow_handler :: proc(ctx: ^web.Context) {
	time.sleep(SLOW_DWELL)
	web.text(ctx, .OK, "slow")
}

BIG_BYTES :: 8 * 1024 * 1024

big_handler :: proc(ctx: ^web.Context) {
	body := make([]u8, BIG_BYTES, context.temp_allocator)
	web.text(ctx, .OK, string(body))
}

// --- shared client primitives for these cells --------------------------------

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

// abort_close closes with SO_LINGER {1, 0}: RST instead of FIN, unsent bytes
// discarded. What a hostile or crashed client does, and the cheapest disconnect
// to write — which is why the campaign uses it.
abort_close :: proc(sock: net.TCP_Socket) {
	lv := Linger_Value{1, 0}
	_ = set_linger(sock, lv)
	net.close(sock)
}

// Returns the status of a plain GET, 0 for "connected but no usable reply",
// -1 for "could not connect at all".
get_status :: proc(port: int, request: string, patience := 2 * time.Second) -> int {
	sock, ok := dial(port)
	if !ok {
		return -1
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, patience)
	_ = net.set_option(sock, .Send_Timeout, patience)
	if !send_all(sock, request) {
		return 0
	}
	reply: [512]u8
	n, err := net.recv_tcp(sock, reply[:])
	if err != nil || n < 12 {
		return 0
	}
	head := string(reply[:n])
	status := 0
	for i in 9 ..< 12 {
		c := head[i]
		if c < '0' || c > '9' {
			return 0
		}
		status = status * 10 + int(c - '0')
	}
	return status
}

PING_REQ :: "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
SLOW_REQ :: "GET /slow HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
BIG_REQ :: "GET /big HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"

// ---------------------------------------------------------------------------
// B4 — every Handler lane busy when a request arrives.
//
// THE TRIGGER IS F-C01-3'S SPIN, and that is worth stating because it explains
// why this test is written as a property rather than as a forced sequence.
// `dispatch_exchange` can only find `td.handler_active` already true if the
// event loop ticked while a handler was running on that lane — and the ONE
// place the loop ticks with a handler active is `handler_lane_enter`'s
// unbounded wait for the cancelled accept's completion (C-01 finding F-C01-3).
// The 503 refusal is therefore reachable only inside a narrow window, so
// forcing it deterministically would mean instrumenting the server, and an
// instrumented server is not the one that ships.
//
// What CAN be asserted without a forced sequence is the property that matters:
// under contention every answer is a well-formed 200 or a well-formed 503 —
// never a hang, never a truncated reply, never a crash — and the server serves
// normally afterwards. That is the F-002 fix's actual contract, and before this
// test it was held only by an ad-hoc validation recorded in a report.
// ---------------------------------------------------------------------------

Contender :: struct {
	port:   int,
	status: int,
}

g_contenders: []Contender
g_next: int

contender_thread :: proc() {
	i := sync.atomic_add(&g_next, 1)
	if i >= len(g_contenders) {
		return
	}
	c := &g_contenders[i]
	c.status = get_status(c.port, SLOW_REQ)
}

@(test)
c03_a_contended_lane_refuses_with_503_and_stays_alive :: proc(t: ^testing.T) {
	server: Server
	limits := base_limits()
	if !start_server(&server, limits) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	testing.expectf(
		t,
		get_status(server.port, PING_REQ) == 200,
		"positive control: a healthy request must be served before the contention starts",
	)

	contenders := make([]Contender, CONTENDERS)
	defer delete(contenders)
	for &c in contenders {
		c.port = server.port
	}
	g_contenders = contenders
	g_next = 0

	threads: [CONTENDERS]^thread.Thread
	for i in 0 ..< CONTENDERS {
		threads[i] = thread.create_and_start(contender_thread)
	}
	for i in 0 ..< CONTENDERS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}
	g_contenders = nil

	ok_count, refused_count, bad := 0, 0, 0
	for c in contenders {
		switch c.status {
		case 200:
			ok_count += 1
		case 503:
			refused_count += 1
		case:
			bad += 1
		}
	}
	fmt.printf(
		"[c03] B4 contended lane   200=%d 503=%d malformed_or_hung=%d (of %d)\n",
		ok_count,
		refused_count,
		bad,
		CONTENDERS,
	)

	after := get_status(server.port, PING_REQ)
	returned := stop_server(&server)

	testing.expect(t, returned, "the server must shut down after lane contention")
	// The contract: every answer is one of the two the design permits. A 0 here
	// is a hang or a truncated reply, a -1 is a refused connect, and either
	// would mean contention costs a client its request rather than costing it
	// a retry.
	testing.expectf(
		t,
		bad == 0,
		"%d of %d contended requests got neither 200 nor 503 — contention must cost a retry, never a request",
		bad,
		CONTENDERS,
	)
	testing.expectf(
		t,
		ok_count > 0,
		"no contended request succeeded at all; the lane is not serving, which makes the 503 count meaningless",
	)
	testing.expectf(
		t,
		after == 200,
		"the server did not serve a normal request after contention (got %d)",
		after,
	)
}

// ---------------------------------------------------------------------------
// B6 — the client disconnects WHILE the handler runs.
//
// This is the F-002 trigger's second half, and it is the regression test that
// report never got: the fix (refuse with 503 instead of deferring the dispatch
// through `next_tick`) was validated ad hoc, in an ASan build, twenty rounds by
// hand. A defect that reliably killed the process deserves a permanent cell.
// ---------------------------------------------------------------------------

@(test)
c03_a_disconnect_during_the_handler_does_not_outlive_the_request :: proc(t: ^testing.T) {
	server: Server
	if !start_server(&server, base_limits()) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	testing.expectf(
		t,
		get_status(server.port, PING_REQ) == 200,
		"positive control: a healthy request must be served first",
	)

	// Twenty rounds, matching the ad-hoc validation the F-002 report describes:
	// send a request that will occupy a lane, then RST while the handler is
	// still inside its dwell. Anything the request owns — the Exchange, the
	// req/res views, the inbound body — lives in the connection's temp arena,
	// which the close path frees.
	ROUNDS :: 20
	for round in 0 ..< ROUNDS {
		sock, ok := dial(server.port)
		if !ok {
			testing.expectf(t, false, "round %d: could not dial", round)
			break
		}
		if !send_all(sock, SLOW_REQ) {
			net.close(sock)
			continue
		}
		// Inside the handler's dwell, not after it.
		time.sleep(SLOW_DWELL / 3)
		abort_close(sock)
	}

	// The server must still be here, and still serving. A process that died
	// would fail this by never answering.
	time.sleep(2 * SLOW_DWELL)
	after := get_status(server.port, PING_REQ)
	returned := stop_server(&server)

	fmt.printf("[c03] B6 disconnect x%d    after=%d shutdown=%v\n", ROUNDS, after, returned)
	testing.expectf(
		t,
		after == 200,
		"the server stopped serving after %d mid-handler disconnects (got %d)",
		ROUNDS,
		after,
	)
	testing.expect(t, returned, "the server must still shut down after mid-handler disconnects")
}

// ---------------------------------------------------------------------------
// C5 — an error during `send`: the peer vanishes mid-write.
//
// The buffered write path answers a send error by marking the connection
// `Will_Close` and running `clean_request_loop`. Nothing drove that branch on a
// real socket: `wp90` proves the DEADLINE aborts a stalled write, which is a
// different thing — there the server decides, here the peer does.
// ---------------------------------------------------------------------------

@(test)
c03_a_send_error_retires_the_connection_without_a_second_write :: proc(t: ^testing.T) {
	server: Server
	if !start_server(&server, base_limits()) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	testing.expectf(
		t,
		get_status(server.port, PING_REQ) == 200,
		"positive control: a healthy request must be served first",
	)

	// Ask for 8 MiB — far past any socket buffer pair, so the send is genuinely
	// in flight — then reset the connection without reading a byte.
	ROUNDS :: 10
	for round in 0 ..< ROUNDS {
		sock, ok := dial(server.port)
		if !ok {
			testing.expectf(t, false, "round %d: could not dial", round)
			break
		}
		if !send_all(sock, BIG_REQ) {
			net.close(sock)
			continue
		}
		time.sleep(30 * time.Millisecond) // let the send get under way
		abort_close(sock)
	}

	time.sleep(200 * time.Millisecond)
	after := get_status(server.port, PING_REQ)
	returned := stop_server(&server)

	fmt.printf("[c03] C5 send error x%d    after=%d shutdown=%v\n", ROUNDS, after, returned)
	testing.expectf(
		t,
		after == 200,
		"the server stopped serving after %d mid-send resets (got %d)",
		ROUNDS,
		after,
	)
	testing.expect(t, returned, "the server must still shut down after mid-send resets")
}

// ---------------------------------------------------------------------------
// D8 — a deadline and the shutdown expiring together.
//
// Two independent teardown paths racing for one connection: the sweep's
// `connection_abort` (SO_LINGER 0, immediate close) and the drain's
// `connection_close` (cancel, shutdown(Send), delayed close). Both free through
// `connection_teardown`. The guard is `connection_set_state`/the
// `state >= .Closing` early return in each — this cell is what proves the guard
// rather than assuming it.
//
// The write deadline and the drain deadline are configured EQUAL and short, so
// the two paths land in the same window rather than in a chosen order.
// ---------------------------------------------------------------------------

@(test)
c03_a_deadline_expiring_with_the_drain_does_not_double_close :: proc(t: ^testing.T) {
	server: Server
	limits := base_limits()
	COINCIDENT :: i64(500 * time.Millisecond)
	limits.max_write_time = COINCIDENT
	limits.max_drain_time = COINCIDENT
	if !start_server(&server, limits) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	// Several non-reading clients, so the sweep has work to do at the moment
	// the drain starts.
	STALLED :: 4
	socks: [STALLED]net.TCP_Socket
	live: [STALLED]bool
	for i in 0 ..< STALLED {
		sock, ok := dial(server.port)
		live[i] = ok
		if ok {
			socks[i] = sock
			_ = send_all(sock, BIG_REQ)
		}
	}

	// Stop at the write deadline, not before it and not after: the sweep is
	// arming its aborts in the same window the drain is closing connections.
	time.sleep(time.Duration(COINCIDENT))
	started := time.now()
	web.stop(&server.app)
	returned := sync.sema_wait_with_timeout(&server.done, STOP_DEADLINE)
	elapsed := time.since(started)
	if returned {
		thread.join(server.thread)
		thread.destroy(server.thread)
		server.thread = nil
		web.destroy(&server.app)
	}
	for i in 0 ..< STALLED {
		if live[i] {
			net.close(socks[i])
		}
	}

	fmt.printf(
		"[c03] D8 deadline+drain   returned=%v elapsed=%v (both deadlines %v)\n",
		returned,
		elapsed,
		time.Duration(COINCIDENT),
	)
	testing.expect(
		t,
		returned,
		"a shutdown landing on the write deadline must still return — a double close would abort the process instead",
	)
}

// ---------------------------------------------------------------------------
// D10 — a stop after a FAILED listen.
//
// Probed during C-01 while chasing an unexplained startup segfault; it came
// back clean, which is exactly why it is written down here. A path known to be
// green is worth a permanent cell, because the next person to see a startup
// crash should not have to re-derive that this is not it.
// ---------------------------------------------------------------------------

@(test)
c03_a_stop_after_a_failed_bind_returns :: proc(t: ^testing.T) {
	// A foreign listener holds the port, so the server's own bind must lose.
	port := SQUATTER_PORT
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	squatter, lerr := net.listen_tcp(ep)
	if lerr != nil {
		testing.expectf(t, false, "the squatter could not bind %d: %v", port, lerr)
		return
	}
	defer net.close(squatter)

	server: Server
	server.port = port
	server.app = web.app()
	web.limits(&server.app, base_limits())
	web.get(&server.app, "/ping", ping_handler)
	server.thread = thread.create_and_start_with_poly_data(&server, serve_thread)
	started := sync.sema_wait_with_timeout(&server.ready, 10 * time.Second)
	testing.expect(t, started, "the failed-bind server thread must post ready")
	time.sleep(200 * time.Millisecond)

	returned := stop_server(&server)
	fmt.printf("[c03] D10 failed bind     shutdown=%v\n", returned)
	testing.expect(
		t,
		returned,
		"a stop after a failed listen must return; a serve that neither bound nor completed is a process that cannot be restarted",
	)
}
