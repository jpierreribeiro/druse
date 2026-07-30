// Druse example 05 — organising routes with `web.Router` and `web.mount`.
//
// A `Router` collects routes under a prefix, with its own middleware, and
// `mount` attaches the whole thing to an application. There is no `web.group`
// and there never will be: a Router is an ordinary value you can build,
// return from a procedure, and mount — which a closure-based group API is not.
//
// A Router accepts the SAME `use` and the SAME five registration verbs an App
// does. Nothing about the API changes when you organise routes; that is the
// point of the design.
//
// Run it from the repository root:
//
//	odin run examples/05-route-groups -collection:druse=.
//
// Try it:
//
//	curl http://localhost:8080/health              -> 200, no auth
//	curl -i http://localhost:8080/api/v1/items     -> 401, the API guard ran
//	curl -H "X-Api-Key: secret" http://localhost:8080/api/v1/items    -> 200
//	curl -H "X-Api-Key: secret" http://localhost:8080/api/v1/items/7  -> 200
//	curl -i -H "X-Api-Key: secret" http://localhost:8080/reports/daily -> 403
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

// A Router built and RETURNED by an ordinary procedure. This is the shape a
// closure-based `group(...)` API cannot give you: routing is just a value.
//
// OWNERSHIP: `web.router()` returns a Router BY VALUE. Do not copy it after
// registering routes — treat it exactly as you treat a `strings.Builder`: pass
// `&r`, never `r`. `mount` COPIES its routes into the App and then CLOSES the
// router, so registering on it afterwards is a boot failure rather than a
// silently dead route.
//
// Because `mount` copies, the App owns everything after this procedure
// returns, and the Router itself needs no separate teardown here.
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

// The mounted path is prefix + pattern: `/api/v1` + `/items/:id` =
// `/api/v1/items/:id`. Parameters keep working across the join.
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
