// Uruquim example 07 — typed application state.
//
// A real service has things it needs everywhere and creates once: a database
// pool, a configuration struct, a template cache. `web.app_with_state` attaches
// exactly one such value to the application, and `web.state` reads it back
// TYPED inside any handler or middleware.
//
//	app := web.app_with_state(&state)     // once, in main
//	s, ok := web.state(ctx, App_State)    // anywhere, typed; check ok
//
// THE CALL SITE HAS NO TYPE ARGUMENTS ON THE HANDLER. That is the whole reason
// this shape was chosen (ADR-004 option A): the alternative was a parametric
// `App(S)`/`Context(S)`, which would put a type parameter on every handler
// signature in your program. The price is that a wrong type is caught at
// RUNTIME by an assert rather than by the compiler — and that assert aborts,
// which is the framework's documented fault model. You will meet it on your
// first request, not in production.
//
// THE POINTER IS YOURS. The App stores the address, not a copy: a handler
// writing through it mutates the value you created, which is what makes a
// connection pool work and a copy would break. The value must OUTLIVE the App
// — put it in `main`, next to the App, exactly as below. A pointer to a local
// in a procedure that has already returned is a dangling pointer, and no assert
// can catch that: the type is still right and the memory is still mapped.
//
// WHAT THIS IS NOT: per-request storage. There is none, and there is not going
// to be one — ADR-028 decided that question and closed it. `ctx` is not an
// extension bag; a value a middleware computes for a handler is passed down by
// calling a procedure, or recomputed. That cost is permanent until an ADR says
// otherwise.
//
// Run it from the repository root:
//
//	odin run examples/07-app-state -collection:uruquim=.
//
// Try it:
//
//	curl http://localhost:8080/config          -> the greeting, from state
//	curl -X POST http://localhost:8080/visit   -> 204, and the counter moves
//	curl http://localhost:8080/stats           -> the counter, shared by both
package main

import "core:sync"
import web "uruquim:web"

// The one value every handler needs. An ordinary struct: the framework does not
// require an interface, a registration macro or a particular field.
App_State :: struct {
	greeting: string,
	visits:   int,
}

Greeting :: struct {
	greeting: string `json:"greeting"`,
}

Stats :: struct {
	visits: int `json:"visits"`,
}

main :: proc() {
	// Created BEFORE the App and living for as long as it does. This is the
	// lifetime rule in one line of layout: both are locals of `main`, and
	// `main` outlives every request.
	state := App_State {
		greeting = "hello from application state",
	}

	// `app_with_state` is `app()` with a value attached: the same automatic 404
	// and 405, the same everything else. A nil pointer here would reject the
	// application fail-closed rather than abort inside the first request.
	app := web.app_with_state(&state)
	defer web.destroy(&app)

	web.get(&app, "/config", show_greeting)
	web.post(&app, "/visit", record_visit)
	web.get(&app, "/stats", show_stats)

	web.serve(&app, 8080)
}

// Reading. `web.state(ctx, App_State)` returns a `^App_State` — the type you
// named, not a `rawptr` you have to cast and hope about — plus an `ok` saying
// whether it was there.
//
// CHECK THE `ok`. It is false only when this application registered no state or
// you asked for a type other than the one it registered: both are programming
// mistakes, neither varies with the request, and both are loud in the log. The
// framework used to ABORT THE PROCESS on them. It no longer does, because Odin
// has no recoverable panic and one wrong handler was taking down every
// in-flight request on every lane. Answering 500 for this one request and
// staying up is the trade; ignoring `ok` and dereferencing `nil` gives back the
// crash, without the message.
show_greeting :: proc(ctx: ^web.Context) {
	s, ok := web.state(ctx, App_State)
	if !ok {
		web.internal_error(ctx)
		return
	}
	web.ok(ctx, Greeting{greeting = s.greeting})
}

// Writing. The pointer is the one `main` created, so this increments the
// caller's own counter and every later request sees it.
//
// Handlers execute concurrently by default, so the shared counter is atomic.
// Immutable application state needs no synchronization.
record_visit :: proc(ctx: ^web.Context) {
	s, ok := web.state(ctx, App_State)
	if !ok {
		web.internal_error(ctx)
		return
	}
	_ = sync.atomic_add(&s.visits, 1)
	web.no_content(ctx)
}

show_stats :: proc(ctx: ^web.Context) {
	s, ok := web.state(ctx, App_State)
	if !ok {
		web.internal_error(ctx)
		return
	}
	web.ok(ctx, Stats{visits = sync.atomic_load(&s.visits)})
}
