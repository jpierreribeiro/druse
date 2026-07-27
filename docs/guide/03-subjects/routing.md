# Routing

**Assumes:** [`../02-build-notes/01-nothing-to-hello.md`](../02-build-notes/01-nothing-to-hello.md).

## The five verbs

```odin
web.get(&app, "/notes", list_notes)
web.post(&app, "/notes", create_note)
web.put(&app, "/notes/:id", replace_note)
web.patch(&app, "/notes/:id", patch_note)
web.delete(&app, "/notes/:id", delete_note)
```

All five have the same signature: `proc(a: ^App, pattern: string, handler:
Handler)`. There is no variadic method list and no `web.any`.

An unmatched path is `404`. A known path under another method is `405`, with an
`Allow` header naming the real methods. You write neither.

## Parameters

A segment starting with `:` is a parameter:

```odin
web.get(&app, "/users/:id", get_user)
```

```odin
	id := web.path(ctx, "id")            // string, always present
	n, ok := web.path_int(ctx, "id")     // int; sends 400 itself if it is not one
```

`web.path` returns a **view into the request**. It is valid while the handler
runs. `web.path_int` is fallible and answers `400` for you — return without
writing.

There are no wildcard or regex segments.

## Static wins over parametric

```odin
web.get(&app, "/users/:id", get_user)
web.get(&app, "/users/me",  get_me)      // registered second
```

`GET /users/me` runs `get_me`. **Registration order does not matter** — a
static segment always beats a parametric one at the same position.

That is a property of the router, not a rule you maintain. You can register in
any order and reorder freely.

## Which pattern matched

```odin
	pattern := web.route(ctx)     // "/users/:id", never "/users/42"
```

Use it for logging and metrics. It is the registered pattern, so it is bounded
by your route table rather than by traffic — a path would not be.

## Groups: a detached router

There is no `web.group`. A group is a `Router` value you build and mount:

```odin
api_router :: proc() -> web.Router {
	r := web.router()
	web.use(&r, require_json)
	web.get(&r, "/users", list_users)
	return r
}
```

```odin
	api := api_router()
	web.mount(&app, "/api/v1", &api)
	web.destroy(&api)
```

Routing is a value, so it composes with every tool the language already has —
a procedure can build one, return one, or take one.

`mount` copies the routes and closes the source. Routers nest: mount an inner
into an outer, then the outer into the application, and prefixes compose.

See [`../04-rules/composition-and-cost.md`](../04-rules/composition-and-cost.md)
for what that copy costs and the three rules it implies.

## Middleware order

Every `web.use` comes **before** any route registration, and it is enforced at
boot. First registered is outermost.

For a guard on three routes out of thirty, mount a small router instead of
using a global middleware. See
[`../05-recipes/write-a-middleware.md`](../05-recipes/write-a-middleware.md).

## No automatic 404 or 405

`web.bare()` builds an application with no default miss responses, when you
want to answer misses yourself. `web.app()` is the one you want otherwise.
