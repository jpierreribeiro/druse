// WP21 public-surface contract — THE FAULT-BEHAVIOUR GUARANTEE, as an external
// consumer sees it.
//
// ADR-020 (accepted 2026-07-19) settled that Phase 2 ships **no recovery
// middleware and no public symbol for it**. Odin has no recoverable panic:
// `context` is by value so `app()` can never install a hook for its caller, and
// bounds-check, nil-deref and divide-by-zero faults never reach a hook at all.
// What Phase 2 guarantees instead is the WP8 driver behaviour — a dispatch that
// commits no response is finalized to the standardized `internal_error` 500.
//
// This suite is the CONSUMER-VISIBLE half of that guarantee. It is deliberately
// written against the public surface only: it never reaches into `package web`,
// because the whole point of ADR-020 is that an application can rely on this
// WITHOUT a symbol to call. There is nothing to import; there is only behaviour.
//
// The suite proves four things WP8 left open:
//
//   1. the guarantee covers an EARLY-RETURN error branch, not only a handler
//      that plainly forgot to respond — that is the shape real code takes;
//   2. `app()` and `bare()` reach the same 500 through DIFFERENT routes: an
//      unmatched path is a 404 under `app()` and the driver's 500 under
//      `bare()`, which is precisely "default in app(), absent in bare()" once
//      ADR-020 removed the middleware from the sentence;
//   3. a SECOND fault behaves exactly like the first, byte for byte, and a
//      healthy request in between is unaffected — no latched state, no drift;
//   4. the 500 carries NO fault detail. `internal_error` takes no message on
//      purpose, and the driver's finalization inherits that property.
//
// `build/check.sh` runs this suite twice: default and `-o:speed`. The gate item
// names both build modes because WP13 measured that build mode changes which
// faults exist at all, and a guarantee that holds only at `-o:none` is not one.
package wp21_public_surface

import "core:log"
import "core:strings"
import "core:testing"
import web "druse:web"

// The exact bytes of the standardized envelope. Written out in full rather than
// referenced: this suite is an external consumer, and a consumer that read the
// constant out of the package could not detect the package changing it.
@(private = "file")
WP21_INTERNAL_ENVELOPE ::
	`{"error":{"code":"internal_error","message":"Internal server error"}}`

// ---------------------------------------------------------------------------
// The framework logs one Error-level `druse:` diagnostic every time it
// finalizes a missing response. The test runner treats an Error log line as a
// failure, so the suite captures the framework's own lines and FORWARDS
// everything else — a swallow-everything logger would make `testing.expect`
// unable to report at all (WP17 mutation control 6).
// ---------------------------------------------------------------------------

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
	if level == .Error && strings.contains(text, "druse:") {
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

// ---------------------------------------------------------------------------
// Handlers. Each one models a real way to leave a request unanswered.
// ---------------------------------------------------------------------------

// The plain case: the handler ran and simply committed nothing.
@(private = "file")
wp21_silent :: proc(ctx: ^web.Context) {
}

// The realistic case: an error branch that returns EARLY without responding.
// This is the shape a forgotten `web.internal_error(ctx)` actually takes in
// application code, and it is why the guarantee is worth stating.
@(private = "file")
wp21_early_return :: proc(ctx: ^web.Context) {
	token := web.path(ctx, "token")
	if len(token) < 1024 {
		// The "failure" branch: give up without answering.
		return
	}
	web.text(ctx, .OK, "unreachable")
}

@(private = "file")
wp21_healthy :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

@(private = "file")
wp21_explicit_internal_error :: proc(ctx: ^web.Context) {
	web.internal_error(ctx)
}

// ---------------------------------------------------------------------------
// 1. A handler that commits nothing is finalized to the standardized 500.
// ---------------------------------------------------------------------------

@(test)
wp21_silent_handler_is_finalized_to_the_standard_500 :: proc(t: ^testing.T) {
	record: Wp21_Log
	context.logger = wp21_recording_logger(&record)

	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/silent", wp21_silent)

	res := web.test_request(&a, .GET, "/silent")

	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
	testing.expect_value(t, res.body, WP21_INTERNAL_ENVELOPE)
	// The framework says so once, on its own diagnostic channel, and never in
	// the response.
	testing.expect_value(t, record.framework_calls, 1)
}

// ---------------------------------------------------------------------------
// 2. An EARLY-RETURN error branch gets the same guarantee.
//
//    WP8 proved the guarantee for a handler that never responds. The case that
//    actually occurs is a handler that responds on the happy path and forgets
//    on one branch — and it must not degrade into a zero status there either.
// ---------------------------------------------------------------------------

@(test)
wp21_early_return_branch_is_finalized_to_the_standard_500 :: proc(t: ^testing.T) {
	record: Wp21_Log
	context.logger = wp21_recording_logger(&record)

	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/vault/:token", wp21_early_return)

	res := web.test_request(&a, .GET, "/vault/hunter2")

	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
	testing.expect_value(t, res.body, WP21_INTERNAL_ENVELOPE)
	testing.expect_value(t, record.framework_calls, 1)
}

// ---------------------------------------------------------------------------
// 3. The 500 carries NO fault detail — the redaction property.
//
//    `web.internal_error(ctx)` takes no message ON PURPOSE, and the driver's
//    finalization inherits that: it emits a compile-time constant, so there is
//    no code path by which a path segment, a route pattern, a method or an
//    internal message could reach the client. This test is what a mutation that
//    "helpfully" adds detail must break.
// ---------------------------------------------------------------------------

@(test)
wp21_the_driver_500_leaks_no_fault_detail :: proc(t: ^testing.T) {
	record: Wp21_Log
	context.logger = wp21_recording_logger(&record)

	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/vault/:token", wp21_early_return)

	res := web.test_request(&a, .GET, "/vault/hunter2", "", "audit=secret-query")

	testing.expect_value(t, res.body, WP21_INTERNAL_ENVELOPE)
	for leak in ([]string{"hunter2", "secret-query", "vault", "token", "GET", "wp21_early_return"}) {
		testing.expectf(
			t,
			!strings.contains(res.body, leak),
			"the standardized 500 must not carry the fault detail %q",
			leak,
		)
	}
	// Belt and braces: the envelope's only message is the fixed one.
	testing.expect_value(t, strings.count(res.body, `"message":`), 1)
	testing.expect(
		t,
		strings.contains(res.body, `"message":"Internal server error"`),
		"the only message in the envelope is the fixed one",
	)
}

// ---------------------------------------------------------------------------
// 4. The driver's 500 is BYTE-IDENTICAL to an explicit `web.internal_error`.
//
//    This is the sharpest statement of "standardized": a client cannot tell a
//    handler that answered 500 deliberately from one the driver finalized. If
//    the two ever diverge, one of them is not the standard envelope.
// ---------------------------------------------------------------------------

@(test)
wp21_driver_500_is_byte_identical_to_an_explicit_internal_error :: proc(t: ^testing.T) {
	record: Wp21_Log
	context.logger = wp21_recording_logger(&record)

	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/silent", wp21_silent)
	web.get(&a, "/explicit", wp21_explicit_internal_error)

	driver := web.test_request(&a, .GET, "/silent")
	explicit := web.test_request(&a, .GET, "/explicit")

	testing.expect_value(t, driver.status, explicit.status)
	testing.expect_value(t, driver.body, explicit.body)
	// Only the driver's own path logs a framework diagnostic; a deliberate
	// `internal_error` is application intent, not a framework failure.
	testing.expect_value(t, record.framework_calls, 1)
}

// ---------------------------------------------------------------------------
// 5. `app()` and `bare()`: the same guarantee, reached differently.
//
//    This is what "default in app(), absent in bare()" means after ADR-020
//    deleted the middleware from the sentence. `app()` installs a default
//    route POLICY, so an unmatched path is a 404. `bare()` installs none, so
//    the same request reaches the driver uncommitted and becomes the 500. The
//    driver guarantee itself is not a default and is not optional: `bare()`
//    means "no default policy", never "no safety".
// ---------------------------------------------------------------------------

@(test)
wp21_app_answers_a_miss_with_404_and_bare_falls_through_to_the_driver_500 :: proc(t: ^testing.T) {
	record: Wp21_Log
	context.logger = wp21_recording_logger(&record)

	full := web.app()
	defer web.destroy(&full)
	web.get(&full, "/known", wp21_healthy)

	stripped := web.bare()
	defer web.destroy(&stripped)
	web.get(&stripped, "/known", wp21_healthy)

	missed_full := web.test_request(&full, .GET, "/absent")
	missed_bare := web.test_request(&stripped, .GET, "/absent")

	testing.expect_value(t, missed_full.status, web.Status.Not_Found)
	testing.expect_value(t, missed_bare.status, web.Status.Internal_Server_Error)
	testing.expect_value(t, missed_bare.body, WP21_INTERNAL_ENVELOPE)

	// The route POLICY differs; the routes themselves do not.
	testing.expect_value(t, web.test_request(&full, .GET, "/known").status, web.Status.OK)
	testing.expect_value(t, web.test_request(&stripped, .GET, "/known").status, web.Status.OK)

	// Exactly one framework diagnostic: `bare()`'s fall-through. A 404 under
	// `app()` is policy, not a framework failure.
	testing.expect_value(t, record.framework_calls, 1)
}

// ---------------------------------------------------------------------------
// 6. `bare()` gives a silent HANDLER the identical guarantee.
//
//    Distinct from the miss above: here the route matched and the handler ran.
//    The guarantee belongs to the driver, so it cannot be switched off by
//    choosing the policy-free constructor.
// ---------------------------------------------------------------------------

@(test)
wp21_bare_finalizes_a_silent_handler_exactly_like_app :: proc(t: ^testing.T) {
	record: Wp21_Log
	context.logger = wp21_recording_logger(&record)

	full := web.app()
	defer web.destroy(&full)
	web.get(&full, "/silent", wp21_silent)

	stripped := web.bare()
	defer web.destroy(&stripped)
	web.get(&stripped, "/silent", wp21_silent)

	from_app := web.test_request(&full, .GET, "/silent")
	from_bare := web.test_request(&stripped, .GET, "/silent")

	testing.expect_value(t, from_app.status, web.Status.Internal_Server_Error)
	testing.expect_value(t, from_bare.status, from_app.status)
	testing.expect_value(t, from_bare.body, from_app.body)
	testing.expect_value(t, record.framework_calls, 2)
}

// ---------------------------------------------------------------------------
// 7. A SECOND fault behaves exactly like the first.
//
//    The gate item says "a second such request behaves identically", and it
//    matters because the failure mode it excludes is real: a guarantee latched
//    behind a one-shot flag, or a finalization that consumes state it needed.
//    A healthy request is interleaved, so the test also rejects the opposite
//    defect — a fault that poisons the app for everything after it.
// ---------------------------------------------------------------------------

@(test)
wp21_a_second_fault_is_answered_identically :: proc(t: ^testing.T) {
	record: Wp21_Log
	context.logger = wp21_recording_logger(&record)

	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/silent", wp21_silent)
	web.get(&a, "/healthy", wp21_healthy)

	first := web.test_request(&a, .GET, "/silent")
	between := web.test_request(&a, .GET, "/healthy")
	second := web.test_request(&a, .GET, "/silent")
	third := web.test_request(&a, .GET, "/silent")

	testing.expect_value(t, first.status, web.Status.Internal_Server_Error)
	testing.expect_value(t, first.body, WP21_INTERNAL_ENVELOPE)

	// Unaffected in between.
	testing.expect_value(t, between.status, web.Status.OK)
	testing.expect_value(t, between.body, "pong")

	// Identical, twice more.
	testing.expect_value(t, second.status, first.status)
	testing.expect_value(t, second.body, first.body)
	testing.expect_value(t, third.status, first.status)
	testing.expect_value(t, third.body, first.body)

	// One diagnostic per fault, three faults — never zero (silently dropped)
	// and never more (a doubled report).
	testing.expect_value(t, record.framework_calls, 3)
}

// ---------------------------------------------------------------------------
// 8. `internal_error` takes NO message — as a signature, not a promise.
//
//    The redaction property in test 3 is only durable because the responder
//    physically cannot be handed a detail string. Assigning it to an explicitly
//    typed variable makes that a compile-time contract: adding a message
//    parameter would fail to build here.
// ---------------------------------------------------------------------------

@(test)
wp21_internal_error_admits_no_message_parameter :: proc(t: ^testing.T) {
	responder: proc(ctx: ^web.Context) = web.internal_error
	testing.expect(t, responder != nil, "internal_error must take a Context and nothing else")
}
