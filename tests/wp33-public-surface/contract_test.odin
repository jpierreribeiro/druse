// WP33 public-surface contract — more than one path parameter.
//
// Phase 1 supported AT MOST ONE `:param` and marked any pattern with more as
// invalid. WP33 raises that bound to `ROUTE_PARAM_MAX` using C-6's convergent
// design: a small fixed inline array of views in request-local storage. Not a
// map, not an allocation, not a bag.
//
// NO PUBLIC SYMBOL IS ADDED. `web.path` and `web.path_int` keep their exact
// signatures and stay the one canonical accessor (G-01). What changed is how
// many questions they can answer, not how you ask them.
//
// G-03 IS THE BOUNDARY, and it is worth stating in a test file because the
// temptation is real: this adds CAPACITY to an existing private slot. It does
// not add a general-purpose keyed store, there is still no `ctx.params`, and
// there never will be.
package test_wp33_public

import "core:testing"
import web "druse:web"

// ONE SINK PER TEST, never one shared between two. The pinned runner runs tests
// on eight threads by default, so a file-scope variable written by two handlers
// and reset by two tests is a data race that fails at random — `captured_org`
// was exactly that, shared by `three_params` and `one_param`, and it went red
// once under an unrelated change before anyone looked at it. Found and fixed
// during WP30; the defect predates it.
@(private = "file")
captured_org: string
@(private = "file")
captured_repo: string
@(private = "file")
captured_number: int
@(private = "file")
captured_id: string

@(private = "file")
three_params :: proc(ctx: ^web.Context) {
	captured_org = web.path(ctx, "org")
	captured_repo = web.path(ctx, "repo")
	number, ok := web.path_int(ctx, "number")
	if !ok {
		return
	}
	captured_number = number
	web.no_content(ctx)
}

@(private = "file")
one_param :: proc(ctx: ^web.Context) {
	captured_id = web.path(ctx, "id")
	web.no_content(ctx)
}

// The shape every REST API eventually needs, and which Phase 1 refused.
@(test)
wp33_three_parameters_are_captured_in_order :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/orgs/:org/repos/:repo/issues/:number", three_params)

	captured_org = ""
	captured_repo = ""
	captured_number = 0

	res := web.test_request(&app, .GET, "/orgs/acme/repos/druse/issues/42")
	testing.expect_value(t, res.status, web.Status.No_Content)
	testing.expect_value(t, captured_org, "acme")
	testing.expect_value(t, captured_repo, "druse")
	testing.expect_value(t, captured_number, 42)
}

// Order is by position in the PATTERN, not by lookup order, and asking for a
// name that is not declared still returns the empty string rather than
// "whichever parameter happens to be captured".
@(test)
wp33_an_undeclared_name_returns_empty :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/a/:first/b/:second", check_names)

	res := web.test_request(&app, .GET, "/a/one/b/two")
	testing.expect_value(t, res.status, web.Status.No_Content)
}

@(private = "file")
check_names :: proc(ctx: ^web.Context) {
	if web.path(ctx, "first") != "one" {
		return
	}
	if web.path(ctx, "second") != "two" {
		return
	}
	// A name no segment declares.
	if web.path(ctx, "third") != "" {
		return
	}
	web.no_content(ctx)
}

// The single-parameter case is untouched: WP33 raised a bound, it did not
// change the shape of the answer.
@(test)
wp33_one_parameter_still_works :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/users/:id", one_param)

	captured_id = ""
	res := web.test_request(&app, .GET, "/users/7")
	testing.expect_value(t, res.status, web.Status.No_Content)
	testing.expect_value(t, captured_id, "7")
}

// Static still beats parametric, at every level, with several parameters in
// play. This is where a multi-parameter tree is most likely to go wrong.
@(test)
wp33_static_still_wins_with_several_parameters :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/a/:x/b/:y", parametric_marker)
	web.get(&app, "/a/fixed/b/:y", static_marker)

	marker = ""
	res := web.test_request(&app, .GET, "/a/fixed/b/two")
	testing.expect_value(t, res.status, web.Status.No_Content)
	testing.expect_value(t, marker, "static")

	marker = ""
	other := web.test_request(&app, .GET, "/a/moving/b/two")
	testing.expect_value(t, other.status, web.Status.No_Content)
	testing.expect_value(t, marker, "parametric")
}

@(private = "file")
marker: string

@(private = "file")
parametric_marker :: proc(ctx: ^web.Context) {
	marker = "parametric"
	web.no_content(ctx)
}

@(private = "file")
static_marker :: proc(ctx: ^web.Context) {
	marker = "static"
	web.no_content(ctx)
}

// THE BOUND, and what happens when it is exceeded — the capacity ledger does
// not accept a bound without this half.
//
// A pattern declaring more than ROUTE_PARAM_MAX parameters is INVALID at
// registration: it never matches, exactly as a two-param pattern did in Phase
// 1. Fail-closed, and a 404 rather than a partial capture.
@(test)
wp33_a_pattern_beyond_the_bound_never_matches :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	// Nine parameters, one past the eight-slot bound.
	web.get(&app, "/:a/:b/:c/:d/:e/:f/:g/:h/:i", one_param)

	res := web.test_request(&app, .GET, "/1/2/3/4/5/6/7/8/9")
	testing.expect_value(t, res.status, web.Status.Not_Found)
}

// Exactly at the bound still works, so the limit is the number stated and not
// one less.
@(test)
wp33_the_bound_itself_is_usable :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/:a/:b/:c/:d/:e/:f/:g/:h", eight_params)

	res := web.test_request(&app, .GET, "/1/2/3/4/5/6/7/8")
	testing.expect_value(t, res.status, web.Status.No_Content)
}

@(private = "file")
eight_params :: proc(ctx: ^web.Context) {
	if web.path(ctx, "a") != "1" {
		return
	}
	if web.path(ctx, "h") != "8" {
		return
	}
	web.no_content(ctx)
}
