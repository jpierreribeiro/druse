# Phase 7 spec — streaming foundation: two orthogonal contracts

**Status:** SPEC, 2026-07-23, WP85, under the ADR-029 delegation and the owner
amendments recorded in `decisoes-do-dono.md` (2026-07-22 block). No public name
below is approved; signatures are born from WP86 evidence and freeze only in
WP101.

**Entry snapshot:** Phase 6 is frozen — the concurrency half in this repository
anchored at `f51fc127`, the data half in `druse-crystals` — and the corrective
Phase 6.5 ran after it (core PRs #103–#111). The live ledger is **63
application + 2 test-support = 65**: Phase 6 added no symbol and Phase 6.5
added exactly one (`web.is_draining`, ADR-040, Phase-1-freeze Amendment 27).
The Phase-7 plan header still says 62 + 2 because it was written before
Phase 6.5; this snapshot corrects it without rewriting history. The full gate
is green at the entry commit. This spec adds no public symbol and changes no
implementation.

The execution plan is `phase-7-plan.md` (owner-approved WP85–WP101, refreshed
by WP85). This document is the normative gate: if the plan and this spec
disagree, this spec wins until an explicit dated amendment records why.

---

## 1. Product decision — two contracts, never one magic stream

Phase 7 delivers **two orthogonal contracts** (program §5):

1. **Detached response streaming.** A Handler opens a long-lived response and
   returns; later code enqueues bounded output from any thread; only the lane
   that owns the connection touches the socket.
2. **Opt-in large-body path.** A request body larger than the buffered budget
   is spooled or consumed incrementally without RAM proportional to its size.
   The buffered path (`web.body`, `form_field`, `form_file`) remains canonical
   and byte-identical.

They share a phase because both extend the same private transport boundary,
not because they are one abstraction. A design that fuses them into a single
public "stream" concept fails this spec.

---

## 2. Frozen facts that bind every work package

Quoted from the Phase-6 freeze and carried as constraints, not aspirations:

- **The lane contract.** "The delivered surface is bounded multi-lane
  synchronous serving: several transport-owned lanes, each invoking ordinary
  synchronous Handlers […] framework-owned counters and lifecycle flags are
  atomic or lane-owned; request-local memory never migrates between lanes."
  The lane that owns a connection executes its Handler **and** writes its
  socket. Streaming must extend this invariant, never bypass it: cross-lane
  producers enqueue; the owner lane writes.
- **The measured base cost.** "The default concurrent-serving path adds
  **+5,472 bytes** to the binary." That Phase-6 binary is the G7-8 baseline;
  streaming's unavoidable base cost is measured against it, not against
  Phase 5.
- **The honest limitation.** "A Handler stuck in non-cancellable foreign code
  can outlive the drain deadline. The framework claims bounded blast radius
  and fail-fast capacity, not preemption of arbitrary blocking code." WP95
  inherits this text verbatim: stream and spool cancellation bound
  framework-owned operations only.
- **One process deadline.** `max_drain_time` remains the single honest process
  drain deadline. A stream-specific grace field may exist only if WP95 proves
  one clock cannot express correct behaviour.
- **Registration discipline.** Registration is single-threaded and closed once
  serving begins; the route/middleware snapshot is immutable. Streams do not
  reopen it.
- **The buffered oracle.** The Phase-5 multipart answer (OQ-20: no temp file;
  `Uploaded_File` is a request-lifetime view into the bounded buffered body)
  is unchanged and is the compatibility oracle for the opt-in path.
- **ADR-033 obligations.** The multipart parser consumes `[]u8` and never
  reads a socket; every vendored hook is a numbered BRIDGE patch in the
  `vendor/odin-http/VENDOR.md` ledger, deletable when `core:net/http` arrives
  (expected January 2027).

---

## 3. Required state machines

The exact enums are private until evidence requires otherwise, but every
implementation must account for these states, and every transition must name
**owner, legal lane/thread, allocation lifetime, observable result, and
cleanup on close/cancellation/drain**.

### 3.1 Response stream

```text
Reserved → Headers_Committed → Open → Closing → Closed
    │              │             │        │
    └──────────────┴─────────────┴────────→ Failed
```

| Transition | Owner | Legal lane | Lifetime | Observable result | Cleanup obligation |
|---|---|---|---|---|---|
| open: Reserved | registry (framework) | connection-owning lane, inside the Handler | until Closed/Failed | token value returned to application | slot freed, generation bumped on any terminal state |
| commit: Headers_Committed | owner lane | owner lane only | headers written once | first bytes on the wire | after commit, framework errors close out of band — never a second envelope |
| send: Open | queue node: stream storage; bytes: copied on enqueue | any Handler lane or approved application thread (enqueue only) | until written or released | typed result closed over {sent, full, closed, stale} | queued items released exactly once on close/cancel/drain |
| close: Closing → Closed | owner lane drains per policy | close request from any thread via reserved control capacity | bounded by policy, then `max_drain_time` | idempotent close result | generation invalidated **before** queued items are released |
| any → Failed | owner lane | owner lane | terminal | out-of-band report (observer), never an HTTP envelope after commit | identical release path as Closed |

Generation changes when a registry slot is reused. A delayed producer holding
an old token targets nothing: the stale send refuses and cannot affect the new
occupant (G7-3).

### 3.2 Outbound item

```text
Caller bytes
  → copied/transferred into bounded stream storage
  → queued for owner lane
  → writing
  → sent and released
       or
  → rejected/dropped/closed and released
```

The Productive contract copies on enqueue. An owned-buffer transfer is
Advanced and ships only if WP86 proves it without a second ownership story.

### 3.3 Inbound body

```text
Reading → In_Memory | Streaming | Spooling → Ready → Consumed → Released
   │             │          │          │
   └─────────────┴──────────┴──────────→ Failed/Cancelled
```

`In_Memory` is the existing buffered path, untouched. `Spooling` writes to an
application-designated temporary directory under the §4.2 quotas. `Streaming`
(a direct incremental consumer) is the Advanced arm — WP86 arms E–H decide
whether it ships at all. The upload resource handed to the Handler is
explicitly owned: automatic cleanup runs exactly once unless the application
explicitly persists/transfers ownership. Its temporary file is bounded and
cancelled independently of the response-stream registry.

---

## 4. Capacity and backpressure contract — pre-registered

These thresholds and refusal rules are fixed **before** WP86 builds a
prototype. A change after seeing a result requires a dated spec amendment made
before the affected result is interpreted (the Phase-6 §5 rule). Defaults must
be safe without tuning; every cap is a `Limits`-style field with `0 = off`
only where off is safe.

### 4.1 Response streaming

| Capacity | Pre-registered default | Refusal rule |
|---|---|---|
| open streams per process | 1,024, and never above `max_connections` | open beyond the cap returns a typed refusal; the connection falls back to an ordinary buffered error response |
| queued events per stream | 64 | enqueue returns the typed full result; nothing blocks |
| queued bytes per stream | 256 KiB | same typed full result; byte cap and event cap are independent, first hit wins |
| total queued stream bytes | 16 MiB per process | enqueue refuses even when the per-stream caps have room |
| write progress per lane tick | 64 KiB per stream per tick | the owner lane round-robins its streams; one stream cannot monopolize a lane tick |
| control reservation | 1 reserved control slot per stream, plus a reserved process-wide control lane for stop | user sends can NEVER consume the capacity needed to deliver close/stop |
| heartbeat/timer capacity | owned by the SSE Crystal, bounded by the open-streams cap | core ships no timer wheel for user protocols |

**Slow-consumer terminal policy.** The canonical full result is **refusal on
enqueue** (typed, observable, non-blocking). A stream whose queue remains full
while the connection accepts no bytes for `max_write_time` (or 30 s where the
application left it 0) is **disconnected**: stream Failed, queued items
released, observer notified. The generic core never invents semantic
coalescing for arbitrary bytes; an application protocol may coalesce
replaceable state before enqueue only when it understands that state.

No producer blocks a Handler lane indefinitely while waiting for stream
space. Blocking send-until-space is a non-goal, permanently.

### 4.2 Large-body ingest

| Capacity | Pre-registered default | Refusal rule |
|---|---|---|
| concurrent large-body spools | `handler lanes − 1`, floor 1 | admission above the cap refuses **before** reading the body (413/503-class typed result); control progress keeps the Phase-6 `capacity < lanes` relationship |
| in-memory prefix/field bytes | 64 KiB per upload | fields and part headers stay bounded in memory; exceeding refuses the request |
| per-upload spool quota | 1 GiB | mid-body breach cancels the spool, deletes the file, answers with a typed terminal result |
| process-wide spool quota | 8 GiB | checked throughout ingestion, not only at admission |
| temp directory | application-designated, required for opt-in; no silent `/tmp` default | files `0600`, unpredictable generated names with the `druse-spool-` prefix, never the client filename |
| cleanup deadline | request teardown; at drain, `max_drain_time` bounds cancellation of active spools | non-persisted files are removed on every path: success, refusal, disconnect, disk-full, shutdown |

**Pre-registered outcomes.** Disk-full and filesystem errors are typed
terminal results and delete the partial spool; the wire mapping is decided by
WP93 evidence, never a silent 200 or a hang. Mid-upload client disconnect
cancels the spool and deletes the file. Shutdown cancels active spools within
`max_drain_time` with exactly-once cleanup. Crash remnants are the documented
operator concern the `druse-spool-` prefix exists for: the core never scans
directories at boot (the no-boot-side-effect rule from ADR-036 territory
holds). Explicit persistence transfer is the only path that leaves a file, and
it renames the file out of the spool namespace.

OQ-20 Amendment 1 is the checklist this section answers in advance:
generated filename, permissions, per-upload/concurrent/process quota,
disk-full, timeout, disconnect, shutdown, crash remnants and explicit
persistence transfer — all fixed here, before spool code exists.

---

## 5. Public-concept inventory under G-09

Baseline: **63 + 2 = 65**. The target is the fewest concepts that can express
open, bounded send outcome and close, plus one ordinary large-upload path that
exposes no event-loop mechanics. Names wait for WP86; the inventory bounds the
budget:

| Concept | Kind | Budget |
|---|---|---|
| open a detached stream from a `Context` | 1 proc | required |
| stream token | 1 value type, stale-safe, no registry memory or adapter handle exposed | required |
| bounded send | 1 proc returning a closed typed result | required |
| send result | 1 closed enum/union {sent, full, closed, stale} | required |
| close | 1 proc, idempotent | required |
| streaming capacity fields | fields on existing `Limits`-shaped config, not names | field-cost precedent (Phases 4–6) |
| opt-in large-body enablement | field(s), not names | field-cost precedent |
| owned upload resource | 1 type + at most 2 accessor/transfer procs | required for the spool path |

Ceiling: **≤ 8 new application symbols** for the whole phase, before WP101
justifies each one symbol-by-symbol. Anything beyond the table (a second
handler shape, a timer API, a coalescing hook, a public backend type) is
refused by this spec. Optional stream/SSE executable code must not link into a
buffered-only Hello World (G7-8); the Phase-5 static-server incident is the
control precedent.

---

## 6. Sync/async tie-in — this phase is the specialised path

The owner asked whether the project "is async by nature". The analysis stands:
the connection layer is already asynchronous (`core:nbio`); the synchronous
part is Handler execution, by measured and reversible decision; whether
ordinary Handlers become async is a research contract
(`planning/sync-async-evaluation.md`) whose trigger sits in Phase 8. **Phase 7
is the specialised async path that document's own decision rule anticipates**
("If async wins only long-lived streaming, ship the specialised Phase-7 path;
do not replace ordinary Handlers").

### 6.1 Terminology, so different mechanisms are not given one name

Reproduced from `sync-async-evaluation.md` §1; every Phase-7 document uses
these terms:

| Layer | Current Druse | Meaning |
|---|---|---|
| connection I/O | asynchronous/non-blocking | `core:nbio` waits for socket readiness without one Handler/thread per idle connection |
| application Handler | synchronous | one ordinary procedure runs until it returns |
| application concurrency | bounded multi-lane | several synchronous Handlers may run concurrently |
| dependency I/O | normally blocking | libpq, filesystem and most C libraries hold their calling lane |
| streaming | **Phase 7, this spec** | a specialised long-lived response lifecycle, not a Handler model change |
| general task runtime | absent | no Future, Promise, async/await, continuation scheduler or implicit worker pool |

### 6.2 WP86 executes two scheduled evidence questions

WP86 answers the two `architecture-evidence-questions.md` §3 rows whose
trigger is Phase-7 entry — "Is response streaming contained above the
connection backend?" and "Are large requests better served by spool or direct
streaming?" — in the §1 required format: observable decision, baseline with
the claim it does not support, at least two arms including shipped behaviour,
semantic equivalence before timing, pre-declared kill/tie rules, and losing-arm
numbers recorded. Prototypes are disposable and never imported by `web`
(evidence checklist §9). OQ-32 — can both directions share one private
lifecycle without a second Handler model? — is the question WP86 answers with
evidence, and it is **in execution** as of this spec.

### 6.3 Executor-agnostic substrate

The stream registry, cross-lane queue and owner-lane wakeup are
**executor-agnostic**: they must not assume the producer is a Handler lane.
An approved application thread is a first-class producer. This is deliberate:
arm B of a future sync/async shootout (event lanes plus bounded job pool)
reuses this substrate rather than duplicating it — `sync-async-evaluation.md`
§3-B names Phase 7's machinery as its natural substrate.

### 6.4 Handoff note for WP102 (named, for the Phase-8 refresh)

When WP102 refreshes the Phase-8 plan, it must pre-register a **reproducible
capacity envelope** for the reference system: the measured maximum sustained
load N on the pinned environment, with the open-loop methodology of
`sync-async-evaluation.md` §6, and a **nominal operating margin of 50–70% of
the measured N** for the deployment guidance. A reference app promoted without
a reproducible envelope invalidates the Phase-8 exit claim. This note is
recorded here because Phase 7 owns the last plan refresh before WP102 runs.

---

## 7. The Crystals half — composition

Per the owner decision of 2026-07-22 (recorded in `decisoes-do-dono.md`,
merged in PR #102), Phase 7 mirrors Phase 6's two-half structure. This spec is
the core half's gate; the **composition half** ships in `druse-crystals`
against the frozen Phase-6 core (`f51fc127`) and may run in parallel:

- **`http_client`** — outbound HTTP/1.1 over `core:net`: bounded connection
  pool, timeouts/deadline budget, cancellation integrated with drain, bounded
  retry; **outbound TLS with real certificate verification (OpenSSL FFI) as an
  inseparable part** — never promised separately. Declared replacement: the
  future `core:net/http` client, mirroring ADR-033's server side. Concurrency
  model per the recorded guidance: event loop (`core:nbio`) or a small
  hard-capped worker pool with a typed `Full` result — never
  thread-per-task, never an unbounded queue. Retry plus backup is
  at-least-once, stated honestly.
- **`metrics`** — Prometheus text exposition over the existing observer hooks,
  redaction rules preserved.

The spec anchor for the half is `planning/production-service-bom.md`
(CORE/CRYSTAL/DELEGADO/RECUSADO/ABERTO — no unclassified item; entry gate of
WP102). The half follows the Phase-6 Crystals pattern (spec → RED →
implementation → gate → freeze) with WPs numbered in the Crystals repository,
estimated 4–6 packages. Phase 8 gains entry condition **E8-7: composition
Crystals frozen**, and its reference application must place at least one real
outbound HTTP call (webhook with timeout, bounded retry, cancellation on
drain). WP97 (SSE) also lives in the Crystals repository, against the frozen
Phase-7 core surface.

---

## 8. Inherited corrective work — bound to named WPs

### 8.1 ADR-039 (write + idle timeouts) closes inside WP90

Phase 6.5 left exactly one package unmerged: WP-6.5.2. The write-deadline
implementation was complete on paper — `Limits.max_write_time`, the
config→adapter plumbing, vendored BRIDGE patch, ledger amendment, a
slow-reader socket test — but the deadline **does not fire**: a stuck write is
not closed, while `max_request_time` on the same sweep demonstrably is. The
narrowed root cause: `response_write_started` never arrives set on the
`Connection` the sweep iterates, even though tracing points at
`response_send_got_body` as the send path — either the real send bypasses that
proc under `web.serve`, or a Connection/build identity diverges. The next
investigative step is recorded: prove which proc emits the send under
`web.serve` with an observable close keyed on a field set at the top of
`response_send_got_body`; check for a second `response.odin` instance; inspect
the adapter's `write_response`/`respond`. Known trap: a test importing
`druse:vendor/odin-http` directly reads a **different package instance**
than `web` uses — measure behaviour, never counters.

WP90 rewrites exactly this vendored transport path for incremental writes, so
the deadline work lands there, with the backend in hand, instead of in an
isolated context. Obligations:

- `max_write_time` **and** `max_idle_time` ship together in **one** `Limits`
  amendment — the idle keep-alive slot vector is the sibling of the stalled
  write, and ADR-039 covers both fields;
- raw-wire proof: a stalled write and an idle keep-alive are each closed at
  their configured deadline (the unmet G6.5-2);
- on completion, ADR-039 moves PROPOSED → ACCEPTED and `phase-6.5-plan.md`
  records WP-6.5.2 as delivered by WP90.

### 8.2 Security backlog refresh (plan Amendment 2, status as of 2026-07-23)

- **F4 is fixed and merged** (Phase 6.5, core PR #108, ADR-037): `client_ip`
  walks `X-Forwarded-For` from the right. No Phase-7 work remains.
- **F5/F6 — decided by this spec.** Static mounts currently serve before the
  middleware chain, so static responses receive no `secure_headers` and no
  global middleware. Decision: **static serving joins the ordinary
  dispatch/commit path.** A static mount keeps prefix ownership (the routing
  decision is unchanged — no router fallback), but its response is produced
  through the same middleware chain and response-header policy as router
  responses. Implementation and its corpus belong to **WP91** (the commit-path
  security package), which is already rebuilding the commit path this change
  rides on. The compatibility note: applications relying on static bypassing
  auth middleware are relying on the vulnerability.
- **F8** (JSON preflight builds a full parse tree) folds into the
  bounded-ingest design of **WP93/WP94**, as the plan already directs.
- **F9** (unhandled `accept()` errors panic the process) lands in **WP90**:
  it patches the same vendored accept/serve flow WP90 rewrites, and WP90's
  gate re-runs the concurrency fault/drain corpus that change needs.

---

## 9. Exit gates, reaffirmed

G7-1 through G7-10 of `phase-7-plan.md` §7 stand as written, with one
correction made by this spec and mirrored in the plan:

- **G7-8 (pay only when used), re-baselined:** a buffered-only application
  links no stream writer, registry or SSE protocol code; any unavoidable
  base-layout cost is measured against the **Phase-6 frozen binary** — which
  already carries the +5,472-byte concurrent path — and entered in the
  capacity/cost ledger. Measuring against Phase 5 would double-charge
  streaming for concurrency.

The remaining gates bind verbatim: detached lifetime (G7-1), single writer
(G7-2), stale safety (G7-3), bounded backpressure (G7-4), post-commit security
(G7-5), honest drain of 3,000 streams plus active spools (G7-6), ecosystem
proof through public contracts only (G7-7), large-body boundedness (G7-9),
buffered compatibility (G7-10).

A failed Phase 7 leaves Phase 6 usable and records streaming as not
delivered; it does not weaken the gates.

---

## 10. Refusal and stopping rules

The affected contract is refused, with evidence, if:

1. detached streaming requires a public backend type, a second Handler shape
   or an uncontained transport rewrite;
2. stale-safe identity cannot be proven under forced slot reuse;
3. bounded cross-lane delivery requires an unbounded queue, a mutex held
   during a socket write, or blocking send-until-space;
4. the large-body path cannot prove exactly-once cleanup on every terminal
   path, or requires RAM proportional to body size;
5. drain cannot bound framework-owned stream/spool operations within
   `max_drain_time`;
6. SSE cannot be expressed outside `web` through the accepted surface;
7. the concept budget of §5 is exceeded and WP101 cannot justify each symbol.

Refusing the Advanced incremental consumer (WP86 arm H) does not refuse safe
large uploads; the Productive spool arm stands on its own.

---

## 11. Rollback

WP85 is documentation and an executable document gate only. **Rollback:
HIGH.** Later WPs carry their own grades as recorded in the plan. This spec
authorizes no release, no tag, and no destructive operation outside
explicitly disposable test resources.
