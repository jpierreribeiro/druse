# Routing

Registering routes, grouping them, and middleware.

Generated from `build/phase1-public-signatures.txt` and the source. Do
not edit by hand — run `build/gen_reference.py`.

## `get`

```odin
get :: proc(a: ^App, pattern: string, handler: Handler)
```

get registers a handler for GET requests matching `pattern`.

Taught in [`03-subjects/routing.md`](../guide/03-subjects/routing.md).

## `post`

```odin
post :: proc(a: ^App, pattern: string, handler: Handler)
```

post registers a handler for POST requests matching `pattern`. See `get` for the pattern, ownership and matching rules.

Taught in [`03-subjects/routing.md`](../guide/03-subjects/routing.md).

## `put`

```odin
put :: proc(a: ^App, pattern: string, handler: Handler)
```

put registers a handler for PUT requests matching `pattern`. See `get`.

## `patch`

```odin
patch :: proc(a: ^App, pattern: string, handler: Handler)
```

patch registers a handler for PATCH requests matching `pattern`. See `get`.

## `delete`

```odin
delete :: proc(a: ^App, pattern: string, handler: Handler)
```

delete registers a handler for DELETE requests matching `pattern`. See `get`.

## `route`

```odin
route :: proc(ctx: ^Context) -> string
```

route returns the REGISTERED PATTERN this request matched — `"/users/:id"`, never `"/users/42"` — or `""` when no route matched.

## `router`

```odin
router :: proc() -> Router
```

router creates an empty, detached Router.

Taught in [`03-subjects/routing.md`](../guide/03-subjects/routing.md).

## `Router`

```odin
Router :: struct {using app: App}
```

Router is a detached collection of routes and middleware, built exactly like an application and then attached to one with `mount`.

## `mount`

```odin
mount :: proc(a: ^App, prefix: string, r: ^Router)
```

mount attaches every route of `r` to the application at `prefix`, with the combined middleware chain: the application's globals first, then the router's own middleware in their `use` order, then the handler (spec §2.1 — outermost first). Routers nest: mounting an inner router into an outer one, then the outer into the App, composes prefixes and chains in that same outermost-first order.

Taught in [`04-rules/composition-and-cost.md`](../guide/04-rules/composition-and-cost.md).

## `use`

```odin
use :: proc(a: ^App, middleware: Handler)
```

use registers `middleware` to run, in registration order, around EVERY dispatch — routed requests and 404/405 misses alike (ADR-023).

Taught in [`05-recipes/write-a-middleware.md`](../guide/05-recipes/write-a-middleware.md).

## `next`

```odin
next :: proc(ctx: ^Context)
```

next runs the remainder of the current chain — later middleware, then the terminal step — and returns when all of it has returned.

Taught in [`05-recipes/write-a-middleware.md`](../guide/05-recipes/write-a-middleware.md).

## `Handler`

```odin
Handler :: proc(ctx: ^Context)
```

Handler is the one and only handler shape (ADR-011). It takes the request context and returns nothing: handlers respond through the response helpers. Do not add a second handler signature, and do not return `error`, `Handler_Error`, `Handler_Outcome`, or any other result from a handler.
