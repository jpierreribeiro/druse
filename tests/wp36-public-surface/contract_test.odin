// WP36 public-surface contract — configurable limits.
//
// THREE SYMBOLS, ledger 47 → 50: the `Limits` struct, the `DEFAULT_LIMITS`
// constant, and `limits(&app, l)`. This is the least reversible change in
// Phase 3, so the suite spends most of itself on the two things that are
// expensive to get wrong: what happens with NO configuration at all, and
// whether both transports enforce the same number.
//
// R-10 IS THE POINT OF THE `Limits`-ON-THE-APP DESIGN. `test_request` never
// calls `serve`. If the body cap lived on `serve`, an in-memory test would
// answer 200 where a socket answers 413 — on exactly the boundary a test suite
// exists to prove. The cap therefore travels with the application and the
// shared driver copies it onto every request, so this suite testing
// `test_request` is testing the same comparison the socket makes.
//
// WHAT IS NOT HERE: read and write timeouts. The vendored server has no
// deadline to configure, so `Limits` ships without those fields rather than
// with fields that do nothing. See `web/limits.odin` and the WP36 note in
// `planning/phase-3-plan.md`.
package test_wp36_public

import "core:log"
import "core:strings"
import "core:testing"
import web "druse:web"

@(private = "file")
Quiet :: struct {
	inner: log.Logger,
}

@(private = "file")
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

@(private = "file")
quiet_logger :: proc(record: ^Quiet) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = quiet_logger_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

@(private = "file")
Payload :: struct {
	pad: string `json:"pad"`,
}

@(private = "file")
echo_body :: proc(ctx: ^web.Context) {
	payload: Payload
	if !web.body(ctx, &payload) {
		return
	}
	web.ok(ctx, payload)
}

// `{"pad":"aaa…"}` of exactly `total` bytes, so a test can sit one byte either
// side of a cap and mean it.
@(private = "file")
body_of_size :: proc(total: int, allocator := context.allocator) -> string {
	prefix := `{"pad":"`
	suffix := `"}`
	fill := total - len(prefix) - len(suffix)
	if fill < 0 {
		fill = 0
	}
	buf := make([]u8, len(prefix) + fill + len(suffix), allocator)
	n := copy(buf[:], prefix)
	for i in 0 ..< fill {
		buf[n + i] = 'a'
	}
	n += fill
	copy(buf[n:], suffix)
	return string(buf)
}

// The three names exist with the ratified shapes. Pinned by USE: this compiles
// only if `Limits` has these three fields, `DEFAULT_LIMITS` is a value of that
// type, and `limits` takes an `^App` and a `Limits`.
@(test)
wp36_the_limits_surface_is_pinned :: proc(t: ^testing.T) {
	custom := web.Limits {
		max_body         = 1024,
		max_request_line = 4000,
		max_headers      = 4000,
	}

	app := web.app()
	defer web.destroy(&app)
	web.limits(&app, custom)

	testing.expect(t, web.DEFAULT_LIMITS.max_body > 0, "DEFAULT_LIMITS must be usable as a value")
	testing.expect_value(t, custom.max_body, 1024)
}

// DEFAULT_LIMITS IS THE SHIPPED BEHAVIOUR, NOT A NEW OPINION. 4 MiB is the cap
// Phase 1 fixed and the capacity ledger has recorded since; 8000 is the
// backend's own default for both text budgets. If any of these three changed,
// an application that never mentioned limits would change behaviour — which is
// the failure mode this test exists to catch.
@(test)
wp36_the_defaults_are_the_values_already_shipped :: proc(t: ^testing.T) {
	testing.expect_value(t, web.DEFAULT_LIMITS.max_body, 4 * 1024 * 1024)
	testing.expect_value(t, web.DEFAULT_LIMITS.max_request_line, 8000)
	testing.expect_value(t, web.DEFAULT_LIMITS.max_headers, 8000)
}

// An application that never calls `limits` behaves exactly as it did before
// this work package: a body under the default cap is decoded.
@(test)
wp36_an_application_that_never_configures_anything_still_works :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/echo", echo_body)

	small := body_of_size(64)
	defer delete(small)

	res := web.test_request(&app, .POST, "/echo", small)
	testing.expect_value(t, res.status, web.Status.OK)
}

// `bare()` gets the same budget. Limits are not miss policy — they are what
// keeps one request from consuming the process — so there is no application
// with "no limits", and there should not be: unlimited is not a configuration.
@(test)
wp36_bare_gets_the_same_budget :: proc(t: ^testing.T) {
	app := web.bare()
	defer web.destroy(&app)
	web.post(&app, "/echo", echo_body)

	small := body_of_size(64)
	defer delete(small)

	res := web.test_request(&app, .POST, "/echo", small)
	testing.expect_value(t, res.status, web.Status.OK)
}

// THE CAP ACTUALLY MOVES, in both directions of the boundary. Exactly the limit
// is allowed; one byte more is 413 — the same "exactly N is allowed" rule the
// fixed 4 MiB cap always had, now at a number the application chose.
@(test)
wp36_a_lowered_body_cap_is_enforced_exactly :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)

	budget := web.DEFAULT_LIMITS
	budget.max_body = 64
	web.limits(&app, budget)
	web.post(&app, "/echo", echo_body)

	at_limit := body_of_size(64)
	defer delete(at_limit)
	over_limit := body_of_size(65)
	defer delete(over_limit)

	testing.expect_value(t, web.test_request(&app, .POST, "/echo", at_limit).status, web.Status.OK)
	testing.expect_value(
		t,
		web.test_request(&app, .POST, "/echo", over_limit).status,
		web.Status(413),
	)
}

// A RAISED cap is enforced too, and this is the half that proves the number is
// really being read rather than a smaller constant being applied twice: a body
// larger than one custom cap passes under a larger one.
@(test)
wp36_a_raised_body_cap_admits_what_a_lower_one_refused :: proc(t: ^testing.T) {
	strict := web.app()
	defer web.destroy(&strict)
	strict_budget := web.DEFAULT_LIMITS
	strict_budget.max_body = 64
	web.limits(&strict, strict_budget)
	web.post(&strict, "/echo", echo_body)

	generous := web.app()
	defer web.destroy(&generous)
	generous_budget := web.DEFAULT_LIMITS
	generous_budget.max_body = 256
	web.limits(&generous, generous_budget)
	web.post(&generous, "/echo", echo_body)

	payload := body_of_size(128)
	defer delete(payload)

	testing.expect_value(
		t,
		web.test_request(&strict, .POST, "/echo", payload).status,
		web.Status(413),
	)
	testing.expect_value(
		t,
		web.test_request(&generous, .POST, "/echo", payload).status,
		web.Status.OK,
	)
}

// Two applications in one process hold two budgets. `DEFAULT_LIMITS` is a
// CONSTANT, so there is no global for one of them to change out from under the
// other — which is exactly the failure the vendored backend's mutable
// `Default_Server_Opts` package variable would allow.
@(test)
wp36_two_applications_hold_two_budgets :: proc(t: ^testing.T) {
	first := web.app()
	defer web.destroy(&first)
	second := web.app()
	defer web.destroy(&second)

	tight := web.DEFAULT_LIMITS
	tight.max_body = 32
	web.limits(&first, tight)

	web.post(&first, "/echo", echo_body)
	web.post(&second, "/echo", echo_body)

	payload := body_of_size(128)
	defer delete(payload)

	testing.expect_value(t, web.test_request(&first, .POST, "/echo", payload).status, web.Status(413))
	testing.expect_value(t, web.test_request(&second, .POST, "/echo", payload).status, web.Status.OK)
}

// ---------------------------------------------------------------------------
// Fail-closed
// ---------------------------------------------------------------------------

// A ZERO FIELD IS REJECTED. `Limits{max_body = 1024}` leaves two fields at zero
// and there is no unset state to tell a forgotten field from a deliberate one,
// so the struct is refused rather than guessed at. Start from `DEFAULT_LIMITS`.
@(test)
wp36_a_partially_filled_limits_value_rejects_the_application :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.limits(&app, web.Limits{max_body = 1024})
	web.post(&app, "/echo", echo_body)

	small := body_of_size(64)
	defer delete(small)

	testing.expect_value(
		t,
		web.test_request(&app, .POST, "/echo", small).status,
		web.Status.Internal_Server_Error,
	)
}

// A negative budget is the same answer.
@(test)
wp36_a_negative_budget_rejects_the_application :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	budget := web.DEFAULT_LIMITS
	budget.max_headers = -1
	web.limits(&app, budget)
	web.get(&app, "/ping", pong)

	testing.expect_value(
		t,
		web.test_request(&app, .GET, "/ping").status,
		web.Status.Internal_Server_Error,
	)
}

@(private = "file")
pong :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

// THE CONCURRENCY DECISION, observable. Limits are read on the request path, so
// changing them mid-flight would make two clients get two different answers to
// the same body. That is REJECTED through the existing poison mechanism rather
// than made impossible by construction.
@(test)
wp36_limits_after_the_first_dispatch_rejects_the_application :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", pong)

	// One healthy request first — this is what closes the window.
	testing.expect_value(t, web.test_request(&app, .GET, "/ping").status, web.Status.OK)

	web.limits(&app, web.DEFAULT_LIMITS)

	testing.expect_value(
		t,
		web.test_request(&app, .GET, "/ping").status,
		web.Status.Internal_Server_Error,
	)
}

// AND IT SITS BESIDE ADR-019/ADR-023 RATHER THAN REPLACING THEM. `use()` after
// the first dispatch is still refused for its own reason: the snapshot model
// added an offence, it did not subsume one. If this ever goes green, a shipped
// fail-closed guarantee has been silently withdrawn.
@(test)
wp36_the_older_use_after_dispatch_guard_is_untouched :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", pong)
	testing.expect_value(t, web.test_request(&app, .GET, "/ping").status, web.Status.OK)

	web.use(&app, passthrough)

	testing.expect_value(
		t,
		web.test_request(&app, .GET, "/ping").status,
		web.Status.Internal_Server_Error,
	)
}

@(private = "file")
passthrough :: proc(ctx: ^web.Context) {
	web.next(ctx)
}

// Order relative to routes does NOT matter, and that is deliberate: a limit
// protects every route equally, so there is no ordering hazard of the kind
// ADR-019 exists for. Configuring after registering must stay legal, or a
// perfectly safe program would be rejected for resembling an unsafe one.
@(test)
wp36_limits_after_a_registration_is_legal :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)

	web.post(&app, "/echo", echo_body)
	budget := web.DEFAULT_LIMITS
	budget.max_body = 64
	web.limits(&app, budget)

	over_limit := body_of_size(65)
	defer delete(over_limit)

	testing.expect_value(
		t,
		web.test_request(&app, .POST, "/echo", over_limit).status,
		web.Status(413),
	)
}
