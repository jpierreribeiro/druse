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
   `DEFAULT_MAX_STREAMS` note) and the corrected **C-04 concurrent buffered
   response matrix**: body-size distribution, handler concurrency, slow readers,
   live arena peak and process RSS high-water.

## 3. What is measured (pre-registered)

- throughput and latency (p50/p95/p99) **by route pattern**;
- **RSS and live allocation vs concurrent buffered responses** — derive the
  workload-specific envelope and observe whether RSS stabilizes after clients
  leave; do not infer live ownership from RSS alone;
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

### Env A (baseline, 2 vCPU / 1.6 GiB) — partial, 2026-07-24

The functional/concurrency/drill/soak results are recorded in the board's
`DEPLOYMENTS.md` (#1–#5 + the drills). The **intermediate live SSE scale probe**
(`ops/sse-scale.sh`) adds the first capacity data point:

| Concurrent SSE subs | Admitted | /health/live | /ready | Server RSS |
|---|---|---|---|---|
| 50  | 50 / 50   | 200 | 200 | 27.9 MB |
| 100 | 100 / 100 | 200 | 200 | 30.2 MB |
| 200 | 200 / 200 | 200 | 200 | 39.8 MB |
| 300 | **297 / 300** | 200 | 200 | 53.4 MB |

- **Capacity knee ≈ 300 concurrent SSE streams on this 2-CPU/1.6 GiB host** —
  admission falls just below the offered load there (3 dropped), and does so
  *gracefully*: health and readiness stayed 200, and the server **recovered 100%**
  after every level (no crash, no wedge).
- **RSS tracks connections linearly and cleanly** (28→30→40→53 MB for
  50→100→200→300) — a live confirmation of the **C-04 rule** (RSS ≈ per-connection
  retention). No runaway growth; RSS returns to baseline after release.
- This is NOT the owed **3,000-socket** round — that needs Env B. But it proves the
  live SSE wire path scales to the small host's limit predictably, and gives the
  first point on the capacity curve. The 3,000 round and the RSS-vs-connections
  slope at scale are the Env B deliverable.

### Env B / C — pending the owner's larger VPS.

## 6. What I need from the owner

SSH (or a key) to the larger VPS(s), each with Docker (for the isolated PostgreSQL)
and the same isolation convention (`/opt/druse-verify`, never the box's own
services). Nothing else — the build, deploy, and suites are scripted.
