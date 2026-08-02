# R2-WP02 verdict — the pre-registration, and a host that does not exist

**Decision: R2-WP02 remains OPEN. R2 remains blocked; the gate stays at R1.**

Three of the four pieces this work package owes are delivered and committed: the
campaign pre-registration with its service SLO, an instrument defect closed with
a positive control and two mutants, and an upload/stream/proxy smoke that did not
exist before. The fourth — a qualified dedicated host — does not exist, so no
host was qualified and none of this is evidence about Druse.

## What was accepted

Against the acceptance list in `planning/readiness/R2-restricted-production.md`
§3:

| Criterion | State | Evidence |
|---|---|---|
| the preflight refuses CPU sets that share a physical core | met | `analysis/topology-check.md`, `raw/preflight-fixed-0-3-vs-4-7.txt` |
| the mutant of that control is red for the right reason | met | `raw/check_soak_controls.out` controls 1–6, `raw/mutations.txt` M1–M2 |
| the pre-registration is committed before the first run | met — no run has occurred | `ops/soak/campaigns/2026-08-02-r2-soak-candidate-1.md`, `config/pre-registration.md` |
| every SLO has a declared origin | met | `analysis/slo-origins.md`: 1 measured, 11 inherited, 18 open |
| `preflight.sh` runs on the host and qualifies it | **NOT met** | no dedicated host exists; see below |
| upload/stream/proxy smoke green on the host | **partially met** | green on an unqualified workstation, stamped as such: `raw/smoke-this-host.txt` |

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
- **No host was qualified.** This is the central gap. `preflight.sh` was run only
  on a workstation it refuses, and the acceptance criterion "the preflight runs
  on the host and qualifies it" is **not met** because there is no host. Every
  host row in §3.1 of the pre-registration is a requirement, not an observation.
- **The green smoke is a fact about the script, not about a host.** All three
  legs passed — a 64 KiB body spooled and checksummed byte-for-byte, ten stream
  frames delivered incrementally, and both again through the pinned Caddy over
  TLS. It ran with `DRUSE_SOAK_SMOKE_ALLOW_UNQUALIFIED=1`, and
  `raw/smoke-this-host.txt` carries `smoke_on_unqualified_host=yes` plus the
  preflight's three refusals, precisely so this paragraph cannot be forgotten.
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
