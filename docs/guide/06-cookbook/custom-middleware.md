# Custom middleware

Middleware that runs before and after a handler, one that short-circuits, and
the two the framework ships. `examples/04-middleware`, complete.

## Server

<!-- druse:begin examples/04-middleware/main.odin -->
```odin
package main

import web "druse:web"

Message :: struct {
	message: string `json:"message"`,
}

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	// ORDER IS A SECURITY BOUNDARY, so it is enforced.
	//
	// Every `use` must precede every route. If you move any `use` below a
	// `get`/`post`/`put`/`patch`/`delete`/`mount`, the application is REJECTED
	// fail-closed: every request answers 500, `web.serve` refuses to start, and
	// a diagnostic names the first route the middleware could not protect.
	//
	// That rule exists because the alternative was measured on a prototype: a
	// route registered above its auth middleware served `200 OK` — with the
	// secret body — to an unauthenticated caller. No error, no warning, no
	// runtime symptom, produced by moving one line. A rule enforced only by
	// documentation is not enforced.
	//
	// Registration order is also EXECUTION order, so `request_id` goes first:
	// everything after it runs with the correlation ID already assigned.
	web.use(&app, web.request_id)
	web.use(&app, web.logger)
	web.use(&app, timing_gate)

	web.get(&app, "/public", public_handler)
	web.get(&app, "/admin", admin_handler)

	web.serve(&app, 8080)
}

timing_gate :: proc(ctx: ^web.Context) {
	// BEFORE: this runs on the way in, for every request including a 404.
	//
	// Guarding a route is done HERE, by returning without calling `next`.
	if !authorized(ctx) {
		// Short-circuit: nothing downstream runs — not the later middleware,
		// not the route handler — and this response is what the client gets.
		web.unauthorized(ctx, "authentication required")
		return
	}

	web.next(ctx)

	// AFTER: the response is committed by now. This is where you would export
	// a metric or inspect the outcome.
	//
	// There is no latency measurement in the framework's own logger, and there
	// is none here either: measuring it needs a clock, and importing one costs
	// every application that never asked for it. Phase 4 owns observability.
}

authorized :: proc(ctx: ^web.Context) -> bool {
	if ctx.request.path != "/admin" {
		return true
	}

	// `web.header` is a pure lookup: it never responds and never logs. Header
	// values are attacker-controlled, so nothing here is echoed back.
	key, found := web.header(ctx, "X-Api-Key")
	return found && key == "let-me-in"
}

public_handler :: proc(ctx: ^web.Context) {
	web.ok(ctx, Message{message = "anyone may read this"})
}

admin_handler :: proc(ctx: ^web.Context) {
	// The correlation ID assigned by `web.request_id`, read through the ONE
	// canonical accessor. There is no `web.request_id_value`: the middleware
	// writes the effective ID where `web.header` already looks.
	//
	// It is unique, and it is deliberately NOT unguessable. Never use it as
	// authentication.
	id, _ := web.header(ctx, "X-Request-Id")

	web.ok(ctx, Message{message = id})
}
```
<!-- druse:end -->

## Run

```text
odin run examples/04-middleware -collection:druse=.
```

## Client

```text
curl http://localhost:8080/public
curl -i http://localhost:8080/admin
```

## What to notice

**Registration order is execution order.** `web.request_id` goes first, so
everything after it runs with a correlation ID already assigned.

**A middleware that does not call `web.next` short-circuits**, and the handler
never runs. That is how a guard refuses.

**`web.use` must come before every route, and the build enforces it.** Moving a
guard one line too late would serve a secret body to an unauthenticated caller
— no error, no warning, no runtime symptom. A rule enforced only by
documentation is not enforced.

**Read the correlation ID through `web.header`.** There is no
`web.request_id_value`: the middleware writes the effective ID where
`web.header` already looks. It is unique and **deliberately not unguessable —
never use it as authentication**.

## Next

[`../05-recipes/write-a-middleware.md`](../05-recipes/write-a-middleware.md) —
the signature, the guard shape, and passing a typed value to the handler.
