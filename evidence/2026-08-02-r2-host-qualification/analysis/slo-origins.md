# The service SLO — every number, and where it came from

R2-WP02 requires a service SLO per workload. This file is the accounting for it:
one row per commitment in §6 of the pre-registration, with its origin. There are
exactly three origins, and no fourth was used.

- `measured` — this repository measured it; the artefact is cited.
- `inherited` — already committed as a criterion; the file is cited.
- `open` — no basis exists. The row states how the number will be obtained and
  the campaign runs without it.

**An open row is a deliverable.** An invented number is not. A microbenchmark is
a fact about a machine; an SLO is a promise to the user of a service, and the two
do not convert.

## Tally

| Origin | Count | Which |
|---|---:|---|
| `measured` | 1 | rollback RTO |
| `inherited` | 11 | health p99 and error budget; availability for the five non-health workloads; interpolation ban; scrape cause taxonomy; scrape-under-saturation expectation; sampler absence; RSS slope and safety stop; FD stability; thread stability |
| `open` | 18 | fifteen latency cells (p50/p95 for `/health`, p50/p95/p99 for the other five); the tolerable rate of failing scrapes; recovery time after saturation; start-to-ready in the restart RTO |

## The one measured number

**Rollback RTO ≤ 3 s.** `evidence/2026-08-02-r1-pilot-exercise/manifest.txt`
records `rollback_seconds=3`, corroborated by `raw/timeline.tsv`
(`rollback-smoke-pass seconds=3`) and `raw/rollback-process.txt`.

It carries a limitation stated in the pre-registration: it was measured on the
R1 pilot host with the pinned Caddy in front, not on this campaign's host. It is
re-measured there or it remains a number from a different machine.

## Why fifteen latency cells are open

There is no latency figure for this candidate taken on a host where the load
generator was not on the server's own cores. Every performance report in
`docs/reports/` from 2026-07 used `0-3` / `4-7` on a c5.2xlarge, whose SMT state
was flagged as suspect in advance and never recorded — see
[`topology-check.md`](topology-check.md) §5.

Even setting that aside, the rates in §4 of the pre-registration are **offered
load chosen for a stability test**, halved after a red smoke on 2026-07-29
(`ops/soak/CRITERIA.md`, "The criteria have a history"). Passing them means the
server kept up with a load someone chose. It does not make any percentile a
promise.

Writing a p99 today would therefore mean copying a microbenchmark or inventing a
number. The pre-registration does neither and says so in the table itself.

**The route to closing them**, in order and in separate commits:

1. the rehearsal step (2 h, R2-WP04) produces the first per-cycle percentile
   distributions on a core-disjoint host;
2. R2-WP05 finds the knee and the degradation curve;
3. the SLO is set at a stated fraction of the knee and committed as an amendment
   to the pre-registration **before the final 12 h run**.

Step 1 may not set a threshold that step 1 then passes. That is G3 read
backwards, and it is the reason the ordering above is written down rather than
left to judgement at the time.

## The one inherited number worth arguing about

**`/health` p99 ≤ 250 ms** is inherited from `CRITERIA.md` criterion 1 rather
than measured here, and it is the single latency cell that is not open.

It is defensible because it is not a performance claim. `/health` is 20 requests
a second returning a fixed string; a p99 of a quarter of a second on that route
is a **liveness** bound — it fires when the server has stopped being able to
answer at all, not when it has become slow. Every workload where the number would
be a performance claim is open.

## The scrape budget, and why it is an alert rather than a budget

ADR-050 moved the metric out of the request path: a thread that owns no Handler
lane writes a snapshot file, and a sampler outside the process reads it
(`ops/monitoring/snapshot-format.md`). Under deliberate total lane occupancy that
channel answered **120 of 120** while `/stats` as a route answered **0 of 120**
(`evidence/2026-08-02-r2-observability-arms/`).

A channel that answers under saturation has no routine failure rate to amortise.
So a sample with `cause != ok` is an alert to be investigated, not a budget to be
spent, and interpolation across the gap is forbidden absolutely — a filled gap is
a claim the process made about itself while it was silent (AUD-P2-009).

What is **open** is the rate at which that channel fails over twelve hours. WP03
measured 120 samples over minutes and asked a different question. The rehearsal
gives the first estimate; until then each non-`ok` sample is reasoned about
individually rather than counted against a threshold nobody has grounds for.
