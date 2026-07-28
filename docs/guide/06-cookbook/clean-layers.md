# A layered service

A URL shortener. The point is not the shortener — it is that **each file
answers one question and the dependencies point one way**.

`examples/11-clean-layers`, complete. See
[`../03-subjects/project-layout.md`](../03-subjects/project-layout.md) for the
layout this follows.

```text
handlers → services → store → models
```

## `models.odin` — what the thing IS

No HTTP, no JSON, no storage. This file would be identical if the service were
a CLI.

<!-- druse:begin examples/11-clean-layers/models.odin -->
```odin
package main

// mentions a status code or a column name, it belongs in another layer.

Link :: struct {
	slug:   string,
	target: string,
	hits:   int,
}

Link_Result :: enum {
	Invalid_Slug,
	Ok,
	Invalid_Target,
	Slug_Taken,
	Not_Found,
}

MAX_SLUG_BYTES :: 32
MAX_TARGET_BYTES :: 2048

slug_ok :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > MAX_SLUG_BYTES {
		return false
	}
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

target_ok :: proc(s: string) -> bool {
	return len(s) > 0 && len(s) <= MAX_TARGET_BYTES
}
```
<!-- druse:end -->

## `store.odin` — where it LIVES

In memory here so the example runs with nothing installed. Swapping this file
for one over `crystals:db/postgres` changes nothing above it.

<!-- druse:begin examples/11-clean-layers/store.odin -->
```odin
package main

// calls these four procedures and never learns what is behind them.

Store :: struct {
	links: map[string]Link,
}

store_open :: proc() -> Store {
	return Store{links = make(map[string]Link)}
}

store_close :: proc(s: ^Store) {
	delete(s.links)
}

store_put :: proc(s: ^Store, l: Link) {
	s.links[l.slug] = l
}

store_get :: proc(s: ^Store, slug: string) -> (Link, bool) {
	l, found := s.links[slug]
	return l, found
}

store_bump :: proc(s: ^Store, slug: string) {
	if l, found := s.links[slug]; found {
		l.hits += 1
		s.links[slug] = l
	}
}
```
<!-- druse:end -->

## `service.odin` — what it DOES

Every rule lives here, and nothing else does. It takes plain values and returns
a domain result. **It cannot answer a request, because it cannot see one** —
which is exactly why it is testable without a socket.

<!-- druse:begin examples/11-clean-layers/service.odin -->
```odin
package main

// without a socket.

create_link :: proc(s: ^Store, slug: string, target: string) -> (Link, Link_Result) {
	if !slug_ok(slug) {
		return Link{}, .Invalid_Slug
	}
	if !target_ok(target) {
		return Link{}, .Invalid_Target
	}
	if _, taken := store_get(s, slug); taken {
		return Link{}, .Slug_Taken
	}

	l := Link{slug = slug, target = target, hits = 0}
	store_put(s, l)
	return l, .Ok
}

visit_link :: proc(s: ^Store, slug: string) -> (Link, Link_Result) {
	l, found := store_get(s, slug)
	if !found {
		return Link{}, .Not_Found
	}
	store_bump(s, slug)
	l.hits += 1
	return l, .Ok
}

read_link :: proc(s: ^Store, slug: string) -> (Link, Link_Result) {
	l, found := store_get(s, slug)
	if !found {
		return Link{}, .Not_Found
	}
	return l, .Ok
}
```
<!-- druse:end -->

## `dto.odin` — what crosses the WIRE

<!-- druse:begin examples/11-clean-layers/dto.odin -->
```odin
package main

// One struct for both is how a caller assigns its own primary key.

Create_Link :: struct {
	slug:   string `json:"slug"`,
	target: string `json:"target"`,
}

Link_View :: struct {
	slug:   string `json:"slug"`,
	target: string `json:"target"`,
	hits:   int    `json:"hits"`,
}

Error_View :: struct {
	code:    string `json:"code"`,
	message: string `json:"message"`,
}

view_of :: proc(l: Link) -> Link_View {
	return Link_View{slug = l.slug, target = l.target, hits = l.hits}
}
```
<!-- druse:end -->

## `handlers.odin` — the only layer that knows HTTP exists

Each handler reads input, calls the service, and maps **one domain result onto
one status**. It contains no rules: everything it could decide, the service
already decided.

<!-- druse:begin examples/11-clean-layers/handlers.odin -->
```odin
package main

// service already decided.

import web "druse:web"

create_handler :: proc(ctx: ^web.Context) {
	st, ok := web.state(ctx, App_State)
	if !ok {
		web.internal_error(ctx)
		return
	}

	input: Create_Link
	if !web.body(ctx, &input) {
		return
	}

	l, result := create_link(&st.store, input.slug, input.target)
	switch result {
	case .Ok:
		web.created(ctx, view_of(l))
	case .Invalid_Slug:
		web.bad_request(ctx, "slug must be 1-32 characters of a-z, 0-9 or -")
	case .Invalid_Target:
		web.bad_request(ctx, "target must be 1-2048 characters")
	case .Slug_Taken:
		web.json(ctx, .Conflict, Error_View{code = "slug_taken", message = "that slug is in use"})
	case .Not_Found:
		web.internal_error(ctx)
	}
}

read_handler :: proc(ctx: ^web.Context) {
	st, ok := web.state(ctx, App_State)
	if !ok {
		web.internal_error(ctx)
		return
	}
	slug := web.path(ctx, "slug")

	l, result := read_link(&st.store, slug)
	if result != .Ok {
		web.not_found(ctx, "link")
		return
	}
	web.ok(ctx, view_of(l))
}

visit_handler :: proc(ctx: ^web.Context) {
	st, ok := web.state(ctx, App_State)
	if !ok {
		web.internal_error(ctx)
		return
	}
	slug := web.path(ctx, "slug")

	l, result := visit_link(&st.store, slug)
	if result != .Ok {
		web.not_found(ctx, "link")
		return
	}
	web.set_header(ctx, "Location", l.target)
	web.json(ctx, .Accepted, view_of(l))
}
```
<!-- druse:end -->

## `routes.odin` — the URL shape

<!-- druse:begin examples/11-clean-layers/routes.odin -->
```odin
package main

// opens another.

import web "druse:web"

register_routes :: proc(app: ^web.App) {
	web.post(app, "/links", create_handler)
	web.get(app, "/links/:slug", read_handler)
	web.get(app, "/go/:slug", visit_handler)
}
```
<!-- druse:end -->

## `main.odin` — composition

<!-- druse:begin examples/11-clean-layers/main.odin -->
```odin
package main

import web "druse:web"

App_State :: struct {
	store: Store,
}

main :: proc() {
	state := App_State{store = store_open()}
	defer store_close(&state.store)

	app := web.app_with_state(&state)
	defer web.destroy(&app)

	web.use(&app, web.request_id)
	web.use(&app, web.logger)

	register_routes(&app)

	web.serve(&app, 8080)
}
```
<!-- druse:end -->

## Run

```text
odin run examples/11-clean-layers -collection:druse=.
```

```text
curl -X POST localhost:8080/links -H 'content-type: application/json' \
     -d '{"slug":"odin","target":"https://odin-lang.org"}'
curl localhost:8080/links/odin
curl -i localhost:8080/go/odin
```

## What to notice

**The service returns a domain result, not a status code.** `Link_Result` has
`Slug_Taken`, not `409`. The handler is the only place that knows a taken slug
is a conflict — so a second consumer, a CLI or a worker, gets the same rule
with a different answer.

**`Invalid_Slug` is the zero value.** A `Link_Result` nothing assigned refuses.
That is the framework-wide convention from
[`../04-rules/result-vocabularies.md`](../04-rules/result-vocabularies.md),
applied to your own enum.

**`view_of` is the one place the domain becomes the wire.** Add a field to
`Link` and no client sees it until somebody edits that procedure. That is the
whole reason `dto` is separate from `models`.

**`main` owns everything.** The store opens before the application and closes
after it, because deferred calls run last-registered-first — a handler must not
reach a closed store while the server drains.

## When not to do this

A three-route service does not need seven files. This layout starts paying when
a second person reads the code, or a second executable shares it.

The plain shape is [`crud.md`](crud.md): one file, six routes, nothing wrong
with it.
