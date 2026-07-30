package main

import "core:os"
import "core:strconv"
import web "druse:web"

Small_Document :: struct {
	id:     int    `json:"id"`,
	name:   string `json:"name"`,
	email:  string `json:"email"`,
	active: bool   `json:"active"`,
}

Medium_Item :: struct {
	id:     int     `json:"id"`,
	name:   string  `json:"name"`,
	score:  f64    `json:"score"`,
	active: bool    `json:"active"`,
}

Medium_Document :: struct {
	request_id: string        `json:"request_id"`,
	items:      []Medium_Item `json:"items"`,
	tags:       []string      `json:"tags"`,
}

medium_items: [64]Medium_Item
medium_tags := [6]string{"alpha", "beta", "gamma", "delta", "epsilon", "zeta"}

Auth_State :: struct {
	account_id: int,
}

Routed_Response :: struct {
	id:         int  `json:"id"`,
	account_id: int  `json:"account_id"`,
	verbose:    bool `json:"verbose"`,
}

health :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

json_small :: proc(ctx: ^web.Context) {
	web.ok(ctx, Small_Document {
		id = 42,
		name = "Ada",
		email = "ada@example.com",
		active = true,
	})
}

json_echo :: proc(ctx: ^web.Context) {
	input: Small_Document
	if !web.body(ctx, &input) {
		return
	}
	web.ok(ctx, input)
}

json_medium_get :: proc(ctx: ^web.Context) {
	web.ok(ctx, Medium_Document {
		request_id = "req-0123456789abcdef",
		items = medium_items[:],
		tags = medium_tags[:],
	})
}

json_medium :: proc(ctx: ^web.Context) {
	input: Medium_Document
	if !web.body(ctx, &input) {
		return
	}
	web.ok(ctx, input)
}

json_medium_decode :: proc(ctx: ^web.Context) {
	input: Medium_Document
	if !web.body(ctx, &input) {
		return
	}
	web.no_content(ctx)
}

onion_outer :: proc(ctx: ^web.Context) {
	web.next(ctx)
}

onion_inner :: proc(ctx: ^web.Context) {
	web.next(ctx)
}

auth_state :: proc(ctx: ^web.Context) {
	state := web.request_state(ctx, Auth_State)
	state.account_id = 7
	web.next(ctx)
}

routed_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}
	verbose_value, verbose_present, verbose_ok := web.query_int_opt(ctx, "verbose")
	if !verbose_ok {
		return
	}
	state := web.request_state(ctx, Auth_State)
	web.ok(ctx, Routed_Response {
		id = id,
		account_id = state.account_id,
		verbose = verbose_present && verbose_value == 1,
	})
}

routed_api :: proc() -> web.Router {
	r := web.router()
	web.use(&r, web.request_id)
	web.use(&r, onion_outer)
	web.use(&r, onion_inner)
	web.use(&r, auth_state)
	web.get(&r, "/users/:id", routed_user)
	return r
}

main :: proc() {
	for i in 0 ..< len(medium_items) {
		medium_items[i] = Medium_Item {
			id = i + 1,
			name = "item-abcdefghijklmnop",
			score = f64(i) + 1.5,
			active = true,
		}
	}

	app := web.app()
	defer web.destroy(&app)

	limits := web.DEFAULT_LIMITS
	if len(os.args) > 1 {
		if n, ok := strconv.parse_int(os.args[1], 10); ok {
			limits.max_handlers = n
		}
	}
	web.limits(&app, limits)

	web.get(&app, "/health", health)
	web.get(&app, "/json/small", json_small)
	web.get(&app, "/json/medium", json_medium_get)
	web.post(&app, "/json/echo", json_echo)
	web.post(&app, "/json/medium", json_medium)
	web.post(&app, "/json/medium/decode", json_medium_decode)

	api := routed_api()
	web.mount(&app, "/api", &api)

	web.serve(&app, 8080)
}
