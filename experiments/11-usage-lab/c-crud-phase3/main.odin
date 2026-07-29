// Usage laboratory, program C — the guarded CRUD service as Phase 3 would
// realistically write it.
//
// Program B, plus the one Phase-3 feature a real CRUD service actually reaches
// for: APPLICATION STATE, holding the thing every handler needs. The plan
// predicted +2 if the lab gained state and asked for it to be MEASURED rather
// than assumed.
//
// It deliberately does NOT reach for `web.route` or `web.limits`. A CRUD
// service has no reason to label telemetry by route or to change its byte
// budget, and adding them to inflate the number would measure the phase's
// surface rather than a program's cost.
package main

import web "druse:web"

// The value every handler needs, created once. In a real service this is a
// database pool; here it is the store's name and a counter.
App_State :: struct {
	store: string,
	next:  int,
}

Item :: struct {
	id:   int `json:"id"`,
	name: string `json:"name"`,
}

New_Item :: struct {
	name: string `json:"name"`,
}

main :: proc() {
	state := App_State{store = "items", next = 1}
	app := web.app_with_state(&state)
	defer web.destroy(&app)

	// Every `use` before the first route — the order is enforced.
	web.use(&app, web.logger)
	web.use(&app, web.request_id)

	items := web.router()
	defer web.destroy(&items)

	web.use(&items, require_auth)
	web.get(&items, "", list_items)
	web.post(&items, "", create_item)
	web.put(&items, "/:id", replace_item)
	web.patch(&items, "/:id", update_item)
	web.delete(&items, "/:id", delete_item)

	web.mount(&app, "/items", &items)

	web.serve(&app, 8080)
}

require_auth :: proc(ctx: ^web.Context) {
	token, ok := web.bearer_token(ctx)
	if !ok || token != "let-me-in" {
		web.unauthorized(ctx, "a valid bearer token is required")
		return
	}
	web.next(ctx)
}

list_items :: proc(ctx: ^web.Context) {
	s := web.state(ctx, App_State)
	web.ok(ctx, Item{id = 1, name = s.store})
}

create_item :: proc(ctx: ^web.Context) {
	s := web.state(ctx, App_State)
	incoming: New_Item
	if !web.body(ctx, &incoming) {
		return
	}
	s.next += 1
	web.created(ctx, Item{id = s.next, name = incoming.name})
}

replace_item :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}
	incoming: New_Item
	if !web.body(ctx, &incoming) {
		return
	}
	web.ok(ctx, Item{id = id, name = incoming.name})
}

update_item :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}
	web.ok(ctx, Item{id = id, name = "patched"})
}

delete_item :: proc(ctx: ^web.Context) {
	if _, ok := web.path_int(ctx, "id"); !ok {
		return
	}
	web.no_content(ctx)
}
