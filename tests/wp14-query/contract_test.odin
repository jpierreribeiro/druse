// WP14 (part 2) — QUERY STRINGS ARE REACHABLE IN MEMORY.
//
// `web.query`, `web.query_int` and `web.query_int_or` are part of the frozen
// Phase-1 surface, and until now none of them could be exercised through
// `test_request`: the facade filled `Inbound.path` and left `Inbound.query`
// empty, so every query lookup missed. Three frozen public procedures were
// untestable without opening a socket.
//
// `query` is a second fully visible default parameter rather than a procedure
// group, for the reason recorded in ADR-021: a group over private members pins
// only its NAME in the freeze snapshot, leaving the callable contract free to
// change. Both defaults appear in `odin doc`, so the whole contract stays frozen.
package test_wp14_query

import "core:mem"
import "core:testing"
import web "druse:web"

Search :: struct {
	q:    string,
	page: int,
}

search :: proc(ctx: ^web.Context) {
	q, found := web.query(ctx, "q")
	if !found {
		web.not_found(ctx, "query")
		return
	}
	page, ok := web.query_int_or(ctx, "page", 1)
	if !ok {
		return
	}
	web.ok(ctx, Search{q, page})
}

create_in_context :: proc(ctx: ^web.Context) {
	input: Search
	if !web.body(ctx, &input) {
		return
	}
	scope, found := web.query(ctx, "scope")
	if !found {
		web.bad_request(ctx, "scope is required")
		return
	}
	web.created(ctx, Search{scope, input.page})
}

@(test)
wp14_query_reaches_the_handler :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/search", search)

	res := web.test_request(&app, .GET, "/search", query = "q=hello")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, `{"q":"hello","page":1}`)
}

// The query is NOT part of the route path: a `?` inside `path` must not be
// mistaken for a query string, exactly as on a socket, where the transport
// splits the request target before the core ever sees it.
@(test)
wp14_query_is_not_part_of_the_route_path :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/search", search)

	res := web.test_request(&app, .GET, "/search?q=hello")

	testing.expect_value(t, res.status, web.Status.Not_Found)
}

@(test)
wp14_body_and_query_work_together :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/items", create_in_context)

	res := web.test_request(
		&app,
		.POST,
		"/items",
		`{"q":"ignored","page":7}`,
		query = "scope=admin",
	)

	testing.expect_value(t, res.status, web.Status.Created)
	testing.expect_value(t, res.body, `{"q":"admin","page":7}`)
}

// Absence must be byte-identical to the frozen extractor contract: `query`
// reports not-found and does NOT respond on its own.
@(test)
wp14_missing_query_follows_the_frozen_extractor_contract :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/search", search)

	res := web.test_request(&app, .GET, "/search")

	testing.expect_value(t, res.status, web.Status.Not_Found)
}

// Malformed must also be byte-identical: `query_int_or` substitutes its default
// ONLY on absence, never for a malformed value, which is a committed 400.
@(test)
wp14_malformed_query_int_is_the_frozen_400 :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/search", search)

	res := web.test_request(&app, .GET, "/search", query = "q=hello&page=abc")

	testing.expect_value(t, res.status, web.Status.Bad_Request)
}

@(test)
wp14_the_phase1_three_argument_form_is_unchanged :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/search", search)

	res := web.test_request(&app, .GET, "/search")

	testing.expect_value(t, res.status, web.Status.Not_Found)
}

@(test)
wp14_the_positional_body_form_is_unchanged :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/items", create_in_context)

	res := web.test_request(&app, .POST, "/items", `{"q":"x","page":1}`)

	testing.expect_value(t, res.status, web.Status.Bad_Request)
}

// Cleanup is a PROPERTY, not an assumption. Both call forms drive the same
// `driver_run`/`driver_cleanup` pair a socket uses, so a request that allocated
// a request arena must release it before `test_request` returns.
//
// Without this assertion the whole path is untested in the direction that
// matters: commenting out `driver_cleanup` leaves every behavioural test above
// still green, because a leak changes no status and no body. Verified — that
// mutation survived until this test existed.
@(test)
wp14_both_forms_release_the_request_arena :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	{
		app := web.app()
		defer web.destroy(&app)
		web.post(&app, "/items", create_in_context)

		// A body large enough to force nested allocation into the request arena.
		res := web.test_request(
			&app,
			.POST,
			"/items",
			`{"q":"a-string-long-enough-to-be-heap-allocated","page":3}`,
			query = "scope=admin",
		)
		testing.expect_value(t, res.status, web.Status.Created)
	}

	// `destroy` released the App and the recorder; `driver_cleanup` released the
	// request arena. Nothing may remain.
	testing.expect_value(t, len(track.allocation_map), 0)
}
