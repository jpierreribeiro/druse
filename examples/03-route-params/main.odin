// Druse example 03 — path parameters and query strings.
//
// Everything about reading input from the URL: a `:param` segment, static
// routes winning over parametric ones, and the three query extractors.
//
// Run it from the repository root:
//
//	odin run examples/03-route-params -collection:druse=.
//
// Try it:
//
//	curl http://localhost:8080/users/me          -> the STATIC route wins
//	curl http://localhost:8080/users/42          -> the :id route
//	curl http://localhost:8080/files/report.pdf  -> path() returns text as-is
//	curl http://localhost:8080/search?q=odin              -> limit defaults to 20
//	curl http://localhost:8080/search?q=odin&limit=5      -> limit is 5
//	curl -i http://localhost:8080/search?q=odin&limit=abc -> 400, never the default
//	curl -i http://localhost:8080/users/abc               -> 400
package main

import web "druse:web"

Profile :: struct {
	id:   int    `json:"id"`,
	name: string `json:"name"`,
}

File_Info :: struct {
	name: string `json:"name"`,
}

Search :: struct {
	query:    string `json:"query"`,
	limit:    int    `json:"limit"`,
	page:     int    `json:"page"`,
	had_sort: bool   `json:"had_sort"`,
	sort:     string `json:"sort"`,
}

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	// A STATIC route and a PARAMETRIC route on the same shape.
	//
	// `/users/me` always wins over `/users/:id`, and that is decided by the
	// shape of the pattern, not by the order you register them — you can swap
	// these two lines and the behavior is identical.
	web.get(&app, "/users/me", current_user)
	web.get(&app, "/users/:id", get_user)

	web.get(&app, "/files/:name", get_file)
	web.get(&app, "/search", search)

	web.serve(&app, 8080)
}

// The static route. No parameter to read.
current_user :: proc(ctx: ^web.Context) {
	web.ok(ctx, Profile{id = 1, name = "the current user"})
}

// `path_int` reads a `:param` and parses it as an integer.
//
// If the value is missing, empty, not a number, or outside the range of `int`,
// the extractor has ALREADY sent a 400 with a standardized body. The handler
// only returns — never write your own error response for an extractor failure.
get_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}

	web.ok(ctx, Profile{id = id, name = "user"})
}

// `path` reads a `:param` as text. The route already matched, so the value is
// present and this extractor cannot fail — there is no `ok` to check.
//
// The result is a VIEW over the request. It is valid while the handler runs;
// copy it explicitly if you need to keep it for longer.
get_file :: proc(ctx: ^web.Context) {
	name := web.path(ctx, "name")

	web.ok(ctx, File_Info{name = name})
}

// The three query extractors, and the difference that matters most.
search :: proc(ctx: ^web.Context) {
	// `query` is a plain lookup. It NEVER sends an error response; `found`
	// simply reports whether the key was in the query string.
	q, found := web.query(ctx, "q")
	if !found {
		web.bad_request(ctx, "the 'q' parameter is required")
		return
	}

	// `query_int` requires the parameter. Missing or malformed -> it sends a
	// 400 itself and returns ok = false.
	page, page_ok := web.query_int(ctx, "page")
	if !page_ok {
		// This request had no `page`, so the extractor already answered 400.
		return
	}

	// `query_int_or` uses the default ONLY when the key is absent.
	//
	//	/search?q=odin              -> limit = 20   (absent: the default)
	//	/search?q=odin&limit=5      -> limit = 5
	//	/search?q=odin&limit=abc    -> 400          (present but malformed)
	//	/search?q=odin&limit=       -> 400          (present but empty)
	//
	// A malformed value is never silently replaced by the default: sending
	// `limit=abc` is a mistake the caller should hear about.
	limit, limit_ok := web.query_int_or(ctx, "limit", 20)
	if !limit_ok {
		return
	}

	sort, had_sort := web.query(ctx, "sort")

	// The response payload is passed BY VALUE.
	web.ok(
		ctx,
		Search{query = q, limit = limit, page = page, had_sort = had_sort, sort = sort},
	)
}
