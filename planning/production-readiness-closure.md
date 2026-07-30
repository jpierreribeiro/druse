# Production Readiness Closure — the systemic pass the write-deadline revealed

**Status: EXECUTED, 2026-07-24.** All eight work packages delivered; see the WP
table in §5 for each one's outcome and `planning/closure-record-and-verdict.md`
for the reconciled record and the verdict. Owner-directed after the
write-deadline finding and two external analyses (production-readiness review;
httprouter comparative study).

**What it found:** four production-blocking defects, all pre-existing on `main`,
none detected by any existing suite — three of which made `web.stop` never
return. Plus two parallel limitation lists that had already drifted into
asserting that shipped features did not exist.

This document proposes inserting a **systemic closure phase** between the
feature-completion corrective (Phase 7.5) and proof-by-use (the current Phase
8). It also folds the httprouter work in as a bounded, non-blocking research
package.

---

## 0. What the fourth accidental finding actually revealed

The write deadline was not an unknown need that appeared from nowhere. It was in
the original contract (Phase-3 plan named configurable "read/write timeouts"),
was deliberately declined at the Phase-3 freeze because the backend had no real
deadline mechanism (the correct call — better no field than a field that does
nothing), and the freeze recorded exactly that: no read timeout, no write
timeout, event-loop surgery required, add by amendment later. The read side then
shipped for slowloris; the write side stayed pending — and **stopped existing as
a tracked item until it resurfaced in conversation.**

So the real question is not *"how did nobody notice a server needs a write
deadline?"* It is:

> How did a known, recorded pending item stop being trackable until it
> reappeared by accident?

**The diagnosis: Druse has an excellent per-feature discipline** (spec →
tests → implementation → freeze → ledgers) **but no layer above it** that
reconciles every promise and pendency into one readiness matrix before
"production" is claimed. The facts are correct in each document (phase plans,
freezes, `operations.md`, ADRs, the experiment backlog, code comments, the
known-limitations lists); the risk lives in the **reconciliation between them.**
The architecture-evidence backlog is a list of trigger-gated *questions*, not a
list of *minimum production requirements over what already exists.*

This is not "the framework is bad." It is the opposite: the framework is now
mature enough to run a **review-by-resource-and-state** pass instead of only
review-by-feature. That change tends to surface a **finite, administrable** set
of gaps and then stop surfacing them randomly, because the analysis space has
been enumerated.

---

## 1. Where this sits in the roadmap (and the renumbering question)

Proposed order:

```text
Phase 7 (frozen: streaming)
  → Phase 7.5   feature-completion corrective (composition Crystals + public upload)
  → Production Readiness Closure   ← THIS PHASE (systemic review-by-resource)
  → Proof-by-use / reference system   (the current Phase-8 plan)
```

The closure must precede proof-by-use, because proof-by-use on an unreconciled
foundation keeps discovering gaps one at a time — which is exactly the failure
mode this phase exists to end.

**The renumbering decision (owner's call — recorded with its cost):**

- **Option R1 — keep numbers, insert a distinct phase.** The closure becomes a
  named phase (e.g. "Phase 7.9 — Production Readiness Closure") with WP
  identifiers that do NOT collide with the frozen ranges; proof-by-use stays
  **Phase 8 / WP102–113, untouched.** Cost: none — no frozen gate changes.
- **Option R2 — the owner's floated framing.** The closure becomes the new
  **Phase 8**; proof-by-use becomes **Phase 9**, its WPs renumbered. Cost: the
  **frozen** `build/check_phase6_spec.sh` asserts *"WP85-WP101 and WP102-WP113
  are numbered and bounded"*; making WP102+ mean the closure and renumbering
  proof-by-use requires a **dated amendment to that phase-freeze gate** plus
  renumbering `phase-8-plan.md`. Achievable, but it edits a frozen governance
  gate for a labelling change.

**Recommendation: R1.** The conceptual value (closure before proof-by-use) is
identical either way, and R1 buys it without amending a frozen gate — the same
reasoning that kept the Phase-7 composition half from renumbering Phase 8. If
the owner wants the clean "8/9" labels, R2 is a one-amendment cost, taken
knowingly.

The rest of this plan uses the neutral name **"the Closure"** and leaves the
final phase number to the owner.

---

## 2. The method — three instruments, then classification

### 2.1 The async-operation inventory (the strongest test)

Enumerate **every `nbio` operation the server starts** — `accept`, `recv`,
`send`, `timeout`, `close`, `wake-up` — and answer, per operation:

1. Who creates it?
2. Where is the handle stored?
3. Who can cancel it?
4. Can the callback fire after cancellation?
5. Can the callback touch freed memory?
6. Who cleans up on success?
7. Who cleans up on error?
8. Who cleans up at shutdown?
9. Is there a maximum deadline?
10. Is there a test interrupting it in each state?

This is precisely the analysis whose ABSENCE let the old pending `recv` outlive
its connection (endless drain + use-after-free, fixed by storing
`pending_recv`), and whose application to `send_poly` would have found the
write-deadline/cancellation gap structurally — no need to know the name "write
deadline" in advance. **WP90a already stored `pending_send` and added the
cancellation + abort**; the inventory confirms that fix is complete and checks
`accept`/`timeout`/`wake-up` with the same rigor.

Deliverable: a table in `production-readiness-closure.md`, one row per op, every
cell answered or flagged.

### 2.2 The resource × property matrix

For every framework-owned resource, one row; columns: **limit, deadline,
cancellation, saturation policy, metric, shutdown behaviour.** An empty cell is
a visible gap, not a forgotten question. The starting matrix (to be verified and
completed, not taken as truth):

| Resource | Limit | Deadline | Cancellation | Saturation | Metric | Shutdown |
|---|---|---|---|---|---|---|
| connection | `max_connections` | — | close socket | refuse | `refused_connections` | yes |
| request read | body/headers caps | `max_request_time` | cancel recv (`pending_recv`) | close | event/log | yes |
| handler | `max_handlers` | application | not preemptible | stop admission per lane | indirect | limited |
| response write | **response size unbounded** | `max_write_time` (WP90a) | cancel send (`pending_send`, WP90a) | retains conn/memory; RST at deadline | refused/aborted counters (WP92) | partial |
| detached stream | §4.1 caps | per-stream 30s default | close/retire | disconnect | stream counters (WP92) | drain (WP95) |
| spool ingest | quotas (§4.2) | request deadline | cancel (exactly-once) | admission refuse | — (substrate) | drain |
| per-connection arena | partly controlled | — | cleanup | retention needs soak | not consolidated | yes |
| accept backlog | kernel | — | kernel | kernel | external | external |

The matrix immediately shows the residual amber cells: **response size has no
limit**, **arena retention is unmeasured (soak)**, **write/stream metrics are
partial**, **combined saturation is unmeasured**.

### 2.3 The closed fault-injection campaign

Run a fixed scenario grid once, instead of discovering one at a time. Axes:

- **Input:** connect-and-send-nothing; one byte/second; truncated request line;
  truncated headers; truncated fixed body; truncated chunked body; ambiguous
  framing; disconnect as the handler begins.
- **Execution:** handler blocks; handler returns without responding; handler
  responds then faults; all lanes busy; database slow; client disconnects while
  the handler runs.
- **Output:** client never reads; client reads slowly; client reads part then
  stops; response larger than the TCP buffer; error during `send`; keep-alive
  after a healthy response; disconnect during response.
- **Lifecycle:** shutdown during accept / recv / handler / send; shutdown
  between callback and cleanup; deadline and shutdown expiring together; second
  `stop`; supervisor kill after drain.

Many cells are already covered (WP41 fault lab, WP58/59 drain, WP72 concurrency,
WP90 deadlines, WP91/92 stream security/backpressure). The campaign's job is to
prove the grid is **complete**, fill the blanks, and leave a single executable
matrix — promoting the backlog's "each new async op must prove shutdown, stale
completion, ownership, cancellation" from a future question to a **full
inspection of what already exists.**

---

## 3. Classification — not everything found is a blocker

Every gap the instruments surface is labelled exactly one of:

- **Defect** — violates an existing promise (e.g. the old silent keep-alive
  close). Fix in-phase.
- **Production-blocking absence** — a framework-controlled operation can retain
  resources indefinitely with no reasonable guard (the write deadline was
  this). Fix in-phase.
- **Acceptable operational limitation** — explicitly delegated to another layer
  (TLS→proxy, total memory→cgroup, backlog→kernel, restart→supervisor).
  Acceptable **only if** the topology is mandatory, documented and tested.
- **Future work** — useful but not required for an ordinary JSON/stream service
  (WebSocket, in-process HTTP/2, OpenAPI, a CPU executor, adaptive concurrency).
  Stays evidence-gated in the backlog.

This is the guard against a "framework is never ready" spiral: the closure ends
when the space is enumerated and every cell is classified — not when nothing
could ever be improved.

---

## 4. The perimeters to close before "production-ready"

Verified against current state (several are already green from Phase 5–7):

1. **Write deadline + `send` cancellation.** ✅ DONE (WP90a: `max_write_time`,
   `pending_send`, RST abort). Closure confirms via the inventory.
2. **Unbounded response size** and its arena/memory impact. ⚠️ OPEN — no size
   limit; the write deadline bounds *time held*, not *bytes*. Decide: a
   `max_response_bytes` limit, or a documented "the application owns response
   size; set a cgroup" with a test.
3. **Memory retention after large responses (soak).** ⚠️ OPEN — a backlog item;
   run an hours-long soak with per-connection/arena attribution.
4. **Shutdown of every async op, not just recv.** ◑ MOSTLY — recv
   (`pending_recv`) and send (`pending_send`) cancel; the inventory verifies
   `accept`/`timeout`/`wake-up`.
5. **Client disconnect during handler**, and where the response goes. ◑ MOSTLY
   — covered for the drain path; the campaign proves the handler-active case.
6. **Combined saturation** (connections + handlers + database + memory). ⚠️
   OPEN — the backlog's "which queue saturates first" question, unmeasured.
7. **Write observability** — deadline-expired, send error, bytes/logical
   response size. ◑ PARTIAL — WP92 added refused/aborted counters; response
   bytes are not exposed.
8. **The exact reverse-proxy contract** — timeouts, buffering, upstream
   keep-alive, duplicated limits. ◑ PARTIAL — `operations.md` documents it
   (WP100); formalize as a tested contract (direct vs proxied control arms
   exist in WP98).

The RST-flood liveness wedge (flagged by the F-002 security report as
follow-up) is a **defect/absence** the campaign owns: under sustained RST the
server stops accepting (threads alive, backlog fills, no crash). Moved here from
the Phase-7.5 hardening track, because it is exactly a review-by-resource
finding on the WP71 accept/lane path.

---

## 5. Work packages (the Closure)

| WP | Name | Type | Deliverable |
|---|---|---|---|
| **C-01** | Async-operation inventory | AUDIT + TESTS | ✅ **DONE.** `planning/closure-async-op-inventory.md` — 22 operation-creating call sites × 10 questions, census gated by `build/check_c01_controls.sh`; `tests/c01-async-ops` interrupts the four states nothing else did. Six findings (§2 there): **F-C01-1** fixed in-phase (vendored patch 24 — an unguarded accept re-arm left an unreachable operation that made shutdown unreachable at fd exhaustion); F-C01-2/3/4/5 classified as declared limitations for the C-02 matrix; **F-C01-6** is a named trigger (the vendored `respond_file` chain drops three handles whose callbacks dereference a freed `^Connection` — gate-enforced unreachable). |
| **C-02** | Resource × property matrix | AUDIT + DOCS | ✅ **DONE.** `planning/closure-readiness-matrix.md` — 14 framework-owned resources × 8 properties, no unanswered cell, gated by `build/check_readiness_matrix.sh` (structure, every `web.Limits` field placed, every public counter placed, the doc pointers hold). It is now the canonical limitations list; `docs/operations.md` §10 and `docs/quick-start.md` point at it, which **closes step 4 of `planning/process-remodel.md`**. The finding that justified the WP: those parallel lists had already drifted into *asserting shipped features did not exist* (upload "no public API yet", "will not spool to disk", "no streaming") — so the gate also forbids re-asserting them. |
| **C-03** | Closed fault-injection campaign | TESTS | ✅ **DONE.** `planning/closure-fault-campaign.md` — 34 cells across four axes (25 covered by existing suites and cited by test name, 6 filled by `tests/c03-fault-campaign`, 1 declared, 1 external, **0 unanswered**), gated by `build/check_c03_controls.sh`. **Two production-blocking defects found and fixed, both pre-existing on `main`:** the inherited **RST-flood wedge** — measured, and the measurement corrected the report (the server never stops *accepting*; it stops *admitting*, because every RST'd connection holds a slot for the whole 500 ms `Conn_Close_Delay`). 1 healthy probe in 59 before, 56 in 56 after (vendored patch 25). And **F-C03-1**: the drain loop's `#partial switch` omitted `.Will_Close`, so a single client sending `Connection: close` and not reading its response made `web.stop` **never return, past every deadline** — `max_drain_time` bounded nothing for the most ordinary client there is (vendored patch 26). |
| **C-04** | Response-size and memory closure | IMPLEMENTATION or DECISION + SOAK | ◑ **ATTRIBUTION CORRECTED; SCALE RUNS OWED.** `planning/closure-response-size-and-memory.md`, gated by `build/check_c04_controls.sh`. ADR-045 subsequently shipped `max_response_bytes`. The original claim that a completed connection retained ~1× its largest response was false: instrumentation around the real cleanup measured 25,167,567 arena bytes live during one 4 MiB response, then one 1 MiB reservation, 4,040 bytes committed and zero used after `free_all`; the negative control retained all seven large blocks and failed. The short soak shows no continuing RSS growth across 1,600 small requests, but remaining RSS is allocator/process high-water, not a live owner. A concurrent buffered-response matrix and the *hours-long* mixed-size soak remain owed beside the 3,000-real-socket SSE round. |
| **C-05** | Write & saturation observability | IMPLEMENTATION | ◑ **PERIMETER 6 DONE, PERIMETER 7 SPECIFIED.** `planning/closure-saturation-and-write-observability.md` + `tests/c05-saturation`, gated by `build/check_c05_controls.sh`. **The lab found a third production-blocking defect: F-C05-1** — `handler_lane_enter`'s accept-cancel spin was unbounded, wedging shutdown in **4 runs of 6** on pristine `main`; fixed by vendored patch 27 and later made structurally non-spinning by patch 28. **Perimeter 6 re-measured after dedicated accept:** ten current runs all saturated, recovered, served after the ramp and shut down; the first observed refusal was lane saturation in 8 and admission refusal in 2. Its ordering is scheduler-dependent and is no longer gated. The stable capacity rule is `lanes ÷ dwell`, while connection slots bound waiting/admission. **Perimeter 7 shipped later as `web.Server_Stats`/`web.stats()` (H-3).** |
| **C-06** | The reverse-proxy contract | TESTS + DOCS | ✅ **TWO CLAUSES PROVEN, TWO OWED.** `planning/closure-proxy-contract.md` + `tests/c06-proxy-contract`, gated by `build/check_c06_controls.sh`. **`proxy_buffering off` is proven MANDATORY, not advisory:** against a stream that does not complete in the window, a buffering proxy (nginx's default) delivered **nothing in 1.23 s**, while direct and unbuffered-proxy arms both delivered the first chunk at **~150 ms** — so the required configuration costs 0.1 ms and the default breaks a shipped feature outright. **The forwarded client address is proven believed only from a trusted hop** (trusted → `203.0.113.7`; direct → socket peer; untrusted-with-header → socket peer, the security half). The proxy is a **fixture in the suite** — no proxy binary exists on the gate machine — so it proves the contract is *satisfiable*, not that nginx satisfies it: a **real-proxy round is recorded as owed**, with upstream keep-alive and duplicated limits through a *pooling* proxy. |
| **C-07** | Closure record + verdict | FREEZE + DOCS | ✅ **DONE.** `planning/closure-record-and-verdict.md`, gated by `build/check_c07_controls.sh` (every cited artifact still exists and is still wired into the gate; the exit condition quoted verbatim, not paraphrased; the one open defect still named; every deferral still carrying a trigger). **Exit condition: MET** — 23 operations, 14 resources, 34 fault cells, **zero unclassified**. **Verdict: production-ready for a CONTROLLED PILOT** behind a proxy with `proxy_buffering off`, under a supervisor with a kill timeout, inside a cgroup sized from the corrected C-04 concurrent campaign, with `max_write_time`/`max_idle_time` enabled. One residual defect (**F-C03-2**, unexplained low-rate crash under gate load) is named with its instrument, not buried. |
| **C-08** | httprouter comparative study | RESEARCH (non-blocking) | ✅ **STEP 1 DONE, STEP 2 DEFERRED WITH A CRITERION.** `planning/closure-httprouter-study.md` + `tests/c08-router-corpus` (10 cases, green), gated by `build/check_c08_controls.sh`. Ported as a **NEGATIVE** corpus: six cases pin the deliberate differences (precedence *with backtracking*, no trailing-slash redirect, no case correction, dot/empty segments refused before routing, no catch-all, fail-closed conflicts), so a regression *toward* httprouter fails the build. BSD-3 notice reproduced in full and gate-protected; **zero public API change**. The `radix_compact` experiment is deferred with an explicit criterion — kept only on material gain, and it must pass the backtracking test unchanged. Recorded finding about the method: two assertions were wrong when first written, both by importing httprouter's expectations. |

**Exit condition (the closure's verdict must satisfy):**

> No framework-owned operation exists without an explicitly declared owner,
> capacity, deadline, or cancellation; and where something is unbounded or
> external, the responsible topology is named, mandatory, documented and tested.

A residual that is a classified **acceptable operational limitation** does not
block the verdict; an unclassified cell or a **blocking absence** does.

---

## 6. The httprouter comparative study (WP C-08, non-blocking)

`httprouter` (Go) is **reference, not dependency**: Druse already has a
private, segment-oriented radix router (the WP29 benchmark fell from ~883 µs to
~1.5 µs at 5,000 routes, near-constant 5→5,000). Value ranking: copying the
router — low; **implementation reference — high; test corpus — very high;** a
new benchmark competitor — high; copying its HTTP semantics — low/dangerous.

Two bounded steps, in order:

1. **Now (high return): port the edge-case corpus.** Translate httprouter's
   test cases — overlapping prefixes (`/contact`, `/co`, `/c`), Unicode routes,
   multi-param, deep paths, catch-all, static-vs-param conflicts, differently
   named params in the same position, invalid routes, trailing slash, method
   collection for OPTIONS — into `tests/router_external_corpus_test.odin`, **not**
   to prove Druse behaves like httprouter but to prove **every difference is
   deliberate.**
2. **Later (measurement): an experimental `radix_compact`.** A private,
   experimental compressed-radix competitor (`radix_idx` = current;
   `radix_compact` = httprouter-inspired) measured in Druse's own harness for
   the one unmeasured cost — **registration time and memory** (a node + a map per
   distinct segment): registration/route, memory at 50/500/5,000 routes, node/map
   counts, teardown cost, lookup p50/p95, `Allow` build, deep/shared-prefix
   behaviour. **Keep only on material gain**, same harness, same gate.

**What must NOT be copied** (Druse's deliberate semantics, to preserve as a
**negative corpus**):

- **Precedence:** httprouter forbids a static and a param route at the same
  position; Druse's rule is **static wins param**, WITH controlled backtracking
  (`/users/me/settings` + `/users/:id/profile`; a request to `/users/me/profile`
  must abandon the static branch and try the param branch). A literal port of
  httprouter's tree would break this — any compact implementation must keep the
  backtracking.
- **Automatic path correction** (trailing-slash redirect, case-fix, path
  cleanup) — directly conflicts with Druse's security policy: no
  normalization, `/users` ≠ `/users/`, case-sensitive, reject `..`/`.`/`//`/
  `%2F`/`%00` before routing. This is a **contrast/negative corpus**, never a
  feature to copy.
- **Catch-all (`*filepath`)** — possibly useful later (reverse proxy, SPA
  fallback, path-preserving gateways), but Druse already has safe static
  mounts; do **not** add `*filepath` to core without a real case the current
  system cannot express. httprouter's code/tests are a good reference **if** the
  need arises (last-segment-only, conflict rules, precedence, alloc-free
  capture).

**What Druse already has and need not borrow:** automatic HEAD/OPTIONS, 405
with frozen-order `Allow`, alloc-free per-request params, conflict diagnostics
(`/users/:id` vs `/users/:uid` refused), and the deliberate absence of panic
recovery (Odin has none; supervision is the model).

**Licence:** httprouter is BSD-3-Clause — modification/redistribution allowed;
any translated/adapted code must preserve the copyright notice and conditions.

---

## 7. Reconciliation with Phase 7.5

Phase 7.5 (`planning/phase-7.5-plan.md`) stays the **feature-completion**
corrective — the composition Crystals (`http_client`, `metrics`) and the public
large-body upload — because those are missing *surfaces* Phase 8/9 depends on
(E8-7, E8-2). Its **Track B (hardening)** — the RST-flood wedge, the
memory/soak items — **moves into this Closure** (C-03/C-04), where it belongs as
review-by-resource work. The one exception is the **3,000 real-socket SSE
round** (a G7-6 wire proof): keep it wherever a quiet CI machine first becomes
available; it is listed in both plans and should be run once, not twice.

Net effect on Phase 7.5: it narrows to the two feature tracks (composition
Crystals + public upload); the Closure absorbs the systemic hardening and adds
the inventory/matrix/campaign that make the write-deadline class of gap
impossible to lose again.

---

## 8. Rollback

The Closure is audit, tests, docs and small targeted fixes — additive and
revertible. The only new public surface it might mint is a `max_response_bytes`
limit (C-04) *if* the size decision goes that way, which pays the normal ledger
amendment; every other deliverable is a matrix, a suite, a soak result or a
BRIDGE fix deletable at the `core:net/http` transition. The httprouter study
changes no public API by construction.
