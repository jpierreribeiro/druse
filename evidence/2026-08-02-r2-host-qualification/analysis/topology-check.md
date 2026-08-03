# The topology check — what was wrong, what it does now, and how it is proved

## 1. The defect

`ops/soak/preflight.sh` tested CPU-set isolation with one line:

```bash
if [[ "$SERVER_CPUS" == "$GENERATOR_CPUS" ]]; then
  problem "server and generator share the CPU set $SERVER_CPUS: the load
           generator would compete with the process under measurement"
fi
```

A **string comparison**. Two families of host passed it while the property it
names was false.

**(a) The same set, spelled twice.** `0-3` and `0,1,2,3` are four identical CPUs
and two different strings.

**(b) The one that matters — SMT siblings.** `0-3` against `4-7` is disjoint by
number. On a host with two threads per core it can be — and on an AWS c5.2xlarge
it is — the two thread halves of the *same four physical cores*. The Nitro
layout pairs them `(0,4) (1,5) (2,6) (3,7)`.

The reason the sets must be disjoint is written in the script's own header:
*"the load generator would compete with the process under measurement"*. Through
SMT siblings it competes exactly so, on every core the server is pinned to, and
the check reported nothing.

This is the shape of INS-003 and INS-013: a control that stays green while the
property it protects is false. Under R2 rule G2 that is an instrument failure,
and an instrument failure fails the campaign rather than the product.

## 2. Measured, not argued

The workstation this ran on is 8 logical CPUs over 4 physical cores with
siblings `(0,4) (1,5) (2,6) (3,7)` — the c5.2xlarge layout
(`raw/host-topology.txt`, `environment.txt`).

| Preflight | Affinity | Topology verdict |
|---|---|---|
| as shipped (`origin/main`) | `0-3` / `4-7` | **no topology problem reported** (`raw/preflight-shipped-this-host.txt`) |
| repaired | `0-3` / `4-7` | refused: *"disjoint by CPU NUMBER and share physical core(s) [0 4;1 5;2 6;3 7]"* (`raw/preflight-fixed-0-3-vs-4-7.txt`) |
| repaired | `0,1,4,5` / `2,3,6,7` | `physical_core_disjoint=yes` (`raw/preflight-fixed-core-split.txt`) |
| repaired | `0-3` / `0,1,2,3` | refused: *"share logical CPU(s) 0,1,2,3"* (`raw/preflight-same-set-two-spellings.txt`) |
| repaired | topology unreadable | refused: *"cannot be verified"* (`raw/preflight-topology-unreadable.txt`) |

The shipped preflight did refuse this host — for a busy port and a small disk.
Neither is the topology, and both are fixable in an afternoon, after which the
same host would have qualified for a twelve-hour campaign with the load generator
on the server's cores.

## 3. What the check does now

Each CPU in each set is expanded to a number, then mapped to its physical core
through `/sys/devices/system/cpu/cpu<N>/topology/thread_siblings_list`. The
sorted sibling list *is* the core's identity: two CPUs are on one core exactly
when they list each other, and no second file is needed to disambiguate a
multi-socket host the way `core_id` would.

Three outcomes, all recorded in the report as facts rather than as the absence of
a complaint:

- `physical_core_disjoint=yes` — with `server_physical_cores` and
  `generator_physical_cores` written out, so "disjoint" is checkable rather than
  asserted;
- `physical_core_disjoint=no` — refused, naming the shared cores;
- `physical_core_disjoint=unknown` — refused. A topology that cannot be read is
  a property that cannot be verified, and INS-013 is the standing finding that an
  absent measurement must never be rendered as a clean result.

## 4. The controls (G2)

Six, in `build/check_soak_controls.sh`, driven by synthetic sibling maps through
`DRUSE_SOAK_TOPOLOGY_DIR` so the result does not depend on the core count of
whatever machine runs the gate. The override is stamped into the preflight's own
report, so a real campaign cannot use it unnoticed.

| # | Case | Fixture siblings | Affinity | Required |
|---|---|---|---|---|
| 1 | **positive** | `(0,1) (2,3) (4,5) (6,7)` | `0-3` / `4-7` | `physical_core_disjoint=yes`, mapping recorded, no refusal |
| 2 | **mutant** | `(0,4) (1,5) (2,6) (3,7)` | `0-3` / `4-7` | refused, *by the physical-core reason* |
| 3 | positive | `(0,4) (1,5) (2,6) (3,7)` | `0,1,4,5` / `2,3,6,7` | qualified |
| 4 | mutant | any | `0-3` / `0,1,2,3` | refused, logical overlap |
| 5 | mutant | absent | `0-3` / `4-7` | refused, `unknown` |
| 6 | **control of the control** | — | — | deleting the refusal from `preflight.sh` makes case 2 red |

Case 1 is what the shipped control never had. An instrument that only ever says
*refused* is indistinguishable from an instrument that is broken, and cases 2, 4
and 5 would all be satisfied by a preflight that failed everything.

Case 2 asserts the **reason**, not the refusal. This host is refused for a busy
port and a small disk as well, so a bare `preflight=fail` would pass with the
topology check absent entirely.

Case 6 is why any of this is believable. `raw/mutations.txt` records all three
mutations run against the working tree:

- **M1** — the physical-core refusal deleted → case 2 goes red with *"refused the
  SMT host for some OTHER reason"*, and case 1 stays green, so the two are
  independent;
- **M2** — the comparison reverted to the shipped string equality → case 1 goes
  red with *"did not confirm physical-core disjointness"*;
- **M3** — `analyze-soak.py` edited so its hash no longer matches the
  pre-registration → the G1 identity control goes red, printing both hashes.

## 5. What this analysis does not claim

**Superseded in part, on the same day.** This section previously said the
topology of the instance behind `docs/reports/` was unknown from the artefacts.
The instance was then designated as the campaign host, `lscpu -e` was run on it,
and the answer is in `raw/ec2-host-topology.txt`: four physical cores, siblings
`(0,4) (1,5) (2,6) (3,7)`, on the same Xeon 8124M and kernel `6.17.0-1017-aws`
those reports name.

So the claim is no longer "unknown". Those campaigns pinned the server to `0-3`
and the generator to `4-7` on a machine where that is one set of four cores
twice, and the load generator was on the server's own cores.

What this analysis still does **not** claim is that any of those numbers is
miscomputed. Each measurement did what it said. What none of them describes is
the configuration it reports itself as having — and that is why §8 of the
pre-registration licenses no comparison with any of them, now for a measured
reason rather than an absent one. Whether those reports carry a correction notice
is a decision for their owner and is deliberately not taken here.
