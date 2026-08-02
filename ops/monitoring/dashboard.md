# Reference dashboard

Five rows, in the order an operator actually asks the questions. Notation is
deliberately tool-neutral: the panels are described by what they plot and what
they must never do, because the "must never do" is where AUD-P2-009 was hiding.

Source of every series: `ops/monitoring/sample-metrics.sh`, format in
`ops/monitoring/snapshot-format.md`.

---

## Row 0 — Is the instrument working?

**This row goes first, above the service's own health, on purpose.** A dashboard
that shows the service green because the sampler is silent is the failure mode
this work package exists to remove.

| Panel | Plot | Rule |
|---|---|---|
| Sample causes | stacked count per tick, one series per `cause` | `ok` is a colour like any other. Do not hide the non-`ok` series behind a toggle. |
| Snapshot age | `age_ns`, with the `max_age` threshold drawn | A rising sawtooth is normal (one export period); a ramp that does not reset is a stopped exporter. |
| Sampler liveness | ticks per minute | Constant by construction. Any dip is the sampler, not the server. |

**Connect nulls: OFF. Interpolation: OFF. Fill: none.**
A gap must render as a gap. An interpolated point is a claim the process made
about itself while it was silent.

---

## Row 1 — Is it saturated, and is that different from quiet?

| Panel | Plot | Rule |
|---|---|---|
| Lane occupancy | `handlers_active / handler_capacity`, 0–1, band at 0.8 | **The saturation panel.** Not derived from any counter. |
| Lane occupancy, absolute | `handlers_active` and `handler_capacity` as two lines | The ceiling moves when `max_handlers = 0` lands on a host with a different core count. Plot it, do not assume it. |
| Connection occupancy | `active_connections / connection_capacity` when capacity > 0 | Draw nothing when capacity is 0 (unbounded), rather than dividing by zero into infinity. |
| Refusals | rates of `refused_connections` and `saturation_refusals`, separate series | Two different resources. Never sum them: one is the admission budget, the other is the acceptor with every lane busy. |

**Do not put throughput on this row.** At full occupancy every completion
counter freezes (finding OBS-001), so a throughput panel here reads *low* during
the incident it is supposed to describe. Throughput belongs on row 2, where it
is honest about being a completion rate.

---

## Row 2 — What is it delivering?

| Panel | Plot | Rule |
|---|---|---|
| Responses | `rate(responses_sent)` | A completion rate. Reads near zero both when idle and when fully saturated; row 1 disambiguates. |
| Bytes | `rate(response_bytes)` | |
| Mean handler dwell | `Δhandler_dwell_ns / Δresponses_sent` | Undefined when `Δresponses_sent` is 0 — render as a gap, not as 0. |
| Send failures | `rate(send_errors)`, `rate(write_deadline_aborts)` | Write-deadline aborts are resets, by design (ADR-039). |
| Stream refusals | the three `stream_*` counters | |

---

## Row 3 — What does the process and the host say?

| Panel | Plot | Rule |
|---|---|---|
| FDs | `fds` against `LimitNOFILE` | |
| Memory | `rss_kb`, `hwm_kb` against `MemoryMax` | HWM never falls; a HWM step that never comes back is the leak shape. |
| Threads | `threads` | Should be flat: lanes are created at `serve` and not after. |
| Restarts | `restarts` (`NRestarts`) | **Annotate every other panel with this.** A restart zeroes every counter, and a counter that went back to zero looks exactly like a quiet period. |
| Kernel refusals | `listen_drops`, `listen_overflows`, `retrans_segs` | Render `-1` as "unavailable", never as 0. |

---

## Row 4 — Is it the application or the path to it?

The row that answers the question AUD-P2-009 says nobody could answer.

| Panel | Plot | Rule |
|---|---|---|
| Attribution | `saturation_refusals` rate and `proxy_connect_errors` rate, same axis | Both rising: **application saturation**. Only the proxy rising: **the path between proxy and server**. Only the acceptor rising: the proxy is absorbing it. |
| Proxy upstream | `proxy_active`, `proxy_retries` | |
| Readiness | `draining` as a state strip | Drain and restart on one timeline is what makes a deploy legible afterwards. |

The attribution panel works because both numbers arrive on **one sampler tick,
from outside the server process**. Scraping the application over HTTP could not
produce it: a failed scrape is exactly the case being attributed.

---

## What this dashboard cannot show

- **Idle versus busy connections.** `active_connections` is admitted-and-not-yet-closed.
  The backend tracks a per-connection `Idle` state but assigns it through both a
  chokepoint and three direct writes, so a counter at the chokepoint would
  undercount connections closing straight out of idle. Splitting it correctly is
  a vendor change across all four sites and was not made for this work package.
  Recorded as a residual in `planning/readiness/R2-restricted-production.md` §4.
- **Per-route anything.** Route is low-cardinality and available to an
  application's own observer; the framework's snapshot carries no route, by
  design — no request-derived byte reaches a scraper through it.
- **More than one process.** The format admits aggregation
  (`ops/monitoring/snapshot-format.md`); nothing in this repository has run it.
