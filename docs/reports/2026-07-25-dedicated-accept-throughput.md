# Dedicated accept throughput validation — 2026-07-25

## Verdict

A dedicated acceptor that assigns each accepted connection once to a Handler
lane recovers the previously observed throughput class without weakening WP71.
On the available single c5.2xlarge it reaches 92% of fasthttp at c100 and 98% at
c400, while retaining a lower absolute p99 in both runs. It also cuts
`io_uring_enter` from about 5.03 to 0.160 per request.

The owner explicitly authorized adoption on 2026-07-25 after accepting the
absolute p99 and the closed-loop c100→c400 queueing interpretation. Dedicated
accept is therefore the default; the previous shared-accept path remains
available as a build-time rollback for one release.

The two-box/NIC round is still owed and is not claimed here. Adoption is an
explicit owner waiver of that unavailable external-validation gate, not a
retroactive claim that it passed. No tag was made.

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

## Uruquim result

The final comparison uses freshly built artifacts from the recorded versions.
Values are medians of three consecutive 10-second runs:

| load | Uruquim req/s | fasthttp 1.72 req/s | ratio | Uruquim p50 | Uruquim p99 | fasthttp p99 |
|---|---:|---:|---:|---:|---:|---:|
| c100 | 261,274 | 282,625 | **92.5%** | 353 µs | 622 µs | 1.12 ms |
| c400 | 285,736 | 292,457 | **97.7%** | 1.33 ms | 2.11 ms | 2.59 ms |

An earlier dedicated perf run at 259,308 req/s counted 415,259 system-wide
`syscalls:sys_enter_io_uring_enter` events while wrk completed 2,594,180
requests: **0.160 enters/request**. The old main measurement was about
5.03/request, a roughly **31× reduction**.

## Cross-framework context

These are the medians from the same c5, affinity and `wrk` procedure:

| framework/runtime | c100 req/s | c100 p99 | c400 req/s | c400 p99 |
|---|---:|---:|---:|---:|
| fasthttp 1.72 / Go 1.26.5 | 282,625 | 1.12 ms | 292,457 | 2.59 ms |
| **Uruquim / Odin pinned nightly** | **261,274** | **0.622 ms** | **285,736** | **2.11 ms** |
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
Axum, Fastify, and Uruquim expose different feature sets.

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
budget. A bounded eight-item handoff queue per lane prevents a connect/RST
flood from building an unobserved callback backlog.

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

One full-gate attempt hit a pre-existing race in the WP87 in-memory oracle,
whose parallel cases share package state. The exact suite passed immediately in
isolation and on the next full run. No transport socket is involved in that
test.

## Adoption criteria

| criterion | result |
|---|---|
| throughput at least 90% of fasthttp | **PASS** — 92.5% c100, 97.7% c400 |
| p99 at most 50% of fasthttp | **MISS** — 55.5% at c100; 81.5% at c400 |
| Uruquim c400/c100 p99 growth below 2× | **MISS** — about 3.4× |
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
