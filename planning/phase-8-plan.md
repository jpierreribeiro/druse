# Phase 8 — Proof by use: the reference production system

**Status: OWNER-APPROVED PROGRAM PLAN, 2026-07-21.** Written before Phases 6 and
7 execute. WP102 must refresh it against both freezes. Work packages continue at
**WP102–WP113**.

Phase 8 is intentionally not another infrastructure feature phase.

> Build, deploy, evolve and fault one real multi-user system until the project
> has evidence about the framework as a product, not only as a collection of
> passing packages.

The application lives in a separate repository. It depends only on released or
pinned public Druse and Crystals contracts. It receives no friend imports,
test-only privileges or core exceptions.

---

## 0. Why the existing examples are not enough

Examples prove syntax and one behaviour at a time. WP83 proves the Phase-6 data
design in a controlled integration. Neither proves:

- repeated schema evolution;
- deploys with real in-flight and long-lived work;
- two users changing the same data;
- accumulated operational diagnosis;
- whether auth, validation and state composition remain pleasant;
- whether public docs are sufficient for a new contributor;
- whether independent “good” APIs compose into an unpleasant application.

Phase 8 makes composition, operation and evolution the test instrument.

---

## 1. Recommended system

Build a small collaborative operations/project board. The final name is an
owner product decision; the domain is recommended because it naturally needs
every capability without inventing artificial benchmark endpoints.

Required workflows:

- accounts, sessions and role-based project membership;
- projects, tasks, status transitions, assignment and comments;
- optimistic conflict detection on concurrent edits;
- file attachments;
- at least one attachment larger than the buffered-body limit, using the
  Phase-7 spool path;
- filtering, search and stable cursor pagination;
- audit history;
- transactional multi-row operations;
- streamed board notifications over SSE;
- reconnect after process deploy/network interruption;
- admin health/readiness and operational metrics;
- at least one real outbound HTTP call — webhook delivery to an external
  endpoint through the Phase-7 composition `http_client` Crystal, with
  timeout, bounded retry and drain cancellation (owner amendment,
  2026-07-22: proof-by-use without an outbound call would prove only half of
  a microservice).

This is a **real application**, not a generic admin generator. Domain code is
ordinary Odin and remains outside framework repositories.

---

## 2. What Phase 8 is allowed to change

The application may discover framework defects or missing capabilities. It may
not repair them by importing internals or mutating core plans silently.

Each friction item enters a ledger with:

- task the user attempted;
- public API used;
- boilerplate/concepts required;
- safety or ownership problem;
- workaround, if any;
- whether the problem is application-specific;
- smallest candidate improvement;
- public cost and reversibility;
- RED test that would distinguish improvement from preference.

Core/Crystal changes happen only in a separately reviewed corrective WP with
their original gates. Phase 8 is a veto and evidence source, not an accretion
exception.

---

## 3. Entry conditions

| ID | Condition |
|---|---|
| E8-1 | Phase 6 frozen with PostgreSQL runtime, migrations and reference app green. |
| E8-2 | Phase 7 frozen with bounded streams, SSE, large-body ingestion and the large-transfer vertical slice green. |
| E8-3 | Pinned consumption/release method exists for core and every used Crystal; no branch-relative hidden dependency. |
| E8-4 | A supported deployment target, reverse proxy, supervisor and dedicated PostgreSQL instance are available. |
| E8-5 | Security and data-retention scope is written before real user data; synthetic/non-sensitive data is the default. |
| E8-6 | Observability can distinguish route pattern, query name, pool state, stream state and failure class without personal data. |
| E8-7 | The Phase-7 composition Crystals are frozen — `http_client` (with outbound TLS and certificate verification) and `metrics` exposition — and `planning/production-service-bom.md` carries no unclassified item and no ABERTO item without a registered trigger. |

The product uses ordinary HTTP commands plus the SSE Crystal directly. No
additional rendering, session or client-runtime abstraction is an entry
condition.

---

## 4. Evidence model

Phase 8 requires both deterministic gates and operational evidence.

### Deterministic

- unit, semantic, raw-wire and integration tests;
- isolated PostgreSQL/migration tests;
- browser reconnection and two-client concurrency tests;
- seeded failure drills;
- allocator/sanitizer/fault laboratories inherited from prior phases.

### Operational

- at least ten recorded deployments, several with active streams;
- at least five forward schema migrations, including one backfill and one
  expand/contract change;
- repeated process and PostgreSQL restart drills;
- a sustained soak long enough to cross connection recycling and session
  expiry boundaries, duration pre-registered in WP102;
- a non-trivial persistent dataset generated/owned for the test;
- human and coding-agent feature additions from public docs;
- every incident/friction item classified rather than forgotten.

Calendar time alone proves nothing. Counts, state transitions and retained
evidence are the gate.

---

## 5. Work-package map

| WP | Name | Type |
|---|---|---|
| 102 | System spec, hypotheses and evidence thresholds | SPEC |
| 103 | Repository, deployment and application lifecycle | IMPLEMENTATION |
| 104 | Identity, sessions and authorization | IMPLEMENTATION |
| 105 | Core relational workflows and transactions | IMPLEMENTATION |
| 106 | Files, validation, search and pagination | IMPLEMENTATION |
| 107 | Streamed notifications and reconnection | IMPLEMENTATION |
| 108 | Conflict, backpressure and concurrency tests | TESTS |
| 109 | Observability and operational dashboard | IMPLEMENTATION + OPS |
| 110 | Failure and recovery drills | TESTS + OPS |
| 111 | Evolution: migrations, upgrades and adapter rehearsal | INTEGRATION |
| 112 | Joy-of-programming and AI-readability study | RESEARCH |
| 113 | Product verdict, documentation and Phase-8 freeze | FREEZE |

```text
WP101 → 102 → 103
              ├─ 104 → 105 → 106 → 107 → 108
              └──────────────────────→ 109 → 110 → 111
                                        {107, docs} → 112
                         {108, 110, 111, 112} → 113
```

---

## 6. Work packages

### WP102 — System spec, hypotheses and evidence thresholds

Write the product requirements, data model, threat model, deployment topology
and exact evidence thresholds before application code.

Hypotheses include:

1. an ordinary contributor needs only the five core concepts plus explicit
   application services;
2. concurrent handlers do not make application state confusing when mutable
   services own their synchronization;
3. explicit SQL remains readable at the application's real query count;
4. migrations can evolve the schema without server boot coupling;
5. streamed notifications do not require backend/internal access;
6. bounded pool and stream policies fail predictably under saturation;
7. one reverse-proxy deployment story is sufficient;
8. documentation lets a human and coding agent implement the same canonical
   shapes.

Pre-register deploy/migration/soak counts, usability tasks and stopping rules.

**Rollback:** HIGH — docs only.

### WP103 — Repository, deployment and application lifecycle

Create the separate application with:

- explicit config loading and validation;
- `application.init`/`destroy` owning pool, services and stream/session state;
- one `App_State` with coherent service pointers/values;
- migrations as a deployment step before replicas start;
- reverse proxy TLS termination;
- supervisor with timeout outside framework drain;
- reproducible local and production-like environments;
- readiness that checks only dependencies needed for admission;
- no core repository relative import.

The first deployment serves a boring health page before domain features. This
proves lifecycle and delivery independently.

**Rollback:** HIGH — separate application.

### WP104 — Identity, sessions and authorization

Implement application-level identity without assuming it belongs in core:

- password or external identity choice recorded with threat model;
- secure password hashing where applicable;
- opaque/session token lifecycle;
- cookie policy at the proxy/application boundary;
- CSRF policy for browser mutations;
- project membership and role checks;
- session revocation and expiry;
- audit-safe identity logging.

Measure repeated auth/authorization boilerplate. If request-scoped typed state
becomes a real problem, this is the evidence ADR-028 requires; the application
does not smuggle an extension bag into `Context`.

**Rollback:** HIGH — application feature; findings may reopen a core ADR.

### WP105 — Core relational workflows and transactions

Implement projects, tasks, comments, assignments, status transitions and audit
history using explicit named SQL.

Required database evidence:

- unique and foreign-key violations mapped through domain errors;
- one transaction spanning several writes;
- serialization/conflict case;
- nullable versus zero values;
- row-decode failure injected in tests;
- cancellation of a deliberately slow query;
- pool exhaustion that fails quickly while health stays live;
- query names in diagnostics, never bound values.

Track query count and repeated decoding code. A query builder or generation
proposal needs an actual friction cluster, not an aesthetic preference.

**Rollback:** HIGH — application code.

### WP106 — Files, validation, search and pagination

Exercise Phase-5/6 surfaces together:

- attachment upload, ownership and cleanup;
- large attachment spool, explicit persistence transfer and quota refusal;
- static download policy and safe content disposition;
- create validation and three-state PATCH;
- unknown-field and nested-field errors;
- stable cursor pagination under concurrent inserts;
- dynamic filters implemented first with explicit SQL;
- file/database transactional boundary and compensation;
- limits and refusal diagnostics.

Do not claim atomic filesystem+database transactions. Specify the compensation
and orphan cleanup job/procedure explicitly.

**Rollback:** HIGH — application code.

### WP107 — Streamed notifications and reconnection

Build a board view where two browser clients observe task changes through
ordinary HTTP commands and SSE notifications:

- ordinary initial HTTP render or JSON load;
- server-pushed add/update/move/comment notifications;
- HTTP requests mapped to domain commands;
- user/stream token ownership;
- heartbeat and reconnect;
- lost-connection state resynchronization;
- authorization rechecked for events and reconnect;
- process deploy while clients are connected;
- no core/internal imports.

The notification tells the client which state changed; the client refreshes or
updates its own view through an explicit application contract. The framework
does not prescribe DOM patching or rendering policy.

**Rollback:** HIGH — application code.

### WP108 — Conflict, backpressure and concurrency tests

Automate:

- two clients editing the same version;
- duplicate/reordered browser event;
- reconnect during update;
- slow consumer and queue saturation;
- many fast clients plus one slow client;
- `lanes - 1` blocked queries while stream delivery continues;
- database pool at cap;
- stale stream token after reconnect;
- route registration and application config immutable while serving;
- memory/capacity counters return to baseline after clients leave.

The product must show a domain conflict or resync, never silent last-write
surprise unless the domain explicitly chose it.

**Rollback:** HIGH — tests.

### WP109 — Observability and operational dashboard

Expose and consume:

- route-pattern counts/latency;
- framework refusal and error events;
- named-query duration/result class;
- pool open/idle/in-use/exhausted;
- stream open/queued/full/closed;
- migration version/dirty status;
- process memory and lane health;
- readiness versus liveness.

The application's own admin view may consume SSE metrics, but the monitoring
path must still diagnose stream failure. Logs and metrics have
cardinality/redaction budgets.

**Rollback:** HIGH — application/ops.

### WP110 — Failure and recovery drills

Run seeded, recorded drills:

- kill/restart application with active requests and streams;
- graceful deploy and forced supervisor kill;
- PostgreSQL restart during query/transaction;
- network interruption and reconnect;
- slow query and pool exhaustion;
- slow browser and full stream queue;
- migration lock contention and dirty refusal;
- upload interruption and storage-full simulation;
- malformed JSON/multipart/wire requests;
- proxy buffering/timeout misconfiguration.

Each drill records expected, observed, detection, recovery and retained data
invariants. “The supervisor restarted it” is recovery only if committed state
and client behaviour remain correct.

**Rollback:** HIGH — tests/operations; never run destructive drills against
unscoped data.

### WP111 — Evolution: migrations, upgrades and adapter rehearsal

Perform at least five forward migrations, including:

- additive column/table;
- backfill under real data volume;
- expand/contract rename or type transition;
- index creation with its transaction mode declared;
- application versions overlapping during a deploy.

Re-pin at least one Odin/Druse/Crystal revision through the documented
upgrade path. Run the complete system against the official `core:net/http`
adapter if available and eligible; otherwise execute the adapter readiness
checklist and record the external blocker without inventing compatibility.

No migration is rewritten after application. Checksums must catch attempts.

**Rollback:** MEDIUM — operational history is intentionally not erased.

### WP112 — Joy-of-programming and AI-readability study

This is a product gate, not marketing research.

Give a human contributor and at least two coding-agent conditions only public
docs/examples, then ask them to implement bounded tasks such as:

- add a validated field through migration, SQL, handler and notification;
- add a protected endpoint;
- add a transactional command;
- diagnose pool exhaustion;
- add one streamed notification.

Record:

- concepts/docs required;
- compile/test iterations;
- invented aliases or internal imports;
- ownership/capacity mistakes;
- framework boilerplate versus domain code;
- compiler and boot diagnostic quality;
- whether independent attempts converge on the canonical shape.

Do not optimize for fastest keystrokes. Optimize for correct code, low concept
count and understandable failure. Amend docs first when the API is sound but
undiscoverable; amend API only with G-09 evidence.

**Rollback:** HIGH — research, with retained evidence.

### WP113 — Product verdict, documentation and Phase-8 freeze

Produce:

- system architecture and operations handbook;
- friction ledger with every item accepted/fixed/refused;
- incident and failure-drill record;
- migration/deploy history;
- capacity and cost report;
- human/AI usability result;
- supported capability matrix and explicit non-capabilities;
- recommendation on whether README retains “microframework”;
- recommendation on release readiness, reserved to the owner.

The README may claim production-oriented data and streaming capability only
for the exact scope proven. Release/tag remains an owner decision.

**Rollback:** HIGH — freeze docs; production data/history is retained.

---

## 7. Exit gates

### G8-1 — No privileged application

No internal import, unguarded patch, friend API or core-specific build flag.

### G8-2 — Evolvable data

Five immutable forward migrations, clean lock/checksum/dirty behaviour and at
least one expand/contract deployment.

### G8-3 — Concurrent product correctness

Two-user conflicts, blocked queries, pool saturation, streamed notifications and reconnect
produce declared outcomes without global stall or silent data loss.

### G8-4 — Operable failure

Every required drill is detected, bounded and recoverable according to the
predeclared invariant.

### G8-5 — Bounded resources

Pool, uploads, request bodies, streams and queues have measured named caps;
post-drill counters/memory return to expected baseline.

### G8-6 — Joy

Independent users/agents complete the canonical tasks from public docs without
inventing a second architecture. Friction is resolved or explicitly accepted.

### G8-7 — Honest positioning

Capability and comparison claims match evidence. “Microframework” remains only
if the seven tests in `phases-6-8-program.md` still hold.

---

## 8. Non-goals

- turning the reference system into framework core;
- generic admin/scaffolding generator;
- automatic ORM/schema synchronization;
- hiding deployment/migrations inside server startup;
- artificial success metrics such as route count or lines of code alone;
- production use of personal/sensitive data before a separate privacy review;
- WebSocket/HTTP2/TLS-in-process merely to make a feature checklist longer;
- release/tag without the owner's explicit decision.

---

## 9. What Phase 8 can legitimately conclude

Success does not prove every web application. It proves one demanding,
multi-user, data-backed system with bounded streaming can be built, evolved and
operated through public Druse contracts — and that the framework remains
pleasant when its independently designed parts meet.

That is the missing evidence between “excellent tests” and “excellent
framework”.
