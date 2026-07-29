// Druse example 02 — a JSON API in CRUD shape.
//
// This is the proof that a small CRUD-style API is expressible with the public
// Phase-1 surface alone: no allocator setup, no transport selection, no
// framework internals.
//
//	GET    /users        list
//	GET    /users/:id    read one
//	POST   /users        create
//	PUT    /users/:id    replace
//	PATCH  /users/:id    update
//	DELETE /users/:id    delete
//
// Run it from the repository root:
//
//	odin run examples/02-json-api -collection:druse=.
//
// Try it:
//
//	curl http://localhost:8080/users
//	curl http://localhost:8080/users/42
//	curl -X POST http://localhost:8080/users \
//	     -H 'content-type: application/json' \
//	     -d '{"name":"Ada","email":"ada@example.com"}'
//	curl -i http://localhost:8080/users/0
//
// NO DATABASE, AND NO STORAGE. Every handler answers from the request itself:
// a read echoes the id you asked for, a create echoes the body you sent. Typed
// application state (`web.state`) and real persistence are later phases, and
// faking them with a mutable global would teach a pattern that breaks the
// moment the server handles two requests at once.
package main

import web "druse:web"

// Data transfer objects. The `json:"..."` tags decide the names on the wire.
User :: struct {
	id:    int    `json:"id"`,
	name:  string `json:"name"`,
	email: string `json:"email"`,
}

// The shape a client sends when creating or updating a user. It is a separate
// struct from `User` on purpose: the client does not choose the id.
User_Input :: struct {
	name:  string `json:"name"`,
	email: string `json:"email"`,
}

User_List :: struct {
	users: []User `json:"users"`,
	count: int    `json:"count"`,
}

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	web.get(&app, "/users", list_users)
	web.get(&app, "/users/:id", get_user)
	web.post(&app, "/users", create_user)
	web.put(&app, "/users/:id", replace_user)
	web.patch(&app, "/users/:id", update_user)
	web.delete(&app, "/users/:id", delete_user)

	web.serve(&app, 8080)
}

// GET /users — 200 with a JSON body.
//
// `ok` sends 200 and serializes the value as JSON. Pass the value itself, never
// a pointer to it.
list_users :: proc(ctx: ^web.Context) {
	users := []User {
		{id = 1, name = "Ada", email = "ada@example.com"},
		{id = 2, name = "Grace", email = "grace@example.com"},
	}

	web.ok(ctx, User_List{users = users, count = len(users)})
}

// GET /users/:id — read one.
//
// `path_int` reads the `:id` segment and parses it. If it is missing or not an
// integer, the extractor has ALREADY sent a 400 with a standardized error body,
// so the handler just returns. That two-line shape is the canonical way to
// handle every fallible extractor.
get_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}

	// An application-level error. `not_found` sends 404 with a standardized
	// body; the handler returns immediately afterwards.
	if id == 0 {
		web.not_found(ctx, "user")
		return
	}

	web.ok(ctx, User{id = id, name = "Ada", email = "ada@example.com"})
}

// POST /users — create.
//
// `body` decodes the JSON request body into a destination you own, and returns
// false if it could not. On failure it has already answered (400 for malformed
// JSON, 413 for a body over the fixed 4 MiB limit), so the handler returns.
//
// Call `body` AT MOST ONCE per request: the body is a single-use capability.
create_user :: proc(ctx: ^web.Context) {
	input: User_Input
	if !web.body(ctx, &input) {
		return
	}

	// `created` sends 201. It is exactly `json(ctx, .Created, value)`.
	web.created(ctx, User{id = 101, name = input.name, email = input.email})
}

// PUT /users/:id — replace. Two extractors, each checked in turn.
replace_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}

	input: User_Input
	if !web.body(ctx, &input) {
		return
	}

	web.ok(ctx, User{id = id, name = input.name, email = input.email})
}

// PATCH /users/:id — partial update.
//
// A field the client omitted arrives as the zero value, so this fills the gaps
// with what a stored record would have provided.
update_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}

	input: User_Input
	if !web.body(ctx, &input) {
		return
	}

	name := input.name
	if name == "" {
		name = "Ada"
	}
	email := input.email
	if email == "" {
		email = "ada@example.com"
	}

	web.ok(ctx, User{id = id, name = name, email = email})
}

// DELETE /users/:id — 204, no body.
//
// `no_content` sends 204 and nothing else: no body, and no `Content-Type`,
// because there is no content to describe.
delete_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}
	_ = id

	web.no_content(ctx)
}
