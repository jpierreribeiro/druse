# C-05 — Combined saturation, and the write-observability gap

**Status: PERIMETER 6 DONE (measured, and it found a wedge). PERIMETER 7
SPECIFIED here, then SHIPPED by Hardening H-3 (`web.stats()`/`web.Server_Stats`,
ledger 73→75).** Answers §4's perimeters 6 and
7 of `planning/production-readiness-closure.md`.

---

## 1. Perimeter 6 — which queue saturates first

A request passes through several bounded resources in series: the kernel's
accept backlog, the admission budget (`max_connections − reserved_conns`), a
synchronous Handler lane, and process memory. The matrix (C-02) says what each
does *alone*. Nobody had asked what they do *together* — the architecture
backlog's "which queue saturates first" question, unmeasured since it was
written.

`tests/c05-saturation` ramps concurrent clients against a server with
`max_connections = 24`, `reserved_conns = 4` (budget 20) and a handler that
dwells 40 ms, and **classifies every request by the outcome that identifies
which resource refused it**:

| Outcome | Means |
|---|---|
| `200` | served |
| `503` | the **Handler lane** refused (the F-002 refuse-and-retry) |
| connected, then EOF with nothing written | the **admission budget** refused |
| connect failed | the kernel **backlog** or the fd table refused |
| timeout | nothing refused; something is merely slow |

Telling the middle two apart is the whole instrument. An admission refusal
accepts the TCP connection and then closes it unwritten, so a client that counts
only "errors" cannot distinguish it from a backlog drop — the same distinction
C-03's RST-flood probe needed, and the reason both suites can describe the
degradation instead of collapsing every non-200 into one bucket.

### The result, re-measured after dedicated accept

**Corrective measurement, 2026-07-29.** The acceptor-side 503 in the historical
table below was emitted before the acceptor had parsed or associated a request.
Go `net/http` observed it as an unsolicited response. Patch 42 removes that
protocol-invalid write: all-lanes-active now closes the socket at the transport
boundary and increments `web.stats().saturation_refusals`. A deterministic
four-lane barrier drives eight such sockets and requires eight transport
refusals, zero pre-request HTTP replies and a counter delta of eight. Restoring
the old raw 503 in an isolated mutant makes the corpus red. The table remains
historical evidence for why the defect was found, not the current contract.

The original record pinned one representative run as an architectural ordering:
"the Handler lane binds first, at four." That conclusion did not survive the
dedicated-accept architecture or repetition. Ten consecutive runs of the
current tree on the local 4-vCPU host produced:

| Observation | Ten-run result |
|---|---:|
| first observed refusal `Lane_Refused` | 8 runs, first at level 12 |
| first observed refusal `Admission_Refused` | 2 runs, first at level 24 |
| first refusal at level 4 | **0 runs** |
| served after the ramp | **10 / 10** |
| shutdown returned | **10 / 10**, 500–584 ms |
| malformed replies | **0** |
| 503 without `Retry-After` | **0** |
| served across the 88 driven clients | 28–34 |
| client timeouts | 0–37 |

**F-C05-2, corrected — the first visible refusal is scheduler-dependent.**
Dedicated accept assigns work to available lanes; under excess concurrency,
requests may wait on lane-owned sockets, meet the acceptor's all-lanes-active
transport refusal, or reach the connection admission budget. Which becomes the
first *observed refusal* is not a stable ordering and must not gate.

What remains deterministic is the capacity model: synchronous handler service
capacity is approximately **`lanes ÷ mean dwell`**; `max_connections` bounds how
many accepted connections can exist and therefore how much waiting/admission
pressure the process permits. Both settings matter, but they govern different
resources. The gate consequently asserts the shape that is stable: the ramp
really saturates, every reply is named and well formed, every observed 503 has
`Retry-After`, dwell accounting moves with dispatched work, a healthy request
is served afterwards, and shutdown returns.

The raw ten-run log and summary are preserved in the local validation evidence
directory with SHA-256 checksums. The test prints the first observed refusal as
a diagnostic; it does not assert its kind or level.

### H-4 follow-ups (the operational corrections this measurement demanded)

1. **Historical, superseded by Patch 42:** the 503 carried `Retry-After: 1` (vendored change at the
   `dispatch_exchange` refusal path). A refusal that does not say *when* to come
   back invites an immediate retry onto the same contended pool, which collides
   again — the refusal creates the retry storm it was trying to shed. One second
   is the smallest honest hint (a synchronous handler's dwell is the thing being
   waited out). The C-05 ramp requires `Lane_Refused_No_Retry` to be zero and
   explicitly reported when a particular run produced no 503. The acceptor no
   longer emits that response at all; request-aware 503 paths retain the header.

2. **There is no explicit application-dispatch queue or work stealing.**
   Dedicated accept chooses an available least-loaded lane and bounds handoffs.
   Once a connection is lane-owned, later bytes on it may wait behind that
   lane's synchronous handler; that is socket queueing, not a copied `Exchange`
   safe to move elsewhere. The old `next_tick` dispatch deferral remains
   forbidden: it was a use-after-free because `req`, `res`, inbound views and
   `Exchange` live in the connection arena that teardown frees.

---

## 2. F-C05-1 — the unbounded accept-cancel spin wedges shutdown

**CLASSIFICATION: production-blocking absence.** *Fixed in-phase (vendored patch
27). Pre-existing: reproduces on `origin/main`.*

The saturation ramp did not only measure. It **hung**, and the hang is a defect
worth more than the measurement that found it.

`handler_lane_enter` suspends a lane's `accept` before running a synchronous
handler. Because `nbio.remove` is asynchronous, it then waits for the
cancellation to be observed:

```odin
for target.accept.client == 0 && target.accept.err == nil {
    _ = nbio.tick(time.Millisecond)
}
```

**No iteration cap, no deadline.** C-01 inventoried this as F-C01-3 and
classified it as an acceptable limitation, on the argument that `io_uring`
always delivers a completion for a cancelled submission so the loop must
terminate. **The measurement refutes the argument.**

| Tree | `web.stop` returns | runs |
|---|---|---|
| pristine `origin/main` (dbbd522) | **NO** | **4 of 6 wedged** |
| pristine, wedged runs | did not return in **15 s**, and in a longer probe not in **60 s** | — |
| with vendored patch 27 | **yes**, at ~0.5 s or ~3.0 s | **11 of 11** |

Note what the fixed timings say: the runs that used to wedge now return at
**~3.0 s**, which is exactly `max_drain_time`. The drain deadline finally bounds
shutdown, as it is documented to.

**Why one lane stops the whole server.** The spin runs on the lane thread. A
lane parked in it never returns to its event loop, never observes `s.closing`,
and never calls `_server_thread_shutdown` — and `serve` waits on
`threads_closed` for *every* lane. So one lane in the spin is a process that
cannot be stopped, **past `max_drain_time`**, which bounds the drain and cannot
bound a lane that never reaches the drain.

**The fix** caps the wait at 250 ms. On expiry it abandons the wait and leaves
the operation record **detached** rather than returning it to the pool:
reattaching a record whose completion may still arrive would hand the pool an
entry the kernel can still write to, trading a wedge for a use-after-free. One
leaked `Operation` per occurrence is the correct price. Abandoning is safe
because `nbio.remove` has already guaranteed the callback will never run; what
the wait exists for is the narrow case where the accept *won* the race and holds
a connected client — worth waiting for, not worth waiting forever for.

### The methodological finding

This is the second time in this phase that a cell classified by **reasoning**
turned out to be wrong, and the first time was the same cell. The inventory's
ten questions found the operation and asked the right question of it — question
9, "is there a maximum deadline?", answered "no". What failed was the step
after: **accepting a reason instead of demanding a test.** Question 10 exists to
stop exactly that, and this cell answered it "n/a — it is not an operation".

The rule now written into `planning/closure-async-op-inventory.md`: *a cell
whose safety rests on reasoning rather than on a test is not answered, it is
deferred.*

---

## 3. Perimeter 7 — write observability: specified here, SHIPPED by H-3

> **SHIPPED.** The specification below was the C-05 deliverable; Hardening H-3
> implemented it verbatim as `web.stats()` returning `web.Server_Stats` (ledger
> 73→75, vendored patch 28 for the four backend counters, the three stream
> counters joined through the transport). `tests/h3-server-stats` proves each
> counter moves on real traffic; `build/check_h3_controls.sh` pins the wiring
> and the no-string-field redaction rule. The rest of this section is the
> original specification, kept as the record of what was asked and why.

**The gap, as it stood.** The core's entire public
observability surface was **one counter**, `web.refused_connections()`, plus the
typed `Framework_Event` observer, which reports per-request framework *errors*
and carries no counters. Consequently an operator **cannot see**:

- how many responses were sent, or how many bytes they carried;
- how many sends failed, or how many connections the write deadline aborted;
- any of the three stream-registry counters — `refused_stream_full`,
  `refused_budget_full`, `aborted_slow` — which **exist and are maintained** in
  `web/internal/stream` and are reachable from no public API. A slow-consumer
  abort is counted and then invisible.

C-05 does **not** ship this, for the reason C-04 did not ship
`max_response_bytes`: it mints public surface, and a ledger-growing change is a
twelve-file ritual (`build/check_public_api.sh`, `check_phase1_freeze.sh`, the
signature snapshot, `planning/phase-1-freeze.md`, `check_docs.sh`,
`docs/ai-context.md`, and the rest) that deserves its own work package and its
own gate run rather than being appended to an audit phase.

### The specification, handed forward

One accessor, one struct, `+2` on the application ledger (73 → 75):

```odin
Server_Stats :: struct {
    refused_connections:  int, // == web.refused_connections(), for one call site
    responses_sent:       int,
    response_bytes:       i64,
    send_errors:          int,
    write_deadline_aborts:int,
    stream_refused_full:  int, // registry: per-stream event/byte cap
    stream_refused_budget:int, // registry: process-wide byte budget
    stream_aborted_slow:  int, // registry: owner tore down on write error/deadline
}
stats :: proc() -> Server_Stats
```

- **Redaction holds by construction** (WP20 §3.1): every field is a plain
  integer, so no request-derived byte can reach it — the same argument that put
  `refused_connections` inside the permitted set.
- **Plumbing:** four atomic counters on the backend `Server` (incremented in
  `on_response_sent` and in the sweep's write branch), surfaced through
  `web/internal/transport` beside `refused_connections`, joined there with
  `stream.counters(&runtime.streams)` — which already returns exactly the three
  stream fields.
- **Zero on a stopped server**, matching `refused_connections`'s existing rule.
- Keep `web.refused_connections()` as-is: it is in the frozen ledger, and
  removing it to tidy the surface would be a breaking change for a cosmetic gain.

**Trigger to promote this from recommendation to requirement:** the first
production deployment that runs detached streams. Slow-consumer aborts are the
one failure this framework can perform silently. Section 1's stable capacity
rule — handler service is `lanes ÷ dwell`, while connection slots bound waiting
and admission — tells the operator how to interpret those numbers without
pretending one refusal must always appear first.
