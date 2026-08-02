# R2-WP03 verdict — observability outside the blind spot

**Decision: R2-WP03 CLOSED, arm B. The gate stays at R1.**

AUD-P2-009 is closed: application saturation and network loss are now
distinguishable, an absent sample carries a cause instead of being interpolated,
and the two levels an operator needs — lane occupancy and connection occupancy —
exist against the ceilings they are measured against. None of that is a result
about Druse's stability, capacity or fitness for production. **No soak was run.**

Criteria frozen before the first run in
`planning/readiness/R2-WP03-preregistration.md` (G3), commit `0f84275`, one
commit ahead of the experiment and three ahead of the implementation.

## What was measured

Full lane occupancy established by barrier — every lane counted inside a handler
before a single sample — then 120 scheduled samples per arm.
Raw: `raw/arm-baseline.txt`, `raw/arm-arm-a.txt`, `raw/arm-arm-b.txt`.
Analysis: `analysis/arms.md`.

| Arm | Delivered | p50 | p99 | Absences ambiguous with the network |
|---|---|---|---|---|
| `baseline` — `/stats` as a route | **0 / 120** | — | — | **120** |
| A — second `App`, own lanes | 120 / 120 | 0.38 ms | 0.54 ms | 0 |
| B — snapshot file, own thread | 120 / 120 | 0.043 ms | 0.087 ms | 0 |

**The negative control went red, which is what made the run count.** B1n said in
advance that a `baseline` at or above 99.9% would void the whole run rather than
pass it, because it would mean the saturation was never established.
`target_saturation_refusals` = 120 names the mechanism: the acceptor refused
every scrape because no lane was free.

## Why B, given that A and B tied

A and B both delivered 120 of 120 and both satisfy B1 and B3. The 8× latency
difference is real and irrelevant at scrape scale. **The decision is B4.**

Every absence arm A can produce is an HTTP failure — refused, timeout, empty
reply, receive error — and **each of those four is producible both by an
application that stopped answering and by a network that dropped the exchange**.
A makes the indistinguishable case rarer. It does not remove it, and AUD-P2-009
is a finding about indistinguishability, not about frequency.

B has no network between the metric and its reader. The causes that remain —
`missing`, `unreadable`, `malformed`, `stale`, `no_process` — all name the
application.

Arm A remains supported and documented as an admin listener
(`docs/operations.md` §5). It is not a mistake; it is not the answer to this
finding.

## OBS-001 — the finding the measurement produced

Not in the audit, and not reasoned about in advance. It came out of reading the
server's own counters during the saturation window.

**Every cumulative field in `Server_Stats` is written when work completes** —
`responses_sent` on send completion, `handler_dwell_ns` after the dispatch
returns. At full lane occupancy nothing completes, so all of them freeze. The
utilization formula `docs/operations.md` teaches,
`Δhandler_dwell_ns / (lanes × Δwall)`, therefore reads **zero at the exact moment
utilization is one**.

Measured: four of four lanes provably inside handlers, 120 of 120 scrapes
refused for saturation, `handler_dwell_ns` = **0**, `responses_sent` = **0**.

**A fully saturated server and an idle server produce identical graphs**, and
before this work package nothing in the public surface told them apart. That is
the second half of AUD-P2-009's sentence — "cumulative counters do not replace
gauges of occupancy and resolved capacity" — and it is sharper than it reads.

It also cost a correction inside this campaign: the first version of the arm
program read `web.stats` *after* `web.stop`, where the documented contract
returns the zero value, and printed `target_saturation_refusals 0` for a run in
which the acceptor had refused all 120 scrapes. A confident, plausible, wrong
number. It is fixed in `experiments/27-observability-arms/main.odin` with the
reason written at the read.

## What was accepted

Against the criteria frozen in the pre-registration:

| ID | Criterion | Result | Evidence |
|---|---|---|---|
| B1 | chosen arm ≥ 99.9% under saturation | **PASS** — 120/120 | `raw/arm-arm-b.txt` |
| B1n | negative control below 99.9% | **PASS** — 0/120 | `raw/arm-baseline.txt` |
| B2 | 100% of absences carry a cause | **PASS** — `unclassified 0` in all three arms | `raw/arm-*.txt` |
| B3 | p99 read latency ≤ 10 ms | **PASS** — 0.087 ms | `raw/arm-arm-b.txt` |
| B4 | zero network paths between metric and sampler | **PASS** — by construction | ADR-050 |
| B5 | exporter CPU ≤ 60 ms per 60 s idle | **PASS** — +20 ms | `analysis/overhead/verdict.txt` |
| B6 | `VmHWM` delta ≤ 2048 KiB | **PASS** — +48 KiB | `analysis/overhead/verdict.txt` |
| B7 | lane cost exactly zero | **PASS** | `tests/r2-observability-saturation`, `raw/controls.txt` |
| — | throughput (DIAGNOSTIC, not a criterion) | **INCONCLUSIVE** | `analysis/overhead-throughput/verdict.txt` |

### B5 and B6, and why the first attempt was thrown away

Five paired alternating reps, 60 s idle each. `no-export` burned 6, 6, 5, 6, 6
clock ticks; `with-export` burned 7, 8, 7, 8, 8. Every exporter rep is above
every control rep, so the +20 ms median difference is a separation rather than a
coincidence — against a 60 ms budget and a 10 ms control-arm spread. `VmHWM`
came out +48 KiB against a 2048 KiB budget; that delta is smaller than the
control arm's own 92 KiB variation, so what B6 establishes is an **upper
bound**, not a measurement of the exporter's memory.

**The first version of this measurement was discarded, not massaged.** One pair
of runs put the exporter at **minus 40 ms** of CPU and minus 1056 KiB of memory.
A negative cost is not a fast exporter; it is a measurement saying it cannot see
what it was pointed at, and printing PASS from it would have been a plausible
number that measured nothing. The script now refuses a negative delta and
refuses a control-arm spread wider than the budget.

A second defect surfaced in the same place and is worth recording because it is
the work package's own subject. The server is started inside a command
substitution, so it is a child of that *subshell*; `wait $pid` therefore returned
immediately, and the dying server wrote its final drain snapshot **inside the
next arm's measurement window**. The symptom was a `no-export` arm reporting one
export tick — a number that could only come from a process that was supposed to
be gone. `stop_server` now polls `/proc` until the pid is gone, and the analysis
**invalidates** any run whose control arm saw an export tick. A measurement whose
window is not the window it claims is the same class of defect as a metric that
reports something other than its name.

### The throughput diagnostic is INCONCLUSIVE, and not for the reason expected

The pre-registration froze an inconclusive rule for host noise. That rule did not
fire; a different validity problem did.

`openload` is a **fixed-rate** generator. At 2000 rps offered, both arms
delivered 1999.9 rps with zero transport errors across seven paired reps. The
server was never the bottleneck, so the measurement is the generator's clock
reported to four decimal places — a number that looks like a result and is not
one. The analysis now detects this case and refuses to call it a pass.

What the run does support is a weaker and honestly-labelled claim: **no
regression** — at a rate this server handles comfortably, the exporter cost zero
delivered requests and zero transport errors. It says nothing about capacity,
which is R2-WP05 on a host that is not this one (G4).

B7 is the criterion that actually closes the finding, and it is asserted rather
than sampled: an idle server, the exporter running for several periods, and then
`handler_dwell_ns == 0` and `responses_sent == 0`. Mutant `m5` gives the exporter
an HTTP scrape to perform and the assertion goes red, so the control can detect
its own absence.

## The instrument proving itself (G2)

`build/check_r2_observability_controls.sh`, wired into `build/check.sh`. Six
mutants, each required to go red **and** to go red for its own stated reason:

| Mutant | What it breaks | Expected red |
|---|---|---|
| m1 | the occupancy gauge always reads zero | `handlers_active is 0 of 4` |
| m2 | capacity reported without the shutdown reserve | `connection_capacity` |
| m3 | the reader accepts a record with no terminator | `no \`end\` terminator` |
| m4 | a stale record reads as a value | `must not read as a value` |
| m5 | the exporter spends lane time | `B7 FAILED` |
| m6 | the saturated route claims to answer | `answered while every lane was inside a handler` |

m1 is the one worth naming. A gauge stuck at zero is what the first version of
every metric looks like, and at full occupancy every counter around it is frozen
— so nothing else in the snapshot would contradict it.

## The gate

`build/check_r2_observability_controls.sh` runs inside `build/check.sh` and
passed there: `raw/gate.txt` lines 1513–1527, seven mutants red for their own
reasons.

**The local gate run does not complete, and the reason is the container.**
`build/check_wp72_controls.sh` raises the soft `RLIMIT_NOFILE` to 8192 for its
3,000-connection laboratory and fails closed when it cannot; this container's
hard limit is 4096, so no user in it can satisfy that. Proven rather than
asserted: a pristine worktree of `origin/main` at `f560f8b`, in the same
container as the same user, fails at the identical line
(`raw/gate-wp72-environment.txt`).

**CI is the authority.** Two earlier gate stops in this campaign were real and
were fixed rather than explained away: an experiment package nothing checked
(`experiments/run_checks.sh`), and a generated cookbook page left stale by the
change to `examples/10-config-and-health` plus a recipe page 21 lines over its
budget.

## Answering ADR-049

**Yes, metrics can be aggregated across processes, and ADR-049 is NOT closed as
refused.** Each worker writes its own snapshot; the sidecar sums them and
publishes `workers_seen` against a `workers_expected` that comes from the
supervisor, never from counting files. A dead worker stops writing, its record
goes stale, and the aggregate is marked incomplete instead of silently summing
fewer.

The cost is real and is now a written entry requirement of R3-WP10: **the
supervisor must publish `workers_expected`**. An aggregate is exactly as honest
as that number, and a wrong one reproduces the defect ADR-049 exists to avoid —
a number that looks global and is not — one level up.

Arm A could not have done this. N admin listeners on N ports means a dead worker
arrives at the scraper as a failed scrape, which by B4 it cannot tell from a lost
packet.

## What this does NOT establish

Stated plainly, because an evidence directory dated during R2 will later be read
as if it were about the product.

- **No soak was run.** Not 12 h, not 2 h, not the burn-in. R2-WP04 is untouched
  and blocked on R2-WP02.
- **No capacity envelope, SLO, security review, supply-chain rebuild or canary
  exists.** WP02 and WP04–WP08 are open.
- **This host is disqualified**, and says so itself: `raw/preflight-this-host.txt`
  records five reasons — 4 online CPUs against a pinned 4–7 affinity, `taskset -c 4-7`
  rejected, no `nstat`, a 4096 hard `nofile` against a required 8192, and 29 GiB
  free against an estimated 100 GiB.
- **Nothing here was measured with more than one process.** The aggregation
  answer above is about what the mechanism *admits*. Proving it is R3-WP10.
- **The arm latencies are numbers about this container**, not about Druse. Four
  shared CPUs (G4). What is decisive in the comparison is which *class* of
  failure each arm admits, which is structural.
- **Nothing here changes the R1 freeze.** The supported profile, the accepted
  risks and their expiry are exactly as `planning/readiness/R1-freeze.md` left
  them. **This work package promotes nothing.**

## Residual, declared rather than quietly dropped

**Active versus idle connections was not separated**, and the minimum-signal list
in `planning/readiness/R2-restricted-production.md` §4 asks for both.
`active_connections` is "admitted and not yet closed". The backend maintains a
`Connection_State` with `.Idle`, but assigns it through one chokepoint **and**
three direct writes (`.New`, `.Closing`, `.Closed`), so a counter placed at the
chokepoint would undercount connections closing straight out of idle. Doing it
correctly is a vendor change across all four sites; it was not made here, and it
is recorded as a residual of this work package rather than as done.

Everything else on the minimum-signal list is delivered: readiness/draining,
resolved handler capacity and current occupancy, active connections and
saturation refusals, responses/bytes/send errors/write aborts, FDs/RSS/HWM/
threads/restart count, `ListenDrops`/`ListenOverflows`/retransmits, scrape
success/latency **and the cause of absence**, and proxy upstream connect
errors/retries/active connections.

## Risks accepted

| Risk | Scope | Mitigation | Validity |
|---|---|---|---|
| The snapshot is one export period old | An operator reading a level sees it up to one period stale | `stale` is an alert, not an interpolation; the reference `max_age` is four periods | Until R2-WP04 measures real period jitter under load |
| `handlers_active` is a sampled level, not a transaction | Lanes may enter and leave while the loop over them runs | It is a gauge, and the loop is bounded at 32 lanes | Permanent, by design |
| The reference exporter is application code, duplicated in two places | A fix in one could miss the other | `build/check_r2_observability_controls.sh` asserts the temp-then-rename discipline in both | Until an operator asks for it in the framework, which would be a G5 decision |
| Overhead was measured on a 4-CPU shared container | B5 sits two clock ticks above the noise floor; B6 is an upper bound rather than a measurement | The abort rules were frozen in advance and the result is reported as measured, including where it is inconclusive | R2-WP02/WP04 on a dedicated host |
| The throughput comparison was never actually performed | A fixed-rate generator below capacity cannot produce one | Reported as INCONCLUSIVE with the reason, not as a pass; the weaker no-regression claim is labelled as such | R2-WP05 |

## Next

**R2-WP02.** Qualify a dedicated host with `ops/soak/preflight.sh` and commit the
pre-registration before the first run. Nothing in R2 past this point can be
answered on this container.
