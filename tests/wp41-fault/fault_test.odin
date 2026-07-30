// WP41 — the fault laboratory's suite. Real sockets, real server, seeded faults.
//
// The instrument is `tests/support/fault_lab`; this file drives it and holds it
// to the criterion the Phase-4 plan fixed BEFORE either was written:
//
//	replay the same seed and get the same trail, AND find at least one
//	mutation the current tests miss.
//
// **A lab that cannot demonstrate a missed mutation has not earned its
// complexity.** That is why `wp41_the_lab_finds_what_the_existing_tests_miss`
// is in this file and is not optional: without it, this package is an elaborate
// way of passing.
//
// WHAT IT FOUND, stated at the top because it is the point rather than a
// footnote: **a client that trickles a request one byte at a time, or sends a
// prefix and holds the socket open, is never disconnected.** The connection
// stays open until the LAB gives up. No existing test observes this, because
// every existing test sends a complete request. It is slowloris, it costs the
// attacker one socket and no bandwidth, and it is exactly the hole ADR-031
// exists to close.
package wp41_fault

import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import lab "druse:tests/support/fault_lab"
import web "druse:web"
import transport "druse:web/internal/transport"

// Distinct from the WP9 corpus's ports: these suites can run in one session and
// a shared port turns a scheduling accident into a flaky failure.
CANDIDATE_PORTS :: [?]int{53171, 53613, 54029, 54497}

// The seed. Fixed rather than drawn from the clock: a lab whose seed changes
// every run cannot be replayed, and "it failed on some seed" is not a bug
// report. A future soak (WP53) sweeps seeds; this suite pins one.
LAB_SEED :: u64(0x5EED_41_FA_17)

handler_hits: int

ping_handler :: proc(ctx: ^web.Context) {
	handler_hits += 1
	web.text(ctx, .OK, "pong")
}

// ---------------------------------------------------------------------------
// The server harness — the WP9 shape, reused rather than reinvented.
// ---------------------------------------------------------------------------

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
}

g_server: ^Server

serve_thread :: proc() {
	s := g_server
	sync.post(&s.ready)
	web.serve(&s.app, s.port)
}

start_server :: proc(s: ^Server) -> bool {
	g_server = s
	for candidate in CANDIDATE_PORTS {
		s.app = web.app()
		web.get(&s.app, "/ping", ping_handler)
		s.port = candidate
		s.thread = thread.create_and_start(serve_thread)
		sync.wait(&s.ready)

		if wait_until_accepting(candidate) {
			return true
		}

		transport.request_stop()
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
		web.destroy(&s.app)
	}
	return false
}

stop_server :: proc(s: ^Server) {
	if s.thread == nil {
		return
	}
	transport.request_stop()
	thread.join(s.thread)
	thread.destroy(s.thread)
	s.thread = nil
	web.destroy(&s.app)
	g_server = nil
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
		time.sleep(5 * time.Millisecond)
	}
	return false
}

// The framework's own Error-level lines are expected here — a fault lab
// provokes diagnostics on purpose — and the pinned runner treats any Error line
// as a failure. Swallow exactly `druse:` Error lines and forward the rest, or
// `testing.expect` cannot report (the WP17 control-6 lesson).
Log_Filter :: struct {
	inner: log.Logger,
}

filter_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	f := (^Log_Filter)(data)
	if level == .Error && strings.contains(text, "druse:") {
		return
	}
	if f.inner.procedure != nil {
		f.inner.procedure(f.inner.data, level, text, options, location)
	}
}

swallow_framework_log :: proc(f: ^Log_Filter) -> log.Logger {
	f.inner = context.logger
	return log.Logger {
		procedure = filter_proc,
		data = rawptr(f),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

// ---------------------------------------------------------------------------
// One step of the lab: pick a fault, apply it, record what happened.
// ---------------------------------------------------------------------------

run_one :: proc(l: ^lab.Lab, port: int) {
	fault := lab.next_fault(l)

	switch fault {
	case .Fragmented_Request:
		// 2..5 pieces. The split lands wherever the arithmetic puts it, which
		// is how a header boundary gets hit without anyone choosing it.
		chunks := 2 + lab.next_int(l, 4)
		sock, ok := lab.dial(port, l.patience)
		if !ok {
			lab.record(l, fault, chunks, .Connect_Refused, 0)
			return
		}
		defer net.close(sock)
		lab.send_fragmented(sock, lab.GET_PING, chunks, 2 * time.Millisecond)
		outcome, status := lab.read_status(l, sock)
		lab.record(l, fault, chunks, outcome, status)

	case .Slow_Writer:
		// One byte at a time, and deliberately STOPPING SHORT of the terminator
		// so the request never completes. This is the slowloris shape.
		limit := 8 + lab.next_int(l, 12)
		sock, ok := lab.dial(port, l.patience)
		if !ok {
			lab.record(l, fault, limit, .Connect_Refused, 0)
			return
		}
		defer net.close(sock)
		lab.send_trickle(sock, lab.GET_PING, time.Millisecond, limit)
		outcome, status := lab.read_status(l, sock)
		lab.record(l, fault, limit, outcome, status)

	case .Slow_Reader:
		// A complete request, then a pause before reading. The server has a
		// response to write and nobody taking it.
		pause := 10 + lab.next_int(l, 40)
		sock, ok := lab.dial(port, l.patience)
		if !ok {
			lab.record(l, fault, pause, .Connect_Refused, 0)
			return
		}
		defer net.close(sock)
		lab.send_fragmented(sock, lab.GET_PING, 1, 0)
		time.sleep(time.Duration(pause) * time.Millisecond)
		outcome, status := lab.read_status(l, sock)
		lab.record(l, fault, pause, outcome, status)

	case .Close_Mid_Request:
		// Half the bytes, then a close. The server is told the client is gone.
		cut := 4 + lab.next_int(l, len(lab.GET_PING) - 8)
		sock, ok := lab.dial(port, l.patience)
		if !ok {
			lab.record(l, fault, cut, .Connect_Refused, 0)
			return
		}
		lab.send_prefix(sock, lab.GET_PING, cut)
		net.close(sock)
		// Nothing to read: the socket is gone. The observation is that the
		// SERVER survived, which the next step's success demonstrates.
		lab.record(l, fault, cut, .Closed_Without_Response, 0)

	case .Truncate_And_Hold:
		// The same prefix, but the socket stays OPEN. The difference from
		// Close_Mid_Request is everything: one is a departure, the other is a
		// client that is still there and saying nothing.
		cut := 4 + lab.next_int(l, len(lab.GET_PING) - 8)
		sock, ok := lab.dial(port, l.patience)
		if !ok {
			lab.record(l, fault, cut, .Connect_Refused, 0)
			return
		}
		defer net.close(sock)
		lab.send_prefix(sock, lab.GET_PING, cut)
		outcome, status := lab.read_status(l, sock)
		lab.record(l, fault, cut, outcome, status)

	case .Close_Before_Response:
		sock, ok := lab.dial(port, l.patience)
		if !ok {
			lab.record(l, fault, 0, .Connect_Refused, 0)
			return
		}
		lab.send_fragmented(sock, lab.GET_PING, 1, 0)
		net.close(sock)
		lab.record(l, fault, 0, .Closed_Without_Response, 0)

	case .Sequential_Reuse:
		// 2..5 complete connections back to back. WP35 found no slot reuse; if
		// a later phase introduces some, this is where it starts to matter.
		rounds := 2 + lab.next_int(l, 4)
		last_outcome := Outcome_Placeholder
		last_status := 0
		for _ in 0 ..< rounds {
			sock, ok := lab.dial(port, l.patience)
			if !ok {
				last_outcome = .Connect_Refused
				break
			}
			lab.send_fragmented(sock, lab.GET_PING, 1, 0)
			o, st := lab.read_status(l, sock)
			net.close(sock)
			last_outcome = o
			last_status = st
		}
		lab.record(l, fault, rounds, last_outcome, last_status)

	case .Shutdown_Mid_Request:
		// Handled by its own test, not by the seeded loop: it ends the server,
		// so it cannot be one step among many. Recorded here as skipped so the
		// trail still accounts for the draw — a trail with holes in it is a
		// trail that cannot be compared.
		lab.record(l, fault, 0, .Responded, 0)
	}
}

// Odin needs the enum named for the local above; aliasing keeps the switch
// readable without importing the name into every line.
Outcome_Placeholder :: lab.Outcome.Responded

// ---------------------------------------------------------------------------
// 1. Determinism — the product.
// ---------------------------------------------------------------------------

// THE CRITERION, and it is checked before anything is claimed about faults: the
// same seed must produce the same trail. A lab whose trails wander cannot hand
// a failure to anyone, because "run it again" would be the whole bug report.
phase_determinism :: proc(t: ^testing.T, server: ^Server) {

	first: lab.Lab
	lab.lab_init(&first, LAB_SEED)
	for _ in 0 ..< 12 {
		run_one(&first, server.port)
	}

	second: lab.Lab
	lab.lab_init(&second, LAB_SEED)
	for _ in 0 ..< 12 {
		run_one(&second, server.port)
	}

	testing.expect_value(t, first.trail_len, 12)
	testing.expect(
		t,
		lab.trails_equal(&first, &second),
		"the same seed produced two different trails; a lab that cannot be replayed cannot hand a failure to anyone",
	)
}

// A DIFFERENT seed must produce a different trail, or the generator is a
// constant and the determinism test above is vacuous. This is the positive
// control for the check that precedes it.
@(test)
wp41_a_different_seed_explores_differently :: proc(t: ^testing.T) {
	a: lab.Lab
	b: lab.Lab
	lab.lab_init(&a, LAB_SEED)
	lab.lab_init(&b, LAB_SEED + 1)

	differed := false
	for _ in 0 ..< 40 {
		if lab.next_fault(&a) != lab.next_fault(&b) {
			differed = true
			break
		}
	}
	testing.expect(
		t,
		differed,
		"two seeds selected identical faults for 40 draws; the generator is effectively constant and the replay test proves nothing",
	)
}

// ---------------------------------------------------------------------------
// 2. THE FINDING — what the lab catches that the existing tests do not.
// ---------------------------------------------------------------------------

// **This is the test that earns the package.**
//
// The WP9 corpus sends malformed requests and asserts the connection is
// retired. Every one of its cases is a COMPLETE transmission: bytes arrive, the
// parser rejects them, the connection closes. None of them ever asks what
// happens when the bytes simply STOP.
//
// They stop here. The client sends a valid prefix and holds the socket open,
// saying nothing further. The result:
//
//	the server never responds, never closes, and holds the connection until
//	the LAB runs out of patience.
//
// One socket, no bandwidth, held indefinitely — and nothing in the framework
// counts it, bounds it, or ends it. This is the concrete evidence behind
// ADR-031, and it is the mutation the current tests miss.
//
// **The assertion is written to FAIL if the hole is ever closed**, which is
// deliberate and is why it carries the sentence it does: when a read deadline
// ships, this test must be amended in the same change, and its amendment is the
// proof that the deadline works.
phase_truncated_hold :: proc(t: ^testing.T, server: ^Server) {

	l: lab.Lab
	lab.lab_init(&l, LAB_SEED, 600 * time.Millisecond)

	sock, ok := lab.dial(server.port, l.patience)
	testing.expect(t, ok, "the lab must be able to connect")
	if !ok {
		return
	}
	defer net.close(sock)

	// A valid, incomplete request: the request line and one header, no
	// terminator. Nothing about it is malformed — it is simply unfinished.
	lab.send_prefix(sock, lab.GET_PING, 30)

	outcome, status := lab.read_status(&l, sock)

	testing.expect_value(t, status, 0)
	testing.expect_value(t, outcome, lab.Outcome.Held_Open_Until_Lab_Gave_Up)

	if outcome != .Held_Open_Until_Lab_Gave_Up {
		log.warnf(
			"WP41: the truncated-request connection was NOT held open (outcome %v). If a read deadline has shipped, this test has done its job and must be amended in the same change that shipped it — see ADR-031.",
			outcome,
		)
	}
}

// The same hole from the other direction: a client that trickles bytes forever
// is never disconnected either. Separated from the test above because the
// mechanisms differ — one is silence, the other is progress too slow to matter
// — and a single deadline may fix one without fixing the other.
phase_trickle :: proc(t: ^testing.T, server: ^Server) {

	l: lab.Lab
	lab.lab_init(&l, LAB_SEED, 500 * time.Millisecond)

	sock, ok := lab.dial(server.port, l.patience)
	testing.expect(t, ok, "the lab must be able to connect")
	if !ok {
		return
	}
	defer net.close(sock)

	// Twenty bytes, one every 5 ms, never reaching the terminator.
	lab.send_trickle(sock, lab.GET_PING, 5 * time.Millisecond, 20)

	outcome, _ := lab.read_status(&l, sock)
	testing.expect_value(t, outcome, lab.Outcome.Held_Open_Until_Lab_Gave_Up)
}

// ---------------------------------------------------------------------------
// 3. The positive control — the lab is not simply reporting failure everywhere.
// ---------------------------------------------------------------------------

// Without this, every assertion above would pass against a server that answered
// nothing at all. A complete request must still be answered normally, through
// the same lab machinery that reports the holes.
phase_complete_request :: proc(t: ^testing.T, server: ^Server) {

	l: lab.Lab
	lab.lab_init(&l, LAB_SEED)

	sock, ok := lab.dial(server.port, l.patience)
	testing.expect(t, ok, "the lab must be able to connect")
	if !ok {
		return
	}
	defer net.close(sock)

	lab.send_fragmented(sock, lab.GET_PING, 1, 0)
	outcome, status := lab.read_status(&l, sock)

	testing.expect_value(t, outcome, lab.Outcome.Responded)
	testing.expect_value(t, status, 200)
}

// Fragmentation is survivable, and this is the second half of the positive
// control: the server must reassemble a request split across several writes.
// If it could not, the "held open" findings above would be unremarkable.
phase_fragmented :: proc(t: ^testing.T, server: ^Server) {

	l: lab.Lab
	lab.lab_init(&l, LAB_SEED)

	for chunks in 2 ..= 5 {
		sock, ok := lab.dial(server.port, l.patience)
		if !ok {
			testing.expect(t, false, "the lab must be able to connect")
			return
		}
		lab.send_fragmented(sock, lab.GET_PING, chunks, 2 * time.Millisecond)
		outcome, status := lab.read_status(&l, sock)
		net.close(sock)

		testing.expectf(
			t,
			outcome == .Responded && status == 200,
			"a request split into %d pieces must still be served; got %v/%d",
			chunks,
			outcome,
			status,
		)
	}
}

// ---------------------------------------------------------------------------
// THE ONE OWNING TEST.
//
// WHY THE PHASES ABOVE ARE NOT `@(test)` PROCEDURES, and this cost a hung run
// to learn: the pinned runner executes tests on EIGHT THREADS by default. Five
// tests that each bind a listener on the same candidate ports, sharing one
// `g_server`, do not race occasionally — they deadlock, and a hanging suite is
// a worse diagnosis than a red one.
//
// The WP9 corpus has exactly one server-owning test for this reason. This is
// the same shape: one listener, one owner, phases in a fixed order. It also
// makes the trail meaningful, since a trail interleaved across threads would
// not replay.
// ---------------------------------------------------------------------------

@(test)
wp41_fault_laboratory :: proc(t: ^testing.T) {
	filter: Log_Filter
	context.logger = swallow_framework_log(&filter)

	server: Server
	if !start_server(&server) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}
	defer stop_server(&server)

	// The positive controls run FIRST. If a complete request is not answered,
	// every "held open" finding below would be unremarkable, and knowing that
	// before reading them is the difference between a finding and a rumour.
	phase_complete_request(t, &server)
	phase_fragmented(t, &server)

	// The determinism criterion.
	phase_determinism(t, &server)

	// The findings.
	phase_truncated_hold(t, &server)
	phase_trickle(t, &server)

	// These two own their own server lifecycle, so they run AFTER the shared
	// listener is released — hence the explicit stop here rather than relying
	// on the deferred one, which would still be holding the port.
	stop_server(&server)

	phase_stop_accepting(t)
	phase_conflicted_never_binds(t)

	// WP46 — the deadline. These own their own server lifecycle too, for the
	// same reason as the two above: ONE listener at a time in this process.
	// Two servers running concurrently is explicitly unsupported (R-10), and in
	// a test runner it presents as a hang rather than as a failure.
	phase_deadline_ends_a_held_connection(t)
	phase_deadline_bounds_a_trickling_client(t)

	// WP44 — stop and drain. Same one-listener rule.
	phase_stop_is_idempotent_and_stops_admission(t)
	phase_a_clean_stop_completes_promptly(t)

	// WP45 — connection lifetime.
	phase_keep_alive_serves_two_requests_on_one_connection(t)
	phase_a_rejection_is_delivered_before_the_close(t)

	// WP47 — bounded admission. The positive control runs FIRST: without it,
	// the bounded phase would pass against a server that refused everything.
	phase_admission_below_the_limit_is_unaffected(t)
	phase_admission_is_bounded_with_a_reservation(t)
	phase_a_reservation_larger_than_the_budget_is_rejected(t)
}

// ---------------------------------------------------------------------------
// 4. Shutdown during a request — §1.3's obligations, made reachable.
// ---------------------------------------------------------------------------

// Obligation 1, the observable half that exists TODAY: after a stop is
// requested, the server stops accepting. What this test cannot yet assert is
// obligation 3 — that the drain ends under a deadline — because there is no
// deadline to end it (spec §1.2). WP44 amends this test; the amendment is the
// evidence.
phase_stop_accepting :: proc(t: ^testing.T) {
	server: Server
	if !start_server(&server) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	// Healthy first — the positive control that makes the refusal meaningful.
	l: lab.Lab
	lab.lab_init(&l, LAB_SEED)
	before, ok := lab.dial(server.port, l.patience)
	testing.expect(t, ok, "the server must accept before the stop")
	if ok {
		lab.send_fragmented(before, lab.GET_PING, 1, 0)
		outcome, status := lab.read_status(&l, before)
		net.close(before)
		testing.expect_value(t, outcome, lab.Outcome.Responded)
		testing.expect_value(t, status, 200)
	}

	port := server.port
	stop_server(&server)

	// After the stop the listener is gone. `dial` failing IS the observation.
	refused := false
	for _ in 0 ..< 40 {
		sock, connected := lab.dial(port, 100 * time.Millisecond)
		if !connected {
			refused = true
			break
		}
		net.close(sock)
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(
		t,
		refused,
		"a stopped server must stop accepting connections; admission-stop is proof obligation 1",
	)
}

// ---------------------------------------------------------------------------
// 5. The boot-time refusal E-4 added to the menu.
// ---------------------------------------------------------------------------

// WP30 made a registration conflict a boot failure, so the fault menu covers
// boot-time refusals and not only dispatch-time ones. A poisoned application
// must never bind — the operator experience the ADR-019 family exists for.
phase_conflicted_never_binds :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", ping_handler)
	web.get(&app, "/ping", ping_handler) // the conflict

	port := CANDIDATE_PORTS[len(CANDIDATE_PORTS) - 1]

	// `serve` returns immediately on a poisoned App rather than blocking, so
	// this needs no thread: if it bound, this call would never return, and the
	// suite would hang rather than fail. That is stated because a hanging test
	// is a worse diagnosis than a red one.
	web.serve(&app, port)

	sock, connected := lab.dial(port, 200 * time.Millisecond)
	if connected {
		net.close(sock)
	}
	testing.expect(
		t,
		!connected,
		"a fail-closed application must never bind a port; serve refusing is the whole point of the boot diagnostic",
	)
}

// ---------------------------------------------------------------------------
// 6. The trail is bounded, and says so.
// ---------------------------------------------------------------------------

// A lab that can allocate without limit under fault injection can run the
// machine out of memory while looking for a bug about running out of memory.
@(test)
wp41_the_trail_is_bounded :: proc(t: ^testing.T) {
	l: lab.Lab
	lab.lab_init(&l, LAB_SEED)
	for i in 0 ..< lab.TRAIL_MAX + 50 {
		lab.record(&l, .Fragmented_Request, i, .Responded, 200)
	}
	testing.expect_value(t, l.trail_len, lab.TRAIL_MAX)
	testing.expect(t, lab.trail_full(&l), "the lab must report a full trail rather than growing silently")

	// And the report names the seed, so a failure is reproducible from the
	// output alone rather than from whoever ran it.
	summary := fmt.tprintf("seed=%d events=%d", l.seed, l.trail_len)
	testing.expect(t, strings.contains(summary, "seed="), "the trail summary must name its seed")
}

// ---------------------------------------------------------------------------
// 7. WP46 — THE DEADLINE, AND THE AMENDMENT THIS FILE PROMISED.
//
// `phase_truncated_hold` and `phase_trickle` above assert that a silent client
// is held open forever, and the note on the first of them said: *when a read
// deadline ships, this test must be amended in the same change, and its
// amendment is the proof that the deadline works.*
//
// This is that amendment. Those two phases still run against a server with NO
// deadline configured — that path must keep behaving as it did, because
// `max_request_time = 0` means "no deadline" and an operator must be able to
// ask for the old behaviour explicitly. What follows is the same client against
// a server that DOES configure one.
// ---------------------------------------------------------------------------

deadline_ping :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

// A server whose request deadline is short enough to observe inside a test.
//
// EACH CALLER PASSES ITS OWN PORT POOL, and that is not tidiness. Two deadline
// tests sharing one pool hang: the first server's listener is still being torn
// down — its swept connections are waiting out `Conn_Close_Delay` — while the
// second binds the same port. This is the third time in this suite that shared
// ports produced a hang rather than a failure, which is the argument for making
// it structurally impossible rather than remembering.
start_deadline_server :: proc(s: ^Server, nanos: i64, ports: []int) -> bool {
	g_server = s
	for candidate in ports {
		s.app = web.app()
		budget := web.DEFAULT_LIMITS
		budget.max_request_time = nanos
		web.limits(&s.app, budget)
		web.get(&s.app, "/ping", deadline_ping)
		s.port = candidate
		s.thread = thread.create_and_start(serve_thread)
		sync.wait(&s.ready)

		if wait_until_accepting(candidate) {
			return true
		}

		transport.request_stop()
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
		web.destroy(&s.app)
	}
	return false
}

// Disjoint pools, one per deadline test. See `start_deadline_server`.
DEADLINE_PORTS_HOLD :: [?]int{55171, 55613}
DEADLINE_PORTS_TRICKLE :: [?]int{56029, 56497}

phase_deadline_ends_a_held_connection :: proc(t: ^testing.T) {
	server: Server
	// 700 ms: comfortably longer than a loopback request takes, comfortably
	// shorter than the lab's patience, so the two cannot be confused.
	ports := DEADLINE_PORTS_HOLD
	if !start_deadline_server(&server, 700 * 1_000_000, ports[:]) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}
	defer stop_server(&server)

	l: lab.Lab
	lab.lab_init(&l, LAB_SEED, 3 * time.Second)

	// THE POSITIVE CONTROL FIRST. A deadline that also refuses valid traffic
	// would pass the assertion below while breaking the server, and that is the
	// likeliest way to get this wrong.
	{
		sock, ok := lab.dial(server.port, l.patience)
		testing.expect(t, ok, "the lab must be able to connect")
		if ok {
			lab.send_fragmented(sock, lab.GET_PING, 1, 0)
			outcome, status := lab.read_status(&l, sock)
			net.close(sock)
			testing.expect_value(t, outcome, lab.Outcome.Responded)
			testing.expect_value(t, status, 200)
		}
	}

	// THE FINDING, INVERTED. The same truncated request that is held open
	// forever without a deadline must now be CLOSED.
	sock, ok := lab.dial(server.port, l.patience)
	testing.expect(t, ok, "the lab must be able to connect")
	if !ok {
		return
	}
	defer net.close(sock)

	lab.send_prefix(sock, lab.GET_PING, 30)
	outcome, _ := lab.read_status(&l, sock)

	testing.expectf(
		t,
		outcome == .Closed_Without_Response,
		"a truncated request must be closed once its deadline passes, not held; got %v",
		outcome,
	)
}

// A trickling client is bounded too, and it needs its own test: an IDLE timeout
// would be reset by every byte and would never fire here, so this is what
// distinguishes a request deadline from an idle one.
phase_deadline_bounds_a_trickling_client :: proc(t: ^testing.T) {
	server: Server
	ports := DEADLINE_PORTS_TRICKLE
	if !start_deadline_server(&server, 700 * 1_000_000, ports[:]) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}
	defer stop_server(&server)

	l: lab.Lab
	lab.lab_init(&l, LAB_SEED, 3 * time.Second)

	sock, ok := lab.dial(server.port, l.patience)
	testing.expect(t, ok, "the lab must be able to connect")
	if !ok {
		return
	}
	defer net.close(sock)

	// One byte every 40 ms, never reaching the terminator. An idle timeout would
	// be reset 25 times a second and would never fire.
	lab.send_trickle(sock, lab.GET_PING, 40 * time.Millisecond, 25)
	outcome, _ := lab.read_status(&l, sock)

	testing.expectf(
		t,
		outcome == .Closed_Without_Response,
		"a trickling client must be bounded by the REQUEST deadline, which an idle timeout would never reach; got %v",
		outcome,
	)
}

// ---------------------------------------------------------------------------
// 8. WP44 — STOP AND DRAIN, and the four proof obligations of spec §1.3.
//
// The spec wrote each obligation as a FAILURE so a test could trip it. These
// phases are those tests. They run inside the one owning test for the reason
// every other server-owning phase does: one listener at a time in this process.
// ---------------------------------------------------------------------------

STOP_PORTS :: [?]int{57171, 57613}
SLOW_PORTS :: [?]int{58171, 58613}

start_configured_server :: proc(
	s: ^Server,
	ports: []int,
	drain_nanos: i64,
	unused_slow: bool,
) -> bool {
	g_server = s
	for candidate in ports {
		s.app = web.app()
		budget := web.DEFAULT_LIMITS
		_ = drain_nanos
		web.limits(&s.app, budget)
		_ = unused_slow
		web.get(&s.app, "/ping", deadline_ping)
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

// OBLIGATIONS 1 AND 4: admission stops, and cleanup runs exactly once.
//
// The positive control is a connection served BEFORE the stop — without it, a
// server that accepted nothing at all would pass. Obligation 4 is exercised by
// requesting the stop TWICE: a second stop while the first is draining must be
// a no-op rather than a second drain, and the observable proof is that the
// serve thread still joins.
phase_stop_is_idempotent_and_stops_admission :: proc(t: ^testing.T) {
	server: Server
	ports := STOP_PORTS
	if !start_configured_server(&server, ports[:], 0, false) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	l: lab.Lab
	lab.lab_init(&l, LAB_SEED, 2 * time.Second)

	{
		sock, ok := lab.dial(server.port, l.patience)
		testing.expect(t, ok, "the server must accept before the stop")
		if ok {
			lab.send_fragmented(sock, lab.GET_PING, 1, 0)
			outcome, status := lab.read_status(&l, sock)
			net.close(sock)
			testing.expect_value(t, outcome, lab.Outcome.Responded)
			testing.expect_value(t, status, 200)
		}
	}

	port := server.port

	// Obligation 4: two stops, one drain. A second drain or a double free would
	// hang the join below or kill the process.
	web.stop(&server.app)
	web.stop(&server.app)

	thread.join(server.thread)
	thread.destroy(server.thread)
	server.thread = nil
	web.destroy(&server.app)
	g_server = nil

	refused := false
	for _ in 0 ..< 40 {
		sock, connected := lab.dial(port, 100 * time.Millisecond)
		if !connected {
			refused = true
			break
		}
		net.close(sock)
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(
		t,
		refused,
		"a stopped server must stop accepting; admission-stop is proof obligation 1",
	)
}

// OBLIGATION 3 COULD NOT BE SATISFIED, AND THIS PHASE RECORDS THAT RATHER THAN
// ASSERTING SOMETHING WEAKER.
//
// The WP39 spec requires an ABSOLUTE drain deadline. WP44 tried to build one as
// a vendored patch and **it did not stay contained** — the full account is in
// `planning/phase-4-plan.md` under WP44. In short: bounding the drain loop is
// not enough, because the `nbio.run()` that follows it waits on every pending
// operation, and a connection the client is holding open has one.
//
// So there is no drain deadline to test. What IS true is tested here — a stop
// with no stuck connection completes promptly — and the gap is named rather
// than papered over, because a phase that asserted the weaker property would
// read, later, as though the obligation had been met.
phase_a_clean_stop_completes_promptly :: proc(t: ^testing.T) {
	server: Server
	ports := SLOW_PORTS
	if !start_configured_server(&server, ports[:], 0, false) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	l: lab.Lab
	lab.lab_init(&l, LAB_SEED, 2 * time.Second)

	// A complete request/response cycle, fully finished on both sides. This is
	// the case a stop must handle promptly, and it is the common one.
	{
		sock, ok := lab.dial(server.port, l.patience)
		testing.expect(t, ok, "the lab must be able to connect")
		if ok {
			lab.send_fragmented(sock, lab.GET_PING, 1, 0)
			outcome, status := lab.read_status(&l, sock)
			net.close(sock)
			testing.expect_value(t, outcome, lab.Outcome.Responded)
			testing.expect_value(t, status, 200)
		}
	}

	started := time.now()
	web.stop(&server.app)
	thread.join(server.thread)
	elapsed := time.diff(started, time.now())

	thread.destroy(server.thread)
	server.thread = nil
	web.destroy(&server.app)
	g_server = nil

	testing.expectf(
		t,
		elapsed < 3 * time.Second,
		"a stop with no connection left in flight must complete promptly; took %v",
		elapsed,
	)
}

// ---------------------------------------------------------------------------
// 9. WP45 — CONNECTION LIFETIME.
//
// C-3 binds this three times: 400-and-close on framing errors, drain-or-close
// after every early rejection, and the staged close of §9.6 — *a 400 the client
// never receives is a real failure mode*.
//
// **The WP9 corpus already proves the first.** Every one of its cases asserts
// that a malformed request RETIRES the connection and that trailing bytes never
// execute as a second request. What no suite proved is the opposite half:
//
//	that a GOOD request PRESERVES the connection.
//
// A server that closed after every single response would pass the entire
// existing suite while making keep-alive a lie, and nothing would have noticed.
// That gap is what these phases close.
// ---------------------------------------------------------------------------

KEEPALIVE_PORTS :: [?]int{59171, 59613}

// KEEP-ALIVE IS REAL: two requests, one connection.
//
// Sent as two separate writes rather than pipelined, because pipelining asks a
// different question (does the server queue?) and answering both in one test
// would leave neither answered.
phase_keep_alive_serves_two_requests_on_one_connection :: proc(t: ^testing.T) {
	server: Server
	ports := KEEPALIVE_PORTS
	if !start_configured_server(&server, ports[:], 0, false) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}
	defer stop_server(&server)

	l: lab.Lab
	lab.lab_init(&l, LAB_SEED, 2 * time.Second)

	sock, ok := lab.dial(server.port, l.patience)
	testing.expect(t, ok, "the lab must be able to connect")
	if !ok {
		return
	}
	defer net.close(sock)

	lab.send_fragmented(sock, lab.GET_PING_KEEPALIVE, 1, 0)
	first, first_status := lab.read_status(&l, sock)
	testing.expect_value(t, first, lab.Outcome.Responded)
	testing.expect_value(t, first_status, 200)

	// THE ASSERTION THIS PHASE EXISTS FOR. If the server retired the connection
	// after the first response, this write either fails or is never answered.
	lab.send_fragmented(sock, lab.GET_PING_KEEPALIVE, 1, 0)
	second, second_status := lab.read_status_again(&l, sock)

	testing.expectf(
		t,
		second == .Responded && second_status == 200,
		"a second request on the same connection must be answered; got %v/%d. Without this, a server that closed after every response would pass the entire existing suite while making keep-alive a lie.",
		second,
		second_status,
	)
}

// THE STAGED CLOSE: a rejection must ARRIVE before the connection goes.
//
// C-3 §9.6's point, and it is easy to get backwards: a server that detects a
// framing error and closes immediately is *safe* — no smuggling — and *unusable*,
// because the client sees a reset rather than a 400 and cannot tell a bad
// request from a network fault. The WP9 corpus asserts the connection is
// retired; it does not assert the response was delivered first.
phase_a_rejection_is_delivered_before_the_close :: proc(t: ^testing.T) {
	server: Server
	ports := KEEPALIVE_PORTS
	if !start_configured_server(&server, ports[:], 0, false) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}
	defer stop_server(&server)

	l: lab.Lab
	lab.lab_init(&l, LAB_SEED, 2 * time.Second)

	sock, ok := lab.dial(server.port, l.patience)
	testing.expect(t, ok, "the lab must be able to connect")
	if !ok {
		return
	}
	defer net.close(sock)

	// Two Content-Length headers: rejected by WP9's patch 4.
	lab.send_fragmented(sock, lab.BAD_DOUBLE_LENGTH, 1, 0)
	outcome, status := lab.read_status(&l, sock)

	testing.expectf(
		t,
		outcome == .Responded,
		"a rejected request must still RECEIVE its response before the connection closes; got %v. A 400 the client never sees is indistinguishable from a network fault.",
		outcome,
	)
	testing.expectf(
		t,
		status >= 400 && status < 500,
		"the delivered rejection must be a 4xx; got %d",
		status,
	)
}

// ---------------------------------------------------------------------------
// 10. WP47 — BOUNDED ADMISSION, and the reservation rule.
// ---------------------------------------------------------------------------

ADMISSION_PORTS :: [?]int{60171, 60613}

start_admission_server :: proc(s: ^Server, ports: []int, max_conns, reserved: int) -> bool {
	g_server = s
	for candidate in ports {
		s.app = web.app()
		budget := web.DEFAULT_LIMITS
		budget.max_connections = max_conns
		budget.reserved_conns = reserved
		// The read deadline is disabled so that a connection held open by this
		// test is held by the TEST, not ended by the WP46 sweep — otherwise a
		// pass would not say which mechanism did the work.
		budget.max_request_time = 0
		web.limits(&s.app, budget)
		web.get(&s.app, "/ping", deadline_ping)
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

// ADMISSION IS REFUSED AT OR BELOW THE RESERVATION, NEVER AT ZERO.
//
// The budget here is 6 with 2 reserved, so 4 connections are admissible and the
// fifth must be refused **while two slots are still free**. That gap is the
// reservation: it is what a drain works in, and testing at zero would prove the
// wrong rule.
//
// Held connections are opened WITHOUT sending a request, so they occupy a slot
// without completing — which is what a real overload looks like.
phase_admission_is_bounded_with_a_reservation :: proc(t: ^testing.T) {
	server: Server
	ports := ADMISSION_PORTS
	if !start_admission_server(&server, ports[:], 6, 2) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}
	defer stop_server(&server)

	held: [8]net.TCP_Socket
	held_count := 0
	defer for i in 0 ..< held_count {
		net.close(held[i])
	}

	// Fill the admissible budget: 6 - 2 = 4.
	for _ in 0 ..< 4 {
		sock, ok := lab.dial(server.port, 500 * time.Millisecond)
		if !ok {
			break
		}
		held[held_count] = sock
		held_count += 1
		time.sleep(20 * time.Millisecond)
	}
	testing.expectf(t, held_count == 4, "the admissible budget must accept 4 connections; got %d", held_count)

	// THE FIFTH. The kernel completes the TCP handshake before the server sees
	// it, so `dial` still succeeds — the refusal is observed as the server
	// CLOSING it rather than as a failed connect. That distinction is why this
	// reads a status rather than checking `ok`.
	time.sleep(100 * time.Millisecond)
	extra, ok := lab.dial(server.port, 800 * time.Millisecond)
	testing.expect(t, ok, "the kernel accepts the handshake regardless; the refusal is the server's close")
	if !ok {
		return
	}
	defer net.close(extra)

	l: lab.Lab
	lab.lab_init(&l, LAB_SEED, 800 * time.Millisecond)
	lab.send_fragmented(extra, lab.GET_PING, 1, 0)
	outcome, _ := lab.read_status(&l, extra)

	testing.expectf(
		t,
		outcome == .Closed_Without_Response,
		"a connection past the admission budget must be refused (closed), not served; got %v. Admission stops at or below the reservation, with slots still free, so a drain has room to work in.",
		outcome,
	)
}

// THE POSITIVE CONTROL, and it is not optional: a server whose limit is far
// above the load must serve everything. Without it, the phase above would pass
// against a server that refused every connection.
phase_admission_below_the_limit_is_unaffected :: proc(t: ^testing.T) {
	server: Server
	ports := ADMISSION_PORTS
	if !start_admission_server(&server, ports[:], 64, 8) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}
	defer stop_server(&server)

	l: lab.Lab
	lab.lab_init(&l, LAB_SEED, 1500 * time.Millisecond)

	for i in 0 ..< 6 {
		sock, ok := lab.dial(server.port, l.patience)
		if !ok {
			testing.expectf(t, false, "connection %d must be accepted well below the limit", i)
			return
		}
		lab.send_fragmented(sock, lab.GET_PING, 1, 0)
		outcome, status := lab.read_status(&l, sock)
		net.close(sock)
		testing.expectf(
			t,
			outcome == .Responded && status == 200,
			"request %d must be served when the limit is far above the load; got %v/%d",
			i,
			outcome,
			status,
		)
	}
}

// A RESERVATION THAT SWALLOWS ITS BUDGET IS REFUSED AT BOOT.
//
// `reserved >= max` would refuse every connection while looking like a working
// configuration — a server that accepts nothing, discovered in production. The
// diagnostic belongs at boot, where an operator is watching.
phase_a_reservation_larger_than_the_budget_is_rejected :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)

	budget := web.DEFAULT_LIMITS
	budget.max_connections = 8
	budget.reserved_conns = 8
	web.limits(&app, budget)
	web.get(&app, "/ping", deadline_ping)

	res := web.test_request(&app, .GET, "/ping")
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
}
