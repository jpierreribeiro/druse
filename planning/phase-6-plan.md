# Phase 6 — Real applications: concurrency, validation and data

**Status: OWNER-APPROVED EXECUTION PLAN, 2026-07-21; WP66 spec gate applied
against the Phase-5 freeze at `6b6edbc`. Names and signatures remain
prototype-gated.**

This plan was first written while Phase 5 was in progress, then refreshed after
WP65 froze at `6b6edbc`. The actual entry ledger is **62 application + 2
test-support = 64**. Phase 5 shipped drain deadline, CORS, static files and
bounded in-memory multipart; large uploads remain impossible because the whole
body is buffered under `Limits.max_body`. WP66 still performs a final
entry-time verification, but these are now observed facts rather than
assumptions.

This phase is the first part of the product program in
`planning/phases-6-8-program.md`. Its frozen output feeds Phase 7's long-lived
response work and Phase 8's real-system validation. Those later phases may
discover evidence that amends this plan; they may not bypass its gates.

The phase continues the numbering with **WP66–WP84**, in two halves:

1. make the synchronous handler model safe for real blocking dependencies;
2. deliver a SQL-first data stack outside `web`, then prove it with a real app.

The thesis in one line:

> Keep handlers synchronous and pleasant, remove the process-wide stall,
> make input failures honest, and provide PostgreSQL without ORM magic,
> unbounded waiting or hidden lifecycle.

This is not a commitment to a particular future HTTP implementation. The
official Odin `core:net/http` is expected after this plan was written, but is
neither available nor an entry blocker. The current vendored transport is the
bridge; the public framework contract stays above it so a later adapter can
replace that bridge.

---

## 0. Viability verdict

The proposed phase is **viable now**, with one important distinction.

| Item | Verdict | Why |
|---|---|---|
| Honest JSON errors and field paths | **Viable** | Framework-level work, independent of transport and database. The exact decoder mechanism is selected by a RED corpus, not assumed. |
| Concurrent synchronous handlers | **Viable, gated** | The vendored server already supports multiple event-loop threads. Druse must remove its own shared-state races and prove liveness before exposing the mode. |
| PostgreSQL driver, bounded pool and transactions | **Viable, gated** | Odin implementations demonstrate protocol viability. WP74 chooses reuse, extraction, `libpq` or a local implementation by evidence. No arm is assumed free. |
| Safe migration runner | **Viable** | It is a separate deploy tool and does not depend on the HTTP scheduler. |
| Optional SQL/schema checker | **Viable** | It runs in development/CI and need not generate runtime code. |
| “A blocked handler can never affect another request” | **Not honestly promiseable** | One blocked handler stalls its event-loop lane, and exhausting every lane stalls the process. The guarantee is bounded blast radius plus fail-fast capacity, not magic. |
| Seamless future `core:net/http` migration | **Viable as an architectural constraint** | Framework semantics and conformance tests can be kept transport-neutral now. The unavailable adapter itself cannot be implemented or promised yet. |

The concurrency target is not a generic worker pool and not Tina's scheduler.
It is the smallest change supported by today's transport: **several independent
event-loop lanes, each invoking ordinary synchronous handlers**. A blocking
operation occupies one lane instead of the whole process. All connections
owned by that lane may pause, which is measured and documented rather than
hidden.

---

## 1. What Phase 6 is for

Phase 5 makes the first week of an application possible: drain, CORS, static
files and bounded in-memory multipart uploads. Phase 6 makes the first **real CRUD service**
possible without asking the user to invent an execution model and a database
operations discipline.

The problems are concrete:

- a synchronous blocking call in the current one-lane server stops unrelated
  requests and can defeat graceful shutdown;
- `web.body` does not yet have a complete client-error taxonomy for valid JSON
  whose shape does not match the destination;
- the project has an application-state slot but no canonical resource
  lifecycle for pools and services;
- database integration has no accepted timeout, cancellation, pool,
  transaction, row-decoding or migration contract;
- the future official HTTP package has no released API against which code can
  be written, so waiting for it would suspend useful product work for an
  unknown interface.

Phase 5 also left two explicit product boundaries that this phase inherits:

- multipart files are request-lifetime views over the fully buffered body; no
  temporary-file spool exists;
- optional feature code must not link into applications that do not use it.
  WP61 measured and corrected a 20,176-byte static-server leak into Hello World;
  the final no-feature delta was 3,680 bytes of configuration/pointer storage,
  with executable static-serving code linked only by users of `static`.

The desired user experience is deliberately conventional:

```odin
state, init_err := application.init(config)
if init_err != nil {
    // log and exit before opening the listener
}
defer application.destroy(&state)

app := web.app_with_state(&state)
web.post(&app, "/users", create_user)
web.serve(&app, config.address, config.limits)
```

Inside a handler, a database call remains synchronous:

```odin
user, db_err := users.find(state.db, id)
if db_err != nil {
    // translate the domain result at the HTTP boundary
}
web.ok(ctx, user)
```

No futures, callbacks, channels, request continuations or hidden dependency
container enter the common path.

---

## 2. Decisions the owner must record in WP66

WP66 does not silently reinterpret existing ADRs. It records dated owner
amendments before code.

### D6-1 — Phase-6 product scope

The demand-driven condition is waived for the class **“first real application”**:
honest request decoding, concurrent blocking dependencies, PostgreSQL,
migrations and the reference CRUD app. The reason is the same circularity as
the Phase-5 table-stakes amendment: at zero users, waiting for external demand
for the capability required to build a real user application is an
unsatisfiable gate.

The waiver does **not** extend to an ORM, Active Record, GraphQL, WebSocket,
streaming, HTTP/2, OpenAPI generation, in-process TLS or a general-purpose job
system.

### D6-2 — ADR-030 is reopened by a different workload

ADR-030's Phase-4 result remains valid for the workload it measured: adding
threads did not produce a trustworthy throughput win above the harness noise.
Phase 6 introduces a different, falsifiable question:

> While one request is deliberately blocked in an external dependency, can an
> independent health request complete before that dependency is released?

This is a liveness property, not a req/s claim. Failure of the one-lane arm and
success of the multi-lane arm are enough to reopen the decision even if peak
throughput is unchanged.

The target arm is multi-lane synchronous serving, but it only ships if WP69's
lab and WP72's fault gate pass. If they do not, the phase records the evidence
and refuses the concurrency surface instead of inventing an asynchronous API
under schedule pressure.

### D6-3 — Concurrent handlers are a semantic change

After the concurrent mode is enabled, separate handlers may execute at the
same time. Registration remains single-threaded and forbidden after serving
begins. The compiled route and middleware snapshot is immutable while serving.

`App_State` remains application-owned and shared. The framework does not
pretend it can make arbitrary user state thread-safe. Mutable shared fields
must be protected or encapsulated by thread-safe services; immutable config is
safe to share. This contract is documented in the public migration notes.

WP71 decides, with owner approval, whether the first release defaults to one
lane for compatibility or to an automatically derived count for conventional
web-framework behaviour. In either case, the public setting describes
**handler concurrency**, not “number of odin-http threads”, so a future adapter
can honor the same intent with another mechanism.

### D6-4 — Core and Crystals stay separate

The following belong to `web` because they define HTTP/application semantics:

- JSON error classification and response shape;
- thread safety of framework-owned state;
- the transport-neutral handler-concurrency setting and diagnostics;
- conformance tests every transport adapter must pass.

The following belong to the Crystals ecosystem and may depend on `web`, while
`web` never depends on them:

- PostgreSQL;
- SQL helpers and query checking;
- migrations;
- domain validation and the thin HTTP validation adapter;
- the reference database application.

CE-E3 remains intact: no Crystal adds, widens or changes a core symbol. The
first Crystal remains the previously required health Route Crystal; the data
stack starts only after that dependency direction is proven.

### D6-5 — SQL-first, not ORM-first

The accepted direction is explicit SQL, positional bindings, explicit row
decoding, typed errors, explicit transactions and a separate migration tool.
Optional verification may connect to a disposable PostgreSQL instance in CI.

The phase explicitly refuses Active Record, lazy loading, automatic
associations, implicit transactions, pluralization, updates that silently
ignore zero values, `UPDATE`-to-`INSERT` fallback, production auto-migration,
mandatory code generation and a DI container.

### D6-6 — The unavailable official HTTP package is not a gate

No Phase-6 symbol may expose odin-http records, operations or thread types.
Vendor changes are documented as a bridge. When `core:net/http` becomes
available, it receives its own adapter spike and must pass the same semantic,
raw-wire, liveness and shutdown corpus before becoming eligible to replace the
current adapter.

No speculative `core:net/http` compatibility shim is written against an API
that does not exist.

---

## 3. Architectural invariants

These are phase-wide gates, not suggestions.

### 3.1 Serving and concurrency

- setup, route registration, middleware composition and runtime derivation
  happen before serving and on one thread;
- serving reads an immutable route/middleware snapshot;
- framework counters and lifecycle flags used across lanes are atomic or
  lane-owned;
- request `Context`, arena, params, body views and response scratch remain
  request-local and never migrate between lanes;
- no request-backed view may escape the handler without an explicit copy;
- response commit remains exactly once;
- request IDs remain unique under concurrent generation;
- stop prevents new admission, wakes every lane and joins every lane exactly
  once;
- `max_drain_time` bounds cancellable framework/transport work, but cannot
  preempt arbitrary user code stuck forever. That limitation remains explicit.

### 3.2 Capacity and backpressure

Every queue or pool introduced in this phase has:

- a hard capacity;
- a named owner;
- a bounded or fail-fast full policy;
- an observable exhaustion result;
- cleanup tests on every error path.

A database pool may never solve saturation by allowing an unlimited queue of
handlers to wait for a connection. The canonical reference deployment keeps
database concurrency below handler-lane capacity and uses a short bounded
acquire deadline or immediate refusal. This preserves capacity for health,
shutdown and non-database work without teaching `web` about PostgreSQL.

### 3.3 Database ownership

- the application owns the pool and places it in `App_State`;
- the HTTP framework does not open, migrate or close a database;
- a pool owns its physical connections;
- a transaction exclusively borrows one connection until commit/rollback;
- rows own or clearly borrow their decode buffers; the lifetime is documented;
- SQL `NULL` maps to an explicit optional type, never a zero-value convention;
- a decode mismatch is a typed error, never silent zero substitution;
- raw SQL text, bound values, credentials and personal data do not enter
  default diagnostics.

### 3.4 Errors

Database infrastructure speaks in a database vocabulary. Domain services
speak in a domain vocabulary. The HTTP layer performs the final translation.

At minimum the database error model distinguishes:

- not found where the operation defines it;
- unique and foreign-key violations;
- serialization/deadlock failure;
- connection and protocol failure;
- pool exhaustion;
- timeout and cancellation;
- row/column decode failure;
- unknown failure.

It preserves SQLSTATE when available, a safe operation/query name and an Odin
source location. It does not decide that a database condition is HTTP 404 or
409.

### 3.5 Transport replacement

The adapter boundary continues to mean:

```text
accept → normalize request → dispatch → commit response → stop
```

The concurrency contract is expressed as observable behaviour:

- maximum simultaneous handler executions;
- independent-request liveness;
- admission and shutdown semantics;
- ownership of request and response memory.

It is not expressed as io_uring operations, odin-http `Connection` fields or a
particular thread topology.

### 3.6 Pay only when used

Phase 5 established the executable-cost precedent by catching static serving
linked into Hello World. Phase 6 inherits it:

- a program with no database imports links no PostgreSQL, migration, validation
  or SQL-checker code by construction;
- one-lane and multi-lane Hello World binaries are measured separately;
- JSON boundary improvements may change code already used by `web.body`, but
  cannot pull optional Crystals or tooling into `web`;
- every unavoidable base-layout/configuration cost is named and measured;
- “zero cost” means a stated perimeter — symbols, executable bytes,
  allocations or hot-path branches — never a slogan.

---

## 4. What the Tina study changes — and what it does not

The relevant Tina documents were reviewed as architectural evidence, especially
`01-arquitetura-do-runtime.md`, `02-memoria-ownership-e-backpressure.md`,
`03-io-scheduler-e-lifecycle.md`, `08-comparacao-com-druse.md`,
`09-propostas-para-o-planejamento.md`, `10-limitacoes-e-questoes-abertas.md`
and `11-impacto-no-roadmap-do-druse.md`.

Tina proves useful facts:

- thread-per-core and synchronous-looking work are viable in Odin;
- immutable boot-derived state reduces shared mutation in the hot path;
- capacity must reserve a route for control and shutdown;
- ownership, state transitions and stale completions need explicit tests;
- a deterministic simulated backend is more valuable than an unrepeatable
  benchmark;
- transport and framework can cooperate without sharing a public API.

It does **not** prove that Druse should adopt Tina, its isolates, scheduler,
Grand Arena, message protocol, recovery model or HTTP server. The Tina dossier
itself requires each borrowed idea to begin with a demonstrated Druse
problem and a differentiating RED test. This plan follows that rule.

The multi-lane design is therefore not “copy Tina”. It is the smallest current
transport change that makes the demonstrated blocking-I/O failure local rather
than process-wide.

---

## 5. Entry conditions

| ID | Condition |
|---|---|
| E6-1 | **Met:** Phase 5 frozen at `6b6edbc`; complete gate green; ledger 62 + 2 = 64. WP66 verifies the exact entry commit again. |
| E6-2 | **Initial refresh applied:** static, CORS and in-memory multipart shipped; drain deadline and recv cancellation shipped; ADR-033 closed keep-and-patch with transition as exit; large uploads, ranges and `Last-Modified` were not delivered. WP66 checks for later amendments. |
| E6-3 | The owner amendments in §2 are recorded in `planning/decisoes-do-dono.md`, `planning/adrs.md`, `planning/roadmap.md` and any contradicted future-phase plan. |
| E6-4 | The stale Crystals draft is reconciled with ADR-032; ADR-C documents needed for the first Crystal are accepted or explicitly replaced before ecosystem code. |
| E6-5 | A pinned PostgreSQL version and an isolated test-database lifecycle are available locally. Destructive migration tests may target only that disposable database. |
| E6-6 | The current Odin toolchain and transport snapshot are pinned. No phase result depends on an unreleased `core:net/http` API. |

---

## 6. Work-package map

| WP | Name | Type | Main output |
|---|---|---|---|
| 66 | Phase-6 spec and governance amendments | SPEC | accepted scope, ADR reopening, refreshed dependencies |
| 67 | JSON failure anatomy | TESTS | committed RED corpus for client/programmer/decoder failures |
| 68 | Honest request decoding | IMPLEMENTATION | stable 400/500 taxonomy and structured field paths |
| 69 | Blocking-I/O and concurrency laboratory | PROTOTYPE | one-lane vs multi-lane liveness evidence |
| 70 | Thread-safe framework core | IMPLEMENTATION | immutable serving snapshot and race-free core-owned state |
| 71 | Concurrent synchronous serving | IMPLEMENTATION | transport-neutral concurrency setting mapped to current lanes |
| 72 | Concurrency, shutdown and Phase-5 feature gate | TESTS + ADR | accepted/rejected ADR-030 amendment with full fault evidence |
| 73 | Crystals boundary and first Route Crystal | SPEC + IMPLEMENTATION | refreshed charter and `crystals:web/health` proof |
| 74 | PostgreSQL contract and driver selection | SPEC + PROTOTYPE | selected driver arm and frozen behavioural contract |
| 75 | PostgreSQL wire/error laboratory | TESTS | RED protocol, TLS/auth, cancellation and error corpus |
| 76 | PostgreSQL execution and row decoding | IMPLEMENTATION | connection, bind, execute/query and fail-closed decoding |
| 77 | Bounded pool, timeout and cancellation | IMPLEMENTATION | hard capacity with bounded acquisition and query cancellation |
| 78 | Explicit transactions | IMPLEMENTATION | one-connection transaction lifecycle and failure rules |
| 79 | Migration contract | SPEC + TESTS | immutable history, lock, checksum, dirty-state RED corpus |
| 80 | Migration runner | IMPLEMENTATION | separate executable; status, dry-run and apply |
| 81 | Validation, optionality and PATCH semantics | SPEC + IMPLEMENTATION | transport-free validation and absent/null/value model |
| 82 | Optional SQL/schema checker | TOOL | CI-time query verification without required generation |
| 83 | Real PostgreSQL reference application | INTEGRATION | CRUD, constraints, pagination, transaction, liveness and deploy path |
| 84 | Documentation and Phase-6 freeze | DOCS + FREEZE | operations guide, claims, ledgers and complete gate |

### Dependency graph

```text
WP65
  └─ WP66
      ├─ WP67 → WP68
      ├─ WP69 → WP70 → WP71 → WP72
      └─ WP73 → WP74
                  ├─ WP75 → WP76 → WP77 → WP78
                  └─ WP79 → WP80

      {WP68, WP73} → WP81
      {WP76, WP80} → WP82
      {WP68, WP72, WP78, WP80, WP81, WP82} → WP83 → WP84
```

WP79 may begin after WP74's database contract and test harness are stable; it
does not need to wait for every convenience in WP78. WP82 is explicitly
optional capability: failure to find a sound checker mechanism may yield a
documented refusal without blocking the runtime data stack or WP83.

---

## 7. Work packages

### WP66 — Phase-6 spec and governance amendments

**Files:** this plan, `planning/phase-6-spec.md`, `planning/adrs.md`,
`planning/decisoes-do-dono.md`, `planning/roadmap.md`,
`planning/later-phases-plan.md`, `planning/open-questions.md`.

Record D6-1–D6-6, refresh this draft against WP65 and specify every threshold
before the first prototype run. Reconcile the earlier claim that database work
does not justify concurrency: that claim remains true for peak-throughput
folklore but not for the independent-request liveness test.

The spec defines the terms **lane**, **blocking dependency**, **bounded
acquisition**, **request-local**, **serving snapshot** and **transport
conformance** so later WPs do not use “worker” to mean three different things.

No ledger growth and no implementation.

**Rollback:** HIGH — documents only.

### WP67 — JSON failure anatomy

**Files:** `tests/wp67-json-boundary/`, a control script and a small experiment
only if the Odin JSON package's error information must be characterized.

Commit RED tests for:

| Input/result | Required HTTP classification |
|---|---|
| malformed JSON | `400 invalid_json` |
| valid JSON, wrong field type | `400 invalid_field` |
| valid JSON, nested mismatch | `400 invalid_field` with stable field path |
| unknown field under strict policy | `400 unknown_field` |
| explicitly required field absent | `400 missing_field` |
| value outside a declared validation rule | `400 invalid_field` |
| unsupported destination/programmer misuse | `500 internal_error` plus safe diagnostic |
| decoder allocator/internal failure | `500 internal_error` plus safe diagnostic |

Unknown fields are rejected by the canonical strict path. Requiredness is
declared; it is never inferred from a zero value. The wire response contains a
stable code and field path but no Odin type name, source file or raw body.

A negative control must prove that the 500-to-400 change is caused by the
framework classification and not by a test transport special case.

**Rollback:** HIGH — tests only.

### WP68 — Honest request decoding

**Files:** the smallest request-decoding module, error response policy,
public-surface tests, docs and ledger amendments if a new public concept is
unavoidable.

Implement the WP67 taxonomy. Prefer the Odin standard decoder when it exposes
enough structured information. If it does not, compare a `json.Value`-based
preflight with a thin bounded decoder; do not fork a complete JSON parser by
default.

**WP67 evidence amendment.** The stdlib exposes no field stack, skips unknown
fields, has no required/validation vocabulary and can silently lose allocation
failure. WP68 therefore makes the decoder suite green for malformed/type/path,
unknown and internal failure. The separately committed required/range suite
stays RED-under-control until WP81 chooses schema and optionality; probe tags
are not an API decision.

The common API remains small. A mode flag is not added for every decoder
choice. Strict decoding is canonical; a permissive alternative exists only if
a real compatibility case and all eight G-09 evidences justify it.

This WP also documents four distinct states needed by later validation:

- missing field;
- present with zero value;
- present as JSON `null`;
- present with a non-null value.

It does not yet place a generic `Patch(T)` abstraction in `web`.

**Rollback:** MEDIUM — public behaviour changes; signatures should remain
stable unless the spec proves otherwise.

### WP69 — Blocking-I/O and concurrency laboratory

**Files:** `experiments/15-blocking-boundary/`,
`tests/wp69-concurrency-lab/`, controls and recorded results.

Compare:

1. current one-lane event loop;
2. several event-loop lanes using the vendored server's existing capability;
3. only as a documented comparison, event loop plus deferred job pool.

Arm 3 is not an implementation candidate unless the first two are falsified;
the current callback/response lifetime does not support returning after a
handler without a large transport-contract change.

Use a deterministic latch before PostgreSQL so the result cannot be blamed on
a driver. The decisive test starts a blocking request, waits until it has
entered the latch, sends `/health`, and requires `/health` to complete before
the latch is released. Repeat with one through `lanes - 1` blocked handlers.

Measure, without turning noise into claims:

- which connections share the blocked event-loop lane;
- health latency and success;
- idle keep-alive behaviour;
- slow reader and slow writer behaviour;
- memory per lane and per connection;
- drain and stop behaviour;
- fairness across lanes;
- startup and teardown repeatability.

The acceptance condition is liveness ordering, not a percentage throughput
gain. Record the losing arm and the remaining saturation boundary.

**Rollback:** HIGH — prototype and tests only.

### WP70 — Thread-safe framework core

**Files:** request-ID generation, dispatch/miss-chain compilation, lifecycle
state, adapter globals, app serving snapshot and concurrency tests.

Resolve the known Phase-4 blockers and every race newly found by WP69:

- request-ID counter;
- lazy `miss_built` construction;
- shared `dispatched`/registration state;
- any remaining cross-thread server pointer or stop flag;
- framework observers and metrics that mutate shared state.

Prefer ownership and immutability over mutexes in the hot path. Build all
route/middleware/miss structures before lanes start. Publish one immutable
snapshot. Atomics are for genuinely shared counters and state transitions,
not a substitute for an ownership model.

Run thread sanitizer where the Odin/C toolchain supports it, plus a deterministic
high-contention corpus where it does not. Application-owned `App_State` is out
of the framework's race-free claim and is covered by explicit documentation.

**Rollback:** MEDIUM — internal concurrency changes, no public feature yet.

### WP71 — Concurrent synchronous serving

**Files:** `web/limits.odin` or the final configuration home, transport boundary,
odin-http adapter, public-surface evidence and migration documentation.

Expose the smallest transport-neutral setting for maximum concurrent handler
execution. Map it to the current adapter's lane/thread count. Validate at boot:

- zero/auto semantics, if any, are unambiguous;
- negative and impossible values fail before the listener opens;
- unsupported adapters fail explicitly rather than silently running one lane;
- an explicit one-lane mode remains available for deterministic tests and
  applications with deliberately single-threaded state.

Do not expose affinity, io_uring queues, odin-http thread records or per-lane
event-loop objects. Those remain adapter details.

The default is decided here from compatibility, ergonomics and WP69 evidence,
then recorded as an owner amendment. Since the project has no established
user base yet and Gin-like frameworks execute handlers concurrently, the
recommended default is an automatically derived bounded count, with `1` as an
explicit compatibility mode. This recommendation is withdrawn if WP72 cannot
prove the safety gates.

**Rollback:** MEDIUM — new execution behaviour; ledger cost is preferably zero
if expressed as a field on an existing configuration type, but all G-09
evidences still apply to the field.

### WP72 — Concurrency, shutdown and Phase-5 feature gate

**Files:** `tests/wp72-concurrent-serving/`, fault-lab extensions,
`planning/phase-6-concurrency.md` and the ADR-030 amendment.

The gate must cover together:

- unique request IDs under contention;
- route hit, 404, 405 and middleware order;
- registration rejected after serving starts;
- app stop called concurrently and repeatedly;
- `max_drain_time` across every lane;
- pending read cancellation and the WP59 use-after-free regression;
- CORS, static files and uploads/multipart from Phase 5;
- 3,000 idle keep-alive connections;
- slow clients and slow writers;
- one through `lanes - 1` blocked database-like calls while health remains
  live;
- full lane saturation reported as a documented capacity boundary;
- allocator tracking and seeded repeated startup/shutdown.

An arbitrary handler stuck in non-cancellable foreign code may outlive the
drain deadline. The gate must distinguish that honest limitation from a
framework or database operation that claims cancellation but fails to obey it.

ADR-030 is amended only if this gate passes. Otherwise the multi-lane surface
is refused and the phase returns to the owner before database integration.

**Rollback:** HIGH for tests/ADR; MEDIUM for reverting the gated feature.

### WP73 — Crystals boundary and first Route Crystal

**Repository:** the accepted Crystals repository/collection, not `web`.

Refresh the stale ecosystem plan and discharge ADR-032's first-package rule by
shipping the smallest `crystals:web/health` Route Crystal. It proves:

- a Crystal depends one-way on a pinned Druse core revision;
- the core build and public ledger do not depend on Crystals;
- package ownership, versioning, support and release metadata exist;
- a Crystal has its own public ledger, examples and gate;
- route mounting does not require a new core symbol.

This is intentionally before PostgreSQL. If the repository boundary cannot
ship one trivial package cleanly, it is not ready to own a database driver.

**Rollback:** HIGH — separate package and governance; no core change.

### WP74 — PostgreSQL contract and driver selection

**Files/repository:** Crystals planning/ADR documents and isolated prototypes.

Evaluate four arms without assuming “pure Odin” automatically wins:

1. adopt an existing maintained Odin driver;
2. extract and audit a suitable pure-Odin implementation;
3. wrap `libpq` behind the Crystal contract;
4. implement the minimum PostgreSQL v3 subset locally.

The selection matrix includes:

- license and maintainer risk;
- supported platforms and build reproducibility;
- thread safety and connection ownership;
- protocol framing and maximum message limits;
- TLS client support, CA/hostname verification and optional client certificate;
- SCRAM-SHA-256 and explicitly accepted legacy auth policy;
- extended query protocol and parameter bindings;
- server-side cancellation and local deadlines;
- SQLSTATE and safe diagnostics;
- prepared-statement lifecycle;
- shutdown and broken-connection recovery;
- testability against a real pinned PostgreSQL server.

If no arm can satisfy authentication, cancellation and fail-closed parsing
without an unauditable dependency, WP74 may refuse the driver. It must not
silently narrow the production security contract to make the schedule pass.

No public API is frozen until this WP concludes.

**Rollback:** HIGH — spec/prototype only.

### WP75 — PostgreSQL wire/error laboratory

**Files:** driver integration tests, disposable PostgreSQL harness, malformed
server/proxy fixture where necessary, controls and recorded versions.

Commit RED tests for:

- startup/auth success and failure;
- SCRAM and TLS verification policy selected by WP74;
- partial/truncated/oversized protocol messages;
- parameter separation from SQL text;
- SQLSTATE mapping;
- connection loss before, during and after a query;
- query timeout and PostgreSQL cancellation;
- cancellation race with a completed query;
- malformed/unexpected column metadata;
- `NULL` versus zero/empty values;
- decode overflow and type mismatch;
- cleanup when the client disconnects and during application stop.

The harness owns a dedicated database. It never points destructive tests at a
developer-provided arbitrary DSN. PostgreSQL image/version and schema are
pinned and reported.

**Rollback:** HIGH — tests only.

### WP76 — PostgreSQL execution and row decoding

Implement the minimum selected contract:

- open and close one connection;
- execute a statement;
- query zero, one or many rows;
- positional bound parameters;
- named operation/query identifier for diagnostics;
- typed error with SQLSTATE and source location;
- explicit row iteration/decoding;
- prepared statement support only if WP74 proves the lifecycle.

No operation that can fail returns only `bool`. A row whose value cannot be
decoded into the requested Odin type fails with column, field and expected-type
metadata safe for logs. It never leaves a zero value and continues.

SQL `NULL` uses Odin's existing optional representation if it satisfies the
contract; a new `Maybe(T)` symbol is introduced only if the language type is
insufficient and the Crystals ledger pays for it.

**Rollback:** MEDIUM — new Crystal public API, isolated from core.

### WP77 — Bounded pool, timeout and cancellation

Add a hard-capped thread-safe pool around WP76. The contract includes:

- minimum/maximum open and idle connections;
- boot-time validation and optional connectivity/readiness check;
- bounded acquire time with a typed `Pool_Exhausted`/timeout result;
- no unlimited waiter queue;
- broken connections discarded, never returned as healthy;
- idle/lifetime recycling with deterministic tests;
- query deadline and explicit cancellation;
- close rejects new borrows and waits/cancels existing work by policy;
- counters available for safe observability without leaking DSNs.

The canonical configuration keeps `max_connections` below handler-lane
capacity. The reference app proves that a blocked PostgreSQL query does not
prevent health or stop from progressing, and that excess database demand
fails quickly instead of consuming every lane while waiting for the pool.

**Rollback:** MEDIUM — new Crystal public API and lifecycle.

### WP78 — Explicit transactions

Provide one canonical transaction pattern:

```odin
tx, err := db.begin(pool, options)
if err != nil { /* ... */ }
defer db.rollback_if_open(&tx)

// all operations use tx's one borrowed connection

err = db.commit(&tx)
```

Specify isolation, read-only mode, commit/rollback idempotence, failed
transaction state, nested-transaction refusal or savepoint support, timeout,
cancellation and what happens when the connection breaks. A transaction may
not return its connection to the pool until its terminal state is known.

No implicit per-request transaction and no hidden retry. A helper for
serialization retries is considered later only with an idempotence contract.

**Rollback:** MEDIUM — new Crystal public API.

### WP79 — Migration contract

**Repository:** one transport-free migration engine Crystal, consumed by a
separate Tool Crystal and, when the application opts in, by an explicit call
in its composition root before `web.serve`. The engine never imports `web`.

Specify and commit RED tests for:

- monotonically ordered immutable migration IDs;
- content checksum and refusal after an applied file changes;
- PostgreSQL advisory lock so two runners cannot apply concurrently;
- one migration at a time;
- transaction by default;
- explicit `no_transaction` for operations PostgreSQL forbids in a transaction;
- applied/failed/dirty history with timestamp, duration and tool version;
- refusal on dirty state;
- refusal by default when history contains an applied ID absent from the
  binary/directory manifest (the database is ahead of this application);
- `up`, `status` and `dry-run`;
- a forward-only canonical surface with no `down` or `force` command in the
  first release;
- equivalent manifests loaded from a directory or declared by the application
  with SQL embedded through `#load`;
- identical behaviour from the CLI and an explicit pre-serve application call;
- deploys with mixed application versions documented as an application
  compatibility responsibility.

The application may deliberately run `migrate.up` after initializing its
database dependency and before constructing/serving HTTP. This is the
first-class self-hosted/small-installation path: one artifact can own its SQL,
take the advisory lock, fail closed, and serve only after success. It is not
AutoMigrate: importing a package, constructing an App or calling `web.serve`
has no migration side effect.

The CLI calls the same engine and remains first-class for SaaS, rolling deploys,
separate DDL credentials and work that outlives a normal startup deadline.
Neither path is labelled the “serious” one. The operational topology chooses.

Forward-only is safe only with **expand-contract** discipline. Additive schema
lands before code requires it; old readers/writers stop using a field in a
later deploy; destructive removal happens in a still later migration. WP79
must document that a strict ahead-of-binary refusal can deliberately prevent
an old binary from restarting after a newer schema lands, and that rolling
deploys therefore require compatible migrations and explicit coordination.

One transaction per migration remains the canonical baseline: every committed
ID is independently clean and resumable. WP79 may prototype an explicit
atomic-batch policy for a wholly transactional pending set, but cannot imply
batch atomicity across `no_transaction` work. Development schema sync/diff is
a separate future convenience, not production migration.

**Rollback:** HIGH — spec and tests only.

### WP80 — Migration runner

Implement WP79 as a transport-free engine plus a separate executable/package.
The executable and explicit pre-serve integration call the same procedures.
The engine acquires the advisory lock, validates the entire history fail-closed,
applies one migration, records the result atomically where PostgreSQL permits,
and returns a typed failure; the executable exits non-zero on every refusal or
failure.

The gate runs two concurrent processes against the disposable database,
mutates an already-applied file, simulates a failed non-transactional migration
and proves the database is never reported clean when state is uncertain.

No `force` or `down` command ships in the first surface. Recovery from dirty
state is a documented operator procedure requiring an explicit database
inspection.

**Rollback:** MEDIUM — separate deploy tool.

### WP81 — Validation, optionality and PATCH semantics

Create transport-free value validation and a thin HTTP translation package.
Do not place domain rules in `web`.

The model distinguishes:

- optional database value: null or value;
- create input: absent/required according to a declared schema;
- patch input: absent, explicit null or value;
- domain validation failure versus decoder failure.

A `Patch(T)`-like type is justified by the three-state wire contract, not by
ORM convenience. Validation errors carry stable rule codes and field paths.
The HTTP adapter maps them to the Phase-6 error envelope without teaching the
validation package about status codes.

Reflection, if used, stays outside the hot path and fails closed on unknown or
contradictory tags. Unknown flags, duplicate names and incompatible nullable
declarations are errors, never ignored annotations.

**Rollback:** MEDIUM — new Crystal APIs; core receives at most documentation
and conformance tests.

### WP82 — Optional SQL/schema checker

Build a development/CI tool that can:

1. create/use the dedicated disposable database;
2. apply WP80 migrations;
3. prepare named queries;
4. compare parameter and result metadata with declared expectations;
5. exit non-zero with safe diagnostics.

The runtime application continues to execute explicit SQL without generated
code. Generation may be offered later as an optional accelerator, never a
requirement to use PostgreSQL.

Dynamic SQL beyond what PostgreSQL can prepare statically is reported as
unchecked rather than falsely certified. If the checker cannot provide useful
evidence without becoming a mandatory compiler/code generator, this WP records
the refusal and does not block the rest of Phase 6.

**Rollback:** HIGH — optional tool only.

### WP83 — Real PostgreSQL reference application

This is the design test, not decorative documentation. Build a deployable
example that demonstrates:

- explicit application initialization and destruction;
- pool in `App_State`;
- create/read/update/delete;
- strict JSON and structured validation errors;
- SQL `NULL` and three-state PATCH;
- unique-constraint conflict;
- a multi-statement transaction;
- pagination with stable ordering;
- the same migrations run through a separate deploy command and an explicit
  pre-serve path, with no implicit `web` hook;
- integration tests against pinned PostgreSQL;
- one deliberately blocked query while `/health` remains responsive;
- query cancellation and bounded pool exhaustion;
- graceful shutdown with active and idle database work;
- logs/metrics that expose query name and result class, never SQL parameters.

The example must remain readable to a user arriving from Gin: explicit, short
and conventional names (`insert`, `select`, `update`, `delete`, `begin`,
`commit`, `rollback`). No mythology or framework-specific vocabulary in the
fundamental data API.

If the example needs repeated unsafe escape hatches, hidden globals or more
boilerplate than the framework's stated joy-of-programming goal permits, that
is a design failure and feeds amendments back to the owning WP before freeze.

**Rollback:** HIGH — example/integration package; it validates earlier APIs.

### WP84 — Documentation and Phase-6 freeze

Update operations, AI context, canonical patterns, README, Crystals docs and
the phase freeze. Document:

- concurrent-handler semantics and `App_State` responsibility;
- the exact blast radius of a blocked lane;
- lane and database-pool capacity planning;
- what query cancellation can and cannot stop;
- database/TLS/auth support matrix;
- migration deploy sequence and dirty-state recovery;
- explicit SQL and transaction patterns;
- JSON/validation error contract;
- the future transport replacement procedure;
- all refused/non-delivered items and why.

Re-run every historical control script affected by concurrency or decoding,
the full core gate, every Crystals gate, sanitizer/fault runs, migration
concurrency tests and the real application suite.

Record separate ledgers:

- the `web` application/test-support ledger, expected to grow minimally;
- the Crystals public ledger, owned by the ecosystem repository;
- claims, lifetimes and capacities introduced in this phase.

Freeze only if all required WPs pass. WP82 may be recorded as a legitimate
optional-tool refusal; concurrency, PostgreSQL runtime safety, migrations and
the reference application are not optional exit items.

**Rollback:** HIGH — documents/gates; no new implementation.

---

## 8. Phase gates

### G6-A — Independent-request liveness

With one through `lanes - 1` handlers stopped at a deterministic latch, a
health request must complete before the latch is released. At full lane
saturation, the system must exhibit the documented bounded failure mode; the
test may not describe queueing forever as “eventual success”.

### G6-B — Concurrency correctness

No duplicate request IDs, mutable serving structures, response double-commit,
use-after-free, cross-request arena view, startup/shutdown race or sanitizer
finding in the exercised corpus. Same seed, same fault schedule, reproducible
result.

### G6-C — Honest input boundary

Every WP67 class maps to the specified stable code and 400/500 family. No
client shape error becomes 500; no programmer/internal error is disguised as
400; bodies and type internals are not leaked.

### G6-D — Database backpressure

A slow query occupies at most its connection and serving lane. Pool exhaustion
is bounded and typed. Excess waiting cannot consume unbounded memory or every
lane. Health and stop remain live under the canonical capacity relationship.

### G6-E — Database correctness

Bound parameters never enter SQL structure, row mismatches fail closed,
SQLSTATE is preserved, transaction connection ownership is exclusive, broken
connections are quarantined and cancellation races are covered.

### G6-F — Migration safety

Only one runner applies at a time; changed history and dirty state refuse;
transactional failure rolls back; non-transactional uncertainty cannot be
reported clean; ahead-of-binary history refuses by default; directory and
embedded manifests agree; `web` never initiates migration, while the explicit
application pre-serve path and CLI share one engine.

### G6-G — Transport replaceability

No new public signature names odin-http. The in-memory and current real adapter
pass the shared semantic corpus. The future adapter checklist is written but
contains no invented official API.

### G6-H — Real application

The WP83 application builds, migrates, passes integration tests and demonstrates
the concurrency/database guarantees from a fresh checkout with pinned tools.

### G6-I — Unused feature cost

The frozen Phase-5 Hello World is rebuilt as the control. It imports no data
Crystal and links none of their executable code. Concurrent-serving base cost,
if any, is measured and entered in the cost ledger; optional database,
migration, validation and checker code remains outside the core binary.

---

## 9. Public-surface and ledger budget

The core should grow very little in this phase.

- JSON improvements should prefer stable error codes and existing response
  mechanisms over a family of public error structs.
- Handler concurrency should prefer a field on the existing limits/config
  contract over adapter-specific functions.
- No database type enters the `web` ledger.
- Every Crystal owns a separate explicit ledger and pays the equivalent of
  G-09: distinct concept, common need, one way, short example, ownership,
  diagnostics, tests and removal cost.

The starting count is now known: **62 application + 2 test-support**. WP66
records a growth estimate from that base and WP84 records the actual count.
Database/validation Crystals never enter the core ledger.

---

## 10. Verification strategy

The exact commands are fixed in WP66 after Phase 5 freezes, but the required
layers are already known:

1. existing full Druse gate on the pinned Odin toolchain;
2. public-surface and example gates;
3. deterministic concurrency lab with explicit seeds;
4. thread sanitizer or the strongest supported equivalent;
5. raw-wire/fault corpus on one and multiple lanes;
6. disposable pinned PostgreSQL integration suite;
7. two-process migration-lock and dirty-state suite;
8. reference-app end-to-end suite;
9. repeated startup, cancellation, drain and teardown with allocator tracking;
10. paired performance runs only where a performance claim is made.

No req/s claim is accepted from the Phase-4 noisy harness without a methodology
that first establishes a lower noise floor. Liveness ordering and safety tests
do not need to pretend to be throughput benchmarks.

---

## 11. Explicit non-goals

- no GORM clone, Active Record or full ORM;
- no DI container;
- no mandatory code generation or reflection-heavy runtime;
- no automatic migration at server boot;
- no implicit transaction or automatic write retry;
- no generic asynchronous handler/continuation API;
- no Tina dependency, isolate API, scheduler or panic recovery;
- no rewrite of the HTTP parser/server;
- no speculative official `core:net/http` adapter;
- no in-process TLS server, HTTP/2, HTTP/3, WebSocket, streaming or OpenAPI in
  this phase;
- no claim that reverse proxies make outbound database TLS unnecessary;
- no claim that multiple lanes make arbitrary blocking code cancellable.

---

## 12. The stopping rules

The phase stops and returns evidence to the owner if any of these occurs:

1. multi-lane serving cannot pass the Phase-5 semantic/fault corpus without a
   public transport leak or an uncontained vendor rewrite;
2. framework-owned state cannot be made race-free while preserving the
   synchronous Handler contract;
3. no PostgreSQL driver arm can provide secure authentication, fail-closed
   framing and cancellation with acceptable maintenance ownership;
4. the pool can preserve liveness only through unbounded waiting;
5. migration history can be reported clean after an uncertain failure;
6. the reference app requires `web` to know about PostgreSQL;
7. the future-transport constraint forces guesses about an unreleased API.

A stopped WP is not a failed phase process. Shipping a concurrency knob,
database pool or migration command that lies about its guarantees would be.

---

## 13. Expected outcome

At the end of Phase 6, a user should be able to build an ordinary PostgreSQL
API in Odin with the same conceptual ease expected from a mature web
framework, while retaining Druse's differentiators:

- memory and ownership are visible;
- capacities are bounded;
- failures are typed and diagnosable;
- SQL stays explicit;
- migrations fail closed;
- lifecycle is owned by the application;
- blocking work has a measured, bounded blast radius;
- the HTTP transport remains replaceable.

That is a stronger and more coherent product than “GORM for Odin”: it removes
the dangerous parts of database work without hiding the database or turning
the framework into a second language.

### Handoff to Phase 7

WP84 must publish, in machine-usable or gate-readable form:

- final handler-lane count/default and application-state concurrency contract;
- immutable serving snapshot ownership;
- cross-lane stop/wakeup mechanism;
- database pool acquisition/cancellation behaviour;
- complete Phase-5 feature results under concurrent serving;
- transport conformance entry points and adapter-private state;
- the remaining limitation that arbitrary blocking code is not preemptible.

Phase 7 consumes those facts to design detached long-lived responses. It may
not add streaming as a hidden extension of WP71 or retain a Handler frame as a
substitute for stream ownership.
