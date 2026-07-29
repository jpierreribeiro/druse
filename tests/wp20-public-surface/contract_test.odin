// WP20 public surface contract — `observe`, `Framework_Event` and the
// now-public `Framework_Error`, as an EXTERNAL consumer of `druse:web` sees
// them.
//
// The redaction constraint (§6.2) is enforced BY TYPE, and this suite is where
// that is visible from outside: an observer receives a `Framework_Event` by
// value and nothing else — no `^Context`, no body, no headers — so it cannot
// respond, cannot read a request byte the event does not carry, and cannot
// dangle. The gate additionally pins the field set so a future `path: string`
// cannot be added (build/check_public_api.sh).
package test_wp20_public

import "core:log"
import "core:strings"
import "core:testing"
import web "druse:web"

// The quiet-logger idiom (WP17/WP18/WP19): these tests deliberately trigger
// framework diagnostics, and the runner records Error-level output as a
// failure, so the expected `druse:` lines are swallowed and everything else
// is forwarded.
Quiet :: struct {
	inner: log.Logger,
}

quiet_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Quiet)(data)
	if level == .Error && strings.contains(text, "druse:") {
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

quiet_logger :: proc(record: ^Quiet) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = quiet_logger_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

Telemetry :: struct {
	count:      int,
	last_kind:  web.Framework_Error,
	last_route: string,
	last_status: web.Status,
	last_method: web.Method,
}

// The canonical observer: a plain procedure taking the event by value. It
// receives NOTHING else — that is the redaction guarantee, expressed as a
// signature.
record_event :: proc(event: web.Framework_Event) {
	sink := (^Telemetry)(context.user_ptr)
	if sink == nil {
		return
	}
	sink.count += 1
	sink.last_kind = event.kind
	sink.last_route = event.route
	sink.last_status = event.status
	sink.last_method = event.method
}

silent_handler :: proc(ctx: ^web.Context) {
	// Responds with nothing: the driver finalizes the standard 500.
}

ok_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

// ---------------------------------------------------------------------------
// The canonical shape.
// ---------------------------------------------------------------------------

@(test)
wp20_public_observer_sees_typed_failures :: proc(t: ^testing.T) {
	sink: Telemetry
	context.user_ptr = &sink
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	a := web.app()
	defer web.destroy(&a)
	web.observe(&a, record_event)
	web.get(&a, "/orders/:id", silent_handler)

	res := web.test_request(&a, .GET, "/orders/42")

	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
	testing.expect_value(t, sink.count, 1)
	testing.expect_value(t, sink.last_kind, web.Framework_Error.No_Response_Committed)
	testing.expect_value(t, sink.last_method, web.Method.GET)
	testing.expect_value(t, sink.last_status, web.Status.Internal_Server_Error)

	// LOW-CARDINALITY route identity: the registered pattern, never the path.
	testing.expect_value(t, sink.last_route, "/orders/:id")
	testing.expect(
		t,
		!strings.contains(sink.last_route, "42"),
		"the raw path must never reach the event (§6.2)",
	)
}

@(test)
wp20_public_a_healthy_request_emits_nothing :: proc(t: ^testing.T) {
	sink: Telemetry
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.observe(&a, record_event)
	web.get(&a, "/ping", ok_handler)

	res := web.test_request(&a, .GET, "/ping")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, sink.count, 0)
}

@(test)
wp20_public_a_404_is_not_a_framework_failure :: proc(t: ^testing.T) {
	sink: Telemetry
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.observe(&a, record_event)
	web.get(&a, "/ping", ok_handler)

	// An automatic 404 is a NORMAL outcome the framework produces on purpose,
	// not a framework-detected failure: nothing is emitted.
	res := web.test_request(&a, .GET, "/nope")

	testing.expect_value(t, res.status, web.Status.Not_Found)
	testing.expect_value(t, sink.count, 0)
}

@(test)
wp20_public_no_observer_is_identical_behaviour :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	observed := web.app()
	defer web.destroy(&observed)
	web.observe(&observed, record_event)
	web.get(&observed, "/silent", silent_handler)

	plain := web.app()
	defer web.destroy(&plain)
	web.get(&plain, "/silent", silent_handler)

	sink: Telemetry
	context.user_ptr = &sink
	with_observer := web.test_request(&observed, .GET, "/silent")
	without := web.test_request(&plain, .GET, "/silent")

	testing.expect_value(t, with_observer.status, without.status)
	testing.expect_value(t, with_observer.body, without.body)
	testing.expect_value(t, sink.count, 1)
}

// ---------------------------------------------------------------------------
// Shape.
// ---------------------------------------------------------------------------

@(test)
wp20_public_signatures_are_pinned :: proc(t: ^testing.T) {
	// Pinned as procedure VALUES (the WP7/WP17/WP18/WP19 precedent).
	observe_sig: proc(a: ^web.App, observer: proc(event: web.Framework_Event)) = web.observe

	// The observer shape itself is contract: it takes the event BY VALUE and
	// takes nothing else. A `^Context` parameter here would be a compile error
	// — which is exactly the redaction guarantee.
	observer_sig: proc(event: web.Framework_Event) = record_event

	a := web.app()
	defer web.destroy(&a)
	observe_sig(&a, observer_sig)

	// Every ratified field is readable, and the enum is a public closed set
	// whose members can be named from outside the package.
	event := web.Framework_Event {
		kind         = web.Framework_Error.None,
		method       = .GET,
		route        = "/x",
		status       = .OK,
		payload_type = typeid_of(int),
	}
	testing.expect_value(t, event.kind, web.Framework_Error.None)
	testing.expect_value(t, event.route, "/x")
	testing.expect_value(t, event.payload_type, typeid_of(int))

	// The members WP6-WP17 ratified, named from an external package.
	kinds := [8]web.Framework_Error {
		.None,
		.Response_Marshal_Failed,
		.Body_Decode_Failed,
		.Body_Consumed_Twice,
		.No_Response_Committed,
		.Invalid_Serve_Port,
		.Serve_Listen_Failed,
		.Use_After_Route,
	}
	testing.expect_value(t, len(kinds), 8)
}

@(test)
wp20_public_observed_app_tears_down_cleanly :: proc(t: ^testing.T) {
	// `odin test` tracks allocations by default: an observer is a procedure
	// pointer and must add no owned storage.
	quiet: Quiet
	context.logger = quiet_logger(&quiet)
	sink: Telemetry
	context.user_ptr = &sink

	a := web.app()
	web.observe(&a, record_event)
	web.get(&a, "/silent", silent_handler)
	_ = web.test_request(&a, .GET, "/silent")
	web.destroy(&a)
}
