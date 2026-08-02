// R2-WP03 — the observability-arm lab: HOW A METRIC LEAVES A SATURATED PROCESS.
//
// THE QUESTION IS AUD-P2-009's. `/stats` is an ordinary route on the same lanes
// as the load, so a scrape competes with the traffic it is trying to describe.
// In the recorded twelve-hour soak 111 of 8,611 scrapes (1.3%) produced nothing
// under saturation, and — this is the part that matters — an absent scrape and a
// lost packet look identical at the sampler. Saturation of the application and
// loss on the network are indistinguishable exactly when the distinction is
// worth having.
//
// THREE ARRANGEMENTS, one process each, chosen by argv[1]:
//
//	baseline  /stats as an ordinary route on the loaded App    (what ships today)
//	arm-a     /stats on a SECOND App: own port, own lanes, own admission budget
//	arm-b     a snapshot file written by a dedicated thread; the sampler reads it
//
// `baseline` IS NOT A CANDIDATE. It is the negative control, and the
// pre-registration (planning/readiness/R2-WP03-preregistration.md, B1n) says so
// before any number exists: if the baseline does not fail under full-lane
// occupancy then the saturation was never established and the whole run is void
// rather than green. A campaign whose control passes has measured that the
// server was up, which is the defect R2-WP01 just removed from the soak
// instrument.
//
// THE SATURATION IS DETERMINISTIC, NOT A RAMP. Every lane is occupied behind a
// barrier — the same mechanism tests/c05-saturation uses — and the program
// refuses to sample until it has counted every lane inside a handler. A
// probabilistic ramp would make the result depend on the scheduler, and a
// scheduler-dependent control is not a control.
//
// WHAT IT DELIBERATELY DOES NOT MEASURE. Throughput, capacity, or anything that
// would be a number about this machine (G4). The output is a per-sample outcome
// from a CLOSED cause taxonomy plus a latency, because the decision between the
// arms turns on WHICH FAILURES EACH ARM CAN ADMIT, and that is structural rather
// than numeric.
//
//	odin run experiments/27-observability-arms -collection:druse=. -- baseline
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import web "druse:web"

// The target server. Four lanes, because four hold clients can occupy four
// lanes deterministically and the shape of the result does not depend on the
// number.
LANES :: 4
TARGET_PORT :: 57431
ADMIN_PORT :: 57432

// The sampling window. 120 samples at 25 ms is ~3 s of wall clock when nothing
// blocks and ~33 s when every sample burns its whole timeout, which is the
// baseline's expected shape.
SAMPLES :: 120
SAMPLE_INTERVAL :: 25 * time.Millisecond
SAMPLE_TIMEOUT :: 250 * time.Millisecond

// A snapshot older than this is `stale` rather than a value. It is four export
// periods: one missed tick is jitter, four is a stopped exporter.
EXPORT_PERIOD :: 250 * time.Millisecond
MAX_AGE :: 4 * EXPORT_PERIOD

SNAPSHOT_PATH :: "/tmp/druse-r2-wp03-snapshot.txt"
SNAPSHOT_TMP :: "/tmp/druse-r2-wp03-snapshot.txt.tmp"
SNAPSHOT_SCHEMA :: 1

// Cause is the CLOSED taxonomy from the pre-registration §2. Every scheduled
// sample leaves with exactly one of these. An absence with no cause is an
// instrument failure, not a datum — which is the whole lesson of INS-013.
Cause :: enum {
	Ok,
	Http_Refused, // curl 7  — the network, or admission
	Http_Timeout, // curl 28 — nothing answered in time
	Http_Empty, // curl 52 — connected, peer closed with nothing written
	Http_Recv_Error, // curl 56 — a receive error
	Missing, // no snapshot file
	Unreadable, // the file exists and the read failed
	Malformed, // no schema line, wrong version, or no terminator
	Stale, // read, but older than MAX_AGE
}

cause_name :: proc(c: Cause) -> string {
	switch c {
	case .Ok:              return "ok"
	case .Http_Refused:    return "http_refused"
	case .Http_Timeout:    return "http_timeout"
	case .Http_Empty:      return "http_empty"
	case .Http_Recv_Error: return "http_recv_error"
	case .Missing:         return "missing"
	case .Unreadable:      return "unreadable"
	case .Malformed:       return "malformed"
	case .Stale:           return "stale"
	}
	return "unknown"
}

// `Http_*` causes are the finding, not a defect of this sampler: EVERY ONE of
// them is producible both by an application that stopped answering and by a
// network that dropped the exchange. `http_ambiguous` marks that in the output
// so the analysis does not have to re-derive it.
cause_is_network_ambiguous :: proc(c: Cause) -> bool {
	#partial switch c {
	case .Http_Refused, .Http_Timeout, .Http_Empty, .Http_Recv_Error:
		return true
	}
	return false
}

target: web.App
admin: web.App

g_hold_entered: int
g_release: int
g_export_stop: int
g_export_ticks: int

// ---------------------------------------------------------------------------
// The target application
// ---------------------------------------------------------------------------

// hold occupies a lane and does not give it back until the driver says so. This
// is the saturation: not "a lot of traffic", but every lane provably inside a
// handler, counted before a single sample is taken.
hold :: proc(ctx: ^web.Context) {
	sync.atomic_add(&g_hold_entered, 1)
	for sync.atomic_load(&g_release) == 0 {
		time.sleep(2 * time.Millisecond)
	}
	web.text(ctx, .OK, "released")
}

tiny :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

// stats_route is the shape that ships today, and the shape AUD-P2-009 is about.
stats_route :: proc(ctx: ^web.Context) {
	web.ok(ctx, web.stats(&target))
}

target_thread :: proc() {
	web.serve(&target, TARGET_PORT)
}

admin_thread :: proc() {
	web.serve(&admin, ADMIN_PORT)
}

// ---------------------------------------------------------------------------
// Arm B — the exporter
// ---------------------------------------------------------------------------

// export_once writes one snapshot and returns whether it landed.
//
// TEMP-THEN-RENAME, because a reader must never see half a record. `rename` is
// atomic within a filesystem, so the sampler either reads the previous complete
// snapshot or the new complete one. The `end` terminator is belt to that brace:
// it lets a reader PROVE it got a whole record rather than assume it, which is
// what makes `malformed` a distinguishable cause instead of a silent short read.
//
// It runs on its own thread and calls `web.stats`, which takes no lock, reads
// atomics and allocates nothing. It therefore consumes no lane time at all —
// criterion B7 in the pre-registration, and the reason this arm can close a
// finding about competing with the load.
export_once :: proc(a: ^web.App) -> bool {
	s := web.stats(a)
	draining := 0
	if web.is_draining(a) {
		draining = 1
	}
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	fmt.sbprintfln(&b, "druse_snapshot %d", SNAPSHOT_SCHEMA)
	fmt.sbprintfln(&b, "pid %d", os.get_pid())
	fmt.sbprintfln(&b, "unix_ns %d", time.now()._nsec)
	fmt.sbprintfln(&b, "draining %d", draining)
	fmt.sbprintfln(&b, "refused_connections %d", s.refused_connections)
	fmt.sbprintfln(&b, "saturation_refusals %d", s.saturation_refusals)
	fmt.sbprintfln(&b, "responses_sent %d", s.responses_sent)
	fmt.sbprintfln(&b, "response_bytes %d", s.response_bytes)
	fmt.sbprintfln(&b, "send_errors %d", s.send_errors)
	fmt.sbprintfln(&b, "write_deadline_aborts %d", s.write_deadline_aborts)
	fmt.sbprintfln(&b, "handler_dwell_ns %d", s.handler_dwell_ns)
	fmt.sbprintfln(&b, "stream_refused_full %d", s.stream_refused_full)
	fmt.sbprintfln(&b, "stream_refused_budget %d", s.stream_refused_budget)
	fmt.sbprintfln(&b, "stream_aborted_slow %d", s.stream_aborted_slow)
	fmt.sbprintfln(&b, "end")
	if os.write_entire_file(SNAPSHOT_TMP, transmute([]u8)strings.to_string(b)) != nil {
		return false
	}
	return os.rename(SNAPSHOT_TMP, SNAPSHOT_PATH) == nil
}

export_thread :: proc() {
	for sync.atomic_load(&g_export_stop) == 0 {
		if export_once(&target) {
			sync.atomic_add(&g_export_ticks, 1)
		}
		time.sleep(EXPORT_PERIOD)
	}
}

// ---------------------------------------------------------------------------
// The samplers
// ---------------------------------------------------------------------------

// sample_http performs one scrape and classifies the outcome into the taxonomy.
//
// The four HTTP causes are separated rather than collapsed into "error" for the
// same reason the C-03 RST probe separates them: an admission refusal accepts
// the TCP connection and then closes it having written nothing, and a client
// that only counts errors cannot tell that from a backlog drop. Separating them
// is what makes the ambiguity that remains VISIBLE — because all four are still
// producible by a lost packet, which is the finding.
sample_http :: proc(port: int) -> Cause {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	sock, derr := net.dial_tcp(ep)
	if derr != nil {
		return .Http_Refused
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, SAMPLE_TIMEOUT)
	_ = net.set_option(sock, .Send_Timeout, SAMPLE_TIMEOUT)
	req := transmute([]u8)string(
		"GET /stats HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
	)
	sent := 0
	for sent < len(req) {
		n, serr := net.send_tcp(sock, req[sent:])
		if serr != nil || n <= 0 {
			return .Http_Recv_Error
		}
		sent += n
	}
	reply: [4096]u8
	n, rerr := net.recv_tcp(sock, reply[:])
	if rerr != nil {
		// A receive that expired against the deadline is a timeout; anything
		// else is a receive error. They are different operational stories: one
		// says "nothing answered", the other says "the connection broke".
		if rerr == net.TCP_Recv_Error.Timeout {
			return .Http_Timeout
		}
		return .Http_Recv_Error
	}
	if n == 0 {
		return .Http_Empty
	}
	return .Ok
}

// sample_file reads the snapshot and classifies it. There is NO NETWORK on this
// path — criterion B4 — so none of the four ambiguous HTTP causes can occur, and
// the causes that remain all name the application: no file, an unreadable file,
// a malformed record, or a record too old. Every one of them says something
// about the process, which is what "distinguishable from network loss" means.
sample_file :: proc() -> Cause {
	data, rerr := os.read_entire_file(SNAPSHOT_PATH, context.temp_allocator)
	if rerr != nil {
		// The distinction the taxonomy insists on: a path that does not exist
		// is a deployment fault, a path that exists and will not open is an I/O
		// or permission fault. `os.exists` after a failed read is a small race
		// and an honest one — both answers name the application.
		if os.exists(SNAPSHOT_PATH) {
			return .Unreadable
		}
		return .Missing
	}
	text := string(data)
	if !strings.has_prefix(text, "druse_snapshot ") {
		return .Malformed
	}
	if !strings.has_suffix(strings.trim_right_space(text), "end") {
		return .Malformed
	}
	schema_line := text[len("druse_snapshot "):]
	if idx := strings.index_byte(schema_line, '\n'); idx >= 0 {
		schema_line = schema_line[:idx]
	}
	schema, sok := strconv.parse_int(strings.trim_space(schema_line), 10)
	if !sok || schema != SNAPSHOT_SCHEMA {
		return .Malformed
	}
	stamp, found := snapshot_field(text, "unix_ns")
	if !found {
		return .Malformed
	}
	age := time.now()._nsec - stamp
	if age > i64(MAX_AGE) {
		return .Stale
	}
	return .Ok
}

snapshot_field :: proc(text: string, key: string) -> (i64, bool) {
	prefix := strings.concatenate({key, " "}, context.temp_allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.has_prefix(line, prefix) {
			value, ok := strconv.parse_i64(strings.trim_space(line[len(prefix):]), 10)
			return value, ok
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// The driver
// ---------------------------------------------------------------------------

hold_client :: proc() {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = TARGET_PORT}
	sock, derr := net.dial_tcp(ep)
	if derr != nil {
		return
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, 120 * time.Second)
	req := transmute([]u8)string(
		"GET /hold HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
	)
	sent := 0
	for sent < len(req) {
		n, serr := net.send_tcp(sock, req[sent:])
		if serr != nil || n <= 0 {
			return
		}
		sent += n
	}
	reply: [512]u8
	_, _ = net.recv_tcp(sock, reply[:])
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

main :: proc() {
	arm := "baseline"
	if len(os.args) > 1 {
		arm = os.args[1]
	}
	if arm != "baseline" && arm != "arm-a" && arm != "arm-b" {
		fmt.eprintfln("usage: %s [baseline|arm-a|arm-b]", os.args[0])
		os.exit(2)
	}

	target = web.app()
	defer web.destroy(&target)
	limits := web.DEFAULT_LIMITS
	limits.max_handlers = LANES
	limits.max_connections = 256
	limits.reserved_conns = 16
	limits.max_write_time = i64(5 * time.Second)
	web.limits(&target, limits)
	web.get(&target, "/hold", hold)
	web.get(&target, "/tiny", tiny)
	web.get(&target, "/stats", stats_route)
	target_t := thread.create_and_start(target_thread)

	if !wait_until_accepting(TARGET_PORT) {
		fmt.eprintfln("FATAL: target server never accepted on %d", TARGET_PORT)
		os.exit(1)
	}

	admin_t: ^thread.Thread
	export_t: ^thread.Thread
	switch arm {
	case "arm-a":
		// A SECOND App: its own acceptor, its own lanes, its own admission
		// budget. Two lanes, not four — an admin listener that costs as much as
		// the application is not an admin listener, and the resource question
		// (an io_uring ring per lane against RLIMIT_MEMLOCK) is exactly the one
		// ADR-049 says N processes will multiply.
		admin = web.app()
		al := web.DEFAULT_LIMITS
		al.max_handlers = 2
		al.max_connections = 32
		al.reserved_conns = 4
		web.limits(&admin, al)
		web.get(&admin, "/stats", proc(ctx: ^web.Context) {
			web.ok(ctx, web.stats(&target))
		})
		admin_t = thread.create_and_start(admin_thread)
		if !wait_until_accepting(ADMIN_PORT) {
			fmt.eprintfln("FATAL: admin server never accepted on %d", ADMIN_PORT)
			os.exit(1)
		}
	case "arm-b":
		os.remove(SNAPSHOT_PATH)
		export_t = thread.create_and_start(export_thread)
		// One period plus slack, so the first sample reads a real snapshot
		// rather than measuring the exporter's startup.
		time.sleep(EXPORT_PERIOD + 100 * time.Millisecond)
	}

	// Establish the precondition BEFORE sampling. A run that never reaches full
	// occupancy has measured nothing, and the pre-registration calls that VOID
	// rather than red.
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
	fmt.printfln("arm %s", arm)
	fmt.printfln("lanes %d", LANES)
	fmt.printfln("occupied %v entered=%d", occupied, sync.atomic_load(&g_hold_entered))
	if !occupied {
		fmt.printfln("verdict VOID saturation-precondition-not-established")
		sync.atomic_store(&g_release, 1)
		os.exit(3)
	}

	counts: [Cause]int
	latencies := make([dynamic]i64, 0, SAMPLES)
	defer delete(latencies)
	for i in 0 ..< SAMPLES {
		start := time.tick_now()
		cause: Cause
		switch arm {
		case "baseline": cause = sample_http(TARGET_PORT)
		case "arm-a":    cause = sample_http(ADMIN_PORT)
		case "arm-b":    cause = sample_file()
		}
		elapsed := i64(time.tick_since(start))
		counts[cause] += 1
		if cause == .Ok {
			append(&latencies, elapsed)
		}
		fmt.printfln(
			"sample %d %s %d %v",
			i,
			cause_name(cause),
			elapsed,
			cause_is_network_ambiguous(cause),
		)
		free_all(context.temp_allocator)
		time.sleep(SAMPLE_INTERVAL)
	}

	// Release the lanes and shut everything down before printing the summary, so
	// a hung teardown cannot be mistaken for a clean run.
	sync.atomic_store(&g_release, 1)
	for i in 0 ..< LANES {
		thread.join(holds[i])
		thread.destroy(holds[i])
	}
	if export_t != nil {
		sync.atomic_store(&g_export_stop, 1)
		thread.join(export_t)
		thread.destroy(export_t)
	}
	web.stop(&target)
	thread.join(target_t)
	thread.destroy(target_t)
	if admin_t != nil {
		web.stop(&admin)
		thread.join(admin_t)
		thread.destroy(admin_t)
		web.destroy(&admin)
	}

	ok_count := counts[.Ok]
	fmt.printfln("samples %d", SAMPLES)
	fmt.printfln("ok %d", ok_count)
	for c in Cause {
		fmt.printfln("cause %s %d", cause_name(c), counts[c])
	}
	unclassified := SAMPLES
	for c in Cause {
		unclassified -= counts[c]
	}
	fmt.printfln("unclassified %d", unclassified)
	ambiguous := 0
	for c in Cause {
		if cause_is_network_ambiguous(c) {
			ambiguous += counts[c]
		}
	}
	fmt.printfln("network_ambiguous_absences %d", ambiguous)
	fmt.printfln("availability_ppm %d", (ok_count * 1_000_000) / SAMPLES)
	if len(latencies) > 0 {
		slice.sort(latencies[:])
		p50 := latencies[len(latencies) * 50 / 100]
		idx99 := len(latencies) * 99 / 100
		if idx99 >= len(latencies) {
			idx99 = len(latencies) - 1
		}
		fmt.printfln("latency_p50_ns %d", p50)
		fmt.printfln("latency_p99_ns %d", latencies[idx99])
		fmt.printfln("latency_max_ns %d", latencies[len(latencies) - 1])
	} else {
		fmt.printfln("latency_p50_ns -1")
		fmt.printfln("latency_p99_ns -1")
		fmt.printfln("latency_max_ns -1")
	}
	if arm == "arm-b" {
		fmt.printfln("export_ticks %d", sync.atomic_load(&g_export_ticks))
	}
	// B7: the lane cost of the export mechanism. Only `/hold` and the scrapes
	// themselves ran handlers, so any dwell attributable to the exporter would
	// have to appear here — and the exporter never touches a lane.
	final := web.stats(&target)
	fmt.printfln("target_handler_dwell_ns %d", final.handler_dwell_ns)
	fmt.printfln("target_responses_sent %d", final.responses_sent)
	fmt.printfln("target_saturation_refusals %d", final.saturation_refusals)
	fmt.printfln("verdict COMPLETE")
}
