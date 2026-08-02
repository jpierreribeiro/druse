# Arm comparison — analysis

Derived entirely from `raw/arm-baseline.txt`, `raw/arm-arm-a.txt` and
`raw/arm-arm-b.txt`. Every number below appears verbatim in one of those files;
this page groups them and says what they mean, and it replaces neither.

Candidate: commit `27fd085`, tree `641570c71e7c9c5152a64318f0bc30334dbfefcc`,
clean working tree. Program binary sha256 in `raw/arms-binary-sha256.txt`.
Host in `../environment.txt` — and disqualified for any soak.

## Precondition

All three runs printed `occupied true entered=4` before sampling. The barrier
counted every lane inside a handler; nothing below was measured against a server
that merely happened to be busy.

A run that fails this prints `verdict VOID` and exits 3. Void, not red — it
measured nothing, and the pre-registration says so in advance rather than
letting a weak run be argued into a result afterwards.

## Per-arm outcome

| | `baseline` | `arm-a` | `arm-b` |
|---|---|---|---|
| samples | 120 | 120 | 120 |
| `ok` | **0** | 120 | 120 |
| `http_recv_error` | **120** | 0 | 0 |
| `http_refused` / `http_timeout` / `http_empty` | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| `missing` / `unreadable` / `malformed` / `stale` | 0 | 0 | 0 |
| `unclassified` | **0** | **0** | **0** |
| `network_ambiguous_absences` | **120** | 0 | 0 |
| availability | 0 ppm | 1 000 000 ppm | 1 000 000 ppm |
| p50 latency | — | 378 986 ns | 42 552 ns |
| p99 latency | — | 540 312 ns | 86 773 ns |
| max latency | — | 1 820 693 ns | 88 936 ns |
| `target_saturation_refusals` | **120** | 0 | 0 |
| `target_handler_dwell_ns` | 0 | 0 | 0 |
| `target_responses_sent` | 0 | 0 | 0 |
| `export_ticks` | — | — | 14 |

`unclassified 0` in every arm is criterion B2: counted = classified. No sample
left the run without a cause.

## Reading the baseline

**0 of 120, and all 120 as `http_recv_error`.** The server reset the connection
rather than closing it gracefully, which is what a transport-level saturation
refusal looks like from the client: the socket is accepted and then closed
before any HTTP request has been parsed, so there is nothing to read.

`target_saturation_refusals` = 120 is the server's own side of the same 120
events, read from inside the process while it was still running. The two numbers
agreeing is what makes the mechanism identified rather than guessed.

**And `http_recv_error` is exactly the point of the finding.** A reset is
producible by a saturated server, by a middlebox, by a proxy tearing down a pool,
and by a network. The sampler classified it correctly and still cannot say which
of those happened. That is AUD-P2-009 stated as a measurement.

## Reading arm A

120 of 120, p99 0.54 ms. The second `App` has its own acceptor, its own two
lanes and its own admission budget, and none of them were contended by the four
saturated lanes next door.

It works. It is also still HTTP, so its failure modes — when they come — are the
same four ambiguous ones. On this run there were none to observe, which is
precisely why the decision could not be made on availability: **an arm that did
not fail cannot demonstrate what its failures would mean.** That is a structural
argument (ADR-050, B4), and structural is the only kind available here.

## Reading arm B

120 of 120, p99 0.087 ms, 14 export ticks over the window. The read is a local
file read; there is no socket, no accept queue and no lane.

The latency advantage is ~8× and is not the reason B was chosen. At a scrape
cadence of seconds, 0.087 ms and 0.54 ms are the same number.

## OBS-001, visible in all three columns

`target_handler_dwell_ns` = **0** and `target_responses_sent` = **0** in every
arm, read while the server was running, with four lanes provably inside
handlers for the whole window.

Both counters advance on **completion** — `responses_sent` when a send finishes,
`handler_dwell_ns` after the dispatch returns. Under total occupancy nothing
completes, so neither moves.

An operator watching the documented utilization formula
`Δhandler_dwell_ns / (lanes × Δwall)` would read **0** across this entire
window. The true value is **1**.

This is why `handlers_active` and `handler_capacity` exist after this work
package: they are the only fields that separate this window from an idle one.

### A correction inside this campaign

The first version of the arm program read `web.stats` **after** `web.stop`,
where the documented contract returns the zero value for an App that is no
longer running a server. It printed `target_saturation_refusals 0` for the
baseline run — a plausible, confident, wrong number, for a window in which the
acceptor had refused all 120 scrapes.

The read now happens before the teardown, with the reason written at the call
site. The number that changed is 0 → 120, and both the defect and the fix are
the same class this whole work package is about: a metric that reports something
other than what its name says, while every value stays individually plausible.

## What this analysis does not claim

- Nothing about throughput, capacity or stability. The latencies describe a
  4-CPU shared container (G4).
- Nothing about more than one process.
- Nothing about arm A's failure behaviour under conditions it did not meet here.
  The claim against A is structural — which classes of absence it can produce —
  and is argued in ADR-050, not measured here.
