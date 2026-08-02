// The soak system under test.
//
// DIAGNOSABILITY (planning/diagnosability.md). The previous version of this
// program installed neither a logger nor an observer, so every framework
// diagnostic emitted during a 12-hour run was discarded twice over —
// `framework_report` returns early when `context.logger.procedure == nil`, and
// with no `web.observe` the typed `Framework_Event` had nowhere to go either.
// `server.log` was 0 bytes in every recorded run for that reason, and a
// diagnostic that reaches no file cannot be part of any verdict.
package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"
import web "druse:web"

KIB :: 1024
MIB :: 1024 * KIB

Medium_Item :: struct {
	id:     int     `json:"id"`,
	name:   string  `json:"name"`,
	score:  f64     `json:"score"`,
	active: bool    `json:"active"`,
}

Medium_Document :: struct {
	request_id: string        `json:"request_id"`,
	items:      []Medium_Item `json:"items"`,
	tags:       []string      `json:"tags"`,
}

medium_items: [64]Medium_Item
medium_tags := [6]string{"alpha", "beta", "gamma", "delta", "epsilon", "zeta"}
app: web.App

on_signal :: proc "c" (_: posix.Signal) {
	context = runtime.default_context()
	web.stop(&app)
}

arg_int :: proc(index, fallback: int) -> int {
	if len(os.args) <= index {
		return fallback
	}
	value, ok := strconv.parse_int(os.args[index], 10)
	return value if ok else fallback
}

health :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

tiny :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

json_medium_get :: proc(ctx: ^web.Context) {
	web.ok(ctx, Medium_Document {
		request_id = "req-0123456789abcdef",
		items = medium_items[:],
		tags = medium_tags[:],
	})
}

json_medium_decode :: proc(ctx: ^web.Context) {
	input: Medium_Document
	if !web.body(ctx, &input) {
		return
	}
	web.no_content(ctx)
}

fill_response :: proc(ctx: ^web.Context, size: int) {
	body, err := make([]u8, size, context.temp_allocator)
	if err != nil {
		web.text(ctx, .Internal_Server_Error, "allocation failed")
		return
	}
	for index in 0 ..< len(body) {
		body[index] = u8('a' + index % 23)
	}
	web.bytes(ctx, .OK, "application/octet-stream", body)
}

bytes_64k :: proc(ctx: ^web.Context) {
	fill_response(ctx, 64 * KIB)
}

bytes_1m :: proc(ctx: ^web.Context) {
	fill_response(ctx, MIB)
}

wait_40ms :: proc(ctx: ^web.Context) {
	time.sleep(40 * time.Millisecond)
	web.text(ctx, .OK, "done")
}

// The route the soak sampler has always scraped, kept because R2-WP01's
// classification of curl exit codes is built on it and because the 1.3% of
// scrapes it loses under saturation is the FINDING — removing the route would
// remove the evidence.
stats :: proc(ctx: ^web.Context) {
	web.ok(ctx, web.stats(&app))
}

// ---------------------------------------------------------------------------
// R2-WP03 / ADR-050 — the out-of-band exporter.
//
// AUD-P2-009 in one sentence: `/stats` above is an ordinary route on the same
// lanes as the load, so in the recorded twelve-hour run 111 of 8,611 scrapes
// produced nothing under saturation — and an absent scrape is indistinguishable
// from a lost packet at the sampler.
//
// This thread owns no lane. `web.stats` allocates nothing, takes no lock and
// reads atomics, so it costs the measured resource nothing, and there is no
// network between the file and its reader, so an absent snapshot can only mean
// this process. Both paths are live during a soak ON PURPOSE: the HTTP scrape
// keeps producing the finding, and the snapshot is what explains it.
// ---------------------------------------------------------------------------

exporter: ^thread.Thread
snapshot_path: string

EXPORT_PERIOD :: 1 * time.Second

export_loop :: proc() {
	for {
		draining := web.is_draining(&app)
		write_snapshot(draining)
		if draining {
			// One final record carrying `draining 1`, so a drain shorter than
			// the export period still lands on the timeline. A deploy that
			// leaves no trace is a deploy nobody can correlate against.
			return
		}
		time.sleep(EXPORT_PERIOD)
	}
}

write_snapshot :: proc(draining: bool) {
	s := web.stats(&app)
	// DO NOT OVERWRITE A REAL RECORD WITH ZEROES. `web.stats` returns the zero
	// value once the App is no longer running a server, which is exactly the
	// state the final drain write can land in: `serve` returns, the exporter
	// wakes, and every counter reads 0. Writing that would publish a counter
	// RESET — and a reset is what this system tells operators to read as a
	// restart. `handler_capacity` is 0 only when no server is running (a running
	// server always has at least one lane), so it is the cheap test for it.
	//
	// Leaving the previous record in place is the honest outcome: it ages past
	// max_age, reads as `stale`, and then as `no_process` once the pid is gone.
	// Every one of those says something true.
	if s.handler_capacity == 0 {
		return
	}
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	fmt.sbprintfln(&b, "druse_snapshot 1")
	fmt.sbprintfln(&b, "pid %d", os.get_pid())
	fmt.sbprintfln(&b, "unix_ns %d", time.now()._nsec)
	fmt.sbprintfln(&b, "draining %d", 1 if draining else 0)
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
	fmt.sbprintfln(&b, "active_connections %d", s.active_connections)
	fmt.sbprintfln(&b, "handlers_active %d", s.handlers_active)
	fmt.sbprintfln(&b, "handler_capacity %d", s.handler_capacity)
	fmt.sbprintfln(&b, "connection_capacity %d", s.connection_capacity)
	fmt.sbprintfln(&b, "end")

	tmp := strings.concatenate({snapshot_path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]u8)strings.to_string(b)) != nil {
		return
	}
	// A failed rename leaves the PREVIOUS record in place, which ages past
	// max_age and reads as `stale`. It is never a fresh-looking record holding
	// old numbers — which is the failure the whole temp-then-rename exists to
	// make impossible.
	_ = os.rename(tmp, snapshot_path)
	free_all(context.temp_allocator)
}

// on_framework_event is the second half of the diagnostic path, and the half
// that does not depend on `context.logger` at all. Every line is one event, on
// stdout, which the orchestrator captures to `server.log`. A framework failure
// that used to vanish now costs one line naming the kind, the route and the
// status the client was given.
on_framework_event :: proc(event: web.Framework_Event) {
	fmt.printfln(
		"framework_event kind=%v method=%v route=%q status=%v payload_type=%v",
		event.kind,
		event.method,
		event.route,
		event.status,
		event.payload_type,
	)
}

main :: proc() {
	for index in 0 ..< len(medium_items) {
		medium_items[index] = Medium_Item {
			id = index + 1,
			name = "item-abcdefghijklmnop",
			score = f64(index) + 1.5,
			active = true,
		}
	}

	// A logger, first, because without one every `framework_report` in the
	// framework returns without writing. Odin installs none by default, so this
	// single line is the difference between a run that records its own failures
	// and a run that cannot.
	// `.Warning`, not `.Debug`: every framework diagnostic goes out at `.Error`
	// (`web/errors.odin`), while the vendored transport logs two `.Debug` lines
	// per closed connection. At 15,000 requests per second that debug stream
	// would measure the logger instead of the framework — a run whose
	// instrument dominates its subject is not evidence.
	context.logger = log.create_console_logger(
		lowest = .Warning,
		opt = {.Level, .Short_File_Path, .Line, .Procedure},
	)
	defer log.destroy_console_logger(context.logger)

	lanes := arg_int(1, 4)
	port := arg_int(2, 8080)
	app = web.app()
	defer web.destroy(&app)

	// The observer is independent of the logger: it is a typed callback, so it
	// survives even if somebody removes the line above. Both are installed on
	// purpose — the run should not depend on one of them being remembered.
	web.observe(&app, on_framework_event)

	limits := web.DEFAULT_LIMITS
	limits.max_handlers = lanes
	limits.max_connections = 4096
	limits.reserved_conns = 64
	limits.max_response_bytes = 4 * MIB
	limits.max_write_time = i64(5 * time.Second)
	limits.max_idle_time = i64(30 * time.Second)
	limits.max_drain_time = i64(10 * time.Second)
	web.limits(&app, limits)

	// `request_id` before any route: it is the only identity a server-side line
	// and a client-side failure could ever be joined on. `web.logger` is
	// deliberately NOT installed — one log line per request at 15,000 requests
	// per second would measure the logger, not the framework.
	web.use(&app, web.request_id)

	web.get(&app, "/health", health)
	web.get(&app, "/tiny", tiny)
	web.get(&app, "/json/medium", json_medium_get)
	web.post(&app, "/json/medium/decode", json_medium_decode)
	web.get(&app, "/bytes/64k", bytes_64k)
	web.get(&app, "/bytes/1m", bytes_1m)
	web.get(&app, "/wait/40ms", wait_40ms)
	web.get(&app, "/stats", stats)

	posix.signal(.SIGTERM, on_signal)
	posix.signal(.SIGINT, on_signal)

	// argv[3], optional: where to write the out-of-band snapshot. Optional
	// rather than mandatory because `run-soak.sh` fixtures and the eight
	// committed reference artefacts predate it, and a soak-server that refuses
	// to start without a new argument would invalidate every one of them.
	if len(os.args) > 3 && len(os.args[3]) > 0 {
		snapshot_path = os.args[3]
		exporter = thread.create_and_start(export_loop)
	}
	web.serve(&app, port)
	if exporter != nil {
		// `serve` has returned, so the drain is over and `export_loop` has
		// written its final record and returned. Join before exit so that record
		// cannot lose a race with process teardown.
		thread.join(exporter)
		thread.destroy(exporter)
	}
}

