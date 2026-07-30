// WP21 internal behaviour — the fault-behaviour guarantee from INSIDE the
// package, where the two ADR-020 facts are actually checkable.
//
// `package web`, compiled in a THROWAWAY package against the real `web/`
// sources, exactly like WP2-WP20.
//
// WHY INTERNAL. The public suite proves what a client receives. Three claims
// underneath it are only visible from in here:
//
//   1. the guarantee is delivered by `driver_run` — the ONE pipeline both
//      transports share — and not by anything transport-specific. A test that
//      only drove `test_request` could not tell the difference, and R-10 is the
//      property that makes "the test transport cannot lie" structural;
//   2. the framework installs NO fault hook. ADR-020's FACT 1 is that `app()`
//      cannot install one for its caller even if it tried, because `context` is
//      an implicit by-value parameter. That is a language fact; this test turns
//      it into an ASSERTED absence, so a future "helpful" hook cannot be added
//      quietly and then be found not to work;
//   3. the finalized body is the compile-time constant itself — the SAME
//      backing storage, not a copy. That is what makes the guarantee
//      allocation-free and what makes the redaction property structural: there
//      is no buffer into which a detail string could be composed.
//
// The gate item "a panic in a handler aborts the process" cannot live here: an
// aborting process takes the test runner with it. It is a SUBPROCESS probe in
// `build/check_wp21_controls.sh`, which is the only honest place for it.
#+private
package web

import "core:log"
import "core:strings"
import "core:testing"
import transport "druse:web/internal/transport"

@(private = "file")
WP21_LOG_MARKER :: "druse:"

@(private = "file")
Wp21_Log :: struct {
	framework_calls: int,
	inner:           log.Logger,
}

@(private = "file")
wp21_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Wp21_Log)(data)
	if level == .Error && strings.contains(text, WP21_LOG_MARKER) {
		record.framework_calls += 1
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

@(private = "file")
wp21_recording_logger :: proc(record: ^Wp21_Log) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = wp21_logger_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

@(private = "file")
wp21_silent :: proc(ctx: ^Context) {
}

// wp21_drive runs ONE request through the shared driver pipeline exactly as
// `serve` and `test_request` both do, and returns the finalized response. The
// caller owns teardown.
@(private = "file")
wp21_drive :: proc(a: ^App, ctx: ^Context, method: string, path: string) {
	driver_run(a, ctx, transport.Inbound{method = method, path = path})
}

// ---------------------------------------------------------------------------
// 1. The guarantee is delivered by `driver_run` itself, for `app()` and for
//    `bare()`, byte for byte.
//
//    Both transports call this one procedure. Asserting here — rather than
//    through either driver's own facade — is what makes socket/in-memory parity
//    structural instead of a claim (R-10).
// ---------------------------------------------------------------------------

@(test)
wp21_driver_run_finalizes_the_missing_response_for_both_constructors :: proc(t: ^testing.T) {
	record: Wp21_Log
	context.logger = wp21_recording_logger(&record)

	full := app()
	defer destroy(&full)
	get(&full, "/silent", wp21_silent)

	stripped := bare()
	defer destroy(&stripped)
	get(&stripped, "/silent", wp21_silent)

	full_ctx: Context
	defer driver_cleanup(&full_ctx)
	wp21_drive(&full, &full_ctx, "GET", "/silent")

	bare_ctx: Context
	defer driver_cleanup(&bare_ctx)
	wp21_drive(&stripped, &bare_ctx, "GET", "/silent")

	testing.expect(t, full_ctx.private.response.committed, "the driver must commit a response")
	testing.expect(t, bare_ctx.private.response.committed, "bare() gets the same guarantee")

	testing.expect_value(t, full_ctx.private.response.status, Status.Internal_Server_Error)
	testing.expect_value(t, bare_ctx.private.response.status, Status.Internal_Server_Error)
	testing.expect_value(
		t,
		string(bare_ctx.private.response.body),
		string(full_ctx.private.response.body),
	)
	testing.expect_value(t, string(full_ctx.private.response.body), ERROR_BODY_INTERNAL)
	testing.expect_value(t, record.framework_calls, 2)
}

// ---------------------------------------------------------------------------
// 2. The finalized body IS the constant — same storage, nothing allocated.
//
//    `error_commit_static` transmutes the compile-time constant, so the
//    response body points AT the constant rather than at a copy of it. Two
//    consequences follow, and both are the reason ADR-020's option (B) is safe:
//    the guarantee cannot fail for want of memory, and there is no buffer in
//    which a fault message could be assembled.
// ---------------------------------------------------------------------------

@(test)
wp21_the_finalized_body_is_the_static_constant_not_a_copy :: proc(t: ^testing.T) {
	record: Wp21_Log
	context.logger = wp21_recording_logger(&record)

	a := app()
	defer destroy(&a)
	get(&a, "/silent", wp21_silent)

	ctx: Context
	defer driver_cleanup(&ctx)
	wp21_drive(&a, &ctx, "GET", "/silent")

	constant := transmute([]u8)string(ERROR_BODY_INTERNAL)
	testing.expect(
		t,
		raw_data(ctx.private.response.body) == raw_data(constant),
		"the standardized 500 must BORROW the constant: no allocation, and no buffer to compose a detail into",
	)
	testing.expect_value(t, len(ctx.private.response.body), len(constant))
}

// ---------------------------------------------------------------------------
// 3. Neither constructor installs a fault hook — ADR-020's FACT 1, asserted.
//
//    Odin's `context` is an implicit BY-VALUE parameter, so an assignment made
//    inside `app()` dies with `app()`'s frame and the caller keeps the old
//    value. That makes "recovery middleware becomes default-on in web.app()"
//    unachievable for every hook-based design, which is exactly why ADR-020
//    ships zero symbols.
//
//    The test records the caller's hook, constructs and exercises both apps,
//    and requires the hook UNCHANGED. It fails both ways round: if a future
//    change installs a hook here, the assertion goes red rather than the hook
//    silently doing nothing.
// ---------------------------------------------------------------------------

@(test)
wp21_neither_app_nor_bare_installs_a_fault_hook :: proc(t: ^testing.T) {
	record: Wp21_Log
	context.logger = wp21_recording_logger(&record)

	before := context.assertion_failure_proc

	full := app()
	defer destroy(&full)
	get(&full, "/silent", wp21_silent)

	stripped := bare()
	defer destroy(&stripped)

	testing.expect(
		t,
		context.assertion_failure_proc == before,
		"app()/bare() must install NO assertion_failure_proc (ADR-020 FACT 1)",
	)

	// And it stays untouched across a request, including the fault path.
	ctx: Context
	defer driver_cleanup(&ctx)
	wp21_drive(&full, &ctx, "GET", "/silent")

	testing.expect(
		t,
		context.assertion_failure_proc == before,
		"finalizing a missing response must not install a fault hook either",
	)
	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
}

// ---------------------------------------------------------------------------
// 4. Repeatable: a second and third fault are finalized identically, and a
//    healthy request between them is untouched.
//
//    The defect this excludes is a guarantee latched behind one-shot state —
//    the failure mode where a server answers the first fault correctly and
//    every later one with a zero status.
// ---------------------------------------------------------------------------

@(test)
wp21_the_guarantee_is_repeatable_and_does_not_latch :: proc(t: ^testing.T) {
	record: Wp21_Log
	context.logger = wp21_recording_logger(&record)

	a := app()
	defer destroy(&a)
	get(&a, "/silent", wp21_silent)
	get(&a, "/healthy", wp21_healthy_internal)

	first_status: Status
	first_body: string
	for round in 0 ..< 3 {
		ctx: Context
		wp21_drive(&a, &ctx, "GET", "/silent")

		if round == 0 {
			first_status = ctx.private.response.status
			first_body = string(ctx.private.response.body)
		}
		testing.expect_value(t, ctx.private.response.status, first_status)
		testing.expect_value(t, string(ctx.private.response.body), first_body)
		driver_cleanup(&ctx)

		// Interleave a healthy request: a fault must not poison the App.
		healthy: Context
		wp21_drive(&a, &healthy, "GET", "/healthy")
		testing.expect_value(t, healthy.private.response.status, Status.OK)
		driver_cleanup(&healthy)
	}

	testing.expect_value(t, first_status, Status.Internal_Server_Error)
	testing.expect_value(t, first_body, ERROR_BODY_INTERNAL)
	// One diagnostic per fault, three faults. Never zero, never doubled.
	testing.expect_value(t, record.framework_calls, 3)
}

@(private = "file")
wp21_healthy_internal :: proc(ctx: ^Context) {
	text(ctx, .OK, "pong")
}

// ---------------------------------------------------------------------------
// 5. A committed response is never overwritten by the guarantee.
//
//    The finalization is a FALLBACK. A handler that answered — including one
//    that answered 500 deliberately — must reach the client unchanged, and no
//    framework diagnostic is emitted for it: a deliberate error is application
//    intent, not a framework failure.
// ---------------------------------------------------------------------------

@(test)
wp21_a_committed_response_is_left_alone_and_reported_nowhere :: proc(t: ^testing.T) {
	record: Wp21_Log
	context.logger = wp21_recording_logger(&record)

	a := app()
	defer destroy(&a)
	get(&a, "/deliberate", wp21_deliberate_internal_error)

	ctx: Context
	defer driver_cleanup(&ctx)
	wp21_drive(&a, &ctx, "GET", "/deliberate")

	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
	testing.expect_value(t, string(ctx.private.response.body), ERROR_BODY_INTERNAL)
	testing.expect_value(t, record.framework_calls, 0)
}

@(private = "file")
wp21_deliberate_internal_error :: proc(ctx: ^Context) {
	internal_error(ctx)
}
