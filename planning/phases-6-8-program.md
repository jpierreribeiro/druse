# Phases 6–8 — product and architecture program

**Status: OWNER-APPROVED PROGRAM, 2026-07-21; Phase-5 handoff refreshed at
`6b6edbc`.**
This is the program-level map. The executable work-package plans are
`phase-6-plan.md`, `phase-7-plan.md` and `phase-8-plan.md`. Phase 5 is frozen;
Phase 6 still performs an exact entry verification, and no future signature
described here is frozen by this program document.

The program turns Druse from a production-capable HTTP core into a proven
platform for ordinary data-backed applications and bounded streaming,
without turning the common API into a full-stack framework.

```text
Phase 6 — real applications
  concurrency + honest input + PostgreSQL + migrations + validation
                         ↓
Phase 7 — streaming foundation
  server push + large bodies + safe spool + bounded backpressure/drain
                         ↓
Phase 8 — proof by use
  one deployed multi-user product, evolved and faulted on purpose
```

The governing statement remains:

> **Internally data-oriented and allocator-aware; externally simple,
> productive and predictable.**

And the product remains:

> **A web framework for the Joy of Programming.**

---

## 1. Is Druse still a microframework?

**Yes.** “Micro” describes the required core and the number of concepts a user
must learn, not a prohibition on capable optional packages.

The ordinary path still has five concepts:

```text
app → route → extract → respond → serve
```

Phase 6 does not put PostgreSQL in `web`; the application owns a pool through
`App_State`. Phase 7 adds the smallest core primitives that only the core can
own — transport-neutral long-lived responses and bounded large-body ingestion
— while SSE remains a package above them. Phase 8 adds no convenience surface merely because
the validation application wants it; friction becomes evidence for a later
spec.

The intended product shape is:

```text
druse:web                         microframework core
  routing, middleware, HTTP I/O,
  safety, lifecycle, stream primitive

crystals:*                          batteries available
  PostgreSQL, migrations, validation,
  SSE and optional tooling
```

This is comparable to Flask's historical meaning of “micro”: keep policy and
unrelated subsystems out of the core, while allowing a coherent first-party
ecosystem. It is not “micro” as a euphemism for incomplete, toy or unsafe.

### The test for keeping the word

The README may continue to say microframework only while all are true:

1. a JSON endpoint requires no database, stream, CLI or code generator;
2. there is one canonical Handler model;
3. `web` never imports a Crystal;
4. optional packages do not make the core public surface grow (CE-E3);
5. transport, allocator and lane details remain absent from the Quick Start;
6. a new user can learn the ordinary path from three compiling examples;
7. the core concept budget and public ledger remain enforced.

If Phase 8 falsifies these, the wording changes honestly. Marketing does not
override architecture.

---

## 2. Odin philosophy translated into design rules

Odin's official principles emphasize simplicity, readability, orthogonality,
high performance and Joy of Programming. Its FAQ adds: there ought to be one
way to write something; programs transform data; algorithms should not be
hidden inside type-system cleverness; and the language should remain possible
for a person to understand.

For Druse, those statements become executable rules:

| Odin principle | Druse rule | Gate |
|---|---|---|
| Simplicity and readability | One canonical path for each common operation; conventional names | public ledger, examples, Phase-8 usability trial |
| Minimal: one way | No alias families, second Handler model or equivalent responders | public-surface gate |
| Orthogonality | HTTP, data, migrations and SSE have one-way dependencies and separate owners | dependency scan, CE-E3 |
| Transform data, not the type system | Structs and procedures; explicit SQL and row decoding; no ORM magic or runtime DI | API review and real application |
| Explicitness | Lifetimes, capacities, cancellation and destructive operations are visible in contracts | lifetime/capacity ledgers |
| High performance through control | Bounded allocation and queues, immutable serving state, allocator ownership | allocation/fault/soak gates |
| Clear over clever | Generational handles and state enums only where stale identity exists; no abstraction without a failing test | prototype-first rule |
| Joy of Programming | Complexity is paid once by the framework, diagnostics occur at build/boot, common handlers stay synchronous | joy/usability gate |

**Joy is not fewer characters at any price.** ADR-029 already fixes the order:
discipline first, joy second, convenience last. A hidden unbounded queue is
convenient; a bounded queue with a clear `Full` result is joyful because it can
be understood at 3 a.m.

Primary references:

- <https://odin-lang.org/> — Simplicity, High Performance, Modern Systems,
  Joy of Programming;
- <https://odin-lang.org/docs/faq/> — simplicity/readability, minimalism,
  orthogonality and data transformation.

---

## 3. Why Axum is a useful comparison

Axum describes itself as an HTTP routing and request-handling library focused
on **ergonomics and modularity**. Its high-level model is routes, handlers,
extractors, responses, state and middleware. That is the useful comparison:

| Axum | Druse |
|---|---|
| routes map to handlers | routes map to synchronous `Handler` procedures |
| extractors parse request data | explicit bool/value extractors commit canonical errors |
| response conversions reduce boilerplate | canonical responders reduce boilerplate |
| shared state is injected into handlers | one typed application-owned state is read through `web.state` |
| middleware composes through Tower | middleware is a flattened Odin onion owned by `web` |
| Hyper/Tokio own transport/runtime | a private adapter owns odin-http today and future `core:net/http` |

The comparison ends there.

- Axum is async Rust over Tokio/Hyper; Druse intentionally preserves ordinary
  synchronous Odin handlers.
- Axum explicitly says runtime/transport independence is not currently a goal;
  it is a load-bearing Druse goal.
- Axum obtains a large middleware ecosystem through Tower traits; Druse uses
  procedures and packages, because reproducing Tower would be foreign
  abstraction rather than Odin design.
- Rust traits, derives and macros can encode integrations at the type level;
  Druse prefers registration-time validation, explicit records and closed
  error sets.

So the intended statement is:

> Druse aims for Axum's modularity and extractor ergonomics, expressed as
> procedural, allocator-aware Odin rather than async Rust.

Primary reference: <https://docs.rs/axum/latest/axum/>.

---

## 4. Why SQLx is a useful comparison

SQLx calls itself an SQL toolkit and explicitly says it is **not an ORM**. It
keeps SQL visible, provides pooling and transactions, and can check queries
against a schema. That is the useful comparison for the Phase-6 data stack.

| SQLx | Druse data Crystals |
|---|---|
| SQL remains SQL; no DSL required | explicit SQL and positional bindings |
| connection pool | bounded, fail-fast PostgreSQL pool |
| typed row decoding | explicit fail-closed row decoding |
| transactions and savepoints | explicit transaction tied to one connection |
| optional compile-time query macros | optional CI checker against disposable PostgreSQL |
| async streaming rows | synchronous bounded execution on handler lanes |
| multiple databases | PostgreSQL first; another backend must earn its own contract |

The comparison also ends at important boundaries:

- Druse does not promise compile-time SQL typing without either generation or
  metaprogramming; the checker is optional and honest about dynamic SQL.
- Druse does not import Rust's async model. Blocking calls are made safe by
  bounded concurrent handler lanes and pool backpressure.
- Druse migrations are a separate deployment tool, not a server startup side
  effect.
- Database failures remain database/domain errors until the application maps
  them at the HTTP boundary.

The intended statement is:

> Druse follows SQLx's SQL-first direction, but replaces async Rust and
> macro-based checking with synchronous Odin, explicit decoding and optional
> CI verification.

Primary references:

- <https://docs.rs/sqlx/latest/sqlx/>;
- <https://docs.rs/sqlx/latest/sqlx/pool/>.

---

## 5. Capability after each phase

### After Phase 6

A conventional production JSON application can have:

- concurrent synchronous handlers with a measured blast radius;
- strict JSON failures and structured validation paths;
- static files, CORS and bounded in-memory multipart uploads inherited from
  Phase 5;
- PostgreSQL pool, typed errors, cancellation and transactions;
- fail-closed migrations through either the separate CLI or an explicit
  application call before serving, never an implicit `web` startup hook;
- optional SQL/schema checking;
- a real CRUD reference application;
- the same routing/handler API across the current and future transport.

Comparable product category: **Gin/Echo/Fiber plus a coherent pgx + migration
tool stack**, with stronger explicit capacity/ownership evidence.

### After Phase 7

The core additionally supports:

- long-lived HTTP responses without holding a Handler frame alive;
- server-initiated chunks/events delivered to the connection-owning lane;
- bounded per-stream queues and typed backpressure;
- stale-handle rejection after close/reuse;
- slow-consumer isolation;
- graceful drain and forced cancellation of thousands of open streams;
- incremental request-body ingestion without RAM proportional to body size;
- bounded streaming multipart and safe temporary-file spool;
- explicit persistence transfer, disk quotas and disconnect cleanup;
- large downloads/static responses through bounded output;
- an SSE Crystal, a proxy interoperability lab and a large-transfer vertical slice.

Comparable product category: **Axum-style modular HTTP plus a safe SSE/server
push foundation**, but with synchronous handlers and explicit memory ownership.

### After Phase 8

The claim changes from “the contracts pass” to “a product used them”:

- multi-user CRUD, auth, files and streamed notifications coexist;
- real schemas evolve through several deploys;
- PostgreSQL restarts, slow queries, pool exhaustion, client disconnects and
  stream backpressure have been rehearsed;
- deploys occur while ordinary requests and long-lived streams are active;
- the same application is used to rehearse a transport swap when the official
  adapter exists;
- human and AI contributors implement changes from public docs without using
  framework internals;
- every friction point is accepted, fixed or recorded as a refused feature.

Only after this phase may the README make strong “production-ready data stack”
or bounded streaming claims.

The Phase-5 in-memory multipart path remains the simplest option for ordinary
files. Phase 7 adds a distinct opt-in large-body path rather than silently
changing `Uploaded_File` ownership. Arbitrary full-duplex protocols remain out;
bounded request ingestion and bounded response streaming are two orthogonal
contracts, not one magical stream abstraction.

---

## 6. What Druse is comparable to — precisely

| Druse composition | Fair comparison | Not a fair claim |
|---|---|---|
| `druse:web` | Gin, Echo, Fiber, Flask core | Rails/Django batteries included |
| `web` + data Crystals | Gin + pgx + goose/sqlc; Axum + SQLx | GORM/Active Record ORM |
| `web` + stream primitive + SSE | Axum SSE and explicit HTTP streaming stacks | a browser UI/session runtime |

Druse's prospective differentiation is not “more features than all four”. It
is a combination that is rare in Odin and uncommon elsewhere:

1. a tiny canonical application surface;
2. allocator and lifetime correctness underneath;
3. capacities and negative guarantees kept in executable ledgers;
4. synchronous programming over bounded concurrency;
5. explicit SQL without ORM ambiguity;
6. transport replaceability;
7. bounded, owned long-lived streams and large-body ingestion;
8. documentation tested for humans and coding agents.

These are hypotheses until Phase 8 proves them in one system.

---

## 7. Innovation budget

Innovation is welcome where it removes a demonstrated cost. It is rejected
where novelty is the only evidence.

### Innovations this program deliberately pursues

- **Executable honesty:** API, claim, lifetime and capacity ledgers remain
  machine-checked together.
- **Blocking without global paralysis:** multiple event-loop lanes preserve
  synchronous handlers, paired with fail-fast database capacity.
- **Transport-neutral long-lived ownership:** a stream is identified by a
  stale-safe token; only its owner lane writes; any thread may attempt a
  bounded enqueue.
- **Control capacity survives overload:** stop/close never depends on a user
  event finding space in a full stream queue.
- **SQL verification without runtime magic:** optional CI preparation and
  metadata checking, no mandatory generator.
- **Joy as evidence:** Phase 8 measures whether a human or coding agent can add
  a feature from the canonical docs without inventing APIs or reading
  internals.
- **A real product as architecture test:** reference examples catch contract
  errors; deployment and evolution catch product errors.

### Innovation that needs evidence first

- automatic stream-event coalescing;
- a template compiler or generated static/dynamic render split;
- a general job/background-task system;
- LISTEN/NOTIFY integration;
- WebSocket, bidirectional channels or resumable protocol logs;
- ORM-like mapping;
- a CLI that becomes required to build or run an application.

Each may enter a prototype. None enters the canonical API because it sounds
modern.

---

## 8. Cross-phase gates

Every phase retains its local gate and additionally satisfies:

### P-1 — Common-path preservation

The Quick Start compiles without a database, stream, CLI, generator, custom
allocator or transport selection. Existing handlers do not change shape.

### P-2 — One-way architecture

```text
application → Crystals → web → private transport adapter
```

No arrow points back. Core tests never need a Crystal; Crystals pin a core
revision.

### P-3 — No hidden waits

Every pool, mailbox, stream queue, migration lock and shutdown wait has a
capacity/deadline and a typed exhaustion outcome. A wait described as bounded
names the perimeter.

### P-4 — No transport leakage

No public symbol names odin-http, nbio or an unreleased `core:net/http` type.
The real adapter and test transport share behavioural conformance.

### P-5 — Joy gate

For each canonical task, a human-readable example compiles and a coding agent
given only public docs can produce the same shape without aliases or internal
imports. Failures become documentation/API evidence, not prompt blame.

### P-6 — Real-system veto

Phase 8 may veto an earlier abstraction. A feature that passes isolated tests
but makes the real application unsafe or unpleasant returns to its owning spec;
the validation app never works around it silently.

---

## 9. Sequencing and stopping rule

Phase 6 must freeze before Phase 7 changes handler concurrency assumptions.
Phase 7 must freeze before Phase 8 treats streams as product capability.

If Phase 7 cannot provide safe cross-lane ownership, bounded backpressure and
honest drain without leaking the backend, streaming is recorded as not
delivered. Phase 8 may still validate the JSON/data framework.

If Phase 8 finds that the ordinary API has accumulated too many required
concepts, the answer is subtraction or moving capability out of core — not
dropping “micro” from the README to excuse accretion.

---

## 10. Final product statement to earn

The program does not place this sentence in the README today. It defines what
the evidence should eventually permit:

> **Druse is an explicit, production-oriented Odin microframework for JSON,
> data-backed applications and explicit streaming workloads: simple by default, bounded by
> construction, and joyful to program.**

Phase 8 decides whether the project earned every adjective.

---

## 11. Amendment — 2026-07-22: the composition half of Phase 7

Phase 6 shipped in two halves — concurrency in core, data in Crystals. Phase 7
adopts the same structure: streaming is its **core half** (WP85–WP101,
unchanged), and **composition** is its **Crystals half** — an `http_client`
Crystal (outbound HTTP/1.1 with TLS and real certificate verification, bounded
connection pool, deadline budget, drain-integrated cancellation, bounded
retry) and a `metrics` exposition Crystal over the existing observer hooks.
The Crystals half builds against the Phase-6 core freeze and may run in
parallel with streaming.

The audit that produced this amendment also produced
`planning/production-service-bom.md`: the composition-facing bill of materials
in which every capability a production service needs is classified CORE /
CRYSTAL / DELEGADO / RECUSADO / ABERTO-with-trigger. It becomes an entry gate
for WP102 (E8-7), and the Phase-8 reference application must place at least
one real outbound HTTP call.

Rationale, recorded so the lesson outlives the fix: every earlier phase asked
inward-facing questions ("what does a server need?"). The outbound HTTP client
escaped through exactly that angle — present in the documents only as a test
workload, never as a capability. The BOM makes the composition question ("what
does a service among services need?") a standing gate instead of an accident.
