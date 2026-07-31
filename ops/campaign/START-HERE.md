# START HERE

You are picking up a verification campaign for **Uruquim**, an HTTP framework
written in Odin. This bundle contains everything needed to run it. Read this
file completely before touching anything; it is short, and the order of the
steps is load-bearing.

## What has already happened

An audit of the framework found nine defects. All nine are **fixed and merged**
into `main` at commit `44bdcda`. You are not fixing them. You are producing the
evidence that four of them are actually fixed.

Five of the nine carry a **negative control**: the fix was reverted, the test was
observed going red, the fix was restored. Those are settled.

**Four do not**, and they are the newest code in the framework's concurrency
path:

1. the acceptor/lane availability handshake (memory ordering),
2. the shutdown teardown ordering (a use-after-destroy window),
3. a lane that died on a tick error but stayed selectable,
4. a `timespec` that put a whole duration into the nanoseconds field.

Worse: the test suite that exercises exactly that code —
`tests/c03-fault-campaign` — **could not be completed anywhere** during the
audit. Not on the fixed tree, not on the pristine tree before it. A direct
comparison confirmed both exceed 25 minutes on the audit machine, so it is
environmental rather than a regression, but it means the framework's RST-flood
verdict is currently unverified against the code that ships.

Your job is to close that.

## The one rule that governs everything here

**A harness proves nothing until it has caught the bug.**

Every campaign has a control step that reverts the fix and expects the harness to
go red. Run it FIRST. If the control does not fail, the clean run that follows is
**not evidence**, and you must report that in those words rather than presenting
the green run alone.

This is not ceremony. It has already changed two conclusions in this project,
both of which you need to know before you start, because they set your
expectations:

- **B4's control passed.** A test was written to pin the `timespec` fix. With the
  bug restored, all three cases still passed: Linux 6.18.5 normalises an
  over-large `tv_nsec` instead of rejecting it, contradicting the audit's
  prediction. The fix was kept as a conformance repair, the claim was corrected
  in the report, and the test is now labelled a regression guard. **No stress
  work is owed for B4** — but re-run its control on your host anyway, because a
  different kernel may behave differently, and if it fails there that is worth
  recording.

- **B1's control did not reproduce.** The accept-stall harness ran 3,123 cycles
  at the most aggressive settings a 4-core container sustained, with the fix
  reverted and the safety-net tick removed, and saw no stall. The window is
  nanoseconds wide. It may reproduce on real cores; it may not. Budget hours,
  and if it still refuses, say so plainly.

If you find yourself wanting to report a clean run whose control never failed,
re-read this section.

## What to read, in order

1. `payload/planning/verification-campaign-plan.md` — why each campaign exists,
   what the hardware must be, and what counts as acceptance. **Read this second,
   right after this file.**
2. `payload/ops/campaign/README.md` — the runbook. What to type.
3. `payload/experiments/23-accept-stall/README.md` and
   `payload/experiments/24-shutdown-race/README.md` — the exact source hunks each
   control reverts, so you can verify the scripts do what they claim.

## Setup

```bash
git clone https://github.com/jpierreribeiro/uruquim.git
cd uruquim
git rev-parse HEAD          # must be 44bdcda or a descendant

/path/to/this/bundle/install.sh .    # drops the campaign files into the checkout

sudo ops/campaign/prepare-host.sh    # limits, sysctls, records host state
ops/ci/install-odin.sh               # pinned toolchain, SHA + commit verified
```

`install.sh` only adds files; it never modifies framework source. The campaign
scaffolding is deliberately **not** committed to the repository — the owner keeps
`main` clean, so leave it untracked and hand back results as artifacts, not as
commits or pull requests.

### Host requirements, and why they are not negotiable

The target is an AWS **c5.2xlarge** or equivalent. Two things about it matter
more than the vCPU count:

- **It has four PHYSICAL cores**, not eight (4 × 2 hyperthreads). Run `lscpu -e`
  and read the CORE column. If CPUs 0–3 and 4–7 are sibling pairs, then pinning
  server to 0–3 and load to 4–7 puts them on the *same physical cores* — which is
  why the harnesses use **two lanes, not four**, leaving real cores for the load
  generator and the canary. A canary competing with the server for CPU produces
  false positives, and that is the one failure mode these campaigns cannot have.
- **`ulimit -n` and `ulimit -l` are stock AMI defaults** and both break campaigns.
  1024 descriptors makes the RST flood ungeneratable. A small `RLIMIT_MEMLOCK`
  makes io_uring ring allocation fail, which this project has already recorded as
  a startup crash (F-C03-2) — under ASan you will hit it instead of the bug you
  are hunting. `prepare-host.sh` sets both, in the session and persistently.

`prepare-host.sh` writes `artifacts/host-state-<timestamp>.txt`. **Every result
you report must be accompanied by that file.** A latency or memory number whose
host state is unknown cannot be compared to anything.

## Order of work

```
A  (c03 completes)          ← blocking; nothing else is trustworthy first
   ├─ B1, B2, B3            ← the uncontrolled fixes
   │     └─ D (soak)        ← needs a stable accept path to mean anything
   └─ C (owner decision)    ← do not start; it needs a human first
```

**Campaign A leads with diagnosis, not pass/fail.** The first question is *why it
does not finish*. Distinguish three outcomes and say which one it is: resource
exhaustion (name the limit that bound), a genuine hang in the framework (**stop
everything and report — that outranks every other item here**), or slow but
progressing (record the wall time).

**Campaign C is not yours.** It needs the owner to choose between three options
for a metric that is currently unreachable. Do not implement one.

Rough budget: A is 1–3 h and needs attention; B1 is ~4 h of control attempts plus
a 6 h clean run; B2 is ~6 h; B3 is 30 minutes of manual work; D is 12–24 h
unattended. Two to three days of wall clock, most of it idle.

## What to hand back

For each campaign, one report containing:

- the host-state file;
- the raw log, not a summary of it;
- the control outcome **first**, then the verify outcome;
- thresholds as configured alongside what was observed. The C-03 gate's committed
  bar is "at least half the healthy probes served during the flood, plus full
  recovery". A run that served 58 of 58 is an observation, not the bar. Write
  both.

Prose without its artifact is exactly the gap this audit found in the project's
benchmark claims. Do not add a second instance of it.

## If something surprises you

Two things in this project have already turned out differently from what a
careful reading predicted — the `timespec` kernel behaviour and the
irreproducibility of the accept stall. Assume there will be a third. When a
result contradicts what this bundle told you to expect, the result wins, and
saying so is the deliverable.
