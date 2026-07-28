# Write a middleware

**Assumes:** [`../04-rules/composition-and-cost.md`](../04-rules/composition-and-cost.md).

A middleware is a `Handler` — `proc(ctx: ^Context)`, the same signature as any
route handler.

`web.next(ctx)` passes control inward, so a middleware runs code before and
after the handler. **A middleware that does not call it short-circuits**, and
the handler never runs — which is how a guard refuses:

```odin
require_admin :: proc(ctx: ^web.Context) {
	token, ok := web.bearer_token(ctx)
	if !ok || !is_admin(token) {
		web.unauthorized(ctx, "admin only")
		return                 // no web.next — the handler never runs
	}
	web.next(ctx)
}
```

## Registration order is execution order

```odin
	web.use(&app, web.request_id)   // outermost
	web.use(&app, web.logger)
	web.use(&app, timing_gate)      // innermost

	web.get(&app, "/public", public_handler)   // routes AFTER every use
```

Every `web.use` must come **before** any route, enforced fail-closed: a `use`
after a route is a boot failure, not a middleware that silently covers some
routes. Registering a guard one line too late would hand a secret body to an
unauthenticated caller, with no error and no runtime symptom.

## The two you get

`web.request_id` assigns a correlation ID, read back through the **one**
canonical accessor — there is no `web.request_id_value`:

```odin
	id, _ := web.header(ctx, "X-Request-Id")
```

It is unique and **deliberately not unguessable. Never use it as
authentication.**

`web.logger` logs the request. Put `request_id` first so everything after it
runs with the ID assigned.

## Reading the request

`web.header` and `web.bearer_token` are pure lookups: case-insensitive, first
occurrence wins, **no automatic response, nothing logged**. `bearer_token` is
strict RFC 6750.

Values are **request-lifetime views**. `ctx.request` carries `method: Method`,
`path`, `query`, `headers: Header_View` and `body: []u8`, all with that
lifetime.

## Handing a value to the handler

```odin
Auth :: struct { account_id: i64 }

auth :: proc(ctx: ^web.Context) {
	web.request_state(ctx, Auth).account_id = 42
	web.next(ctx)
}
```

The handler reads the same type back; a different type aborts.

To guard three routes rather than thirty, use a one-route router instead of
`web.use` — see
[`../04-rules/composition-and-cost.md`](../04-rules/composition-and-cost.md).
