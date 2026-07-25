# Performance discovery — the WP71 accept-suspension costs 3x throughput

**Status: DISCOVERY + PoC, 2026-07-25. NOT FOR MERGE AS-IS.** Measured on a
dedicated AWS c5-class 8-vCPU box (non-burstable), pilot toolchain `819fdc7`, core
`origin/main@79a40ce`. The PoC (branch `claude/perf-work`) proves the ceiling; it
is not shippable because it reverts a ratified guarantee (below). This document is
the honest record and a menu of resolutions.

## What was measured

`GET /ping → "pong"`, keep-alive, `wrk -t4 -c100 -d12s`, two runs, on the c5:

| Build | req/s | p50 | p90 | p99 | max | CPU |
|---|---|---|---|---|---|---|
| **Baseline** (`origin/main`) | 84–86k | 58µs | 134µs | **633–644ms** | 1.24s | 522% |
| **PoC** (accept dance removed) | **251k** | 213µs | 1.44ms | **3.4ms** | 9.3ms | 416% |
| Go net/http (reference) | 189k | 290µs | 1.79ms | 3.5ms | 11ms | 438% |

The PoC is **3× the baseline throughput**, **~184× better p99**, **less CPU**, and
**beats Go net/http** on throughput (1.33×) and p99, on a trivial route.

## Root cause (confirmed by code, not just measurement)

Per request — **including every keep-alive request** — `handler_lane_enter`
(`vendor/odin-http/server.odin`) cancels the lane's pending accept
(`nbio.detach`+`nbio.remove`), then **spin-waits for the cancel completion**:

```odin
for target.accept.client == 0 && target.accept.err == nil {
    if time.since(cancel_deadline) >= 0 { ...; break }   // bounded to 250ms
    _ = nbio.tick(time.Millisecond)                       // 1ms-granularity spin
}
```

The 250ms bound is **PATCH 27 (Closure C-05 / F-C05-1)** — added *because* this
spin wedged reproducibly ("4 runs in 6... web.stop did not return in 60s against a
3s drain"). So the tail was already a known, documented hazard; the benchmark just
put a number on it: up to 250ms per request under load → the 633ms p99.

## Why it exists (the ratified guarantee — PATCH 13 / WP71)

The accept suspension is **not gratuitous**. It guarantees: *a new (e.g. health)
connection is never trapped behind a lane blocked in a synchronous handler while
another lane is free* (VENDOR.md Patch 13, tested by
`tests/wp71-concurrent-serving/…four_handler_capacity_keeps_new_health_connections_off_blocked_lanes`).
Mechanism: a lane about to run a (possibly blocking) handler cancels its posted
accept, so the kernel can only hand a new connection to a *free* lane.

This is structurally necessary given the architecture: **accept and handler share
the lane thread**. During a synchronous blocking handler the thread runs no nbio
code, so any accept posted on it is frozen — a connection the kernel completed into
that lane's ring waits until the handler returns. The only way to keep a new
connection off a blocked lane is to have no accept posted there when it blocks.

## Why the PoC is not shippable

Removing the dance (PoC / V1) reverts the WP71 guarantee. Measured against the c5:
- **`check_wp71_controls.sh` FAILS** — the behavioural test
  `four_handler_capacity_keeps_new_health_connections_off_blocked_lanes` breaks.
- **`check_c05_controls.sh` FAILS** — the wedge-prevention control no longer finds
  its bound (it cannot tell "removed" from "reverted to unbounded").

Both gates encode ratified decisions. The `/ping` benchmark is *aggregate* and used
`time.sleep`; it does not exercise the specific worst case the gates protect (an
individual health connection stuck behind a blocking handler). Both truths hold at
once: the PoC is 3× faster **and** it drops a guarantee that matters for health
checks behind a load balancer.

## Why the cheap syntheses fail (two independent reasons)

The tempting fix — cancel the accept but skip the spin — is **incorrect for two
separate reasons**, both found by design analysis:

1. **Late-completion corruption.** The spin serializes the accept's completion
   *before* the handler, while `handler_active` blocks re-arm. Without it, the
   completion arrives *after* `handler_lane_leave` re-armed, and the late
   `on_accept` sets `td.accept = nil`, erasing the freshly re-armed accept: state
   corruption / operation-tracking leak. A generation/epoch guard could fix *this*
   in isolation.

2. **Lazy submission breaks the guarantee anyway (the deeper one).** `nbio.remove`
   only *enqueues* the cancel in userspace; it is submitted to the kernel on the
   next `tick`/submit. The spin's `nbio.tick` is what actually **pumps the cancel
   into the kernel** before the handler blocks. Skip the ticking and the cancel sits
   in userspace while the handler runs — the accept stays **live in the kernel for
   the whole handler**, so a new connection can still land on the blocked lane. The
   WP71 guarantee is violated even with a perfect generation guard.

**Conclusion:** the guarantee and the cost are *coupled* in the current model
(accept + handler on one thread, lazy io_uring submission). A safe fix must both
submit the cancel eagerly AND guard the late completion — real concurrency work with
its own test cycle — or move accept off the handler thread entirely (option 2). It
is not a hot-patch.

## Resolution menu (for a proper WP, with trade-offs)

1. **Safe accept-suspension without a spin.** Keep the cancel; make a late accept
   completion a safe no-op (e.g. a per-lane generation/epoch so a stale `on_accept`
   is ignored, and the re-armed accept is authoritative). Preserves WP71, removes
   the spin (the perf + the C-05 wedge). **This is the recommended target** — most
   of the gain, guarantee intact — but it is real concurrency work with its own
   tests, not a hot-patch.
2. **Dedicated accept thread / SO_REUSEPORT sharding (thread-per-core, M4).** Accept
   off the handler lanes entirely; a blocking handler cannot trap a new connection
   because it does not own accept. Biggest rewrite; also the biggest ceiling.
3. **Opt-in guarantee.** Ship the fast path (no suspension) as default and the
   suspension as an opt-in for deployments with heavy blocking handlers. Makes the
   trade-off the operator's, explicitly. Cheapest, but pushes a sharp edge to users.
4. **Keep baseline.** Reject the perf gain, keep the guarantee. The honest null
   option; rejected here only because option 1 plausibly gets both.

## Recommendation

Pursue **option 1** as a dedicated WP: a generation-guarded accept suspension that
keeps WP71 green while removing the spin. Validate against `check_wp71_controls.sh`,
`check_c05_controls.sh`, the full gate suite, AND the `/ping` + blocking-handler
benchmarks on a non-burstable box. Do **not** merge the PoC. The PoC's value is the
evidence: it proves the ceiling is real and worth the concurrency work.

## Artifacts

- PoC diff: `vendor/odin-http/server.odin` on `claude/perf-work` (commit removing
  the dance). Compiles; 3× measured; fails wp71/c05 by design.
- Bench method: `wrk -t4 -c100 -d12s` /ping; blocking-handler A/B via a 50ms-sleep
  route; both on the c5. Reproducible with the pinned toolchain.
