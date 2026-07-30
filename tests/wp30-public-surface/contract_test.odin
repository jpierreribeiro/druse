// WP30 public-surface contract — registration conflict diagnostics.
//
// NO PUBLIC SYMBOL IS ADDED. The five verbs, `mount` and `serve` keep their
// exact signatures; registration still returns void and still reports through
// the ADR-019 fail-closed mechanism rather than a return value. The ledger does
// not move. What changed is that a registration which could never have served
// now says so.
//
// WHAT AN APPLICATION CAN ACTUALLY SEE, and this file is deliberately confined
// to it: the 500. `poisoned` is private, the diagnostic goes to the log, and an
// application has no way to ask "am I rejected?" — by design, because the
// answer is meant to be a boot failure a developer reads, not a runtime
// condition a program routes around. The internal half of the contract is
// `tests/wp30-internal/`.
package test_wp30_public

import "core:log"
import "core:strings"
import "core:testing"
import web "druse:web"

// The rejection is an EXPECTED Error-level `druse:` line, and the pinned test
// runner records Error output as a failure. This swallows exactly those and
// forwards everything else — the WP8 idiom, reused rather than reinvented.
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
ok :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "served")
}

// The observable contract in one test: register the same route twice and the
// application answers 500 to everything, instead of quietly serving the first
// registration and pretending the second was never written.
@(test)
wp30_a_duplicate_registration_rejects_the_application :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/users", ok)
	web.get(&app, "/users", ok)

	res := web.test_request(&app, .GET, "/users")
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
}

// AND IT TAKES THE HEALTHY ROUTES WITH IT. This is the part that makes it a
// boot failure rather than a per-route penalty: a rejected application serves
// nothing, so the failure is impossible to miss in the first minute of testing
// and impossible to ship past.
@(test)
wp30_the_rejection_covers_routes_that_never_conflicted :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/health", ok)
	web.post(&app, "/orders", ok)
	web.post(&app, "/orders", ok)

	res := web.test_request(&app, .GET, "/health")
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
}

// Two spellings of one route. An application author reading `/users/:id` and
// `/users/:uid` sees two lines; the router sees one slot, and always did — the
// difference is that Phase 1 kept the disagreement to itself.
@(test)
wp30_two_spellings_of_one_parametric_route_are_rejected :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/users/:id", ok)
	web.get(&app, "/users/:uid", ok)

	res := web.test_request(&app, .GET, "/users/42")
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
}

// A prefix is path construction, so a mount can compose a collision. The
// application is rejected for the same reason and with the same mechanism.
@(test)
wp30_a_mount_prefix_can_compose_a_collision :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	r := web.router()
	defer web.destroy(&r)

	web.get(&app, "/api/users", ok)
	web.get(&r, "/users", ok)
	web.mount(&app, "/api", &r)

	res := web.test_request(&app, .GET, "/api/users")
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
}

// ---------------------------------------------------------------------------
// The half that has to keep working, tested just as hard. A rejection policy
// that quietly grew would break applications whose routes were legal the day
// they were written.
// ---------------------------------------------------------------------------

// A REST resource: one path, five methods. Not a conflict, and never was.
@(test)
wp30_one_path_under_every_method_still_serves :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/users", ok)
	web.post(&app, "/users", ok)
	web.put(&app, "/users", ok)
	web.patch(&app, "/users", ok)
	web.delete(&app, "/users", ok)

	testing.expect_value(t, web.test_request(&app, .GET, "/users").status, web.Status.OK)
	testing.expect_value(t, web.test_request(&app, .DELETE, "/users").status, web.Status.OK)
}

// The precedence case WP4 pinned: a literal segment and a parameter at the same
// depth are two routes, and the literal wins the match.
@(test)
wp30_static_and_parametric_at_the_same_depth_still_serve :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/users/me", ok)
	web.get(&app, "/users/:id", ok)

	testing.expect_value(t, web.test_request(&app, .GET, "/users/me").status, web.Status.OK)
	testing.expect_value(t, web.test_request(&app, .GET, "/users/42").status, web.Status.OK)
}

// `/users` and `/users/` remain distinct — the meaning WP31 ratified. If the
// conflict rule ever merged them, this application would stop serving.
@(test)
wp30_the_trailing_slash_pair_still_serves :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/users", ok)
	web.get(&app, "/users/", ok)

	testing.expect_value(t, web.test_request(&app, .GET, "/users").status, web.Status.OK)
	testing.expect_value(t, web.test_request(&app, .GET, "/users/").status, web.Status.OK)
}

// The same router shape mounted at two prefixes — the reason prefixes exist.
@(test)
wp30_two_versions_of_one_api_still_serve :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	v1 := web.router()
	defer web.destroy(&v1)
	v2 := web.router()
	defer web.destroy(&v2)

	web.get(&v1, "/users", ok)
	web.get(&v2, "/users", ok)
	web.mount(&app, "/v1", &v1)
	web.mount(&app, "/v2", &v2)

	testing.expect_value(t, web.test_request(&app, .GET, "/v1/users").status, web.Status.OK)
	testing.expect_value(t, web.test_request(&app, .GET, "/v2/users").status, web.Status.OK)
}

// Deep, distinct, multi-parameter routes — the WP33 shapes — are still
// unrelated to each other.
@(test)
wp30_distinct_multi_parameter_routes_still_serve :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/orgs/:org/repos/:repo", ok)
	web.get(&app, "/orgs/:org/members/:user", ok)

	testing.expect_value(
		t,
		web.test_request(&app, .GET, "/orgs/acme/repos/druse").status,
		web.Status.OK,
	)
	testing.expect_value(
		t,
		web.test_request(&app, .GET, "/orgs/acme/members/jp").status,
		web.Status.OK,
	)
}
