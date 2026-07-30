# Soak criteria

The criteria this instrument judges a run by. They live here, in git, for a
reason given at the bottom of this file.

## The run

One server process, pinned to CPUs 0-3, with the load generators on CPUs 4-7,
driving six profiles at once for the configured number of hours:

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
8. **`/stats` answers 200** on every sample.
9. Safety stop: RSS above 4 GiB ends the run and fails it.

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
