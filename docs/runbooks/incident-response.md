# R1 controlled-pilot incident response

The priority order is: protect the bounded failure domain, stop admission,
preserve evidence, roll back, then diagnose. The normative boundary is
`docs/supported-profile.md`; never widen it during an incident.

## First five minutes

1. Declare the abort time in UTC and identify the owner/operator.
2. Make the proxy return not-ready and stop `/pilot/*` admission. Do not kill
   the process before a normal drain unless integrity or exposure requires it.
3. Capture, without request data: active bundle hash, unit state, exit
   status/signal, restart count, cgroup memory events, Druse counters, proxy
   status summary and spool file names/sizes.
4. Execute `docs/runbooks/rollback.md` within the five-minute target.
5. Confirm health, readiness, allowed-route behavior and data integrity on the
   previous bundle. Keep the pilot closed until the cause has executable
   evidence.

## Classification and diagnosis

| Symptom | Evidence to collect | Expected action |
|---|---|---|
| bind failure | journal plus listener table | stop the old owner; never race two bundles on one port |
| memlock/preflight failure | preflight output and `/proc/self/limits` | keep closed; restore measured limits, do not bypass preflight |
| OOM | `memory.events`, `Result=oom-kill`, response/handler arm | rollback; preserve cgroup and peak evidence; remeasure before raising memory |
| crash loop | `NRestarts`, `StartLimitBurst`, core metadata | leave unit failed, rollback bundle, inspect core offline |
| blocked drain | readiness timeline and `TimeoutStopSec` result | let supervisor enforce outer bound; do not claim Handler preemption |
| saturation | **`handlers_active` / `handler_capacity` from the out-of-band snapshot**, saturation/admission counters, proxy upstream errors | rollback or reduce offered traffic only after closing admission |
| metrics absent | the sampler's `cause=` field, snapshot `age_ns`, `NRestarts` | **do not interpolate.** See §"When the metrics stop" below — the cause names the fault |
| proxy/TLS | Caddy logs, certificate fingerprint, upstream protocol | rollback binary and proxy config together |
| spool quota/orphan | quota counters and `druse-spool-*` names/sizes | close admission, clean only unowned remnants, preserve names and timestamps |

## When the metrics stop (R2-WP03 / ADR-050)

**A gap in the graphs is a finding, not a blind spot to wait out.** Read the
sampler's `cause=` field first; it is stamped on every tick, including the ticks
that read nothing.

| `cause` | What it means | First action |
|---|---|---|
| `stale` | the process is alive and **not exporting** — wedged, or the exporter thread died | check `handlers_active`; a wedged process usually shows full occupancy in its last good record |
| `no_process` | the pid in the last record is gone | correlate `NRestarts`; if it did not restart, this is the fault, not a symptom |
| `missing` | no file at the path | deployment fault — wrong path, or the process never started with `METRICS_SNAPSHOT` set |
| `unreadable` | present, read failed | permissions or the filesystem holding the snapshot |
| `malformed` | wrong schema version, or no terminator | a writer from a different build; check what is actually deployed |

**Do not read a flat throughput graph as a quiet period.** Every cumulative
counter is written on completion, so at full lane occupancy all of them freeze
(finding OBS-001). Flat counters plus `handlers_active == handler_capacity` is a
saturated server; flat counters plus `handlers_active == 0` is a quiet one. The
graphs are identical without that field.

**Attributing saturation versus a network problem.** The sampler joins the
process snapshot, `/proc`, the host's `ListenDrops`/`ListenOverflows` and the
proxy's upstream counters onto **one tick, from outside the process**:

- acceptor `saturation_refusals` rising **and** proxy upstream connect errors
  rising → **application saturation**;
- proxy upstream connect errors rising **without** acceptor refusals → the path
  between proxy and server;
- `ListenOverflows` rising with neither → the kernel queue, before the server
  saw anything.

Scraping the application over HTTP cannot produce this table, because a failed
scrape is precisely the case being attributed.

## Evidence hygiene

Record request IDs only after validation. Never preserve bodies, authorization,
cookies, complete headers, credentials, private keys or user data. Core files
remain host-restricted; the evidence bundle records their identifier and
backtrace classification, not their bytes.

## Reopening

An incident is not resolved by a successful restart. Reopening requires a named
cause, an executable negative control that reproduces it (or a declared external
cause with provider evidence), the full gate, the deployment campaign, and a new
owner decision.
