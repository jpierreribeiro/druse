# What this is

**Assumes:** nothing. This is the first page.

Druse is an HTTP framework for Odin. You write handlers. It does routing, body
decoding, and the standard error responses.

Crystals is a separate repository of optional packages that sit on top: a
PostgreSQL pool, sessions, password hashing, CSRF, validation, migrations,
background jobs, mail, object storage, rate limiting and idempotency.

Together they cover what a production service needs. They are two repositories
and one product, and this guide teaches them as one.

## The shape of a program

A Druse application is one process. It binds a port and blocks:

```odin
package main

import web "druse:web"

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	web.get(&app, "/ping", ping)

	web.serve(&app, 8080)
}

ping :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}
```

Four things happen. `web.app()` creates the application. `defer
web.destroy(&app)` releases it when `main` ends. `web.get` registers a route.
`web.serve` binds the port and blocks.

That is the whole framework's shape. Everything else in this guide adds to that
`main`, and nothing hides from it.

## What you get without writing it

Druse answers these itself. You never write them:

```text
GET  /unknown-path        404   {"error":{"code":"not_found", ...}}
DELETE /a-GET-only-path   405   + an Allow header listing the real methods
GET  /users/abc           400   invalid_path_parameter
POST with broken JSON     400   invalid_json
POST with wrong type      400   invalid_field + field path
POST with unknown key     400   unknown_field + field path
POST with a huge body     413   body_too_large
```

Every one is JSON in the same envelope. `docs/errors.md` lists them all.

A fallible extractor follows the same rule. If `web.path_int` cannot read the
value, it has already sent the `400`. Your handler returns:

```odin
get_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}

	web.ok(ctx, User{id = id, name = "Ada"})
}
```

This is the shape you use everywhere. Never write your own error response for a
case an extractor already handles.

## What the framework is, in one sentence

Druse is explicit. Nothing is discovered, registered, injected or initialized
behind your back.

That has three consequences you feel immediately:

- **You see every long-lived value.** A pool is created in `main`, stored in
  your own struct, and destroyed in `main`. There is no container to ask.
- **You see every allocation that outlives a request.** The framework tells you
  which values are views and which are copies. See
  [`../04-rules/ownership-and-lifetime.md`](../04-rules/ownership-and-lifetime.md).
- **You see the cost.** A middleware that runs on every request is a line you
  wrote in `main`, not an annotation on a handler.

The cost of that explicitness is real, and
[`what-it-refuses.md`](what-it-refuses.md) states it rather than hiding it.

## Two ledgers, and why they matter to you

The application API is exactly 80 symbols. The test-support API is 2. The union
is 82.

That number is enforced by a build check. It is not a boast. It is a promise
about what you have to learn, and a promise that a symbol will not appear
without a review.

If something is not in `docs/ai-context.md`, it does not exist. Do not guess a
procedure name. The first four defects ever recorded against this framework
were all guessed names.

## What runs underneath

An HTTP/1.1 server. It is an internal implementation detail, it is replaceable,
and you never configure it. None of it appears in the API you write against.

## Next

- [`what-it-refuses.md`](what-it-refuses.md) — the refusals, and their cost.
- `docs/quick-start.md` — build the program above, from nothing, and run it.
