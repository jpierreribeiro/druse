// WP34 public-surface contract — `web.route`, the route identity accessor.
//
// ONE SYMBOL: `route :: proc(ctx: ^Context) -> string`. The ledger moves 44 →
// 45, and the whole contract is about WHICH STRING comes back.
//
// THE PATTERN, NEVER THE PATH. `/users/:id`, not `/users/42`. That is C-2's
// constraint — the OpenTelemetry `http.route` rule — and it is the reason this
// accessor is worth a symbol at all: an application that wanted the path
// already has `ctx.request.path`. What it could not get is the LOW-CARDINALITY
// identity, which is the only one safe to key a metric on.
//
// The rule is also a gate assertion (`build/check_public_api.sh` §8b), because
// a test can only check the routes it thought to write while the assertion
// checks every assignment to the slot. Both exist; neither substitutes for the
// other.
//
// ONE SINK PER TEST, through `context.user_ptr` — the WP17 idiom. The pinned
// runner runs tests on eight threads, so a file-scope capture variable shared
// by two tests is a data race that fails at random rather than a convenience.
package test_wp34_public

import "core:log"
import "core:strings"
import "core:testing"
import web "druse:web"

// One test deliberately provokes a framework diagnostic, and the pinned runner
// records any Error-level line as a failure. This swallows exactly the
// `druse:` Error lines and FORWARDS everything else — `testing.expect`
// reports through `context.logger`, so a swallow-everything logger would make
// the test unable to fail (the defect WP17's mutation control 6 caught).
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
Sink :: struct {
	route:       string,
	event_route: string,
	handler_ran: bool,
	events:      int,
}

@(private = "file")
sink_of :: proc(ctx: ^web.Context) -> ^Sink {
	return (^Sink)(context.user_ptr)
}

@(private = "file")
capture :: proc(ctx: ^web.Context) {
	s := sink_of(ctx)
	s.route = web.route(ctx)
	s.handler_ran = true
	web.no_content(ctx)
}

// The signature is pinned by ASSIGNMENT, not by description: this compiles only
// if `web.route` has exactly this shape, so a changed parameter or result is a
// build failure in the contract suite rather than a surprise downstream.
@(test)
wp34_the_route_signature_is_pinned :: proc(t: ^testing.T) {
	pinned: proc(ctx: ^web.Context) -> string = web.route
	testing.expect(t, pinned != nil, "web.route must have the ratified shape")
}

// THE TEST THIS WORK PACKAGE EXISTS FOR. A parametric route must report its
// pattern, and the path that produced it must not appear anywhere in the answer.
@(test)
wp34_a_parametric_route_reports_the_pattern_and_never_the_path :: proc(t: ^testing.T) {
	sink: Sink
	context.user_ptr = &sink

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/users/:id", capture)

	res := web.test_request(&app, .GET, "/users/42")
	testing.expect_value(t, res.status, web.Status.No_Content)
	testing.expect(t, sink.handler_ran, "the handler must have run")
	testing.expect_value(t, sink.route, "/users/:id")
}

// Two requests to the same route produce the SAME string. That is the property
// a metrics label needs and the one a path-valued answer would destroy: two
// users would be two time series.
@(test)
wp34_two_requests_to_one_route_report_one_identity :: proc(t: ^testing.T) {
	sink: Sink
	context.user_ptr = &sink

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/users/:id", capture)

	web.test_request(&app, .GET, "/users/1")
	first := sink.route
	web.test_request(&app, .GET, "/users/999999")

	testing.expect_value(t, sink.route, first)
	testing.expect_value(t, sink.route, "/users/:id")
}

// Several parameters, the WP33 shapes: every `:name` survives verbatim and no
// captured value leaks in.
@(test)
wp34_a_multi_parameter_route_reports_every_parameter_by_name :: proc(t: ^testing.T) {
	sink: Sink
	context.user_ptr = &sink

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/orgs/:org/repos/:repo", capture)

	web.test_request(&app, .GET, "/orgs/acme/repos/druse")
	testing.expect_value(t, sink.route, "/orgs/:org/repos/:repo")
}

// A static route is its own identity — the case where pattern and path are the
// same string, which is exactly why it proves nothing on its own and why the
// parametric tests above carry the contract.
@(test)
wp34_a_static_route_reports_itself :: proc(t: ^testing.T) {
	sink: Sink
	context.user_ptr = &sink

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/health", capture)

	web.test_request(&app, .GET, "/health")
	testing.expect_value(t, sink.route, "/health")
}

// A MOUNTED route reports the COMPOSED pattern — the path it actually serves,
// not the one it was registered with on the Router. Anything else would name a
// route that does not exist in the running application.
@(test)
wp34_a_mounted_route_reports_the_composed_pattern :: proc(t: ^testing.T) {
	sink: Sink
	context.user_ptr = &sink

	app := web.app()
	defer web.destroy(&app)
	r := web.router()
	defer web.destroy(&r)

	web.get(&r, "/users/:id", capture)
	web.mount(&app, "/api", &r)

	web.test_request(&app, .GET, "/api/users/7")
	testing.expect_value(t, sink.route, "/api/users/:id")
}

// ---------------------------------------------------------------------------
// The miss
// ---------------------------------------------------------------------------

@(private = "file")
observe_route :: proc(ctx: ^web.Context) {
	s := sink_of(ctx)
	s.route = web.route(ctx)
	s.handler_ran = true
	web.next(ctx)
}

// NO ROUTE MEANS THE EMPTY STRING, and that is the answer rather than an error.
// The framework cannot supply an identity for a request that matched nothing,
// and inventing one — the path, say — would be worse than saying nothing
// (§6.2, the same rule `Framework_Event.route` follows). Middleware runs on a
// miss (ADR-023), which is how this is observable at all.
@(test)
wp34_a_miss_has_no_route :: proc(t: ^testing.T) {
	sink: Sink
	sink.route = "unset"
	context.user_ptr = &sink

	app := web.app()
	defer web.destroy(&app)
	web.use(&app, observe_route)
	web.get(&app, "/health", capture)

	res := web.test_request(&app, .GET, "/nothing/here")
	testing.expect_value(t, res.status, web.Status.Not_Found)
	testing.expect(t, sink.handler_ran, "app middleware must run on a miss")
	testing.expect_value(t, sink.route, "")
}

// A 405 is a miss for this purpose too: the PATH is known, the ROUTE is not —
// no entry was selected for this method — so there is no identity to report.
// Reporting the other method's pattern would name a route that did not run.
@(test)
wp34_a_405_has_no_route_either :: proc(t: ^testing.T) {
	sink: Sink
	sink.route = "unset"
	context.user_ptr = &sink

	app := web.app()
	defer web.destroy(&app)
	web.use(&app, observe_route)
	web.get(&app, "/users/:id", capture)

	res := web.test_request(&app, .POST, "/users/42")
	testing.expect_value(t, res.status, web.Status.Method_Not_Allowed)
	testing.expect_value(t, sink.route, "")
}

// ---------------------------------------------------------------------------
// G-01: one question, one name
// ---------------------------------------------------------------------------

// The observer receives the event BY VALUE and receives no Context, so it
// cannot reach the sink through `sink_of`. It reads `context.user_ptr` the same
// way — the observer runs on the request's own thread, inside `test_request`.
@(private = "file")
observer :: proc(event: web.Framework_Event) {
	s := (^Sink)(context.user_ptr)
	if s == nil {
		return
	}
	s.event_route = event.route
	s.events += 1
}

@(private = "file")
capture_then_commit_nothing :: proc(ctx: ^web.Context) {
	s := sink_of(ctx)
	s.route = web.route(ctx)
	s.handler_ran = true
	// Deliberately commits no response: the driver finalizes it as a 500 and
	// reports `No_Response_Committed`, which is a framework failure INSIDE a
	// request — so the event carries the request's own route identity.
}

// `web.route(ctx)` and `Framework_Event.route` must be the SAME STRING. They
// read one slot and answer one question, and the reason the accessor is not
// called `route_pattern` or `matched_route` is precisely so that nobody has to
// be told these two are the same thing. If they ever diverge, this goes red.
@(test)
wp34_the_accessor_and_the_event_report_one_identity :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)
	sink: Sink
	context.user_ptr = &sink

	app := web.app()
	defer web.destroy(&app)
	web.observe(&app, observer)
	web.get(&app, "/orders/:ref", capture_then_commit_nothing)

	res := web.test_request(&app, .GET, "/orders/abc123")
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
	testing.expect_value(t, sink.events, 1)
	testing.expect_value(t, sink.route, "/orders/:ref")
	testing.expect_value(t, sink.event_route, sink.route)
}
