# Context and state

**Assumes:** [`request.md`](request.md).

`ctx` is not an extension bag. There is no dynamically keyed store and no
`context.WithValue` equivalent. There are exactly two typed slots.

## Application state — one struct, whole process

```odin
app_with_state :: proc(state: ^$T) -> App
state          :: proc(ctx: ^Context, $T: typeid) -> ^T
```

```odin
App_State :: struct {
	db:       pg.Pool,
	sessions: session.Manager,
}

main :: proc() {
	st := App_State{...}

	app := web.app_with_state(&st)
	defer web.destroy(&app)
	// ...
}

handler :: proc(ctx: ^web.Context) {
	s := web.state(ctx, App_State)
	// s.db, s.sessions
}
```

One value, not many. A new service is a new **field**, and that struct
declaration is your entire service list.

`web.state` asserts the type before it casts, so a wrong type aborts at the
first request rather than reading the wrong bytes. `app_with_state` rejects a
nil pointer.

**The state must outlive the application.** A local in `main` works because
`main` blocks in `web.serve`. Build the application inside a helper that
returns it, and every handler reads freed stack.

## Request state — one typed value, one request

```odin
request_state :: proc(ctx: ^Context, $R: typeid) -> ^R
```

```odin
Auth :: struct { account_id: i64 }

auth :: proc(ctx: ^web.Context) {
	web.request_state(ctx, Auth).account_id = 42
	web.next(ctx)
}

me :: proc(ctx: ^web.Context) {
	web.ok(ctx, web.request_state(ctx, Auth)^)
}
```

A middleware computes; the handler reads it back.

The first call in a request zeroes the value and stamps the type. Every later
call asserts the same type, and a different one aborts.

Storage is request-local and fixed — no allocation. **The `^R` must not escape
the request.**

## One type, for the whole request

Two independent middlewares cannot each keep their own value. If you need both,
declare one struct holding both — and accept that this couples two otherwise
unrelated pieces of code.

That cost is deliberate. An untyped bag turns a compile error into a runtime
`nil` and makes the set of things in flight unknowable. See
[`../01-concepts/what-it-refuses.md`](../01-concepts/what-it-refuses.md).

## What else is on ctx

`ctx.request` — `method`, `path`, `query`, `headers`, `body`. Read it directly.

`ctx.private` is off limits. A Crystal that reads it is a failed Crystal.

## Services are never global

Pools, clients and caches live in `App_State`. There is no registry, no
container, no package global and no import side effect (ADR-C003). Creation,
readiness and destruction all stay visible in `main`.
