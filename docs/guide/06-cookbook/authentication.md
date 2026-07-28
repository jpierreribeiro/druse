# Authentication

A bearer-token gate and a typed user lookup — both **application code**, not
framework symbols. `examples/06-authentication`, complete.

## Server

<!-- druse:begin examples/06-authentication/main.odin -->
```odin
package main

import web "druse:web"

User :: struct {
	id:   int    `json:"id"`,
	name: string `json:"name"`,
	role: string `json:"role"`,
}

Message :: struct {
	message: string `json:"message"`,
}

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	web.use(&app, web.request_id)
	web.use(&app, web.logger)

	// Public routes go on the app; gated routes go in a Router with the gate.
	web.get(&app, "/", index)

	private := private_router()
	web.mount(&app, "", &private)

	web.serve(&app, 8080)
}

private_router :: proc() -> web.Router {
	r := web.router()

	// The gate comes first. This is enforced, not advised: `use` after a route
	// rejects the whole application fail-closed.
	web.use(&r, require_auth)

	web.get(&r, "/me", show_me)
	web.get(&r, "/greeting", greeting)

	return r
}

// ---------------------------------------------------------------------------

require_auth :: proc(ctx: ^web.Context) {
	// `web.bearer_token` parses `Authorization` STRICTLY: the scheme is
	// case-insensitive, exactly one space separates it from the token, and any
	// whitespace inside the token is a rejection. A sloppy header is REJECTED,
	// never repaired — normalising a credential invites bugs upstream.
	token, ok := web.bearer_token(ctx)
	if !ok {
		web.unauthorized(ctx, "authentication required")
		return
	}

	if _, valid := user_for_token(token); !valid {
		// NOTE what is not here: the token is not logged, not echoed, and not
		// included in the response. It is attacker-controlled, and a rejected
		// credential in a log file is a credential in a log file.
		web.unauthorized(ctx, "authentication required")
		return
	}

	web.next(ctx)
}

current_user :: proc(ctx: ^web.Context) -> (User, bool) {
	token, ok := web.bearer_token(ctx)
	if !ok {
		return {}, false
	}
	return user_for_token(token)
}

user_for_token :: proc(token: string) -> (User, bool) {
	switch token {
	case "ada-token":
		return User{id = 1, name = "Ada", role = "admin"}, true
	case "linus-token":
		return User{id = 2, name = "Linus", role = "user"}, true
	}
	return {}, false
}

// ---------------------------------------------------------------------------

index :: proc(ctx: ^web.Context) {
	web.ok(ctx, Message{message = "public"})
}

show_me :: proc(ctx: ^web.Context) {
	// One call, one validation.
	user, ok := current_user(ctx)
	if !ok {
		// Unreachable behind `require_auth`, and handled anyway: a handler that
		// assumes a middleware ran is a handler that breaks when someone
		// re-registers it somewhere else.
		web.unauthorized(ctx, "authentication required")
		return
	}

	web.ok(ctx, user)
}

greeting :: proc(ctx: ^web.Context) {
	// Call it ONCE and pass the value down, rather than calling it in each
	// procedure that needs the user. With the string comparison above the
	// difference is nothing; with a database lookup it is the difference
	// between one query and four.
	user, ok := current_user(ctx)
	if !ok {
		web.unauthorized(ctx, "authentication required")
		return
	}

	web.ok(ctx, Message{message = greeting_for(user)})
}

greeting_for :: proc(user: User) -> string {
	if user.role == "admin" {
		return "welcome back, administrator"
	}
	return "welcome back"
}
```
<!-- druse:end -->

## Run

```text
odin run examples/06-authentication -collection:druse=.
```

## What to notice

**`require_auth` and `current_user` are yours, and will stay yours.** The
framework provides `web.bearer_token`, a strict RFC 6750 parse. The application
provides its own gate and its own lookup. Two procedures you can read in one
screen beat a framework abstraction you have to trust.

**The cost, stated rather than hidden: `current_user` revalidates on every
call.** A handler that calls it three times validates three times.

Why: this example predates `web.request_state`, and it shows the shape that
works without any per-request slot at all.

**The fix is ordinary Odin, not a framework feature.** If your validation is
expensive — a database round-trip rather than a string comparison — call it
**once** at the top of the handler and pass the `User` down as a parameter.

Or use `web.request_state` for one typed value a middleware computes and the
handler reads back — see
[`../03-subjects/context-and-state.md`](../03-subjects/context-and-state.md).

## For real sessions and API keys

This example authenticates against a hardcoded token, which is right for
learning the shape and wrong for production. Use `crystals:auth/session` for
humans and `crystals:auth/api_key` for machines:

- [`../02-build-notes/05-sessions-and-login.md`](../02-build-notes/05-sessions-and-login.md)
- [`../05-recipes/api-keys.md`](../05-recipes/api-keys.md)
