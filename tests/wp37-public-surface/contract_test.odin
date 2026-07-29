// WP37 public-surface contract — typed application state.
//
// TWO SYMBOLS, ledger 45 → 47: `app_with_state` builds the application around
// one value, `state` reads it back typed. ADR-004 option A, delivered — a
// `rawptr` plus a `typeid` privately, and an accessor that asserts before it
// casts.
//
// THE CALL SITE IS THE POINT. `web.state(ctx, App_State)` carries no generic
// noise, which is exactly what ADR-004 chose option A for: option B — a
// parametric `App(S)`/`Context(S)` — would put a type argument on every handler
// signature in the program. The price is a runtime assert instead of a compile
// error, and this suite is where that price is looked at rather than assumed.
//
// WHAT THIS IS NOT. There is no request-scoped state and there will not be one
// (ADR-028, option 1, ACCEPTED). This is ONE value, APP-scoped, set before
// serving. The auth example's revalidation cost is unaffected and nothing here
// promises to remove it.
package test_wp37_public

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
App_State :: struct {
	name:  string,
	calls: int,
}

@(private = "file")
Other_State :: struct {
	n: int,
}

@(private = "file")
read_name :: proc(ctx: ^web.Context) {
	s, state_ok := web.state(ctx, App_State)
	if !state_ok {
		web.internal_error(ctx)
		return
	}
	web.text(ctx, .OK, s.name)
}

@(private = "file")
bump :: proc(ctx: ^web.Context) {
	s, state_ok := web.state(ctx, App_State)
	if !state_ok {
		web.internal_error(ctx)
		return
	}
	s.calls += 1
	web.no_content(ctx)
}

// Both signatures are pinned by ASSIGNMENT for `state`'s non-generic half and
// by USE for the generic one: a parametric procedure cannot be stored in a
// variable, so the shape is pinned by the fact that these calls compile at all.
// A changed parameter or result is a build failure in the contract suite.
@(test)
wp37_the_state_signatures_are_pinned :: proc(t: ^testing.T) {
	value := App_State{name = "pinned"}
	app := web.app_with_state(&value)
	defer web.destroy(&app)

	web.get(&app, "/name", read_name)
	res := web.test_request(&app, .GET, "/name")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "pinned")
}

// THE PROPERTY THAT MAKES IT USEFUL: the App holds the POINTER, so a handler
// writing through it mutates the caller's own value. A copy would be a second
// database pool, which is the failure this design exists to avoid.
@(test)
wp37_a_handler_mutates_the_original_value :: proc(t: ^testing.T) {
	value := App_State{name = "counter"}
	app := web.app_with_state(&value)
	defer web.destroy(&app)

	web.post(&app, "/bump", bump)
	web.test_request(&app, .POST, "/bump")
	web.test_request(&app, .POST, "/bump")
	web.test_request(&app, .POST, "/bump")

	testing.expect_value(t, value.calls, 3)
}

// TWO APPLICATIONS, TWO STATES. There is no global slot and no registry: the
// value hangs off the App, so two Apps in one program never see each other's.
@(test)
wp37_two_applications_hold_distinct_states :: proc(t: ^testing.T) {
	first_value := App_State{name = "first"}
	second_value := App_State{name = "second"}

	first := web.app_with_state(&first_value)
	defer web.destroy(&first)
	second := web.app_with_state(&second_value)
	defer web.destroy(&second)

	web.get(&first, "/name", read_name)
	web.get(&second, "/name", read_name)

	testing.expect_value(t, web.test_request(&first, .GET, "/name").body, "first")
	testing.expect_value(t, web.test_request(&second, .GET, "/name").body, "second")

	// And they stay distinct after a mutation to one of them.
	web.post(&first, "/bump", bump)
	web.test_request(&first, .POST, "/bump")
	testing.expect_value(t, first_value.calls, 1)
	testing.expect_value(t, second_value.calls, 0)
}

// `app_with_state` gives the SAME defaults as `app()` — the automatic 404 and
// 405 — because it is `app()` with a value attached, not a third constructor
// with its own policy.
@(test)
wp37_an_app_with_state_keeps_the_default_responses :: proc(t: ^testing.T) {
	value := App_State{name = "defaults"}
	app := web.app_with_state(&value)
	defer web.destroy(&app)

	web.get(&app, "/name", read_name)

	testing.expect_value(
		t,
		web.test_request(&app, .GET, "/absent").status,
		web.Status.Not_Found,
	)
	testing.expect_value(
		t,
		web.test_request(&app, .POST, "/name").status,
		web.Status.Method_Not_Allowed,
	)
}

// The state survives the whole application, not one request: a value written
// during the first request is still there for the second. That is the LIFETIME
// difference between this and everything else reachable from a `^Context`.
@(test)
wp37_the_state_outlives_a_request :: proc(t: ^testing.T) {
	value := App_State{name = "persistent"}
	app := web.app_with_state(&value)
	defer web.destroy(&app)

	web.post(&app, "/bump", bump)
	web.get(&app, "/name", read_name)

	web.test_request(&app, .POST, "/bump")
	testing.expect_value(t, web.test_request(&app, .GET, "/name").body, "persistent")
	testing.expect_value(t, value.calls, 1)
}

// A NIL STATE REJECTS THE APPLICATION (AMEND-1). Fail-closed at construction is
// the same answer registration gives every other unusable input, and it is
// strictly better than the alternative: an App that accepted nil would abort
// inside the first request instead — the same failure, later, in front of a
// client.
@(test)
wp37_a_nil_state_rejects_the_application :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	nothing: ^App_State
	app := web.app_with_state(nothing)
	defer web.destroy(&app)

	web.get(&app, "/name", read_name)
	res := web.test_request(&app, .GET, "/name")
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)

	// STRENGTHENED BY AMENDMENT 39, and the reason is worth stating because the
	// control caught it rather than a human noticing.
	//
	// The 500 above no longer distinguishes what it was written to
	// distinguish. Before `web.state` returned `(^T, bool)`, only a POISONED
	// application could answer 500 here. Now a healthy application whose state
	// happens to be nil produces the same 500 by a completely different route:
	// `web.state` returns `(nil, false)` and `read_name` answers
	// `internal_error` itself. `build/check_wp37_controls.sh` deletes the nil
	// rejection in `app_with_state` and this test stayed GREEN — the defect had
	// become invisible to it.
	//
	// THE PROPERTY THAT STILL SEPARATES THEM: poisoning is APPLICATION-wide.
	// Every route answers 500, including one that never touches state at all.
	// A healthy-but-nil application serves this route normally.
	web.get(&app, "/untouched", untouched_by_state)
	untouched := web.test_request(&app, .GET, "/untouched")
	testing.expectf(
		t,
		untouched.status == web.Status.Internal_Server_Error,
		"a nil state must POISON the application, so a handler that never calls web.state answers 500 too; got %v. If this is 200, `app_with_state` accepted nil and built a healthy App — the failure moved into the first handler that wanted state, which is the later, client-facing failure the rejection exists to prevent.",
		untouched.status,
	)
}

// Deliberately does NOT call `web.state`. It is the probe for application-wide
// poisoning: it can only fail if the App itself was rejected.
@(private = "file")
untouched_by_state :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "no state needed")
}

// The state a handler reads is the state the App was built with, even when the
// same type is used by a Router mounted into it: `mount` copies routes, not
// state, and a mounted handler reads the APPLICATION's value.
@(test)
wp37_a_mounted_handler_reads_the_applications_state :: proc(t: ^testing.T) {
	value := App_State{name = "mounted"}
	app := web.app_with_state(&value)
	defer web.destroy(&app)
	r := web.router()
	defer web.destroy(&r)

	web.get(&r, "/name", read_name)
	web.mount(&app, "/api", &r)

	testing.expect_value(t, web.test_request(&app, .GET, "/api/name").body, "mounted")
}

// Middleware reads it too — the same Context, the same accessor. There is no
// separate "middleware state", which is the point of there being one name.
@(test)
wp37_middleware_reads_the_same_state :: proc(t: ^testing.T) {
	value := App_State{name = "shared"}
	app := web.app_with_state(&value)
	defer web.destroy(&app)

	web.use(&app, count_in_middleware)
	web.get(&app, "/name", read_name)

	web.test_request(&app, .GET, "/name")
	testing.expect_value(t, value.calls, 1)
}

@(private = "file")
count_in_middleware :: proc(ctx: ^web.Context) {
	s, state_ok := web.state(ctx, App_State)
	if !state_ok {
		web.internal_error(ctx)
		return
	}
	s.calls += 1
	web.next(ctx)
}

// The type registered is the type that must be asked for.
//
// AMENDED (Phase-1 freeze Amendment 39). This comment used to read: "this is
// the half a test cannot execute — a wrong type aborts the process by design
// (ADR-020), and a test that could observe it would mean the assert was not an
// assert". That was accurate while `state` asserted. It is no longer, and the
// difference is the point of the change: a wrong type now returns
// `(nil, false)` and the process survives, so the half that could not be
// executed is executed below, on real traffic, with the server still answering
// afterwards.
//
// What this case still pins is the compile-time half: `^Other_State` and
// `^App_State` are distinct types and not accidentally interchangeable.
@(test)
wp37_the_requested_type_decides_the_result_type :: proc(t: ^testing.T) {
	other := Other_State{n = 7}
	app := web.app_with_state(&other)
	defer web.destroy(&app)

	web.get(&app, "/n", read_other)
	testing.expect_value(t, web.test_request(&app, .GET, "/n").status, web.Status.OK)
	testing.expect_value(t, other.n, 8)
}

@(private = "file")
read_other :: proc(ctx: ^web.Context) {
	s, state_ok := web.state(ctx, Other_State)
	if !state_ok {
		web.internal_error(ctx)
		return
	}
	s.n += 1
	web.ok(ctx, s.n)
}

// --- Amendment 39: the two failures are survivable, and now observable ------
//
// THESE TESTS COULD NOT BE WRITTEN BEFORE. `web.state` asserted on both
// failures, and an assert aborts the test runner along with everything else —
// which is precisely why the wrong-type contract went untested for the whole
// life of the API and was pinned only by a build-time control.
//
// That is the argument for the change stated as evidence rather than as
// intent: Odin has no recoverable panic (ADR-020), so one handler asking for
// the wrong type stopped every in-flight request on every lane. It now answers
// `(nil, false)`, the application turns that into a 500 for the one request,
// and the server is still serving on the next line — which is what these
// assert.

@(private = "file")
wrong_type_handler :: proc(ctx: ^web.Context) {
	// Registered state is App_State. This asks for Other_State.
	s, ok := web.state(ctx, Other_State)
	if !ok {
		web.text(ctx, .Internal_Server_Error, "refused")
		return
	}
	web.text(ctx, .OK, "should not happen")
	_ = s
}

@(private = "file")
healthy_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "alive")
}

@(test)
wp37_a_wrong_type_is_refused_and_the_server_survives :: proc(t: ^testing.T) {
	value := App_State{name = "registered"}
	app := web.app_with_state(&value)
	defer web.destroy(&app)
	web.get(&app, "/wrong", wrong_type_handler)
	web.get(&app, "/healthy", healthy_handler)

	// The framework logs this refusal at Error level, which `core:testing`
	// would otherwise count as a test failure. Silence it for exactly this one
	// call and restore immediately — NOT with a `defer`, because a deferred
	// restore leaves the nil logger installed across the assertions below, and
	// `testing.expect*` reports failures through `context.logger`. That exact
	// mistake made another suite in this repository unable to fail.
	saved := context.logger
	context.logger = {}
	refused := web.test_request(&app, .GET, "/wrong")
	context.logger = saved

	testing.expect_value(t, refused.status, web.Status.Internal_Server_Error)
	testing.expect_value(t, refused.body, "refused")

	// THE HALF THAT MATTERS: the process is alive and the next request is
	// served normally. Under the old assert this line was unreachable — the
	// runner was gone.
	alive := web.test_request(&app, .GET, "/healthy")
	testing.expect_value(t, alive.status, web.Status.OK)
	testing.expect_value(t, alive.body, "alive")
}

@(test)
wp37_state_on_an_app_without_state_is_refused_and_survivable :: proc(t: ^testing.T) {
	// `web.app()` registers no state at all — the other failure mode.
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/wrong", wrong_type_handler)
	web.get(&app, "/healthy", healthy_handler)

	saved := context.logger
	context.logger = {}
	refused := web.test_request(&app, .GET, "/wrong")
	context.logger = saved

	testing.expect_value(t, refused.status, web.Status.Internal_Server_Error)
	alive := web.test_request(&app, .GET, "/healthy")
	testing.expect_value(t, alive.status, web.Status.OK)
}
