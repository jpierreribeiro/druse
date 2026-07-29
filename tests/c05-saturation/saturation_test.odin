// C-05 — the combined-saturation lab: HOW THE SERVER DEGRADES AND RECOVERS.
//
// THE QUESTION, and it is the architecture backlog's, not a new one: a request
// passes through several bounded resources in series — the kernel's accept
// backlog, the server's admission budget (`max_connections` minus
// `reserved_conns`), a synchronous Handler lane, and process memory. Each has
// its own limit and its own refusal. Under dedicated accept, which refusal is
// observed first in a particular run is scheduler-dependent: excess work may
// be refused or may wait on a lane-owned socket until the client times out.
//
// Nobody had measured it. `planning/closure-readiness-matrix.md` records every
// one of those resources with a limit and a saturation policy — that is C-02's
// job — but a matrix says what each resource does ALONE. This suite asks what
// they do TOGETHER.
//
// THE METHOD. Ramp concurrent clients against a server whose limits are set so
// the two framework-owned bounds are BOTH reachable on a test machine, and
// classify every single request by the outcome that identifies which resource
// refused it:
//
//	200                  served
//	503                  DEFECT: acceptor wrote HTTP before parsing a request
//	connected-then-EOF   an admission or Handler-saturation transport refusal
//	connect failed       the kernel BACKLOG or the fd table refused
//	timeout              nothing refused; something is merely slow
//
// The distinction between the middle two is the whole instrument, and it is the
// same one the C-03 RST-flood probe needed: an admission refusal accepts the
// TCP connection and then closes it with nothing written, so a client that only
// counts "errors" cannot tell it from a backlog drop. This suite counts them
// apart, which is why it can describe the degradation instead of guessing.
//
// WHAT IT DELIBERATELY DOES NOT DO: it is not a benchmark. The numbers it
// prints are a RATIO between refusal kinds, not a throughput claim, and the
// assertions are about the SHAPE of the degradation — that the server keeps
// answering, that every refusal is a refusal the design names, and that nothing
// is answered with a truncated or malformed reply. A load figure from a shared
// development box would be a number about the box.
package test_c05_saturation

import "core:fmt"
import "core:strings"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "uruquim:web"

CANDIDATE_PORTS :: [?]int{55037, 55363, 55631, 55907}

// The admission budget is set SMALL and the handler dwell LONG, so both bounds
// are reachable with a client count a test machine can produce. The point is
// the ordering of the two refusals, not the absolute numbers.
MAX_CONNECTIONS :: 24
RESERVED_CONNS :: 4 // budget = 20
WORK_DWELL :: 40 * time.Millisecond

// The ramp. Each level runs a fresh burst of concurrent clients.
LEVELS :: [?]int{4, 12, 24, 48}
MAX_CLIENTS :: 48

CLIENT_PATIENCE :: 3 * time.Second

Outcome :: enum {
	Served, // 200
	Lane_Refused, // DEFECT: pre-request 503, retained as the negative-control outcome
	Lane_Refused_No_Retry, // same defect without Retry-After
	Admission_Refused, // connected, then closed with nothing written
	Connect_Failed, // the backlog or the fd table said no
	Timed_Out, // slow, not refused
	Malformed, // a reply that is neither — the only real defect
}

Client :: struct {
	port:    int,
	outcome: Outcome,
}

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
	done:   sync.Sema,
}

g_server: ^Server
g_clients: []Client
g_next: int
g_hold_entered: int
g_hold_release: sync.Sema
g_hold_results: [4]Outcome
g_hold_next: int

work_handler :: proc(ctx: ^web.Context) {
	// A synchronous dwell is the point: it occupies a Handler lane for a known
	// time, which is what makes lane saturation reachable and legible.
	time.sleep(WORK_DWELL)
	web.text(ctx, .OK, "done")
}

hold_handler :: proc(ctx: ^web.Context) {
	_ = sync.atomic_add(&g_hold_entered, 1)
	sync.wait(&g_hold_release)
	web.text(ctx, .OK, "released")
}

serve_thread :: proc() {
	s := g_server
	sync.post(&s.ready)
	web.serve(&s.app, s.port)
	sync.post(&s.done)
}

base_limits :: proc() -> web.Limits {
	l := web.DEFAULT_LIMITS
	l.max_connections = MAX_CONNECTIONS
	l.reserved_conns = RESERVED_CONNS
	l.max_handlers = 4
	l.max_drain_time = i64(3 * time.Second)
	return l
}

start_server :: proc(s: ^Server) -> bool {
	return start_server_with(s, base_limits())
}

start_server_with :: proc(s: ^Server, limits: web.Limits) -> bool {
	g_server = s
	for candidate in CANDIDATE_PORTS {
		s.app = web.app()
		web.limits(&s.app, limits)
		web.get(&s.app, "/work", work_handler)
		web.get(&s.app, "/hold", hold_handler)
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

stop_server :: proc(s: ^Server) -> bool {
	if s.thread == nil {
		g_server = nil
		return true
	}
	web.stop(&s.app)
	returned := sync.sema_wait_with_timeout(&s.done, 15 * time.Second)
	if returned {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
		web.destroy(&s.app)
	}
	g_server = nil
	return returned
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

REQ :: "GET /work HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
HOLD_REQ :: "GET /hold HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"

one_request_with :: proc(port: int, request: string) -> Outcome {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	sock, derr := net.dial_tcp(ep)
	if derr != nil {
		return .Connect_Failed
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, CLIENT_PATIENCE)
	_ = net.set_option(sock, .Send_Timeout, CLIENT_PATIENCE)

	buf := transmute([]u8)request
	sent := 0
	for sent < len(buf) {
		n, serr := net.send_tcp(sock, buf[sent:])
		if serr != nil || n <= 0 {
			// The peer went away mid-write: it accepted us and then closed,
			// which is the admission refusal seen from the write side.
			return .Admission_Refused
		}
		sent += n
	}

	reply: [512]u8
	n, rerr := net.recv_tcp(sock, reply[:])
	if rerr != nil {
		if rerr == net.TCP_Recv_Error.Timeout {
			return .Timed_Out
		}
		// A peer-side close may surface as Reset/Broken_Pipe rather than a
		// zero-byte EOF. Both are explicit transport refusals; classifying every
		// recv error as timeout hid seven of eight controlled closes.
		return .Admission_Refused
	}
	if n == 0 {
		// Accepted, then closed with NOTHING written. This is the admission
		// refusal's signature, and telling it apart from a backlog drop is the
		// reason this suite can distinguish how saturation presented.
		return .Admission_Refused
	}
	if n < 12 {
		return .Malformed
	}
	head := string(reply[:n])
	status := 0
	for i in 9 ..< 12 {
		c := head[i]
		if c < '0' || c > '9' {
			return .Malformed
		}
		status = status * 10 + int(c - '0')
	}
	switch status {
	case 200:
		return .Served
	case 503:
		// A dedicated acceptor has not parsed a request and may not answer HTTP.
		// Keep both old shapes distinct so the rollback control proves this
		// instrument sees the defect rather than merely an absent header.
		lower := strings.to_lower(head, context.temp_allocator)
		if strings.contains(lower, "retry-after:") {
			return .Lane_Refused
		}
		return .Lane_Refused_No_Retry
	}
	return .Malformed
}

one_request :: proc(port: int) -> Outcome {
	return one_request_with(port, REQ)
}

hold_client_thread :: proc() {
	i := sync.atomic_add(&g_hold_next, 1)
	if i < 0 || i >= len(g_hold_results) {
		return
	}
	g_hold_results[i] = one_request_with(g_server.port, HOLD_REQ)
}

client_thread :: proc() {
	i := sync.atomic_add(&g_next, 1)
	if i >= len(g_clients) {
		return
	}
	c := &g_clients[i]
	c.outcome = one_request(c.port)
}

Tally :: [Outcome]int

run_level :: proc(port: int, clients: int) -> Tally {
	pool := make([]Client, clients)
	defer delete(pool)
	for &c in pool {
		c.port = port
	}
	g_clients = pool
	g_next = 0

	threads: [MAX_CLIENTS]^thread.Thread
	for i in 0 ..< clients {
		threads[i] = thread.create_and_start(client_thread)
	}
	for i in 0 ..< clients {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}
	g_clients = nil

	tally: Tally
	for c in pool {
		tally[c.outcome] += 1
	}
	return tally
}

@(test)
c05_combined_saturation_degrades_recovers_and_stops :: proc(t: ^testing.T) {
	server: Server
	if !start_server(&server) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	// Deterministic PATCH 42 perimeter. Occupy all four configured Handler
	// lanes behind a barrier, then drive eight ordinary requests while the
	// acceptor can prove no lane is available. This is the non-vacuous control
	// the probabilistic ramp below cannot provide on every scheduler.
	g_hold_entered = 0
	g_hold_next = 0
	hold_threads: [4]^thread.Thread
	for i in 0 ..< len(hold_threads) {
		hold_threads[i] = thread.create_and_start(hold_client_thread)
	}
	holds_ready := false
	for _ in 0 ..< 200 {
		if sync.atomic_load(&g_hold_entered) == len(hold_threads) {
			holds_ready = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expectf(
		t,
		holds_ready,
		"only %d/%d hold handlers entered; the deterministic saturation control never established its precondition",
		sync.atomic_load(&g_hold_entered),
		len(hold_threads),
	)

	saturation_before := web.stats().saturation_refusals
	controlled := run_level(server.port, 8)
	saturation_after := web.stats().saturation_refusals
	controlled_http :=
		controlled[.Lane_Refused] + controlled[.Lane_Refused_No_Retry]
	testing.expectf(
		t,
		controlled_http == 0,
		"%d HTTP 503 responses were emitted before a request was parsed in the deterministic saturation control",
		controlled_http,
	)
	testing.expectf(
		t,
		controlled[.Admission_Refused] == 8,
		"expected 8 transport refusals with all lanes held, got %d (timeouts=%d malformed=%d)",
		controlled[.Admission_Refused],
		controlled[.Timed_Out],
		controlled[.Malformed],
	)
	testing.expectf(
		t,
		saturation_after - saturation_before == 8,
		"saturation_refusals moved by %d for 8 controlled refusals",
		saturation_after - saturation_before,
	)
	for _ in 0 ..< len(hold_threads) {
		sync.post(&g_hold_release)
	}
	for i in 0 ..< len(hold_threads) {
		thread.join(hold_threads[i])
		thread.destroy(hold_threads[i])
		testing.expectf(
			t,
			g_hold_results[i] == .Served,
			"held request %d did not complete after release: %v",
			i,
			g_hold_results[i],
		)
	}
	fmt.printf(
		"[c05] controlled saturation: transport_refused=%d pre_request_503=%d counter_delta=%d\n",
		controlled[.Admission_Refused],
		controlled_http,
		saturation_after - saturation_before,
	)

	fmt.printf(
		"[c05] budget=%d slots (max_connections=%d - reserved=%d), handler dwell=%v\n",
		MAX_CONNECTIONS - RESERVED_CONNS,
		MAX_CONNECTIONS,
		RESERVED_CONNS,
		WORK_DWELL,
	)

	total_malformed := 0
	total_lane_503 := 0
	total_lane_503_no_retry := 0
	// Requests the server actually DISPATCHED. Only these charge handler dwell:
	// a refusal is answered before dispatch and a timed-out client never got a
	// reply. The dwell floor below is built from this, NOT from the number of
	// clients driven — those are not the same number and differ by 2-3x once
	// the ramp starts refusing.
	total_served := 0
	// Any refusal the design names, independent of which kind appears first.
	total_refused := 0
	// Clients that waited out CLIENT_PATIENCE without a reply. Under dedicated
	// accept this is the COMMON face of saturation, not an anomaly: a request
	// arriving at a busy lane queues on that lane's socket, so the ramp binds
	// as latency rather than as a 503. Counted separately because a bound that
	// presents as queueing is still a bound.
	total_timed_out := 0
	first_observed_refusal_kind := Outcome.Served
	first_observed_refusal_level := 0

	for clients in LEVELS {
		tally := run_level(server.port, clients)
		fmt.printf(
			"[c05] clients=%d served=%d lane_503=%d no_retry=%d admission=%d connect_fail=%d timeout=%d malformed=%d\n",
			clients,
			tally[.Served],
			tally[.Lane_Refused],
			tally[.Lane_Refused_No_Retry],
			tally[.Admission_Refused],
			tally[.Connect_Failed],
			tally[.Timed_Out],
			tally[.Malformed],
		)
		total_malformed += tally[.Malformed]
		total_lane_503 += tally[.Lane_Refused] + tally[.Lane_Refused_No_Retry]
		total_lane_503_no_retry += tally[.Lane_Refused_No_Retry]
		total_served += tally[.Served]
		total_refused +=
			tally[.Lane_Refused] +
			tally[.Lane_Refused_No_Retry] +
			tally[.Admission_Refused] +
			tally[.Connect_Failed]
		total_timed_out += tally[.Timed_Out]

		// Record the first OBSERVED refusal for diagnostics. This is explicitly
		// not an architectural ordering assertion: dedicated accept, lane-owned
		// socket queueing and client scheduling decide which visible refusal
		// happens first in any one run.
		lane_refused := tally[.Lane_Refused] + tally[.Lane_Refused_No_Retry]
		if first_observed_refusal_kind == .Served {
			if tally[.Admission_Refused] > 0 {
				first_observed_refusal_kind = .Admission_Refused
				first_observed_refusal_level = clients
			} else if lane_refused > 0 {
				first_observed_refusal_kind = .Lane_Refused
				first_observed_refusal_level = clients
			} else if tally[.Connect_Failed] > 0 {
				first_observed_refusal_kind = .Connect_Failed
				first_observed_refusal_level = clients
			}
		}
		// Let the server return to rest between levels, so each level measures
		// its own load rather than the previous level's tail.
		time.sleep(300 * time.Millisecond)
	}

	if first_observed_refusal_kind == .Served {
		fmt.printf("[c05] no resource bound at any level up to %d clients\n", LEVELS[len(LEVELS) - 1])
	} else {
		fmt.printf(
			"[c05] FIRST OBSERVED REFUSAL (scheduler-dependent): %v, at %d concurrent clients\n",
			first_observed_refusal_kind,
			first_observed_refusal_level,
		)
	}

	// A healthy request after the ramp: saturation must be transient.
	after := one_request(server.port)
	fmt.printf("[c05] after the ramp: %v\n", after)

	// Campaign C plus PATCH 42: handler dwell measures dispatched work, while
	// saturation_refusals names accepted sockets closed before HTTP dispatch.
	// The two counters deliberately describe different resources.
	stats := web.stats()
	fmt.printf(
		"[c05] handler_dwell_ns=%d saturation_refusals=%d pre_request_503=%d handler dwell=%v\n",
		stats.handler_dwell_ns,
		stats.saturation_refusals,
		total_lane_503,
		WORK_DWELL,
	)

	returned := false
	{
		web.stop(&server.app)
		stop_started := time.now()
		returned = sync.sema_wait_with_timeout(&server.done, 15 * time.Second)
		fmt.printf("[c05] stop returned=%v after %v\n", returned, time.since(stop_started))
		if returned {
			thread.join(server.thread)
			thread.destroy(server.thread)
			server.thread = nil
			web.destroy(&server.app)
		}
		g_server = nil
	}

	testing.expect(t, returned, "the server must shut down after the saturation ramp")
	// THE ONE HARD ASSERTION. Every outcome must be one the design NAMES.
	// A malformed or truncated reply means a resource ran out in a way nobody
	// chose — which is precisely the "failure mode is an accident" that the
	// admission bound (WP40 §2.5) exists to prevent.
	testing.expectf(
		t,
		total_malformed == 0,
		"%d requests got a reply that was neither 200, 503, nor a clean refusal; under saturation every outcome must be one the design names",
		total_malformed,
	)
	testing.expectf(
		t,
		after == .Served,
		"the server did not serve a normal request after the ramp (got %v); saturation must be transient",
		after,
	)
	// PATCH 42 — zero HTTP responses may originate before request parsing. The
	// two 503 counters are retained as a rollback detector, not as a supported
	// overload outcome.
	fmt.printf(
		"[c05] lane 503s: %d total, %d without Retry-After\n",
		total_lane_503,
		total_lane_503_no_retry,
	)
	// NON-VACUITY, stated over what the ramp DETERMINISTICALLY produces.
	//
	// Two earlier forms of this assertion were both wrong, and the second was
	// wrong in an instructive way:
	//
	//   `total_lane_503 > 0` — a coin flip. Over nine runs on a 4-vCPU host the
	//   ramp produced zero 503s in six, failing the gate on correct code, on
	//   this tree and on the tree before Campaign C alike.
	//
	//   `total_refused > 0` — also a coin flip, for a reason worth writing
	//   down. A gate run served 36 of 88 clients and REFUSED NONE: the other 52
	//   timed out. Under dedicated accept a request meeting a busy lane queues
	//   on that lane's socket, so saturation's normal face is latency, not a
	//   refusal. That is precisely Campaign C's thesis, and an assertion that
	//   demanded a refusal contradicted it.
	//
	// What IS deterministic is that the ramp overwhelms the server: 88 clients
	// against a 20-slot budget with 40 ms handlers cannot all be served, by
	// arithmetic rather than by timing. Whether the excess is refused or merely
	// made to wait is exactly the scheduling detail that must NOT gate.
	total_driven := 0
	for clients in LEVELS {
		total_driven += clients
	}
	testing.expectf(
		t,
		total_served < total_driven,
		"every one of the %d driven clients was served on a %d-slot budget with %v handlers; the ramp did not saturate anything, so the assertions below are vacuous",
		total_driven,
		MAX_CONNECTIONS - RESERVED_CONNS,
		WORK_DWELL,
	)
	fmt.printf(
		"[c05] ramp outcome: %d/%d served, %d refused, %d timed out — saturation presented as %s\n",
		total_served,
		total_driven,
		total_refused,
		total_timed_out,
		"refusal" if total_refused > 0 else "queueing (no refusal at all)",
	)
	testing.expectf(
		t,
		total_lane_503 == 0,
		"%d HTTP 503 responses were emitted before a request was parsed (%d lacked Retry-After); acceptor saturation must be a transport refusal",
		total_lane_503,
		total_lane_503_no_retry,
	)
	testing.expectf(t, stats.saturation_refusals >= 8, "the controlled saturation refusals disappeared from the running total")
	// Campaign C — the dwell counter is WIRED, not decorative. A dwell total
	// that stays near zero while every SERVED request ran a 40 ms handler is a
	// dead saturation signal, which is the defect this replaced.
	//
	// The floor is built from requests the server actually DISPATCHED. The
	// first version of this assertion summed LEVELS — every client driven,
	// including the ones that were refused before dispatch or timed out — and
	// called it `served_all`. That is 88 where the real figure is 30-36, so it
	// demanded ~2.5x the dwell the run can possibly produce and passed only on
	// the margin between the WORK_DWELL/4 floor and the true WORK_DWELL. On a
	// slower host it fails on correct code. Count what was served.
	min_dwell_ns := i64(WORK_DWELL / 4)
	testing.expectf(
		t,
		stats.handler_dwell_ns >= i64(total_served) * min_dwell_ns,
		"web.stats().handler_dwell_ns=%d is far below the %d SERVED dispatches at %v dwell each; the dwell accumulator is not wired to the dispatch bracket",
		stats.handler_dwell_ns,
		total_served,
		WORK_DWELL,
	)
	// The floor above is a wiring check and passes at a quarter of the real
	// dwell. Report the mean so a bracket that measures the WRONG interval
	// (rather than none at all) is visible to a reader even when it clears the
	// floor.
	if total_served > 0 {
		fmt.printf(
			"[c05] mean dwell = %v over %d served dispatches (handler sleeps %v)\n",
			time.Duration(stats.handler_dwell_ns / i64(total_served)),
			total_served,
			WORK_DWELL,
		)
	}
}
