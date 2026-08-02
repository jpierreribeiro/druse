# R2-WP01 verdict — the instrument

**Decision: R2-WP01 CLOSED. R2 remains blocked; the gate stays at R1.**

The soak instrument is now capable of explaining a failure it observes, and
`build/check_soak_controls.sh` proves it against eight committed fixtures and
eleven negative controls. That satisfies the R2-WP01 acceptance criteria and
unblocks R2-WP02. It is not a result about Druse.

## What was accepted

Against the acceptance list in `planning/readiness/R2-restricted-production.md`
§2:

| Criterion | State | Evidence |
|---|---|---|
| every fixture produces an exact verdict and reasons | met | `raw/fixture-verdicts.txt`, 8 fixtures |
| an instrument error never becomes a PASS | met | negative controls 1–11 |
| the analyser depends on no file the runner may not create | met | `missing-final-state`, `child-death` fixtures |
| criteria and schema carry a version and hash in the manifest | met | `raw/e2e-manifest.txt`, negative control 7 |
| `build/check_soak_controls.sh` is in the main gate and proves the mutants | met | `raw/check_soak_controls.out`, 26 controls |

The eight mandatory negative controls are all present and red-on-mutation:
zeroed curl exit (1), discarded `failure_examples` (2), inflated `completed`
(3), workload removed without `skipped` (4), telemetry samples removed (5),
death before cleanup (6), criterion changed after the manifest (7), binary
changed after its hash (8). Three more were added for findings the audit turned
up: missing `COMPLETE` (9), undeclared injection (10), kernel counters never
collected (11).

## The finding that matters

`INS-003` and `INS-013` are the same defect from two directions, and together
they are why this work package existed.

A twelve-hour soak whose telemetry sampler died in the first second graded
**PASS** under the shipped instrument. The RSS-slope criterion applies only at
720 samples or more, so a two-row artefact did not fail that criterion — it
removed it. Nothing in the artefact recorded that a criterion had not run.

`INS-013` is the live trigger for it: on a host without `nstat`, `pipefail`
killed the sampler on its first iteration. One missing optional tool produced a
clean twelve-hour result with no telemetry in it at all.

This is the shape the whole R2 plan is built around, and it was still present in
the instrument that would have produced R2's evidence.

## What this does NOT establish

Stated plainly, because an evidence directory dated during R2 will be read later
as if it were about the product:

- **No soak was run.** Not 12 h, not 2 h, not the burn-in. The end-to-end run in
  `raw/e2e-*` is a 14-second wiring check on an unqualified host, and the
  analyser correctly refuses it.
- **No capacity envelope, SLO, security review, supply-chain rebuild or canary
  exists.** R2-WP03 through R2-WP08 are untouched.
- **This host is disqualified.** `raw/preflight-this-host.txt` records six
  reasons: 4 CPUs against a 0-3/4-7 topology, `taskset -c 4-7` rejected, no
  `nstat`, no Odin on `PATH`, a 4096 hard `nofile` limit against a required
  8192, and 29 GiB free against an estimated 100 GiB. R2-WP02 requires a
  dedicated host and this is not one.
- **Nothing here changes the R1 freeze.** The supported profile, the accepted
  risks and their expiry are exactly as `planning/readiness/R1-freeze.md` left
  them.

## Risk accepted

| Risk | Scope | Mitigation | Validity |
|---|---|---|---|
| The repaired instrument has never produced a full-length artefact | The ladder in R2-WP04 begins at smoke for exactly this reason | The smoke and burn-in steps exist to find schema and wiring faults before the 12 h run; neither can promote | Until the first qualified-host smoke |
| `expected_samples` tolerance is 2% and was chosen, not measured | A sampler losing up to 2% of ticks under load would not be flagged | Recorded in `analyze-soak.py` as a stated constant; revisit after the first rehearsal on a real host | R2-WP04 |
| The 100 GiB disk estimate in `preflight.sh` is an estimate | A host could pass preflight and still fill up | The rehearsal step measures real evidence volume and the estimate is corrected before the final run | R2-WP04 |

## Next

R2-WP02: copy `ops/soak/campaigns/TEMPLATE.md`, qualify a dedicated host with
`ops/soak/preflight.sh`, and commit the pre-registration **before** the first
run. No soak result is admissible for promotion without that file committed
ahead of the run's `started_utc`.
