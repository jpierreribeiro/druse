# Uruquim — Architecture Specification

## Purpose

This document defines the architecture of Uruquim, a high-performance HTTP
microframework for Odin.

Uruquim borrows the ergonomics *goals* of Gin/FastAPI-class frameworks while
rejecting the implementation assumptions that come from garbage-collected
runtimes, reflection-rich type systems, and object-oriented design. It is
designed to be idiomatic for Odin:

- procedural API style
- explicit data and state
- allocator-aware internals
- transport decoupling
- DOD-first design
- low-allocation hot paths
- no hidden OOP simulation

This document is normative.

## Central Architectural Statement

> Internally data-oriented and allocator-aware; externally simple, productive,
> and predictable.

**Simple by default, explicit when needed, data-oriented underneath.**

The framework SHALL hide allocator, router, transport, and response machinery
from ordinary handlers. A user must be able to implement a typed JSON API using
only `app`, route registration, extractors, response helpers, and `serve`.

The overall structure is deliberately small:

```text
Application
   ↓
Canonical API
   ↓
Router + Context + Middleware
   ↓
core:net/http (via internal boundary)
```

There is no code generator, no mandatory CLI, and no heavy metaprogramming.
Ergonomics come from extractors and canonical helpers, not from tooling.

Tagline: *a web framework for the Joy of Programming.*

## Three Equal Commitments

The architecture is governed by three commitments of equal weight:

1. **Performance** — memory correctness and a predictable hot path.
2. **Productivity** — safe defaults, simple CRUD, few mandatory concepts.
3. **AI readability** — canonical API, compiling examples, no aliases, no magic.

Any design decision that maximizes one commitment by materially damaging
another is invalid.

## Productivity as a First-Class Architectural Requirement

The framework SHALL optimize not only for runtime performance, but also for
implementation correctness, discoverability, and low cognitive overhead.

The default application path SHALL:

- require no explicit allocator configuration
- require no explicit transport selection
- provide production-oriented defaults
- expose canonical helpers for common HTTP operations
- allow a functional JSON API to be written with minimal framework knowledge

Advanced memory and transport configuration SHALL remain available through a
separate explicit API.

The framework SHALL provide two usage levels:

1. **Productive API** — default and documented first.
2. **Advanced API** — explicit control over allocators, transport, state, and
   lifecycle.

The acceptance metric for the public API is:

> A basic AI coding agent, after reading three examples, can produce a correct
> CRUD API without inventing abstractions.

The ordinary user SHALL NOT need to understand any of the following to ship a
working API: allocators, transport callbacks, buffer ownership, adapter
internals, manual `Context` assembly, response writer construction, or router
initialization. These concerns exist — internally.

## Canonical Transport Direction

The future Odin `core:net/http` package (announced as built on `core:nbio`)
SHALL be treated as the canonical transport backend.

Before it is available or stable, the framework MAY use `laytan/odin-http`
behind an internal adapter.

No public framework API SHALL expose `odin-http` types.

Migration to `core:net/http` SHALL NOT require application-level handler or
routing changes.

The internal boundary is:

```text
Framework Core
    └── Internal HTTP Boundary
            ├── core:net/http adapter — canonical (when available)
            ├── odin-http adapter — bootstrap/compatibility
            └── test transport — in-memory, no sockets
```

Consequences:

1. Development MAY begin on `odin-http`.
2. The public API MUST NEVER depend on its types.
3. When `core:net/http` ships, an official adapter is created.
4. Once the official adapter is stable, the `odin-http` adapter MAY be removed
   or moved to a separate package.
5. The framework SHALL NOT reimplement full HTTP parsing without necessity.

The transport boundary is an **internal** architecture concern. It SHALL NOT
appear in the Quick Start or in ordinary application code. Ordinary usage is:

```odin
web.serve(&app, 8080)
```

Internally, transport selection is resolved by the framework:

```odin
@(private)
default_transport :: proc() -> Transport {
	when ODIN_HAS_CORE_HTTP {
		return core_http_transport()
	} else {
		return odin_http_transport()
	}
}
```

Advanced users MAY inject a transport explicitly:

```odin
web.serve_transport(&app, &custom_transport, web.Serve_Config{port = 8080})
```

This appears only in advanced documentation, never in the Quick Start. It shares
the reserved `Serve_Config` shape described under *Serving* (ADR-045): a
structured address with an explicit family, no `host: string`.

## Public API Surface

### The five concepts

The entire ordinary public API is built from five concepts:

```text
app        create/destroy the application
route      register handlers on methods and paths
extract    read typed values out of the request
respond    write typed responses
serve      run the server
```

### Application

```odin
app := web.app()            // production-oriented defaults
defer web.destroy(&app)

app := web.bare()           // no default middleware or policies (advanced)

app := web.app_with_state(&state)   // app() + registered typed app state
```

`web.app()` returns `App` by value and is the canonical Productive API. After
the return, all mutating operations take `^App` pointing at the caller's
storage. The implementation SHALL NOT retain a self-pointer captured inside
`app()` before it returns. `App` owns its allocations and is non-copyable by
contract after initialization: copied values SHALL NOT be independently
destroyed. `web.destroy` is called exactly once for the original caller-owned
value. The future Advanced API MAY additionally expose `app_init(&app)`.

`web.app()` SHALL be appropriate for moderate production use, not only demos.
It SHALL configure by default:

- panic recovery
- request body size limit
- read timeout
- write timeout
- header count/size limits
- consistent 404 and 405 handling
- rejection of malformed requests
- startup logging
- graceful shutdown

This list is the end-state default-policy contract. Delivery is progressive:

- Phase 1: fixed 4 MiB buffered request-body cap, consistent 404, and minimal
  405 with an `Allow` header containing the registered methods for the path
- Phase 2: panic recovery
- Phase 3: read/write timeouts, configurable body limits, header limits, and
  the optimized router implementation of the already-frozen 405 behavior
- Phase 4: robust graceful shutdown for in-flight requests and the remaining
  production hardening

A build SHALL document which phase it implements and SHALL NOT claim defaults
scheduled for a later phase.

`web.bare()` creates an application with none of the default middleware or
policies, for users who want full control.

### Routing

```odin
web.get(&app, "/users/:id", get_user)
web.post(&app, "/users", create_user)
web.put(&app, "/users/:id", update_user)
web.patch(&app, "/users/:id", patch_user)
web.delete(&app, "/users/:id", delete_user)
```

Route groups use explicit router values, not configuration callbacks
(callbacks complicate lifetimes and produce less predictable code for AI):

```odin
api := web.router("/api")

web.get(&api, "/users", list_users)
web.post(&api, "/users", create_user)

admin := web.group(&api, "/admin", require_admin)
web.get(&admin, "/stats", stats)

web.mount(&app, &api)
```

### Handlers

```odin
Handler :: proc(ctx: ^web.Context)
```

One signature for handlers and middleware. Handlers write to the context via
response helpers and do not return values in v1. This is a deliberate Odin
decision, not an accidental omission of an Echo-style `error` result.

Experiment 10 proved that Odin permits a caller to silently discard a returned
`Handler_Error` or `Handler_Outcome`. It also proved that an unnamed result
breaks the canonical extractor flow `if !ok { return }`. A returned error would
therefore add ceremony without providing the safety property expected from it.

Framework-detected failures SHALL enter one private, typed error-report path
before formatting, server-side logging, and response commit. If the response is
already committed, the failure is logged/observed but SHALL NOT produce a
second write. Application-domain errors remain application types and are
mapped explicitly at the HTTP boundary; the framework SHALL NOT transport
arbitrary errors through `any`.

A typed error observer/policy is Phase-2 scope. A result-returning handler may
only be reconsidered as a separately gated breaking design after real
application evidence; it SHALL NOT coexist as a second canonical handler.

### Extractors

Extractors read typed values from the request. **On failure, the extractor
writes the standardized error response itself and returns `false`; the
handler only returns.** This is the single most important productivity
mechanism in the framework. Ergonomics come from extractors, not from code
generation.

There are exactly two extractor shapes:

```odin
// 1. Value-producing extractor
id, ok := web.path_int(ctx, "id")
if !ok {
	return
}

// 2. Destination-filling extractor
input: Create_User
if !web.body(ctx, &input) {
	return
}
```

#### Canonical Extractor Control Flow (normative)

Fallible HTTP extractors SHALL return `(value, ok: bool)` without
`#optional_ok`:

```odin
path_int :: proc(ctx: ^Context, name: string) -> (value: int, ok: bool)
```

The missing directive is intentional. On the pinned compiler, discarding the
boolean from a plain two-result procedure is a compile error (`Assignment
count mismatch`), while `#optional_ok` permits silent discard. HTTP extractors
write a response on failure, so forcing the caller to handle `ok` is safer for
humans and coding agents. The canonical call site remains unchanged.

When extraction fails, the extractor SHALL write the complete HTTP error
response before returning `false`.

Handlers SHALL use the following canonical form:

```odin
value, ok := web.extractor(ctx, ...)
if !ok {
	return
}
```

Destination-filling extractors — those that populate a caller-owned value,
such as `web.body` — SHALL take a destination pointer and return only `bool`:

```odin
body :: proc(ctx: ^Context, dst: ^$T) -> bool
```

```odin
input: Create_User
if !web.body(ctx, &input) {
	return
}
```

The destination form keeps ownership and storage explicit, avoids a
parametric-return API, lets the caller choose where the value lives, and
matches traditional parsing/decoding style.

The framework documentation SHALL NOT use statement blocks with `or_else`,
because `or_else` accepts a replacement expression, not a statement block.
This pattern may be amended once, through a spec-first change, only if a
compiling prototype demonstrates a meaningfully clearer and equally
predictable Odin-native alternative.

#### Canonical query extractor family (normative)

```markdown
The canonical query extractor family SHALL be:

- `web.query(ctx, name) -> (string, found)`     — plain lookup, no auto-response
- `web.query_int(ctx, name) -> (int, ok)`       — required; responds on failure
- `web.query_int_or(ctx, name, default) -> (int, ok)` — optional with default

Typed query extractors SHALL use explicit type-specific procedure names.
The MVP SHALL NOT expose a generic `web.query_or(ctx, name, type, default)`
procedure.
```

`query_int_or` semantics: the default applies **only when the parameter is
absent**. A present-but-malformed value is a 400 error, never silently
replaced by the default:

```text
GET /users              → page = 1
GET /users?page=2       → page = 2
GET /users?page=banana  → 400 invalid_query_parameter
```

Future typed variants follow the same naming pattern (`query_bool`,
`query_bool_or`, `query_float`, `query_float_or`): `query_<type>` /
`query_<type>_or`. A weak LLM can infer the family without inventing
`typeid` parameters.

Path extractors follow the same style: `web.path(ctx, name) -> string`
(present whenever the route matched) and `web.path_int(ctx, name) ->
(int, ok)`.

### Response helpers

Explicit helpers, one per output kind. No `respond(ctx, status, any)` style
overload whose behavior depends on `any`.

```odin
web.ok(ctx, payload)          // 200 + JSON
web.created(ctx, payload)     // 201 + JSON
web.no_content(ctx)           // 204

web.json(ctx, status, payload)   // arbitrary status + JSON
web.text(ctx, status, "pong")
web.bytes(ctx, status, content_type, data)
web.redirect(ctx, .Found, "/login")

web.bad_request(ctx, "invalid input")
web.unauthorized(ctx, "authentication required")
web.forbidden(ctx, "insufficient permission")
web.not_found(ctx, "user")
web.conflict(ctx, "email already registered")
web.internal_error(ctx)
```

`ok`/`created` are the canonical form for their statuses, defined as exact,
tiny shorthands:

```odin
ok :: proc(ctx: ^Context, value: $T) {
	json(ctx, .OK, value)
}

created :: proc(ctx: ^Context, value: $T) {
	json(ctx, .Created, value)
}
```

```markdown
`web.ok` SHALL be exactly equivalent to `web.json(ctx, .OK, value)`.

`web.created` SHALL be exactly equivalent to
`web.json(ctx, .Created, value)`.

Convenience response procedures SHALL NOT introduce behavior that differs
from the underlying renderer — no extra serialization, headers, or error
handling.
```

Phase-1 JSON response payloads are passed as values. Canonical examples SHALL
use `web.ok(ctx, value)`, `web.created(ctx, value)`, and
`web.json(ctx, status, value)`, never `&value` and never a variable whose type
is a pointer. The pinned `core:encoding/json` marshaller rejects pointer and
procedure payloads with `Unsupported_Type`.

When serialization fails, the framework SHALL log the marshal error on the
server before producing `internal_error`. Serialization completes before the
response is committed; the error path SHALL emit one fresh standardized 500
response and SHALL NOT leak or reuse a partially rendered/stale payload.

WP6 SHALL contain a non-blocking prototype for dereferencing exactly one
pointer level before marshal. If that implementation is small, explicit, and
compiles cleanly on the pinned toolchain, the pointer restriction MAY be
relaxed through a spec-first amendment. Until then, value-only is normative.

> **WP6 status (implemented).** All response helpers render and commit through
> the internal single-commit guard. Rendered JSON/text bodies are owned by the
> internal response and released by a private teardown the response driver calls
> after capture (ADR-014); no public cleanup exists. `Content-Type` is
> `application/json` for JSON and every envelope, `text/plain; charset=utf-8`
> for text, and unset for `no_content`. The pointer-dereference prototype was
> run and NOT adopted; value-only remains normative.

### Serving

```odin
web.serve(&app, 8080)                              // canonical
web.serve_with(&app, web.Serve_Config{             // RESERVED shape — ADR-045
	address = <structured, explicit family>,       //   never `host: string`
	port    = 8080,
})
web.serve_transport(&app, &transport, config)      // advanced: inject transport
```

`Serve_Config` is a RESERVED shape (ADR-045), not a shipped signature: its
address is STRUCTURED with an explicit address family — never a stringly-typed
`host` — and an unavailable family fails startup rather than falling back
silently. `serve_with` and `serve_transport` do not exist today; every gate
rejects them. The final field set is gated on future-research #21 (whether
`IPV6_V6ONLY` can be set on this stack at all).

### Canonical vocabulary (provisionally frozen)

The teaching vocabulary — the only API shown in introductory documentation:

```text
Application   web.app        web.destroy
Server        web.serve

Routes        web.get  web.post  web.put  web.patch  web.delete

Middleware    web.use  web.next

Input         web.path       web.path_int
              web.query      web.query_int      web.query_int_or
              web.header     web.bearer_token
              web.body
              web.state

Response      web.json       web.text
              web.ok         web.created        web.no_content
              web.bad_request  web.unauthorized  web.forbidden
              web.not_found    web.internal_error
```

Additional helpers (`bytes`, `redirect`, `conflict`, group/router/mount,
built-in middleware constructors) exist in the full reference but are not
part of the first-contact vocabulary. Frozen definitively at the Phase 1
Spec Gate.

## Standardized Error Responses

All framework-generated error responses SHALL share one JSON envelope:

```json
{
  "error": {
    "code": "invalid_path_parameter",
    "message": "Path parameter 'id' must be an integer",
    "field": "id"
  }
}
```

Required error codes include at minimum:

- `invalid_path_parameter`
- `invalid_query_parameter`
- `invalid_json`
- `body_too_large`
- `not_found`
- `method_not_allowed`
- `unauthorized`
- `forbidden`
- `internal_error`

The envelope shape and code list are part of the compatibility contract and
SHALL be documented in `docs/errors.md`.

`error.field` is optional. It is present only when an error is bound to a
specific input field or parameter. When there is no applicable field, the key
SHALL be omitted entirely; it SHALL NOT be emitted as `null` or `""`. Clients
MUST NOT rely on `field` being present.

## Context Model

### Default Context (non-parametric)

The default `Context` is a plain struct. It is what nearly every application
and every documentation example uses:

```odin
// Phase 1
Context :: struct {
	request: Request,            // WP2

	private: Context_Internal,   // chain cursor, allocators, transport hooks
}
```

`response` is NOT a public field. Applications respond exclusively through
`web.json`, `web.ok`, `web.created`, `web.text`, `web.no_content` and the error
helpers. The internal `Response` and its single-commit guard belong to WP2/WP6.

Omitting `ctx.response` keeps the API responder-only: it avoids advertising
mutable response state as public API, so applications reach for the helpers
instead of hand-editing a status or a `committed` flag, and accidental
double-writes stop being an easy mistake to make.

It does NOT make the internal state inaccessible and is NOT a security
boundary. Odin's `@(private)` hides a declaration's *name*, not the
reachability of fields through a public field, and per-field privacy is a
syntax error (ADR-008, "Scope of the guarantee").

`params` and `route` are NOT public fields, in Phase 1 or later (amended in
WP4). WP4 adds route matching, and the matched parameter is stored in the
package-private `Context_Internal` — not on `Context`. Applications read path
parameters through the extractors `web.path` and `web.path_int` (WP5), which
are the single canonical access path; there is no public `Params`, `Param`,
`Route_Info`, `Route`, or `Router` type and no public accessor for either.

A stable internal route identity/pattern for observability remains internal and
future (Phase 3, §Router; OQ-18). Announcing `params`/`route` as public fields
would freeze a matching and identity contract that no work package delivers,
against a public surface frozen at 32 application symbols.

The parametric `Context(App_State, Request_State)` form SHALL NOT be the
default public surface: highly parametric signatures are noisy at call sites
and are reproduced incorrectly by AI agents with limited Odin exposure.

### Application state without visible generics

Typed application state is registered once and read with a validated typed
accessor:

```odin
App_State :: struct {
	db:     ^Database,
	config: Config,
}

state := App_State{db = db}
app := web.app_with_state(&state)
```

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

Internally this MAY use a `rawptr` + `typeid` pair validated at the boundary:

```odin
App :: struct {
	state_ptr:  rawptr,
	state_type: typeid,
	// ...
}

state :: proc(ctx: ^Context, $T: typeid) -> ^T {
	assert(ctx.private.app.state_ptr != nil,
		"web.state called without registered application state")
	assert(ctx.private.app.state_type == typeid_of(T),
		"web.state called with a type different from the registered App_State")
	return cast(^T)ctx.private.app.state_ptr
}
```

A single `rawptr` isolated behind a typed, asserted accessor is acceptable; a
`map[string]any` bag spread through the request is not. This distinction is
normative.

`app_with_state` SHALL reject a nil state pointer at registration.
`web.state(ctx, T)` SHALL assert both that application state was registered and
that `T` matches the registered type before casting. Nil/unregistered state or
a wrong requested type is programmer misuse detected at the boundary, never a
request-time validation error. This policy belongs to the future typed-state
work and does not add state to the Phase-1 public surface.

### Typed request state — opt-in (Advanced API)

The Advanced API gives explicit control over allocators, transport, limits,
and typed state:

```odin
web.app_init(&app, web.Advanced_Config{
	allocator         = allocator,
	request_allocator = request_allocator,
	transport         = transport,
	max_body_size     = 4 * mem.Megabyte,
})
```

Fully typed app + request state remains available here as well:

```odin
app: web.Typed_App(App_State, Request_State)

web.app_init(&app, &state, web.Advanced_Config{...})
```

An application-defined `Request_State` is the future home for
middleware-produced request data (e.g. an `Auth_State` populated once and
consulted by extractors). It belongs to the advanced typed context, never to
the canonical `Context`.

Or, if compiler ergonomics make full parametrization too costly, via
composition:

```odin
App_Context :: struct {
	using base: web.Context,

	app:     ^App_State,
	request: Request_State,
}
```

The rule: **typed state is an advanced capability, not a tax charged to every
application.** The exact mechanism (parametric specialization vs. composed
context) SHALL be validated with real Odin prototypes before the Advanced API
freezes; the Productive API freezes first and independently.

### Dependencies / extraction procedures

There is no dependency-injection container. Composable procedures fill the
role of FastAPI's `Depends`:

```odin
current_user :: proc(ctx: ^web.Context) -> (^User, bool) {
	token, ok := web.bearer_token(ctx)
	if !ok {
		web.unauthorized(ctx, "missing bearer token")
		return nil, false
	}

	user, verified := auth.verify(token)
	if !verified {
		web.unauthorized(ctx, "invalid token")
		return nil, false
	}

	return user, true
}

profile :: proc(ctx: ^web.Context) {
	user, ok := current_user(ctx)
	if !ok {
		return
	}

	web.ok(ctx, user^) // explicit value; `user` itself is ^User
}
```

Extraction procedures follow the extractor contract: respond on failure,
return `(value, ok)`.

### Middleware-Produced Request Data (normative)

The canonical `web.Context` SHALL NOT expose an untyped `user_data`,
`locals`, `values`, or `map[string]any` field.

Application-specific request values SHALL be obtained through typed
extraction procedures, such as:

```odin
user, ok := current_user(ctx)
if !ok {
	return
}
```

For the canonical API, middleware SHOULD primarily:

- allow or reject request execution
- modify HTTP response metadata
- perform logging and observability
- enforce transport-level policies

The advanced typed-context API MAY allow middleware to populate an
application-defined `Request_State`. Untyped request-local storage SHALL NOT
be added to the canonical Context.

**Avoiding duplicate validation.** When a handler needs the authenticated
user, it calls `current_user` directly — the extractor authenticates and
responds on failure, so no `require_auth` middleware is needed on that
route. Gate-only middleware (`require_auth`) is for routes that must be
authenticated but do not need the user value:

```odin
admin := web.group(&app, "/admin")
web.use(&admin, require_auth)
```

Later, the advanced `Request_State` can cache the auth check so middleware
and extractors validate at most once per request:

```odin
Auth_State :: struct {
	checked: bool,
	user:    Maybe(^User),
}
```

## Router

### Responsibilities

- route registration
- route conflict detection
- path matching
- method dispatch
- parameter extraction
- lookup of the precomputed middleware+handler execution chain
- route metadata for observability

### Structure

The router SHALL use one compact radix tree per HTTP method.

Suggested node shape:

```odin
Node_Kind :: enum {
	Static,
	Param,
	Wildcard,
}

Route_Node :: struct {
	prefix: string,
	kind:   Node_Kind,

	static_keys:     [dynamic]u8,
	static_children: [dynamic]^Route_Node,

	param_child:    ^Route_Node,
	wildcard_child: ^Route_Node,

	param_name: string,
	priority:   u32,

	route: ^Resolved_Route,
}
```

### Registration rules

Registration SHALL validate and reject invalid patterns at registration time:

- path must begin with `/`
- wildcard segment must be terminal
- a param segment occupies exactly one path segment
- static and param/wildcard children must not produce ambiguous resolution
- duplicate method+path registrations are invalid
- all conflicts detected early, with clear diagnostics

Route precedence: static > parameter > wildcard.

### Middleware flattening

Registration produces a `Resolved_Route` containing the final flattened
handler chain (global → group nesting order → route middleware → terminal
handler). No chain concatenation occurs during dispatch.

### Parameter storage

Params are written into request-local storage (small fixed array or
pre-capacitied slice). The framework SHALL NOT allocate a map for params on
the hot path.

## Middleware

### User surface

The user surface is trivial; the precomputed chain is internal.

```odin
web.use(&app,
	web.logger(),
	web.recovery(),
	web.cors(web.Cors_Config{
		allowed_origins = {"https://example.com"},
	}),
)
```

Custom middleware is an ordinary handler that calls `web.next`:

```odin
require_auth :: proc(ctx: ^web.Context) {
	token, found := web.bearer_token(ctx)
	if !found {
		web.unauthorized(ctx, "missing bearer token")
		return
	}

	if !auth.token_is_valid(token) {
		web.unauthorized(ctx, "invalid bearer token")
		return
	}

	web.next(ctx)
}
```

Middleware gates, observes, and sets response metadata; it does not hand
typed values to handlers (see *Middleware-Produced Request Data*).

The user SHALL NOT be required to: return a new handler, assemble wrappers,
manipulate a chain index, use `rawptr`, or provide continuation callbacks.

### Execution model (internal)

The Phase-2 prototype SHALL evaluate this deterministic cursor-based onion
candidate:

- `next(ctx)` advances to the next handler
- middleware may run code before and after `next(ctx)`
- returning without calling `next(ctx)` short-circuits
- `abort(ctx)` prevents further downstream execution
- if onion is adopted, post-`next` code runs in reverse-unwind order

Ordering is fixed regardless of the selected continuation model:
app/global middleware → outer groups → inner groups → route middleware →
terminal handler. It SHALL be stable and test-covered.

**Decision gate:** post-`next` (after-response-side) semantics SHALL be
supported only if the transport boundary can guarantee them without confusing
behavior (e.g. around response commit). If it cannot, the contract is
simplified to pre-handler middleware with short-circuit only. This decision
is made at the Phase 2 Spec Gate, with a compiling prototype on the bootstrap
transport.

### Error and panic policy

- parsing/binding/validation errors are normal response paths
- registration conflicts fail loudly at setup time
- runtime panic recovery is provided by the official recovery middleware,
  installed by default in `web.app()`

## Transport Adapter (internal)

The adapter isolates the core from socket/event-loop, HTTP parser, body
streaming, and server runtime concerns.

### Conceptual contract, not a frozen ABI

The internal transport shape SHALL NOT be frozen before the first real
adapter is implemented. The future official `core:net/http` may expose a
blocking server, an explicit event loop, per-connection or per-request
callbacks, its own lifecycle objects, multiple loops per thread, or internal
workers — `core:nbio` today runs per-thread event loops with tick-driven
callbacks executed on the loop's thread. The internal contract therefore
expresses **what the framework needs**, not the anticipated shape of a
library that does not exist yet:

```text
transport accepts HTTP work
transport invokes framework dispatch
transport commits framework response
transport supports shutdown when available
```

A minimal private shape is sufficient until a real adapter forces decisions:

```odin
Transport :: struct {
	data: rawptr,

	serve: Serve_Proc,
	stop:  Stop_Proc,
}
```

This type is private. Its fields and procedures may change freely until the
first Implementation Gate that exercises two transports.

### Execution model (normative)

```markdown
The canonical handler API is synchronous from the application perspective.

The transport implementation MAY execute handlers on an I/O thread, worker
thread, or transport-managed execution context.

No guarantee SHALL be made about the execution thread until the official
transport adapter is prototyped and specified.
```

Because `core:nbio`-style loops execute callbacks on the loop's thread, a
slow synchronous handler could stall other work on that loop. Whether the
answer is transport-managed workers, an adapter-side thread pool, or a
documented "don't block the I/O thread" rule is **an open question that
cannot be closed until the official package exists**. The spec deliberately
does not choose.

### Request/Response ownership (normative)

```markdown
Public request types SHALL be framework-owned abstractions.

Their underlying storage MAY be transport-owned for the duration of request
dispatch.

Applications SHALL NOT retain request-derived slices, strings, headers, or
body views beyond the request lifecycle without making an explicit copy.
```

"Framework-owned types" means the *abstraction* is ours — it does not mean
copying every header, path, and body into independent storage. Views over
transport buffers are the expected implementation:

```odin
Request :: struct {
	method:  Method,
	path:    string,
	query:   string,
	headers: Header_View,
	body:    []u8,
}
```

Valid only during the request; anything persistent is copied with an
explicit allocator.

Phase 1 assumes buffered request bodies; streaming is a later, specialized
API.

### Test transport

A **test transport** (in-memory, no sockets) is required from Phase 1 so that
`web.test_request` works without binding ports.

### Three test suites (normative)

Transport correctness is verified by three separate suites — not by running
the whole application suite against every backend:

```text
Contract suite         — runs on the test transport
    router, extractors, middleware, responses, error envelopes, JSON,
    404/405 — the public behavior of the framework

Transport conformance suite — runs against EVERY real adapter
    request conversion, body lifetime, header normalization, response
    commit, connection close, timeouts, shutdown, malformed HTTP,
    concurrency

End-to-end suite       — a few complete flows over real sockets
```

The conformance suite exists **from Phase 1** as a factory-parameterized
harness, so the bootstrap adapter is held to the same contract a future
adapter must meet, and the first backend cannot silently shape the design:

```odin
transport_contract_test :: proc(t: ^testing.T, factory: Transport_Factory)
```

## Future Migration to `core:net/http`

Migration to the future official Odin HTTP package is expected to be
localized to the transport boundary, provided the framework preserves the
following constraints:

1. No transport-specific type is exposed through the public application API.
2. Router, middleware, extractors, request context, response rendering, and
   error behavior remain framework-owned.
3. Request-derived data is valid only for the request lifecycle unless copied
   explicitly.
4. Buffered request bodies remain the canonical MVP contract.
5. Every real transport must pass the transport conformance suite.

The official `core:net/http` API is not yet known — official communication
says only that it will be built on `core:nbio`, with no published API or
timeline. Therefore, the framework SHALL NOT assume its threading model,
callback model, ownership rules, shutdown semantics, or server lifecycle.
Documentation SHALL refer to it as the "future official `core:net/http`
package", never with an assumed release date.

The canonical application handler API SHALL remain synchronous from the
application developer's perspective. A transport adapter MAY invoke handlers
directly, dispatch them to worker threads, or use transport-managed
execution, provided public behavior remains equivalent.

Migration SHALL be considered successful when:

- the public application examples compile unchanged;
- the framework contract suite remains green;
- the new adapter passes the transport conformance suite;
- request lifetime, response commit, concurrency, shutdown, and timeout
  semantics are documented and tested.

The architecture aims to make migration **controlled and
application-transparent**. It does not guarantee that implementing the future
adapter will be trivial, because the official package API and execution model
are not yet defined.

## Lifecycle

Request lifecycle:

1. transport accepts and parses into framework-native request view
2. router resolves method/path into `Resolved_Route`
3. framework initializes `Context`
4. framework executes the flattened chain
5. response committed to transport
6. request-local resources cleaned up
7. temp allocator region cleared at transport-defined boundary

Application lifecycle: `app` → registration → (internal transport init) →
`serve` → graceful shutdown → destroy. In the Productive API, steps other than
`app`, registration, `serve`, and `destroy` are invisible.

## Observability

Core requirement, mostly middleware-shaped:

- request ID
- access logging by route pattern (not raw path)
- panic recovery logging
- route pattern introspection
- hook points for metrics/tracing

## Memory Model (internal)

Allocation classes: app-lifetime, router-lifetime, request-lifetime,
scratch/temp. Route trees and flattened chains are router-lifetime; context
and param buffers are request-lifetime or frame-backed; parsing scratch uses
the temp allocator where safe. Allocator ownership is documented for every
init/destroy pair.

None of this appears in the Productive API. `web.app()` selects correct
allocators internally; the Advanced API exposes them.

## AI-Friendly API Rules (normative)

- One canonical name per common operation. No equivalent aliases
  (`body`, not also `decode_json`/`parse_body`/`extract_json`/`bind`).
- No overloads whose behavior depends on `any`.
- Prefer explicit helpers: `ok`, `json`, `text`, `body`, `path_int`.
- Every public procedure has a minimal compiling example.
- Public examples are part of the compatibility contract and compile in the
  mandatory verification gate. The gate runs locally before every push and
  MAY be repeated by a remote verifier; it SHALL NOT depend on a paid CI
  provider.
- Internal procedures are never documented beside public ones without being
  clearly marked private.
- `docs/canonical-patterns.md` defines the single recommended form for each
  common task; documentation and examples use only those forms.
- `docs/ai-context.md` maintains a compact public-API reference sized for an
  agent context window; it is updated in the same commit as any public API
  change.

## Freeze Discipline (normative)

```markdown
No public signature SHALL be frozen merely because it looks elegant in the
document. Every canonical signature SHALL be demonstrated by at least one
compilable Odin example and one behavior test before it is frozen.
```

Specification text proposes; compiling prototypes ratify. A gate freezes
only what has been demonstrated in real Odin — everything else (onion
post-`next` semantics, threading guarantees, final arena design, optimized
radix internals, OpenAPI, streaming, WebSocket, the definitive `Transport`
shape) waits for implementation evidence at its own later gate. This keeps
the spec coherent with the actual language, not just internally coherent as
a text.

## Validation (deferred, prototype-gated)

Tag-driven validation (`validate:"required,min=2"`) and a
`web.body_validated` extractor are attractive but SHALL NOT enter the core
until prototypes establish: real tag-introspection capability, reflection
cost, compile-time metadata options, diagnostic ergonomics, and binary-size
impact. Any solution MUST NOT require a mandatory code generator; in the
MVP, validation is explicit procedural code in handlers and services.

## No Code Generation, No Mandatory CLI

The framework ships without a code generator, without a mandatory CLI, and
without heavy metaprogramming. This keeps the framework smaller, more
transparent, easier to maintain — and simple enough for weaker LLMs to use
from a handful of examples. Ergonomics come from extractors and canonical
helpers.

## OpenAPI (out of MVP)

OpenAPI/automatic documentation is explicitly deferred. When it arrives, it
SHALL be an optional layer over the existing API that does not require
rewriting handlers. A possible future direction (not decided now):

```odin
web.post(&app, "/users", create_user, web.Route_Info{
	summary = "Create user",
})
```

## Non-Goals for the Core

- ORM/database layer (but see below)
- dependency injection container
- template engine
- WebSocket abstraction in core
- HTTP/2-specific abstractions in core
- reflection-heavy auto-validation in v1
- macro-like hidden magic

**Integration story requirement:** while no ORM ships in core, the framework
SHALL make database/config/auth integration natural via `app_with_state` +
`web.state`, and the cookbook SHALL show a full Postgres-backed CRUD example.

## Reference Project Structure

```text
uruquim/
├── web/                        public package (import web "uruquim:web")
│   ├── app.odin                app / bare / app_with_state / destroy
│   ├── routing.odin            get/post/... , router/group/mount
│   ├── context.odin
│   ├── extract.odin            path, path_int, query, query_int, query_int_or, body, state
│   ├── respond.odin            ok, created, json, text, errors, ...
│   ├── serve.odin              serve / serve_with / serve_transport
│   ├── errors.odin             error envelope + codes
│   │
│   ├── internal/
│   │   ├── router/             radix tree, register, lookup, params
│   │   ├── chain/              flattening + cursor execution
│   │   ├── transport/          boundary, odin_http adapter, core_http adapter, test transport
│   │   └── memory/             allocation classes, request arenas
│   │
│   ├── middleware/             logger, recovery, request_id, cors, timeout, secure_headers, body_limit
│   └── testing/                test_request, recorder
│
├── docs/
│   ├── quick-start.md
│   ├── canonical-patterns.md
│   ├── cookbook.md
│   ├── errors.md
│   ├── memory-model.md
│   ├── middleware.md
│   └── ai-context.md
│
└── examples/                   all compiled by the verification gate
    ├── 01-hello-world/
    ├── 02-json-api/
    ├── 03-route-params/
    ├── 04-middleware/
    ├── 05-route-groups/
    ├── 06-authentication/
    ├── 07-crud/
    ├── 08-postgres/
    ├── 09-file-upload/
    └── 10-observability/
```

## Final Architectural Position

The framework is defined by five pillars:

- productive canonical public API (`app` / route / extract / respond / `serve`)
- custom radix router
- deterministic flattened middleware chain
- internal transport boundary with `core:net/http` as the canonical backend
- opt-in typed state (Advanced API), never a tax on ordinary applications

Not "FastAPI in Odin", but: **FastAPI's productivity with a data-oriented,
predictable implementation for Odin.**
