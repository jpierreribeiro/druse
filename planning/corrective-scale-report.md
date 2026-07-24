# Scale & robustness report — the release Gate 2 evidence

**Status: SKELETON, 2026-07-24. Awaiting owner-provided larger VPS(s).** This is
the deliverable that closes release-readiness Gate 2. It separates *framework
behaviour* from *host limit* by running the same suites on differently-sized
hosts, and folds in the production-scale demos Closure/Hardening left owed. It is
pre-registered here (method + pass criteria) BEFORE the runs, so the campaign
cannot be declared done by moving the bar.

## 1. Environments (to be filled at run time)

| Env | CPU | RAM | Role | Notes |
|---|---|---|---|---|
| A (baseline, done) | 2 | 1.6 GiB | constrained | the Phase-8 VPS `45.32.215.234`; soak PASS, smoke 22/22, deployment #5 |
| B (headroom) | _TBD_ | _TBD_ | scale | owner-provided; the primary scale host |
| C (optional) | _TBD_ | _TBD_ | cross-check | a third size to bracket the curve |

Each runs the SAME corrective build: core `phase8` `03c2bce`, crystals
`corrective` `7c64d47`, board `corrective-repin`, under the same proxy/supervisor/
cgroup contract (Caddy `proxy_buffering off`, `TimeoutStopSec > max_drain_time`,
`LimitMEMLOCK=infinity`, cgroup sized by C-04).

## 2. Suites (each host)

1. **Functional** — `ops/smoke.sh` (22 cases) + the deployment-#5 corrective
   checks (named status, `query_int_opt`, `arg_timestamptz`, download, Expect).
2. **Concurrency** — `ops/concurrency-check.sh` (two-client 409, pool-at-cap 503
   with live liveness), scaled: N-client contention up to the host's core count.
3. **Drills** — `ops/drills.sh` + `ops/malformed-drill.sh` + `ops/migration-drill.sh`,
   plus the **deferred WP110 cells**: network interruption (drop the PG socket /
   iptables), upload interruption (client abort mid-body), proxy timeout/buffering
   misconfiguration.
4. **Soak** — `ops/soak.sh`, longer on the headroom host, **with a shortened
   session TTL** (env override) so a session-expiry boundary is actually crossed —
   the gap Env A's 24h TTL could not close.
5. **Owed scale demos** — the **3,000 concurrent real-socket SSE** round (needs a
   public stream-cap knob — an ABERTO item to resolve or a documented per-host
   `DEFAULT_MAX_STREAMS` note) and a sustained high-connection load to validate the
   **C-04 per-connection retention rule at scale** (RSS ≈ `max_connections ×
   largest response`).

## 3. What is measured (pre-registered)

- throughput and latency (p50/p95/p99) **by route pattern**;
- **RSS vs concurrent connections** — does it track the C-04 rule, and does it
  return to baseline after clients leave (the soak's leak-watch, at scale);
- pool counters (open/idle/in-use/waiters) and stream counters
  (open/queued/full/closed) under saturation, and their return to baseline;
- refusal behaviour: fast 503 at pool cap / stream `Full` while liveness stays
  200 < 250 ms — the G8-5 bounded-resource promise, at load;
- **zero unclassified failures** across every drill.

## 4. Pass criteria (the Gate-2 bar)

- No unclassified failure in any suite on any host.
- RSS bounded by the C-04 envelope and returning to baseline post-load; no
  monotonic growth over the long soak on the headroom host.
- Saturation is a *predictable refusal* (503 / `Full`), never a stall or a crash;
  liveness independent of readiness throughout.
- A stated **capacity/cost envelope**: connections, RSS, and request rate the
  framework sustains per host size — the number a real deployment plans against.

## 5. Results

_Pending the campaign. Each env's numbers, what held, what did not, and the
capacity envelope go here; then release-readiness Gate 2 flips GREEN._

## 6. What I need from the owner

SSH (or a key) to the larger VPS(s), each with Docker (for the isolated PostgreSQL)
and the same isolation convention (`/opt/uruquim-verify`, never the box's own
services). Nothing else — the build, deploy, and suites are scripted.
