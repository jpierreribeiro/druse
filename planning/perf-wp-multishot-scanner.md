# Perf WP (Phase 10 candidate) — multishot recv into the HTTP scanner

**Status: SPEC + VALIDATION RECORD, 2026-07-25.** Not scheduled; this is the
measured case for (and the honest scoping of) the one throughput lever that
survived investigation. It follows the perf correction in
`planning/perf-netpoller-study-and-architecture.md` and its `## Re-measurement`
and iowait sections. Read those first.

---

## 0. The one-paragraph summary

The framework's throughput on a single-box loopback `/ping` benchmark (~78k
req/s, 4 cores) is **identical to a bare nbio echo with no framework at all**, and
is **~1/3.6 of fasthttp** (280k) on the *same* harness with the load generator
demonstrably idle. This is not a framework overhead and not a test error: it is a
**documented characteristic of io_uring at request-depth-1** — one
`io_uring_enter` syscall per request, ~1.9µs, not amortized (external benchmarks
put io_uring echo at ~1/3 of epoll at depth-1). Cheap fixes were tried and
**refuted by measurement**. The one lever that could close it is **multishot recv
+ a provided-buffer ring wired into the HTTP scanner**, so one `enter` harvests
many keep-alive requests. That is a substantial transport-internal rewrite, and
its real payoff can only be confirmed on a **two-box benchmark** (loopback both
under-measures io_uring and confounds server/client on one box). This WP specifies
that work and gates it on the two-box result.

---

## 1. What was measured (AWS c5.2xlarge, 8 vCPU, kernel 6.17, loopback, wrk)

Server pinned cores 0-3, wrk cores 4-7, keep-alive `/ping`, distributed load
(4 dst IPs). Numbers are steady-state; loopback single-box, so **relative** only.

| server | req/s | per-core mpstat |
|---|---|---|
| bare nbio echo (reuseport, no framework, hardcoded "pong") | ~78k | usr~20 sys~30 **iowait~30-50** soft~5 idle=0 |
| **Uruquim framework** (`web.app`, full parse/route/lanes/arena) | ~78k | usr~24 sys~37 **iowait~28** soft~11 idle=0 |
| fasthttp (Go zero-alloc ceiling) | **~280k** | usr~40 sys~38 **iowait=0** soft~22 idle=0 |
| Go net/http | ~162k | — |

**The three facts this pins:**
1. **Zero framework overhead.** Bare nbio echo == framework (both ~78k). The
   ceiling is in the nbio/io_uring layer they share, not in routing/parsing/lanes.
2. **The load generator is not the bottleneck.** fasthttp does 280k on the
   identical harness (sanity-checked twice), and the wrk client cores sit 40-100%
   idle during the echo runs. 78k is the server's ceiling, not the client's.
3. **The blocking wait is not the limiter.** Patching the echo's loop from
   blocking `nbio.tick()` (`io_uring_enter` min_complete=1) to busy-poll
   `nbio.tick(0)` (min_complete=0, spin) did **not** move throughput toward
   fasthttp (63-80k either way, within run-to-run noise). The cost is the
   **per-request `enter` syscall itself**, which busy-poll still pays on submit —
   not the sleeping.

## 2. Levers eliminated by measurement (do not re-try without new evidence)

| lever | result |
|---|---|
| `COOP_TASKRUN` + `SINGLE_ISSUER` | **already set** (`vendor/nbio/impl_linux.odin:139`). Not a lever. |
| `DEFER_TASKRUN` | patched, rebuilt, benched → **refuted**: throughput flat (77-82k), iowait slightly worse. |
| busy-poll completions (`tick(0)`) | **refuted**: 63-80k, no move toward 280k. Blocking is not the cause. |
| `IORING_ENTER_NO_IOWAIT` (6.15) | accounting relabel only; adds no throughput; absent from the pinned toolchain. |
| NAPI busy-poll (`REGISTER_NAPI`) | targets **latency** (RTT 55→38µs upstream); ours is already 44µs. Wrong axis; nil on loopback (no NIC). |
| SQPOLL alone | removes the *submit* enter, but nbio still enters for `wait_nr>0` completions (`uring.odin:131`), which is the iowait. Would need pairing with busy-poll reaping, and burns a full core. |
| multishot recv at the **echo prototype** level | benched earlier → "no HTTP win", because a 1-recv-per-request echo does not amortize. **NOT the same as wiring it into the scanner** (§3). |

## 3. The lever: multishot recv + buffer ring, wired into the scanner

**The site.** `vendor/odin-http/scanner.odin:263` issues a **single-shot**
`nbio.recv_poly` per request (`pending_recv`). Every keep-alive request therefore
costs its own submit `enter`. Under keep-alive with many sequential requests per
connection, that is exactly the amortizable case the echo prototype was not.

**The mechanism (documented in the research + liburing/SynapServe/tokio-uring).**
Pre-register a ring of fixed buffers (`IORING_REGISTER_BUFFERS`), arm
`recv_multishot` with `IOSQE_BUFFER_SELECT` against the buffer group, and the
kernel delivers **one CQE per data arrival, picking a buffer from the pool, with
no per-request re-submit**. The event loop already reaps *many* CQEs per `enter`
(`impl_linux.odin` loops over `cqes[:completed]`), so multishot lets **one
`enter` harvest many requests' bytes** — cutting the per-request syscall the
measurement isolated. The scanner must then parse streaming/partial reads
(merge until a full request line + headers arrive) and recycle each buffer back
to the ring when done.

**The infrastructure already exists** (built in Phase 9, unused by the server):
`vendor/uring_buf_ring/{buf_ring,multishot}.odin` (provided-buffer ring) and
`vendor/nbio/multishot.odin` (`recv_multishot_poly`). The WP is the *wiring into
the scanner*, not the primitives.

## 4. Scope, risk, and why this is not a pilot change

- **Transport-internal, no public API change.** `web.serve`, handlers, extractors
  and the ledger are untouched. It is invisible above the boundary (ADR-009).
- **High risk, exactly where the bugs live.** The scanner's `pending_recv` handle
  is the subject of F-002 (use-after-free on deferred dispatch), F-C01-2 (deadline
  during drain) and the WP71 accept guarantee. Multishot changes the recv
  lifecycle (one op spanning many requests; cancellation at drain; buffer reuse vs
  connection teardown; a stale CQE against a recycled buffer). Every one of those
  is a re-run of a bug class this project already paid for. It needs the C-01
  async-op inventory questions applied to the multishot op, and the raw-wire +
  fault suites green.
- **Partial reads become the common path.** Today the scanner reads into one
  buffer; multishot delivers arbitrary fragments across ring buffers. The HTTP
  request assembler must handle a header split across two buffers, which the
  single-shot path rarely exercises. New corpus required.

## 5. Validation plan (the WP is gated on this, in order)

1. **Two-box benchmark FIRST, before building anything.** Server alone on all 8
   cores of one c5; a dedicated load box (a second c5) running wrk/wrk2 over a
   real NIC. This answers the question single-box cannot: **is 78k a real io_uring
   ceiling, or a loopback artifact?** External reports say loopback both
   under-measures io_uring and confounds server/client. If the framework does
   substantially more than 78k over a real NIC, the whole premise weakens and this
   WP may not be worth its risk. **No multishot code until this number exists.**
2. **Prototype multishot recv in the scanner behind a build flag**, off by
   default. Measure req/s AND iowait AND the fault/raw-wire suites, on the two-box
   rig. Adopt only on a **material, measured** throughput gain with every gate
   still green — the same bar C-04/C-08 used.
3. **Apply the C-01 inventory** to the multishot op (who cancels it, can its CQE
   fire after teardown, can it touch a freed buffer/connection) before it ships.
4. **Keep the single-shot path** until the multishot path passes the full
   conformance + fault campaign. A regression here is a use-after-free, not a slow
   response.

## 6. Recommendation

**Do not schedule this for the pilot.** The latency story — p50 44µs, p99 67µs,
**flat under load** (~40× better than fasthttp at c400) — is world-class and is
the framework's real differentiator; it is unaffected by this gap. The throughput
gap is a **known io_uring-at-depth-1 characteristic**, the framework adds no
overhead to it, and closing it is a high-risk transport rewrite for raw RPS that a
p99-SLA service does not need. Schedule it only when (a) a two-box run shows the
gap is real (not a loopback artifact) **and** (b) throughput becomes a stated
product requirement. The lever, its site, its infrastructure, and the refuted
alternatives are recorded here so that work starts from evidence, not from zero.
