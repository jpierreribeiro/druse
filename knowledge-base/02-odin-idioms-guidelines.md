# Druse — Odin Idioms and Coding Guidelines

## Status

This document is normative for the implementation agent.

If a code generation choice conflicts with this document, this document wins.
If this document conflicts with `01-architecture-spec.md`, the architecture
spec wins.

## Core Identity

You are writing Odin, not Go-with-different-syntax.

You MUST optimize for:

- explicitness
- procedural design
- allocator correctness
- data layout clarity
- low hidden cost
- spec compliance
- a simple, predictable public surface

You MUST NOT optimize for:

- Go familiarity
- Rust stylistic imitation when it harms Odin clarity
- pseudo-OOP aesthetics
- abstract "generic elegance" at the cost of straightforward code

## Productivity Is Not the Enemy of Explicitness

Do not expose systems-level complexity merely because the language permits it.

The framework internals must be allocator-aware and ownership-correct.
The common public API must provide safe defaults and hide infrastructure
details that application developers do not need to control.

Do not require users to configure allocators, transports, radix nodes,
response buffers, or middleware cursors for ordinary applications.

Explicitness is a property we demand of the *internals* and of the *contract*,
not a burden we shift onto every Hello World.

## AI-Friendly API Rules

- Use one canonical name per common operation.
- Avoid equivalent aliases.
- Avoid overloads whose behavior depends on `any`.
- Prefer explicit helpers such as `ok`, `json`, `text`, `body`, and `path_int`.
- Every public procedure must have a minimal compiling example.
- Public examples are part of the compatibility contract.
- Never document internal procedures beside public procedures without clearly
  marking them private.
- When choosing between two equally correct public APIs, prefer the one with:
  fewer required concepts, fewer user-managed lifetimes, fewer generic
  parameters visible at call sites, one obvious way to perform the task,
  better compiler diagnostics, and lower probability of hallucinated usage.

### Canonical syntax must actually compile

Every pattern published in docs, examples, or `ai-context.md` MUST be valid
Odin verified by the mandatory local/remote verification gate. In particular:

- `or_else` takes an *expression*, not a statement block. Patterns like
  `id := f() or_else { respond(...); return }` are NOT valid Odin and MUST NOT
  appear anywhere in documentation.
- The canonical extractor patterns are exactly two:

```odin
// Value-producing extractor
id, ok := web.path_int(ctx, "id")
if !ok {
	return
}

// Destination-filling extractor
input: Create_User
if !web.body(ctx, &input) {
	return
}
```

Value-producing HTTP extractors deliberately do **not** declare
`#optional_ok`. The pinned compiler then rejects a call that captures only
the value (`Assignment count mismatch`), forcing humans and coding agents to
handle `ok`. Destination-filling extractors take `dst: ^$T` and return only
`bool`.

If prototyping later proves a strictly better compiling form, the canonical
pattern is amended once, spec-first, before the API freezes — never ad hoc in
individual examples.

## Language Mindset

### No OOP simulation

Do not simulate classes, methods, inheritance, or "objects with behavior".

Use:

- records for data
- procedures for operations
- packages as library boundaries
- explicit state passed by pointer when mutation is intended

Preferred:

```odin
router_init :: proc(r: ^Router) { ... }
router_add_route :: proc(r: ^Router, method: Method, path: string, h: Handler) -> Route_Error { ... }
```

Avoid receiver-thinking (`Router.add_route(...)`, `ctx.json(...)`) even where
style tricks would allow it.

### Package style

Packages are libraries, not pseudo-namespaces. Keep responsibilities crisp;
prefer a few coherent packages over many tiny pseudo-class packages. The
public package is `web`; internals live under `web/internal/`.

## Memory Management Rules

### General allocator policy

Every allocation belongs to exactly one lifetime:

- application lifetime
- router lifetime
- request lifetime
- temporary scratch lifetime

Identify the lifetime before allocating.

### `context.allocator`

Use for allocations that survive the current local operation: router
construction, chain precomputation, persistent request-owned structures, test
harness objects.

### `context.temp_allocator`

Use only for short-lived scratch where ALL of the following hold: the
allocation is temporary, is not stored into framework state that outlives the
operation, is not returned as part of a persistent structure, and is not
referenced after the temp allocator may be cleared.

Allowed: path normalization scratch, temporary formatting buffers, short-lived
parse helpers, lookup-time scratch consumed immediately.

Forbidden: storing temp-allocated strings in route tables; storing
temp-allocated slices in request state; returning temp-allocated data unless
the contract explicitly requires immediate copy; keeping temp-allocated
values in deferred work.

Note: `core:net` documents a performance dependency on an adequately sized
`context.temp_allocator`. Allocator discipline is correctness, not tuning.

### Deallocation forms

- `free(ptr)` for pointer/object storage
- `delete(x)` for slices, dynamic arrays, maps, strings with managed backing
- `free_all(allocator)` only when the allocator semantics support it

Pair init/destroy procedures for router-, application-, and request-level
lifetimes.

### Allocation restrictions by area

**Registration** MAY allocate (radix nodes, metadata, chain flattening,
pattern storage, diagnostics).

**Lookup / request hot path** treats allocation as exceptional. Forbidden by
default: param maps, heterogeneous containers, heap-backed path splitting,
diagnostic string formatting on the success path. Allowed if justified and
documented: bounded once-per-request storage, phase-contracted body
buffering, explicit fallback allocation in error paths.

**Body handling**: do not copy bodies without reason; do not materialize
strings when bytes suffice; cap sizes; allocate with request-lifetime
allocator; avoid double copies; define ownership clearly.

## Data-Oriented Design Rules

Prefer simple structs with obvious ownership, contiguous storage, flat
arrays/slices over pointer-chasing, enum-indexed tables, and fixed-capacity
param storage. Avoid maps in hot dispatch paths, per-request map-based feature
bags, and generic tree abstractions with opaque cost.

If work can be done at registration time, do it then: flattened chains, param
counts, pattern metadata, conflict validation, static-child ordering.

## Error Modeling

Do not emulate Go's `error` interface or return strings as the primary error
channel.

Prefer:

- enums for closed failure sets
- unions (`#shared_nil`) for multi-domain failure sets
- `(value, ok)` where failure is binary and carries no detail
- `(value, Error)` when detail is needed

```odin
Route_Register_Error :: enum {
	None = 0,
	Empty_Path,
	Path_Must_Start_With_Slash,
	Duplicate_Route,
	Wildcard_Must_Be_Last,
	Conflicting_Route,
}

Bind_Error :: union #shared_nil {
	Json_Bind_Error,
	Query_Bind_Error,
	Validation_Error,
}
```

**Extractor contract:** public value-producing extractors return
`(value, ok)` without `#optional_ok`; destination-filling extractors
(`web.body(ctx, &dst)`) return `bool`. Both are responsible for writing the
standardized error response before returning `false`. Detailed error
taxonomies (`Bind_Error` etc.) exist internally and power the standardized
envelope; ordinary handlers never inspect them. Typed extractors use
explicit type-specific names (`query_int`, `query_int_or`) — never `typeid`
parameters in the canonical surface.

Handlers do not return a generic error. The fixed compiler accepts silently
discarded procedure results, so an Echo-like return does not force callers to
handle failures; an unnamed result also prevents the canonical bare `return`
after extractor failure. Route framework failures through a private, closed,
typed error event that owns formatting, logging, and commit checks.
Application-domain errors remain application types and are mapped explicitly
at the HTTP boundary. Do not imitate Go error propagation with `any`, an open
error bag, or multiple canonical handler signatures.

### Panic policy

Panic only for impossible internal invariants, programmer misuse at
initialization time, or corruption. Never for request-time validation or user
input failure.

## `any` Policy

Assume `any` is dangerous. Do not use `any` in core framework architecture
unless a spec explicitly allows it.

Forbidden uses: request-scoped storage bags, middleware communication, route
parameter values, handler return channels, error transport, default public
extension points.

Allowed only in tightly bounded tooling/debug cases (debug logging, test
utilities, diagnostic payloads off the hot path) — documented, lifetime-
annotated, and isolated at boundaries.

### The one sanctioned `rawptr`

`app_with_state` stores a single `rawptr` + `typeid` pair, validated by
assertion inside `web.state(ctx, T)`. This controlled, boundary-isolated use
of type information is explicitly permitted. It does not license dynamic bags
anywhere else. This is a future Phase-3/Advanced API: registration rejects a
nil pointer, and access asserts that state was registered and that the
requested `typeid` matches before casting. `rawptr` is never public.

## Procedure Design Rules

Signatures communicate ownership and mutability:

```odin
router_lookup :: proc(r: ^Router, method: Method, path: string) -> (^Resolved_Route, []Param, bool)
```

Use pointers for mutable large state; do not pass giant structs by value
casually. Every type that owns memory has init/destroy pairs — in the
Productive API these are wrapped (`web.app()` / `web.destroy(&app)`), but they
exist and are documented in the Advanced API.

`web.app()` returns an owning `App` by value for the Productive API. `App` is
non-copyable by contract: initialize it once, pass `&app`, and destroy that
same value exactly once. Initialization must not store a pointer to the
pre-return local `App`; internal self-pointers may only be established after
the caller-owned value exists. `app_init(&app)` remains a future Advanced API.

JSON response payloads are passed by value in the Phase-1 baseline. A pointer
variable (for example `user: ^User`) and `&user` are not accepted payload
forms until a separate one-level-dereference prototype proves a clean
implementation. If the official JSON marshaller rejects a payload type, the
renderer logs the marshal error on the server and, while still uncommitted,
writes one fresh standardized `internal_error` response. It never emits a
silent 500 or partial JSON.

## Context Usage Rules

- `context` always means Odin's implicit context.
- `ctx` always means the framework request `Context`.
- Never name a framework context variable `context`.

Capture allocators deliberately at boundaries
(`ctx_internal.allocator = context.allocator`); override `context.allocator`
only in narrow, documented scopes.

## Concurrency and Async Discipline

No goroutine-like assumptions. All async/event-loop work is explicit in the
transport layer (`core:nbio`-backed once `core:net/http` lands). Core
framework control flow stays transport-agnostic and synchronous unless a
phase introduces streaming APIs.

Never retain references into transport-owned request storage past the request
lifetime; copy intentionally with the correct allocator if a value must
survive.

## Testing Rules

Spec first, tests second, implementation third — always, for core components.

Required test layers: unit tests for radix operations; unit tests for chain
semantics; integration tests via the in-memory test transport; negative tests
for route conflicts; allocator/lifetime tests where possible; **compile tests
for every documented example**.

Transport testing is split into three suites (see architecture spec): the
**contract suite** (public framework behavior, runs on the test transport),
the **transport conformance suite** (factory-parameterized
`transport_contract_test`, runs against every real adapter — body lifetime,
header normalization, response commit, shutdown, malformed HTTP,
concurrency), and a small **end-to-end suite** over real sockets. Do not
duplicate application-level rules into per-backend tests.

Must-test invariants:

- Router: static beats param; param beats wildcard; duplicates rejected;
  wildcard-last enforced; per-method dispatch isolated.
- Middleware: exact order and short-circuit are mandatory; if the Phase-2 gate
  adopts onion semantics, post-`next` runs in reverse-unwind order. Recovery
  catches panics.
- Context/extractors: params/query/header lookups predictable; failed
  extractors write the standardized envelope exactly once; response commit
  rules enforced.
- Defaults are progressive and test-pinned: Phase 1 enforces a fixed 4 MiB
  request-body cap and standardized 404/405 handling (`Allow` is mandatory on
  405); Phase 2 installs recovery; Phase 3 adds configurable limits,
  read/write timeouts, and optimized 405/header handling; Phase 4 hardens
  graceful shutdown. Documentation must identify the delivery phase instead
  of implying that the end-state set already ships.
- JSON rendering: unsupported payload types log the marshal error server-side
  and produce exactly one standardized `internal_error` before commit; no
  partial JSON may escape.

## Public API Design Rules

- Minimize surface area; start with a small core that composes.
- One canonical name per concept; no synonyms in the first release.
- Explicit names over vague, magic, or cute ones.
- No reflection-heavy validation by default; if metadata-driven validation
  appears later it is optional and never infects the hot path.
- No code generator, no mandatory CLI, no heavy metaprogramming. Ergonomics
  come from extractors and canonical helpers, not tooling.
- The canonical `Context` never gains an untyped `user_data`/`locals`/
  `map[string]any` field; middleware-produced values reach handlers through
  typed extraction procedures (or, later, the advanced `Request_State`).

## Dependency Rules

Write code robust to vendored third-party packages. Do not hardwire external
package details into the public architecture. Transport-specific types must
not leak into user handlers — this is the load-bearing rule that makes the
`odin-http` → `core:net/http` migration a non-event for applications.

## Documentation Rules

For any nontrivial procedure, document: ownership expectations, allocator use,
failure modes, and whether returned strings/slices are borrowed or owned.
Mandatory for router, context, extractor, and transport-boundary procedures.

Additionally, any change to the public API MUST, in the same commit:

- update `docs/canonical-patterns.md` if a canonical form changed
- update `docs/ai-context.md`
- keep every affected example compiling

## Final Behavioral Rules for the Agent

You MUST: favor explicit procedures over abstraction theater; keep structs
simple; keep hot paths predictable; keep allocator ownership visible
internally; model failures with enums/unions; avoid `any`; avoid OOP
simulation; write tests before implementation; preserve the transport
boundary; keep the ordinary public surface down to app/route/extract/respond/
serve.

You MUST NOT: port Gin or FastAPI mechanically; mimic Go's context bag;
assume GC-like lifetime forgiveness; introduce maps/interfaces/`any` into hot
request paths; design public APIs around hidden allocations; add public
aliases or a second way to do an already-canonical task.
