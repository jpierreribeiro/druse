# Dedicated accept throughput validation — 2026-07-25

## Verdict

A dedicated acceptor that assigns each accepted connection once to a Handler
lane recovers the previously observed throughput class without weakening WP71.
With the corrected fault-safe handoff bound, the available single c5.2xlarge
reaches 91.7% of fasthttp at c100 and 96.6% at c400, while retaining a lower
absolute p99 in both runs. It also cuts
`io_uring_enter` from about 5.03 to 0.160 per request.

The owner explicitly authorized adoption on 2026-07-25 after accepting the
absolute p99 and the closed-loop c100→c400 queueing interpretation. Dedicated
accept is therefore the default; the previous shared-accept path remains
available as a build-time rollback for one release.

The two-box/NIC round is still owed and is not claimed here. Adoption is an
explicit owner waiver of that unavailable external-validation gate, not a
retroactive claim that it passed. No tag was made.

**2026-07-26 correction.** Re-running C-03 on the same host exposed that the
adopted eight-callback handoff bound was not stable at the host's faster flood
rate. The current `main` served only 18-24 of 58 healthy probes while accepting
about 49-52k RST connections/s; the pre-#140 shared-accept control served 57/57.
The final bound is two callbacks per lane. It passed three consecutive C-03
campaigns (57/57, 57/57, 57/57; one run admitted 6.3k connections/s), while the
next values, three and four, reproduced the failure. Contemporary steady-state
A/B below shows the cost is bounded and does not change the throughput class.

## Rig and method

- AWS c5.2xlarge, 8 vCPU, kernel 6.17.
- Odin `dev-2026-07-nightly:819fdc7`.
- Server pinned to cores 0–3; `wrk` pinned to cores 4–7.
- Loopback, one box, four wrk threads, keep-alive `GET /ping`.
- Release build: `-o:speed`. This matters: `-o:minimal` made both old and new
  candidates appear substantially slower and explains one source of historical
  non-reproduction.
- Every comparison server ran on the same four cores. Each runtime was
  configured for four workers/Handler lanes where that was an explicit choice.
- Each response was semantically equivalent: HTTP 200, a four-byte `pong`
  body, and `text/plain; charset=utf-8`. Header bytes were not forced to be
  identical.

This run deliberately does not claim to satisfy Phase 0's two-box gate. It is
the best available validation on the one box the owner supplied.

## Druse result

The original adoption comparison used the then-current bound of eight and is
retained here as historical evidence. Values are medians of three consecutive
10-second runs:

| load | Druse req/s | fasthttp 1.72 req/s | ratio | Druse p50 | Druse p99 | fasthttp p99 |
|---|---:|---:|---:|---:|---:|---:|
| c100 | 261,274 | 282,625 | **92.5%** | 353 µs | 622 µs | 1.12 ms |
| c400 | 285,736 | 292,457 | **97.7%** | 1.33 ms | 2.11 ms | 2.59 ms |

The corrected bound-two default was measured in a contemporary five-run A/B:
259,233 req/s / 0.646 ms p99 at c100 and 282,426 req/s / 2.38 ms p99 at c400.
Those are the current-default values used in the README and adoption verdict.

An earlier dedicated perf run at 259,308 req/s counted 415,259 system-wide
`syscalls:sys_enter_io_uring_enter` events while wrk completed 2,594,180
requests: **0.160 enters/request**. The old main measurement was about
5.03/request, a roughly **31× reduction**.

## Cross-framework context

These are the medians from the same c5, affinity and `wrk` procedure:

| framework/runtime | c100 req/s | c100 p99 | c400 req/s | c400 p99 |
|---|---:|---:|---:|---:|
| fasthttp 1.72 / Go 1.26.5 | 282,625 | 1.12 ms | 292,457 | 2.59 ms |
| **Druse / Odin pinned nightly** | **259,233** | **0.646 ms** | **282,426** | **2.38 ms** |
| Axum 0.8.9 / Rust 1.97.1 | 250,214 | 0.706 ms | 269,230 | 2.69 ms |
| Go `net/http` 1.26.5 | 151,226 | 2.54 ms | 150,419 | 7.98 ms |
| Gin 1.12 / Go 1.26.5 | 148,958 | 2.69 ms | 149,931 | 8.49 ms |
| Fastify 5.10 / Node 26.5 | 122,769 | 2.00 ms | 123,183 | 3.85 ms |

Gin used `gin.New()` in release mode without logging/recovery middleware.
Fastify used four cluster workers without logging. Axum used four Tokio worker
threads. Go servers used `GOMAXPROCS=4`. No run reported a non-2xx response.

This table isolates the minimum HTTP transport path. It does not support a
general claim about JSON, parameter extraction, middleware, bodies, streaming,
TLS, connection churn, memory use, or application work. In particular,
fasthttp is a server engine rather than a batteries-included router, while Gin,
Axum, Fastify, and Druse expose different feature sets.

## What changed

The old topology made every Handler lane share the listen socket. Before
entering synchronous application code, a lane had to cancel its accept and
submit the cancellation so WP71 remained true. That made an accept lifecycle
operation part of the request hot path.

The candidate keeps one shared listener but moves it to one dedicated accept
loop. It:

1. accepts on the caller's event loop;
2. chooses the least-loaded available Handler lane;
3. hands the connection to that lane once with `nbio.next_tick_poly`;
4. keeps parsing, request dispatch, sends, deadlines, and teardown on that lane
   for the connection's entire lifetime.

There is no per-request worker dispatch and no per-request accept
cancel/re-arm. A first prototype that did cross-thread work handoff per request
reached only 16–32k req/s and was deleted; connection-affinity is the important
boundary.

The acceptor retains the existing overload contract. If every Handler lane is
inside synchronous application code, it emits a complete 503 with
`Retry-After: 1` and closes. Connection admission remains one server-wide
budget. A bounded two-item handoff queue per lane prevents a connect/RST flood
from building an unobserved callback backlog.

Two disabled-timeout timestamp costs were also removed: disabled response-write and
idle deadlines no longer call `time.now()`. The request timestamp is likewise
skipped when its read deadline is disabled.

## Fault finding during implementation

The first dedicated-accept version passed normal traffic but failed C-03 under
a sustained RST flood: only 19 of 59 healthy probes were served. The acceptor
could enqueue dead sockets faster than the lanes observed their RSTs.

After bounding pending handoffs, three C-03 runs served 47/58, 46/57, and 45/56
healthy probes during floods, and 20/20 after each flood. The protection did
not move steady-state throughput: c100 remained about 259k and
`io_uring_enter/request` remained 0.160.

That first validation was not stable across the wider flood-rate range. On
2026-07-26, the eight-item version admitted roughly 50k dead connections/s and
again served only 18-24/58 healthy probes. The discrete bound search produced:

| handoffs/lane | C-03 result | observed flood rate |
|---:|---:|---:|
| 8 | FAIL, 18-24/58 | 49-52k/s |
| 4 | FAIL, 25/58 | 47.8k/s |
| 3 | mixed, 37/57 then 19/58 | 28.6-48.8k/s |
| 2 | PASS 3/3, 57/57 each | 1.4-6.3k/s |
| 1 | PASS 3/3, 57-58/58 | about 1.4k/s |

Two is the largest tested stable value. A same-host, same-sequence five-run
steady-state A/B against eight measured:

| load | bound 8 control | bound 2 | throughput delta | p99 delta |
|---|---:|---:|---:|---:|
| c100 | 262,267 / 0.613 ms | 259,233 / 0.646 ms | -1.16% | +5.4% |
| c400 | 286,971 / 2.34 ms | 282,426 / 2.38 ms | -1.58% | +1.7% |

This is a small, measured steady-state cost for restoring the pre-existing
liveness claim. Bound two still reaches 91.7% of the recorded fasthttp c100
throughput and 96.6% at c400, with lower p99 in both comparisons. The C-03
control pins the value so it cannot drift upward without a new fault campaign
and throughput A/B.

## Correctness evidence

The pinned full gate completed successfully with the candidate enabled:

- public API remains exactly 82 symbols;
- raw-wire and semantic conformance passed;
- C-01 inventories all 27 asynchronous operation sites;
- C-03 fault campaign passed, including RST flood and coincident
  deadline/drain;
- C-05 saturation passed with complete 503 responses and `Retry-After`;
- WP71 proved blocked Handler lanes own no accept while the dedicated acceptor
  remains armed;
- deadline, backpressure, streaming, upload, drain, and shutdown suites passed.

After the 2026-07-26 bound-two correction, the pinned full gate passed again.
Its in-gate C-03 run served 58/58 healthy probes and recovered 20/20; C-05
observed 57 complete lane-saturation 503s, all with `Retry-After`; WP41, WP71,
WP98 and WP99 were green. The public ledger remained 80 application plus 2
test-support symbols.

One full-gate attempt hit a pre-existing race in the WP87 in-memory oracle,
whose parallel cases share package state. The exact suite passed immediately in
isolation and on the next full run. No transport socket is involved in that
test.

## Adoption criteria

| criterion | result |
|---|---|
| throughput at least 90% of fasthttp | **PASS** — 91.7% c100, 96.6% c400 |
| p99 at most 50% of fasthttp | **MISS** — 57.7% at c100; 91.9% at c400 |
| Druse c400/c100 p99 growth below 2× | **MISS** — about 3.7× |
| complete gate green | **PASS** |
| two-box real-NIC validation | **PENDING** |

The pre-registered c400 growth target cannot be interpreted independently of closed-loop
queueing on four server cores: 400 continuously outstanding requests at
283k req/s imply about 1.41 ms average residence time before any percentile is
considered. The target may become feasible with all eight server cores and a
separate generator, but it was not met here. The owner explicitly accepted that
result and the absolute p99 as sufficient for adoption; the table retains the
miss so the decision does not rewrite the evidence.

## Consequence for multishot recv

The measured premise for the scanner rewrite no longer holds on this
candidate. At 0.160 `io_uring_enter` per request, the target of fewer than one
enter/request is already exceeded by a wide margin without changing the
scanner or buffer lifecycle. A multishot scanner would add the highest-risk
ownership surface in the transport for an unquantified residual gain.

Do not implement it unless the two-box run shows a new, specific syscall
bottleneck. The provided-buffer and multishot primitives remain available for
streaming workloads where many receives per request can actually amortize.
