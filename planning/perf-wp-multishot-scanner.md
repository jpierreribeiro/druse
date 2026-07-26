# Perf WP (Phase 10 candidate) — multishot recv into the HTTP scanner

**Status: SPEC + VALIDATION RECORD, SUPERSEDED BY MEASUREMENT, 2026-07-25.** Not scheduled; this is the
measured case for (and the honest scoping of) the one throughput lever that
survived investigation. It follows the perf correction in
`planning/perf-netpoller-study-and-architecture.md` and its `## Re-measurement`
and iowait sections. Read those first.

> **2026-07-25 adopted result:** the default dedicated shared acceptor with
> connection-affine lane handoff reached 259k req/s at c100 and 283k at c400,
> while cutting `io_uring_enter` from ~5.03 to **0.160/request**. The scanner
> was not changed. This refutes the premise that multishot recv is the next
> measured throughput lever. See
> `docs/reports/2026-07-25-dedicated-accept-throughput.md`.

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
that work and gates it on the two-box result. **The premise is now measured (§4b):
we issue ~5 `io_uring_enter` syscalls per request vs fasthttp's 0.02 `epoll_wait` —
a ~250× gap — so the amortization headroom multishot targets is real and large.**

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

## 4b. The premise, QUANTIFIED — syscalls per request (2026-07-25, single-box)

The one thing that could have killed this WP before it starts: *is there actually
amortization headroom, or does the loop already batch many requests per `enter`?*
Measured directly with `perf stat -a -e syscalls:sys_enter_io_uring_enter` (and
`epoll_pwait` for fasthttp) over a 10s window under distributed load — a **ratio,
not a throughput**, so it is single-box-valid:

| server | syscalls **per request** | rps |
|---|---|---|
| **Uruquim framework** (`web.app`) | **4.97 `io_uring_enter`/req** | 80.7k |
| **bare nbio echo** (no framework) | **4.99 `io_uring_enter`/req** | 79.0k |
| **fasthttp** (Go netpoller) | **0.02 `epoll_pwait`/req** | 281k |

**The headroom is real and enormous — a ~250× gap in syscalls per request.** Every
request today costs ~5 `io_uring_enter` syscalls (arm-recv, wait-recv, arm-send,
wait-send, plus loop overhead); fasthttp's edge-triggered epoll returns ~50 ready
sockets per `epoll_wait`, so it spends **0.02** waits per request. Research B's
~1.9µs-per-`enter` cost, multiplied by ~5, is a per-request syscall tax the
netpoller simply does not pay.

Two things this pins:
1. **The premise holds.** There is not "maybe" headroom — we do 250× the syscalls.
   Multishot recv (kernel delivers many requests' bytes per `enter`, no per-request
   re-submit) targets exactly this number. The WP is worth its risk *if* the
   two-box test (§5.1) shows the syscall tax actually bounds throughput on a real
   NIC and not just on loopback.
2. **It explains every refuted lever.** Busy-poll (`tick(0)`) removed the *blocking*
   but not the *count* — each request still issues ~5 submits, so throughput did
   not move. DEFER_TASKRUN reorders completion delivery, not the count. Only
   cutting the **enters-per-request count** — which multishot does and none of the
   flags do — can close this. That is why the cheap fixes were dead and this one
   is not.
3. **It is nbio-level, not framework-level.** Framework 4.97 ≈ bare echo 4.99: the
   syscall pattern is the shared nbio I/O loop, confirming §1's "zero framework
   overhead" from a second angle.

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

## 7. Post-spec validation: do not build the scanner rewrite

The available c5 validation could not satisfy the required two-box topology,
but it did isolate a lower-risk structural lever before any scanner code was
written. Moving shared accept ownership off Handler lanes removes the
per-request accept cancel/re-arm and lets each connection remain affine to one
lane. On four server cores this produced:

| load | Uruquim | fasthttp | Uruquim p99 | fasthttp p99 |
|---|---:|---:|---:|---:|
| c100 | 259–260k req/s | 278k req/s | 619–625 µs | 1.13 ms |
| c400 | 283k req/s | 290k req/s | 2.46 ms | 2.76 ms |

The decisive counter was 415,259 `io_uring_enter` calls over 2,594,180
requests, or **0.160/request**. This is already below the WP's intended
less-than-one target, without fragmenting scanner buffers or introducing a
connection-spanning recv operation.

Therefore Phase 2's multishot prototype is **not authorized by the evidence**.
Keep this specification as the ownership checklist if a future real-NIC run
isolates recv submissions again; do not pay its UAF and teardown risk merely
because the primitives exist.
