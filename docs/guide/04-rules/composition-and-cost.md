# Composition and cost

**Assumes:** [`../01-concepts/shape-of-an-application.md`](../01-concepts/shape-of-an-application.md).

What a composition call copies, and what it costs on every request.

## `mount` copies, then closes

```odin
	r := health.routes()
	web.mount(&app, "/internal", &r)
	web.destroy(&r)
```

`mount` copies every route into the application and then marks the source
closed. The application owns its copy from that point.

Three rules follow:

- **Destroy the source router.** It still owns the storage its own routes and
  middleware were built in, and `mount` copied out of that storage rather than
  taking it. `Router` embeds `App`, so the same `web.destroy` accepts a
  `^Router`. There is no separate `destroy_router`.
- **Registering on a router after you mount it is a boot failure.** The router
  is closed, and a later `web.get` on it is refused loudly. It is not a
  silently dead route.
- **Mounting a closed router poisons the application.** So does mounting the
  same router twice. Build one router, mount it once.

Skipping the `destroy` in a `main` that serves for the whole process life leaks
nothing that outlives the process, and `examples/05-route-groups` does skip it.
The reference application destroys it anyway. Do that: the habit is what keeps
it correct when the same code moves into a test that runs a thousand times.

**Pass `&r`, never `r`.** `web.router()` returns a `Router` by value. Treat it
exactly as you treat a `strings.Builder`: after you register a route on it, a
copy of the value is not the same router.

## A router is just a value

`web.router()` allocates nothing. Storage is lazy, and the first `use` or
registration creates it.

That is why a router can be built and returned by an ordinary procedure:

```odin
api_router :: proc() -> web.Router {
	r := web.router()
	web.use(&r, require_json)
	web.get(&r, "/users", list_users)
	return r
}
```

This is the shape a closure-based `group(...)` API cannot give you. Routing is
a value, so it composes with every tool the language already has.

Routers nest. Mount an inner router into an outer one, then the outer into the
application. Prefixes and middleware chains compose in the same outermost-first
order.

## Order is yours, and it is enforced

`web.use` registers a middleware. Every `web.use` call must come **before** any
route registration. The framework enforces this fail-closed rather than
silently applying a middleware to some routes and not others.

Middleware runs in onion order: the first registered is the outermost. It sees
the request first and the response last.

```odin
	web.use(&app, web.logger)      // outermost
	web.use(&app, auth)            // inner

	web.get(&app, "/me", me)       // routes AFTER every use
```

`web.next(ctx)` passes control inward. A middleware that does not call
`web.next` short-circuits, and the handler never runs.

## The route-level guard

A middleware registered with `web.use` runs on every request, including the
ones it does not care about.

For a guard that protects three routes out of thirty, build a one-route router
instead:

```odin
	admin := web.router()
	web.use(&admin, require_admin)
	web.get(&admin, "/users", list_users)

	web.mount(&app, "/admin", &admin)
```

`require_admin` now runs on `/admin/*` and nowhere else. A one-route `Router`
is the route-level guard, and there is no per-route middleware annotation
because this already is one.

## What a middleware costs

A middleware is a procedure call per request, plus whatever it does.

That sounds obvious, and it is the point: there is nothing else. No reflection,
no lookup, no dynamic dispatch through a registry. What you wrote is what runs.

Two costs are worth stating because they are easy to add without noticing:

- **A middleware that hits the database runs a query per request.** An auth
  middleware on `web.use` costs one session lookup for every request, including
  the ones that do not need identity. Move it to a router that covers the
  authenticated routes.
- **A middleware that allocates does so per request.** Nothing pools it for
  you.

## Configuration parsing happens before the hot path

Reflection and configuration parsing, when justified, happen before the hot
path, and they fail closed.

Read your configuration in `main`. Do not read an environment variable inside a
handler. It costs a syscall per request, and it moves a start-time failure to
request time, where your supervisor cannot see it.

## Everything bounded has a stated exhaustion result

Queues, pools, messages and retries always have a numeric bound and a result
for exhaustion. This is a rule the Crystals contract enforces on every package.

| Bound | Exhaustion result |
|---|---|
| `pg.Pool` size | `acquire` returns a typed error after `DEFAULT_ACQUIRE_TIMEOUT_MS` |
| `http_client` pool | `Pool_Exhausted` |
| `password` limiter | `Verify_Result.Too_Busy` — nothing was hashed |
| `session.Config.max_sessions_per_subject` | `Error_Kind.Too_Many_Sessions` — refuses, never evicts |
| `validate` error set | Truncation is reported, not silent |
| `config` error set | `config.truncated` |

**Handle the exhaustion result as a distinct case.** It is not a failure of the
thing you asked for. `Too_Busy` is not a wrong password, and a pool timeout is
not a missing row. See
[`result-vocabularies.md`](result-vocabularies.md).

## What the build check does not prove

The project's build check is thorough, and it is not a correctness proof.

The recorded fact: 35 green negative controls did not catch four defects, and
all four were integration defects — each package correct, the composition
wrong.

A reader who concludes "the check is green, therefore the composition is
correct" has been taught the wrong thing. The check proves each package does
what its tests say. It does not prove your `main` wired them together
correctly.

That is what your own integration tests are for. `web.test_request` runs a
request through real routing without a socket, so an integration test costs you
nothing but the writing.
