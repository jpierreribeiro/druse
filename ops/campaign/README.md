# Verification campaign runbook

Everything the agent needs to execute `planning/verification-campaign-plan.md`.
Read that plan first: it says what each campaign is for and what counts as an
acceptance. This file says what to type.

## Before anything

```bash
sudo ops/campaign/prepare-host.sh    # limits, sysctls, and records host state
ops/ci/install-odin.sh               # pinned toolchain, SHA + commit verified
```

`prepare-host.sh` writes `artifacts/host-state-<timestamp>.txt`. **Commit that
file with every campaign result.** A latency or memory number whose host state is
unknown cannot be compared to the next one.

## The rule that governs all of this

**A harness proves nothing until it has caught the bug.** Every campaign below
has a "control" step that reverts the fix and expects the harness to go red. Run
it FIRST. If the control does not fail, the clean run that follows is not
evidence — and you must say so in those words rather than reporting the green
run alone.

This is not ceremony. It has already changed one conclusion in this project:
`tests/nbio-timeout` was written to pin the `timespec` fix, its control was run,
and the control passed — the kernel normalises the value the audit predicted
would be rejected. The fix was kept, the claim was corrected, and the report now
records it. Do the same wherever a control refuses to fail.

## Campaign A — c03 completes

```bash
ops/campaign/run-campaign-a.sh
```

The suite did not finish in 25 minutes on the audit container, on the patched
tree *or* on pristine `61bec774` — a direct comparison confirmed it is
environmental, not a regression. The first question is therefore **why it does
not finish**, not whether it passes.

If it still hangs after `prepare-host.sh`, attach and find out where:

```bash
pgrep -f c03-fault-campaign                   # then, against that pid:
gdb -p <pid> -batch -ex "thread apply all bt" # where is it
ss -s                                         # socket-state exhaustion
dmesg | tail -50                              # conntrack / backlog drops
strace -c -f -p <pid>                         # a spinning syscall
```

Report which of three it is: resource exhaustion (record the limit that bound),
a genuine hang in the framework (**stop everything — that outranks every other
item in this plan**), or slow-but-progressing (record wall time).

**Control:** `URUQUIM_C03_CONTROL=1 ops/campaign/run-campaign-a.sh` rebuilds with
`URUQUIM_ACCEPT_HANDOFF_LIMIT` at 8 and expects failure.

## Campaign B1 — the accept stall

```bash
ops/campaign/run-campaign-b1.sh control   # revert the fix, try to reproduce
ops/campaign/run-campaign-b1.sh verify    # restore the fix, long clean run
```

**Status going in:** the control was attempted on a 4-core container for 3,135
aggressive cycles (dwell 3 ms, quiet 30 ms, wave 16) and **did not reproduce the
stall**. That is recorded, not hidden. It may reproduce on four real cores with
different timing, or it may not reproduce at all — the window is nanoseconds
wide, and x86-TSO permits the store→load reordering but does not make it
frequent. Budget several hours for the control before concluding.

If the control never fails, the honest report is: *"the harness ran N cycles
without reproducing the defect on reverted code, so it bounds nothing; the fix
stands on the memory-model argument alone."*

The exact hunks the control reverts are in
`experiments/23-accept-stall/README.md`.

## Campaign B2 — the shutdown race

```bash
ops/campaign/run-campaign-b2.sh control   # revert, expect an ASan report
ops/campaign/run-campaign-b2.sh verify    # restore, 50k iterations clean
```

ASan is the oracle; the harness's own output means nothing without it. Requires
`ulimit -l unlimited` (see `prepare-host.sh`) or ASan + io_uring reproduces
F-C03-2 — a startup assert — instead of the bug under test.

## Campaign B3 — the dead lane

Not scripted, because it needs a one-line fault injection and doing it by hand
keeps the injection out of the shipped tree. Procedure:

1. In `vendor/nbio/impl_linux.odin`, inside `_flush_submissions`, add a
   counter-guarded `return .EBUSY` that fires once after N ticks.
2. Build and run any two-lane server; drive traffic.
3. **Before the fix** (revert the `server_shutdown(s)` call in the lane loop's
   tick-error branch in `vendor/odin-http/server.odin`): the server keeps
   serving at reduced capacity, two connections strand, one log line is the only
   trace.
4. **After**: the process shuts down.
5. Remove the injection. Do not commit it.

## Campaign B4 — done, and the control falsified the claim

```bash
odin test tests/nbio-timeout -collection:uruquim=$PWD
```

Green, and committed. Its control was run and **passed**, meaning the test does
not catch the defect it was written for, because Linux 6.18.5 normalises an
over-large `tv_nsec` instead of rejecting it. The split is retained as a
conformance repair. Re-run the control on the campaign host anyway: a different
kernel may not normalise, and if it fails there, that is worth recording.

## Campaign C — lane_collisions

Owner decision first (three options in the plan). No script until that lands.

## Campaign D — the soak

```bash
ops/campaign/run-campaign-d.sh          # on the server box
ops/campaign/soak-load.sh <server-ip>   # on the second, small instance
```

Run only after A and B. **State the acceptable RSS band as a number before the
run starts**, not after seeing the result. Mixed response sizes are the point:
per-connection buffers retain roughly the largest response that connection ever
served and `max_idle_time = 0` means idle connections are never reaped, so a
uniform-size soak cannot see the ratchet.

## Artifacts

Everything lands in `artifacts/`, which is gitignored for scratch but whose
*promoted* results belong in the repository:

```
artifacts/
  host-state-<ts>.txt        commit with every result
  c03-<ts>.log
  b1-control-<ts>.log
  b1-verify-<ts>.log
  b2-control-<ts>.log
  b2-verify-<ts>.log
  soak-<ts>.csv
```

Promote to `docs/reports/<date>-<campaign>.md` with the raw log committed beside
it. Prose without its artifact is exactly the gap the audit found in the
benchmark claims; do not add a second instance.
