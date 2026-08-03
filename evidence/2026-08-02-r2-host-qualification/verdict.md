# R2-WP02 verdict — the host exists, and one thing disqualifies it

**Decision: R2-WP02 remains OPEN. R2 remains blocked; the gate stays at R1.**

The owner designated the host mid-work-package: an existing `c5.2xlarge` at
`44.200.160.96`. It was inventoried, prepared and measured, and the campaign
pre-registration was amended and committed **before** anything ran on it.

The result is narrow and specific. Of the fourteen host requirements in §3.1,
thirteen are met on this machine. **One is not: it has 17 GiB of free disk
against an estimated 100 GiB for a twelve-hour run**, and that is now the only
thing between this host and a qualified one. It is a decision about storage, not
about Druse, and it belongs to the owner — see "The one blocker" below.

Everything else this work package owes is delivered: the pre-registration with
its service SLO, an instrument defect closed with a positive control and three
mutants, an upload/stream/proxy smoke that did not exist before and is **green on
the designated host**, and the SMT question that had been open since 2026-07
answered by measurement.

**None of this is evidence about Druse.** No soak was run.

## What was accepted

Against the acceptance list in `planning/readiness/R2-restricted-production.md`
§3:

| Criterion | State | Evidence |
|---|---|---|
| the preflight refuses CPU sets that share a physical core | met | `analysis/topology-check.md`, `raw/ec2-preflight-0-3-vs-4-7.txt` |
| the mutant of that control is red for the right reason | met | `raw/check_soak_controls.out` controls 1–6, `raw/mutations.txt` M1–M2 |
| the pre-registration is committed before the first run | met — no run has occurred, and the affinity amendment was committed before the smoke | `ops/soak/campaigns/2026-08-02-r2-soak-candidate-1.md` §3.1/§3.4 |
| every SLO has a declared origin | met | `analysis/slo-origins.md`: 1 measured, 11 inherited, 18 open |
| `preflight.sh` runs on the host | met | `raw/ec2-preflight-0-3-vs-4-7.txt`, `raw/ec2-preflight-core-split.txt` |
| …and **qualifies** it | **NOT met** — 13 of 14 requirements pass; free disk does not | `raw/ec2-preflight-core-split.txt`: one `problem=` line, and it is storage |
| upload/stream/proxy smoke green on the host | met, with the override stamped | `raw/ec2-smoke.txt`: `smoke=pass`, all three legs |

`build/check_soak_controls.sh` is at 38 assertions, up from 26. The twelve new
ones are six for the topology check, three for the smoke's ordering and its
override, one for the new criterion 18, one that compiles the smoke server, and
one that recomputes the instrument hashes the pre-registration pins.

## The finding

`ops/soak/preflight.sh` tested CPU isolation with `[[ "$SERVER_CPUS" ==
"$GENERATOR_CPUS" ]]`. On the workstation this ran on — 8 logical CPUs, 4
physical cores, siblings `(0,4) (1,5) (2,6) (3,7)`, which is the AWS c5.2xlarge
Nitro layout — the shipped preflight reported **no topology problem at all** for
server `0-3` against generator `4-7`
(`raw/preflight-shipped-this-host.txt`). Those two sets are the two thread halves
of the same four cores.

The script's own header states why the sets must be disjoint: *"the load
generator would compete with the process under measurement"*. Through SMT
siblings it competes exactly so, on every core the server is pinned to. The check
that exists to prevent it was green while the property was false — the same shape
as INS-003 and INS-013, and the third time this repository has paid for that
class.

It did refuse this host, for a busy port and 40 GiB of free disk. Both are
fixable in an afternoon, after which the host would have qualified for a
twelve-hour campaign with the generator on the server's cores, and the artefact
would have recorded a properly isolated run.

## The second finding, which the first one exposed

Once the preflight could refuse a host by topology, the obvious next question was
what happens to a run that never asked it. The answer: nothing.

`manifest.txt` has recorded `preflight=pass|skipped|absent` since `soak/1`, and
`schema.md` documents the field. **`analyze-soak.py` never read it.** A run taken
with `DRUSE_SOAK_SKIP_PREFLIGHT=1` graded exactly like a run on a qualified host.

That is criterion 11's finding one level up — a field written for a rule that
never ran — and it is now `CRITERIA.md` criterion 18, enforced by the analyser
and controlled three ways (`skipped`, `absent`, and the key missing entirely).
All eight committed fixtures already carried `preflight=pass`, so the criterion
cost the reference artefacts nothing; it had simply never been asked of them.

`raw/mutations.txt` M4 records the analyser with the new check disabled: negative
control 12 goes red immediately.

## The finding, confirmed on the machine that produced the reports

`44.200.160.96` is not a fresh instance. It is the `c5.2xlarge` the 2026-07
performance campaigns ran on — same Xeon Platinum 8124M @ 3.00 GHz, same kernel
`6.17.0-1017-aws`, with the campaign directories still on its disk.

`planning/verification-campaign-plan.md` said in advance that `0-3`/`4-7` on this
shape was "almost certainly" sibling pinning and told the reader to run `lscpu -e`
before anything else. Nobody did. It was run now
(`raw/ec2-host-topology.txt`):

```text
CPU NODE SOCKET CORE        cpu0=0,4   cpu4=0,4
  0    0      0    0        cpu1=1,5   cpu5=1,5
  1    0      0    1        cpu2=2,6   cpu6=2,6
  2    0      0    2        cpu3=3,7   cpu7=3,7
  3    0      0    3
  4    0      0    0
```

Four physical cores. So the repaired preflight, run on this host with the
historical affinity, refuses it — and names the reason
(`raw/ec2-preflight-0-3-vs-4-7.txt`):

> `problem=server (0-3) and generator (4-7) are disjoint by CPU NUMBER and share
> physical core(s) [0 4;1 5;2 6;3 7]`

**Every 2026-07 campaign on this box ran with the load generator on the server's
own four physical cores.** That is measured now, not suspected. It does not make
those numbers miscomputed — the measurements did what they said — but none of
them describes the configuration it claims to report. Whether those reports need
a correction notice is their owner's decision; amending them quietly inside a
host-qualification commit is the kind of edit this programme exists to prevent,
so it is recorded and not acted on.

With the amended affinity the same host reports
`physical_core_disjoint=yes` (`raw/ec2-preflight-core-split.txt`), which is what
makes the refusal above a statement about the affinity rather than the machine.

## The one blocker

`raw/ec2-preflight-core-split.txt` ends with a single `problem=` line:

> `17 GiB free at /home/ubuntu/druse-r2; a 12h run is estimated to need 100 GiB
> of raw CSV`

The root volume is 29 GiB with 9 GiB already used by previous campaigns. The
100 GiB figure is an estimate and is recorded as one — R2-WP01 accepted it as a
risk precisely because it had never been checked against a real run — but the
arithmetic behind it is not in doubt at this order of magnitude: roughly
15.7k req/s across the six profiles at about 120 bytes a row is about 81 GB over
twelve hours. Seventeen GiB buys roughly two and a half hours at those rates.

That is enough for the smoke, the burn-in and *possibly* the two-hour rehearsal.
It is not enough for a final run, and a campaign that fills its disk at hour
three produces an invalidated artefact, not a short one.

Three ways out, and only one of them costs no criterion:

1. **Attach storage.** A 100–150 GiB gp3 volume mounted at `DRUSE_SOAK_BASE`.
   Costs a few dollars for the length of the campaign and changes nothing else in
   this file. **Recommended.**
2. **Reduce raw retention.** The per-request CSV is the dominant artefact and it
   is also the entire diagnosability story R2-WP01 was built to preserve — a
   failure that cannot be located in absolute time is a failure that cannot be
   named. Trading it for disk undoes that work package.
3. **Lower the offered rates.** Legitimate, but it is a different campaign, and
   at two lanes the rates are already due for re-derivation (§3.4). Doing both at
   once means never learning which change moved the result.

The rehearsal step corrects the 100 GiB estimate with a measurement either way;
that is what it is for. It cannot be used to justify starting a final run on a
volume that arithmetic already says is too small.

## The decision the finding forces

The campaign pre-registers a host with **`ThreadsPerCore=1`** — eight vCPUs that
are eight whole cores, e.g. a `c5.4xlarge` launched with
`CoreCount=8,ThreadsPerCore=1` — keeping `0-3` / `4-7`, four lanes, and every
rate and criterion unchanged.

The core-disjoint split of a c5.2xlarge (`0,1,4,5` / `2,3,6,7`) is pre-approved
as a fallback and is proved to qualify by control 3. It is not free: it halves
the server's physical cores from four to two, drops `DRUSE_SOAK_LANES` from 4 to
2, and costs every offered rate its inherited basis. Taking it means editing and
committing the pre-registration before the run — not setting an environment
variable at the prompt, which is the thing `preflight.sh` refuses by name.

Reasoning in `ops/soak/campaigns/2026-08-02-r2-soak-candidate-1.md` §3.2.

## What this does NOT establish

Stated plainly, because an evidence directory dated inside R2 will be read later
as if it were about the product.

- **No soak was run.** Not 12 h, not 2 h, not the burn-in, not the smoke step of
  the ladder. Nothing here measures Druse.
- **The host is still not qualified.** Thirteen of fourteen requirements pass;
  free disk does not, and "thirteen of fourteen" is not a qualification. The
  acceptance criterion is **not met**.
- **The green smoke was taken with the override on.** All three legs passed on
  the designated host — a 64 KiB body spooled and checksummed byte-for-byte, ten
  stream frames delivered incrementally, and both again through the pinned Caddy
  over TLS, with no spool leaked. But it ran with
  `DRUSE_SOAK_SMOKE_ALLOW_UNQUALIFIED=1`, because the preflight refuses the host
  on disk, and `raw/ec2-smoke.txt` carries `smoke_on_unqualified_host=yes` plus
  that reason. It proves the three paths work on this machine. It does not
  qualify it.
- **`time_to_ready_ms=8` is not a startup benchmark.** One sample, 100 ms poll
  granularity, one curl round trip, on an idle host.
- **The host was modified.** The pinned Odin toolchain and docker were installed
  during this work package; neither was present. Nothing else was changed, and no
  limit, sysctl or governor was touched — the campaign's own host preparation is
  R2-WP04's, not this file's.
- **The SLO is mostly open, and open is not a placeholder for "fine".** Fifteen
  of eighteen latency cells have no number. So do the tolerable rate of failing
  scrapes, the recovery time after saturation, and start-to-ready in the restart
  RTO. `analysis/slo-origins.md` states how each is obtained. Until they are,
  this project has no latency promise for any workload except `/health`'s
  liveness bound.
- **Nothing here says the historical reports are wrong.** It says their topology
  is unknown from their artefacts: they used `0-3` / `4-7` on a c5.2xlarge,
  `planning/verification-campaign-plan.md` asked for `lscpu -e` to confirm the
  SMT state before anything else, and no confirmation was recorded. That is why
  the pre-registration licenses no comparison with any of them. One command on
  that instance closes it.
- **`time_to_ready_ms` in the smoke report is not a startup benchmark.** It is a
  100 ms-granularity upper bound including a curl round trip, taken on an
  unqualified laptop, recorded because the restart RTO needs some honest input
  and had none.
- **Nothing here changes the R1 freeze.** The supported profile, the accepted
  risks and their expiry are exactly as `planning/readiness/R1-freeze.md` left
  them.

## Risk accepted

| Risk | Scope | Mitigation | Validity |
|---|---|---|---|
| The pre-registration freezes criteria for a host nobody has provisioned | §3.1 could turn out to be unsatisfiable, or satisfiable only at a cost the owner declines | The fallback in §3.2 is pre-approved and proved to qualify by control 3; taking it is an edit and a commit, which keeps G3 intact either way | Until a host is provisioned |
| The smoke has never run on a qualified host | Its three legs are proved on one workstation with one kernel and one filesystem | It is the first step of host qualification, before the ladder; a failure there costs minutes | Until the first qualified-host smoke |
| Pinning six instrument hashes in the pre-registration adds friction to every future soak change | A WP touching `run-soak.sh` or the analyser must update the table in the same commit or the gate is red | That friction is G1 stated as a check: a changed instrument is a changed candidate. The failure message says so and names both hashes | Permanent, by design |
| `time_to_ready_ms` may be read as a startup figure | It appears in a report next to numbers that are assertions | The note carries its own granularity and its bound in the same line | Until measured on the campaign host |

## Next

R2-WP02 closes when a host satisfying §3.1 exists, `ops/soak/preflight.sh`
qualifies it with `physical_core_disjoint=yes`, and `ops/soak/smoke.sh` reports
`smoke=pass` on it without the override — with both outputs committed. Until then
R2-WP04, WP05, WP07 and WP08 stay blocked, and the gate stays at R1.
