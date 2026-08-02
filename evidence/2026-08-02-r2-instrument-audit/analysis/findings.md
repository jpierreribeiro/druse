# R2-WP01 — audit of the soak instrument

Twelve findings against `ops/soak/run-soak.sh`, `ops/soak/analyze-soak.py`,
`ops/soak/CRITERIA.md`, `ops/soak/openload/`, `ops/soak/soak-server/`,
`build/check_soak_controls.sh` and `ops/soak/experiments/`.

**Severity is about the verdict, not the code.** `silent-pass` means the
instrument returned PASS for an artefact that should have been red — the worst
outcome available, because it is indistinguishable from a good result.
`no-verdict` means it crashed: bad, but it stops. `blind` means the data was
recorded and never read, so the criterion existed on paper only.

| ID | Question | Finding | Severity |
|---|---|---|---|
| INS-001 | 6 | `stats_http="$(curl …)" \|\| true` followed by `stats_curl_exit=$?` reads the exit status of `true`. Every failed `/stats` scrape in the history of this harness recorded `0`, so the promised taxonomy (7/28/52/56) was unreachable. | blind |
| INS-002 | 7 | The analyser raised `FileNotFoundError` when a run died before `control/final-state.txt` — the single most likely artefact of a bad night. | no-verdict |
| INS-003 | 1, 5 | Sampler death was undetected. A truncated `telemetry/process.csv` silently disabled the RSS-slope criterion, which only applies at ≥720 samples. **A two-row artefact of a twelve-hour run graded PASS.** | silent-pass |
| INS-004 | 2 | No arithmetic closure. `completed < planned`, `sum(status) != completed` and `succeeded + errors != completed` all passed. Requests could vanish leaving no record of any kind. | silent-pass |
| INS-005 | 5 | Kernel counters were recorded from 2026-07-30 and read by nothing. They are also absolute since boot, so without differencing against a pre-load baseline they are not attributable to the run. | silent-pass |
| INS-006 | 3 | Injected faults (`c*-rst.json`, slow readers) were never read by the analyser: not separated from spontaneous failures, not present in any total, not declared anywhere. | blind |
| INS-007 | 1 | The `COMPLETE` marker was written and never checked. A run killed at hour two graded exactly like one that finished twelve. | silent-pass |
| INS-008 | 10 | The manifest recorded no tree hash, did not reject a dirty working tree, and pinned no criteria or schema version — so a criterion could be edited between a run and its grade with nothing able to detect it. | blind |
| INS-009 | 9 | No host preflight. `taskset -c 4-7` on a host with four CPUs surfaced as *"release-candidate server exited before readiness"* — a sentence about the product, produced by a host that could never have run the measurement. | mis-attributed |
| INS-010 | 7 | A missing per-cycle artefact killed the orchestrator mid-run: `jq` on an absent health file exits non-zero under `set -e`. The run then died leaving exactly the artefact INS-002 crashed on. | no-verdict |
| INS-011 | 6 | `curl -o` truncates its output before it knows whether it can fill it, so a failed scrape left a zero-byte `stats-NNNNNN.json` indistinguishable on disk from a successful scrape of an empty body. | blind |
| INS-012 | 7 | Further crash paths on short or empty input: `rss[0]`, `min(threads)`, `statistics.median([])`, `slope_per_hour` on all-zero RSS, and `int(value)` over a `final-state.txt` line whose value is not a number. | no-verdict |

Question 4 (absolute timestamps and a class on every raw row) and question 8
(absent profiles carrying a pre-registered reason) were already satisfied by the
generator and by `control/skipped.txt`. They are the two the previous
diagnosability work closed, and they are the reason the other ten were findable
at all.

## INS-013 — found by running the repaired instrument

The eleven above came from reading. This one came from the first end-to-end run
and is the most instructive of the set.

`run-soak.sh` runs under `set -o pipefail`. The kernel-counter sample is a
pipeline. On a host with no `nstat` that pipeline returns 127, `pipefail`
propagates it, and the sampler's subshell dies **on its first iteration** —
leaving `telemetry/process.csv` holding a header and nothing else.

Under the shipped analyser that artefact graded **PASS**: see
`raw/shipped-analyser-on-the-same-artefacts.txt`, fixture `dead-sampler`.

So a host missing one optional tool produced a clean twelve-hour result with no
telemetry at all, and nothing anywhere said so. The repair is three parts, and
the third is the one that matters:

1. the pipeline is guarded, so a missing tool no longer kills the sampler;
2. `nstat=present|absent` is recorded in the manifest;
3. **`nstat=absent` fails the run.** Zeros in those columns read as "no drops",
   which is the single thing the columns exist to distinguish. A host that could
   not collect them did not observe a clean kernel — it observed nothing.

## What the shipped instrument said about the same artefacts

`raw/shipped-analyser-on-the-same-artefacts.txt`, verbatim:

| Fixture | soak/0 | soak/1 |
|---|---|---|
| `pass` | PASS | PASS |
| `fail-classified` | FAIL | FAIL |
| `fail-unclassified` | FAIL | FAIL |
| `child-death` | **crash, no verdict** | FAIL, 7 reasons |
| `missing-final-state` | **crash, no verdict** | FAIL, 3 reasons |
| `dead-sampler` | **PASS** | FAIL, 2 reasons |
| `kernel-drops` | **PASS** | FAIL, 1 reason |
| `broken-accounting` | **PASS** | FAIL, 2 reasons |

Three of eight artefacts that should have been red were graded green, and two
produced no grade at all. The three green ones are the finding: an instrument
that cannot fail is not measuring anything, and every soak verdict this project
has recorded was produced by it.

## What this does not establish

This work package repaired the **instrument**. It measured nothing about the
product. No soak has been run on a qualified host, and the R2 promotion criteria
remain untouched — see `verdict.md`.
