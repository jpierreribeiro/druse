# R1-WP06 pilot exercise verdict

**Decision: PROMOTE TO R1 — internal, non-critical controlled pilot only.**

- Candidate   `350eefbacac5f9d32b889207754a22a9a03b24f5` passed the full gate and was installed as an immutable
  binary + runtime + pilot policy + Caddy bundle.
- TLS/proxy smoke, route allowlist, request-ID correlation, trusted client
  identity, HTTP/2 ingress, HTTP/1.1 upstream policy, detached streaming,
  spooled upload and 10 rps low load passed.
- Normal SIGTERM drained with zero restarts. A deliberate Handler fault
  produced SIGABRT core metadata and `Restart=on-failure` recovered the same
  candidate bundle.
- Rollback atomically selected actual parent commit   `489421d71bdd33f458165b3a7127b33bbc689269`, changed binary and proxy hashes together, completed in
  3s, then passed health/readiness/route/stream/integrity smoke.
- No candidate process, listener or orphan spool remained after final stop.

This verdict does not authorize critical production, direct exposure, a
different proxy, irreversible migration or load above
`ops/deploy/pilot-profile.env`.
