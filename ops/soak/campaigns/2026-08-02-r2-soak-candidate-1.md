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
| `ops/soak/CRITERIA.md` | `e324025c201e307e9ea1cca6aef5c1dfa21fc80ad696ae46b764f595c08ca9e8` |
| `ops/soak/schema.md` | `e611a96f1360f01e2e3d2a9f595c4ebbd62eb5e5484a08aa61137d3764bf5640` |
| `ops/soak/run-soak.sh` | `0ef0dd841f64715aa7a13eab68c3a8e8de483fba430fa604c9469852d47be2e8` |
| `ops/soak/analyze-soak.py` | `18da528451bb46ce7d31f27033dbff7c903c6baad234899d6776c43a10feb62d` |
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

**Amended three times, every time before the run it governs** — twice on
2026-08-02 and once on 2026-08-04 (§3.7).

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

**Superseded by §3.7 on 2026-08-04** — the two rows below marked ⟶ carry the
third amendment's values. The rest of the table is unchanged and still binding.

| Field | Required value |
|---|---|
| hostname / provider | ⟶ AWS `c5.2xlarge`, `i-08c31e483e890fd16`, `us-east-1a`, Xeon Platinum 8275CL @ 3.00 GHz |
| OS / kernel | ⟶ Ubuntu 24.04.4 LTS, `6.17.0-1017-aws` |
| logical CPUs online | ≥ 8 — **measured: 8** |
| physical cores | 4 (2 threads each), siblings `(0,4) (1,5) (2,6) (3,7)` — **measured, not assumed** |
| **isolation** | **`preflight.sh` must report `physical_core_disjoint=yes`** |
| server CPU set | `0,1,4,5` — physical cores `{0,1}` |
| generator CPU set | `2,3,6,7` — physical cores `{2,3}` |
| lanes (`DRUSE_SOAK_LANES`) | ⟶ **0 — o default do produto** (§4.8). Era 2, e o R2-WP05 mediu que 2 estava abaixo do piso do próprio default e produzia as recusas que pararam o WP04 |
| **`memlock` (`RLIMIT_MEMLOCK`)** | **unlimited — see §3.5. The stock 8 MiB is a known startup crash (F-C03-2), not a tuning preference.** |
| governor / turbo | recorded, not constrained |
| NUMA nodes | recorded; a multi-node host needs this file amended before running |
| RAM | ≥ 8 GiB (the RSS safety stop is 4 GiB) |
| swap / swappiness | recorded |
| nofile hard limit | ≥ 8192 |
| cgroup | recorded |
| `nstat` present | must be `yes`; absent fails the run |
| free disk | ⟶ ≥ the estimate `preflight.sh` **derives** from the offered rate, floor 25 GiB (§3.7). At the §4.5 rates that is 25 GiB; **measured on the host of record: 91 GiB free** |
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

### 3.7 Terceira emenda ao host — 2026-08-04, antes de qualquer degrau

**O host de registro anterior foi perdido, não trocado por conveniência.**
`184.72.201.140` parou de responder a SSH. O sintoma foi medido em vez de
suposto: a porta 22 completava o handshake TCP e **zero bytes** chegavam — sem
banner, cinco tentativas, e o mesmo depois de um reboot que o log de sistema
mostra ter subido o `ssh.service` verde. O `ssh.socket` do Ubuntu 26.04 é
socket-activated, o que casa exatamente: o systemd aceita a conexão e o `sshd`
nunca é gerado.

**E o log entregou algo maior que a queda.** Aquele host voltou rodando kernel
`7.0.0-1009-aws` contra os `7.0.0-1006-aws` que esta seção pinava — um
unattended-upgrade instalou kernel novo entre a qualificação e o run. Sob G1 isso
já era ambiente diferente, e teria invalidado um final que começasse num kernel
e terminasse noutro sem que nenhum artefato registrasse a troca. O buraco de
instrumento está fechado: `preflight.sh` agora **recusa** um host que se atualiza
sozinho, nomeando os units, com override carimbado e mutante.

**O host de registro passa a ser `44.212.50.252`.**

| Campo | Anterior (pinado) | Agora | Sob G1 |
|---|---|---|---|
| instância | `i-05c3c8168b18776a5`, us-east-1b | `i-08c31e483e890fd16`, **us-east-1a** | diferente |
| tipo | `c5.2xlarge` | `c5.2xlarge` | igual |
| CPU | Xeon Platinum 8275CL @ 3,00 GHz | **8275CL — o mesmo modelo** | igual |
| topologia | 4 núcleos, irmãos `(0,4) (1,5) (2,6) (3,7)` | **idêntica, medida** | igual |
| OS | Ubuntu 26.04 | **Ubuntu 24.04.4 LTS** | diferente |
| kernel | `7.0.0-1006-aws` | **`6.17.0-1017-aws`** | diferente |
| RAM | ≥ 8 GiB | 15,25 GiB | ok |
| memlock | unlimited | unlimited (`limits.d` + `user@.service.d`) | ok |
| disco livre | ≥ 100 GiB | 91 GiB contra 25 derivados | ok, ver abaixo |
| auto-upgrade | não verificado | **`auto_upgrade_units=none`** | novo requisito |

**A affinity de registro não muda.** A topologia é a mesma medida — não assumida
do tipo de instância — então servidor `0,1,4,5`, gerador `2,3,6,7` e
`DRUSE_SOAK_LANES=2` seguem valendo, e o `preflight.sh` confirmou
`physical_core_disjoint=yes` neste host.

**Uma ironia que vale registrar em vez de esconder:** o kernel novo é
`6.17.0-1017-aws`, exatamente o do **primeiro** host, aquele que o §3.1 recusou
por disco. A campanha volta à geração de kernel de onde saiu. Isso não é um
problema — é um fato de identidade, e é por isso que ele está numa tabela em vez
de numa nota de rodapé.

#### O que esta emenda custa, dito antes do run

**Nada de medição carrega**, e desta vez isso não custa um degrau: a escada já ia
reiniciar no smoke por causa da mudança de taxa do §4.5. O smoke, o burn-in e o
rehearsal de 2026-08-03 pertencem ao candidato antigo por **duas** razões
independentes agora — taxa e ambiente — e nenhuma delas é nova despesa.

**O que se perdeu de verdade** são os artefatos brutos que só existiam naquele
disco: `~/ladder2/` e `~/rate-derivation/`. As conclusões estão preservadas neste
arquivo (§4.1, §4.2, §4.3, §4.4) com os números que as sustentam; os diretórios
de ciclo e a telemetria por segundo, não. **Nenhum pacote de burn-in ou rehearsal
tinha sido commitado em `evidence/`**, e essa é a lição operacional do episódio:
um degrau cujo artefato vive só no host é um degrau que um host leva embora.

#### O piso de disco deixou de ser constante

Os 100 GiB do `preflight.sh` vinham de uma aritmética escrita no próprio script —
*"~15,6k req/s ... ~120 bytes a row, is ~80 GiB"* — cujo **resultado** foi pinado.
As emendas §4.1 e §4.5 cortaram a taxa agregada por dez e o número não se moveu,
então ele recusou este host por um run que o §4.4 mediu em ~10,2 GiB.

Passou a ser derivado da taxa oferecida, com margem de 1,5× e piso de 25 GiB
porque o disco guarda a escada inteira e não um run. **Nas taxas históricas a
derivação pede 113 GiB, mais que a constante que substituiu** — não é limiar
afrouxado para admitir um host, e o controle no gate assere exatamente isso.

#### Qualificação deste host

| | |
|---|---|
| `preflight.sh` | **pass** — `physical_core_disjoint=yes`, `odin_can_build=yes`, `memlock=unlimited`, `auto_upgrade_units=none`, `nofile_hard=1048576`, `ntp_synchronized=yes` |
| `smoke.sh` | **pass** — upload spooled com checksum, upload buffered, stream incremental (10 frames, spread 0,451 s) através do Caddy fixado sobre TLS |
| override | **ausente** — sem `smoke_on_unqualified_host` |
| validade | 7 dias a partir de 2026-08-04 (§10) |

**Uma recusa intermediária, registrada porque o instrumento acertou.** A primeira
tentativa reprovou com `port 8080 already has a listener`: um teste de build que
o operador deixou pendurado depois que o SSH expirou. Não era o host e não era o
produto — era operador, e o preflight pegou antes de a campanha começar em vez de
depois de doze horas.

## 4. Workloads, rates and connections

Every profile that will run, and every profile that will not. A profile absent
without a pre-registered reason fails the run; a profile absent *with* one does
not. Both directions are enforced by the analyser.

> **Superseded by §4.1 on 2026-08-03.** The rates below are the ones this
> campaign started with and are kept so the derivation can be read against them.
> **The rates of record are in §4.1**, and criterion C21 checks the manifest
> against that table, not against this one. The connection counts, the expected
> statuses and the injected-fault schedule are unchanged.

| Profile | Path | Rate (superseded) | Connections | Expected status | In this campaign? |
|---|---|---:|---:|---|---|
| health | `/health` | 20/s | 16 | 200 | yes |
| tiny | `/tiny` | 10,000/s | 128 | 200 | yes |
| json encode | `/json/medium` | 1,500/s | 128 | 200 | yes |
| json decode | `/json/medium/decode` | 4,000/s | 256 | 204 | yes |
| 64 KiB | `/bytes/64k` | 150/s | 64 | 200 | yes |
| blocking | `/wait/40ms` | 15/s | 32 | 200 | yes |
| 1 MiB | `/bytes/1m` | — | — | — | **not as a rated profile.** The route is exercised — it is the target of the slow-reader injection below, 24 sockets abandoned mid-response (`run-soak.sh`) — but it carries no rate, no connection count and no expected status, so it has no SLO row in §6.2. Giving it one now would be a new profile with no history, decided during a stability campaign. Recorded in `control/short.txt` at run time. |

### 4.1 Quarta emenda — as taxas, re-derivadas por medição (2026-08-03)

**Emendada depois do burn-in e antes do próximo degrau.** §3.4 ponto 3 escreveu,
antes de qualquer run, que estas taxas perderiam sua base herdada com duas lanes
e que *"o burn-in e o rehearsal decidem se elas são sustentáveis"*. O burn-in
decidiu: não são.

#### A medição que forçou a emenda

O burn-in de 15 ciclos (`6bff82f`) reprovou por **`health transport errors`** —
o ciclo 3 teve 8 erros em `/health`, 6 `eof_on_fresh_conn` e 2 `peer_reset`. O
critério 1 exige **zero**, e continua exigindo: `/health` é liveness, e um
orquestrador que recebe recusa nele tira o processo de rotação qualquer que seja
a razão.

**O que foi medido não é a taxa em que `/health` suja; é a taxa em que o
acceptor recusa.** `vendor/odin-http/server.odin:1206` recusa um socket aceito
somente quando **toda** lane está dentro de um handler naquele instante, e
`/health` abre 16 conexões novas por ciclo num total de ~624. Se `/health` é o
workload que come a recusa é sorte; se o servidor recusa **alguma coisa** é
mecanismo. No f=0,60 abaixo o `/health` ficou limpo e o servidor ainda recusou
79 conexões — passar ali seria passar por sorte.

Escada de derivação, três ciclos por ponto, mesma affinity e mesmas lanes
(`~/rate-derivation/` no host de campanha; artefatos e vereditos preservados):

| fator | carga agregada | recusas do servidor | erros em `/health` | erros de transporte totais |
|---:|---:|---:|---:|---:|
| 1,00 | 15.685/s | **1.913** (15 ciclos) | **8** | 1.682 |
| 0,60 | 9.411/s | 79 | 0 | 49 |
| 0,40 | 6.274/s | 62 | 0 | 20 |
| 0,25 | 3.922/s | 38 | 0 | 34 |
| 0,20 | 3.137/s | 1 | 0 | 1 |
| 0,18 | 2.824/s | 2 | 0 | 2 |
| **0,15** | **2.352/s** | **0** | **0** | **0** |
| 0,10 | 1.569/s | 0 | 0 | 0 |
| 0,06 | 941/s | 0 | 0 | 0 |
| 0,03 | 471/s | 0 | 0 | 0 |

**O teto livre de recusa está em 2.352/s agregados; a primeira recusa reaparece
em 2.824/s.** O zero não é de um ponto só — quatro pontos consecutivos abaixo do
limiar deram zero, o que distingue "abaixo do limiar" de "teve sorte uma vez".

**As recusas se concentram na borda do ciclo.** A telemetria por segundo mostra
os picos nos instantes em que os seis geradores reabrem suas ~624 conexões, não
distribuídos pela carga permanente. Com capacidade de 2 handlers, uma conexão
que chega enquanto as duas lanes estão dentro de handlers é recusada, e uma
rajada de reconexão é onde isso é mais provável. É informação de capacidade que
o R2-WP05 quer, e está registrada aqui porque foi este degrau que a produziu.

#### As taxas de registro, a partir de agora

| Profile | Path | Taxa | Conexões | Status esperado |
|---|---|---:|---:|---|
| health | `/health` | **20/s — inalterada** | 16 | 200 |
| tiny | `/tiny` | **1.500/s** | 128 | 200 |
| json encode | `/json/medium` | **225/s** | 128 | 200 |
| json decode | `/json/medium/decode` | **600/s** | 256 | 204 |
| 64 KiB | `/bytes/64k` | **22/s** | 64 | 200 |
| blocking | `/wait/40ms` | **2/s** | 32 | 200 |

Agregado: **2.369/s**. As cinco cargas escalam por 0,15; **`/health` não escala**
— é uma sonda, não carga, e reduzi-la de 20/s para 3/s daria quatro vezes menos
amostras para o critério que esta emenda existe para respeitar. Os 17/s de
diferença são 0,7% do agregado.

#### O que esta emenda não resolve, dito antes do run

- **Seis minutos não provam doze horas.** Cada ponto acima é de três ciclos. Um
  final de 12 h tem ~360 rajadas de reconexão contra 3; zero em três rajadas
  limita muito pouco a probabilidade por rajada. **O burn-in (15 ciclos) e o
  rehearsal (60) são a confirmação, e não são formalidade.** Se qualquer recusa
  aparecer neles, a taxa desce de novo — nesta seção, em seu próprio commit,
  antes do final. Uma taxa baixada depois de um final vermelho invalidaria aquele
  final (G3).
- **A margem é estreita e está declarada:** 2.369/s de registro contra 2.824/s
  onde a recusa reaparece — cerca de 16%. Foi escolhida assim de propósito:
  descer mais troca cobertura de estresse real por margem que os degraus longos
  vão testar de qualquer forma.
- **Isto não é o knee.** É o teto abaixo do qual o acceptor não recusa, que é uma
  pergunta diferente de capacidade máxima. O envelope é R2-WP05.
- **A recomendação que sai daqui e não pertence a este WP:** com
  `max_handlers = lanes`, uma implantação que precise manter `/health` limpo sob
  carga tem de ficar abaixo do limiar de recusa, ou pôr liveness fora das lanes
  de aplicação — que é exatamente o argumento que a ADR-050 já fez para métrica.
  Registrado como entrada do R2-WP05, não decidido aqui.

#### C21 — a taxa do run é a taxa desta seção

Critério novo, congelado antes do próximo run, no mesmo espírito do C18:

> as taxas em `manifest.txt` (`health_rate`, `tiny_rate`, `json_encode_rate`,
> `json_decode_rate`, `bytes_64k_rate`, `wait_40ms_rate`) têm de ser exatamente
> as da **tabela de registro vigente**.

**A tabela vigente é a da emenda mais recente.** Quando o C21 foi escrito havia
só uma, e "a tabela acima" era exata; a quinta emenda (§4.5) tornou a frase
ambígua, e um critério ambíguo é um critério que não recusa nada. Hoje: **§4.5 é
a vigente** (f = 0,10) e a tabela desta seção fica registrada como o que o smoke,
o burn-in e o rehearsal de 2026-08-03 realmente ofereceram. Um run é lido contra
a emenda vigente na data em que começou.

Razão de existir: a affinity tem um preflight que **recusa** e o critério C18; as
taxas não tinham nem um nem outro, e um run que ajustasse a taxa no prompt
produziria um artefato que discorda do seu plano sem que nada percebesse. O
`run-soak.sh` **não** é modificado — os seus defaults continuam sendo os
históricos, as taxas de campanha são parâmetros do runner e ficam gravadas no
manifesto, e é a comparação manifesto↔§4 que fecha o laço. Mudar os defaults
mudaria o hash do instrumento em §2.1 por uma escolha que é de campanha, não de
instrumento.

---

**As taxas originais abaixo ficam registradas como o que foram.** Elas vêm de
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
| host qualification | — | `preflight.sh` green, `smoke.sh` green | no | **PASS** 2026-08-03, `184.72.201.140` |
| smoke | 10 min | wiring, schema, clocks, hashes | no | **PASS** 2026-08-03 at the fourth attempt (`9905509`); three red runs, all instrument. `evidence/2026-08-03-r2-soak-smoke/`. **Re-run PASS** at the §4.1 rates (`6b4f3d4`) |
| burn-in | 30 min | every workload and fault class appears | no | **FAIL** at the original rates (`6bff82f`) — `health transport errors`, which produced §4.1. **PASS** at the §4.1 rates (`6b4f3d4`), health 0 errors in 36,000 — but see §4.2 |
| rehearsal | 2 h | fast drift, evidence volume, first latency distributions | no | **PASS** 2026-08-03 — health 0 errors in 144,000, RSS slope 30.7 KiB/h, and 345 refusals which fire §4.2's rule (see §4.3) |
| final | ≥12 h | R2 stability criterion + §6 SLO | yes, if PASS | **settled: run at f = 0.10**, registered in §4.5. The rate change is a new candidate, so smoke, burn-in **and rehearsal** re-run at f = 0.10 first (§4.5) — ~2 h 40, not 40 min. Two finals, different days (§9) |

### 4.2 The burn-in passed and the rule of §4.1 fired anyway

**Recorded before the rehearsal finished, so it cannot be read as a reaction to
its result.**

The burn-in at the §4.1 rates is a PASS by every criterion: `/health` took 36,000
requests with **zero** transport errors, the only two errors in the whole run
were `eof_on_fresh_conn` on `tiny`, RSS tail slope was 737 KiB/h against a
1 MiB/h ceiling, and kernel `listen_drops`/`listen_overflows` stayed at zero.

**And the server still refused 3 connections.**

§4.1 wrote the rule before this run: *"Se qualquer recusa aparecer neles, a taxa
desce de novo — nesta seção, em seu próprio commit, antes do final."* Three is
any. The rule fired.

It fired for the reason §4.1 gave in advance, which is the part worth keeping:
**three cycles measured zero and fifteen cycles measured three.** Six minutes did
not predict thirty. A twelve-hour final is ~360 cycles, and if refusals scale
with cycles at all, the arithmetic is not comforting:

| | |
|---|---|
| refusals per cycle, measured at 15 cycles | 0.2 |
| projected over a 360-cycle final | ~72 |
| `/health`'s share of connection attempts | 16 of 624 ≈ 2.6% |
| expected `/health` refusals in one final | **~1.8** |

Criterion 1 allows zero. **On this projection a twelve-hour final at the current
rate is more likely to fail than to pass**, and it would fail for the mechanism
this campaign already understands rather than for anything new.

**So the burn-in's green is not permission to run the final.** It says the rate is
no longer catastrophic; it does not say it is under the threshold. What settles
it is the rehearsal — 60 cycles, four times the burn-in's evidence — and the
decision waits for that number rather than for this projection, because a
projection from one point is exactly what §4.1 warned against.

**The decision, stated in advance so the rehearsal cannot be read selectively:**

- rehearsal refusals **= 0** → the rate stands and the final may run;
- rehearsal refusals **> 0** → the rate comes down again, in this section, in its
  own commit, before the final. The next step down is f = 0.10 (1,569/s
  aggregate, health still 20/s), which the derivation measured clean and which
  has two further clean points below it.

Either way this is the ladder working. A rate that passes a 30-minute step and
fails a 12-hour one is precisely what the intermediate steps exist to find
*before* twelve hours are spent, and finding it here costs two hours instead of
invalidating a final under G3.

### 4.3 The rehearsal answered, and it contradicted the reason the rule existed

**Rehearsal: PASS**, 60 cycles, every criterion green.

| | |
|---|---:|
| `/health` transport errors | **0** in 144,000 requests |
| `/health` p99, median / max cycle | 10.6 ms / 13.0 ms |
| total transport errors, all workloads | 26 |
| RSS tail slope | **30.7 KiB/h** against a 1 MiB/h ceiling |
| **server-counted refusals** | **345** |

345 is not zero, so §4.2's rule fires and **the finals run at f = 0.10**.

**But the reasoning behind that rule turned out to be wrong, and saying so is the
point of writing it down in advance.** §4.1 argued that whether `/health` eats a
refusal is *luck* — that its 16 fresh connections per cycle are exposed in
proportion to the 624 total. Under that assumption 345 refusals should have cost
`/health` about **8.8** of them. It cost **zero**, across 960 fresh connections.

Zero against 8.8 expected is not luck; it is a mechanism nobody had named.
`run-soak.sh` launches the workloads with a one-second stagger and **`/health`
goes first**, so it reconnects while the lanes are still draining the previous
cycle rather than while the other five are saturating them. That protection is
systematic — and it is also why the original burn-in *did* hurt `/health` at
15,685 req/s: there, the previous cycle's work was still occupying both lanes
when `/health`'s turn came.

**The conclusion survives the correction even though the argument does not.**
Zero events in 960 trials bounds the per-connection refusal probability at about
0.31% (rule of three, 95%), and a twelve-hour final is ~5,760 fresh `/health`
connections — six times the exposure. **The observed zero does not exclude a
failure at that scale.** So the pre-registered rule is followed, and it is
followed because the margin argument still holds, not because the luck argument
did.

**Following a rule written in advance needs no justification; overriding one
does.** That asymmetry is the whole reason §4.2 was committed before this run.

### 4.4 The two open estimates of §5, now measured

§5 said the rehearsal is where R2-WP01's two accepted risks get corrected.

| Estimate | Was | Measured |
|---|---|---|
| disk for a 12 h run (`preflight.sh` demands ≥ 100 GiB) | a guess | **1.7 GiB for 2 h** → ~10.2 GiB for 12 h. The 100 GiB floor is ~10× the need; it is left as-is because it costs nothing on this host and refusing a nearly-full disk is the safer error, but it is no longer *unmeasured* |
| evidence volume | unknown | 60 cycle directories, 7,761 telemetry samples, 1.7 GiB per 2 h |

**The rate change of §4.1 is a new candidate and the ladder restarts at smoke.**
G1 counts load-bearing configuration as part of a candidate's identity, and the
offered load is load-bearing by construction. Restarting costs ten minutes and
keeps the rule intact; carrying the old smoke forward would mean citing a green
step taken at rates the campaign no longer uses.

The rehearsal is also where the two open estimates from R2-WP01's accepted risks
are corrected: the 100 GiB disk figure in `preflight.sh` and the 2%
`expected_samples` tolerance in `analyze-soak.py`.

### 4.5 Quinta emenda — as taxas dos finais (f = 0,10)

**Commitada antes de qualquer final, que é o que a regra do §4.1 exige** ("a taxa
desce de novo — nesta seção, em seu próprio commit, antes do final"). O gatilho
já disparou e está registrado no §4.3: o rehearsal contou **345 recusas do
servidor**, e a regra não distingue 345 de 3. Nenhum resultado novo foi visto
entre aquela linha e esta.

#### As taxas de registro dos finais

Escala f = 0,10 sobre os defaults do `run-soak.sh`, com `/health` **não
escalado** pela mesma razão do §4.1 — é sonda, não carga, e reduzi-la tira
amostras do critério 1, que é o critério que a descida existe para proteger.

| Profile | Path | Taxa | Conexões | Status esperado |
|---|---|---:|---:|---|
| health | `/health` | **20/s — inalterada** | 16 | 200 |
| tiny | `/tiny` | **1.000/s** | 128 | 200 |
| json encode | `/json/medium` | **150/s** | 128 | 200 |
| json decode | `/json/medium/decode` | **400/s** | 256 | 204 |
| 64 KiB | `/bytes/64k` | **15/s** | 64 | 200 |
| blocking | `/wait/40ms` | **1/s** | 32 | 200 |

Agregado: **1.586/s**.

**A regra de arredondamento, dita porque uma linha depende dela.** Truncamento
para zero, que é o que a quarta emenda já fez (22,5 → 22 e 2,25 → 2). Quatro das
cinco cargas escalam exato; `/wait/40ms` cai em 1,5 e vira **1**. Isso oferece o
bloqueante a 0,067× do default em vez de 0,10× — uma diferença de 0,5 req/s, ou
**0,03% do agregado**. Preferi a regra consistente a uma exceção que faria a
tabela discordar do fator que a nomeia; o desvio está aqui para ser contestado.

**Por que 1.586/s e não os 1.569/s da escada de derivação:** aquele ponto escalou
`/health` junto (20 → 2). Manter a sonda em 20/s soma 17/s, +1,1%. É a mesma
aritmética que o §4.1 declarou para o f = 0,15 (lá, +0,7%).

**A margem, declarada antes do run:** 1.586/s contra 2.352/s onde as recusas
ainda eram zero e 2.824/s onde a primeira reaparece — **33% abaixo do teto livre
de recusa e 44% abaixo da primeira recusa**. No f = 0,15 essa margem era 16%, e
16% não sobreviveu a 60 ciclos. A derivação mediu zero em f = 0,10 e em dois
pontos abaixo dele.

#### A escada reinicia — e isso inclui o rehearsal

G1 conta configuração load-bearing como identidade do candidato, então esta
tabela cria um **candidato novo** e a escada recomeça no smoke, exatamente como o
§4.4 registrou para a emenda anterior.

**O rehearsal de 2 h faz parte do reinício, e vale dizer por quê**, porque a
tentação de pular é real e custa 2 h:

| degrau | ciclos | recusas medidas no f = 0,15 |
|---|---:|---:|
| burn-in | 15 | 3 |
| rehearsal | 60 | 345 |

Quinze ciclos disseram "3" e sessenta disseram "345". **Um burn-in verde no
f = 0,10 não é evidência de que 360 ciclos ficam limpos** — é o mesmo erro que o
§4.2 nomeou quando seis minutos não previram trinta. O rehearsal é o único
degrau com ciclos suficientes para limitar a probabilidade por ciclo antes de
gastar doze horas.

Custo do reinício: smoke 10 min + burn-in 30 min + rehearsal 2 h ≈ **2 h 40**,
não os ~40 min que o mapa de estado dizia. A correção está feita lá também.

#### C22 — a descida tem um piso, e o piso é uma decisão

Critério novo, congelado agora porque congelá-lo depois de ver um degrau
vermelho seria a violação exata que o G3 proíbe:

> se qualquer degrau pré-final no f = 0,10 contar **recusa do servidor > 0**, a
> taxa desce uma vez mais, para **f = 0,06** (941/s de carga escalada, `/health`
> ainda em 20/s), nesta seção e em commit próprio. **Se o rehearsal do f = 0,06
> também contar recusa, o R2-WP04 para** e o resultado é um achado de capacidade
> sobre `max_handlers = lanes`, entregue ao R2-WP05 para atribuição — não uma
> quarta descida.

Razão de existir: sem piso, a regra do §4.1 é uma busca por uma taxa em que nada
acontece, e uma taxa suficientemente baixa sempre existe. O que ela produziria
não é uma alegação de estabilidade sob um envelope de produção; é a descoberta de
que o envelope é pequeno — que é informação, e pertence ao WP05, dita como
achado em vez de escondida atrás de um verde. Cada descida custa 2 h 40 e compra
uma alegação de estresse mais fraca.

O dono pode sobrepor este piso; sobrepor uma regra escrita antes exige
justificativa registrada, seguir uma não exige nada (§4.3).

### 4.6 Sexta emenda — o C22 conta a recusa errada, e a medição que mostrou isso

**Escrita depois do smoke do f = 0,10 no host novo e antes do burn-in.** Ela
resolve uma ambiguidade minha, e resolve no sentido que **permite a escada
continuar** — que é exatamente a razão de estar escrita aqui em vez de aplicada
em silêncio.

#### O que o smoke mediu

`result=PASS`, 5 ciclos, 951.600 requisições, `/health` com **zero** erros de
transporte. E o servidor contou **56 recusas de saturação**, que pelo texto do
C22 ("recusa do servidor > 0") derrubariam a taxa para f = 0,06.

A telemetria por segundo diz onde elas aconteceram:

| | |
|---|---|
| amostras com `saturation_refusals = 0` | **522** |
| amostras com `= 56` | 153 |
| saltos distintos na série | **um só** |
| instante do salto | `2026-08-04T04:01:58.81Z` |
| `control/injected.txt` declara | `cycle=5 kind=rst attempted=128 utc=2026-08-04T04:01:58Z`<br>`cycle=5 kind=slow_readers attempted=24 utc=2026-08-04T04:01:58Z` |

**O mesmo segundo.** As 56 recusas não estão distribuídas pelas rajadas de
reconexão dos cinco ciclos — são um degrau único no instante em que 24 leitores
lentos foram injetados contra duas lanes. **A carga oferecida a f = 0,10 produziu
zero recusas neste host**, em 522 segundos de regime.

#### Por que isto não é interpretar o resultado a meu favor

Porque a regra que decide já existia e é mais velha que este run.
`CRITERIA.md` 14 e o §4 deste arquivo: **falhas injetadas são contadas à parte
das espontâneas e nunca abatidas umas das outras.** O C22 apenas não citou essa
regra, e por isso pôde ser lido como somando as duas.

E há uma razão estrutural, que é a mais forte: **a escada de derivação do §4.1
tem três ciclos por ponto.** Com três ciclos não existe quinto ciclo, e as
injeções rodam no quinto. Então **nenhum dos dez pontos daquela tabela mediu uma
recusa injetada** — cada número ali é carga pura. Comparar um run que inclui um
ciclo de injeção contra aqueles limiares é comparar coisas diferentes, e era isso
que o C22 mandava fazer.

#### O texto do C22, corrigido

> se qualquer degrau pré-final no f = 0,10 contar recusa do servidor
> **atribuível à carga oferecida** — isto é, fora das janelas em que
> `control/injected.txt` declara uma injeção ativa — a taxa desce uma vez mais,
> para f = 0,06. Recusas concorrentes com uma injeção declarada são contadas e
> **relatadas**, nunca abatidas, e não movem a taxa: baixar a carga de fundo não
> remove 24 leitores lentos estacionados em duas lanes, então descer por causa
> delas seria seguir a letra da regra errando o mecanismo, e descer para sempre
> sem nunca remover a causa.

O piso de f = 0,06 e a condição de parada do C22 seguem valendo, inalterados,
para recusas de carga.

#### A dúvida retrospectiva, registrada porque é séria

**O §4.2 e o §4.3 podem ter disparado sobre falhas injetadas.** O burn-in tinha
15 ciclos (3 de injeção) e contou 3 recusas; o rehearsal tinha 60 (12 de injeção)
e contou 345 — cerca de 29 por ciclo de injeção, a mesma ordem das 56 medidas
aqui num ciclo. Se aquelas recusas eram majoritariamente injetadas, a descida de
f = 0,15 para f = 0,10 respondeu a um sinal que não era sobre a taxa.

**Não dá para verificar:** os artefatos daqueles runs viviam em `~/ladder2/`, no
host perdido (§3.7). É a segunda vez neste episódio que evidência não commitada
custa uma resposta.

**O que faço com a dúvida: nada, deliberadamente.** A taxa registrada continua
f = 0,10. Reverter para f = 0,15 seria desfazer uma decisão congelada com base na
re-análise de dados que não existem mais, e sob G1 este host precisa da própria
derivação de qualquer forma. Rodar mais devagar que o necessário **enfraquece** a
alegação de estresse, não a fortalece — é o erro seguro. A re-derivação neste
host é entrada do R2-WP05, registrada aqui e não feita agora.

#### C23 — a atribuição é obrigatória, não opcional

> um degrau que relate `saturation_refusals > 0` tem de dizer **quantas** caem
> dentro de janela de injeção declarada e quantas não. Um total sem essa divisão
> não satisfaz o C22 em direção nenhuma — nem para descer nem para continuar.

Existe porque a divisão é o que distingue as duas leituras, e um run que não a
produza deixaria a próxima pessoa exatamente onde eu estava: com um número e duas
histórias.

### 4.7 Sétima emenda — o C22 disparou contra mim, e a taxa desce para f = 0,06

**Escrita depois do burn-in do f = 0,10 e antes do próximo degrau**, que é onde a
regra manda. O C22 foi congelado nesta manhã e emendado no §4.6 poucas horas
antes deste run; agora ele reprova o run e o custo é meu.

#### A medição

O burn-in deu `result=PASS` pelo analisador — 15 ciclos, `/health` com **zero**
erros de transporte, p99 mediano 1.546 µs, todas as seis falhas classificadas. E
a atribuição do C23 encontrou o seguinte:

| | |
|---|---|
| `saturation_refusals` total | **105** |
| dentro de janela de injeção declarada | 104 |
| **atribuíveis à carga oferecida** | **1** |

**A recusa de carga não é artefato de borda de janela, e isso foi verificado
antes de aceitar o custo.** Ela caiu às `04:24:56.449`, com o run começando às
`04:18:22` — 394 s de decorrido, portanto **ciclo 4**. A injeção mais próxima é a
do ciclo 5, às `04:27:04`, **128 segundos depois**. Nenhum alargamento defensável
da janela a alcança.

As outras três subidas (12, 50 e 42) caem nos ciclos 5, 10 e 15 — os de injeção —
dentro de um segundo das declarações. O padrão é limpo.

#### Por que uma recusa não é pedantismo

É a aritmética do §4.2, refeita com o número deste host:

| | |
|---|---|
| recusas de carga medidas em 15 ciclos | 1 |
| por ciclo | 0,067 |
| projetado num final de ~360 ciclos | **~24** |
| fração de conexões novas que é `/health` | 16 de 624 ≈ 2,6% |
| recusas esperadas em `/health` num final | **~0,6** |

O critério 1 permite **zero**. Meio evento esperado não é um final que se aposta,
e a projeção vem de um ponto só — que é exatamente contra o que o §4.1 avisou.
Mas a regra não pede projeção: ela pede zero recusa de carga nos degraus
pré-finais, e houve uma.

#### A descida, e um problema aritmético que ela expõe

f = 0,06 sobre os defaults, `/health` inalterado pela razão de sempre:

| Profile | Path | Taxa | Conexões | Status esperado |
|---|---|---:|---:|---|
| health | `/health` | **20/s — inalterada** | 16 | 200 |
| tiny | `/tiny` | **600/s** | 128 | 200 |
| json encode | `/json/medium` | **90/s** | 128 | 200 |
| json decode | `/json/medium/decode` | **240/s** | 256 | 204 |
| 64 KiB | `/bytes/64k` | **9/s** | 64 | 200 |
| blocking | `/wait/40ms` | **1/s** | 32 | 200 |

Agregado: **960/s**.

**A regra de truncamento do §4.5 quebra aqui, e a correção precisa ser dita.**
`/wait/40ms` a 0,06 dá 0,9, que truncado é **zero** — e o `run-soak.sh` **pula**
uma carga com taxa ≤ 0, gravando `skipped=... reason=rate_zero`. Truncar
obedientemente removeria a carga bloqueante da campanha, que é justamente a que
exercita o dwell de handler, e o §4 deste arquivo existe para dizer *"toda
carga que vai rodar, e toda que não vai"* — não para deixar uma sumir por
arredondamento.

Então: **piso de 1/s para qualquer carga que o fator zeraria.** O bloqueante
roda a 0,067× do default em vez de 0,06× — a mesma forma de desvio que o §4.5 já
declarou, por 0,1% do agregado. Declarado aqui em vez de descoberto no manifesto.

#### O que isto NÃO significa

- **Não é uma alegação de capacidade.** É a taxa abaixo da qual o acceptor deste
  host não recusa sob carga, que é pergunta diferente de teto. O envelope é o
  R2-WP05.
- **Não é o Druse piorando.** É a terceira taxa de registro em três hosts, e o
  §4.6 já registrou a suspeita de que a primeira descida respondeu a um sinal
  errado. O que este número diz é que **o limiar de recusa é propriedade do
  framework NUM AMBIENTE**, não do framework sozinho — e essa é a entrada mais
  útil que esta escada produziu para o WP05.
- **Não é o piso.** O C22 permite esta descida e mais nenhuma.

#### A escada reinicia, e o C22 agora tem a última palavra

G1: taxa nova é candidato novo, então smoke → burn-in → rehearsal outra vez,
~2h40. E a condição de parada do C22 vale como escrita, lida com o §4.6:

> **se o rehearsal do f = 0,06 contar recusa atribuível à carga, o R2-WP04
> para**, e o resultado é um achado de capacidade sobre `max_handlers = lanes`
> entregue ao R2-WP05 — não uma quarta descida.

### 4.8 Oitava emenda — as lanes voltam ao default do produto, e a taxa sobe com elas

**Antes de qualquer degrau do candidato novo**, que é onde emenda de campanha se
escreve.

#### O que o R2-WP05 mediu, e por que ele reprova esta campanha

Três experimentos, dezessete braços, dois critérios de refutação disparando
(`evidence/2026-08-05-r2-wp05-knee/`):

| | |
|---|---|
| não há knee até **10.000 req/s** — oito pontos, todos ≥ 99,99% | H4 refutada |
| sobreassinar lanes **não custa** nos três pontos de stress | H5 refutada |
| e **melhora**: 8 lanes dão p99 menor (−5,7%, −6,0%, −16,7%) e **zero** recusa | não estava previsto |

**E o achado que reprova a §3.4 desta campanha:** o default do produto é
`max_handlers = 0` → `CPU count clamped to 4..32`, ou seja **nunca abaixo de 4
lanes**. Esta campanha fixou **2**, com o raciocínio da §3.4:

> *"Two physical cores cannot host four Handler lanes plus a load generator
> without reintroducing the competition this amendment exists to remove."*

**Esse raciocínio está medido como errado.** Nos mesmos dois núcleos físicos, 4 e
8 lanes entregam cauda menor e zero recusa. **Uma lane bloqueada não consome
CPU** — ela segura um slot de concorrência, e a competição temida custa menos que
o bloqueio de cabeça de fila que a escolha criou.

**Consequência direta: o R2-WP04 parou por recusas que o default do produto não
teria produzido.** Ele mediu uma configuração que nenhuma implantação usaria.

#### A mudança

**`DRUSE_SOAK_LANES = 0`.** A campanha deixa de escolher e passa a medir o que o
produto escolhe.

Não é "subir para 8": é **parar de sobrepor o default**. O valor resolvido fica
gravado no artefato — o snapshot da ADR-050 carrega `handler_capacity`, que é o
número que o adapter escolheu — então o run registra a decisão do produto em vez
de a minha.

**A affinity não muda.** Servidor `0,1,4,5`, gerador `2,3,6,7`. O isolamento por
núcleo físico da §3.2 continua certo e continua valendo; era a contagem de lanes
que não estava.

#### E a taxa volta para f = 0,15

As duas descidas — §4.5 (f = 0,10) e §4.7 (f = 0,06) — responderam a recusas
**causadas pela configuração que esta emenda corrige**. Mantê-las seria carregar
para a frente uma compensação cujo motivo deixou de existir.

| Profile | Path | Taxa | Conexões | Status esperado |
|---|---|---:|---:|---|
| health | `/health` | **20/s — inalterada** | 16 | 200 |
| tiny | `/tiny` | **1.500/s** | 128 | 200 |
| json encode | `/json/medium` | **225/s** | 128 | 200 |
| json decode | `/json/medium/decode` | **600/s** | 256 | 204 |
| 64 KiB | `/bytes/64k` | **22/s** | 64 | 200 |
| blocking | `/wait/40ms` | **2/s** | 32 | 200 |

Agregado: **2.369/s** — a tabela do §4.1, restaurada.

> #### Correção da própria emenda, antes do run: **a taxa é 1.118/s, e quem a
> escolheu foi o disco**
>
> **O preflight recusou o host** com a tabela acima, e estava certo. Ao consertar
> o piso de disco para ser derivado — ele era uma constante de 25 GiB ao lado de
> uma estimativa que eu já tinha derivado ontem, defeito meu deixado pela metade
> — a conta real apareceu:
>
> **A escada inteira são 96.000 s de run:** smoke (10 min) + burn-in (30 min) +
> rehearsal (2 h) + dois finais de 12 h, todos preservados lado a lado, porque
> run vermelho é evidência e não se apaga.
>
> | taxa | escada inteira, com margem 1,5× | cabe em 19 GiB? |
> |---|---:|---|
> | 2.369/s (f = 0,15) | **38,1 GiB** | não |
> | 1.586/s (f = 0,10) | 25,5 GiB | não |
> | **1.118/s** | **18,0 GiB** | **sim** |
>
> **A constante de 25 GiB estava errada nas duas direções:** a 960/s a escada
> pede 15 e ela recusava hosts que cabiam; a 2.369/s pede 38 e ela teria admitido
> um host que fica sem disco no meio do segundo final. Uma constante não
> consegue ser conservadora para uma quantidade que anda 4×.
>
> **A taxa de registro passa a ser 1.118/s**, e a razão está dita: **é o disco do
> host que a escolhe, não o produto nem a campanha**. O R2-WP05 mediu 10.000
> req/s entregues a 99,99%; a 10.000/s a escada precisaria de 161 GiB. Apresentar
> 1.118/s como um limite do Druse seria mentir por omissão.
>
> **O que destravaria f = 0,15:** um volume de 60 GB no host de campanha. É ação
> do dono, custa centavos, e está nomeada aqui em vez de sofrida em silêncio.
>
> | Profile | Path | Taxa | Conexões |
> |---|---|---:|---:|
> | health | `/health` | **20/s — inalterada** | 16 |
> | tiny | `/tiny` | **702/s** | 128 |
> | json encode | `/json/medium` | **105/s** | 128 |
> | json decode | `/json/medium/decode` | **280/s** | 256 |
> | 64 KiB | `/bytes/64k` | **10/s** | 64 |
> | blocking | `/wait/40ms` | **1/s** | 32 |
>
> Agregado: **1.118/s**.

**Os dois finais rodam em sequência**, e o artefato do primeiro é puxado e
verificado antes do segundo — mas o piso derivado já **não** conta com isso: ele
exige espaço para a escada inteira lado a lado, que é a suposição segura.

#### O que esta emenda cria, e o que ela não desfaz

**Candidato novo sob G1** — lanes e taxa são configuração load-bearing. A escada
reinicia no smoke: smoke, burn-in, rehearsal, e só então os finais.

**O C22 e o C23 continuam valendo como escritos.** Se a recusa de carga
reaparecer no default, a regra desce a taxa como sempre — e aí o **B3** (tirar a
sonda de liveness das lanes de aplicação) volta a ser o caminho, com evidência
melhor que a de hoje. Está escrito antes do run de propósito.

**O que esta emenda NÃO desfaz:** nada do R2-WP04 vira inválido. Ele mediu o que
mediu, na configuração que tinha, e o veredito dele continua correto para aquela
configuração. O que mudou é que agora se sabe que aquela configuração não era a
do produto.

## 6. Criteria and SLO

The eighteen criteria in `ops/soak/CRITERIA.md` apply as written and are pinned
by hash (§2.1). Anything **additional** for this campaign is numbered here,
before the run.

| # | Criterion | Threshold | Rationale |
|---|---|---|---|
| C18 | the run's affinity equals §3 | `manifest.txt` `server_cpus`/`generator_cpus` match this file exactly | a run that adapted its affinity is a run whose plan and artefact disagree |
| C19 | the host was qualified by core, not by number | the attached preflight report carries `physical_core_disjoint=yes` | the property §3.2 exists to guarantee, asserted in the artefact rather than assumed |
| C20 | the smoke was green on this host, unqualified-override absent | `smoke=pass` and no `smoke_on_unqualified_host` line | a green smoke taken with the override is a fact about the script |
| C21 | the run's rates equal the current amendment | the six `*_rate` fields in `manifest.txt` match the registered table in force when the run started (§4.5 today, §4.1 before it) | defined in full in §4.1; a run that adjusted its rate at the prompt disagrees with its own plan and nothing notices |
| C24 | the campaign does not override the product default for `max_handlers` | `manifest.txt` records `lanes=0` and the snapshot's `handler_capacity` records what the adapter resolved | defined in full in §4.8; a campaign that picks a value the product would never pick measures a configuration nobody runs |
| C22 | the descent has a floor | any pre-final step counting server refusals **attributable to offered load** at f = 0.10 drops the rate to f = 0.06 once; a load refusal in the f = 0.06 rehearsal stops R2-WP04 for attribution | defined in §4.5, amended in §4.6 — the rate-derivation ladder never measured an injected-fault cycle, so counting injected refusals against its thresholds compares different things |
| C23 | a refusal total is attributed, not just counted | a step reporting `saturation_refusals > 0` states how many fall inside a declared injection window and how many do not | defined in full in §4.6; the split is what separates the two readings of C22, and a total without it leaves the next person with one number and two stories |

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
| verdict | **os finais NÃO rodaram** — a escada parou no rehearsal por regra C22 |
| analyser output | todos os cinco degraus deram `PASS`; ver `evidence/2026-08-04-r2-wp04-ladder/steps/*/raw/verdict.json` |
| reasons | o rehearsal a f = 0,06 contou **7 recusas atribuíveis à carga** (461 totais, 454 injetadas). O §4.7 já tinha gasto a única descida permitida |
| decision | **HOLD AT R1** |

### O encerramento, e por que ele não é uma reprovação do produto

**Todo degrau passou em todos os critérios pré-registrados**, o rehearsal
inclusive: `/health` com zero erros de transporte em 60 ciclos, p99 mediano
1.196 µs, e inclinação de RSS de **49,0 KiB/h avaliada** contra 1 MiB/h — a
primeira vez que o run foi longo o bastante para `rss_slope_evaluated=true`.

O que encerrou foi o **C22**, que é uma regra sobre qual taxa pode ser
certificada para um final. A conta:

| | |
|---|---|
| recusas de carga a f = 0,06 | 8 em 80 ciclos = **0,100/ciclo** |
| projetado num final de ~360 ciclos | ~36 |
| `/health` como fração das conexões novas | 16 de 624 = 2,56% |
| esperadas em `/health` num final | **~0,9** |
| critério 1 permite | **0** |

Um final de doze horas nesta taxa tem cerca de uma recusa esperada exatamente no
workload que não pode ter nenhuma.

**E descer a taxa não move o piso:** f = 0,10 deu 1 recusa de carga em 20 ciclos
(0,050/ciclo), f = 0,06 deu 8 em 80 (0,100/ciclo). Os intervalos se sobrepõem
largamente — não dá para dizer que piorou — mas **não há evidência nenhuma de que
baixar 40% da carga tenha ajudado**, e é essa a alegação que a descida precisava
sustentar.

Todas as recusas medidas caem em **rajada de reconexão**, não em carga
permanente. A hipótese entregue ao **R2-WP05**: com `max_handlers = lanes = 2` a
variável é a rajada de ~624 conexões por ciclo, não a taxa de requisições — e se
for, nenhuma taxa converge. A resposta seria mais lanes, ou uma admissão que não
recuse a sonda de liveness.

O veredito completo, com proveniência, está em
`evidence/2026-08-04-r2-wp04-ladder/verdict.md`.
