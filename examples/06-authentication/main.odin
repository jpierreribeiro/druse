// Druse example 06 — the canonical authentication pattern, and what it costs.
//
// `require_auth` and `current_user` below are APPLICATION CODE. They are not
// framework symbols and they are not going to become framework symbols: the
// framework provides `web.bearer_token`, a strict RFC 6750 parse, and the
// application provides its own typed gate and its own typed lookup. Two
// procedures you can read in one screen beat a framework abstraction you have
// to trust.
//
// THE COST, STATED UP FRONT because pretending it is not there would be the
// dishonest version of this example: `current_user` REVALIDATES THE TOKEN ON
// EVERY CALL. A handler that calls it three times validates three times.
//
// Why: a middleware cannot hand a typed value to a handler. The request
// context is deliberately not an extension bag — there is no `ctx.user_data`,
// no `locals`, no `map[string]any`, and there never will be (guardrail G-03).
// So the only way for a handler to get a `User` is to derive it again.
//
// WILL A LATER PHASE REMOVE THE COST? UNDECIDED — and this comment will not
// promise it. There is no accepted decision for request-scoped typed storage.
// ADR-004 reserves `web.state` for APPLICATION state (a database handle,
// configuration) and not for per-request values, and the research finding C-6
// argues the opposite way: the mechanisms other frameworks use for this
// (Go's `context.WithValue`, Rust's `http::Extensions`) exist for type-erased
// dynamically-keyed state crossing library boundaries, which this framework
// does not have. Treat the cost below as PERMANENT until an ADR says otherwise.
//
// THE WORKAROUND, which is what you should actually do: if your validation is
// expensive — a database round-trip, not the string comparison used here —
// call `current_user` ONCE at the top of the handler and pass the `User` down
// as an ordinary parameter. That is a normal Odin thing to do, it costs
// nothing, and it does not depend on a framework feature arriving.
//
// Run it from the repository root:
//
//	odin run examples/06-authentication -collection:druse=.
//
// Try it:
//
//	curl -i http://localhost:8080/me                          -> 401
//	curl -i -H "Authorization: Bearer nope" .../me            -> 401
//	curl -H "Authorization: Bearer ada-token" .../me          -> 200
//	curl -i -H "Authorization: bearer  ada-token" .../me      -> 401 (two spaces)
package main

import web "druse:web"

// The application's OWN user type. The framework has no idea this exists, which
// is exactly right.
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
// The canonical gate. It authenticates and it does NOTHING else.
// ---------------------------------------------------------------------------

// require_auth rejects an unauthenticated request and lets an authenticated one
// through. It does not hand the user object downstream, because in Phase 2 it
// cannot — see the header comment.
//
// Respond and return WITHOUT calling `next` to short-circuit. That is the whole
// mechanism: no `abort`, no error return, no special middleware result type.
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

// current_user re-derives the authenticated user.
//
// It is safe to call from any handler behind `require_auth`, and it returns
// `(User, false)` anywhere else — it never assumes the gate ran.
//
// THE COST: this revalidates. See the header comment for why, and for what to
// do when validation is expensive.
current_user :: proc(ctx: ^web.Context) -> (User, bool) {
	token, ok := web.bearer_token(ctx)
	if !ok {
		return {}, false
	}
	return user_for_token(token)
}

// The application's own validation. In a real service this is a signature
// check or a session lookup; the shape of the example does not depend on it.
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
// Handlers.
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
