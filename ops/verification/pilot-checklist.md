# R1 controlled-pilot entry/exit checklist

Record `PASS`, `FAIL` or `NA(reason)` for every row. A blank row is a failure.
The canonical policy is `ops/deploy/pilot-profile.env` and the normative support
boundary is `docs/supported-profile.md`.

## Entry

- [ ] candidate commit/tree and clean status recorded
- [ ] compiler, binary and complete bundle SHA-256 recorded
- [ ] full gate green on the same candidate
- [ ] owner `jpierreribeiro`, 60-minute attended window and rollback operator present
- [ ] previous immutable bundle and manifest verified
- [ ] no irreversible migration; data is synthetic or reconstructible
- [ ] systemd unit and runtime preflight green under effective limits
- [ ] pinned Caddy configuration and TLS identity verified
- [ ] `/health`, `/ready`, `/pilot/*` allowed; every other route rejected
- [ ] dashboards visible and abort alerts armed
- [ ] load generator capped at 10 rps, 20 clients, two streams, one upload

## Exercise

- [ ] functional and wire smoke green through proxy
- [ ] low representative load stayed inside latency/error/memory thresholds
- [ ] normal stop published not-ready then drained
- [ ] injected Handler fault produced classified exit and supervised restart
- [ ] previous binary and configuration rolled back together
- [ ] post-rollback hashes, health, readiness, routes and sentinel verified

## Exit

- [ ] no candidate process/listener or orphan spool remains
- [ ] proxy, service-manager and application UTC timelines preserved
- [ ] before/candidate/rollback hashes and status/signal preserved
- [ ] every manual intervention recorded
- [ ] final decision is exactly `PROMOTE TO R1`, `HOLD` or `ROLL BACK TO R0`
- [ ] evidence SHA-256 manifest verifies from a clean checkout
