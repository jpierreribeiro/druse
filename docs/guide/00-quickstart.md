# Quickstart

A running server in five minutes. You type this; you do not read about it.

## What you need

The pinned Odin compiler — the exact build is in `odin-version.txt` — and a
clone of the `druse` repository. There is nothing to install.

## 1. Make a directory

```sh
mkdir hello && cd hello
```

## 2. Write `main.odin`

```odin
package main

import web "druse:web"

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	web.get(&app, "/", hello)

	web.serve(&app, 8080)
}

hello :: proc(ctx: ^web.Context) {
	web.ok(ctx, Message{message = "Hello, World!"})
}

Message :: struct {
	message: string `json:"message"`,
}
```

## 3. Run it

```sh
odin run . -collection:druse=/path/to/druse
```

## 4. Call it

```sh
$ curl http://localhost:8080/
{"message":"Hello, World!"}
```

`Ctrl+C` stops it. **That is a complete server** — routing, JSON, and the
standard error responses for everything you did not write.

## 5. Add a parameter

Change `main` and add a handler:

```odin
	web.get(&app, "/users/:id", get_user)
```

```odin
get_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}
	web.ok(ctx, User{id = id, name = "Ada"})
}

User :: struct {
	id:   int    `json:"id"`,
	name: string `json:"name"`,
}
```

```sh
$ curl http://localhost:8080/users/7
{"id":7,"name":"Ada"}

$ curl http://localhost:8080/users/abc
{"error":{"code":"invalid_path_parameter", ...}}
```

**You did not write that error.** `web.path_int` answered it. That
`if !ok { return }` is the shape of every fallible extractor in Druse — return
without writing, because the response is already committed.

## 6. Add a middleware

```odin
	web.use(&app, web.request_id)   // before any route
	web.use(&app, web.logger)
```

Every `web.use` goes before every route. The build refuses the other order.

**`web.logger` writes to `context.logger`, and Odin gives you none by default,**
so on the program above it prints nothing. Druse does not import `core:log` —
that would cost about 37 KiB in every binary, including the ones that never log
— so installing a logger is the application's line to write:

```odin
import "core:log"

main :: proc() {
	context.logger = log.create_console_logger()
	// ... the rest of main
}
```

This is not only about request lines. **Every framework diagnostic goes the same
way**, so without a logger a failure reports nowhere — including a `web.serve`
that could not bind its port.

## Next steps

- [`03-subjects/routing.md`](03-subjects/routing.md) — parameters, groups, and
  why static beats parametric.
- [`03-subjects/request.md`](03-subjects/request.md) — reading input, and the
  one lifetime rule that governs it.
- [`03-subjects/response.md`](03-subjects/response.md) — sending output.

Then [`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md).
Read it before you write a handler that returns a string — it prevents more
defects than anything else here.

## One thing to know now

A fault in a handler — a panic, a failed assertion, an out-of-bounds index —
**aborts the process**. Odin has no recoverable panic, so there is no recovery
middleware and there never will be. Run under a supervisor with
`Restart=on-failure`.

A handler that *returns without responding* is different and safe: it gets a
standardized 500.
