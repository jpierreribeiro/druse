# Phase 6 spec — real applications without hidden machinery

**Status:** SPEC, 2026-07-21, WP66, under the ADR-029 delegation and the
owner amendments recorded in `decisoes-do-dono.md`.

**Entry snapshot:** Phase 5 frozen at `6b6edbc`, ledger **62 application + 2
test-support = 64**. The Phase-5 gate is green. This spec adds no public symbol
and changes no implementation.

The execution plan is `phase-6-plan.md`. This document is the normative gate:
if the plan and this spec disagree, this spec wins until an explicit amendment
records why.

---

## 1. Product decision

Phase 6 makes an ordinary, production-minded PostgreSQL application possible
without changing the common Druse programming model:

```text
app → route → extract → service/SQL → respond → serve
```

Handlers remain synchronous Odin procedures. SQL remains visible. The
application owns its services. The framework removes the process-wide stall
caused by one blocking handler only if the measured multi-lane arm passes all
safety and shutdown gates.

The owner has waived the roadmap's external-demand wait for the bounded class
**first real application**:

- honest JSON decoding and validation errors;
- safe synchronous blocking dependencies;
- PostgreSQL, explicit transactions and bounded pooling as Crystals;
- a fail-closed migration tool;
- transport-free validation and optional SQL checking;
- one real PostgreSQL reference application.

The waiver does not waive G-09, evidence, ownership or rollback. It does not
extend to an ORM, Active Record, a DI container, mandatory generation,
GraphQL, OpenAPI, WebSocket, HTTP/2, in-process TLS or a general job runtime.

Response streaming and the opt-in large-body/spool path are scheduled for the
separately gated Phase 7. They are named now because Phase 5 proved the need;
they do not enter Phase 6 through the side door.

---

## 2. Owner amendments that bind the phase

### 2.1 ADR-030 is reopened for liveness, not throughput

ADR-030 correctly rejected threading as an unmeasurable throughput
optimisation in Phase 4. Phase 6 asks a different binary question:

> While one handler is deliberately blocked in an external dependency, can an
> independent health handler finish before the dependency is released?

The old throughput result remains history. The new workload reopens the
execution-model decision because database calls, filesystem calls, password
hashing and external HTTP are ordinary application work, not hypothetical
framework CPU load.

The candidate is **bounded multi-lane synchronous serving**, not asynchronous
Handlers, futures or request continuations. It ships only if WP69–WP72 prove
the framework-owned state, request lifetime, Phase-5 features, cancellation and
stop lifecycle safe. Inconclusive safety means the one-lane default remains
and the concurrency surface is refused.

### 2.2 Core and data ecosystem remain one-way

`web` owns HTTP semantics, framework concurrency safety and transport
conformance. It never imports PostgreSQL, migrations, validation packages or a
query checker.

Data packages live in the Crystals ecosystem. An application may place their
services in `App_State`; that does not make the database part of `web`.
CE-E3 remains intact: a Crystal cannot add, widen or change a core symbol.

Before the data stack, WP73 ships the small Route Crystal required by ADR-032
to prove that the dependency direction works in practice.

### 2.3 SQL-first is the accepted direction

The data stack uses explicit SQL, separate parameters, explicit row decoding,
typed errors, explicit transactions and migrations as an explicit lifecycle
step. The same migration engine supports a separate CLI and an application
call made before `web.serve`; neither path is hidden inside `web`. It may offer
an optional CI checker. It does not hide table names, writes, transactions or
schema changes behind reflection or conventions.

No server boot automatically migrates production. No row mismatch becomes a
zero value. No relevant database operation returns only an unexplained `bool`.

**Owner amendment, 2026-07-22.** Explicit in-band migration is a first-class
deployment path for self-hosted and small installations, not a development-only
convenience. It means application code deliberately calls the migration engine,
handles its typed result, and only then constructs/serves HTTP. The equivalent
CLI remains first-class for SaaS, privilege separation and long-running schema
work. Starting `web`, constructing an App or importing a package never applies
migrations as a side effect.

### 2.4 The future official transport is an exit, not a guessed API

The official Odin HTTP package expected in January 2027 is not available in
this pinned toolchain. Phase 6 exposes no odin-http type and invents no
compatibility shim. A future adapter must pass the same semantic, raw-wire,
liveness and shutdown corpus before it can replace the current bridge.

---

## 3. Terms used by every work package

- **Lane:** one transport-owned execution lane that accepts work and invokes
  synchronous Handlers. A lane is an observable capacity unit, not a promise
  about a particular backend thread type.
- **Blocking dependency:** external work whose call does not return while it
  waits, such as a synchronous database query. Arbitrary permanently stuck
  user code is not made preemptible.
- **Serving snapshot:** the immutable route, middleware and runtime data read
  after serving begins. Registration remains single-threaded and closed at
  that point.
- **Request-local:** memory or state owned by one dispatched request and never
  shared with or moved to another lane. `Context`, params, body views, request
  arena and response scratch are request-local.
- **Bounded acquisition:** resource acquisition has a hard capacity and either
  returns immediately or by a declared deadline with a typed exhaustion
  result. It never creates an unbounded waiter list.
- **Transport conformance:** behaviour every real or in-memory adapter must
  preserve: request normalization, dispatch, exactly-once commit, admission
  stop, deadline-bound cancellable work and exactly-once cleanup.

The word **worker** is avoided in normative contracts because it can mean a
connection thread, a handler lane, a database connection or a job executor.

---

## 4. Scope and work-package order

| WP | Required result |
|---|---|
| 66 | This spec, owner amendments and executable spec gate. |
| 67 | RED JSON failure corpus and negative control. |
| 68 | Stable honest request-decoding taxonomy. |
| 69 | One-lane/multi-lane blocking-I/O laboratory. |
| 70 | Immutable serving snapshot and race-free framework-owned state. |
| 71 | Transport-neutral bounded Handler concurrency. |
| 72 | Full concurrency/fault/shutdown gate and ADR-030 verdict. |
| 73 | Crystals boundary plus the first Route Crystal. |
| 74 | PostgreSQL contract and driver-arm selection. |
| 75 | RED wire, auth, TLS, cancellation and error corpus. |
| 76 | Execution, binding and fail-closed row decoding. |
| 77 | Bounded pool, acquisition deadline and query cancellation. |
| 78 | Explicit transaction lifecycle on one connection. |
| 79 | Migration contract and RED safety corpus. |
| 80 | Separate migration executable. |
| 81 | Validation, optionality and absent/null/value semantics. |
| 82 | Optional SQL/schema checker, or an evidence-backed refusal. |
| 83 | Real PostgreSQL reference application and deployment path. |
| 84 | Documentation, ledgers, non-deliveries and Phase-6 freeze. |

The hard order is:

```text
WP66
  ├─ WP67 → WP68
  ├─ WP69 → WP70 → WP71 → WP72
  └─ WP73 → WP74 → {WP75 → WP76 → WP77 → WP78, WP79 → WP80}

{WP68, WP73} → WP81
{WP76, WP80} → WP82
{WP68, WP72, WP78, WP80, WP81, WP82} → WP83 → WP84
```

WP82 is conditionally deliverable. Concurrency safety, the PostgreSQL runtime,
migrations and the reference application are not optional Phase-6 exit items.

---

## 5. Pre-registered evidence

These outcomes are fixed before WP67 or WP69 builds a prototype. A later
threshold change must be a dated spec amendment made before seeing the affected
result.

### 5.1 JSON boundary matrix

| Condition | Required wire classification |
|---|---|
| malformed JSON | `400 invalid_json` |
| valid JSON, wrong scalar or aggregate type | `400 invalid_field` |
| nested mismatch | `400 invalid_field` with stable field path |
| unknown field in the canonical strict path | `400 unknown_field` |
| explicitly required field absent | `400 missing_field` |
| declared validation rule fails | `400 invalid_field` |
| unsupported destination/programmer misuse | `500 internal_error` plus safe server diagnostic |
| allocator/decoder internal failure | `500 internal_error` plus safe server diagnostic |

Requiredness is explicit; it is never inferred from a zero value. The response
does not expose the raw body, Odin type names, source paths or decoder internals.

### 5.2 Independent-request liveness laboratory

The deterministic laboratory uses four lanes and a latch-controlled blocking
Handler:

1. **negative control, one lane:** the blocked Handler starts; a health request
   must not complete during a 250 ms observation window; after latch release it
   must complete;
2. **candidate, four lanes:** three blocked Handlers start on distinct lanes;
   health must complete within 250 ms and before any latch is released;
3. **full saturation:** four blocked Handlers may prevent health progress, but
   the condition, capacity and recovery after release must be deterministic and
   documented. The framework may not claim preemption it does not have;
4. each case repeats with CORS, static serving, buffered multipart, request IDs,
   middleware and stop enabled so concurrency cannot pass by bypassing Phase 5.

The 250 ms number is a liveness observation window, not a latency SLO or req/s
benchmark. The lab records its loopback baseline; if the unblocked baseline is
25 ms or more, the environment is invalid and the result is not interpreted.

### 5.3 Database capacity laboratory

The canonical test deployment uses four Handler lanes and a pool capacity of
two. Two latch-controlled queries occupy the pool. A third acquisition with a
configured 100 ms deadline must return the pool's typed exhaustion/timeout
result within 250 ms. During that saturation, a database-free health request
must still satisfy §5.2.

No implementation is required to use those values as production defaults.
They define the reproducible test and the relationship **pool capacity < lane
capacity** that preserves control progress.

### 5.4 Cancellation and shutdown

- cancellation races before send, during query and after server completion
  have one terminal result and exactly-once resource return;
- a cancellable blocked query must be interrupted early enough for `web.stop`
  to return no later than `max_drain_time + 250 ms` in the laboratory;
- an arbitrary Handler stuck in user code is explicitly outside that promise;
- broken or protocol-uncertain connections are quarantined, never returned to
  the pool as healthy.

### 5.5 Migration safety

- two runners against one disposable database result in exactly one lock owner;
- a checksum change to applied history refuses before new DDL;
- dirty/uncertain state refuses further apply;
- transactional failure leaves no partial schema change;
- non-transactional failure can never be recorded as clean;
- an unknown applied ID (database ahead of the binary/manifest) refuses by
  default before serving or applying new DDL;
- directory and compile-time embedded sources produce the same validated
  migration manifest and checksums;
- the CLI and explicit pre-serve call exercise the same engine and history;
- `web` has no boot path that applies migrations; only application code may
  explicitly invoke the engine before calling `web.serve`.

### 5.6 Row and error safety

- values are always bound separately from SQL structure;
- a column count/type/nullability mismatch is a typed decode error;
- SQLSTATE and a safe constraint/query name are retained where available;
- SQL text, parameter values, credentials and personal data are absent from
  default diagnostics;
- a transaction owns exactly one connection until commit or rollback and has
  one terminal state.

---

## 6. Public surface and cost budget

The starting core ledger is **62 + 2**.

- JSON work should change behaviour and stable codes before adding public
  types.
- Handler concurrency should prefer a field on an existing configuration or
  limits record; fields still pay signature, documentation and binary-cost
  evidence even though they do not add a ledger name.
- no database, migration, validation or SQL-checker type enters `web`.
- each Crystal has its own literal public ledger and G-09-equivalent evidence.
- the Phase-5 Hello World is the unused-feature binary control.

WP66 fixes no final symbol names. Names and signatures freeze only after their
RED corpus and prototype justify them.

---

## 7. Security and ownership rules

- route/middleware mutation after serving begins remains rejected;
- `App_State` is application-owned and shared; mutable application state is the
  application's synchronisation responsibility;
- framework counters and lifecycle state shared by lanes are atomic or
  lane-owned;
- no request-backed view escapes its Handler;
- every pool/queue has capacity, owner, full policy and cleanup test;
- PostgreSQL TLS/auth support is part of driver selection, not assumed from
  local plaintext tests;
- migration tests may destroy only an explicitly named disposable database;
- migrations, SQL checking and integration tests never target a database
  inferred from a broad environment default;
- database conditions remain database/domain vocabulary until application code
  translates them at the HTTP boundary.

---

## 8. Refusal and stopping rules

The affected feature is refused, with evidence, if:

1. multi-lane serving requires a public backend type or uncontained transport
   rewrite;
2. framework-owned state cannot pass the concurrency/fault corpus while
   preserving the synchronous Handler contract;
3. every viable PostgreSQL arm lacks secure authentication, bounded operation,
   cancellation or maintainable ownership;
4. pool liveness requires unbounded waiting;
5. migration uncertainty can be reported as clean;
6. the reference application requires `web` to know about PostgreSQL;
7. compatibility with the unreleased official package requires inventing its
   API.

WP82 may conclude that useful SQL verification requires generation or
metaprogramming the project refuses. That is a legitimate non-delivery. It does
not weaken the runtime database contract.

---

## 9. Exit contract

Phase 6 freezes only when:

- the JSON matrix is green on the in-memory and real transport paths;
- ADR-030 has an evidence-backed Phase-6 verdict;
- all framework-owned concurrent state, stop and Phase-5 features pass their
  fault controls;
- the first Route Crystal proves CE-E3 without a core amendment;
- PostgreSQL execution, pool, cancellation and transactions pass against a
  pinned disposable server;
- the migration engine is fail-closed, supports both the separate CLI and the
  explicit pre-serve application path, and is never invoked by `web` itself;
- the reference application demonstrates CRUD, constraints, conflict,
  pagination, transaction, migration, cancellation and health liveness;
- cost, ownership and public ledgers are frozen literally;
- every limitation and non-delivery is recorded;
- the complete existing Druse gate remains green.

The expected result is still a microframework: `web` stays small and ordinary,
while first-party Crystals make the common data-backed application complete.
Capability grows without forcing database, streaming, a CLI or code generation
on the Hello World user.

---

## Amendment 1 — WP67 separates decoding from schema validation

**Recorded 2026-07-21, before WP68 implementation.** The pinned stdlib anatomy
in `experiments/14-json-failure-anatomy/` established:

- type mismatch reports a token and destination type, but no field path;
- unknown fields are deliberately skipped;
- `required` and validation tags have no decoder semantics;
- allocator refusal can return `err=nil` with zero values directly, while the
  current `web.body` path can misclassify valid bytes as `invalid_json`.

Therefore WP68 owns malformed JSON, wrong type/path, unknown-field refusal and
internal decoder/allocation failure. The `missing_field` and declared-rule
rows in §5.1 remain phase requirements but are implemented by WP81 after it
chooses the explicit schema/optionality representation. Their RED tests are
committed separately under `tests/wp67-json-boundary/schema/`.

The probe tags `json:"name,required"` and `validate:"..."` are test stimuli,
not accepted syntax. WP68 may not make them canonical merely to turn the whole
WP67 directory green. This amendment changes ownership/order, not the required
wire taxonomy.

---

## 10. Rollback

WP66 is documentation and an executable document gate only. **Rollback: HIGH.**
Later implementation WPs carry their own rollback grades. This spec does not
authorize a release, tag, Tina dependency, published-history rewrite or any
destructive database operation outside an explicitly disposable test database.

---

## Amendment 2 — WP68 keeps the stdlib grammar and owns the missing structure

**Recorded 2026-07-21, after the WP67 RED corpus and before WP68 merge.** A
`json.Value` preflight was chosen over a second parser. The standard tokenizer,
string decoder and typed unmarshaller remain authoritative; a private bounded
RTTI walk adds only the missing field stack and unknown-key refusal.

The preflight uses a disposable arena destroyed before typed decoding. Client
paths are copied into fixed request-local storage, capped without splitting
UTF-8, and never contain raw values or Odin types. Multiple unknown keys select
the lexicographically smallest key, so map iteration cannot change the wire
result. A root mismatch uses `$`; nested objects use dot-separated names.

The implementation also requires EOF after the root value. This closes a gap
where the pinned parser could successfully return the first value while leaving
trailing tokens unread. Requiredness and declared validation remain explicitly
outside WP68 and RED-under-control until WP81.
