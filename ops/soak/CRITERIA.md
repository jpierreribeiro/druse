# Soak criteria

The criteria this instrument judges a run by. They live here, in git, for a
reason given at the bottom of this file — and since R2-WP01 a run also PINS
THIS FILE'S SHA256 in its manifest, so the reason at the bottom is now enforced
rather than merely written down. An edit to this file after a run makes that
run's grade FAIL, naming the mismatch.

The artefact these criteria are read from is defined in
[`schema.md`](schema.md), version `soak/1`.

## The run

One server process, pinned to CPUs 0-3, with the load generators on CPUs 4-7,
driving six profiles at once for the configured number of hours.

**Those must be eight PHYSICAL cores, not eight logical CPUs.** On an SMT host
`0-3` and `4-7` are routinely the two thread halves of the same four cores — an
AWS c5.2xlarge pairs them `(0,4) (1,5) (2,6) (3,7)` — and then the generator
runs on the server's own cores, which is the single condition the split exists to
prevent. `ops/soak/preflight.sh` maps every CPU through
`thread_siblings_list` and refuses the host when the two sets share a core; a run
whose preflight report does not carry `physical_core_disjoint=yes` describes a
server that was competing with its own load generator (R2-WP02).

| Profile | Rate | Connections | Expected status |
|---|---:|---:|---|
| `/health` | 20/s | 16 | 200 |
| `/tiny` | 10,000/s | 128 | 200 |
| `/json/medium` (encode) | 1,500/s | 128 | 200 |
| `/json/medium/decode` (POST) | 4,000/s | 256 | 204 |
| `/bytes/64k` | 150/s | 64 | 200 |
| `/wait/40ms` (blocking handler) | 15/s | 32 | 200 |

Every fifth cycle also injects faults on purpose: 128 connections reset after
write (`rst-after-write`), and 24 slow readers abandoned mid-response. Those are
recorded in their own files so the analyser can tell a fault we caused from a
fault the framework produced.

## What makes a run green

1. **Health**: zero transport errors, and p99 under 250 ms in every cycle.
2. **Other profiles**: transport error ratio at most 0.01%, and no HTTP status
   outside the expected one.
3. **Every failure is explained.** Each failure carries a class from the
   generator's closed taxonomy and its verbatim error text. A failure that
   arrives `unclassified`, or a failure counted with no class at all, is a RED
   run **regardless of the rate**. See *Accounting, not tolerance*.
4. **The process survives**: no death, no `SIGKILL`, exit status zero.
5. **Threads constant** for the whole run.
6. **File descriptors** back within baseline + 4 after the settling window.
7. **RSS tail slope** at most 1 MiB/h over the second half of the run.
8. **`/stats` answers 200 on every sample**, and a sample that does not carries
   the reason it did not — curl's exit code alongside the HTTP code. This was
   measured and never enforced: a 12-hour run recorded 111 failures of 8,611,
   passed, and the number sat in the artefact with no cause and no consequence.
9. Safety stop: RSS above 4 GiB ends the run and fails it.

## What R2-WP01 added

The nine above are unchanged. These are additional, and every one of them
describes an artefact that used to grade PASS:

10. **The run finished.** `COMPLETE` is present. A run killed at hour two used
    to grade exactly like a run that finished twelve.
11. **The instrument survived.** `telemetry/process.csv` holds at least 98% of
    the manifest's `expected_samples`. A sampler that died in minute three does
    not merely lose data — criterion 7 only applies at 720 samples, so a short
    file DISABLED it silently and the run went green with the rule never
    evaluated.
12. **The arithmetic closes.** Per workload:
    `completed <= planned`, `completed == sum(status)`, and
    `completed == succeeded + transport_errors`. A workload that reported 640
    of 1,000 requests and accounted for 600 outcomes used to pass. A shortfall
    is permitted only with a reason in `control/short.txt`.
13. **The kernel did not eat the load.** `listen_drops` and `listen_overflows`
    are differenced against sample 0, taken before the first cycle, and must not
    move. These counters were recorded from 2026-07-30 and read by nothing: a
    run in which the kernel discarded every connection at the listen queue
    graded identically to one in which it discarded none.
14. **Injected faults are declared and never netted off.** Each deliberate
    campaign appears in `control/injected.txt` and in its own report, the two
    agree, and the totals are reported beside the spontaneous failures rather
    than added to or subtracted from them.
15. **The candidate is one candidate.** The tree was clean, this file's hash and
    `schema.md`'s hash are pinned in the manifest and still match, and the
    binaries that finished the run hash to what the manifest recorded.
16. **A scrape that answered carries a body.** `curl -o` truncates its output
    before it knows whether it can fill it, so a failed scrape leaves a
    zero-byte file indistinguishable from an empty success. `stats_bytes` says
    which.
17. **An unreadable artefact is a verdict, not a crash.** The analyser prints a
    verdict for every input, including the artefact of a run that died before
    writing anything. `soak/0` raised `FileNotFoundError` on precisely the
    artefact a bad night produces, so the run with the most to say produced no
    grade at all.

## What R2-WP02 added

18. **The host was qualified.** `manifest.txt` records `preflight=pass`. The
    field has existed since `soak/1` and was read by NOTHING, so a run taken
    with `DRUSE_SOAK_SKIP_PREFLIGHT=1` graded exactly like a run on a qualified
    host — the same shape as criterion 11's finding, one level up. It matters
    more since R2-WP02, because the preflight is now also what refuses a host
    whose server and generator CPU sets are SMT siblings of the same physical
    cores; a run that skipped it establishes neither that the host could run the
    campaign nor that the generator stayed off the server's cores.

## Accounting, not tolerance

Criterion 3 is the one this instrument exists for.

A rate ceiling — "at most 0.01% transport error" — is satisfied by 674
unexplained failures exactly as well as by zero. That is not a hypothetical: a
12-hour run on 2026-07-29 recorded 674 transport errors across 390 million
calls, passed every criterion of the day, and could not say what a single one of
them was. The generator had stored a boolean and discarded the error; the server
under test installed neither a logger nor an observer; the per-request log the
generator could already write was never requested.

So the ceiling stays, and this is added on top of it: **a cause that cannot be
named is a failing run.** It is a stronger criterion than the one it joins, and
it is affordable precisely because the volume is tiny — 674 in 390 million.

`build/check_soak_controls.sh` proves the instrument satisfies its own rule: a
deliberately caused failure must arrive classified, with its text, locatable in
absolute time; a generator mutated to classify nothing must be caught; and the
analyser must refuse an artefact shaped like the old one.

Since R2-WP01 it also grades the eight committed fixtures in `ops/soak/fixtures/`
against their exact expected reasons, and runs ten negative controls — one per
mechanism the audit found missing. The positive fixture is not decoration: an
analyser that returned FAIL unconditionally would satisfy every negative control
in the file, and this repository has already paid once for a run that went red
for the wrong reason with no control able to tell the difference.

## The criteria have a history

They were not always these. A 10-second smoke at roughly double this load
returned RED on 2026-07-29, and two things changed after it:

- the offered rate was about halved — `/tiny` 20,000 to 10,000/s, JSON encode
  3,000 to 1,500/s, 64 KiB 300 to 150/s, the blocking handler 20 to 15/s;
- the transport-error rule went from **zero errors on any route** to **at most
  0.01% outside health**.

The relaxation is defensible: this instrument injects resets and slow readers by
design, so demanding zero transport errors contradicted the instrument rather
than measuring the framework. It also did not launder the red result, which
still fails under today's rule. But it was load-bearing — under the original
rule the 12-hour run would have failed — and it happened in a harness that was
not in version control, so proving the change required running today's analyser
over yesterday's data and comparing message strings.

**That is why this file is in git.** A criterion with no history is a criterion
that can be moved to fit a result, and nobody will be able to tell afterwards.
