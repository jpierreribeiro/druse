# R1 controlled-pilot deployment

This runbook deploys only the profile in `docs/supported-profile.md`. The
machine-readable policy is `ops/deploy/pilot-profile.env`; do not raise a value
in the field without changing that file, re-running its checker and recording a
new campaign.

## Authorization boundary

- Owner/on-call: `jpierreribeiro`; the operator executing the checklist is
  incident commander for the window.
- Window: at most 60 minutes, attended from start through rollback expiry.
- Traffic: at most 10 requests/s sustained and 20 concurrent clients, including
  at most two response streams and one active upload.
- Routes: `/health`, `/ready` and `/pilot/*` only. The proxy must reject every
  other application path during R1.
- Data: synthetic or reconstructible, non-critical, no secrets, credentials,
  regulated data or irreversible migration.
- Topology: one App/listener process, canonical systemd unit/runtime profile and
  pinned Caddy configuration. No direct client-to-Druse traffic.

## Required dashboards and alerts

The operator must see these before admission opens:

| Layer | Dashboard signal | Abort/alert |
|---|---|---|
| proxy | request rate, status, p99, upstream errors | 5xx >1% or p99 >500 ms for two samples |
| application | health/readiness, responses, send errors, write aborts, saturation refusals | two consecutive readiness failures or any saturation event |
| supervisor | `ActiveState`, `SubState`, `Result`, `NRestarts` | unexpected restart, `failed`, timeout or OOM |
| cgroup/process | `memory.current/max`, `memory.events`, FDs, threads | memory >80%, `oom_kill` increment, FD budget drift |
| spool | bytes, live `druse-spool-*`, cleanup age | quota refusal, orphan or unexpected growth |

If a real telemetry backend is unavailable, the attended pilot dashboard is the
versioned sampling command in the WP06 campaign. “No dashboard” is not an
accepted substitute.

## Entry procedure

1. Start from a clean candidate commit. Record commit, tree, compiler hash,
   binary hash, configuration-bundle hash and UTC start.
2. Verify `bash build/check.sh` is green for that candidate.
3. Install the candidate into a versioned, immutable release directory. The
   binary, runtime limits and proxy configuration are one bundle; never copy
   only the binary over the active release.
4. Run `ops/deploy/check-runtime-limits.sh` inside the effective cgroup before
   bind. Refuse any inherited, unbounded or mismatched value.
5. Validate the pinned Caddy configuration, TLS identity and route allowlist.
6. Atomically switch the `current` release link, start the supervised service,
   and wait for health then readiness.
7. Run functional smoke through TLS/proxy: allowed route, rejected route,
   request ID, stream first byte, body limit and client identity.
8. Open admission only after dashboards and alerts are observed, then apply the
   fixed low load. Record every manual intervention.

## Abort criteria

Abort immediately and execute `docs/runbooks/rollback.md` when any of these is
true outside an explicitly injected drill:

- unexpected response/status, malformed framing, data-integrity mismatch or
  traffic reaching a route outside `/pilot/*`;
- 5xx exceeds 1%, p99 exceeds 500 ms for two samples, or readiness fails twice;
- any saturation refusal at the R1 load, send error/write abort without an
  explained slow-client arm, unexpected restart, OOM, crash-loop or unit
  `failed` state;
- memory exceeds 80% of `MemoryMax`, FD/thread count leaves its recorded bound,
  or a spool orphan remains;
- candidate binary/config hash no longer matches the installed manifest;
- owner, dashboard or rollback artifact becomes unavailable.

Do not tune through an abort. Roll back first; investigate on a closed copy.

## Exit

Stop admission, publish not-ready, drain, stop the service and verify no live
socket or spool remains. Either roll back to the previous bundle or explicitly
retain the candidate only after the complete checklist is green. Preserve the
timeline and decision under `evidence/`.
