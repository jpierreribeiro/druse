# The shape of an application

**Assumes:** [`core-and-crystals.md`](core-and-crystals.md).

There is no container and no registry, so every long-lived value is visible in
one procedure. This page shows that procedure.

## The composition root

`main` is the composition root. It does four things, in order:

1. It creates every service.
2. It builds the application over one typed state value.
3. It mounts routers and registers middleware.
4. It serves, and it destroys what it created.

Everything a handler can reach was put there by a line you can read.

## One typed state value

`web.app_with_state` takes a pointer to one struct you declare. A handler reads
it back with `web.state`:

```odin
App_State :: struct {
	greeting: string,
}

main :: proc() {
	state := App_State{greeting = "hello"}

	app := web.app_with_state(&state)
	defer web.destroy(&app)

	web.get(&app, "/greet", greet)
	web.serve(&app, 8080)
}

greet :: proc(ctx: ^web.Context) {
	s := web.state(ctx, App_State)
	web.text(ctx, .OK, s.greeting)
}
```

`web.state` asserts the type before it casts. A wrong type aborts at the first
request rather than reading the wrong bytes.

One value, not many. When you need a second service, add a field. That struct
is your service list, and its declaration is the only place it exists.

`app_with_state` rejects a nil pointer.

**The state must outlive the application.** `state` above is a local in `main`,
and `main` blocks in `web.serve`, so it does. If you build the application
inside a helper procedure and return it, the state dies and every handler reads
freed stack. See
[`../04-rules/ownership-and-lifetime.md`](../04-rules/ownership-and-lifetime.md).

## Services go in the struct

A pool is a service. It is created in `main`, held in `App_State`, and closed
in `main`:

```odin
App_State :: struct {
	pool: pg.Pool,
}

main :: proc() {
	pool, e := pg.pool_open(cfg)
	if pg.is_err(e) {
		os.exit(1)
	}
	defer pg.pool_close(&pool)

	state := App_State{pool = pool}

	app := web.app_with_state(&state)
	defer web.destroy(&app)

	web.serve(&app, 8080)
}
```

Read the order. The pool is opened before the application and closed after it,
because `defer` runs last-registered first. That ordering is not incidental: a
handler must not reach a closed pool during drain.

## Routers are detached, and the application mounts them

A Route Crystal returns a `web.Router`. It does not receive your `App` and it
cannot change it (ADR-C002). You choose the prefix, the order and the
middleware:

```odin
	r := health.routes()
	web.mount(&app, "/internal", &r)
```

**`mount` copies the routes, then closes the router.** After the call the
application owns everything, and the router needs no teardown. There is no
`destroy` for a `Router`.

Two rules follow from that, and
[`../04-rules/composition-and-cost.md`](../04-rules/composition-and-cost.md)
states them.

## Request-scoped state is one typed value

A middleware computes something and the handler reads it back:

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

The first call in a request zeroes the value and stamps the type. Every later
call asserts the same type.

Storage is request-local and fixed. **The `^Auth` must not escape the request.**

One type, for the whole request, across every middleware. Two middlewares that
each want their own value share one struct. That is the cost stated in
[`what-it-refuses.md`](what-it-refuses.md).

## Shutdown is yours to wire

`web.stop(&app)` is thread-safe and signal-safe, and it drains within
`Limits.max_drain_time`. Druse installs no `SIGTERM` handler for you. Your
`main` installs one and calls `web.stop`.

See `docs/operations.md` for the pattern.

## Next

- [`../04-rules/ownership-and-lifetime.md`](../04-rules/ownership-and-lifetime.md)
  — read this before you write a handler that returns a string.
