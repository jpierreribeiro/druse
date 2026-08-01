# Quick Start

Druse is a small HTTP framework for Odin, aimed at JSON APIs. You write
handlers; it does routing, JSON, and the standard error responses.

This page takes you from nothing to a running API. It assumes you can program,
but not that you know Odin or anything about memory management or HTTP servers.

## What you need

- The pinned Odin compiler. The exact build this project is tested against is
  in `odin-version.txt`.
- A local copy of this repository. There is nothing to install: you point the
  compiler at the repository with one flag.

## The one flag

Druse is used through an Odin *collection*. Every command that builds your
program includes:

```text
-collection:druse=/path/to/druse
```

That is what makes `import web "druse:web"` resolve. From inside this
repository the path is simply `.`.

## Your first server

Create a directory with a `main.odin`:

<!-- compile: examples/01-hello-world/main.odin -->
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

Four things happen here:

- `web.app()` creates the application.
- `defer web.destroy(&app)` releases it when `main` ends. Call it once.
- `web.get` registers a route. The handler runs on `GET /ping`.
- `web.serve` binds the port and **blocks** while the server runs.

## Run it

```text
odin run . -collection:druse=/path/to/druse
```

Or, from the repository root, run the example directly:

```text
odin run examples/01-hello-world -collection:druse=.
```

## Try it

In another terminal:

```text
$ curl http://localhost:8080/ping
pong
```

Press `Ctrl+C` to stop the server.

## A route with a parameter

A path segment starting with `:` is a parameter. Read it with `web.path_int`
when it should be a number:

<!-- fragment: phase1/path-int -->
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

**This is the shape you will use everywhere.** If the id is missing or is not a
number, `path_int` has *already* sent a `400` with a proper error body. Your
handler just returns — never write your own error response for that.

`web.ok` sends `200` with the value serialized as JSON. Pass the value itself,
not a pointer to it.

## Reading a JSON body

`web.body` decodes the request body into a variable you own:

<!-- fragment: phase1/body -->
```odin
create_user :: proc(ctx: ^web.Context) {
	input: Create_User
	if !web.body(ctx, &input) {
		return
	}

	web.created(ctx, User{id = 1, name = input.name})
}
```

Same shape again: if the body is missing, malformed, has a wrong field type,
contains an undeclared key, or exceeds the body limit, `web.body` has already
answered and you return.

Call `web.body` **at most once per request**. The body is read once; a second
call decodes nothing.

## Testing without a server

You do not need a socket to test a handler. `web.test_request` runs one request
through the real routing and returns what the client would have received:

<!-- fragment: phase1/test-request -->
```odin
check_ping :: proc() -> bool {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", ping)

	res := web.test_request(&app, .GET, "/ping")
	return res.status == .OK && res.body == "pong"
}
```

`test_request` takes a method and a path — nothing else.

## Errors you get for free

You do not write these:

```text
GET  /unknown-path        404   {"error":{"code":"not_found", ...}}
DELETE /a-GET-only-path   405   + an Allow header listing the real methods
GET  /users/abc           400   invalid_path_parameter
POST with broken JSON     400   invalid_json
POST with wrong type      400   invalid_field + field path
POST with unknown key     400   unknown_field + field path
POST with a huge body     413   body_too_large
```

Every one is JSON, with the same envelope shape. `docs/errors.md` lists them
all.

When you want to send an error yourself:

<!-- fragment: phase1/errors -->
```odin
deny :: proc(ctx: ^web.Context) {
	web.bad_request(ctx, "email is required")
}
```

The full set is `bad_request`, `unauthorized`, `forbidden`, `not_found` and
`internal_error`.

## Current limitations

**The canonical list lives in one place: `planning/closure-readiness-matrix.md`.**
Every framework-owned resource has a row there — limit, deadline, cancellation,
saturation policy, metric, shutdown behaviour — and a gate fails the build when
a cell goes missing. This page used to keep its own copy of that list; it
drifted into claiming that shipped features did not exist, which is exactly what
a list maintained in eleven places does.

The four that will surprise you first, so nothing does:

- **A fault in a handler aborts the process.** A panic, a failed assertion or an
  out-of-bounds index takes the server down; the client sees an empty reply.
  There is no recovery middleware and there never will be — Odin has no
  recoverable panic (ADR-020). Run under a supervisor with `Restart=on-failure`.
  What Druse *does* guarantee is the other half: a handler that returns
  without responding gets the standardized 500. See `docs/errors.md`.
- **The write and idle timeouts are OFF by default.** `Limits.max_request_time`
  bounds request *arrival* (a slowloris defence) and is on. `Limits.max_write_time`
  bounds a slow-reading client stalling a response write (the connection is
  reset at the deadline) and `Limits.max_idle_time` reclaims idle keep-alive
  slots — both default to `0` = off. Enable them in production, sized to your
  slowest legitimate client, or keep a reverse proxy's timeouts in front.
- **A response has no size limit.** `max_body` caps what a client may send;
  nothing caps what your handler may build, and the response is buffered whole
  (ADR-014). Run under a memory cgroup.
- **Graceful shutdown is not wired to a signal for you.** `web.stop(&app)` is
  thread- and signal-safe and drains within `Limits.max_drain_time`, but the
  core installs no `SIGTERM`/`SIGINT` handler — your `main` must install one and
  call `web.stop`. See `docs/operations.md` for the pattern.

Druse is usable for building and testing a JSON API today, and for a
controlled pilot behind a reverse proxy under a supervisor. Read
`docs/operations.md` before exposing it to real traffic.

## Next

Three complete programs, all compiled by the project's own gate:

- `examples/01-hello-world` — the program above.
- `examples/02-json-api` — a CRUD-shaped API: list, read, create, replace,
  update, delete.
- `examples/03-route-params` — path parameters, static-route precedence, and
  the three query extractors.

Then `docs/canonical-patterns.md` for the one recommended form of each task,
and `docs/errors.md` for the full error contract.

---

*A note, not an instruction:* the HTTP server underneath is an internal
implementation detail and is replaceable. You never configure it, and none of
it appears in the API you write against.
