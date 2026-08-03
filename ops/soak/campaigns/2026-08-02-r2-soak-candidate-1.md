# Campaign pre-registration — `r2-soak-candidate-1`

**R2-WP02.** Copied from [`TEMPLATE.md`](TEMPLATE.md) and committed **before the
first run**. Readiness rule G3: criteria are frozen before the run, and this
file's commit date is either earlier than the run's `started_utc` or it is not.

**This file promotes nothing.** The gate stays at R1. It makes a future run
*admissible*; it is not evidence about Druse and contains no measurement of it.

**The host does not exist yet.** §3 states the topology a host must satisfy and
why the obvious one does not. Until a host is provisioned and both
`ops/soak/preflight.sh` and `ops/soak/smoke.sh` are green on it, R2-WP04 cannot
start. That is a blocker recorded, not a criterion relaxed.

---

## 1. Hypothesis

**H1:** the candidate identified in §2, on the host described in §3, sustains
the six workloads of §4 for twelve continuous hours without violating any of the
eighteen criteria in `ops/soak/CRITERIA.md` or the service SLO in §6.

One claim, and it is falsifiable by a single red criterion.

**Not hypotheses.** Written now so the result cannot be stretched later:

- **Not a capacity measurement.** The rates in §4 are *offered load chosen for a
  stability test*, not a ceiling and not a demonstrated maximum. The knee, the
  envelope and the degradation curve are R2-WP05 and this campaign must not be
  cited for any of them.
- **Not a statement about real traffic.** One generator, six synthetic profiles,
  loopback or a private link, no client diversity, no CDN, no keep-alive
  distribution taken from anything real. Composition under real traffic is
  R2-WP07.
- **Not a comparison with any other framework, build or campaign.** See §8; the
  permitted list is empty on purpose.
- **Not a security result.** R2-WP06 is untouched.
- **Not a statement that the SLO in §6 is achievable.** Fifteen of its eighteen
  latency cells are `open` (§6.2) — five workloads with no percentile at all, and
  `/health` with only its inherited p99. This campaign is where the first honest
  inputs to them come from, which is not the same as passing them.

## 2. Candidate identity

Readiness rule G1: a candidate is an identity, not a directory. Any change to
code, toolchain, configuration or **instrument** creates a new candidate, and
evidence is not transferred by similarity.

| Field | Value |
|---|---|
| commit | recorded by `run-soak.sh` into `manifest.txt` at run start |
| tree hash | recorded by the run |
| working tree clean | must be `yes`; `DRUSE_SOAK_ALLOW_DIRTY` invalidates the run for promotion |
| Odin release / commit | `dev-2026-07a` / `819fdc7` (`odin-version.txt`, sha256 verified from the release asset before use) |
| server binary sha256 | filled by the run |
| generator binary sha256 | filled by the run |
| `CRITERIA.md` sha256 | filled by the run and re-checked at grading |
| `schema.md` sha256 | filled by the run and re-checked at grading |
| artefact schema | `soak/1` |

### 2.1 The instrument, pinned here

The commit cannot be pinned in the file that is part of it. The **instrument**
can, and under G1 the instrument is half the candidate's identity — a repaired
`analyze-soak.py` grades differently from the one that shipped, and R2-WP01 is
the finding that says so.

These are the hashes as of the commit that adds this file.
`build/check_soak_controls.sh` recomputes them and fails if they drift, so an
instrument change cannot silently keep an old pre-registration:

<!-- r2-wp02-instrument-hashes -->

| File | sha256 |
|---|---|
| `ops/soak/CRITERIA.md` | `834ed848a6993537fa40f3379f7818fd4b7b562e6e4f2ad9b938649c5c5ca676` |
| `ops/soak/schema.md` | `e611a96f1360f01e2e3d2a9f595c4ebbd62eb5e5484a08aa61137d3764bf5640` |
| `ops/soak/run-soak.sh` | `0ef0dd841f64715aa7a13eab68c3a8e8de483fba430fa604c9469852d47be2e8` |
| `ops/soak/analyze-soak.py` | `fe10c09657d6f0e47aeb61f9e2486b893d28e5afd007189c49cc29a64fdd7546` |
| `ops/soak/soak-server/main.odin` | `59e22b0b7cd017acb7658023950e3ac35bceb4dfb3e25b21e6d9c717e2823b54` |
| `ops/soak/openload/main.go` | `3382a965e18bb1e714fe36cb6b4ec2ff71b27dfa3818e260c970980d132c48dd` |

<!-- /r2-wp02-instrument-hashes -->

`preflight.sh`, `smoke.sh` and `smoke-server/main.odin` are deliberately **not**
in that table. They qualify the host and then stop; they do not run during the
campaign and do not touch the artefact. Pinning them would make an unrelated
preflight improvement invalidate a pre-registration for no reason a reader could
defend.

## 3. Host and isolation

Attach the output of `ops/soak/preflight.sh`. It refuses rather than adapts; if
the host cannot satisfy the topology below, **change this file and commit the
change** before running. Do not narrow the affinity at the prompt.

### 3.1 The requirement

**Amended twice on 2026-08-02, both times before any run.**

The first amendment took the fallback branch of §3.2: the owner designated an
existing `c5.2xlarge` at `44.200.160.96`, so the affinity changed to a
core-disjoint split and the lane count dropped. That host qualified on thirteen
of fourteen requirements and failed on free disk — 17 GiB against an estimated
100 GiB (`evidence/2026-08-02-r2-host-qualification/raw/ec2-preflight-core-split.txt`).

The second amendment is this one. The owner provisioned a **new instance**,
`184.72.201.140`, with 143 GiB free. It is the host of record below.

**It is not the same machine, and G1 does not let that pass quietly.** Same
instance type, same four-core SMT topology, and three differences that are part
of the candidate's identity: a Xeon **8275CL** instead of an 8124M, Ubuntu
**26.04** instead of 24.04, and kernel **7.0.0-1006-aws** instead of
6.17.0-1017-aws. No measurement taken on the previous host carries over, and none
was — nothing beyond a smoke ever ran there.

| Field | Required value |
|---|---|
| hostname / provider | AWS `c5.2xlarge`, `i-05c3c8168b18776a5`, `us-east-1b`, Xeon Platinum 8275CL @ 3.00 GHz |
| OS / kernel | Ubuntu 26.04, `7.0.0-1006-aws` |
| logical CPUs online | ≥ 8 — **measured: 8** |
| physical cores | 4 (2 threads each), siblings `(0,4) (1,5) (2,6) (3,7)` — **measured, not assumed** |
| **isolation** | **`preflight.sh` must report `physical_core_disjoint=yes`** |
| server CPU set | `0,1,4,5` — physical cores `{0,1}` |
| generator CPU set | `2,3,6,7` — physical cores `{2,3}` |
| lanes (`DRUSE_SOAK_LANES`) | **2** (was 4; see §3.4) |
| **`memlock` (`RLIMIT_MEMLOCK`)** | **unlimited — see §3.5. The stock 8 MiB is a known startup crash (F-C03-2), not a tuning preference.** |
| governor / turbo | recorded, not constrained |
| NUMA nodes | recorded; a multi-node host needs this file amended before running |
| RAM | ≥ 8 GiB (the RSS safety stop is 4 GiB) |
| swap / swappiness | recorded |
| nofile hard limit | ≥ 8192 |
| cgroup | recorded |
| `nstat` present | must be `yes`; absent fails the run |
| free disk | ≥ 100 GiB at `DRUSE_SOAK_BASE` |
| clock synchronised | `NTPSynchronized=yes` |
| known neighbours | none; the host runs nothing else for the window |
| upload/stream/proxy smoke | `ops/soak/smoke.sh` reports `smoke=pass` **without** `smoke_on_unqualified_host` |

### 3.2 Why `ThreadsPerCore=1`, and why a c5.2xlarge is not enough

The campaign pins the server to CPUs `0-3` and the generator to `4-7` because
the generator must not compete with the process under measurement. **On a
c5.2xlarge those eight vCPUs are four physical cores with two hyperthreads
each**, and the Nitro layout pairs them `(0,4) (1,5) (2,6) (3,7)` — so `0-3` and
`4-7` are the two thread halves of the *same four cores*, and the generator
competes with the server on every core the server runs on.

The two sets are disjoint by number and identical by core. Until R2-WP02 the
preflight compared them as strings and reported nothing at all; it now maps each
CPU through `thread_siblings_list` and refuses this shape by name.

**The decision is a host with `ThreadsPerCore=1`** — e.g. a `c5.4xlarge`
launched with `--cpu-options CoreCount=8,ThreadsPerCore=1`, which presents eight
vCPUs that are eight whole cores. Reasons, in order:

1. It is the only option that leaves `run-soak.sh`, `CRITERIA.md` §"The run",
   the four-lane configuration and the whole ladder unchanged. Everything else
   in this file stays true.
2. The alternative below halves the server's physical cores from four to two.
   That changes the machine the candidate is measured on *more* than the SMT
   contamination does, and none of the offered rates in §4 would retain any
   basis at all.
3. The cost is one instance size for the length of the campaign. It is not a
   permanent cost and it buys an isolation property that cannot be recovered
   afterwards by analysis.

**The pre-approved fallback**, if the owner keeps a c5.2xlarge: server
`0,1,4,5`, generator `2,3,6,7` — two whole cores each, which
`build/check_soak_controls.sh` proves the preflight qualifies on exactly that
topology. Adopting it is **an edit to this file, committed before the run**, and
it carries three consequences that must be written into the edit:

- `DRUSE_SOAK_LANES` drops from 4 to 2 (two physical cores cannot host four
  lanes plus a generator; `planning/verification-campaign-plan.md` reaches the
  same conclusion from the other direction);
- every rate in §4 loses its inherited basis and must be re-derived at the
  rehearsal step before the final run;
- the halved core count is recorded as a limitation of the candidate, and no
  result is comparable to a four-core run.

It is not a runtime switch. Setting `DRUSE_SOAK_SERVER_CPUS` in the environment
to make the preflight pass is the thing `preflight.sh` refuses by name — *"Do
not adapt the affinity silently during a campaign"* — and it produces a run
whose manifest disagrees with its plan.

### 3.5 `RLIMIT_MEMLOCK`, and why it is a requirement rather than tuning

The new host ships the stock AMI default: `memlock` 8 MiB. Every io_uring ring
this framework allocates pins memory against that limit, and this repository has
already recorded what happens when it is too small — **F-C03-2**, diagnosed as a
startup crash and validated in production, with the cause named in
`planning/verification-campaign-plan.md`: *"Each lane's io_uring rings pin memory
against `RLIMIT_MEMLOCK`. This is the documented cause of F-C03-2."*

So it is listed in §3.1 as a host requirement, not left to whoever runs the
campaign. It must be raised **persistently** — `/etc/security/limits.conf` and
`LimitMEMLOCK=` on any unit — because a twelve-hour run started from a login
shell that inherited the default fails for a reason nobody traces back to a
limit.

`preflight.sh` did not check it, which was a gap in the instrument — and
`R2-restricted-production.md` §3 lists "nofile, memlock, cgroup e kernel
compatíveis" among the preflight's own requirements, so the gap was this work
package's to close rather than the next one's. It now refuses a host whose
`memlock` cannot hold the rings, with a control in
`build/check_soak_controls.sh`.

### 3.6 Third amendment — the metric channel, after the smoke measured it

**Amended 2026-08-03, after the smoke step and before the burn-in.**

The smoke ran and graded **FAIL**, and the instrument named why. One of the three
reasons is this amendment:

> `/stats did not answer 200 on 322 of 658 samples (295x exit 52 (empty reply
> from server), 27x exit 56 (receive failure))`

`run-soak.sh` was scraping `/stats` over HTTP, once per second, on the same
Handler lanes it was sampling. At two lanes that is half the machine taken from
the measurement to take a measurement. **ADR-050 had already decided against
this channel** (R2-WP03, AUD-P2-009) and the soak server had already grown the
out-of-band exporter — the runner had simply never passed `argv[3]`, so the
channel this project shipped had never once run in a campaign.

Changed, before the next step:

- the runner passes the snapshot path, turning the exporter on;
- the sampler and the per-cycle capture read the **file**, not the route;
- absence carries one cause from ADR-050's closed taxonomy — `missing` (101),
  `unreadable` (102), `malformed` (103), `stale` (104), `no_process` (105),
  `disabled` (106) — every one of which names the application;
- `CRITERIA.md` criterion 8 is rewritten to match, and negative control 1 in
  `build/check_soak_controls.sh` is ported to drive every branch of the new
  taxonomy, including a **positive** case.

**Why this is not a criterion moved to fit a result (G3).** The smoke step
cannot promote — §5 says so, and it was run to find exactly this class of fault
before the twelve-hour run. The change is committed *before* the next step, the
failing artefact is preserved, and the amendment names the measurement that
caused it. What is forbidden is editing a criterion after a run that *could*
have promoted; this is the ladder doing its job.

**The instrument hashes in §2.1 are updated in the same commit**, which the gate
enforces.

### 3.4 What the amendment costs, stated before the run

The host is kept and the affinity changes. §3.2 pre-approved this and named three
consequences; all three are now in force, and one more was found on the host.

1. **The server has two physical cores, not four.** `0,1,4,5` is cores `{0,1}`
   and `2,3,6,7` is cores `{2,3}`. Half the machine each, and no thread shared.
2. **`DRUSE_SOAK_LANES` is 2.** Two physical cores cannot host four Handler
   lanes plus a load generator without reintroducing the competition this
   amendment exists to remove. `planning/verification-campaign-plan.md` reaches
   the same number from the other direction.
3. **Every rate in §4 loses its inherited basis.** They were set on this machine
   under `0-3`/`4-7` with four lanes — which §3.3 now confirms was SMT-shared —
   and they are carried forward only as *starting* offered load. The burn-in and
   the rehearsal decide whether they are sustainable at two lanes; if they are
   not, the rates are amended here, in their own commit, before the final run.
   A rate lowered after seeing a red final run would invalidate that run (G3).
4. **No result from this campaign is comparable to a four-core run**, including
   any future campaign on a `ThreadsPerCore=1` host. The core count is part of
   the candidate's identity.

The `ThreadsPerCore=1` option in §3.2 is not withdrawn. It remains the better
host, and taking it later is a new candidate and a new pre-registration — not an
edit to this one.

### 3.3 A limitation of everything measured before this campaign

Every published performance report in `docs/reports/` from 2026-07 was measured
on a c5.2xlarge with the server on `0-3` and the generator on `4-7`.
`planning/verification-campaign-plan.md` §"It has four physical cores, not
eight" flagged in advance that this was "almost certainly" sibling pinning and
told the reader to confirm it with `lscpu -e` before anything else. **No
confirmation was ever recorded.**

**Resolved on 2026-08-02, and the answer is the bad one.** The instance was
still running, the command was run on it, and the output is committed in
`evidence/2026-08-02-r2-host-qualification/raw/ec2-host-topology.txt`:

```text
CPU NODE SOCKET CORE            thread_siblings_list
  0    0      0    0            cpu0=0,4
  1    0      0    1            cpu1=1,5
  2    0      0    2            cpu2=2,6
  3    0      0    3            cpu3=3,7
  4    0      0    0
  5    0      0    1
  6    0      0    2
  7    0      0    3
```

Four physical cores. CPUs `0-3` and `4-7` are the two thread halves of the same
four cores, exactly as warned. It is the same machine — Xeon Platinum 8124M @
3.00 GHz, kernel `6.17.0-1017-aws` — that `docs/reports/2026-07-25-json-
application-performance.md` and the rest name as their host.

**So every one of those campaigns ran with the load generator on the server's own
physical cores.** Not "possibly": the topology is now measured and recorded. This
does not make any of those numbers wrong in the sense of miscomputed — the
measurement did what it said — but it means each of them describes a server
sharing all four of its cores with the process generating its load, which is not
the configuration any of them claims to be reporting.

Two consequences, and neither is this work package's to resolve:

- §8 licenses no comparison with any of them, and now for a measured reason
  rather than an unknown one;
- whether those reports need a correction notice is a decision for their owner.
  It is recorded here and not acted on: amending published reports is outside
  R2-WP02, and doing it quietly inside a host-qualification commit is exactly the
  kind of edit this programme exists to prevent.

## 4. Workloads, rates and connections

Every profile that will run, and every profile that will not. A profile absent
without a pre-registered reason fails the run; a profile absent *with* one does
not. Both directions are enforced by the analyser.

| Profile | Path | Rate | Connections | Expected status | In this campaign? |
|---|---|---:|---:|---|---|
| health | `/health` | 20/s | 16 | 200 | yes |
| tiny | `/tiny` | 10,000/s | 128 | 200 | yes |
| json encode | `/json/medium` | 1,500/s | 128 | 200 | yes |
| json decode | `/json/medium/decode` | 4,000/s | 256 | 204 | yes |
| 64 KiB | `/bytes/64k` | 150/s | 64 | 200 | yes |
| blocking | `/wait/40ms` | 15/s | 32 | 200 | yes |
| 1 MiB | `/bytes/1m` | — | — | — | **not as a rated profile.** The route is exercised — it is the target of the slow-reader injection below, 24 sockets abandoned mid-response (`run-soak.sh`) — but it carries no rate, no connection count and no expected status, so it has no SLO row in §6.2. Giving it one now would be a new profile with no history, decided during a stability campaign. Recorded in `control/short.txt` at run time. |

**These rates are offered load, not promises.** They come from
`ops/soak/CRITERIA.md` §"The criteria have a history", where they were halved
after a red 10-second smoke on 2026-07-29 — on the topology §3.3 describes. They
are inherited for continuity of the instrument, and §6.2 is where that inheritance
stops: none of them is an SLO and none is a capacity claim.

Injected faults, and the cycles they run on:

| Injection | Every | Attempts | Declared in |
|---|---|---:|---|
| `rst-after-write` | 5th cycle | 128 | `control/injected.txt` |
| slow readers | 5th cycle | 24 | `control/injected.txt` |

Injected faults are counted apart from spontaneous failures and never netted
against them (CRITERIA.md 14).

## 5. Ladder

R2-WP04. A failure at one step stops the ones after it. A fix restarts at smoke
with a **new candidate**. Runs of different builds are never concatenated to
reach twelve hours.

| Step | Duration | Question | Can promote? | Result |
|---|---:|---|---|---|
| host qualification | — | `preflight.sh` green, `smoke.sh` green | no | pending — no host |
| smoke | 10 min | wiring, schema, clocks, hashes | no | |
| burn-in | 30 min | every workload and fault class appears | no | |
| rehearsal | 2 h | fast drift, evidence volume, first latency distributions | no | |
| final | ≥12 h | R2 stability criterion + §6 SLO | yes, if PASS | |

The rehearsal is also where the two open estimates from R2-WP01's accepted risks
are corrected: the 100 GiB disk figure in `preflight.sh` and the 2%
`expected_samples` tolerance in `analyze-soak.py`.

## 6. Criteria and SLO

The eighteen criteria in `ops/soak/CRITERIA.md` apply as written and are pinned
by hash (§2.1). Anything **additional** for this campaign is numbered here,
before the run.

| # | Criterion | Threshold | Rationale |
|---|---|---|---|
| C18 | the run's affinity equals §3 | `manifest.txt` `server_cpus`/`generator_cpus` match this file exactly | a run that adapted its affinity is a run whose plan and artefact disagree |
| C19 | the host was qualified by core, not by number | the attached preflight report carries `physical_core_disjoint=yes` | the property §3.2 exists to guarantee, asserted in the artefact rather than assumed |
| C20 | the smoke was green on this host, unqualified-override absent | `smoke=pass` and no `smoke_on_unqualified_host` line | a green smoke taken with the override is a fact about the script |

### 6.1 What an SLO is here

A **service SLO is a promise to the user of the service.** A microbenchmark is a
fact about a machine. The two are not convertible, and copying a benchmark
number into this table would produce a promise nobody decided to make.

So every row below carries an **origin**, and there are exactly three:

- `measured` — a number this repository has measured, with the artefact cited;
- `inherited` — a number already committed as a criterion, cited to the file;
- `open` — no basis exists. The row states how the number will be obtained, and
  the campaign runs without it. **An open row is a deliverable.** An invented
  number is not.

### 6.2 Latency and availability, per workload

*Availability* here means: of the requests the generator offered, the fraction
that completed carrying the expected status.

| Workload | Availability | p50 | p95 | p99 | Error budget | Origin |
|---|---|---|---|---|---|---|
| `/health` | 100% | open | open | ≤ 250 ms | **zero** transport errors | p99 and error budget `inherited` — `CRITERIA.md` 1; p50/p95 `open` |
| `/tiny` | ≥ 99.99% | open | open | open | ≤ 0.01% transport, every failure classified | availability and budget `inherited` — `CRITERIA.md` 2–3; latency `open` |
| `/json/medium` | ≥ 99.99% | open | open | open | as above | as above |
| `/json/medium/decode` | ≥ 99.99% | open | open | open | as above | as above |
| `/bytes/64k` | ≥ 99.99% | open | open | open | as above | as above |
| `/wait/40ms` | ≥ 99.99% | open | open | open | as above | as above |

**Why fifteen of eighteen latency cells are open, in one paragraph.** No latency
figure exists for this candidate on a host where the generator is not on the
server's cores — §3.3 is the reason, and it applies to every number in
`docs/reports/`. The rates in §4 were chosen as offered load for a stability
test, so passing them says the server kept up with a chosen load, not that any
percentile is a promise. Setting a p99 now would mean either copying a
microbenchmark, which §6.1 forbids, or inventing one.

**How they will be obtained, in order.** The rehearsal (§5) records per-cycle
percentiles on the qualified host — the first uncontaminated distributions this
project will have. R2-WP05 then finds the knee and the degradation curve. The
SLO is set from WP05's knee, at a stated fraction of it, and committed **as an
amendment to this file in its own commit, before the final run**. The rehearsal
may not set a threshold the same rehearsal then passes; that is G3 read
backwards.

`/health`'s p99 is the one exception and it is `inherited`, not measured here: it
has been a committed criterion since before R2 and it is a liveness bound rather
than a performance claim.

### 6.3 The rest of the service SLO

| Property | Value | Origin |
|---|---|---|
| **Retry policy** | the generator does **not** retry, at any layer | `decision`. An open-loop generator that retries converts a refusal into latency. `saturation_refusals` is the one counter that still moves while every cumulative counter is frozen under full occupancy (OBS-001), and retrying would hide the signal the campaign most needs to see. Applications behind a proxy may retry; the *measurement* must not. |
| **Missing metric scrape — interpolation** | zero, absolutely | `inherited` — `ops/monitoring/alerts.yml` (`DruseMetricsAbsent`) and `ops/monitoring/snapshot-format.md`. A filled gap is a claim the process made about itself while it was silent (AUD-P2-009). |
| **Missing metric scrape — cause** | every non-`ok` sample carries one of the nine causes in ADR-050's closed taxonomy; a sample absent without a cause is an instrument failure and invalidates the run (G2) | `inherited` — R2-WP03 pre-registration §2 |
| **Missing metric scrape — expected rate** | any `cause != ok` is an **alert**, not a budget: it is investigated, not amortised | `inherited` — the WP03 measurement, `evidence/2026-08-02-r2-observability-arms/`, where arm B answered **120 of 120** under deliberate total lane occupancy. A channel that answers under saturation has no routine failure rate to budget for. |
| **Missing metric scrape — failing rate** | open | `open`. WP03 measured 120 samples over minutes; how often the out-of-band exporter fails over twelve hours is a different question and has never been asked. The rehearsal produces the first estimate; until then a non-`ok` sample is reported and reasoned about individually. |
| **Sampler absence** | zero occurrences of the sampler emitting no line at all | `inherited` — `alerts.yml` `DruseSamplerAbsent`, and `CRITERIA.md` 11 (telemetry ≥ 98% of `expected_samples`) is the campaign-side form of it |
| **Recovery time after saturation** | open | `open`. Nothing has measured it. Method: an R2-WP05 step-down — hold above the knee for a fixed interval, drop to half the knee, and measure the time until p99 re-enters the below-knee SLO. It cannot be stated before the knee is known. |
| **Memory stability** | RSS tail slope ≤ 1 MiB/h over the second half; hard stop at 4 GiB | `inherited` — `CRITERIA.md` 7 and 9 |
| **File-descriptor stability** | back within baseline + 4 after the settling window | `inherited` — `CRITERIA.md` 6 |
| **Thread stability** | constant for the whole run | `inherited` — `CRITERIA.md` 5 |
| **Rollback RTO** | ≤ 3 s from decision to previous version serving | `measured` — `evidence/2026-08-02-r1-pilot-exercise/manifest.txt` (`rollback_seconds=3`), `raw/timeline.tsv`. Measured on the R1 pilot host with the pinned Caddy in front, not on this campaign's host; it is re-measured there or it stays a number from another machine. |
| **Restart RTO** | drain + start-to-ready, where drain ≤ `max_drain_time` (10 s in the soak configuration) and start-to-ready is open | `open` for the second term. `ops/soak/smoke.sh` records `time_to_ready_ms` on the qualified host at 100 ms granularity, which is the first input; a restart-under-load figure needs R2-WP04's ladder and is not claimed here. |

## 7. Abort and invalidation

**Abort** — stop the run; the result stands as a red run about the product:

- RSS above the 4 GiB safety stop;
- server death, restart, `SIGKILL`, or non-zero exit;
- `/health` p99 over 250 ms for **3** consecutive cycles;
- any unclassified failure (`CRITERIA.md` 3);
- kernel `listen_drops` or `listen_overflows` moving off baseline
  (`CRITERIA.md` 13).

**Invalidate** — the run says nothing about the product, because the instrument
or the host failed (readiness rule G2):

- the sampler stops before the run ends;
- an artefact the schema requires is missing;
- a binary or config changes mid-run;
- the affinity used differs from §3 (criterion C18);
- the attached preflight report does not carry `physical_core_disjoint=yes`
  (criterion C19), including the case where it reports `unknown`;
- the smoke report carries `smoke_on_unqualified_host` (criterion C20);
- the host is disturbed — a neighbour, a thermal event, provider maintenance, or
  anything else that ran on the box during the window.

An invalidated run is preserved, not deleted. It is evidence about the
instrument.

## 8. Permitted comparisons

**None.** The list is empty and that is the finding, not an omission.

- Every campaign in `docs/reports/` from 2026-07 ran on a topology whose SMT
  state was never recorded (§3.3). A comparison against an unknown topology is
  not a comparison.
- No prior soak was ever run by the repaired instrument. The eight artefacts in
  `ops/soak/fixtures/` are reference inputs for the analyser, not results.
- The R1 pilot evidence answers operational questions — shutdown, rollback,
  proxy contract — on a different host at a different load, and R1's own freeze
  says so.

This campaign may be compared only with its own repeats (§9) and with later
campaigns that state the same host topology, the same affinity and the same
instrument hashes.

## 9. Repetition plan

Two independent final runs of the **same candidate**, on different days, with
the host re-qualified by `preflight.sh` and `smoke.sh` before each.

- Both PASS → the stability claim stands for the candidate.
- One PASS, one FAIL → **red**. Not best-of-two, and not "the failing one had a
  bad night": a candidate that fails one twelve-hour run in two has an
  unexplained failure, and the failure is the result. The next step is
  attribution, not a third run.
- Both FAIL → red, and R2-WP04 stops.

A third run is only licensed after the disagreement has a named cause and that
cause is either fixed — creating a **new candidate**, restarting at smoke — or
recorded as a limitation.

## 10. Owner and window

| Field | Value |
|---|---|
| owner | the repository owner |
| window (UTC) | **not scheduled** — no host satisfying §3 exists. The window opens when one is provisioned and both `preflight.sh` and `smoke.sh` are green on it. |
| qualification validity | 7 days. A run starting more than 7 days after its qualification re-runs the preflight and the smoke first; a host is not qualified indefinitely. |
| escalation | any abort or invalidation stops the ladder and is reported before the next step, not batched into a final report |
| evidence directory | `evidence/YYYY-MM-DD-r2-soak-candidate-1/` |

---

## Result

Filled in **after** the run. The analyser's output is the verdict; this section
cites it and does not restate it.

| Field | Value |
|---|---|
| verdict | — not run |
| analyser output | `analysis/verdict.json` |
| reasons | — |
| decision | PROMOTE TO R2 / HOLD AT R1 / REVOKE |
