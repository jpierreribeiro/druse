# Phase 9 — I/O architecture & performance parity with Go net/http

**Status: PHASE PLAN + LIVING STUDY, 2026-07-25.** This is the master document for Phase 9
(WP114–WP121). It records the study the owner asked for (Go's netpoller, io_uring multishot),
the measured evidence that motivates the phase, the architecture, and a living results table
updated at every measurement. All numbers were measured on a dedicated AWS c5-class 8-vCPU box
(non-burstable), pilot toolchain `819fdc7`, base `origin/main@79a40ce`.

## Why this phase exists

A measured optimization campaign proved Uruquim can compete with Go net/http on a trivial
route, and found a real, addressable gap. The owner's goal: **≥ Go on every axis** (throughput,
latency, CPU), keeping the WP71 guarantee — building I/O infrastructure from scratch if needed.

### Measured state (c5, `GET /ping`, keep-alive, wrk -t4 -c100)

| Build | req/s | p50 | p90 | p99 | CPU | WP71 guarantee | Gates |
|---|---|---|---|---|---|---|---|
| baseline (`origin/main`) | 80k | 63µs | 134µs | 517ms | 521% | ✅ | ✅ |
| **PATCH 28** (WP114) | 108k | 59µs | 102µs | **149µs** | 355% | ✅ | ✅ 141 PASS |
| v1 (PoC, rejected) | 241k | 213µs | 1.44ms | 3.2ms | 382% | ❌ breaks | ❌ wp71/c05 |
| p29 submit-only (rejected) | 188k | 248µs | 0.99ms | 2.35ms | 447% | ✅ | ❌ leaks conns |
| **Go net/http** | 181k | 306µs | 1.84ms | 3.57ms | **176%** | — | — |

**PATCH 28 already beats Go on p50/p90/p99 by 5–24× and preserves the guarantee.** The two
remaining gaps are **throughput** (108k vs 181k) and **CPU** (355% vs 176%).

## The study

### Go's netpoller (`runtime/netpoll.go`, `netpoll_epoll.go`)

- A **single** poller multiplexes thousands of fds with **epoll in edge-triggered mode**
  (`netpollopen` arms ET). Edge-triggered means the kernel signals a readiness *transition*
  once; the runtime need not re-arm interest per event, which sharply cuts syscalls under load.
- A goroutine doing I/O with no data ready is **parked** (taken off the run queue). When the fd
  becomes ready, `netpollready` returns it to a P's run queue. No spin, no busy-wait.
- One `epoll_wait` **batches** many ready fds into one syscall. Net effect: very few syscalls
  amortized across many connections + cheap goroutines. **This is what buys Go its ~176% CPU.**
- Takeaway for us: the efficiency is not magic — it is *amortized syscalls + batching + a
  readiness model that doesn't re-arm per event*. io_uring's multishot is the completion-based
  analogue, and can go further (the kernel does the receive, not just readiness).

### io_uring multishot + provided buffers (the modern, more efficient equivalent)

- **`IORING_RECV_MULTISHOT`**: one recv SQE keeps posting a CQE per data arrival, **without
  re-arm** — eliminates the per-request recv syscall. Completions carry `IORING_CQE_F_MORE`
  while the op stays armed.
- **Provided buffer ring** (`IORING_REGISTER_PBUF_RING` + `IOSQE_BUFFER_SELECT`): the kernel
  picks a buffer from a pre-registered pool per receive; the CQE reports the buffer id in
  `flags >> IORING_CQE_BUFFER_SHIFT`. Removes per-I/O buffer mapping and a copy. The app
  recycles the buffer back to the ring after consuming it.
- **`IORING_ACCEPT_MULTISHOT`**: one persistent accept SQE posts a CQE per connection —
  eliminates the accept re-arm **and** the cancel/re-arm dance entirely.
- Sources: `io_uring_prep_recv_multishot(3)`, `io_uring_provided_buffers(7)`,
  `io_uring_multishot(7)`, LWN "io_uring: multishot recv".

### The blocker: Odin has no multishot infrastructure

`core/sys/linux/uring/ops.odin` ships `provide_buffers`, `remove_buffers`, `read_multishot`
as **empty `unimplemented()` stubs**. There is no `recv_multishot`, no `accept_multishot`, no
`setup_buf_ring`. So Phase 9 must **build the base from scratch**, bottom-up: uring → nbio →
odin-http. This is the "infrastructure from zero" the owner authorized.

## Why we can't just "keep the 241k" (the owner's question, answered)

The v1 PoC hit 241k by **not suspending the accept**. That breaks the ratified **WP71/Patch-13
guarantee**: a new (e.g. health) connection must never be trapped behind a lane blocked in a
synchronous handler. In today's model **accept and handler share the same lane thread**, so to
honor the guarantee the lane must cancel its accept before blocking — and that per-request
cancel is what costs the throughput (measured: PATCH 28's `nbio.tick(0)` submit is ~90k req/s
of the gap). **The only way to have 241k AND the guarantee is to take accept off the lane
thread** — a dedicated accept path. That is architecture, not a patch. → WP119.

## Why CPU is the hardest axis (measured fact)

**Even v1 — no guarantee, the perf ceiling — loses on CPU to Go: 382% vs 176%.** So the CPU
gap is **not** the accept dance; it is **syscalls per request**. Each Uruquim request does a
one-shot recv (+re-arm), a send, and an accept re-arm. Go amortizes all of it via the
edge-triggered netpoller. Our lever is multishot recv + provided buffers (fewer syscalls/req).
Honest caveat: matching a 15-year-old netpoller on CPU is ambitious — we measure, not promise.

## Architecture — two levers, mapped to WPs

- **CPU** ← multishot recv + provided buffers (WP115–WP117): fewer syscalls/request.
- **Throughput + guarantee (241k back)** ← multishot accept on a dedicated accept path
  (WP118–WP119): structural guarantee, no per-request cancel.
- **Reconcile + verdict** (WP120–WP121): admission/drain under the new model; final measure.

The WP breakdown and definitions of done live in the phase plan
(`~/.claude/plans/tarefa-de-an-lise-sunny-phoenix.md`); this doc is refined as they execute.

## Living results table (updated at every measurement)

| WP | Change | req/s | p99 | CPU | syscalls/req | Gates | Notes |
|---|---|---|---|---|---|---|---|
| WP114 | PATCH 28 (non-spin accept suspension) | 108k | 149µs | 355% | — | ✅ 141 PASS | **MERGED** (main f69d51e); beats Go on latency |
| WP115 | provided-buffer ring (from scratch) | — | — | — | — | ✅ unit | **DONE** — ABI built + proven vs kernel 6.8 (vendor/uring_buf_ring); test GREEN |
| WP116 | multishot recv (prep + proof) | — | — | — | — | ✅ unit | **DONE** — 1 SQE → N CQEs, buffer-select, F_MORE proven; test GREEN |
| WP117 | scanner multishot recv (odin-http integration) | — | — | — | — | — | in progress; target: CPU → 176% |
| WP118 | multishot accept (prep + proof) | — | — | — | — | ✅ unit | **DONE** — 1 SQE accepts N conns, F_MORE proven; test GREEN |
| WP119 | dedicated accept path | — | — | — | — | — | target: ≥ 241k + guarantee |
| WP121 | Phase 9 final | — | — | — | — | — | full picture vs Go |

**WP115–116 note:** the I/O infrastructure Odin lacked (provided-buffer ring + multishot recv)
is now built from scratch and proven against a real kernel, unit-tested locally. WP117 is the
integration step: replace odin-http's one-shot recv path (`scanner.odin`) with this, preserving
every HTTP framing invariant. That integration is a deeper rewrite (the scanner is the request
parser) and pairs naturally with WP119's dedicated-accept path — the two together are the
"correct I/O base" rewrite. It needs the c5 for the CPU measurement that closes the WP.

## Rules of engagement (what got us here)

- Measure before claiming; refuting is a valid result (v1, p29, submit-only all died in
  measurement — each death was progress).
- Toolchain changes (uring/nbio) are a serious dependency move: **vendor into Uruquim**, never
  modify the global toolchain; document each patch and its upstream-ability.
- Never promise "≥ Go on CPU" before measuring; ship the truth of the data.
