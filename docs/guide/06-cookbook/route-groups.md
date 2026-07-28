# Route groups

A group with its own prefix, its own middleware and its own routes — built as a
value and mounted. `examples/05-route-groups`, complete.

## Server

<!-- druse:begin examples/05-route-groups/main.odin -->
```odin
package main

import web "druse:web"

Item :: struct {
	id:   int    `json:"id"`,
	name: string `json:"name"`,
}

Health :: struct {
	status: string `json:"status"`,
}

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	// App-level middleware first, as always. These wrap EVERYTHING, including
	// every mounted route and every 404.
	web.use(&app, web.request_id)
	web.use(&app, web.logger)

	// An ungated route, registered directly on the app.
	web.get(&app, "/health", health)

	// A GROUP: its own prefix, its own middleware, its own routes.
	api := api_router()
	web.mount(&app, "/api/v1", &api)

	// A ONE-ROUTE ROUTER is the canonical way to guard a single route. There
	// are no per-route middleware parameters — the five registration
	// signatures are frozen — so a route needing its own guard gets its own
	// Router mounted at its path.
	reports := reports_router()
	web.mount(&app, "/reports", &reports)

	web.serve(&app, 8080)
}

api_router :: proc() -> web.Router {
	r := web.router()

	// Router-level middleware. It runs INSIDE the app-level chain — app
	// globals outermost, then the router's, then the handler — and it applies
	// only to this router's routes. `/health` above never sees it.
	//
	// The same ordering rule applies here: `use` before the routes.
	web.use(&r, require_api_key)

	web.get(&r, "/items", list_items)
	web.get(&r, "/items/:id", get_item)

	return r
}

reports_router :: proc() -> web.Router {
	r := web.router()
	web.use(&r, require_admin)
	web.get(&r, "/daily", daily_report)
	return r
}

require_api_key :: proc(ctx: ^web.Context) {
	key, found := web.header(ctx, "X-Api-Key")
	if !found || key != "secret" {
		web.unauthorized(ctx, "an API key is required")
		return
	}
	web.next(ctx)
}

require_admin :: proc(ctx: ^web.Context) {
	// Distinct from 401: the caller IS identified, and is still not allowed.
	role, _ := web.header(ctx, "X-Role")
	if role != "admin" {
		web.forbidden(ctx, "administrator access is required")
		return
	}
	web.next(ctx)
}

health :: proc(ctx: ^web.Context) {
	web.ok(ctx, Health{status = "ok"})
}

list_items :: proc(ctx: ^web.Context) {
	web.ok(ctx, []Item{{id = 1, name = "first"}, {id = 2, name = "second"}})
}

get_item :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}
	web.ok(ctx, Item{id = id, name = "an item"})
}

daily_report :: proc(ctx: ^web.Context) {
	web.ok(ctx, Health{status = "nothing to report"})
}
```
<!-- druse:end -->

## Run

```text
odin run examples/05-route-groups -collection:druse=.
```

## Client

```text
curl http://localhost:8080/health
curl http://localhost:8080/api/v1/users
curl -i http://localhost:8080/reports/daily
```

## What to notice

**There is no `web.group`.** A group is a `web.Router` value, and an ordinary
procedure builds and returns one. That is the shape a closure-based group API
cannot give you: routing is a value, so it composes with everything the
language already has.

**A one-route Router is the route-level guard.** There are no per-route
middleware parameters — a route needing its own guard gets its own Router
mounted at its path.

**`mount` copies the routes and closes the source.** Registering on a router
after mounting it is a boot failure, not a silently dead route.

**Pass `&r`, never `r`.** `web.router()` returns a value; treat it as you treat
a `strings.Builder`.

## Next

[`../03-subjects/routing.md`](../03-subjects/routing.md) — the five verbs,
nesting, and how prefixes compose.
