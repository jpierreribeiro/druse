# What the soak's transport failures were — 2026-07-30

## Verdict

The 12-hour release soak recorded **1,085 client-side transport failures across
624,890,400 calls** (1.74 per million) and could not name one of them. They are
the framework's **acceptor saturation refusals**, observed from the client, where
a refusal is indistinguishable from a failure because it closes the connection
before any HTTP request is parsed.

This is documented, deliberate behaviour — `web/observability.odin` states that
`saturation_refusals` "is a TCP refusal before any HTTP request has been parsed,
so it must never be described as a 503 response", and `docs/operations.md` §6
repeats it with the reason. **No framework defect is implicated.** The defect was
in the measuring instrument, which counted a documented refusal as an
unexplained error and could not tell the two apart.

## Method

Three arms, each run twice in alternating order (A B C C B A), 15 minutes each,
on AWS `c5.2xlarge` with the server pinned to CPUs 0-3 and the generators to
4-7 — the soak's own topology. Predictions were written down before the run in
[`ops/soak/experiments/2026-07-30-saturation-attribution.md`](../../ops/soak/experiments/2026-07-30-saturation-attribution.md),
including the conditions under which the experiment would settle nothing.

| Arm | Change from the soak's configuration |
|---|---|
| A | none — 4 handler lanes, all six profiles |
| B | `max_handlers` 4 → 16 |
| C | the 40 ms blocking handler removed (`rate 0`) |

**The pre-registered rule: H1 survives only if failures and refusals fall
together in both B and C.**

## Result

| Arm | Planned | Failures | Per million | `saturation_refusals` | `ListenOverflows` | `ListenDrops` |
|---|---:|---:|---:|---:|---:|---:|
| A-1 | 14,116,500 | 44 | 3.117 | 120 | 0 | 0 |
| A-2 | 14,116,500 | 70 | 4.959 | 157 | 0 | 0 |
| **B-1** | 14,116,500 | **0** | **0.000** | **0** | 0 | 0 |
| **B-2** | 14,116,500 | **0** | **0.000** | **0** | 0 | 0 |
| C-1 | 14,103,000 | 10 | 0.709 | 26 | 0 | 0 |
| C-2 | 14,103,000 | 5 | 0.355 | 8 | 0 | 0 |

Both fell together, in both arms:

- **B, sixteen lanes: failures and refusals are exactly zero, in both repeats.**
- **C, no blocking handler:** failures fell 7.6× (4.04 → 0.53 per million) and
  refusals fell 8.1× (138.5 → 17). They track each other.

All three falsification conditions came back negative. Arm A produced failures,
so there was something to attribute. **No failure arrived unclassified**, so the
taxonomy covered what happened. And `ListenOverflows` and `ListenDrops` were
**zero in all six arms** — the kernel dropped nothing, so every refusal was the
server's own.

## The mechanism, not merely the correlation

The dominant failure class is **`eof_on_fresh_conn`** — 38 of 44 in A-1, 50 of
70 in A-2. That is the client opening a *new* connection and the server closing
it with no response, which is the literal signature of an accept-then-refuse: the
socket is accepted, the lanes are found busy, and it is closed before a request
line is read. `peer_reset` and `request_write_failed` are the same event caught
at a different instant of the client's state machine.

The connection-reuse counter rules out the obvious alternative. These are fresh
connections, not connections that had been idle long enough to race an
idle-timeout sweep.

## What C refines

Arm C removed the blocking handler and refusals dropped by 8× but **not to
zero**, while arm B raised the lane count and they vanished entirely. So the
refusals are a function of total lane occupancy, not of the blocking handler
alone: the other five profiles also hold lanes, and at four lanes their
coincidence is occasionally enough. The blocking handler is the largest single
contributor, not the only one.

## Also measured, and worth an operator's attention

The soak's own telemetry recorded **111 samples of 8,611 where `/stats` answered
nothing at all**, spread evenly across the twelve hours. `/stats` is an ordinary
route on the same server, competing for the same four lanes, so a scrape
arriving when every lane is busy is refused exactly like any other request.

**The endpoint an operator reads under pressure is subject to the same refusal
as the traffic that created the pressure.** At one request per second it lost
1.3% of its samples. A monitoring system that alerts on scrape failure will
alert during saturation; one that silently interpolates will under-report it.

## What this does not say

It does not say the refusals are harmless — a refused client sees a closed
connection and must retry, and at four lanes under this load that happened
roughly four times per million requests. It says the refusals are *the
documented behaviour working*, and that no unexplained failure remains in the
soak.

It also does not measure capacity. Every arm ran at the soak's offered rate,
which is a small fraction of what this box sustains; the experiment varied lanes
and workload shape, not load.

## Method notes

The arms ran on `f2963a3`, the revision `v0.10.0` tags, rather than on the
soak's `9b46a46`. The reason and the argument that the two are the same program
for this question are recorded in the pre-registration itself, written at
launch rather than afterwards.

The instrument that produced these numbers is the one rebuilt for this
investigation (`ops/soak/`, `planning/diagnosability.md`). The instrument that
ran the soak could not have produced this table: it discarded every error value
it observed, recorded no absolute timestamps, and never wrote the per-request
log it was capable of writing.
