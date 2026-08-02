# Campaign pre-registration — `<candidate>`

Copy to `ops/soak/campaigns/YYYY-MM-DD-<candidate>.md`, fill it in, and **commit
it before the first run**. R2-WP02.

Readiness rule G3: criteria are frozen before the run. A criterion decided after
a result is not a criterion, and this file is the artefact that makes the
ordering checkable afterwards — its commit date is either before the run's
`started_utc` or it is not.

`build/check_soak_controls.sh` proves the instrument can produce a verdict.
This file is what the verdict is about. Neither substitutes for the other.

---

## 1. Hypothesis

**H1:** _the one claim this campaign can falsify._

**Not hypotheses.** _What this campaign will not answer, written down now so the
result is not stretched to cover it later. At minimum: this is not a capacity
measurement (that is R2-WP05) and not a statement about real traffic (R2-WP07)._

## 2. Candidate identity

Readiness rule G1: a candidate is an identity, not a directory. Any change to
code, toolchain, configuration or instrument creates a new candidate, and
evidence is not transferred by similarity.

| Field | Value |
|---|---|
| commit | |
| tree hash | |
| working tree clean | must be `yes`; `DRUSE_SOAK_ALLOW_DIRTY` invalidates the run for promotion |
| Odin release / commit | |
| server binary sha256 | filled by the run |
| generator binary sha256 | filled by the run |
| `CRITERIA.md` sha256 | filled by the run and re-checked at grading |
| `schema.md` sha256 | filled by the run and re-checked at grading |
| artefact schema | `soak/1` |

## 3. Host and isolation

Attach the output of `ops/soak/preflight.sh`. It refuses rather than adapts; if
this host cannot satisfy the topology below, **change this file and commit the
change** before running. Do not narrow the affinity at the prompt.

| Field | Value |
|---|---|
| hostname / provider | |
| CPUs online | ≥8 for the 0-3 / 4-7 split |
| server CPU set | |
| generator CPU set | |
| governor / turbo | |
| NUMA nodes | |
| RAM / swap / swappiness | |
| nofile hard limit | ≥8192 |
| cgroup | |
| `nstat` present | must be `yes`; absent fails the run |
| free disk | |
| clock synchronised | |
| known neighbours | |

## 4. Workloads, rates and connections

State every profile that will run and every profile that will not. A profile
absent without a pre-registered reason fails the run; a profile absent *with*
one does not. Both directions are enforced.

| Profile | Path | Rate | Connections | Expected status | In this campaign? |
|---|---|---:|---:|---|---|
| health | `/health` | 20/s | 16 | 200 | |
| tiny | `/tiny` | 10,000/s | 128 | 200 | |
| json encode | `/json/medium` | 1,500/s | 128 | 200 | |
| json decode | `/json/medium/decode` | 4,000/s | 256 | 204 | |
| 64 KiB | `/bytes/64k` | 150/s | 64 | 200 | |
| blocking | `/wait/40ms` | 15/s | 32 | 200 | |

Injected faults, and the cycles they run on:

| Injection | Every | Attempts | Declared in |
|---|---|---:|---|
| `rst-after-write` | 5th cycle | 128 | `control/injected.txt` |
| slow readers | 5th cycle | 24 | `control/injected.txt` |

Injected faults are counted apart from spontaneous failures and never netted
against them.

## 5. Ladder

R2-WP04. A failure at one step stops the ones after it. A fix restarts at smoke
with a **new candidate**. Runs of different builds are never concatenated to
reach twelve hours.

| Step | Duration | Question | Can promote? | Result |
|---|---:|---|---|---|
| smoke | 10 min | wiring, schema, clocks, hashes | no | |
| burn-in | 30 min | every workload and fault class appears | no | |
| rehearsal | 2 h | fast drift, evidence volume | no | |
| final | ≥12 h | R2 stability criterion | yes, if PASS | |

## 6. Criteria and SLO

The eighteen criteria in `ops/soak/CRITERIA.md` apply as written and are
pinned by hash. Anything **additional** for this campaign goes here, with a
number, before the run.

| # | Criterion | Threshold | Rationale |
|---|---|---|---|

Service SLO for this candidate — not copied from a microbenchmark:

| Workload | Availability | p50 | p95 | p99 | Error budget |
|---|---|---|---|---|---|

## 7. Abort and invalidation

**Abort** (stop the run; the result stands as a red run):

- RSS safety stop at 4 GiB;
- server death or restart;
- health p99 over 250 ms for _N_ consecutive cycles;
- any unclassified failure.

**Invalidate** (the run says nothing about the product — instrument or host
failure, readiness rule G2):

- the sampler stops before the run ends;
- an artefact the schema requires is missing;
- a binary or config changes mid-run;
- the host is disturbed (neighbour, thermal event, maintenance).

An invalidated run is preserved, not deleted. It is evidence about the
instrument.

## 8. Permitted comparisons

_Which earlier campaigns this one may be compared with, and why the work is
equivalent. Comparisons not listed here are not licensed by this campaign._

## 9. Repetition plan

_How many repeats, in what order, and what disagreement between them means._

## 10. Owner and window

| Field | Value |
|---|---|
| owner | |
| window (UTC) | |
| escalation | |
| evidence directory | `evidence/YYYY-MM-DD-r2-soak-<candidate>/` |

---

## Result

Filled in **after** the run. The analyser's output is the verdict; this section
cites it and does not restate it.

| Field | Value |
|---|---|
| verdict | |
| analyser output | `analysis/verdict.json` |
| reasons | |
| decision | PROMOTE TO R2 / HOLD AT R1 / REVOKE |
