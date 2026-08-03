# R2-WP07 step 1 — shadow replay, no response to a user

**Decision: the shadow step of the canary progression is GREEN. Nothing is
promoted; the gate stays at R1, and steps 2–6 are not reached.**

## Why this ran at all

R2-WP07 had been recorded as *blocked on real production traffic*, and that
reading was wrong. `R2-restricted-production.md` §8 opens its canary progression
with **"shadow ou replay sanitizado, sem resposta ao usuário"** — a step whose
definition is the absence of a user. It needs a candidate, the supported edge and
traffic in the shape of production. All three existed. The steps that need real
users are 2 through 6, and §8.1 records those as a formal accepted risk for the
owner to sign rather than as a blockage.

## What ran

| | |
|---|---|
| candidate | `tests/r1-real-proxy/server`, `sha256` in `manifest.txt` — the fixture the pinned Caddyfile is written against |
| edge | pinned Caddy `2.11.4-alpine`, by digest, `ops/proxy/caddy/Caddyfile` unmodified |
| shape | `ops/canary/shadow-profile.md`, declared with an origin per number |
| window | 60 s, 40 req/s offered, seed 20260803 |
| result | **467 requests, 467 × 200, zero transport errors**, 5,138 response bytes read and discarded |

## The containment claim

| # | Property | Result |
|---|---|---|
| K1 | candidate listen address | **wildcard — recorded, not asserted.** See the finding below |
| K1b | every peer that talked to the candidate was the proxy | `k1b_foreign_peers=none`, sampled every 250 ms for the whole window |
| K2 | the pinned proxy publishes only to `127.0.0.1` | pass — every `HostIp` in `raw/proxy-port-bindings.json` is loopback |
| K3 | the accounting closes with no remainder | **pass** — 359→467 sent, the same served, `responses_delivered_to_a_user=0` |

K3 is the claim that survives being moved to another topology: *every request the
edge served is one the shadow sent*. A response that reached a user is a served
request nobody in this harness sent, and it appears as an unaccounted remainder
rather than as an absence somebody has to notice. `analysis/containment.txt`
carries the per-route reconciliation.

The reconciliation is exercised by `build/check_shadow_containment.sh`: a
positive that stays green and five mutants that must go red — a route never sent,
more served than sent, an empty log, an unparsable line, and a missing log.
Without them, "containment=proven" would be a string the script always prints.

### SHADOW-001 — Druse cannot be told to listen on loopback only

`web.serve(&app, port)` takes a port and **no address**, and the transport binds
dual-stack Any — `::`, falling back to `0.0.0.0`
(`web/internal/transport/odin_http_adapter.odin`). There is no way to confine a
Druse listener to loopback.

For a shadow this removes the natural containment. For any deployment it means
the process is reachable on every interface the host has, and confining it is the
host firewall's job rather than the application's — an operational constraint
`docs/supported-profile.md` does not currently state.

No API was invented for it (G5). K1b is the substitute and it is **weaker in
kind**: a property holds always, an observation holds over the window it
observed. The manifest labels it that way so `k1b_peer_observation=pass` is never
read as "the port was closed".

## Two harness defects found by running it

Both were silent, and both would have made the evidence say something untrue.

1. **The access log could not be read, and `cp` said nothing.** Caddy runs as
   root in the container and writes `/logs/access.json` mode 0600 root:root; the
   bind mount carries that ownership to the host, so an unprivileged copy failed.
   K3 reported `proxy_access_log=MISSING` and containment was `unproven` for a
   reason with nothing to do with containment. Retrieved through `docker cp` now,
   and the container's log directory is captured in `raw/proxy-log-dir.txt` so
   the next failure of this kind is diagnosable from the artefact.
2. **Every POST answered 400.** The driver sent `{"name": …}` and the candidate's
   `/body` handler binds `{ data: string }`, so `web.body` refused all 79 writes.
   The accounting still closed — a 400 is a served request — but a shadow whose
   writes all bounce off the binder exercises the transport and nothing above it.
   Fixed; the run above is 467 × 200.

## What this does NOT establish

- **Not steps 2–6 of §8.** No real traffic reached this candidate. The 1%, 5%,
  25%, 50% and 100% steps are untouched and are recorded as an accepted risk in
  `R2-restricted-production.md` §8.1, for the owner to sign — a risk accepted by
  whoever found it is not an acceptance.
- **The shape is declared, not sampled.** Route mix, body sizes, keep-alive
  distribution and think time are choices with stated reasons
  (`shadow-profile.md` §2), not measurements of anything real. This is the
  weakest part of the evidence and it is weak by necessity: there is no traffic
  to sample.
- **Not capacity.** 40 req/s was chosen so composition is the only variable.
  R2-WP05 owns the envelope.
- **Not stability.** Sixty seconds. R2-WP04 owns twelve hours, twice.
- **Not a rollback exercise.** R1 measured that (3 s, on a different host); this
  run neither repeated nor extended it.
- **K1b is an observation, not a guarantee.** It says no foreign peer connected
  during this window. It does not say none could have.
