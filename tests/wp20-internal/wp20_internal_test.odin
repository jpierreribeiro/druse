// WP20 internal behavior tests — the typed framework-error observer:
// `observe`, `Framework_Event`, and the now-public `Framework_Error`.
//
// This file declares `package web` but does NOT live in `web/`: the emit
// helpers, the Context-carried observer slot and the recorded route pattern
// are package-private, and `build/check.sh` assembles the usual THROWAWAY
// package from the real `web/` sources plus this file (the WP2-WP19
// arrangement).
//
// Every test here DELIBERATELY triggers a framework diagnostic, so each
// installs the capture logger — which captures `druse:` Error lines and
// FORWARDS everything else, because `testing.expect` reports through
// `context.logger` and a swallow-everything logger makes a test unable to
// fail (the defect WP17's mutation control 6 caught).
#+private
package web

import "base:runtime"
import "core:mem"
import "core:testing"
import transport "druse:web/internal/transport"

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

@(private = "file")
Wp20_Sink :: struct {
	events:  [8]Framework_Event,
	n:       int,
	log_buf: [512]u8,
	log_n:   int,
	inner:   runtime.Logger,
}

// The observer under test. It is a top-level procedure of the ratified shape —
// it receives the EVENT and nothing else — so it reaches the test's sink
// through `context.user_ptr`, exactly as the WP17/WP18 middleware harnesses do.
//
// Note what this signature makes IMPOSSIBLE: an observer has no `^Context`, so
// it cannot respond, cannot read the body, and cannot reach a request byte
// that the event does not carry. That is stronger than the single-commit
// guard, and it is a property of the accepted shape (ADR-026), not of this
// test.
@(private = "file")
wp20_record :: proc(event: Framework_Event) {
	sink := (^Wp20_Sink)(context.user_ptr)
	if sink == nil {
		return
	}
	if sink.n < len(sink.events) {
		sink.events[sink.n] = event
		sink.n += 1
	}
}

@(private = "file")
wp20_second_observer :: proc(event: Framework_Event) {
	sink := (^Wp20_Sink)(context.user_ptr)
	if sink == nil {
		return
	}
	// Marks itself distinguishably: a `Bad_Request` status can never be
	// produced by the failures under test, so its presence identifies WHICH
	// observer ran (last-wins).
	if sink.n < len(sink.events) {
		event_copy := event
		event_copy.status = .Bad_Request
		sink.events[sink.n] = event_copy
		sink.n += 1
	}
}

@(private = "file")
wp20_capture_logger_proc :: proc(
	data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options,
	location := #caller_location,
) {
	sink := (^Wp20_Sink)(data)
	if level == .Error && wp20_contains(text, "druse:") {
		for i in 0 ..< len(text) {
			if sink.log_n < len(sink.log_buf) {
				sink.log_buf[sink.log_n] = text[i]
				sink.log_n += 1
			}
		}
		return
	}
	if sink.inner.procedure != nil {
		sink.inner.procedure(sink.inner.data, level, text, options, location)
	}
}

@(private = "file")
wp20_capture_logger :: proc(sink: ^Wp20_Sink) -> runtime.Logger {
	sink.inner = context.logger
	return runtime.Logger {
		procedure    = wp20_capture_logger_proc,
		data         = sink,
		lowest_level = .Debug,
		options      = context.logger.options,
	}
}

@(private = "file")
wp20_contains :: proc(haystack: string, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(haystack) < len(needle) {
		return false
	}
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i + len(needle)] == needle {
			return true
		}
	}
	return false
}

@(private = "file")
wp20_run :: proc(a: ^App, ctx: ^Context, method: Method, path: string, body_bytes: string = "") {
	driver_run(
		a,
		ctx,
		transport.Inbound{
			method = method_token(method),
			path = path,
			body = transmute([]u8)body_bytes,
		},
	)
}

// ---------------------------------------------------------------------------
// Handlers that provoke exactly one framework failure each.
// ---------------------------------------------------------------------------

@(private = "file")
Wp20_User :: struct {
	id: int,
}

// A destination the pinned decoder cannot support (a pointer field), which is
// the `Unsupported_Type` branch — a decoder/destination fault, never the
// client's malformed JSON.
@(private = "file")
Wp20_Hostile :: struct {
	p: ^int,
}

@(private = "file")
wp20_h_marshal_failure :: proc(ctx: ^Context) {
	user := Wp20_User{id = 1}
	// ADR-003 is value-only: a pointer payload is rejected by the marshaller.
	json(ctx, .OK, &user)
}

@(private = "file")
wp20_h_decode_failure :: proc(ctx: ^Context) {
	dst: Wp20_Hostile
	if !body(ctx, &dst) {
		return
	}
	no_content(ctx)
}

@(private = "file")
wp20_h_double_body :: proc(ctx: ^Context) {
	first: Wp20_User
	_ = body(ctx, &first)
	second: Wp20_User
	_ = body(ctx, &second)
}

@(private = "file")
wp20_h_silent :: proc(ctx: ^Context) {
	// Commits nothing: the driver finalizes it to the standard 500.
}

@(private = "file")
wp20_h_ok :: proc(ctx: ^Context) {
	text(ctx, .OK, "ok")
}

// ---------------------------------------------------------------------------
// 1. Every triggerable variant is observed EXACTLY ONCE, with the right fields
// ---------------------------------------------------------------------------

@(test)
wp20_marshal_failure_is_observed_once :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	observe(&a, wp20_record)
	get(&a, "/users/:id", wp20_h_marshal_failure)

	ctx: Context
	wp20_run(&a, &ctx, .GET, "/users/42")
	driver_cleanup(&ctx)

	testing.expect_value(t, sink.n, 1)
	testing.expect_value(t, sink.events[0].kind, Framework_Error.Response_Marshal_Failed)
	testing.expect_value(t, sink.events[0].method, Method.GET)
	// LOW-CARDINALITY route identity: the REGISTERED PATTERN, never the raw
	// path (§6.2 / OpenTelemetry http.route).
	testing.expect_value(t, sink.events[0].route, "/users/:id")
	testing.expect_value(t, sink.events[0].status, Status.Internal_Server_Error)
	testing.expect_value(t, sink.events[0].payload_type, typeid_of(^Wp20_User))
}

@(test)
wp20_decode_failure_is_observed_once :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	observe(&a, wp20_record)
	post(&a, "/items", wp20_h_decode_failure)

	ctx: Context
	wp20_run(&a, &ctx, .POST, "/items", `{"p":1}`)
	driver_cleanup(&ctx)

	testing.expect_value(t, sink.n, 1)
	testing.expect_value(t, sink.events[0].kind, Framework_Error.Body_Decode_Failed)
	testing.expect_value(t, sink.events[0].method, Method.POST)
	testing.expect_value(t, sink.events[0].route, "/items")
	testing.expect_value(t, sink.events[0].status, Status.Internal_Server_Error)
	testing.expect_value(t, sink.events[0].payload_type, typeid_of(Wp20_Hostile))
}

@(test)
wp20_double_body_is_observed_once :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	observe(&a, wp20_record)
	post(&a, "/items", wp20_h_double_body)

	ctx: Context
	wp20_run(&a, &ctx, .POST, "/items", `{"id":1}`)
	driver_cleanup(&ctx)

	testing.expect_value(t, sink.n, 1)
	testing.expect_value(t, sink.events[0].kind, Framework_Error.Body_Consumed_Twice)
	testing.expect_value(t, sink.events[0].route, "/items")
}

@(test)
wp20_missing_response_is_observed_once :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	observe(&a, wp20_record)
	get(&a, "/silent", wp20_h_silent)

	ctx: Context
	wp20_run(&a, &ctx, .GET, "/silent")
	driver_cleanup(&ctx)

	testing.expect_value(t, sink.n, 1)
	testing.expect_value(t, sink.events[0].kind, Framework_Error.No_Response_Committed)
	testing.expect_value(t, sink.events[0].route, "/silent")
	// The status the framework COMMITTED for this failure — read after the
	// commit, so it is the truth rather than a prediction.
	testing.expect_value(t, sink.events[0].status, Status.Internal_Server_Error)
}

@(test)
wp20_invalid_serve_port_is_observed_once :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	observe(&a, wp20_record)
	get(&a, "/x", wp20_h_ok)

	// `serve` validates the port and returns WITHOUT binding.
	serve(&a, 0)

	testing.expect_value(t, sink.n, 1)
	testing.expect_value(t, sink.events[0].kind, Framework_Error.Invalid_Serve_Port)
	// No request produced this failure, so there is no method, no route and no
	// committed status: the event says so rather than inventing values.
	testing.expect_value(t, sink.events[0].method, Method.UNKNOWN)
	testing.expect_value(t, sink.events[0].route, "")
	testing.expect_value(t, sink.events[0].status, Status(0))
}

@(test)
wp20_use_after_route_is_observed_once :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	observe(&a, wp20_record)
	get(&a, "/admin", wp20_h_ok)
	use(&a, wp20_mw_noop) // poisons the App (ADR-019)

	// `serve` refuses to start on a poisoned application and reports it.
	serve(&a, 8080)

	testing.expect_value(t, sink.n, 1)
	testing.expect_value(t, sink.events[0].kind, Framework_Error.Use_After_Route)
	testing.expect_value(t, sink.events[0].route, "")
}

@(private = "file")
wp20_mw_noop :: proc(ctx: ^Context) {
	next(ctx)
}

// ---------------------------------------------------------------------------
// 2. Route identity: the pattern, or nothing at all
// ---------------------------------------------------------------------------

@(test)
wp20_a_miss_carries_no_route :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	// `bare()` commits nothing on a miss, so the driver finalizes a 500 — a
	// framework failure on a request that matched NO route.
	a := bare()
	defer destroy(&a)
	observe(&a, wp20_record)
	get(&a, "/known", wp20_h_ok)

	ctx: Context
	wp20_run(&a, &ctx, .GET, "/nope")
	driver_cleanup(&ctx)

	testing.expect_value(t, sink.n, 1)
	testing.expect_value(t, sink.events[0].kind, Framework_Error.No_Response_Committed)
	// §6.2, HARD: on a miss there is no route, so `route` is "" — populated by
	// nothing, NEVER by the request path.
	testing.expect_value(t, sink.events[0].route, "")
	testing.expect(
		t,
		!wp20_contains(sink.events[0].route, "nope"),
		"the raw request path must never reach the event",
	)
}

@(test)
wp20_route_is_the_pattern_for_every_parametric_path :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	observe(&a, wp20_record)
	get(&a, "/orders/:id", wp20_h_silent)

	// Two different high-cardinality paths must produce the SAME low-
	// cardinality route identity — the whole point of pattern-only identity.
	ctx1: Context
	wp20_run(&a, &ctx1, .GET, "/orders/1")
	driver_cleanup(&ctx1)
	ctx2: Context
	wp20_run(&a, &ctx2, .GET, "/orders/999999")
	driver_cleanup(&ctx2)

	testing.expect_value(t, sink.n, 2)
	testing.expect_value(t, sink.events[0].route, "/orders/:id")
	testing.expect_value(t, sink.events[1].route, "/orders/:id")
}

@(test)
wp20_the_event_survives_the_request_by_value :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	observe(&a, wp20_record)
	get(&a, "/orders/:id", wp20_h_silent)

	ctx: Context
	wp20_run(&a, &ctx, .GET, "/orders/7")
	driver_cleanup(&ctx)

	// The event was passed BY VALUE and its only string is an App-owned
	// pattern, so a stored copy stays readable after the request is torn down
	// — an observer that keeps events cannot dangle (§6.2).
	testing.expect_value(t, sink.events[0].route, "/orders/:id")
	testing.expect_value(t, sink.events[0].kind, Framework_Error.No_Response_Committed)
}

// ---------------------------------------------------------------------------
// 3. Registration semantics and parity
// ---------------------------------------------------------------------------

@(test)
wp20_last_observer_wins :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	observe(&a, wp20_record)
	observe(&a, wp20_second_observer) // replaces the first
	get(&a, "/silent", wp20_h_silent)

	ctx: Context
	wp20_run(&a, &ctx, .GET, "/silent")
	driver_cleanup(&ctx)

	// Exactly one observer ran, and it was the SECOND (its marker status).
	testing.expect_value(t, sink.n, 1)
	testing.expect_value(t, sink.events[0].status, Status.Bad_Request)
}

@(test)
wp20_no_observer_behaves_exactly_as_before :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	// No `observe` call at all: the failure is still logged and still answered
	// identically, and nothing is emitted.
	a := app()
	defer destroy(&a)
	get(&a, "/silent", wp20_h_silent)

	ctx: Context
	wp20_run(&a, &ctx, .GET, "/silent")

	testing.expect_value(t, sink.n, 0)
	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
	testing.expect_value(t, string(ctx.private.response.body), ERROR_BODY_INTERNAL)
	testing.expect(
		t,
		wp20_contains(wp20_logged(&sink), "druse:"),
		"the framework diagnostic must still be logged when no observer is registered",
	)

	driver_cleanup(&ctx)
}

@(private = "file")
wp20_logged :: proc(sink: ^Wp20_Sink) -> string {
	return string(sink.log_buf[:sink.log_n])
}

@(test)
wp20_bare_installs_no_observer :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	// `bare()` installs nothing, observer included; a failure under it is
	// logged and finalized exactly as always, with no emission.
	a := bare()
	defer destroy(&a)
	get(&a, "/silent", wp20_h_silent)

	ctx: Context
	wp20_run(&a, &ctx, .GET, "/silent")
	driver_cleanup(&ctx)

	testing.expect_value(t, sink.n, 0)
}

@(test)
wp20_an_observed_response_is_byte_identical_to_an_unobserved_one :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	// The response a client receives must not depend on whether an observer is
	// installed — observation is a side channel, never a response writer.
	observed := app()
	defer destroy(&observed)
	observe(&observed, wp20_record)
	get(&observed, "/boom", wp20_h_marshal_failure)

	plain := app()
	defer destroy(&plain)
	get(&plain, "/boom", wp20_h_marshal_failure)

	ctx_observed: Context
	wp20_run(&observed, &ctx_observed, .GET, "/boom")
	ctx_plain: Context
	wp20_run(&plain, &ctx_plain, .GET, "/boom")

	testing.expect_value(t, ctx_observed.private.response.status, ctx_plain.private.response.status)
	testing.expect_value(
		t,
		string(ctx_observed.private.response.body),
		string(ctx_plain.private.response.body),
	)
	testing.expect_value(t, sink.n, 1)

	driver_cleanup(&ctx_observed)
	driver_cleanup(&ctx_plain)
}

// ---------------------------------------------------------------------------
// 4. Cost
// ---------------------------------------------------------------------------

@(test)
wp20_observing_allocates_zero :: proc(t: ^testing.T) {
	sink: Wp20_Sink
	context.user_ptr = &sink
	context.logger = wp20_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	observe(&a, wp20_record)
	get(&a, "/silent", wp20_h_silent)

	warm: Context
	wp20_run(&a, &warm, .GET, "/silent")
	driver_cleanup(&warm)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	temp_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&temp_track, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&temp_track)

	context.allocator = mem.tracking_allocator(&track)
	context.temp_allocator = mem.tracking_allocator(&temp_track)

	ctx: Context
	wp20_run(&a, &ctx, .GET, "/silent")
	driver_cleanup(&ctx)

	// The event is a value passed through a procedure pointer: no allocation,
	// on either allocator.
	testing.expect_value(t, sink.n, 2)
	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect_value(t, temp_track.total_allocation_count, 0)
}
