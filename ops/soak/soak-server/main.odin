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
import "core:sys/posix"
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

stats :: proc(ctx: ^web.Context) {
	web.ok(ctx, web.stats())
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
	web.serve(&app, port)
}

