// WP8 internal behavior tests — the response-driver finalization and the
// neutral-boundary conversions that live on the core side.
//
// `package web`, compiled in a THROWAWAY package against the real `web/`
// sources exactly like WP2-WP7. The declarations covered — `driver_finalize`,
// the private `Response`/`Context`, the method token mapping — are all
// package-private.
//
// WHY INTERNAL. Two WP8 contracts are observable only from inside the package:
// that a dispatch leaving the response uncommitted is finalized to a logged 500
// (WP8 D5), and that the request-local teardown runs on that path too. The real
// socket round-trip lives in tests/wp8-socket/.
//
// The log oracle mirrors WP6/WP7: it records the framework's own diagnostic and
// swallows it, forwarding everything else so real assertion failures still reach
// the runner.
#+private
package web

import "core:log"
import "core:strings"
import "core:testing"

@(private = "file")
WP8_LOG_MARKER :: "druse:"

@(private = "file")
Wp8_Log :: struct {
	framework_calls: int,
	inner:           log.Logger,
}

@(private = "file")
wp8_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Wp8_Log)(data)
	if level == .Error && strings.contains(text, WP8_LOG_MARKER) {
		record.framework_calls += 1
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

@(private = "file")
wp8_recording_logger :: proc(record: ^Wp8_Log) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = wp8_logger_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

@(private = "file")
wp8_noop_handler :: proc(ctx: ^Context) {
}

// ---------------------------------------------------------------------------
// 1. A handler that does not respond is finalized to a logged 500 (WP8 D5).
// ---------------------------------------------------------------------------

@(test)
wp8_uncommitted_response_is_finalized_to_500 :: proc(t: ^testing.T) {
	record: Wp8_Log
	context.logger = wp8_recording_logger(&record)

	a := app()
	defer destroy(&a)
	get(&a, "/silent", wp8_noop_handler)

	ctx: Context
	defer response_destroy(&ctx.private.response)
	ctx.request.method = .GET
	ctx.request.path = "/silent"
	dispatch(&a, &ctx)

	// The handler committed nothing; dispatch left the response uncommitted.
	testing.expect(t, !ctx.private.response.committed, "precondition: handler responded with nothing")

	driver_finalize(&ctx)

	testing.expect(t, ctx.private.response.committed, "the driver must finalize an uncommitted response")
	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
	testing.expect_value(
		t,
		string(ctx.private.response.body),
		`{"error":{"code":"internal_error","message":"Internal server error"}}`,
	)
	testing.expect_value(t, record.framework_calls, 1)
}

// ---------------------------------------------------------------------------
// 2. driver_finalize does NOT disturb a response that was committed.
// ---------------------------------------------------------------------------

@(test)
wp8_finalize_leaves_a_committed_response_intact :: proc(t: ^testing.T) {
	record: Wp8_Log
	context.logger = wp8_recording_logger(&record)

	ctx: Context
	defer response_destroy(&ctx.private.response)
	ok(&ctx, 42)
	first_body := string(ctx.private.response.body)

	driver_finalize(&ctx)

	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), first_body)
	testing.expect_value(t, record.framework_calls, 0)
}

// ---------------------------------------------------------------------------
// 3. bare() still installs no 404/405; the 500 is only the driver's job.
//
//    An unmatched request under bare() leaves the response uncommitted (the
//    core adds no policy), and it is the DRIVER finalization — not dispatch —
//    that turns that into a 500.
// ---------------------------------------------------------------------------

@(test)
wp8_bare_miss_is_uncommitted_until_the_driver_finalizes :: proc(t: ^testing.T) {
	record: Wp8_Log
	context.logger = wp8_recording_logger(&record)

	a := bare()
	defer destroy(&a)
	get(&a, "/known", wp8_noop_handler)

	ctx: Context
	defer response_destroy(&ctx.private.response)
	ctx.request.method = .GET
	ctx.request.path = "/absent"
	dispatch(&a, &ctx)

	// The core installed no 404 (bare's contract is unchanged).
	testing.expect(t, !ctx.private.response.committed, "bare() must not commit an automatic 404")

	// Only the driver turns the miss into a valid HTTP response.
	driver_finalize(&ctx)
	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
}

// ---------------------------------------------------------------------------
// 4. test_request finalizes an uncommitted response too, for parity with the
//    real transport (WP8 D5).
//
//    Before WP8, a handler that responded with nothing yielded the ZERO status
//    through test_request. WP8 makes both drivers agree: it becomes a 500.
// ---------------------------------------------------------------------------

@(test)
wp8_test_request_finalizes_a_silent_handler_to_500 :: proc(t: ^testing.T) {
	record: Wp8_Log
	context.logger = wp8_recording_logger(&record)

	a := app()
	defer destroy(&a)
	get(&a, "/silent", wp8_noop_handler)

	res := test_request(&a, .GET, "/silent")

	testing.expect_value(t, res.status, Status.Internal_Server_Error)
	testing.expect_value(
		t,
		res.body,
		`{"error":{"code":"internal_error","message":"Internal server error"}}`,
	)
}

// ---------------------------------------------------------------------------
// 5. The method token mapping the adapter relies on is total and exact.
// ---------------------------------------------------------------------------

@(test)
wp8_method_token_round_trip :: proc(t: ^testing.T) {
	for m in ([]Method{.GET, .POST, .PUT, .PATCH, .DELETE}) {
		token := method_token(m)
		testing.expect(t, len(token) > 0, "a registrable method must have a token")
		testing.expect_value(t, method_from_token(token), m)
	}

	// HEAD and OPTIONS are NOT public methods: they map to .UNKNOWN and never
	// become GET (WP8 D6).
	testing.expect_value(t, method_from_token("HEAD"), Method.UNKNOWN)
	testing.expect_value(t, method_from_token("OPTIONS"), Method.UNKNOWN)
	testing.expect_value(t, method_from_token("get"), Method.UNKNOWN)
}
