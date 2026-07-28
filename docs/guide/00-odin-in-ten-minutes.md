# Odin in ten minutes

**Assumes:** you can program in something. It does not assume you know Odin.

You do not need to learn Odin to use Druse. You need about eight things, and
they are all on this page. Come back here when a symbol in a sample looks
strange.

## `::` declares. `:=` assigns.

```odin
PORT :: 8080                       // a constant, known at compile time
port := 8080                       // a variable
```

`::` is the one that surprises people. Everything declared with it — a
constant, a type, a procedure — is a compile-time thing with a name.

```odin
ping :: proc(ctx: ^web.Context) { ... }    // a procedure is declared with ::
User :: struct { ... }                     // so is a type
```

That is why every handler in this guide reads `name :: proc(...)`.

## A procedure

```odin
add :: proc(a: int, b: int) -> int {
	return a + b
}
```

Parameters are `name: type`. The return type follows `->`.

**A procedure can return more than one value**, and Druse uses this everywhere:

```odin
path_int :: proc(ctx: ^Context, name: string) -> (value: int, ok: bool)
```

You read both:

```odin
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}
```

Use `_` to discard one you do not want:

```odin
	id, _ := web.header(ctx, "X-Request-Id")
```

## `^` is a pointer

```odin
	app := web.app()          // app is an App
	web.get(&app, "/", ping)  // &app takes its address
```

`^App` is "pointer to App". `&app` makes one. `app^` reads through one.

You pass `&app` because `web.get` changes the application. You pass `ctx`
already as `^web.Context`, so you do not add another `&`.

## `defer` runs on the way out

```odin
main :: proc() {
	app := web.app()
	defer web.destroy(&app)     // runs when main ends, whatever happens

	web.serve(&app, 8080)
}
```

The deferred call runs when the enclosing procedure returns — from any path,
including early returns you add later. That is why every resource in this guide
is released with `defer` on the line after it is acquired.

**Deferred calls run last-registered-first.** Open the pool before the
application and it closes after it.

## A struct, and the tag that names it on the wire

```odin
User :: struct {
	id:    int    `json:"id"`,
	name:  string `json:"name"`,
}
```

The backtick part is a **tag**. Druse reads `json:"..."` to decide the field's
name in JSON. Without it the field would use its Odin name.

Make one with named fields:

```odin
	u := User{id = 1, name = "Ada"}
```

**Every field you do not name is the zero value** — `0`, `""`, `false`. Odin has
no "unset". That is why this guide keeps saying *start from `DEFAULT_CONFIG`*:

```odin
	c := session.DEFAULT_CONFIG    // copy the defaults
	c.idle_ttl_seconds = 3600      // change one
```

## `Maybe(T)` is a value that may not be there

```odin
	body: Maybe(string)
```

Read it with `.?`, which gives you the value and whether it was present:

```odin
	if b, has := input.body.?; has {
		// b is a string
	}
```

This is how JSON `null` stays different from `""`, and how a nullable database
column stays different from an empty one.

## An enum, and why the zero matters

```odin
Verify_Result :: enum {
	Invalid,
	Valid,
	Too_Busy,
}
```

**The first member is the zero value.** A variable nothing assigned holds it.

Druse and Crystals put the *safe* value first on purpose — `Invalid`,
`Rejected`, `Anonymous`, `Failed`. A result you forgot to assign denies rather
than grants.

Write a member with a leading dot when the type is already known:

```odin
	web.text(ctx, .OK, "pong")          // .OK, not web.Status.OK
```

Switch on it, and the compiler tells you when you missed a case:

```odin
	switch password.verify(...) {
	case .Valid:      // ...
	case .Invalid:    // ...
	case .Too_Busy:   // ...
	}
```

## Strings and slices are views

```odin
	name := web.path(ctx, "name")     // points into the request buffer
```

A `string` in Odin is a pointer and a length. **It does not own its bytes.**

That single fact is the subject of
[`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md), and
it is the difference between this framework and a garbage-collected one. Read
that chapter before you write a procedure that returns a string.

`[]byte` and `[]User` are slices — the same idea for a sequence.

## Imports and collections

```odin
import web "druse:web"
import pg "crystals:db/postgres"
```

`web` and `pg` are the names you choose locally. `druse:` and `crystals:` are
**collections**, mapped by a flag on the build command:

```sh
odin build . -collection:druse=/path/to/druse
```

There is no package manager. That flag is the whole dependency mechanism.

## That is enough

You now know every Odin construct this guide uses. What is left is the
framework.

If you want the language properly, the official Odin documentation is at
odin-lang.org. You do not need it to finish this guide.

## Next

[`00-quickstart.md`](00-quickstart.md) — a running server in five minutes.
