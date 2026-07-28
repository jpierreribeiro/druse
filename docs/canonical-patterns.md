# Canonical API Patterns

This document is **normative**. For every common task there is exactly one
recommended form. Documentation, examples, tests, and generated code use only
these forms. If a pattern here conflicts with any other document except
`knowledge-base/01-architecture-spec.md`, this document wins.

> Status: Phase-1 canonical forms, ratified and implemented.
>
> Every Phase-1 form below works today against the real `web` package on the
> pinned toolchain: routing, extractors, JSON bodies, responses, the error
> envelopes, in-memory testing, and a real HTTP server.
>
> Sections marked **Phase 2**, **Phase 3** or **Phase 4** are design targets.
> They are NOT available today and their code blocks are marked accordingly —
> do not copy them.
>
> Still ahead: graceful shutdown with a deadline (Phase 4). Typed application
> state (WP37) and configurable limits (WP36) shipped in Phase 3; **read and
> write timeouts did not**, because the vendored server then had no deadline to
> configure — the read deadline arrived in Phase 4 (`max_request_time`, WP46)
> and the write/idle deadlines in Phase 7 (`max_write_time`/`max_idle_time`,
> WP90). Request-scoped state is not ahead either and never will be, because
> ADR-028 decided against it, and panic recovery never will be: Odin has no recoverable
> panic, a faulting handler aborts the process, and ADR-020 records why.

## The one rule

**One important concept has one canonical name and one canonical form of use.**

There is no `decode_json` / `parse_body` / `extract_json` / `bind` — only
`web.body`. There is no `respond(ctx, 200, value)` — only the explicit
helpers below.

## Request data lifetime (copy to persist)

Request-derived strings, slices, headers, query values, params and body are
**temporary views** over storage owned by the transport for the duration of
one request. They are valid only during that request.

**To keep any of it, copy it explicitly with an appropriate allocator.**
Background work must receive owned application data — never a captured `ctx`
and never a request view.

The reused buffer does not fail loudly; the view silently starts reading
different bytes — same length, still live memory, different contents. This is
test-pinned (WP2): a path view that read `"/users"` reads `"######"` after the
transport reused its buffer, while a copy taken beforehand still reads
`"/users"`.

The canonical form is an explicit clone with an explicit allocator, taken
BEFORE the request ends:

<!-- fragment: phase1/copy-to-persist -->
```odin
import "core:slice"
import "core:strings"

handler :: proc(ctx: ^web.Context) {
	// Views — valid only for this request.
	path := ctx.request.path
	body := ctx.request.body

	// Copies — owned by the caller, valid afterwards. Free them.
	saved_path := strings.clone(path, context.allocator)
	saved_body := slice.clone(body, context.allocator)
	defer delete(saved_path)
	defer delete(saved_body)

	web.no_content(ctx)
}
```

Never hand `ctx`, a `Request`, or any view to background work: give it the
owned copies instead.

Applications do not reach a response object. There is no `ctx.response` — you
respond through `web.json`, `web.ok`, `web.created`, `web.text`,
`web.no_content` and the error helpers, and the framework guarantees those
supported paths do not overwrite a response that was already produced.

That guarantee covers the supported paths. It is not a security boundary: the
application and the framework share one program, and code that deliberately
reaches into framework internals bypasses it (ADR-008, "Scope of the
guarantee").

## Who owns what (the ownership table)

Phase 2 handed you five new borrowed things, and "copy it if it must outlive
the request" was spread across a dozen comments. This is the single canonical
answer. Every row answers the same four questions.

| Value | Owner | Valid until | May it escape? | Who cleans up |
|---|---|---|---|---|
| route pattern (`web.route(ctx)`) | App | `web.destroy(&app)` | only as a documented view, and only while the App lives | App |
| `ctx.request.path` / `query` / `body` | transport | end of the request | **no** — copy first | transport |
| inbound header name and value (`web.header`) | transport | end of the request | **no** — copy first | transport |
| `web.bearer_token` result | transport | end of the request | **no** — copy first | transport |
| path / query parameter (`web.path`, `web.query`) | request storage | end of the request | **no** — copy first | driver |
| decoded JSON body (`web.body`) | request arena | end of the request | **no** — copy first | driver |
| effective request ID (`web.header(ctx, "X-Request-Id")`) | Context | end of the request | **no** — copy first | driver |
| `web.Framework_Event` (and every field but `route`) | the value itself | unbounded | **yes**, it is a value | nobody |
| `Framework_Event.route` | App | `web.destroy(&app)` | only while the App lives | App |
| middleware list and chain pool | App | `web.destroy(&app)` | **no** | App |
| `web.Router` after `web.mount` | App (routes were copied) | `web.destroy(&app)` | **no** | App |
| application state (`web.state`) | **you** | as long as you keep the value alive | it is yours; the App only borrows it | **you** — the framework allocated nothing |
| `web.Recorded_Response` (`status`, `body`) | the recorder | until the next `test_request` | copy to keep | App teardown |

Read the table as one rule: **only `Framework_Event` may escape a request.**
Everything else is a view, and a view outlives nothing — with one named
exception, twice over: the route pattern, whether it reaches you through
`web.route(ctx)` or through `Framework_Event.route`, is App-owned and stays
valid until `web.destroy`. It outlives the request and it does not outlive the
application.

## An App and a Router are never copied

Treat `web.App` and `web.Router` exactly as you treat a `strings.Builder`: they
own storage, so you pass `&app`, never `app`.

<!-- pseudocode: pass the App by pointer, never by value -->
```odin
app := web.app()
defer web.destroy(&app)

configure(&app)          // correct
// configure(app)        // WRONG: a copy that registers into nothing
```

A copy shares the original's dynamic arrays. Registering on the copy grows a
table the original will never see, and destroying both is a double free. There
is no copy constructor to protect you — this is Odin, and the compiler will let
you do it.

The **zero value is not a usable App.** `app := web.App{}` gives you no default
responses and no initialised storage; `web.app()` and `web.bare()` are the two
constructors, and there are no others.

## Exactly one server per process

`web.serve` is blocking, and the transport keeps per-process state. Running two
servers in one process is **not supported**: they cross-wire dispatch. One
process, one `web.serve`.

There is also no stop procedure. `web.serve` returns when the process ends.
Graceful shutdown with a deadline is Phase 4, and it will add public API — so
today, run under a supervisor that can restart the process, and do not build a
control plane that assumes it can stop the server from inside.

## Reading the request

<!-- pseudocode: the request field list -->
```odin
handler :: proc(ctx: ^web.Context) {
	if ctx.request.method == .GET {   // UPPERCASE: .GET, never .Get
		web.ok(ctx, ctx.request.path)
		return
	}

	web.no_content(ctx)
}
```

`ctx.request` is the only public request surface in Phase 1:

| Field | Type | Notes |
|---|---|---|
| `method` | `web.Method` | `.UNKNOWN`, `.GET`, `.POST`, `.PUT`, `.PATCH`, `.DELETE` |
| `path` | `string` | view |
| `query` | `string` | view, raw and unparsed — use the query extractors |
| `headers` | `web.Header_View` | no lookup in Phase 1 |
| `body` | `[]u8` | view |

`Method` members are UPPERCASE. `.GET` is the canonical spelling; `.Get` does
not compile.

Any method token outside that set — `"HEAD"`, `"OPTIONS"`, `"PROPFIND"`, or a
lowercase `"get"`, since methods are case-sensitive — arrives as `.UNKNOWN`.
`.UNKNOWN` is not an error and produces no response by itself.

`Header_View` is **encapsulated by contract**, not opaque: Odin offers no
opacity, and it promises nothing about its representation. **There is no
header lookup in Phase 1** — `web.header(ctx, name)` is Phase 2. Do not invent
a substitute by reaching into the view.

## Application skeleton

<!-- fragment: phase1/app-lifecycle -->
```odin
package main

import web "uruquim:web"

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	web.get(&app, "/health", health)
	web.get(&app, "/users/:id", get_user)
	web.post(&app, "/users", create_user)

	web.serve(&app, 8080)
}
```

- `web.app()` — progressive production defaults. Delivered so far: a
  standardized 404 and a minimal 405 with the `Allow` header (WP4), and the
  fixed 4 MiB request-body cap (WP7). Still to come: configurable limits,
  read/write timeouts, and optimized 405/header handling (Phase 3); graceful
  shutdown hardening (Phase 4). Note what is NOT and never will be on that
  list: a recovery default (ADR-020). A handler that commits no response is
  finalized to the standardized 500 under BOTH `web.app()` and `web.bare()` —
  that is a driver guarantee, not a default — while a handler that *faults*
  aborts the process.
- `web.bare()` — no defaults (advanced; not for quick starts). It routes
  exactly like `web.app()` but installs neither the 404 nor the 405, so an
  unmatched request produces no response at all.
- `web.serve(&app, port)` — the canonical and only entry point. It validates
  the port, binds dual-stack (IPv6 `::` when the host has IPv6, serving IPv4
  clients too; IPv4 Any otherwise), and blocks while the server runs. Host
  selection and other options are a later phase.

`App` owns resources and is non-copyable by contract. Keep the value returned
by `web.app()`, pass its address, and destroy that same value exactly once.
Do not copy an `App` or destroy a copy.

## Routing

One canonical registration form per method — `web.get`, `web.post`, `web.put`,
`web.patch`, `web.delete` — taking the app, a pattern, and a handler:

<!-- fragment: phase1/routing -->
```odin
web.get(&app, "/users", list_users)       // static
web.get(&app, "/users/:id", get_user)     // one :param segment
```

A pattern begins with `/`. A `:param` occupies exactly one whole segment, must
be named, and a pattern may declare **up to eight** of them (WP33 raised the
Phase-1 bound of one). There is no wildcard.

A pattern outside that grammar — a ninth `:param`, a bare `/users/:`, or one
without a leading `/` — **never matches any request**, and never contributes to
an `Allow` header either. Registration accepts it silently and reports nothing,
so check your patterns: a route that is never reached looks exactly like a 404.

When a static and a parametric route both match, **the static one always
wins**, independently of registration order:

<!-- pseudocode: pattern grammar -->
```odin
web.get(&app, "/users/:id", get_user)
web.get(&app, "/users/me", get_current_user)   // /users/me reaches THIS one
```

Methods are isolated: registering GET on a path does not register any other
method on it.

**Paths are not normalized, and the policy is now decided (WP31).** `/users`
and `/users/` are different, and percent-encoding is never decoded or rewritten.
The policy REJECTS rather than transforms: a dot segment, an interior empty
segment, a percent-encoded slash or a percent-encoded NUL is answered `400`
before route matching. Everything else passes through byte-exact.

**Registration conflicts are diagnosed (WP30).** Registering two routes for the
same method and the same path shape rejects the application fail-closed: every
request answers 500 and `web.serve` refuses to start, with a diagnostic naming
the losing route. Parameter names do not distinguish routes — `/users/:id` and
`/users/:uid` are one pattern — and a `web.mount` prefix can compose a
collision with a route registered directly. There is still no registration
error to handle and no such API: registration reports through the fail-closed
mechanism, not a return value. A pattern the dispatcher cannot interpret is a
different case and simply never wins a match.

The pattern string is copied: the App owns its copy, so the caller may reuse or
free its own buffer immediately after registering.

`web.app()` answers an unmatched request automatically:

```text
unknown path                     → 404
path registered on another method → 405 + Allow
```

`Allow` names only the methods registered for that path, always in the order
`GET, POST, PUT, PATCH, DELETE`, comma-and-space separated, never duplicated.

**`HEAD` and `OPTIONS` are served but never listed.** On a route registered only
for GET, `HEAD` answers 200 with an empty body and `OPTIONS` answers 204 with
`Allow: GET` — three methods supported, one advertised. RFC 9110 §10.2.1 says
`Allow` is the set of methods the resource *supports*, so this is a known
deviation held in place on purpose: the five-verb order is frozen (WP32b) and
the router corpus refuses an `Allow` containing HEAD or OPTIONS, after an
earlier attempt to add them was rejected as importing another router's
conventions. Do not read `Allow` as a capability probe for those two methods.
Phase 1 exposes no way to read response headers, so it is verified internally.
Both bodies are empty until WP6 renders the error envelope.

A method token outside the `Method` set arrives as `.UNKNOWN` and follows the
same 404/405 rules; it never becomes a 501.

## Route identity (delivered in Phase 3, WP34)

**The canonical way to label telemetry by route is `web.route(ctx)`. The
canonical way is never `ctx.request.path`.**

<!-- fragment: phase3/route-identity -->
```odin
by_route :: proc(ctx: ^web.Context) {
	// "/users/:id" — never "/users/42". `record_hit` is YOUR code.
	record_hit(web.route(ctx))
	web.next(ctx)
}
```

`web.route` returns the **registered pattern** the request matched. That is the
whole distinction and it is a correctness rule, not a style one: route identity
must be low-cardinality, so a metric labelled with the path has one time series
per user id, and a log field labelled with the path carries user data into
wherever those logs go.

- a mounted route reports the **composed** pattern — `/api/users/:id`;
- a `404` and a `405` report `""`, because no route ran. Treat it as the
  "unmatched" bucket rather than substituting the path;
- the result is a view over **App-owned** storage, valid until `destroy`. It is
  the single value reachable from a `^Context` that outlives its request;
  everything else in the ownership table is request-scoped;
- it is the same string `web.Framework_Event.route` carries. One question, one
  name (G-01) — the accessor is not called `route_pattern` or `matched_route`
  precisely so nobody has to be told they are the same value.

## Handler

<!-- fragment: phase1/readme-taste -->
```odin
Health :: struct {
	status: string `json:"status"`,
}

health :: proc(ctx: ^web.Context) {
	web.ok(ctx, Health{status = "ok"})
}
```

Handlers take `^web.Context` and return nothing. They respond via helpers.
Payloads are typed structs — there is no untyped object literal.

The missing return value is deliberate: Uruquim does not use Echo-style
generic error propagation. Odin allows returned results to be ignored, and a
result would make the canonical extractor `return` more ceremonial. Internal
framework failures still pass through one private typed path for consistent
logging, public error formatting, and single-commit protection. Keep domain
errors in the application and map them explicitly at the HTTP boundary.

## Extractor pattern (the load-bearing pattern)

Extractors respond on failure themselves. The handler checks the boolean and
returns — nothing else. There are exactly two shapes:

<!-- fragment: phase1/path-int -->
```odin
// 1. Value-producing extractor: (value, ok)
id, ok := web.path_int(ctx, "id")
if !ok {
	return
}

// 2. Destination-filling extractor: bool
input: Create_User
if !web.body(ctx, &input) {
	return
}
```

Full handler:

<!-- fragment: phase1/body -->
```odin
get_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}

	user, found := users.find(id) // returns a User value
	if !found {
		web.not_found(ctx, "user not found")
		return
	}

	web.ok(ctx, user)
}
```

Failure of `path_int` automatically produces:

```json
{
  "error": {
    "code": "invalid_path_parameter",
    "message": "Path parameter 'id' must be an integer",
    "field": "id"
  }
}
```

Do NOT write `or_else { ... }` blocks — that is not valid Odin. Do NOT write
manual status/JSON assembly for extractor failures — the extractor already
responded.

## JSON body binding

`web.body` fills a caller-owned destination and returns `bool`:

<!-- fragment: phase1/body -->
```odin
Create_User :: struct {
	name:  string `json:"name"`,
	email: string `json:"email"`,
}

create_user :: proc(ctx: ^web.Context) {
	input: Create_User
	if !web.body(ctx, &input) {
		return
	}

	user, err := insert_user(input)
	if err != nil {
		web.internal_error(ctx)
		return
	}

	web.created(ctx, user)
}
```

Malformed or incomplete JSON produces `invalid_json` (400). A value that does
not fit its declared type produces `invalid_field` with a stable dot-separated
path; an undeclared key produces `unknown_field`. A body over the configured
cap produces `body_too_large` (413). In every case `web.body` has already
responded — just `return`.

WP7 rules you must not guess at:

- **The default is one bind per request.** `web.body` is a single-use
  capability: the first call consumes it, even if it fails. A second call
  decodes nothing. Bind once, into one destination.
- **Decoded data is request-lifetime.** Nested strings and slices live in a
  per-request arena and are freed when the request ends. Copy explicitly (with
  an appropriate allocator) to keep any of it — the same rule as every request
  view. After a `false` return, `dst` is undefined; discard it.
- **Values only.** The destination is a concrete struct; the payload decodes by
  value, matching the response side (`web.ok(ctx, value)`).
- **Strict JSON.** Comments, unquoted keys and single-quoted strings are
  rejected, trailing tokens are rejected, and undeclared object keys are not
  ignored. Do not rely on JSON5 or permissive field skipping.
- **Four input states are distinct design concerns.** A field may be missing,
  present with its zero value, present as JSON `null`, or present with a
  non-null value. WP68 does not infer requiredness from zero and does not add a
  generic patch wrapper; explicit requiredness/validation is owned by WP81.

## Query parameters

Three canonical procedures, explicit per-type names:

<!-- fragment: phase1/query -->
```odin
// Plain text lookup — no automatic error response.
search, found := web.query(ctx, "search")

// Required int — missing or malformed responds 400 and returns ok = false.
page, ok := web.query_int(ctx, "page")
if !ok {
	return
}

// Optional int with default — default applies ONLY when absent;
// a malformed value is still a 400.
limit, ok := web.query_int_or(ctx, "limit", 20)
if !ok {
	return
}
```

```text
GET /users              → limit = 20
GET /users?limit=50     → limit = 50
GET /users?limit=banana → 400 invalid_query_parameter
GET /users?limit=       → 400 invalid_query_parameter
```

The last line is the one that surprises people. Presence is decided by the
KEY, not by whether the value is usable, so `?limit=` is PRESENT with an empty
value — and an empty value is not an integer. The default applies only when
the key is absent entirely. `query_int_or` never substitutes the default for a
value the caller actually sent.

Future typed variants follow the same pattern: `query_<type>` /
`query_<type>_or`.

### What the query extractors do NOT do (WP5)

These are deliberate omissions, not oversights. Do not write code that assumes
otherwise:

- **No decoding.** `?q=a%20b+c` yields the literal `a%20b+c`. There is no
  percent-decoding and `+` does not become a space. Decode in the application
  if you need it.
- **No normalization.** Keys and values are compared and returned byte for
  byte, case-sensitively.
- **No duplicate-key contract.** When a key repeats, the first occurrence
  wins. That is a minimal internal rule so the scan is deterministic; it is not
  a promise about multi-value parameters.
- **Strict decimal integers.** An optional `-` then ASCII digits. `+5`,
  `0x10`, `1_000`, `1.5` and surrounding whitespace are all 400s.

`web.query` returns a VIEW over `ctx.request.query`, exactly like every other
request-derived string. Copy it explicitly to keep it (see Request data
lifetime above).

## Responses

| Intent | Canonical call |
|---|---|
| 200 + JSON | `web.ok(ctx, payload)` |
| 201 + JSON | `web.created(ctx, payload)` |
| 204 | `web.no_content(ctx)` |
| other status + JSON | `web.json(ctx, status, payload)` |
| plain text | `web.text(ctx, status, s)` |
| raw bytes — Phase 3, unavailable | `web.bytes(...)` |
| redirect — Phase 3, unavailable | `web.redirect(...)` |
| 400 | `web.bad_request(ctx, msg)` |
| 401 | `web.unauthorized(ctx, msg)` |
| 403 | `web.forbidden(ctx, msg)` |
| 404 | `web.not_found(ctx, resource)` |
| 409 — Phase 3, unavailable | `web.conflict(...)` |
| 500 | `web.internal_error(ctx)` |

`web.ok` is exactly `web.json(ctx, .OK, value)` and `web.created` is exactly
`web.json(ctx, .Created, value)` — tiny shorthands, no extra behavior.

Phase-1 JSON payloads are concrete values:

<!-- fragment: phase1/responses -->
```odin
user: User = load_user()
web.ok(ctx, user)       // accepted: User value
```

Do not pass `&user`, and do not pass a variable whose type is `^User`.
Pointers are unsupported by the Phase-1 baseline because the pinned official
JSON marshaller rejects them. A WP6 disposable prototype confirmed one-level
dereference compiles and marshals a `^User`, but pointer support was NOT
adopted — the value-only baseline stands until the specification is amended.

If marshalling rejects a payload, the renderer logs the failure on the server
before returning one complete standardized `internal_error`, while the response
is still uncommitted. It never returns a silent 500 or a partial body.

`web.json`/`web.ok`/`web.created` set `Content-Type: application/json`;
`web.text` sets `text/plain; charset=utf-8`; `web.no_content` sets none. There
is no public way to set a response header in Phase 1.

## Limits (delivered in Phase 3, WP36)

**Start from `web.DEFAULT_LIMITS` and change what you mean to change.**

<!-- fragment: phase3/limits -->
```odin
budget := web.DEFAULT_LIMITS
budget.max_body = 64 * 1024
web.limits(&app, budget)
```

Never build a `Limits` from scratch: a zero field is **rejected**, because the
struct has no unset state to tell a forgotten field from a deliberate one, and
an application running on a silent mix of its values and the framework's would
be worse than one that refuses to start.

| Field | Default | Enforced by |
|---|---|---|
| `max_body` | 4 MiB | the shared request path — exactly the limit is accepted, one byte more is `413` |
| `max_request_line` | 8000 | the backend, before the core sees the request |
| `max_headers` | 8000 | the backend, before the core sees the request |
| `max_request_time` | 30 s (nanoseconds) | a periodic sweep on the serving loop — the connection is closed when one request takes longer than this to ARRIVE |
| `max_connections` | 1024 | the accept path — a connection past the budget is closed, not queued |
| `reserved_conns` | 16 | slots held back from admission so a shutdown always has room; admission stops **at or below** `max_connections - reserved_conns`, never at zero |
| `max_handlers` | `0` = auto | maximum concurrent synchronous Handlers; auto is CPU count clamped to 4..32, `1` is compatibility mode, explicit values stop at 256 |

- the budget belongs to the **App**, not to `web.serve`, so `web.test_request`
  enforces the same numbers as a socket. A 413 in a test is a 413 in production;
- `web.limits` **after the first request** rejects the application fail-closed:
  the budget is read on the request path, and changing it mid-flight would give
  two clients different answers to the same body. Order relative to routes does
  not matter — a limit protects every route equally;
- `DEFAULT_LIMITS` is a **constant**, so no library can change another's
  defaults;
- **`max_request_time` is a REQUEST deadline, not an idle timeout**, and the
  difference is the whole defence: an idle timer is reset by every byte, so a
  client trickling one byte per second resets it forever. This bounds the total
  time a request may take to arrive. The idle gap between keep-alive requests
  has its own bound, `max_idle_time`, and the response send has
  `max_write_time` (both WP90 / ADR-039, both `0` = off by default). It does
  **not** bound a slow handler —
  that is your program's own time, and killing its connection would turn a slow
  page into a broken one. Set it to `0` to ask for the old unbounded behaviour
  explicitly;
- **there is still no WRITE deadline**, and no field for one. Do not write
  `web.Limits{write_timeout = ...}`.
- Handlers run concurrently by default. Protect mutable `App_State` with a
  lock/atomics or put it behind a thread-safe service. Set `max_handlers = 1`
  only when intentional single-Handler compatibility is the desired contract.

`Limits` bounds Uruquim's **own per-request working memory**. It does not bound
connections, accept backlog, inbound header count or process memory — those are
the transport's and the operating system's, and no document may say the
framework is "bounded" because this type exists.

## Application state (delivered in Phase 3, WP37)

**One value, app-scoped, created before serving.** A database pool, a
configuration struct, a template cache — the things a service creates once and
needs everywhere.

<!-- pseudocode: the App_State shape and its lifetime -->
```odin
App_State :: struct {
	db:     ^postgres.Pool,
	config: Config,
}

main :: proc() {
	// The state and the App are BOTH locals of main. That layout is the
	// lifetime rule: the value must outlive the App.
	state := App_State{db = db, config = config}
	app := web.app_with_state(&state)
	defer web.destroy(&app)

	register_routes(&app)
	web.serve(&app, 8080)
}
```

`web.app_with_state` is `web.app()` with a value attached: the same automatic
404 and 405, the same everything else. **A nil pointer rejects the application
fail-closed** — every request answers 500 and `web.serve` refuses to start —
because an App that accepted nil would abort inside the first request instead.

The App stores the **pointer**, never a copy. A handler writing through it
mutates your value, which is what makes a connection pool work.

<!-- pseudocode: reading the state inside a handler -->
```odin
list_users :: proc(ctx: ^web.Context) {
	state := web.state(ctx, App_State)

	users, err := user_repository.list(state.db)
	if err != nil {
		web.internal_error(ctx)
		return
	}

	web.ok(ctx, users)
}
```

`web.state(ctx, T)` asserts that state was registered **and** that `T` is
exactly the registered type, then returns `^T`. Both are programming errors and
neither varies with the request, so a failing assert aborts on your first
request rather than in front of a client (ADR-020: run under a supervisor).
Exact type, not assignable type: there is no subtyping walk, and casting a
`^Config` to a `^Database` because both are pointers is what the check exists
to make impossible.

**There is no request-scoped state, and there is not going to be one**
(ADR-028). `ctx` is not an extension bag (G-03). A value one middleware
computes for a handler is passed down by calling a procedure, or recomputed —
including the auth pattern's `current_user`, whose revalidation cost is
permanent until an ADR decides otherwise.

## Middleware (delivered in Phase 2, WP17)

**Every `web.use` comes before the first route, and this is enforced**: `use`
after any registration — or after the first dispatched request — rejects the
whole application fail-closed (every request answers `500`, `web.serve`
refuses to start, a diagnostic names the unprotectable pattern). Ordering is a
security boundary: the mis-ordered program the prototype measured served a
protected route to an unauthenticated caller with a healthy `200`.

Attach, one middleware per call, in the order they should run:

<!-- fragment: phase2/middleware-use -->
```odin
web.use(&app, require_auth) // before any route — the order is enforced
web.get(&app, "/admin/users", list_users)
```

Write — an ordinary handler; allow by calling `web.next`, reject by responding
and returning without it:

<!-- fragment: phase2/bearer-auth -->
```odin
require_auth :: proc(ctx: ^web.Context) {
	token, ok := web.bearer_token(ctx)
	if !ok || !token_is_valid(token) {
		web.unauthorized(ctx, "authentication required")
		return
	}
	web.next(ctx)
}
```

(`web.bearer_token` is a later Phase-2 work package; until it lands, examples
carry the credential in a query parameter.)

Chains unwind in reverse order; code after `next` runs when the response is
already committed — read there, never write. A second `next()` is a no-op.
Middleware also observe the automatic `404`/`405`. Full contract:
`docs/middleware.md`.

Middleware gates requests, logs, and sets response metadata. It does NOT hand
values to handlers — there is no `ctx.user_data`, no `locals`, no
`map[string]any`, by design. Recovery middleware does not exist and never
will (ADR-020): Odin has no recoverable panic. CORS is a Phase-4 built-in.

## Auth / dependencies (delivered in Phase 2, WP19)

`web.bearer_token` parses the `Authorization` header against RFC 6750
STRICTLY — scheme case-insensitive, exactly one space, non-empty token, no
whitespace tolerance — and returns the token verbatim, never trimmed or
normalised. It is a PURE lookup: `(value, ok)`, no automatic response,
nothing logged. The `auth.*` calls below are your application's code.

When the handler needs the user, call a typed extraction procedure directly
(same contract as extractors) — no middleware involved:

<!-- pseudocode: auth.find_user_by_token / auth.token_is_valid are application code -->
```odin
current_user :: proc(ctx: ^web.Context) -> (^User, bool) {
	token, found := web.bearer_token(ctx)
	if !found {
		web.unauthorized(ctx, "missing bearer token")
		return nil, false
	}

	user, ok := auth.find_user_by_token(token)
	if !ok {
		web.unauthorized(ctx, "invalid bearer token")
		return nil, false
	}

	return user, true
}

get_profile :: proc(ctx: ^web.Context) {
	user, ok := current_user(ctx)
	if !ok {
		return
	}

	web.ok(ctx, user^) // explicit value; `user` itself is ^User
}
```

Use `require_auth` middleware only for routes that must be authenticated but
do not need the user value (typically whole groups):

<!-- phase: 2; unavailable -->
```odin
admin := web.group(&app, "/admin")
web.use(&admin, require_auth)
```

Do not stack both on the same route — that duplicates validation. Pick the
extractor when you need the user, the gate when you don't.

## Route organisation (delivered in Phase 2, WP18)

A `Router` is built exactly like an application — the SAME `use` and the same
five verbs accept `&router` — and then attached with `mount`. Explicit router
values; no configuration callbacks. `web.group` stays unavailable forever
(rejected for every future phase, ADR-024): once a Router can be mounted at
a prefix, `group` would be a second canonical way to do one operation.

<!-- fragment: phase2/router-mount -->
```odin
api := web.router()
defer web.destroy(&api)
web.use(&api, require_auth)
web.get(&api, "/users", list_users)

web.mount(&app, "/api", &api)
```

Rules, each enforced fail-closed (a violation answers `500` everywhere and
`web.serve` refuses to start):

- every `use(&router, …)` before the router's first route (ADR-019, inside
  the Router too);
- everything registered before `mount` — mount COPIES and then CLOSES the
  router; a later registration on it, or a second mount, is rejected loudly,
  never dropped silently;
- the prefix must begin with `/` and must not end with `/`; the mounted
  pattern is prefix + pattern VERBATIM — nothing is normalised, so a router
  `"/"` mounted at `"/api"` serves `"/api/"`, not `"/api"`.

Two owners: destroy the app AND each router, exactly once, in either order.
Chain order is app globals, then each enclosing router outermost-first, then
the handler. A route that needs its own guard is a ONE-ROUTE Router mounted
at the path (ADR-025, option B).

## Testing

<!-- fragment: phase1/test-request -->
```odin
res := web.test_request(&app, .GET, "/users/42")
testing.expect(t, res.status == .OK)
testing.expect_value(t, res.body, `{"id":42}`)
```

`web.test_request(a: ^App, method: Method, path: string) -> Recorded_Response`
drives one request through the framework IN-MEMORY: no socket, no port, no
network syscall. `Recorded_Response` has exactly two fields:

<!-- fragment: phase1/test-request -->
```odin
res.status  // web.Status — copied by value
res.body    // string — a view over a copy the App owns
```

Lifetime: every response `test_request` returns stays readable — alongside all
the others from the same App — until `web.destroy(&app)`, which frees them. There
is no per-response cleanup, and there is no public `headers` field.

Routing is wired (WP4), so `test_request` returns real routed results: a
registered handler runs, an unknown path gives 404, and a path registered under
another method gives 405 with an `Allow` header. Because no response helper
works until WP6, a handler cannot produce a body — a matched route therefore
reports a zero status and an empty body, which is the honest report of an
uncommitted response, not a fabricated 200. The 404 and 405 bodies are also
empty until WP6 defines the error envelope. The machinery lives in
`web/testing/` and is not meant to be imported directly.
