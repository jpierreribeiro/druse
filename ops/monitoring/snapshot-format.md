# `druse_snapshot 1` — the metric snapshot format

**Status:** reference format, versioned, **not public API.** It lives in `ops/`
because it belongs to the deployment, not to the library. `web.Server_Stats` is
the contract; this file is one way to get it out of a process. A new format is a
new version number, not a breaking change.

Decided in ADR-050, from the measurement in
`evidence/2026-08-02-r2-observability-arms/`.

## Why a file and not an endpoint

`/stats` as a route runs on the same Handler lanes as the load. Under full lane
occupancy the measurement recorded **0 of 120** scrapes answered, and every one
of those absences was `http_*` — a class producible both by an application that
stopped answering and by a network that dropped the exchange. That ambiguity is
AUD-P2-009. An admin listener on a second port fixes the availability (120/120)
and **does not fix the ambiguity**, because it is still HTTP.

There is no network between this file and its reader. The causes that remain all
name the application.

## Writing it

A thread that owns no Handler lane calls `web.stats(&app)` — which allocates
nothing, takes no lock and reads atomics, so it is safe from any thread — and
writes the record to `PATH.tmp`, then `rename`s it onto `PATH`.

**`rename` is the whole durability story.** It is atomic within a filesystem, so
a reader sees either the previous complete record or the new complete one, never
half of either. Writing in place would let a reader observe a truncated record
and, worse, a *plausible* truncated record.

Put `PATH` on `tmpfs`. A metric that generates disk I/O has become a workload.

## Reading it

```
druse_snapshot 1          <- schema line, must be first
pid 4242
unix_ns 1785000000000000000
draining 0
refused_connections 0
saturation_refusals 0
responses_sent 10231
response_bytes 41889271
send_errors 0
write_deadline_aborts 0
handler_dwell_ns 918273645
stream_refused_full 0
stream_refused_budget 0
stream_aborted_slow 0
active_connections 37
handlers_active 4
handler_capacity 4
connection_capacity 4032
end                       <- terminator, must be last
```

Order is fixed. Keys are stable. Every value is an integer, which is what keeps
the record inside the redaction policy's permitted set: no request-derived byte
can reach a scraper through it, because there is nowhere for one to go.

**`end` is not decoration.** It is what lets a reader *prove* it has a whole
record instead of assuming it, which is what makes `malformed` a distinguishable
outcome rather than a silent short read.

## Counters, levels, ceilings

Three kinds of number, and mixing them up is a defect rather than a rounding
error.

| Kind | Fields | How to read it |
|---|---|---|
| running totals | `refused_connections` … `stream_aborted_slow` | **difference** consecutive samples |
| levels | `active_connections`, `handlers_active` | take **as they are** |
| ceilings | `handler_capacity`, `connection_capacity` | take as they are; `connection_capacity` 0 means unbounded |

Differencing `active_connections` yields the net change in occupancy — a number
that looks like a rate and is not one.

### The counters freeze at exactly the wrong moment

Every running total is written when work **completes**. At full lane occupancy
nothing completes, so all of them stop moving, and
`Δhandler_dwell_ns / (lanes × Δwall)` reads **zero** while utilization is
**one**. A saturated server and an idle server draw the same flat lines
(`evidence/2026-08-02-r2-observability-arms/`, finding OBS-001).

`handlers_active / handler_capacity` is the signal that tells them apart. Alert
on that, not on a flat counter.

## Absence has a cause, always

| Cause | Meaning | What it says |
|---|---|---|
| `ok` | fresh record | — |
| `missing` | no file at `PATH` | wrong path, or the process never started |
| `unreadable` | file present, read failed | permissions, or the filesystem |
| `malformed` | no schema line, wrong version, or no `end` | a writer from a different build, or a partial write |
| `stale` | record older than `max_age` | **the process is not exporting** — it is wedged, or the exporter thread died |

Four export periods is the reference `max_age`: one missed tick is jitter, four
is a stopped exporter.

**Never interpolate across an absent sample.** An interpolated point is a claim
the process made about itself while it was silent. Alert on the gap.

## More than one process

Each worker writes `PATH.d/<pid>` and the sidecar reads the directory, summing
counters and levels and taking the ceilings per worker.

**Publish `workers_seen` against a `workers_expected` that comes from the
supervisor, never from counting files.** A dead worker stops writing; its record
goes `stale`; the aggregate must then be marked incomplete rather than silently
summing fewer. An aggregate is exactly as honest as `workers_expected`, and a
wrong one produces a number that looks global and is not — the defect
ADR-049/R3-WP10 exists to avoid.

**Nothing in this repository has run more than one worker.** This section states
what the format admits, not what has been measured.
