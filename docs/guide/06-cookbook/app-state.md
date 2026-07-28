# Application state

A database pool, a configuration struct, a template cache — the things a service
creates once and needs everywhere. `examples/07-app-state`, complete.

## Server

<!-- druse:begin examples/07-app-state/main.odin -->
```odin
package main

import "core:sync"
import web "druse:web"

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

show_greeting :: proc(ctx: ^web.Context) {
	s, ok := web.state(ctx, App_State)
	if !ok {
		web.internal_error(ctx)
		return
	}
	web.ok(ctx, Greeting{greeting = s.greeting})
}

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
```
<!-- druse:end -->

## Run

```text
odin run examples/07-app-state -collection:druse=.
```

## What to notice

**No type arguments on any handler.** That is the whole reason this shape was
chosen (ADR-004). The alternative was a parametric `App(S)` and `Context(S)`,
which would put a type parameter on every handler signature in your program.

The price: a wrong type is caught at **runtime** by an assert that aborts. You
meet it on your first request, not in production.

**The pointer is yours, and the value must outlive the App.** The App stores the
address, not a copy — which is what makes a connection pool work and what a copy
would break. Put the value in `main`, next to the App, exactly as above. A
pointer to a local in a helper that returns is freed stack.

**One value, not many.** A new service is a new field on that struct. That
declaration is your entire service list, and there is no registry to ask.

## Next

[`../03-subjects/context-and-state.md`](../03-subjects/context-and-state.md) —
the per-request slot as well, and why there is only one of each.
