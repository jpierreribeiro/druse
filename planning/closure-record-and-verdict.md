# C-07 — The Closure record and the production-readiness verdict

**Status: FREEZE (Closure, WP C-07).** The reconciled record of the Production
Readiness Closure, and the verdict its exit condition demands.

---

## 1. What the phase was for, and whether it worked

The Closure was called after a fourth finding arrived by accident. The write
deadline was in the Phase-3 contract, was deliberately declined at the Phase-3
freeze for a correct reason, was recorded as pending — **and then stopped being
trackable until it resurfaced in conversation.** The diagnosis was not that the
framework was bad but that it had excellent per-feature discipline and no layer
above it reconciling every promise into one place.

The test of that diagnosis is simple: *did review-by-resource find things
review-by-feature had missed?*

**It found four production-blocking defects, all pre-existing on `main`, none of
which any existing suite detected.** Three of the four make `web.stop` never
return — the framework's most load-bearing operational promise. That is the
answer.

| # | Defect | How it was reached | Fix |
|---|---|---|---|
| **F-C03-1** | The drain loop's `#partial switch` omitted `.Will_Close`, so a single client sending `Connection: close` and not reading its response made `web.stop` **never return, past every deadline**. `max_drain_time` bounded nothing for the most ordinary client there is. | C-03 cell D8 — enumerating *states*, not scenarios | patch 26 |
| **F-C05-1** | `handler_lane_enter`'s accept-cancel spin is unbounded. A lane parked in it never reaches `_server_thread_shutdown`, and `serve` waits for every lane: **4 runs in 6 wedged**, `web.stop` not returning in 60 s against a 3 s deadline. | C-05's saturation ramp — and it refuted an argument C-01 had accepted | patch 27 |
| **F-C01-1** | The `.Insufficient_Resources` accept retry re-armed unguarded, leaving an unreachable `accept` that survives `nbio.remove(td.accept)` and holds `num_waiting()` above zero — shutdown never ends, exactly at fd exhaustion. | C-01's ten questions, asked of every operation | patch 24 |
| **A10** | Every RST'd connection held an admission slot for the full 500 ms close delay, so a flood above `budget / 500 ms` made the server refuse everyone: **1 healthy probe served in 59**. | C-03, inheriting the F-002 report's out-of-scope note | patch 25 |

Two further results are worth as much as the fixes:

- **The parallel limitation lists had already drifted into falsehood.**
  `docs/operations.md` told operators large-body upload had "no public API yet"
  and that the framework "will not spool to disk" — both false since 7.5-C2 —
  and called streaming out-of-core four bullets after saying SSE covers server
  push. A list maintained in eleven places decays into telling you to build a
  workaround for a solved problem.
- **`proxy_buffering off` was proven mandatory rather than advisable**: with
  nginx's default, a stream reaches the client *never*.

---

## 2. The exit condition, judged

> No framework-owned operation exists without an explicitly declared owner,
> capacity, deadline, or cancellation; and where something is unbounded or
> external, the responsible topology is named, mandatory, documented and tested.

**MET.** The evidence, each part gate-enforced so it cannot quietly stop being
true:

| Half of the condition | Instrument | Gate |
|---|---|---|
| every operation has a declared owner / capacity / deadline / cancellation | `planning/closure-async-op-inventory.md` — **23 operation-creating call sites × 10 questions**, census derived from the source | `check_c01_controls.sh` |
| every framework-owned resource has limit / deadline / cancellation / saturation / metric / shutdown | `planning/closure-readiness-matrix.md` — **14 resources × 8 properties, no unanswered cell** | `check_readiness_matrix.sh` |
| the fault space is enumerated rather than discovered | `planning/closure-fault-campaign.md` — **34 cells, 0 unanswered** | `check_c03_controls.sh` |
| the combined saturation profile is known, and the write-observability gap is specified | `planning/closure-saturation-and-write-observability.md` — first visible refusal is scheduler-dependent; stable capacity is **`lanes ÷ dwell`**, with connection slots bounding waiting/admission | `check_c05_controls.sh` |
| the router's deliberate differences are pinned as a negative corpus | `planning/closure-httprouter-study.md` — 10 cases, BSD-3 notice gated | `check_c08_controls.sh` |
| unbounded memory has a named, mandatory topology **with measured attribution** | `planning/closure-response-size-and-memory.md` — completed responses release oversize arena blocks; concurrent peak and RSS remain cgroup-owned | `check_c04_controls.sh` |
| the delegated topology is **tested**, not only documented | `planning/closure-proxy-contract.md` | `check_c06_controls.sh` |

**Unclassified cells: zero.** Every cell in the matrix and every cell in the
grid carries a disposition, and both gates fail if one loses it.

---

## 3. The residual, classified

Per §3 of the plan, a classified **acceptable operational limitation** does not
block the verdict; an **unclassified cell** or a **blocking absence** does.
There are none of the latter two. What remains:

### 3.1 The one DEFECT — DIAGNOSED and FIXED by H-2 (patches 29 + 30)

> **RESOLVED (Hardening H-2, 2026-07-24).** F-C03-2 is no longer open. Patch 29
> diagnosed it (below); **patch 30 fixed it**: a server that cannot acquire its
> io_uring event loop now UNWINDS — `web.serve` returns / reports
> `Serve_Listen_Failed` instead of the process terminating. Verified on the VPS
> under kernel 7.0 with a forced 16 KiB memlock — the exact condition that
> aborted at the acquire assertion before the patch (`Allocation_Failed`,
> `server.odin:360`) now returns cleanly and `tests/h2-graceful-acquire`
> survives to its final assertion. What is left is **monitoring, not a defect**:
> confirming the dev-box gate flake is gone across many runs, since the fix
> addresses the diagnosed mechanism (the acquire) and the flake matched exactly
> that signature. The record below is kept as the history of how it was found.

> **VALIDATED IN PRODUCTION (Phase 8, deployment #1, 2026-07-24).** The very
> first real deployment of the reference application (`druse-board`) hit this
> unprompted: on the test VPS (default `RLIMIT_MEMLOCK` = 8 MiB) the server
> exited cleanly every ~1 s under systemd instead of crashing — patch 30's
> graceful unwind, in the field. The operational remedy the patch-29 diagnostic
> names, `LimitMEMLOCK=infinity` in the systemd unit, made it serve. A framework
> fix made in Hardening was confirmed by the first use, and the fix's *value* —
> a clean, recoverable failure with a named remedy rather than a crash-loop — is
> exactly what a real deployment needs. See `druse-board/DEPLOYMENTS.md` #1.

**The original open-defect record:

**F-C03-2 — the real-socket suites crash at a low rate under gate load.** At the
Closure freeze this was unexplained: two observations against fourteen green
runs, ruled out as a regression, signature a crash inside server *startup*. The
verdict named the instrument it needed — an ASan build on a constrained host —
and **Hardening H-2 ran it and got the diagnosis.**

**The cause.** `nbio.acquire_thread_event_loop()` sets up the thread's `io_uring`
rings, which pin memory against `RLIMIT_MEMLOCK`. One loop is created per Handler
lane per server, so under a low memlock budget or memory pressure the setup
fails — and the vendored server *asserted* on it (the deferred error handling
upstream never wrote), turning a resource failure into a startup crash the runner
reports as `Segmentation_Fault`. Reproduced deterministically on a VPS with
`ulimit -l` = 8 MiB and <1 GiB free, under `-sanitize:address`. It looked random
only because nothing named its cause; the rate tracks proximity to the
locked-memory limit.

**What is fixed, and what is still open.** Vendored **patch 29** replaces both
bare asserts with a diagnostic naming `RLIMIT_MEMLOCK` / memory and the remedy —
so the crash is now actionable rather than mysterious. **The graceful unwind is
NOT closed:** returning an error from `web.serve` instead of terminating is a
multi-threaded lifecycle change across the lane workers and `serve`'s wait group,
and it is specified as a follow-up rather than rushed:

> **Follow-up (specified, not done): graceful serve-failure on event-loop
> acquisition.** On a failed `acquire_thread_event_loop`, `_server_thread_init`
> should mark the server failed, signal `threads_closed` for its lane, and
> return, so `serve`'s `sync.wait` completes and `web.serve` returns a
> `Listen_Failed`-class error — a clean, supervisor-restartable outcome instead
> of process termination. Trigger to promote it from follow-up to required: any
> deployment where a transient event-loop setup failure must not take the
> process down.

**This is no longer an open item.** The graceful handling that the box above
called future work is patch 30, done and verified (see the RESOLVED note at the
top of §3.1). The crash is diagnosed, made actionable, AND converted to a clean
`web.serve` failure. What remains is monitoring — confirming the dev-box gate
flake stays gone — not a defect.

### 3.2 Acceptable operational limitations, delegated with a mandatory topology

Each is in the matrix with its owner; none blocks the verdict.

- **TLS** → the reverse proxy. Topology now **tested** (C-06).
- **Total process memory** → a cgroup, with the C-04 sizing rule.
- **Accept backlog** → the kernel (`somaxconn`).
- **Restart, and the outer bound on a blocked handler** → a supervisor with a
  kill timeout. A faulting handler aborts the process by construction (Odin has
  no recoverable panic, ADR-020) and a blocked one is not preemptible.
- **Deadlines are request-scoped, not shutdown-scoped** (F-C01-2): between
  `web.stop` and the drain deadline the sweep no longer runs, so `max_drain_time`
  (default 10 s) is the only bound that survives. Setting it to 0 is valid and
  removes that bound too.
- **Periodic lane timers are uncancellable but self-terminating** — a clean stop
  costs 991 ms, and C-01 named the mechanism (the 1 s Date timer).
- **`web.static` reads synchronously**, blocking its lane, bounded by
  `max_file_size` (8 MiB default).

### 3.3 Specified and deferred — each with a trigger, none with a question mark

Deferred work here means *a specification handed forward*, not an open question.

| Item | Why deferred | Trigger |
|---|---|---|
| `Limits.max_response_bytes` (C-04) | mints a `Limits` field **and** a `Framework_Error` member — a twelve-file ledger amendment deserving its own WP and gate run | a deployment that cannot set a memory cgroup |
| `web.Server_Stats` / `web.stats()` (C-05) | same, +2 ledger | the first deployment running detached streams |
| A real-proxy interop round (C-06) | no proxy binary on the gate machine | before any production deployment behind nginx |
| Upstream keep-alive + duplicated limits through a **pooling** proxy (C-06) | needs a second fixture, not a switch on the first | with the real-proxy round |
| Concurrent buffered-response matrix (corrected C-04) | local attribution proved reclamation but not the aggregate live/RSS envelope | before setting the production cgroup budget |
| The **hours-long** soak (C-04) | a 2-second two-phase run answers the shape question; only a long run reaches slow accumulation | a quiet machine |
| The **3,000 real-socket** SSE round (Phase 7) | same | the same quiet machine — run once, together |
| `radix_compact` (C-08) | optimisation with no readiness consequence | only on material gain, and it must pass the backtracking test unchanged |

**Follow-forward status (R1, 2026-08-01):** the two C-06 deferrals above are
closed for the pinned Caddy topology by R1-WP03
(`ops/proxy/caddy/`, `ops/verification/run-real-proxy-contract.sh` and
`evidence/2026-08-02-r1-real-proxy/`). They remain historical rows because
this table records what the Closure freeze handed forward. The result does not
transfer to nginx, HAProxy or a different CDN/trust chain.

---

## 4. The verdict

> **PRODUCTION-READY FOR A CONTROLLED PILOT**, behind a reverse proxy with
> `proxy_buffering off`, under a supervisor with a kill timeout, inside a memory
> cgroup sized from the corrected C-04 concurrent campaign, with
> `max_write_time` and `max_idle_time`
> enabled. The Closure's exit condition is **met**: no framework-owned operation
> lacks a declared owner, capacity, deadline or cancellation, and every
> delegation names a topology that is mandatory, documented and now tested.
>
> **The one item that qualified this verdict — F-C03-2 — is now RESOLVED.** The
> Hardening phase diagnosed it (an io_uring event-loop setup failure against
> `RLIMIT_MEMLOCK`, patch 29) and fixed it (a graceful `web.serve` failure
> instead of a process crash, patch 30), verified on the VPS where it reproduced.
> What remains is monitoring the gate flake, not an open defect. The controlled-
> pilot posture stands on its topology requirements (proxy, supervisor, cgroup,
> the two enabled deadlines), not on an unexplained crash.

**What changed the verdict from the 2026-07-23 audit's "controlled pilot" is not
the label but its basis.** That audit reached the same words from a review of
features. This one reaches them from an enumerated space: 23 operations, 13
resources, 34 fault cells, zero unclassified. The difference is that a future
finding is now a *new cell* rather than a *new category* — which is the only
form of "done" a systemic review can honestly claim.

### The rule this phase leaves behind

Written into `planning/closure-async-op-inventory.md` beside the entry that
earned it, because C-01 got a cell wrong and C-05's measurement caught it:

> **A cell whose safety rests on reasoning rather than on a test is not
> answered, it is deferred.**

C-01 classified the unbounded accept-cancel spin as acceptable on the argument
that `io_uring` always delivers a completion for a cancelled submission. The
argument was plausible, the kind a careful reader accepts — and four runs in six
wedged. The ten questions found the operation and asked the right question of
it; what failed was the step after.

---

## 5. What Phase 8 inherits

Phase 8 (proof-by-use, WP102–113, **not renumbered** — R1 stands) begins on a
foundation where:

- shutdown actually terminates in the three ways it previously did not;
- the limitations list is one gated document rather than eleven prose lists, two
  of which were lying;
- the saturation profile is known without claiming a scheduler invariant the
  test cannot support: handler capacity is **`lanes ÷ dwell`**, connection slots
  bound waiting/admission, and the first visible refusal may be either lane
  saturation or admission pressure.
