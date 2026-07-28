# CRUD

A complete JSON API in CRUD shape: list, read, create, replace, update, delete.
No database — every handler answers from the request itself, so the program runs
with nothing installed.

This is `examples/02-json-api`, complete. The build check compiles it.

## Server

<!-- druse:begin examples/02-json-api/main.odin -->
```odin
package main

import web "druse:web"

User :: struct {
	id:    int    `json:"id"`,
	name:  string `json:"name"`,
	email: string `json:"email"`,
}

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

list_users :: proc(ctx: ^web.Context) {
	users := []User {
		{id = 1, name = "Ada", email = "ada@example.com"},
		{id = 2, name = "Grace", email = "grace@example.com"},
	}

	web.ok(ctx, User_List{users = users, count = len(users)})
}

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

create_user :: proc(ctx: ^web.Context) {
	input: User_Input
	if !web.body(ctx, &input) {
		return
	}

	// `created` sends 201. It is exactly `json(ctx, .Created, value)`.
	web.created(ctx, User{id = 101, name = input.name, email = input.email})
}

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

delete_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}
	_ = id

	web.no_content(ctx)
}
```
<!-- druse:end -->

## Run

```text
odin run examples/02-json-api -collection:druse=.
```

## Client

**List**

```text
curl http://localhost:8080/users
```

```json
{"users":[{"id":1,"name":"Ada","email":"ada@example.com"},{"id":2,"name":"Grace","email":"grace@example.com"}],"count":2}
```

**Read one**

```text
curl http://localhost:8080/users/42
```

**Create**

```text
curl -X POST http://localhost:8080/users \
     -H 'content-type: application/json' \
     -d '{"name":"Ada","email":"ada@example.com"}'
```

Answers `201`.

**A missing record**

```text
curl -i http://localhost:8080/users/0
```

Answers `404` with the standard envelope.

**Delete** answers `204` with no body and no `Content-Type`.

## What to notice

**Two structs, not one.** `User` is what you send; `User_Input` is what the
client sends. They are separate because **the client does not choose the id**.
Reusing one struct for both is how a client assigns its own primary key.

**`if !ok { return }`, four times.** `web.path_int` and `web.body` have already
answered when they report failure. The handler writes nothing more. That shape
is the same for every fallible extractor.

**`web.ok` takes the value, not a pointer.** `web.created` is exactly
`web.json(ctx, .Created, value)`, and `web.no_content` sends `204` with no
`Content-Type`, because there is no content to describe.

**PATCH fills gaps by hand here.** A field the client omitted arrives as the
zero value, and this program cannot tell that from an explicit empty string.
With a database you use `validate.Patch(T)` instead, which distinguishes
*absent* from *null* from *set* — see
[`../02-build-notes/04-listing-patch-and-failure.md`](../02-build-notes/04-listing-patch-and-failure.md).

## Next

[`../02-build-notes/02-database-and-migrations.md`](../02-build-notes/02-database-and-migrations.md)
— the same shape, against a real PostgreSQL.
