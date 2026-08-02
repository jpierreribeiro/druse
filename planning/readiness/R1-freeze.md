# R1 freeze — controlled pilot decision

**Frozen on:** 2026-08-02.
**Decision: PROMOTE TO R1 — internal, non-critical controlled pilot only.**
**Owner:** `jpierreribeiro`.

This freeze answers one narrow question: the reviewed Druse profile may receive
limited internal traffic whose loss is tolerable and whose data is synthetic or
reconstructible. It does not declare Druse generally production-ready. Critical
production, an external SLO, direct Internet exposure, another proxy, a second
platform, irreversible migration, or a larger load remain prohibited.

## Frozen deployment profile

- Linux x86-64 and the Odin commit pinned by `odin-version.txt`;
- one App, listener and process in the deployment profile, although the core
  supports at most 16 servers per process;
- Caddy at the TLS/HTTP/2 edge and HTTP/1.1 to Druse, with zero configured
  load-balancer retries;
- cooperative transport drain plus the systemd process deadline; an arbitrary synchronous Handler is not preempted by Druse;
- the canonical limits, policy, route allowlist and abort thresholds in
  `ops/deploy/runtime-limits.example` and `ops/deploy/pilot-profile.env`;
- no native TLS or HTTP/2 claim, no WebSocket claim, and no druse-crystals
  support claim in the R1 proof.

Any change to a load-bearing value, platform, proxy, supervisor policy, route
set, data class or candidate binary invalidates this decision and requires the
owning campaign to be repeated.

## Evidence index

| Work | Result | Preserved evidence or gate |
|---|---|---|
| R0/R1 entry | PASS; zero open P0 at entry | `evidence/2026-08-01-r1-entry/` |
| R1-WP01 | PASS; real signal, drain and supervisor boundary | `evidence/2026-08-01-r1-shutdown/` and `build/check_r1_shutdown_controls.sh` |
| R1-WP02 | PASS; resource budget, preflight and systemd drills | `evidence/2026-08-01-r1-resource-budget/` and `build/check_supervisor_contract.sh` |
| R1-WP03 | PASS for pinned Caddy only | `evidence/2026-08-02-r1-real-proxy/` and `build/check_proxy_config.sh` |
| R1-WP04 | PASS; normative profile and nine semantic mutants | `docs/supported-profile.md` and `build/check_supported_profile.sh` |
| R1-WP05 | PASS; policy, three runbooks, checklist and five mutants | `ops/deploy/pilot-profile.env` and `build/check_pilot_runbooks.sh` |
| R1-WP06 | PASS; deploy, low load, drain, crash/restart and rollback | `evidence/2026-08-02-r1-pilot-exercise/` and `build/check_pilot_exercise.sh` |
| R1-WP07 | PASS when the freeze evidence verifies | `evidence/2026-08-02-r1-freeze/` and `build/check_r1_freeze.sh` |

The WP01 evidence predates the repository-wide `SHA256SUMS` convention. Its
manifest and README are tracked Git objects and its full-gate log SHA is pinned
inside the manifest. WP02, WP03, WP06 and WP07 carry self-verifying
`SHA256SUMS`; the freeze gate checks each one.

## P0/P1 disposition ledger

`ACCEPTED-R1` means the limitation is accepted only inside the frozen profile,
with the stated mitigation. It is not a waiver for R2. Every acceptance expires
before R2 promotion or immediately when its scope changes.

| Finding | Disposition | Evidence or mitigation | Owner | Scope and validity |
|---|---|---|---|---|
| AUD-P0-001 | CLOSED | claimed/live registry, deterministic regression and 30/30 control in R0 | lifecycle | all profiles; guarded by WP123 controls |
| AUD-P1-002 | ACCEPTED-R1 | Handler deadlines plus `TimeoutStopSec=30s`; blocked Handler is killed by supervisor | jpierreribeiro | R1 synchronous profile only; expires before R2-WP08 |
| AUD-P1-003 | ACCEPTED-R1 | no Tier 2 claim and no soak claim; instrument repair and candidate soak remain mandatory in R2-WP01 | jpierreribeiro | R1 pilot only; expires before any production traffic |
| AUD-P1-004 | CLOSED | pinned Caddy campaign proves the delegated edge contract | operations | Caddy R1 topology only; another proxy is outside profile |
| AUD-P1-005 | CLOSED | derived 1,213 FD budget, `LimitNOFILE=2048` and fail-closed preflight | operations | frozen one-listener R1 profile |
| AUD-P1-006 | ACCEPTED-R1 | response cap is not an OOM guarantee; streaming plus `MemoryMax=1G` contain the process | jpierreribeiro | R1 response/data limits only; expires before R2 capacity approval |
| AUD-P1-007 | CLOSED | normative profile, reconciled claims and semantic mutation gate | documentation | current R1 contract; checker remains mandatory |

Therefore there is no P0 or P1 without a closed disposition or an explicit,
owned, scoped and expiring R1 mitigation. AUD-P1-003 deliberately continues to
block R2 until R2-WP01 repairs the soak instrument and measures an immutable
candidate on a qualified host.

## Exit criteria

| Criterion | Verdict |
|---|---|
| zero P0/P1 without accepted mitigation | PASS — disposition ledger above |
| full gate green on a clean candidate | PASS — WP06 candidate and WP07 freeze evidence |
| shutdown and supervisor boundary proved | PASS — WP01/WP02 |
| resource budget and fail-closed preflight | PASS — WP02 |
| real proxy contract | PASS — WP03, Caddy only |
| normative documents mutation-tested | PASS — WP04 |
| rollback executed, not described | PASS — WP06, 3 seconds |
| pilot has owner, alerts and abort policy | PASS — WP05 |

## Commands

The freeze runner executes these commands against the same clean candidate and
preserves their output:

```sh
bash build/check.sh
bash build/check_supported_profile.sh
bash build/check_supervisor_contract.sh
bash build/check_r1_shutdown_controls.sh
bash build/check_proxy_config.sh
bash build/check_pilot_runbooks.sh
bash build/check_pilot_exercise.sh
bash build/check_r1_freeze.sh
```

## What R1 still does not prove

- a current 12-hour soak or a capacity knee for this candidate;
- production traffic, durable customer data, an external SLO or incident history;
- isolation or cancellation of arbitrary blocking Handler work;
- native TLS, HTTP/2 or WebSocket support;
- another operating system, CPU architecture, proxy or Odin release;
- general support for druse-crystals or a second production transport adapter.

Those are R2/R3 questions. Widening this verdict by wording alone is a freeze
violation and must make `build/check_r1_freeze.sh` fail.
