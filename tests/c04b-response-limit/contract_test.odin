// C-04b — the per-response size limit, `max_response_bytes` (ADR-045).
//
// The ledger's RED test: RED before ADR-045 (a handler could build a response
// of any size and it was copied to the transport whole, the one framework-owned
// resource the C-02 matrix bounded nowhere), GREEN after — a body strictly
// larger than the limit is replaced with the standardized 500 BEFORE copy-out
// and reported as `Framework_Error.Response_Too_Large`, on the shared path so a
// test and a socket agree by construction (R-10).
//
// Driven through the public in-memory transport, exactly like the C1–C7 tests.
package test_c04b_response_limit

import "core:log"
import "core:strings"
import "core:testing"
import web "uruquim:web"

// The quiet-logger idiom (WP17–WP20): this suite deliberately triggers a
// framework diagnostic (the over-limit 500 logs at Error level), and the runner
// records Error output as a failure, so the expected `uruquim:` line is
// swallowed and everything else forwarded.
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
	if level == .Error && strings.contains(text, "uruquim:") {
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

quiet_logger :: proc(record: ^Quiet) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure    = quiet_logger_proc,
		data         = rawptr(record),
		lowest_level = .Debug,
		options      = context.logger.options,
	}
}

// The observer sink: a plain proc receives the event by value and records it
// through `context.user_ptr`, the WP20 idiom.
Telemetry :: struct {
	count:       int,
	last_kind:   web.Framework_Error,
	last_route:  string,
	last_status: web.Status,
}

record_event :: proc(event: web.Framework_Event) {
	sink := (^Telemetry)(context.user_ptr)
	if sink == nil {
		return
	}
	sink.count += 1
	sink.last_kind = event.kind
	sink.last_route = event.route
	sink.last_status = event.status
}

// A response of `size` bytes of 'a', built as an owned body through `web.bytes`.
// The size is chosen per test relative to the limit under exercise.
BIG :: 4096
SMALL :: 16

big_handler :: proc(ctx: ^web.Context) {
	buf := make([]u8, BIG, context.temp_allocator)
	for i in 0 ..< len(buf) {
		buf[i] = 'a'
	}
	web.bytes(ctx, .OK, "application/octet-stream", buf)
}

small_handler :: proc(ctx: ^web.Context) {
	buf := make([]u8, SMALL, context.temp_allocator)
	for i in 0 ..< len(buf) {
		buf[i] = 'a'
	}
	web.bytes(ctx, .OK, "application/octet-stream", buf)
}

limited_app :: proc(limit: int) -> web.App {
	a := web.app()
	budget := web.DEFAULT_LIMITS
	budget.max_response_bytes = limit
	web.limits(&a, budget)
	return a
}

// RED before ADR-045: a 4096-byte response under a 1024-byte limit reached the
// client at 200/4096 bytes. GREEN: it is a 500, and no over-limit body is sent.
@(test)
c04b_over_limit_response_is_a_500 :: proc(t: ^testing.T) {
	sink: Telemetry
	context.user_ptr = &sink
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	a := limited_app(1024)
	defer web.destroy(&a)
	web.observe(&a, record_event)
	web.get(&a, "/big", big_handler)

	res := web.test_request(&a, .GET, "/big")

	// The response is replaced, not truncated: a standardized 500 with the
	// internal-error envelope, never a partial 200.
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
	testing.expect(t, strings.contains(res.body, "internal_error"), "over-limit response must carry the standardized internal_error envelope")
	testing.expect(t, !strings.contains(res.body, "aaaa"), "no byte of the over-limit body may reach the client")

	// The typed observer saw it, with the route and the committed status and no
	// request bytes.
	testing.expect_value(t, sink.last_kind, web.Framework_Error.Response_Too_Large)
	testing.expect_value(t, sink.last_route, "/big")
	testing.expect_value(t, sink.last_status, web.Status.Internal_Server_Error)
}

// A response at or below the limit is untouched — the guard is `>`, exactly like
// `max_body`'s "exactly the limit is accepted".
@(test)
c04b_at_or_below_limit_is_served :: proc(t: ^testing.T) {
	sink: Telemetry
	context.user_ptr = &sink
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	// Limit equal to the big body's exact size: exactly this many is allowed.
	a := limited_app(BIG)
	defer web.destroy(&a)
	web.observe(&a, record_event)
	web.get(&a, "/big", big_handler)

	res := web.test_request(&a, .GET, "/big")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, len(res.body), BIG)
	testing.expect_value(t, sink.count, 0) // no failure observed
}

// The default (0 = off) preserves the shipped behaviour: an unbounded response
// is served whole, no matter how large. This is what makes shipping the field
// safe for every application that never sets it.
@(test)
c04b_default_off_is_unbounded :: proc(t: ^testing.T) {
	sink: Telemetry
	context.user_ptr = &sink
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	a := web.app() // DEFAULT_LIMITS: max_response_bytes = 0
	defer web.destroy(&a)
	web.observe(&a, record_event)
	web.get(&a, "/big", big_handler)

	res := web.test_request(&a, .GET, "/big")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, len(res.body), BIG)
	testing.expect_value(t, sink.count, 0)
}

// A small response under a small limit is the ordinary path: served, unobserved.
@(test)
c04b_small_response_under_limit_untouched :: proc(t: ^testing.T) {
	sink: Telemetry
	context.user_ptr = &sink
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	a := limited_app(1024)
	defer web.destroy(&a)
	web.observe(&a, record_event)
	web.get(&a, "/small", small_handler)

	res := web.test_request(&a, .GET, "/small")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, len(res.body), SMALL)
	testing.expect_value(t, sink.count, 0)
}

// A negative `max_response_bytes` is a mistake, refused at configuration like
// every other negative budget: the application is poisoned and answers 500.
@(test)
c04b_negative_limit_is_rejected :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	a := web.app()
	defer web.destroy(&a)
	budget := web.DEFAULT_LIMITS
	budget.max_response_bytes = -1
	web.limits(&a, budget)
	web.get(&a, "/small", small_handler)

	// A poisoned application answers 500 to every request.
	res := web.test_request(&a, .GET, "/small")
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
}
