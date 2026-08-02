// R2-WP03 — observability under saturation, driven through a real server.
//
// AUD-P2-009 is two findings wearing one sentence, and this suite proves both
// are real and both are closed.
//
// THE FIRST is the one everybody quotes: `/stats` is an ordinary route on the
// same Handler lanes as the load, so a scrape competes with the traffic it
// describes. Under full lane occupancy it does not answer.
//
// THE SECOND is in the same sentence and is easier to miss: cumulative counters
// "do not replace gauges of occupancy and resolved capacity". Finding OBS-001
// says why that is sharper than it sounds. Every counter in `Server_Stats` is
// written when work COMPLETES — `responses_sent` on send completion,
// `handler_dwell_ns` after the dispatch returns. At full occupancy nothing
// completes, so every counter FREEZES, and the utilization formula the docs
// teach, `Δdwell / (lanes × Δwall)`, reads zero while utilization is one. A
// saturated server and an idle server produce identical flat lines.
//
// So the assertions below are, in order: the counters really do freeze; the
// gauge really does not; the route really does fail; the out-of-band read really
// does succeed in the same instant; the export really does cost zero lane time;
// and an absent snapshot really does carry a cause instead of a plausible
// number.
//
// SATURATION IS A BARRIER, NOT A RAMP. Every lane is counted inside a handler
// before any assertion runs, the same mechanism tests/c05-saturation uses. A
// probabilistic ramp would make the result depend on the scheduler, and a
// scheduler-dependent control is not a control.
//
// ONE @(test): this suite starts a server, and it must be sequential.
package test_r2_observability_saturation

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

CANDIDATE_PORTS :: [?]int{55471, 55797, 56063, 56341}

LANES :: 4
MAX_CONNECTIONS :: 64
RESERVED_CONNS :: 8
// The enforced admission ceiling is max_connections - reserved_conns, not
// max_connections. Reporting the latter would show headroom admission will
// never hand out.
EXPECTED_CONNECTION_CAPACITY :: MAX_CONNECTIONS - RESERVED_CONNS

EXPORT_PERIOD :: 50 * time.Millisecond
MAX_AGE :: 4 * EXPORT_PERIOD

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
}

g_server: ^Server
g_hold_entered: int
g_release: int
g_export_stop: int
g_export_ticks: int
g_snapshot: string

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

hold :: proc(ctx: ^web.Context) {
	sync.atomic_add(&g_hold_entered, 1)
	for sync.atomic_load(&g_release) == 0 {
		time.sleep(2 * time.Millisecond)
	}
	web.text(ctx, .OK, "released")
}

stats_route :: proc(ctx: ^web.Context) {
	web.ok(ctx, web.stats(&g_server.app))
}

serve_thread :: proc() {
	s := g_server
	sync.post(&s.ready)
	web.serve(&s.app, s.port)
}

start_server :: proc(s: ^Server) -> bool {
	g_server = s
	for candidate in CANDIDATE_PORTS {
		s.app = web.app()
		l := web.DEFAULT_LIMITS
		l.max_handlers = LANES
		l.max_connections = MAX_CONNECTIONS
		l.reserved_conns = RESERVED_CONNS
		l.max_drain_time = i64(2 * time.Second)
		web.limits(&s.app, l)
		web.get(&s.app, "/hold", hold)
		web.get(&s.app, "/stats", stats_route)
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
	for _ in 0 ..< 400 {
		sock, err := net.dial_tcp(ep)
		if err == nil {
			net.close(sock)
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

// ---------------------------------------------------------------------------
// The exporter under test — the same shape examples/10-config-and-health and
// ops/soak/soak-server run, reduced to what an assertion needs.
// ---------------------------------------------------------------------------

render_snapshot :: proc(s: web.Server_Stats, draining: bool, allocator := context.allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator)
	fmt.sbprintfln(&b, "druse_snapshot 1")
	fmt.sbprintfln(&b, "pid %d", os.get_pid())
	fmt.sbprintfln(&b, "unix_ns %d", time.now()._nsec)
	fmt.sbprintfln(&b, "draining %d", 1 if draining else 0)
	fmt.sbprintfln(&b, "responses_sent %d", s.responses_sent)
	fmt.sbprintfln(&b, "handler_dwell_ns %d", s.handler_dwell_ns)
	fmt.sbprintfln(&b, "saturation_refusals %d", s.saturation_refusals)
	fmt.sbprintfln(&b, "active_connections %d", s.active_connections)
	fmt.sbprintfln(&b, "handlers_active %d", s.handlers_active)
	fmt.sbprintfln(&b, "handler_capacity %d", s.handler_capacity)
	fmt.sbprintfln(&b, "connection_capacity %d", s.connection_capacity)
	fmt.sbprintfln(&b, "end")
	return strings.to_string(b)
}

write_snapshot :: proc(draining: bool) -> bool {
	s := web.stats(&g_server.app)
	// A record of zeroes is a counter RESET, and operators are told to read a
	// reset as a restart. `web.stats` returns the zero value once the App stops
	// running a server, which is precisely where the final drain write lands, so
	// the previous record must stand instead. A running server always has at
	// least one lane.
	if s.handler_capacity == 0 {
		return false
	}
	text := render_snapshot(s, draining)
	defer delete(text)
	tmp := strings.concatenate({g_snapshot, ".tmp"})
	defer delete(tmp)
	if os.write_entire_file(tmp, transmute([]u8)text) != nil {
		return false
	}
	return os.rename(tmp, g_snapshot) == nil
}

export_thread :: proc() {
	for sync.atomic_load(&g_export_stop) == 0 {
		if write_snapshot(web.is_draining(&g_server.app)) {
			sync.atomic_add(&g_export_ticks, 1)
		}
		time.sleep(EXPORT_PERIOD)
	}
}

// ---------------------------------------------------------------------------
// The reader's side, and its closed absence taxonomy
// ---------------------------------------------------------------------------

Cause :: enum {
	Ok,
	Missing,
	Unreadable,
	Malformed,
	Stale,
}

read_snapshot :: proc(allocator := context.allocator) -> (Cause, string) {
	data, rerr := os.read_entire_file(g_snapshot, allocator)
	if rerr != nil {
		if os.exists(g_snapshot) {
			return .Unreadable, ""
		}
		return .Missing, ""
	}
	text := string(data)
	if !strings.has_prefix(text, "druse_snapshot 1\n") {
		return .Malformed, text
	}
	if !strings.has_suffix(strings.trim_right_space(text), "end") {
		return .Malformed, text
	}
	stamp, found := field(text, "unix_ns")
	if !found {
		return .Malformed, text
	}
	if time.now()._nsec - stamp > i64(MAX_AGE) {
		return .Stale, text
	}
	return .Ok, text
}

field :: proc(text: string, key: string) -> (i64, bool) {
	prefix := strings.concatenate({key, " "}, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, prefix) {
			return strconv.parse_i64(strings.trim_space(line[len(prefix):]), 10)
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Clients
// ---------------------------------------------------------------------------

hold_client :: proc() {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = g_server.port}
	sock, derr := net.dial_tcp(ep)
	if derr != nil {
		return
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, 60 * time.Second)
	send_all(sock, "GET /hold HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
	reply: [512]u8
	_, _ = net.recv_tcp(sock, reply[:])
}

send_all :: proc(sock: net.TCP_Socket, req: string) -> bool {
	bytes := transmute([]u8)req
	sent := 0
	for sent < len(bytes) {
		n, err := net.send_tcp(sock, bytes[sent:])
		if err != nil || n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

// scrape_stats performs one HTTP scrape of `/stats` and reports only whether it
// produced a response. WHICH failure it hit is deliberately not asserted: the
// point of the finding is that the four HTTP failure modes are all producible by
// a network too, so a test that pinned one of them would be asserting something
// about this kernel rather than about the framework.
scrape_stats :: proc(port: int, timeout: time.Duration) -> bool {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	sock, derr := net.dial_tcp(ep)
	if derr != nil {
		return false
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, timeout)
	_ = net.set_option(sock, .Send_Timeout, timeout)
	if !send_all(sock, "GET /stats HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n") {
		return false
	}
	reply: [4096]u8
	n, rerr := net.recv_tcp(sock, reply[:])
	return rerr == nil && n > 0
}

// ---------------------------------------------------------------------------

@(test)
r2_observability_survives_saturation_and_names_every_absence :: proc(t: ^testing.T) {
	// `os.get_env` returns an EMPTY, unallocated string when the variable is
	// unset, so the free has to be conditional. Deleting it unconditionally is a
	// bad free that the test runner reports and nothing else notices.
	env_dir := os.get_env("TMPDIR", context.allocator)
	defer if len(env_dir) > 0 {
		delete(env_dir)
	}
	dir := env_dir if len(env_dir) > 0 else "/tmp"
	g_snapshot = fmt.aprintf("%s/druse-r2-wp03-test-%d.snapshot", dir, os.get_pid())
	defer delete(g_snapshot)
	os.remove(g_snapshot)

	// --- Before any server: the accessor is safe and everything is zero ------
	// Including the four new fields. A capacity reported for a server that does
	// not exist would be a ceiling with nothing under it.
	{
		empty: web.App
		z := web.stats(&empty)
		testing.expect_value(t, z.handlers_active, 0)
		testing.expect_value(t, z.handler_capacity, 0)
		testing.expect_value(t, z.connection_capacity, 0)
		testing.expect_value(t, z.active_connections, 0)
	}

	server: Server
	if !start_server(&server) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}
	defer {
		sync.atomic_store(&g_release, 1)
		web.stop(&server.app)
		thread.join(server.thread)
		thread.destroy(server.thread)
		web.destroy(&server.app)
		os.remove(g_snapshot)
	}

	// --- Resolved capacity is reported, and it is the ENFORCED number --------
	idle := web.stats(&server.app)
	testing.expect_value(t, idle.handler_capacity, LANES)
	testing.expect_value(t, idle.connection_capacity, EXPECTED_CONNECTION_CAPACITY)
	testing.expect_value(t, idle.handlers_active, 0)

	// --- B7: the export mechanism costs ZERO lane time ----------------------
	// An idle server, the exporter running for several periods, and then the two
	// counters that would move if any of it had touched a lane. This is the
	// criterion that actually closes AUD-P2-009: the finding is that the metric
	// competes with the load, and the contested resource is the lane.
	sync.atomic_store(&g_export_stop, 0)
	sync.atomic_store(&g_export_ticks, 0)
	exporter := thread.create_and_start(export_thread)
	for _ in 0 ..< 200 {
		if sync.atomic_load(&g_export_ticks) >= 4 {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expectf(
		t,
		sync.atomic_load(&g_export_ticks) >= 4,
		"exporter produced only %d snapshots; the B7 window never opened",
		sync.atomic_load(&g_export_ticks),
	)
	after_export := web.stats(&server.app)
	testing.expectf(
		t,
		after_export.handler_dwell_ns == 0,
		"B7 FAILED: handler_dwell_ns is %d after %d exports against an idle server. The exporter spent lane time, which is the resource AUD-P2-009 is about.",
		after_export.handler_dwell_ns,
		sync.atomic_load(&g_export_ticks),
	)
	testing.expectf(
		t,
		after_export.responses_sent == 0,
		"B7 FAILED: responses_sent is %d after exports against an idle server; the export path ran a request",
		after_export.responses_sent,
	)

	// --- Saturate: every lane inside a handler, counted before asserting -----
	holds: [LANES]^thread.Thread
	for i in 0 ..< LANES {
		holds[i] = thread.create_and_start(hold_client)
	}
	occupied := false
	for _ in 0 ..< 400 {
		if sync.atomic_load(&g_hold_entered) >= LANES {
			occupied = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expectf(
		t,
		occupied,
		"only %d/%d lanes entered a handler; the saturation precondition was never established, so nothing below measured anything",
		sync.atomic_load(&g_hold_entered),
		LANES,
	)
	if !occupied {
		sync.atomic_store(&g_export_stop, 1)
		thread.join(exporter)
		thread.destroy(exporter)
		return
	}

	saturated := web.stats(&server.app)

	// --- OBS-001: the gauge moves and the counters do not -------------------
	testing.expectf(
		t,
		saturated.handlers_active == saturated.handler_capacity,
		"handlers_active is %d of %d with every lane provably inside a handler; the occupancy gauge does not see saturation",
		saturated.handlers_active,
		saturated.handler_capacity,
	)
	// The counters are frozen, and that is the finding rather than a bug. If
	// this assertion ever fails because dwell started accruing during a
	// dispatch, OBS-001 has been fixed at the source and this suite should say
	// so rather than keep asserting the old shape.
	testing.expectf(
		t,
		saturated.handler_dwell_ns == 0,
		"handler_dwell_ns is %d under total occupancy; OBS-001 assumed every counter freezes because it is written on completion. Re-derive the finding before changing this number.",
		saturated.handler_dwell_ns,
	)
	testing.expect_value(t, saturated.responses_sent, 0)

	// --- The route fails, the file does not, in the same window -------------
	route_answered := scrape_stats(server.port, 500 * time.Millisecond)
	testing.expect(
		t,
		!route_answered,
		"`/stats` answered while every lane was inside a handler. Either the saturation was not real or the route no longer runs on the Handler lanes — AUD-P2-009 is asserted on the first, so check it before deleting this.",
	)

	// The exporter must keep TICKING through the saturation, not merely have left
	// a readable file behind before it. So poll for a snapshot that reports the
	// occupancy — a stale record from before the barrier would satisfy a
	// single read and prove nothing. The bound is generous in periods and tight
	// in meaning: if no fresh record appears within it, the exporter stopped.
	cause := Cause.Missing
	text: string
	fresh := false
	for _ in 0 ..< 200 {
		if len(text) > 0 {
			delete(text)
			text = ""
		}
		cause, text = read_snapshot()
		if cause == .Ok {
			if active, ok := field(text, "handlers_active"); ok && active == i64(LANES) {
				fresh = true
				break
			}
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expectf(
		t,
		cause == .Ok,
		"the out-of-band snapshot read as %v during saturation; the whole arm rests on it being readable exactly here",
		cause,
	)
	testing.expect(
		t,
		fresh,
		"no snapshot written DURING the saturation reported full lane occupancy; the exporter either stopped or is reporting a level it cannot see",
	)
	if fresh {
		capacity, ok_capacity := field(text, "handler_capacity")
		testing.expect(t, ok_capacity, "the snapshot lost handler_capacity")
		testing.expectf(
			t,
			capacity == i64(LANES),
			"the snapshot reports a capacity of %d against %d configured lanes",
			capacity,
			LANES,
		)
	}
	delete(text)

	// --- Draining reaches the snapshot --------------------------------------
	// A drain that never appears in any sample is a deploy nobody can correlate
	// an incident against afterwards.
	web.stop(&server.app)
	drained_snapshot := false
	for _ in 0 ..< 200 {
		c, body := read_snapshot()
		if c == .Ok {
			if d, found := field(body, "draining"); found && d == 1 {
				drained_snapshot = true
			}
		}
		delete(body)
		if drained_snapshot {
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(
		t,
		drained_snapshot,
		"`draining 1` never reached a snapshot; restart and drain must appear on the timeline",
	)

	// --- Stop exporting: absence gets a CAUSE, not an interpolated number ----
	sync.atomic_store(&g_export_stop, 1)
	thread.join(exporter)
	thread.destroy(exporter)
	sync.atomic_store(&g_release, 1)
	for i in 0 ..< LANES {
		thread.join(holds[i])
		thread.destroy(holds[i])
	}
	thread.join(server.thread)

	// --- A dead server must not publish a record of zeroes -------------------
	// `web.stats` returns the zero value once the App is no longer running a
	// server. An exporter that writes that record publishes a counter RESET —
	// and a reset is exactly what operators are told to read as a restart. So a
	// write attempted after the server is gone must be REFUSED, leaving the last
	// real record to age into `stale` and then `no_process`.
	testing.expect(
		t,
		!write_snapshot(true),
		"the exporter wrote a snapshot after the server stopped. Every counter in it is 0, which publishes a counter reset and reads as a restart that did not happen.",
	)
	after_stop, after_stop_text := read_snapshot()
	testing.expect(
		t,
		after_stop == .Ok || after_stop == .Stale,
		"the last real record did not survive the stop",
	)
	if len(after_stop_text) > 0 {
		if sent, found := field(after_stop_text, "handler_capacity"); found {
			testing.expectf(
				t,
				sent == i64(LANES),
				"the surviving record reports handler_capacity=%d; a zeroed record replaced the real one",
				sent,
			)
		}
	}
	delete(after_stop_text)

	// STALE: the file is present, complete and parseable, and every number in it
	// is a real number the process really reported. It is still not a sample.
	// This is the assertion that separates "alert on the gap" from "carry the
	// last value forward" — the two are indistinguishable on a graph and one of
	// them hides an outage.
	time.sleep(MAX_AGE + 100 * time.Millisecond)
	stale_cause, stale_text := read_snapshot()
	delete(stale_text)
	testing.expectf(
		t,
		stale_cause == .Stale,
		"a snapshot %v older than max_age read as %v; a record that stopped being updated must not read as a value",
		MAX_AGE,
		stale_cause,
	)

	// MALFORMED: a record without its terminator. A reader that accepted this
	// would be accepting a partial write as a whole one — and a partial write of
	// integers is PLAUSIBLE, which is what makes it dangerous.
	truncated := "druse_snapshot 1\npid 1\nunix_ns 1\nhandlers_active 4\n"
	testing.expect(t, os.write_entire_file(g_snapshot, transmute([]u8)truncated) == nil)
	trunc_cause, trunc_text := read_snapshot()
	delete(trunc_text)
	testing.expectf(
		t,
		trunc_cause == .Malformed,
		"a record with no `end` terminator read as %v; truncation must be detectable, not assumed away",
		trunc_cause,
	)

	// MALFORMED: a schema this reader does not speak. A writer from another
	// build is a deployment fault and has to read as one rather than be parsed
	// optimistically.
	other := "druse_snapshot 2\npid 1\nunix_ns 1\nend\n"
	testing.expect(t, os.write_entire_file(g_snapshot, transmute([]u8)other) == nil)
	schema_cause, schema_text := read_snapshot()
	delete(schema_text)
	testing.expectf(
		t,
		schema_cause == .Malformed,
		"schema version 2 read as %v; a version this reader does not speak is malformed to it",
		schema_cause,
	)

	// MISSING: no file at all.
	os.remove(g_snapshot)
	missing_cause, missing_text := read_snapshot()
	delete(missing_text)
	testing.expectf(
		t,
		missing_cause == .Missing,
		"an absent snapshot read as %v",
		missing_cause,
	)

	fmt.printf(
		"[r2-wp03] saturated: handlers_active=%d/%d dwell=%d responses=%d refusals=%d route_answered=%v\n",
		saturated.handlers_active,
		saturated.handler_capacity,
		saturated.handler_dwell_ns,
		saturated.responses_sent,
		saturated.saturation_refusals,
		route_answered,
	)
}
