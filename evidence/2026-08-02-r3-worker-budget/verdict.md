# R3-WP10 Stage 1 verdict — what N worker processes cost, and what an arm costs

**Decision: no arm is adopted. The track continues, with the real price written.
The gate stays at R1.**

`R3-general-maturity.md` §6 makes the N>1 resource budget a **precondition** of
choosing an arm rather than a follow-up to it. This is that measurement, plus a
re-check of the two feasibility claims ADR-049 rested on. Criteria frozen in
`planning/readiness/R3-WP10-preregistration.md` at `dccadb7`, before the run.

Decision recorded in **ADR-051**, which supersedes ADR-049's feasibility table.

## Finding 1 — the resource cost is not the obstacle

`analysis/budget.md`, from `raw/per-worker.txt`. N ∈ {1, 2, 4}, four lanes each.

| | per worker | constant in N? |
|---|---|---|
| FDs | 14 | yes |
| threads | 5 | yes |
| io_uring rings | **5** (4 lanes + 1 acceptor) | yes |
| ring bytes | **1 044 480** (~1020 KiB) | yes |
| `VmLck` | **0** | yes |
| `VmRSS` | ~4.5 MiB | yes |

**W1 PASS.** Nothing per-worker varies with N. No coupling between processes.

**W2/W3.** `LimitMEMLOCK` is an RLIMIT — **per process** — so each worker gets
its own 64 MiB against ~1 MiB of rings: about **64× of headroom**. Extrapolated
to the R1 profile (8 lanes → 9 rings) it is ~1.8 MiB, still ~35× under. The limit
would only bind at roughly **320 lanes in one process**, and
`AUTO_HANDLER_CONCURRENCY_MAX` is 32.

ADR-049 named memlock as "the cost that decides the design". Measured, it is not.

**What does change meaning is `MemoryMax`**, and it changes silently: it belongs
to the cgroup, so it is **aggregate**. The same 1 GiB becomes 256 MiB per worker
at N=4, and nothing in the unit says "divided by N". Adding the two kinds of
limit together, or treating `LimitMEMLOCK` as aggregate, produces a unit that
looks correct and kills workers under load.

**`VmLck` reads 0 on every worker, and that is the trap rather than an error.**
The kernel charges io_uring ring memory against `RLIMIT_MEMLOCK` without
reporting it under `VmLck`, so an operator watching `VmLck` to predict memlock
exhaustion sees a flat zero right up to the allocation that fails — a mode this
repository has already reproduced (F-C03-2, patch 30). The number to watch is the
summed mappings, and no `/proc` file hands it over ready-made.

## Finding 2 — ADR-049's feasibility was wrong, and the error collapses its cost table

Both claims were checked, not repeated. `raw/adr049-feasibility-recheck.txt`.

**Claim 1: "`net.Socket_Option.Reuse_Port` exists in the pinned Odin."** The
*symbol* exists. On Linux it is `-1` — `core/net/socket_linux.odin:40`,
`_SOCKET_OPTION_REUSE_PORT :: -1`. Only FreeBSD maps it to a real constant. So
`net.set_option(sock, .Reuse_Port, true)` on Linux is a `setsockopt` with optname
−1. The symbol is a placeholder, and the target platform is exactly the one
without the capability.

**Claim 2: "the bind path is `vendor/nbio/impl.odin:_listen_tcp`, so inserting
`Reuse_Port` is one line."** The *product's* bind path is `core:nbio`.
`web/internal/transport/odin_http_adapter.odin:19` and all four
`vendor/odin-http` files import `core:nbio`; `druse:vendor/nbio` is imported by
**two bench programs and nothing else**. Patching it would change the benches and
not the server.

Together: the "one line" would be a no-op in a file the product does not use.

**The tree already contained the working recipe and says so in a comment.**
`bench/echo_reuseport/main.odin` (the WP119 prototype) opens its listener with a
raw `linux.setsockopt(fd, SOL_SOCKET, .REUSEPORT, &one)` because — its words —
*"core:net on Linux does not expose REUSEPORT"*. It has been in the tree since
WP119.

## What that does to the arms

`_listen_tcp` runs create-socket → `Reuse_Address` → `bind` → `listen` with no
seam, and `SO_REUSEPORT` must be set **before** bind. There is no insertion point
from outside.

So **A and B converge on the same missing capability**: `nbio` cannot adopt a
socket it did not create. `create_tcp_socket` goes through `create_socket`, which
associates the socket with the event loop; there is no `adopt`. ADR-049 charged
that cost to arm B alone. It belongs to A as well.

| Arm | ADR-049's cost | Measured cost |
|---|---|---|
| A — `SO_REUSEPORT` | 1 vendored line | **a new nbio entry point** + a raw `core:sys/linux` socket + the dedicated-accept lane rethought |
| B — inherited listener | a new nbio entry point | **the same entry point**, plus the socket-activation contract |
| C — pre-fork | fork + threads + io_uring | unchanged, still without precedent |

A's cost advantage over B **disappears**. What separated them was one line against
an entry point; measured, both pay the entry point — and then B, which loses
**zero** connections when a worker dies because the accept queue belongs to
someone who did not die, is the better candidate at the same price.

## Why "no arm" is not "keep N=1"

`R3-general-maturity.md` §6 lists **keep N=1** as an allowed outcome for when the
resource cost does not pay for itself. The measurement says the opposite: the
resource cost is modest, linear and uncoupled. What is missing is **an entry
point in `nbio`** — a nameable piece of work, not an impediment.

Adopting A today would pay B's price for a mechanism that loses the dead worker's
accept queue. That is the decision this measurement exists to prevent, and it is
the decision ADR-049 was written to stop someone making in an afternoon.

## What this does NOT establish

- **The fault campaign did not run, and could not.** F1 (kill a worker, survivors
  keep serving) and its negative control **F1n** (the same campaign at N=1 must go
  RED) both require an implemented arm. No listener is shared today, so there was
  nothing to kill one of. **No containment has been demonstrated.**
- **Nothing was run with a shared listener at all.** The N ∈ {2, 4} processes in
  this measurement each bound their **own port**. They are a resource-accounting
  fixture, not a worker pool.
- **No drain-per-worker, no rollback-to-N=1, no unit template.** F4 and F5 are
  untouched.
- **The numbers are from a 4-CPU shared container**, and they are deterministic
  accounting — descriptors, rings, mapped bytes — not capacity or tail latency (G4).
- **Nothing changes the R1 freeze or the supported profile.** A handler fault
  still costs 100% of capacity and every connection in flight. This work package
  measured the price of changing that; it did not change it.

## Risks accepted

| Risk | Scope | Mitigation | Validity |
|---|---|---|---|
| The ring-bytes figure is summed from `/proc/PID/maps`, not from a kernel accounting interface | It could drift from what `RLIMIT_MEMLOCK` actually charges | The 64× headroom is far larger than any plausible discrepancy; it would take a ~64× accounting error to change the conclusion | Until a host with a tight memlock limit is used |
| `MemoryMax` division by N is arithmetic, not measured under load | A worker could still OOM at a share this run did not exercise | Named as the binding constraint so the unit template must address it explicitly | R3-WP10 Stage 3 |
| Four lanes per worker, not the R1 profile's eight | The per-worker constants are reported so the profile can be recomputed | Rings scale as lanes + 1; the extrapolation is stated, not hidden | Until a host with ≥8 usable cores |

## Next

**An `nbio` entry point that adopts an existing socket** — the piece A, B and
socket activation all share. `core:nbio` belongs to the pinned toolchain and is
not vendored, so that is either an upstream change or a decision to vendor the
package, and the vendor policy has been *shrinking* the delta (patch 42 deleted
1 295 lines). It is a policy decision, not a detail, and it is the gate on
everything after it.
