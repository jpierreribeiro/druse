# Path and query parameters

Everything about reading input from the URL: a `:param` segment, static routes
winning over parametric ones, and the three query extractors.

`examples/03-route-params`, complete.

## Server

<!-- druse:begin examples/03-route-params/main.odin -->
```odin
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

current_user :: proc(ctx: ^web.Context) {
	web.ok(ctx, Profile{id = 1, name = "the current user"})
}

get_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}

	web.ok(ctx, Profile{id = id, name = "user"})
}

get_file :: proc(ctx: ^web.Context) {
	name := web.path(ctx, "name")

	web.ok(ctx, File_Info{name = name})
}

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
```
<!-- druse:end -->

## Run

```text
odin run examples/03-route-params -collection:druse=.
```

## Client

```text
curl http://localhost:8080/users/me            # the STATIC route wins
curl http://localhost:8080/users/42            # the :id route
curl http://localhost:8080/files/report.pdf    # path() returns text as-is
curl http://localhost:8080/search?q=odin               # limit defaults to 20
curl http://localhost:8080/search?q=odin&limit=5       # limit is 5
curl -i http://localhost:8080/search?q=odin&limit=abc  # 400, never the default
curl -i http://localhost:8080/users/abc                # 400
```

## What to notice

**`/users/me` beats `/users/:id`, whatever the registration order.** That is a
property of the router, not a rule you maintain. Register in any order.

**`?limit=abc` is a `400`, not the default.** A present-but-invalid value is a
client error. Only an *absent* value gets the default. Getting this backwards
means a typo silently becomes a different query.

**`web.path` returns the segment as text, unparsed.** `report.pdf` arrives with
its dot. Use `web.path_int` when it must be a number, and let it answer the
`400` for you.

## Next

[`../05-recipes/read-a-query-parameter.md`](../05-recipes/read-a-query-parameter.md)
— all four extractors and what missing means to each.
