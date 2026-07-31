# 26 — ADR-020: the shape of a leak per recovered fault

**What this is:** a committed, runnable measurement of what one skipped
deallocation costs per request on the real request path, and whether that cost
is bounded or linear.

**What this is NOT, and the distinction is the reason the experiment exists:**
it is not a reproduction of the WP13 prototype that produced ADR-020's
"**8,250 bytes per recovered fault**".

## Why the original cannot be reproduced

ADR-020 weighed four options and chose (B). Its rationale quotes a measurement
of option **(C)** — a `setjmp`/`longjmp` fence that recovered from a fault and
kept serving — to argue why (C) is worse than a clean abort.

**(C) was rejected.** It was never implemented and never merged. The prototype
that measured it lived entirely in `/tmp/wp13-probe/`, was never committed, and
that directory is long gone. The shipped code cannot recover from a fault; a
fault aborts the process, which is the decision ADR-020 records.

So there is nothing to re-run. A script claiming to reproduce 8,250 would be
measuring something this codebase cannot do, and reporting the agreement as
confirmation would be a green result for a reason it did not name
(`planning/diagnosability.md` rule 4).

This is recorded here because
`planning/verification-campaign-plan.md` requires every reported number to be
regenerable from a committed script, and ADR-020's number is not. The honest
close is not a fabricated reproduction — it is a committed measurement of the
quantity the decision actually turns on, plus a plain statement that the
historical constant stands on a prototype that no longer exists.

## What the decision actually rests on

Not the constant. The **shape**, as ADR-020 and
`planning/history/phase-2-prototype-recovery.md` §9 both argue it:

> the leak is linear and unbounded, nothing reclaims it, and — the part that
> makes it a security property rather than a performance one — the process keeps
> answering 500s and never signals its supervisor, so nothing restarts it until
> the kernel OOM-kills it and takes every in-flight request with it.

A bounded leak would be a performance defect. An unbounded one that is invisible
to the supervisor is a remote memory-exhaustion vector reachable through any
faulting route. That argument does not depend on whether the constant is 8,192,
8,250, or a different number on different hardware.

## How the fault is modelled

A recovered fault skips every `defer` between the fault site and the fence.
There is no way to skip a `defer` in Odin without faulting, and a fault aborts —
so the *consequence* is modelled directly rather than the mechanism: the leaking
arm allocates and does not free. This makes no claim about the fence.

Two arms, `REQUESTS` requests each through `web.test_request`, both under a
`mem.Tracking_Allocator`:

| Arm | Handler |
|---|---|
| clean | allocates 8 KiB, frees it |
| leaking | allocates 8 KiB, does not free |

**The clean arm is subtracted, and that is inherited rather than invented.**
`web.test_request` records every response and retains it until `web.destroy`.
That retention is documented driver behaviour, not a leak, and it grows in both
arms — which is why the original document used the clean line as its baseline
rather than zero. The reported figure is a difference.

The allocation escapes through a package global so the optimiser cannot delete
it. A measurement whose subject was optimised away would print zero and read as
"no leak" — a green result for the wrong reason, which is the failure this
repository has a rule about.

## Running it

```
odin run experiments/26-adr020-leak-shape -collection:druse=.
```

Or, with the pinned toolchain and no ambient `ODIN_ROOT`:

```
bash experiments/26-adr020-leak-shape/run.sh
```

It is **not** in `build/check.sh`. It takes minutes, it produces a number rather
than a verdict, and `planning/diagnosability.md` is explicit that a threshold on
a continuous measurement carries its own obligation — say where the number came
from. This README is that obligation discharged. The same reasoning keeps
`check_wp26_bench.sh` out of the gate.

## Result, 2026-07-31

Full run archived verbatim in `RESULT-2026-07-31.txt` (20,000 requests per arm,
pinned toolchain `dev-2026-07a` / `819fdc7`):

| | |
|---|---|
| leaked bytes per request | **8,192.0** |
| residue beyond the modelled buffer | **0.0** (control: expected 0.0) |
| linearity drift over the run | **0.0%** |

The shape ADR-020 argues from is confirmed on shipped code: perfectly linear,
nothing reclaimed, 163,840,000 bytes still live after 20,000 requests.

**And it explains the 8,250 / 8,192 discrepancy that had sat unreconciled in
`planning/history/phase-2-prototype-recovery.md`** — the two numbers count
different things and are consistent:

- **8,192** is the single 8 KiB buffer one skipped `defer` fails to release.
  This experiment models exactly that, and measures exactly that, to the byte.
- **8,250** is ~58 bytes/request higher because the R-c fence skipped **every**
  `defer` between the fault site and the fence — the buffer *plus* the request's
  other deferred frees. Only a real fence produces that figure, and there is no
  fence, so it cannot be re-measured.

Neither supersedes the other. Quote 8,192 for "what one skipped free costs" and
8,250 for "what the rejected fence measured", and say which.

## Reading the output

The per-request figure exceeds 8,192 because the allocator's own bookkeeping for
the leaked block is leaked with it. The gap between the two is printed
separately so it is attributable rather than absorbed into a headline number.

The linearity line is the actual claim under test: it projects the first
sampling interval across the whole run and reports the drift. A bounded leak —
anything with a cache, a pool, or a reclaim path — would fall away from that
projection. An unbounded one tracks it.
