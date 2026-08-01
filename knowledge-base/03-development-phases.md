# Druse — Development Phases

## Process Contract

Every phase follows this strict rule:

- finalize spec statements for the phase
- write tests for the phase
- implement only after tests exist
- do not expand scope mid-phase unless the specification is amended first

Each phase has three mandatory gates: **Spec Gate**, **Test Gate**,
**Implementation Gate**. A phase is not complete until all three pass.

Cross-phase invariants, enforced from Phase 1 onward:

- no transport-native types in any public signature
- every documented example compiles in the mandatory verification gate
- `docs/ai-context.md` matches the public API at every merge
- no code generator, no mandatory CLI, no heavy metaprogramming
- every real transport adapter passes the factory-parameterized transport
  conformance suite (`transport_contract_test`), which exists from Phase 1
  so the first backend cannot silently shape the design

**Note on `web.app()` defaults:** the architecture spec defines the full
default-policy contract (recovery, limits, timeouts, 404/405, graceful
shutdown). It is delivered progressively: Phase 1 enforces a fixed 4 MiB
request-body cap plus standardized 404 and minimal 405 with `Allow`; Phase 2
adds the documented fault behaviour rather than a recovery middleware, because
Odin has no recoverable panic (ADR-020); configurable limits, read/write
timeouts, and optimized 405/header handling arrive in Phase 3; shutdown
robustness arrives in Phase 4. The *end-state contract* is fixed now, but
documentation must say which part is available in each phase.

## Phase 1 — Minimal Productive API

### Goal

A user can build a small JSON API with routes, extractors, and JSON/text
responses, without touching transport internals. Not just Hello World: the
phase is complete only when a small CRUD-style API is writable from the
public API alone.

### Scope (required)

- application: `web.app()`, `web.bare()`, `web.destroy`
- routes: `web.get`, `web.post`, `web.put`, `web.patch`, `web.delete`
  (static and `:param`), via a simple interim dispatcher
- `web.Context` (plain struct, non-parametric)
- path extractors: `web.path`, `web.path_int`
- query extractors: `web.query`, `web.query_int`, `web.query_int_or`
- JSON body: `web.body(ctx, &dst)`
- responses: `web.ok`, `web.created`, `web.no_content`, `web.json`,
  `web.text`
- error helpers + standardized envelope: `bad_request`, `unauthorized`,
  `forbidden`, `not_found`, `internal_error`
- fixed 4 MiB request-body cap; oversized input produces `body_too_large`
- consistent 404 behavior and minimal 405 with the required `Allow` header
- server: `web.serve(&app, port)` with clean stop
- internal transport boundary as a **conceptual contract** (accepts HTTP
  work → invokes dispatch → commits response → supports shutdown); the
  private `Transport` shape is NOT frozen before the first real adapter
- functional bootstrap adapter over `odin-http`
- transport conformance suite skeleton:
  `transport_contract_test(t, factory)`, run against the test transport and
  the bootstrap adapter from day one
- in-memory test transport + `web.test_request` (required by the tests-first
  process itself)

### Forbidden in this phase

- middleware registration (`web.use`), groups
- radix tree (interim dispatcher must already match the routing spec's
  observable behavior — precedence, 404 — so Phase 3 changes nothing
  publicly)
- streaming, uploads, validation system
- Advanced API surface (`app_init`, `Advanced_Config`, `serve_transport`,
  typed state)
- OpenAPI

### Freeze discipline (normative for this gate)

```markdown
No public signature SHALL be frozen merely because it looks elegant in the
document. Every canonical signature SHALL be demonstrated by at least one
compilable Odin example and one behavior test before it is frozen.
```

The pre-implementation gate ratifies **only the shapes and behavior directly
demonstrated by compilable prototypes**. Exact Phase-1 symbols not exercised
by name yet (including `bare`, `no_content`, `text`, raw `path`/`query`, the
individual error helpers, and `transport_contract_test`) remain the approved
target vocabulary but are not frozen signatures until WP1's compile-contract
test references them and their owning WP adds a behavior test.

```text
RATIFIED SHAPES              PROVISIONAL UNTIL WP1/OWNER WP
app/get/serve/handler        remaining public vocabulary
extractor result shapes      exact helper signatures not exercised
JSON value responders        transport_contract_test signature
request views/lifetimes      405 implementation evidence
single response commit
conceptual transport flow    DELIBERATELY LATER-PHASE
in-memory dispatch           post-next onion semantics
                              threading / Transport ABI / radix
                              OpenAPI / streaming / WebSocket
```

The first provisional column is closed incrementally by WP1 and the owning
tests-first work package. The later-phase column is decided only at its own
gate. No provisional symbol may be advertised as shipped before its gate.

### Spec Gate checklist

- [ ] every signature below is backed by a compiling example AND a behavior
      test before being marked frozen
- [ ] freeze the canonical vocabulary (app/routes/extractors/responses/serve)
- [ ] freeze the extractor control flow: plain `(value, ok)` without
      `#optional_ok` for value-producing extractors, so the compiler forces
      the boolean to be captured; `^$T` destination + `bool` for `web.body`
- [ ] freeze `query_int_or` semantics (default only on absence; malformed
      value is a 400)
- [ ] freeze the error envelope and initial code list
- [x] define `Request` public minimum fields (`method`, `path`, `query`,
      `headers`, `body`), the `Method` minimum set
      (`UNKNOWN/GET/POST/PUT/PATCH/DELETE`), and `Header_View` as a
      contract-encapsulated wrapper over private pairs — WP2
- [x] `Response` and its commit state stay internal; the single-commit guard
      covers the supported `web.*` paths and is NOT a security boundary — WP2
- [x] request-lifetime view rule: no retention without explicit copy — WP2
- [ ] `HEAD`/`OPTIONS` contracts — deferred until specified and tested; with
      the Phase-1 minimum set they convert to `.UNKNOWN`
- [ ] define the conceptual transport contract and the conformance suite
      scope (request conversion, body lifetime, header normalization,
      response commit, connection close, shutdown, malformed HTTP) —
      WITHOUT freezing the internal `Transport` ABI
- [ ] record the execution-model non-guarantee: handlers are synchronous
      from the application perspective; execution thread is unspecified
      until the official adapter is prototyped
- [ ] define clean-stop behavior

### Test Gate checklist

- [ ] static route returns expected status and body
- [ ] `:param` route extracts value; `path_int` failure produces
      `invalid_path_parameter`
- [ ] `web.query_int` missing/malformed produces `invalid_query_parameter`
- [ ] `web.query_int_or`: absent → default; malformed → 400
- [ ] `web.body` success and `invalid_json` failure paths
- [ ] body larger than 4 MiB produces `body_too_large` without decoding
- [ ] unknown route returns standardized 404
- [ ] known path under another method returns standardized 405 and an exact
      `Allow` header
- [ ] `web.ok`/`web.created` byte-identical to equivalent `web.json` calls
- [ ] unsupported JSON payload type logs the marshal failure server-side and,
      before commit, produces one complete `internal_error` response with no
      partial JSON
- [ ] `test_request` round-trips without sockets
- [ ] `transport_contract_test` passes on the test transport AND the
      bootstrap adapter
- [ ] adapter starts and stops cleanly; response cannot be committed twice

### Implementation Gate checklist

- [ ] odin-http bootstrap adapter implemented behind the boundary
- [ ] test transport implemented
- [ ] examples `01-hello-world`, `02-json-api`, `03-route-params` compile and
      run in the verification gate
- [ ] small CRUD example writable using only public API (proof of goal)
- [ ] no transport-native types leak into public signatures
- [ ] `docs/quick-start.md`, `docs/errors.md`, `docs/canonical-patterns.md`,
      `docs/ai-context.md` cover the shipped surface

## Phase 2 — Middleware and Groups

### Goal

Deterministic middleware and route organization, still on the interim
dispatcher.

### Scope (required)

- `web.use` at app and router level; route-level middleware is expressed as a
  one-route `Router` mounted at the path (ADR-025, option B — the five Phase-1
  registration signatures stay frozen; a variadic tail remains available later
  by freeze amendment if real usage proves the need)
- route organisation: `web.Router`, `web.router`, `web.mount` — and NO
  `web.group`: once a detached Router can be mounted at a prefix,
  `group(&app, "/admin")` is a second canonical way to perform one operation,
  which G-01 rejects (ADR-024)
- `web.next`; short-circuit by returning without `next`
- **fault behaviour (amended 2026-07-19, ADR-020).** Phase 2 ships **no
  recovery middleware and no public symbol for it.** Odin has no recoverable
  panic: `Assertion_Failure_Proc` is typed `-> !`, `context` is by-value so
  `app()` cannot install a hook for its caller, and bounds-check, nil-deref and
  divide-by-zero faults never reach a hook at all. What Phase 2 guarantees is
  the WP8 driver behaviour — a handler that commits no response is finalized
  to a standardized 500 — and documentation stating plainly that a panic aborts
  the process. A "last-gasp responder" is deferred to Phase 4 and must never be
  called recovery. Evidence: `planning/history/phase-2-prototype-recovery.md`
- logger middleware
- request ID middleware
- typed framework-error observer/policy for centralized logging and optional
  external reporting; it receives a closed event, never arbitrary `any`, and
  does not change the canonical handler signature
- `web.header`, `web.bearer_token` lookups
- documented auth pattern: gate-only `require_auth` middleware + typed
  `current_user` extraction procedure (no `user_data` field, ever)

### Spec Gate checklist (all ticked at the WP15 Spec Gate, owner-approved
2026-07-19; the clause pointers are into `planning/phase-2-spec.md`)

- [x] exact ordering rules (global → outer routers → inner → handler) — §2.1
- [x] **onion decision:** post-`next` semantics supported only if the
      transport boundary guarantees them without confusing behavior
      (prototype on the bootstrap transport); otherwise simplify to
      pre-handler + short-circuit — decided **B1, specified and tested**
      (ADR-022; WP12 P4/P5 are the bootstrap-transport prototype) — §3
- [x] chain flattening at registration time specified — §2.2 (index pairs,
      append-only pool invariant)
- [x] fault-behaviour documentation (ADR-020: driver 500 + panic aborts) — §8;
      request ID source/generation — §7 (ADR-027: strict charset, counter +
      process-start entropy, documented as not unguessable)
- [x] `use()`-before-routes enforcement (ADR-019): applies to `Router`,
      `mount` and `bare()`; diagnostic text approved in §5; the mechanism is
      constrained by ADR-019's three properties, with poison-vs-cured-abort
      delegated to the WP17 prototype by that ADR — §5
- [x] error-event fields, redaction policy, observer isolation, and behavior
      after response commit — §6 (ADR-026: pattern-only route identity, no
      message string, safety by type)

### Test Gate checklist

- [ ] middleware order exactness, including nested groups
- [ ] short-circuit stops downstream
- [ ] post-`next` unwind order correct (if onion adopted)
- [x] a handler that commits no response is finalized to a standardized 500
      (this is what Phase 2 means by recovery — ADR-020) — WP21. Proven under
      BOTH transports (`tests/wp21-public-surface`, `tests/wp21-socket`), in
      default AND `-o:speed` builds, for `app()` and `bare()`, for a plain
      silent handler and for an early-return error branch, and repeatably: the
      second and third fault are byte-identical to the first and a healthy
      request in between is unaffected. The finalized body BORROWS the
      compile-time constant (`tests/wp21-internal`), so the guarantee cannot
      fail for want of memory and there is no buffer in which a detail string
      could be composed
- [x] a panic in a handler aborts the process, and the documentation says so —
      WP21. It cannot be an in-process test, because the process it asserts
      about is the test runner; it is `build/check_wp21_controls.sh` control 7,
      which BUILDS and RUNS three programs. A fault-free baseline exits 0 (so
      the probe is sound, not merely a broken build), while a panicking handler
      and an out-of-bounds index are each killed by signal 4 (status 132) —
      both fault classes, because ADR-020 turns on their difference. The
      documentation half is `build/check_docs.sh` §6e, with control 6 proving
      it rejects a document that promises recovery (G-08)
- [ ] `use()` after a registered route fails at boot, fail-closed (ADR-019),
      with a test proving the mis-ordered auth program does NOT serve the
      route
- [ ] request ID present in context and response header
- [ ] every framework error is observed exactly once; an observer cannot
      trigger a second response write or expose internal details
- [ ] app-level middleware observe a 404 and a 405, in `bare()` too, with the
      standard envelopes and the 405 `Allow` header unchanged (ADR-023)
- [ ] `web.bare()` installs none of the defaults

### Implementation Gate checklist

- [ ] flattened chains built at registration; no dispatch-time assembly
- [ ] logger and request ID implemented; fault behaviour documented (ADR-020)
- [ ] examples `04-middleware`, `05-route-groups`, `06-authentication`
- [ ] all Phase 1 public-behavior tests still pass unchanged

## Phase 3 — Performance Core

### Goal

Replace the interim internals with the real data-oriented core, with no
public API change.

### Scope (required)

- method-sharded radix tree router (static, `:param`, terminal `*wildcard`)
- zero-allocation lookup on the common path
- params in small fixed buffers (no maps)
- route conflict detection with diagnostics; optimized 405 method discovery
  and header construction
- precomputed middleware chains (from Phase 2) verified allocation-free at
  dispatch
- per-request arena; reusable buffers
- allocation reduction pass across the hot path
- typed application state: `app_with_state` + `web.state`, backed by the one
  sanctioned private `rawptr + typeid` pair; this is Advanced and never a
  Phase-1 requirement
- configurable body-size limit (replacing the fixed Phase-1 cap) and
  read/write timeouts — become default-on in `web.app()`
- benchmark suite (lookup, dispatch, JSON round-trip) with regression harness

### Spec Gate checklist

- [ ] disposable router shootout compares pointer-radix, index-radix, and a
      hybrid/data-oriented layout on the pinned toolchain; the production node
      shape is selected from recorded lookup latency, allocations, footprint,
      and build cost rather than external-framework claims
- [ ] radix node shape; precedence rules; duplicate/conflict rules
- [ ] path normalization policy; 405 and OPTIONS policy
- [ ] param representation; arena lifetime contract
- [ ] oversize-allocation bypass and reusable-buffer retention policy selected
      from normal, burst, and giant-request memory measurements
- [ ] internal stable route identity/pattern contract: successful match and 405
      preserve it; 404 has none; no public accessor is implied
- [ ] default limit/timeout values for `web.app()`

### Test Gate checklist

- [ ] static beats param; param beats wildcard
- [ ] duplicate registration rejected; invalid wildcard placement rejected
- [ ] per-method routing isolated; 405 when route exists on another method
- [ ] matched pattern preserved for instrumentation
- [ ] fuzz/property tests for insert+lookup invariants
- [ ] benchmark compares peak and retained memory after a giant request, not
      only common-path allocation count
- [ ] optional debug-only lifetime probe validates the pinned
      `base:sanitizer` poison/unpoison behavior and documents its false-negative
      window; it adds no release hot-path check and is not a safety guarantee
- [ ] configured body limit overrides the 4 MiB default; oversized body still
      produces `body_too_large`; timeout behavior covered

### Implementation Gate checklist

- [ ] radix insert/lookup implemented; params without map allocation
- [ ] arena + buffer reuse implemented; hot path allocation-reviewed
- [ ] benchmarks recorded; regression harness in the mandatory verification
      gate (local pre-push plus clean VPS repetition)
- [ ] all Phase 1–2 public-behavior tests pass unchanged

## Phase 4 — Production

### Goal

Harden for serious use.

### Scope (required)

- graceful shutdown robustness: stop admission, finish admitted work until an
  absolute deadline, force-close remaining work, cleanup exactly once; details
  remain transport-private
- trusted-proxy security policy: forwarding headers ignored by default,
  explicit trusted networks, original peer preserved; ADR required before code
- CORS middleware; secure headers middleware
- cookies helpers
- file uploads (fully specified multipart contract with request-owned temporary
  resources, explicit persistence transfer, quotas, and failure cleanup; JSON
  never spills implicitly to disk)
- static file serving
- structured logging; observability hooks (route-pattern keyed metrics and
  tracing points) with bounded non-blocking delivery and no raw-path fallback
- deterministic bounded admission/load shedding; adaptive overload control is
  future research and cannot replace the deterministic mechanism
- load tests
- allocator/lifetime audit

### Gates (summary)

- Spec: shutdown guarantees after a two-transport prototype; trusted-proxy ADR;
  upload ownership/quotas; static contracts; telemetry hook points and queue
  bounds; deterministic shedding policy
- Test: shutdown with slow headers/body/writer, keep-alive and deadline races;
  proxy spoofing and IPv4/IPv6 chain corpus; upload limits plus disk-full,
  disconnect and timeout cleanup; 200/404/405 route-cardinality behavior;
  blocked exporter cannot block a handler; shedding/load-test baseline recorded
- Implementation: hardening middleware done; audit completed; examples
  `07-crud`, `08-postgres`, `09-file-upload`, `10-observability`; docs
  `memory-model.md`, `middleware.md`, `cookbook.md` complete

## Phase 5 — Future

### Goal

Optional layers and the canonical transport, without disturbing the frozen
API.

### Scope (candidates, each spec-gated individually)

- **official `core:net/http` adapter** when the package ships (no assumed
  date — "coming soon" is not a schedule). Migration is successful when:
  public application examples compile unchanged; the contract suite stays
  green; the new adapter passes the transport conformance suite; and request
  lifetime, response commit, concurrency, shutdown, and timeout semantics
  are documented and tested. The bootstrap adapter is then demoted or
  removed. The adapter's difficulty depends on the execution and ownership
  model the official package adopts — the architecture guarantees a
  *controlled, application-transparent* migration, not a trivial adapter.
  (If the package ships earlier, this item may be pulled forward between
  phases.)
- OpenAPI as an optional layer over the existing API (`web.Route_Info`
  direction); no handler rewrites required
- automatic documentation from the OpenAPI layer
- WebSocket (separate package)
- streaming request/response APIs
- HTTP/2, as the official transport permits
- Advanced API completion: `app_init` + `Advanced_Config`, typed
  per-request `Request_State`, `serve_transport` (typed application state is
  introduced separately in Phase 3)
- validation story decision (explicit vs tag-based), prototype-gated, never
  requiring a generator
- adaptive overload controller, only after deterministic bounded admission and
  shedding have passed Phase-4 tests
- public read-only route-pattern access, only if a real application use case
  cannot be served by internal instrumentation hooks
- project templates

## Exit Criteria for the Project Core

The framework core is architecturally established only when:

- a small JSON CRUD API can be written from `docs/ai-context.md` alone
- the router is custom, benchmarked, and fully test-covered
- middleware semantics are stable and test-pinned
- transport is decoupled, with `core:net/http` as canonical backend
- the hot path has been allocation-reviewed
- every documented example compiles in the verification gate
