// WP30 internal behaviour tests — registration conflict diagnostics.
//
// THE DEBT THIS PAYS. WP4 D5 deliberately left a duplicate registration
// undiagnosed: the second route was stored, never matched, and nothing said so.
// Phase 3 decided the arm — diagnose-and-poison, resolved under the ADR-029
// delegation (`planning/phase-3-plan.md` §2b) — and this suite is the half that
// makes it real rather than merely written down.
//
// WHY THE SUITE IS INTERNAL. The three things worth asserting are all
// package-private: `a.private.poisoned` (the predicate — registration returns
// void and cannot signal by return), the composed diagnostic text, and the fact
// that `serve` takes the POISON branch rather than the invalid-port one. The
// public half of the contract lives in `tests/wp30-public-surface/`, where an
// application can only see the 500.
//
// The capture logger FORWARDS everything that is not a `druse:` Error line,
// because `testing.expect` reports through `context.logger` and a
// swallow-everything logger makes a test unable to fail — the defect WP17's
// mutation control 6 caught, and the reason this idiom is copied rather than
// reinvented.
#+private
package web

import "base:runtime"
import "core:testing"
import transport "druse:web/internal/transport"

// ---------------------------------------------------------------------------
// Harness (the WP18 shape)
// ---------------------------------------------------------------------------

@(private = "file")
Wp30_Sink :: struct {
	log_buf:   [4096]u8,
	log_n:     int,
	log_lines: int,
	inner:     runtime.Logger,
}

@(private = "file")
wp30_contains :: proc(haystack: string, needle: string) -> bool {
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
wp30_capture_logger_proc :: proc(
	data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options,
	location := #caller_location,
) {
	sink := (^Wp30_Sink)(data)
	if level == .Error && wp30_contains(text, "druse:") {
		sink.log_lines += 1
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
wp30_capture_logger :: proc(sink: ^Wp30_Sink) -> runtime.Logger {
	sink.inner = context.logger
	return runtime.Logger {
		procedure    = wp30_capture_logger_proc,
		data         = sink,
		lowest_level = .Debug,
		options      = context.logger.options,
	}
}

@(private = "file")
wp30_logged :: proc(sink: ^Wp30_Sink) -> string {
	return string(sink.log_buf[:sink.log_n])
}

@(private = "file")
wp30_run :: proc(a: ^App, ctx: ^Context, method: Method, path: string) {
	driver_run(a, ctx, transport.Inbound{method = method_token(method), path = path})
}

@(private = "file")
wp30_handler :: proc(ctx: ^Context) {
	no_content(ctx)
}

@(private = "file")
wp30_observed: Framework_Event
@(private = "file")
wp30_observed_n: int

@(private = "file")
wp30_observer :: proc(event: Framework_Event) {
	wp30_observed = event
	wp30_observed_n += 1
}

// ---------------------------------------------------------------------------
// The conflict itself
// ---------------------------------------------------------------------------

// The plain case: the same method and the same pattern, twice. Phase 1 kept the
// first and dropped the second in silence; the application is now rejected.
@(test)
wp30_a_duplicate_method_and_pattern_poisons_the_app :: proc(t: ^testing.T) {
	sink: Wp30_Sink
	context.logger = wp30_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	get(&a, "/users", wp30_handler)
	testing.expect(t, !a.private.poisoned, "one registration must not poison anything")

	get(&a, "/users", wp30_handler)
	testing.expect(t, a.private.poisoned, "the duplicate must reject the application")
	testing.expect(
		t,
		wp30_contains(wp30_logged(&sink), "two routes were registered for the same method"),
		"the conflict must produce its own diagnostic",
	)
}

// THE CASE A TEXT COMPARISON WOULD MISS, and the reason the detection lives in
// the index rather than beside the patterns. `:id` and `:uid` are different
// strings and the same route: both walk to the same parametric child, because a
// node has ONE parametric child whatever it is called. The second route could
// never serve, so it is diagnosed exactly like the literal duplicate.
@(test)
wp30_parameter_names_do_not_distinguish_two_routes :: proc(t: ^testing.T) {
	sink: Wp30_Sink
	context.logger = wp30_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	get(&a, "/users/:id", wp30_handler)
	get(&a, "/users/:uid", wp30_handler)

	testing.expect(t, a.private.poisoned, "same shape, different parameter name, still one route")
}

// The diagnostic NAMES the offending route, through the fixed buffer. A
// diagnostic that says "somewhere you registered something twice" is a 3 a.m.
// failure; this one can be pasted into a grep.
@(test)
wp30_the_diagnostic_names_the_losing_route :: proc(t: ^testing.T) {
	sink: Wp30_Sink
	context.logger = wp30_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	post(&a, "/orders/:ref", wp30_handler)
	post(&a, "/orders/:reference", wp30_handler)

	testing.expect(
		t,
		wp30_contains(wp30_logged(&sink), "Offending route: \"POST /orders/:reference\""),
		"the composed tail must carry the method and the pattern that lost",
	)
}

// THE FIRST DIAGNOSIS STANDS — the rule the whole ADR-019 family shares. A
// third colliding registration must not add a second sentence: `route_register`
// takes its early exit on a poisoned App, so the log holds exactly one line.
@(test)
wp30_only_the_first_conflict_is_reported :: proc(t: ^testing.T) {
	sink: Wp30_Sink
	context.logger = wp30_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	get(&a, "/users", wp30_handler)
	get(&a, "/users", wp30_handler)
	get(&a, "/users", wp30_handler)
	get(&a, "/users", wp30_handler)

	testing.expect_value(t, sink.log_lines, 1)
}

// ---------------------------------------------------------------------------
// What the rejection means
// ---------------------------------------------------------------------------

// Fail-closed is not advisory: every request answers 500, including one to the
// route that registered cleanly before the conflict existed.
@(test)
wp30_a_conflicted_app_answers_500_everywhere :: proc(t: ^testing.T) {
	sink: Wp30_Sink
	context.logger = wp30_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	get(&a, "/healthy", wp30_handler)
	get(&a, "/users", wp30_handler)
	get(&a, "/users", wp30_handler)

	ctx: Context
	wp30_run(&a, &ctx, .GET, "/healthy")
	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
	driver_cleanup(&ctx)
}

// `serve` REFUSES TO BIND, and this asserts which branch it took rather than
// merely that it returned. The port is 0 — invalid — so a `serve` that had lost
// its poison guard would still not bind, but would report `.Invalid_Serve_Port`
// instead. The observer tells the two apart, which is what makes this a test of
// the rejection and not of the port check.
@(test)
wp30_serve_refuses_a_conflicted_app_before_it_looks_at_the_port :: proc(t: ^testing.T) {
	sink: Wp30_Sink
	context.logger = wp30_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	observe(&a, wp30_observer)
	wp30_observed = Framework_Event{}
	wp30_observed_n = 0

	get(&a, "/users", wp30_handler)
	get(&a, "/users", wp30_handler)

	serve(&a, 0)
	testing.expect_value(t, wp30_observed_n, 1)
	testing.expect_value(t, wp30_observed.kind, Framework_Error.Use_After_Route)
}

// ---------------------------------------------------------------------------
// What is NOT a conflict — the larger half, because a rejection rule that
// quietly grew would reject applications that were correct the day they were
// written.
// ---------------------------------------------------------------------------

// Per-method isolation is the whole point of the `by_method` array: the same
// path under two methods is two routes and always was.
@(test)
wp30_the_same_pattern_under_two_methods_is_not_a_conflict :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "/users", wp30_handler)
	post(&a, "/users", wp30_handler)
	put(&a, "/users", wp30_handler)
	patch(&a, "/users", wp30_handler)
	delete(&a, "/users", wp30_handler)

	testing.expect(t, !a.private.poisoned, "five methods on one path are five routes")
}

// Static and parametric at the same depth are DIFFERENT nodes — the static
// child and the parametric child — so registering both is the ordinary
// precedence case WP4 pinned, not a collision.
@(test)
wp30_static_and_parametric_siblings_are_not_a_conflict :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "/users/me", wp30_handler)
	get(&a, "/users/:id", wp30_handler)

	testing.expect(t, !a.private.poisoned, "static over parametric is precedence, not conflict")

	ctx: Context
	wp30_run(&a, &ctx, .GET, "/users/me")
	testing.expect_value(t, ctx.private.response.status, Status.No_Content)
	driver_cleanup(&ctx)
}

// The trailing slash keeps the meaning WP31 ratified: `/users` and `/users/`
// are two distinct patterns. If the conflict rule ever decided they were one,
// this goes red — which is the point of writing it down here rather than
// trusting that nobody will.
@(test)
wp30_a_trailing_slash_is_still_a_distinct_pattern :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "/users", wp30_handler)
	get(&a, "/users/", wp30_handler)

	testing.expect(t, !a.private.poisoned, "the trailing slash keeps its Phase-1 meaning")
}

// An INVALID pattern is not indexed at all, so it cannot occupy a slot and
// cannot collide. Registering the same unusable pattern twice is therefore not
// a conflict — and that is the honest answer rather than an oversight: neither
// registration could ever serve, so there is no second route being silently
// shadowed by a first. `pattern_classify` already refuses both.
@(test)
wp30_two_invalid_patterns_do_not_collide :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "users", wp30_handler)
	get(&a, "users", wp30_handler)

	testing.expect(t, !a.private.poisoned, "an unusable pattern occupies no slot")
}

// ---------------------------------------------------------------------------
// The interaction the plan named: mount
// ---------------------------------------------------------------------------

// A prefix composes a pattern, and a composed pattern can collide with one
// registered directly. Nothing in `mount` compares strings for this — the
// composed route reaches `index_insert` exactly like any other, and the
// occupied slot does the work.
@(test)
wp30_a_mounted_route_can_collide_with_a_direct_one :: proc(t: ^testing.T) {
	sink: Wp30_Sink
	context.logger = wp30_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	r := router()
	defer destroy(&r)

	get(&a, "/api/users", wp30_handler)
	get(&r, "/users", wp30_handler)
	mount(&a, "/api", &r)

	testing.expect(t, a.private.poisoned, "the composed pattern collides and is diagnosed")
	testing.expect(
		t,
		wp30_contains(wp30_logged(&sink), "Offending route: \"GET /api/users\""),
		"the diagnostic must name the COMPOSED pattern, which is what collided",
	)
}

// Mounting the same router shape at two different prefixes is the reason
// prefixes exist. It must stay legal.
@(test)
wp30_two_prefixes_are_not_a_conflict :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	r1 := router()
	defer destroy(&r1)
	r2 := router()
	defer destroy(&r2)

	get(&r1, "/users", wp30_handler)
	get(&r2, "/users", wp30_handler)
	mount(&a, "/v1", &r1)
	mount(&a, "/v2", &r2)

	testing.expect(t, !a.private.poisoned, "the same shape under two prefixes is two routes")
}

// A conflict inside a mount STOPS the copy: the rest of the router is not
// appended into an application that is already rejected, and no second
// diagnostic is emitted.
@(test)
wp30_a_conflict_during_mount_stops_at_the_first_diagnosis :: proc(t: ^testing.T) {
	sink: Wp30_Sink
	context.logger = wp30_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	r := router()
	defer destroy(&r)

	// BOTH mounted routes would collide. The second one is what makes this a
	// test rather than a tautology: `mount` must stop at the first diagnosis,
	// not walk the rest of the router logging one sentence per route.
	get(&a, "/api/one", wp30_handler)
	get(&a, "/api/two", wp30_handler)
	get(&r, "/one", wp30_handler)
	get(&r, "/two", wp30_handler)
	mount(&a, "/api", &r)

	testing.expect(t, a.private.poisoned, "the first mounted route collides")
	testing.expect_value(t, sink.log_lines, 1)
}
