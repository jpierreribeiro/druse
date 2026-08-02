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
| saturation | lane dwell, saturation/admission counters, proxy upstream errors | rollback or reduce offered traffic only after closing admission |
| proxy/TLS | Caddy logs, certificate fingerprint, upstream protocol | rollback binary and proxy config together |
| spool quota/orphan | quota counters and `druse-spool-*` names/sizes | close admission, clean only unowned remnants, preserve names and timestamps |

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
