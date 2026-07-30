// Druse example 04 — middleware: ordering, short-circuiting, and the two
// built-ins.
//
// Middleware is an ORDINARY HANDLER. There is no `Middleware` type, no
// configuration object, and no second registration form: a middleware is a
// `proc(ctx: ^web.Context)` that calls `web.next(ctx)` to run the rest of the
// chain.
//
// The one rule that is enforced rather than advised: every `web.use` comes
// BEFORE the first route. Get it wrong and the whole application is rejected —
// see the comment on `main` below, which explains why the framework refuses the
// program instead of trusting you to read a paragraph.
//
// Run it from the repository root:
//
//	odin run examples/04-middleware -collection:druse=.
//
// Try it:
//
//	curl http://localhost:8080/public          -> 200, and one log line
//	curl -i http://localhost:8080/admin        -> 401, the chain short-circuited
//	curl -i -H "X-Api-Key: let-me-in" http://localhost:8080/admin  -> 200
//	curl -i http://localhost:8080/nope         -> 404, and STILL a log line
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

// THE ONION. Middleware run in registration order and unwind in exactly the
// reverse order:
//
//	use(A); use(B); get("/x", H)   =>   A > B > H < B < A
//
// Code placed after `next` runs as this frame resumes — the request is fully
// answered by then. Read there; never write. A response attempt at unwind time
// is rejected by the single-commit guard and the first response survives
// byte-for-byte.
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

// Only `/admin` is gated; everything else passes through.
//
// A route that needs its own guard, rather than an app-wide one, is a ONE-ROUTE
// `web.Router` mounted at its path — see example 05. There are no per-route
// middleware parameters: the five registration signatures are frozen.
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
