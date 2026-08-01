# 1 — From nothing to a running server

**Assumes:** [`../01-concepts/what-this-is.md`](../01-concepts/what-this-is.md).
You can program. You do not need to know Odin.

This chapter gets one process listening on a port. The next one gives it a
database.

Every program in this build-along is a real program under `examples/`. The
project's build check compiles all of them. Nothing here was typed into
markdown and hoped for.

## What you need

- The pinned Odin compiler. The exact build is in `odin-version.txt`.
- A clone of the `druse` repository.

There is nothing to install. You point the compiler at the repository with one
flag.

## The one flag

Druse is used through an Odin *collection*:

```text
-collection:druse=/path/to/druse
```

That is what makes `import web "druse:web"` resolve. From inside the repository
the path is `.`.

## The program

Create a directory with a `main.odin`:

```odin
package main

import web "druse:web"

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	web.get(&app, "/ping", ping)

	web.serve(&app, 8080)
}

ping :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}
```

That is `examples/01-hello-world`, complete.

Four things happen:

- `web.app()` creates the application.
- `defer web.destroy(&app)` releases it when `main` ends. Call it once, on the
  value `web.app()` returned.
- `web.get` registers a route. The handler runs on `GET /ping`.
- `web.serve` binds the port and **blocks** while the server runs.

## Run it

```text
odin run . -collection:druse=/path/to/druse
```

Or, from the repository root:

```text
odin run examples/01-hello-world -collection:druse=.
```

In another terminal:

```text
$ curl http://localhost:8080/ping
pong
```

`Ctrl+C` stops it.

## A parameter, and the shape you will use everywhere

A path segment starting with `:` is a parameter:

```odin
get_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}

	web.ok(ctx, User{id = id, name = "Ada"})
}
```

Register it with `web.get(&app, "/users/:id", get_user)`.

**Read the `if !ok { return }`.** If the id is missing or is not a number,
`web.path_int` has *already* sent a `400` with a proper error body. Your handler
returns and writes nothing.

That is the shape of every fallible extractor in Druse. Never write your own
error response for a case an extractor already answers.

`web.ok` sends `200` with the value serialized as JSON. Pass the value, not a
pointer to it.

## Reading a body

```odin
create_user :: proc(ctx: ^web.Context) {
	input: Create_User
	if !web.body(ctx, &input) {
		return
	}

	web.created(ctx, User{id = 1, name = input.name})
}
```

Same shape. A missing body, malformed JSON, a wrong field type, an undeclared
key or a body over the limit — `web.body` has already answered.

**Call `web.body` at most once per request.** The body is read once. A second
call decodes nothing.

## Test it without a socket

```odin
check_ping :: proc() -> bool {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", ping)

	res := web.test_request(&app, .GET, "/ping")
	return res.status == .OK && res.body == "pong"
}
```

`web.test_request` runs one request through the real routing and returns what
the client would have received. It takes a method and a path, nothing else.

Write these from the first day. They cost one procedure call, and they are the
only thing that checks your composition — see
[`../04-rules/composition-and-cost.md`](../04-rules/composition-and-cost.md).

## The four things that will surprise you

State them now, so nothing does later.

- **A fault in a handler aborts the process.** A panic, a failed assertion or an
  out-of-bounds index takes the server down and the client sees an empty reply.
  There is no recovery middleware and there never will be (ADR-020). Run under a
  supervisor with `Restart=on-failure`. A handler that *returns without responding*
  is different and safe: it gets the standardized 500.
- **The write and idle timeouts are off by default.** `Limits.max_request_time`
  bounds arrival and is on. `max_write_time` and `max_idle_time` default to `0`.
  Turn them on in production, or keep a reverse proxy in front.
- **A response has no size limit.** `max_body` caps what a client may send.
  Nothing caps what your handler builds, and the response is buffered whole
  (ADR-014). Run under a memory cgroup.
- **Shutdown is not wired to a signal for you.** `web.stop(&app)` is
  signal-safe and drains, but your `main` installs the `SIGTERM` handler. See
  `docs/operations.md`.

## Next

[`02-database-and-migrations.md`](02-database-and-migrations.md) — a schema, a
pool, and why the server never migrates itself.
