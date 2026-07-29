# Phase 7 — Streaming foundation: server push, large bodies and bounded I/O

**Status: OWNER-APPROVED PROGRAM PLAN, 2026-07-21; refreshed by WP85 on
2026-07-23 against the Phase-6 freeze and the Phase-6.5 corrective.** The
normative gate is `planning/phase-7-spec.md`; where they disagree, the spec
wins. Entry ledger is **63 application + 2 test-support = 65** (Phase 6 added
no symbol; Phase 6.5 added `web.is_draining`). No signature below is approved
or frozen. Work packages continue at **WP85–WP101**.

**Amendment 1 — 2026-07-22, owner decision: the composition half.** Phase 7
adopts the two-half structure Phase 6 shipped with (concurrency in core, data
in Crystals). This plan is the **core half**, unchanged: WP85–WP101, streaming
in both directions. The **Crystals half — composition** ships in
`druse-crystals` against the Phase-6 core freeze and may run in parallel
with the core half:

- an **`http_client`** Crystal: outbound HTTP/1.1 over `core:net` with a
  bounded connection pool, timeouts and a deadline budget, cancellation
  integrated with drain, bounded retry — and **outbound TLS with real
  certificate verification as an inseparable part**. The official future
  `core:net/http` client is the declared replacement path, mirroring
  ADR-033's server side;
- a **`metrics`** exposition Crystal (Prometheus text format) over the
  existing observer hooks, preserving the redaction rules.

Its spec anchor is `planning/production-service-bom.md`; its work packages
follow the Phase-6 Crystals pattern (spec → RED → implementation → gate →
freeze) and are numbered in the Crystals repository. Phase 8 gains entry
condition E8-7 (composition Crystals frozen) and its reference application
must place at least one real outbound HTTP call. WP85 records this structure
in `planning/phase-7-spec.md`.

**Amendment 2 — 2026-07-22, security-corrective backlog from the Phase-6-freeze
scan.** A `claude-security` scan of the freeze (`e6554e5`) found 14 verified
vulnerabilities. The three unauthenticated process-crash bugs were fixed and
merged immediately (core PR #103: F1 JSON nesting-depth, F2 chunked-trailer
readonly, F3 negative chunk-size). Six more clean, self-contained bugs are
fixed in a follow-up corrective PR (F7 intermediate-directory symlink escape,
F10 Content-Length overflow, F11 out-of-range integer truncation, F12 bare-CR
header injection, F13 unanchored multipart boundary, F14 obs-fold tab). The
remainder are **not** mechanical bug-fixes and are tracked here, because each
either reverses a documented decision or is the shape of work this phase
already owns:

**Amendment 2 status refresh — WP85, 2026-07-23.** F4 was fixed and merged by
Phase 6.5 (core PR #108, ADR-037); no Phase-7 work remains on it. F5/F6 are
decided by `phase-7-spec.md` §8.2 (static joins the dispatch/commit path,
implemented in WP91). F8 folds into WP93/WP94; F9 lands in WP90. The original
backlog text below is retained as the record of what was found:

1. **[FIRST PRIORITY] F4 — leftmost `X-Forwarded-For` is trusted, letting any
   client spoof the resolved client IP** (`web/client_address.odin:150`,
   HIGH). With any `trust_proxies` configured, `client_ip` returns the
   *leftmost* XFF entry — but real proxies (nginx `$proxy_add_x_forwarded_for`,
   AWS ELB, HAProxy) *append* the real peer, so the leftmost value is exactly
   what the client forged. Every control keyed on the client IP — rate limits,
   allow-lists, geo rules, abuse counters, audit logs — attributes the
   attacker's chosen address. This is **not a mechanical fix**: the leftmost
   choice is a *documented design decision* (the file's own comment argues for
   it and calls it "the original client") with a frozen `tests/wp48` suite, so
   correcting it changes the public semantics of `client_ip`. It needs a spec
   note and an ADR amendment before the code changes. **Correct behaviour:**
   with a known trusted-proxy set, walk `X-Forwarded-For` from the RIGHT,
   discarding entries whose source matches a trusted prefix, and return the
   first untrusted address (or the peer if all are trusted); never return the
   leftmost entry unconditionally. This is the first security item WP85's spec
   refresh must schedule as its own corrective work package.

2. **F5 / F6 — static mounts are served before the middleware chain**
   (`web/serve.odin:182`, MEDIUM). Static responses therefore receive no
   `secure_headers` (F5) and run no global `use()` middleware such as auth or
   rate-limiting (F6). This is *entangled with a documented design decision*
   ("a static mount OWNS its prefix. Checked before the router"), so the fix is
   architectural, not a one-line change: it decides whether static serving
   joins the dispatch/commit path (gaining the header policy and middleware) or
   whether per-mount middleware is added and the "global middleware does not
   cover static" limitation is documented. WP85 must choose and spec this
   alongside the streaming commit path it is already redesigning.

3. **F8 — the JSON preflight builds a full parse tree, amplifying a bounded
   body into large transient memory** (`web/json_decode.odin`, MEDIUM). The
   real fix is a streaming/bounded-state preflight instead of a full
   `json.Value` tree — which is exactly the bounded-memory discipline this
   phase's large-body work (WP93/WP94) establishes. It is partially mitigated
   already by the F1 nesting-depth cap. Fold it into the bounded-ingest design
   rather than bolting a second parser on now.

4. **F9 — unhandled `accept()` errors panic the server process**
   (`vendor/odin-http/server.odin:621`, MEDIUM, confidence low). A transient
   `ECONNABORTED`/`EINTR`/`EWOULDBLOCK` at accept aborts the process. The fix
   (tolerate transient `Accept_Error` values and re-arm accept) is small, but
   it sits in the accept/shutdown flow the concurrency gate (WP71/WP72)
   exercises most heavily and is race-dependent, so it belongs in a change that
   re-runs that full fault/drain corpus rather than a quick patch.

The promise:

> A handler may establish a long-lived response and return; later work can
> enqueue bounded output from any thread, while only the connection-owning lane
> touches the wire. Separately, a large request body may be consumed or spooled
> incrementally without occupying RAM proportional to its size, and shutdown
> can still prove cleanup in both directions.

This phase closes two independent HTTP limitations recorded by Phase 5:
incremental long-lived responses and request bodies larger than the in-memory
buffer budget. It does not build a template language, client runtime or
WebSocket.

---

## 0. Why this is core work

The current private boundary is deliberately buffered:

```text
Inbound → synchronous Dispatch_Proc → complete Outbound → request teardown
         → adapter writes status + headers + full body
```

SSE does not avoid the structural change. Server push requires ownership that
outlives `Context`, incremental commit and a wake-up path to the event-loop lane
that owns the connection.

Large uploads require a different structural change: today dispatch starts only
after the adapter has materialized the entire body as `[]u8`. Phase 5 proved
bounded in-memory multipart useful and simultaneously proved its perimeter — a
multi-gigabyte body cannot be supported by raising `max_body` honestly. The
owner has now made that limitation an explicit Phase-7 requirement; no later
“real demand” gate remains.

CE-E3 remains unchanged. Phase 7 is an explicit **core decision**, through the
core's spec, ledger and gates. Optional protocols such as SSE consume the
smallest accepted primitive without privileged access or further core growth.

---

## 1. Entry conditions

| ID | Condition |
|---|---|
| E7-1 | Phase 6 frozen; WP72 accepted concurrent serving and the full Phase-5 feature corpus passes on multiple lanes. |
| E7-2 | **Satisfied (WP85 refresh).** The frozen contract (ADR-030 Amendment 1, WP71/WP72): `max_handlers = 0` selects automatic bounded 4..32; `1` is explicit single-lane compatibility; `2..256` is exact. Application-owned mutable state, observer sinks and logger sinks must synchronize themselves; framework-owned counters and lifecycle flags are atomic or lane-owned; request-local memory never migrates between lanes. |
| E7-3 | **Satisfied (WP85 refresh).** The bounded PostgreSQL pool lives in the **Crystals** data stack (Phase 6, frozen), reached through `App_State` — not in `web`. Acquisition has a hard capacity and deadline with a typed exhaustion result, so the stream lab cannot be invalidated by handlers waiting forever. WP96's blocked-database-Handler cases use the Crystal. |
| E7-4 | ADR-008, ADR-009 and ADR-012 are explicitly reopened only for the long-lived path; buffered responses remain unchanged. |
| E7-5 | The owner records that bounded long-lived responses and large-body ingestion are core HTTP capabilities, while protocol policy such as SSE remains outside `web`. |
| E7-6 | Current transport and Odin toolchain are pinned. Official `core:net/http` is used only if its real API exists and passes a spike. |

If concurrent serving is refused by Phase 6, Phase 7 stops. A long-lived
single-lane system would recreate the global head-of-line failure this program
exists to remove.

---

## 2. Pre-decisions and open decisions

### Fixed before prototyping

- Buffered `Handler :: proc(^Context)` remains the only Handler shape.
- Opening a stream is opt-in and must not add concepts to ordinary endpoints.
- `Context` and every request view die when the Handler returns.
- The adapter/owning lane is the only writer to a connection.
- Sending from another thread means bounded enqueue, never direct socket use.
- User output cannot consume the control capacity required to close/stop.
- Queue full is a typed, observable result; no unlimited waiting or memory.
- After first-byte commit, framework errors close the stream and report out of
  band. They never append a second HTTP envelope.
- A closed/reused stream rejects stale producers.
- The current vendored implementation is bridge work and exposes no public
  backend type.
- Optional stream/SSE executable code must not link into a buffered-only Hello
  World. The Phase-5 static-server incident is the control precedent: unused
  feature code is zero linked executable bytes; unavoidable configuration or
  dispatch storage is measured and justified explicitly.

### Decided by WP86/WP87 evidence

1. specialised SSE primitive versus generic byte/event stream;
2. opaque generational token versus pointer-like handle;
3. per-stream queue versus per-lane queue with stream-indexed entries;
4. copy-on-enqueue versus an advanced owned-buffer transfer;
5. disconnect-on-full versus caller-selected policy;
6. whether the Productive API needs more than open, try-send and close.
7. incremental body consumer versus adapter-managed spool versus bounded ingest
   workers;
8. whether streaming multipart yields parts directly or spools file parts while
   keeping fields bounded in memory.

The recommended starting arm is a generic, bounded stream primitive with a
stale-safe value token; SSE is its first Crystal. It is recommended, not
pre-frozen.

---

## 3. Required state machines

The exact enum is private until evidence requires otherwise, but every
implementation must account for these states:

```text
Reserved → Headers_Committed → Open → Closing → Closed
    │              │             │        │
    └──────────────┴─────────────┴────────→ Failed
```

An outbound item has its own ownership path:

```text
Caller bytes
  → copied/transferred into bounded stream storage
  → queued for owner lane
  → writing
  → sent and released
       or
  → rejected/dropped/closed and released
```

Every transition names:

- owner of connection, queue node and bytes;
- legal thread/lane;
- allocation lifetime;
- observable result;
- cleanup on close, cancellation and process drain.

Generation changes when a registry slot is reused. A delayed producer holding
an old token cannot target the new connection.

Inbound bodies have a separate ownership path:

```text
Reading → In_Memory | Streaming | Spooling → Ready → Consumed → Released
   │             │          │          │
   └─────────────┴──────────┴──────────→ Failed/Cancelled
```

The default `web.body` and Phase-5 multipart path remain buffered and unchanged.
The large-body path is opt-in. Its temporary file or consumer buffer is owned,
bounded and cancelled independently of the response stream registry.

---

## 4. Capacity and backpressure contract

At minimum Phase 7 fixes:

- maximum open streams;
- maximum queued events and bytes per stream;
- maximum total queued stream bytes;
- maximum write progress per lane tick;
- heartbeat/timer capacity where SSE uses it;
- separate control reservation for close and shutdown;
- slow-consumer threshold and terminal policy.
- maximum simultaneous large-body ingests;
- maximum in-memory prefix/field bytes during incremental multipart;
- per-upload and process-wide spool quotas;
- temporary directory ownership, permissions and cleanup deadline;
- disk-full, disconnect and shutdown outcomes.

The generic core does not invent semantic coalescing for arbitrary bytes. Its
canonical full result is refusal or disconnect according to a predeclared
policy. An application protocol may coalesce replaceable state before enqueue
only when it understands that state semantically.

No producer blocks a handler lane indefinitely while waiting for stream space.

---

## 5. Work-package map

| WP | Name | Type |
|---|---|---|
| 85 | Phase-7 spec, ADR reopenings and ledger budget | SPEC |
| 86 | Bidirectional streaming topology and API shootout | PROTOTYPE |
| 87 | Stream/body lifecycle and ownership corpus | TESTS |
| 88 | Stream registry and stale-safe identity | IMPLEMENTATION |
| 89 | Cross-lane bounded delivery | IMPLEMENTATION |
| 90 | Incremental current-transport adapter, both directions | IMPLEMENTATION |
| 91 | Commit, partial-write and failure security | TESTS + IMPLEMENTATION |
| 92 | Response backpressure and slow-consumer policy | IMPLEMENTATION |
| 93 | Inbound body-source and multipart laboratory | SPEC + TESTS |
| 94 | Safe spool and incremental multipart | IMPLEMENTATION |
| 95 | Stream/body stop, drain and forced cancellation | IMPLEMENTATION |
| 96 | Scale, fairness, sanitizer and fault laboratory | TESTS |
| 97 | SSE as the first consumer Crystal | IMPLEMENTATION |
| 98 | Streaming interoperability and proxy laboratory | TESTS |
| 99 | Large-transfer and progress vertical slice | INTEGRATION, separate application |
| 100 | Operations, protocol and migration documentation | DOCS |
| 101 | Phase-7 freeze | FREEZE |

Critical path:

```text
WP84 → 85 → 86 → 87 → 88 → 89 → 90 → 91 → 92
                              └────────→ 93 → 94
                    {92, 94} → 95 → 96
                                    └→ 97
{96, 97} → 98
{94, 96, 97, 98} → 99 → 100 → 101
```

---

## 6. Work packages

### WP85 — Phase-7 spec, ADR reopenings and ledger budget

Create `planning/phase-7-spec.md`. Record:

- ADR-008 amendment: commit for buffered responses stays unchanged; a stream
  commits headers once and has no second HTTP response;
- ADR-009 amendment: the private boundary gains a long-lived capability while
  transport types remain private;
- ADR-012 amendment: ordinary body binding remains single-consumer and
  buffered; a distinct opt-in body-source/spool path may consume incrementally;
- OQ-20 Amendment 1: Phase 5's no-temp-file answer remains true for
  `form_file`, while the large-body path must answer ownership, cleanup, quotas,
  persistence transfer, disk-full, timeout and disconnect independently;
- a new ADR for stream ownership, backpressure and stale identity;
- core versus SSE ownership under CE-E3;
- pre-registered thresholds and refusal rules.

Inventory every public concept candidate under G-09. The target is the fewest
concepts that can express open, bounded send outcome and close, plus one
ordinary large-upload path that does not expose event-loop mechanics. Names
wait for WP86.

**Rollback:** HIGH — documents only.

### WP86 — Bidirectional streaming topology and API shootout

Build disposable candidates that send the same ten updates:

- A: Handler remains alive and writes synchronously;
- B: Handler returns a producer/callback polled by the lane;
- C: Handler opens a detached stream and later code enqueues using a token;
- D: SSE-specific API with no generic stream.

Compare:

- whether a Handler lane remains occupied;
- cross-thread correctness;
- request-view escape risk;
- public concepts and call-site clarity;
- per-event allocation and copy count;
- bounded-full behaviour;
- stop/drain feasibility;
- implementability by test, current and future official adapters.

Candidate A is expected to fail the lane-capacity requirement. Candidate C is
recommended only if the lab proves ownership and usability.

Negative controls deliberately reuse a closed slot and attempt cross-thread
direct writes.

In a second arm, ingest the same large multipart body through:

- E: Handler pulls chunks synchronously from the connection;
- F: adapter incrementally spools before invoking the Handler;
- G: bounded ingest workers spool and then schedule the ordinary Handler;
- H: application-provided incremental consumer.

Compare lane occupation, disk/memory bounds, cancellation, user concepts,
direct-to-object-store feasibility and future-adapter portability. The
recommended Productive arm is bounded spool; an Advanced consumer ships only
if its ownership and ergonomics remain recognizably Odin.

**Rollback:** HIGH — experiments only.

### WP87 — Stream/body lifecycle and ownership corpus

Commit RED tests before implementation:

- open commits status/headers exactly once;
- Handler returns and its arena is destroyed while stream remains valid;
- enqueue copies or takes ownership exactly as specified;
- stale token after close/reuse refuses;
- close is idempotent;
- send racing close has one terminal owner;
- queue-full result is deterministic;
- user capacity full cannot block control close;
- no send after server drain begins;
- test transport observes the same semantic transitions as a socket adapter.
- buffered `web.body`/`form_file` remain byte-identical;
- large-body bytes never coexist fully in RAM;
- temp files are generated privately and removed on every non-persisted path;
- disk-full, timeout and mid-upload disconnect produce typed terminal results;
- a Handler cannot read a request-backed chunk after its callback/read lifetime;
- ingest capacity full refuses before accepting unbounded work.

The control mutation removes the generation check and must make the gate fail.

**Rollback:** HIGH — tests only.

### WP88 — Stream registry and stale-safe identity

Implement the private registry selected by WP86. Prefer contiguous slots,
explicit free list and generation over pointer graphs. A public token, if
needed, is a value that cannot expose registry memory or adapter handles.

Registration occurs on the connection-owning lane. Closing invalidates the
generation before releasing queued items. Reuse is tested under forced tiny
capacity.

**Rollback:** MEDIUM — internal lifecycle foundation plus minimal gated public
surface.

### WP89 — Cross-lane bounded delivery

Allow any Handler lane or approved application thread to attempt an enqueue.
The operation:

1. validates token generation;
2. reserves bounded capacity atomically;
3. copies/transfers bytes into stream-owned storage;
4. publishes to the owner lane;
5. wakes that lane;
6. returns a closed typed result.

Only the owner lane removes an ordinary event for writing. Close/stop uses a
separate control route that remains available under user saturation.

No mutex is held during a socket write. No unbounded MPSC queue ships.

**Rollback:** MEDIUM-HIGH — central concurrency mechanism.

### WP90 — Incremental current-transport adapter, both directions

Extend the private odin-http bridge to:

- commit status/headers without a complete body;
- write incremental body chunks on the owner lane;
- observe short write/would-block/error;
- resume only after the backend reports progress;
- cancel pending writes safely;
- surface bounded inbound chunks without materializing the complete body;
- pause/resume socket reads according to spool/consumer capacity;
- stop reading and retire/cancel correctly on early refusal;
- remove every vendored hook at future adapter replacement.

Measure vendor diff containment, but do not use “any backend state-machine
change kills the project” as the criterion. Streaming inherently needs backend
cooperation. It fails if the implementation leaks backend types publicly,
cannot be removed with the adapter, or cannot prove lifecycle safety.

If official `core:net/http` exists at execution time, a compile/behaviour spike
is added here. Its absence does not block the phase.

**Delivery record (2026-07-23).** The inherited half (ADR-039 write/idle
deadlines, the send-cancellation memory-safety fix, F9) landed first; the
response-direction streaming adapter (chunked commit, owner-lane pump over
the WP88/89 registry, close/disconnect/drain teardown, vendored BRIDGE
patch 22) landed second. **The inbound bullets — bounded inbound chunks,
pause/resume of socket reads, early-refusal retirement — are delivered with
WP94**, whose spool is their only consumer: the mechanism and its consumer
land together, so no dead unexercised hook sits in the transport meanwhile.
This is a delivery-order note, not a scope change; WP94 cannot freeze
without them.

**Inherited into this WP (WP85 refresh, 2026-07-23):**

- **ADR-039 write + idle timeouts.** Phase 6.5's WP-6.5.2 was implemented but
  not merged: the write deadline does not fire (diagnosis and narrowed root
  cause in `phase-7-spec.md` §8.1 — `response_write_started` never reaches the
  Connection the sweep iterates). WP90 rewrites the same vendored transport
  path, so it closes `max_write_time` **and** `max_idle_time` together in one
  `Limits` amendment, proves both on the raw wire (G6.5-2), marks ADR-039
  ACCEPTED and updates `phase-6.5-plan.md`.
- **F9 accept-error tolerance.** Transient `Accept_Error` values are tolerated
  and accept re-armed, inside this WP because its gate re-runs the
  concurrency fault/drain corpus that change needs.

**Rollback:** MEDIUM — bridge patch governed by vendor policy.

### WP91 — Commit, partial-write and failure security

Reproduce the response-splitting risk predicted by the Phase-2 recovery lab.
After headers/bytes are committed:

- framework 4xx/5xx responders cannot append;
- forgotten response finalization cannot append;
- observer/logging may report safely out of band;
- panic follows the existing process-fault policy;
- adapter error closes/cancels the stream;
- short writes never duplicate bytes on retry;
- headers reject CR/LF before first commit;
- body bytes remain body bytes, framed by the adapter.

Middleware unwinds after stream establishment, not after the stream's lifetime;
post-`next` mutation remains forbidden once committed.

**Rollback:** MEDIUM — security contract and implementation.

### WP92 — Response backpressure and slow-consumer policy

Implement byte and event caps selected in WP85. Tests cover:

- one client that never reads;
- queue reaching event cap first and byte cap first;
- many small versus one large event;
- concurrent producers racing for the final slot;
- refusal/disconnect metrics;
- application-level coalescing without core semantic knowledge;
- other streams continuing while one is slow.

Default behaviour must be safe without tuning. Advanced policies are added
only if they are orthogonal and pay G-09.

**Rollback:** MEDIUM — capacity behaviour is public once used.

### WP93 — Inbound body-source and multipart laboratory

Specify the opt-in large-body contract and commit RED tests before spool code.
It must answer:

- memory ownership and chunk validity;
- temporary directory and filename generation;
- file permissions and symlink policy;
- per-upload, concurrent-upload and process spool quotas;
- maximum fields/parts/header bytes;
- persistence transfer versus automatic deletion;
- disk-full and filesystem error classification;
- request deadline and client disconnect;
- early application refusal and unread-body connection policy;
- shutdown and crash leftovers;
- direct-to-object-store consumer feasibility.

The streaming multipart parser is incremental and boundary-correct across every
fragmentation point. It never trusts filename or part Content-Type. The existing
in-memory parser remains its compatibility oracle for bodies within both
perimeters.

**Rollback:** HIGH — spec and committed RED tests.

### WP94 — Safe spool and incremental multipart

Implement the winning Productive arm from WP86/WP93. The expected shape is:

```text
socket chunks → bounded multipart parser → small fields in bounded memory
                                     └──→ generated temporary file
```

The Handler receives an explicitly owned upload resource only after the body is
ready. Automatic cleanup runs exactly once unless the application explicitly
persists/transfers ownership. Admission limits concurrent spools below handler
lane capacity, and aggregate disk quota is checked throughout ingestion.

An Advanced incremental consumer/direct sink is delivered only if WP86 proves
it without a second Handler model, hidden callback lifetime or unbounded queue.
Refusing that arm does not refuse safe large uploads.

**Rollback:** MEDIUM-HIGH — new security/lifecycle surface.

### WP95 — Stream/body stop, drain and forced cancellation

Extend lifecycle in order:

1. stop admission of requests, streams and body ingests;
2. signal existing streams through reserved control capacity;
3. allow bounded queued output according to policy;
4. cancel pending reads/writes/spools/timers at deadline;
5. invalidate tokens;
6. release queues/session hooks exactly once;
7. join every lane.

`max_drain_time` must remain one honest process deadline. A stream-specific
grace field is introduced only if one clock cannot express correct behaviour.

The Phase-5 recv cancellation fix is retained; stream writes, body reads,
temporary files, timers and queue storage join its proof.

**Rollback:** MEDIUM-HIGH — lifecycle integration.

### WP96 — Scale, fairness, sanitizer and fault laboratory

Required cases:

- 3,000 idle open streams;
- 3,000 streams receiving heartbeat/control close;
- updates from every lane to streams owned by every other lane;
- one slow consumer among fast consumers;
- queue saturation plus shutdown;
- stale completion after slot reuse;
- client disconnect before/after enqueue and during write;
- seeded short writes, write failures and delayed wakeups;
- one blocked database-like Handler while stream patches on other lanes flow;
- allocator tracking, sanitizer and repeated startup/shutdown.
- concurrent large uploads mixed with ordinary JSON and SSE;
- disk quota and disk-full injection under active streams;
- disconnect at every multipart boundary and spool lifecycle state;
- process drain with streams and spools active together.

Pre-register liveness and memory thresholds after the harness baseline. Report
per-stream and per-queued-byte memory, not only process RSS.

**Delivery note (WP96, 2026-07-23).** The public streaming surface
(`web.stream`/`Stream`/`stream_send`/`Stream_Send`/`stream_close`, ledger
63→68, Phase-1-freeze Amendment 30) is minted here — the concept the whole
phase builds toward, private until now and reached only through the transport
boundary. G7-6's 3,000-stream scale claim is proven **on the registry in
memory** (`tests/wp96-scale`: 3,000 open/receive/drain, cross-lane fan-out,
zero leak) plus the wire path at modest count (`tests/wp95-drain` 24 streams,
`tests/wp96-public-stream` end-to-end). **Honest limitation, recorded for the
freeze:** 3,000 *real* concurrent sockets need a dedicated quiet CI machine;
this shared development box segfaults socket suites under its baseline load, so
the 3,000-count wire round is deferred to such a machine. A **real memory
defect found and fixed here:** the registry allocated its full ring eagerly
(1024 × 256 KiB = 256 MiB) for every server including buffered-only ones; it
is now lazy per slot (a non-streaming server pays ~150 KiB), honouring G7-8.

**Rollback:** HIGH — tests; failures veto the feature.

### WP97 — SSE as the first consumer Crystal

Ship an SSE package outside `web` using only the accepted stream surface:

- event, data, id and retry encoding;
- newline-safe multi-line data;
- heartbeat comments;
- Last-Event-ID parsing/reconnection contract;
- proxy buffering guidance;
- bounded send outcomes surfaced to the application;
- no backend import and no core amendment.

Raw-wire tests verify framing and reconnection. SSE proves the core abstraction
can support a real protocol without privileged access.

**Rollback:** HIGH — separate package.

### WP98 — Streaming interoperability and proxy laboratory

Exercise the accepted response stream and SSE Crystal through real clients and
the supported reverse-proxy topology:

- `curl -N` and a browser receive events incrementally rather than at close;
- proxy buffering is detected and the supported configuration disables it;
- heartbeat and idle timeouts have declared outcomes;
- `Last-Event-ID` crosses the proxy unchanged;
- a slow client reaches the bounded policy without delaying a fast client;
- client disconnect and process drain release every queued byte exactly once.

The lab distinguishes framework behaviour from proxy behaviour with direct and
proxied control arms. It adds no product/session/rendering policy to core.

**Rollback:** HIGH — tests and disposable deployment fixtures.

### WP99 — Large-transfer and progress vertical slice

Build a small separate application using only public contracts:

- upload a file larger than the buffered-body limit through the spool path;
- validate quota, content metadata and persistence transfer explicitly;
- report application-owned processing progress over SSE;
- reconnect and obtain current progress without assuming event replay;
- download the result through bounded response streaming;
- prove two clients are isolated when one becomes slow;
- interrupt upload, download and deploy, then verify cleanup and drain.

The application may own a worker for its processing step; Phase 7 does not add
a background-job system. The slice decides whether both streaming directions
compose without internal imports or backend escape hatches.

**Rollback:** HIGH — separate integration application.

### WP100 — Operations, protocol and migration documentation

Document common API separately from streams. Add:

- stream ownership/lifetime diagram;
- queue sizing and metrics;
- slow-client policy;
- proxy buffering/timeouts;
- heartbeat and reconnect guidance;
- shutdown semantics;
- the rule after first-byte commit;
- adapter replacement obligations;
- known absence of WebSocket and arbitrary full-duplex protocols;
- buffered versus spooled upload paths;
- temp ownership, quota, persistence and crash-remnant cleanup;
- direct object-store guidance.

No stream concept enters the ordinary Quick Start.

**Rollback:** HIGH — docs.

### WP101 — Phase-7 freeze

Freeze only if:

- all lifecycle, ownership, fault and scale gates pass;
- SSE uses no internal/core escape hatch;
- the interoperability lab and large-transfer slice use no backend type;
- public ledger growth is justified symbol by symbol;
- buffered endpoints remain byte-identical;
- common-path binary/API cost is measured;
- large multipart never requires RAM proportional to body size;
- spool cleanup, disk-full and disconnect gates pass;
- every non-delivered item and limitation is recorded.

Close or retain open the stream ADRs based on evidence. A failed Phase 7 leaves
Phase 6 usable and records streaming as not delivered; it does not weaken the
gates.

**Rollback:** HIGH — freeze records; implementation rollback varies by WP.

---

## 7. Phase-7 exit gates

### G7-1 — Detached lifetime

Handler and request arena are gone while stream output remains valid; no request
view escapes.

### G7-2 — Single writer

Only the owning lane touches transport state. Cross-lane producers can only
enqueue through the bounded mechanism.

### G7-3 — Stale safety

Delayed send/completion against a reused slot refuses and cannot affect the new
stream.

### G7-4 — Bounded backpressure

All queue memory has named caps. Slow clients cannot grow memory indefinitely
or stop unrelated streams.

### G7-5 — Post-commit security

No second response, error envelope or header mutation appears after incremental
commit.

### G7-6 — Honest drain

Three thousand open streams terminate or are cancelled within the declared
deadline, while active body ingests/spools are cancelled or completed by the
same lifecycle with exactly-once cleanup.

### G7-7 — Ecosystem proof

SSE, the proxy laboratory and the large-transfer slice work only through
public accepted contracts.

### G7-8 — Pay only when used

A buffered-only application links no stream writer, registry or SSE protocol
code. Any unavoidable base-layout cost is measured against the **Phase-6**
frozen binary — which already carries the +5,472-byte concurrent path — and
entered in the capacity/cost ledger (re-baselined by WP85; measuring against
Phase 5 would double-charge streaming for concurrency).

### G7-9 — Large-body boundedness

A body larger than memory limits is processed with bounded memory. Temporary
storage has per-upload and aggregate quotas; disk-full, timeout, disconnect and
shutdown leave no falsely persistent file and no unbounded waiter.

### G7-10 — Buffered compatibility

Existing `web.body`, `form_field`, `form_file` and their request-lifetime view
contracts remain byte- and behaviour-compatible. Large-body support is a
distinct opt-in path, not a silent ownership change.

---

## 8. Non-goals

- arbitrary full-duplex request/response protocols;
- WebSocket or HTTP/2/3;
- template/session framework or client runtime in core;
- automatic semantic patch coalescing in `web`;
- background job system;
- arbitrary user callbacks running on event-loop internals;
- blocking send-until-space;
- per-connection application pointer bags;
- transport types in public API;
- promise that a process can recover from memory corruption/panic.

---

## 9. The honest product result

After Phase 7, Druse is still a microframework. Ordinary users still see
app, route, extract, respond and serve; small bodies keep the Phase-5 path.
Applications gain bounded long-lived responses, SSE and progressive output,
while large-body applications gain an explicit spool/consumer path without RAM
proportional to upload size. These remain optional HTTP capabilities; ordinary
buffered applications do not learn their concepts or pay their executable-code
cost.
