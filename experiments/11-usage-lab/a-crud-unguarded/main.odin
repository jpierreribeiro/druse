// Usage laboratory, program A — a five-route CRUD service, unguarded.
//
// THE PHASE-1 SHAPE, written from public documentation only. It is the
// baseline the concept budget is measured against, and it must stay at 14.
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

	web.get(&app, "/items", list_items)
	web.post(&app, "/items", create_item)
	web.put(&app, "/items/:id", replace_item)
	web.patch(&app, "/items/:id", update_item)
	web.delete(&app, "/items/:id", delete_item)

	web.serve(&app, 8080)
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
