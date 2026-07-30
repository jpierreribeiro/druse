// Usage laboratory, program B — the same five-route CRUD service, guarded.
//
// It adopts everything Phase 2 shipped: ordered middleware, a router mounted at
// a prefix, bearer-token auth, request logging and request IDs. This is the
// program the concept BUDGET applies to, and Phase 2 measured it at 23.
package main

import web "druse:web"

Item :: struct {
	id:   int `json:"id"`,
	name: string `json:"name"`,
}

New_Item :: struct {
	name: string `json:"name"`,
}

main :: proc() {
	app := web.app()
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
	web.ok(ctx, Item{id = 1, name = "first"})
}

create_item :: proc(ctx: ^web.Context) {
	incoming: New_Item
	if !web.body(ctx, &incoming) {
		return
	}
	web.created(ctx, Item{id = 2, name = incoming.name})
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
