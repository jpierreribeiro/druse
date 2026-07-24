# WP113 — Phase 8 product verdict, capability matrix and freeze

**Status: DRAFT VERDICT, 2026-07-24.** Substantially complete; two inputs remain
explicitly PENDING and are marked so throughout — the ≥4h soak's final RSS number
(running; early signal strong) and the WP112 **human** usability condition
(owner). The release/tag decision is reserved to the owner (plan §WP113). This
document is the capstone of Phase 8 (proof-by-use); it does not itself freeze
anything until the two pending inputs land.

The reference application is `jpierreribeiro/uruquim-board` (board `master`
`c0df594`); framework findings live in `planning/phase-8-friction-ledger.md`
(core `phase8`).

---

## 1. What Phase 8 built and proved

A real, multi-user, data-backed operations/project board, built and operated
**only through pinned public Uruquim + Crystals contracts** (separate repo; no
friend import; G8-1 structural), then deployed, evolved and faulted on real
hardware (VPS `45.32.215.234`, isolated under `/opt/uruquim-verify`).

Proven **live against real PostgreSQL** (not just typecheck):

- **WP104 identity** — argon2id passwords, opaque bearer-token sessions
  (SHA-256-stored, SQL-checked expiry/revocation), per-project RBAC.
- **WP105 relational + transactions** — tasks/comments/status-machine, optimistic
  concurrency (version → 409), a transaction per mutation with a persistent
  `audit_log`.
- **WP106 files + validation + pagination** — buffered AND spool upload (5 MiB
  attachment → `spooled=true` live), 413 cap, file/DB compensation, keyset
  pagination + filters, true three-state PATCH.
- **WP107 SSE** — per-project subscription, synchronized hub, `Last-Event-ID`
  reconnect.
- **WP108 concurrency** — two clients / same version → exactly one 200 + one 409;
  pool-at-cap → fast 503 while `/health/live` stays 200.
- **WP109 observability** — Prometheus `/obs/metrics` (crystals `metrics`) +
  authenticated `/admin/stats` (`web.stats` + `pg.pool_stats`).
- **WP110 drills** — SIGKILL→supervisor recovery + durable data; PostgreSQL
  restart → liveness stays 200, readiness bounded 503 → recovers as the pool
  reconnects; graceful restart; malformed-request rejection (16/16, injection
  stored as a literal); migration checksum-mismatch **refused** (immutability).
- **WP111 evolution** — 7 immutable migrations (≥5), including a **backfill**
  (`comment_count`, verified 2400 over 600 tasks) and an **expand/contract**
  (`body`→`description`) deployed in the safe order.
- **WP112 usability (agent conditions)** — 3 independent agents converged
  byte-identically on the canonical shape, first-compile, zero internal imports.

Dataset owned for the test: 5 projects, 600 tasks, 2400 comments, plus attachments
incl. a spooled >max_body file.

---

## 2. Exit-gate status (plan §7)

| Gate | Verdict | Basis |
|---|---|---|
| **G8-1** No privileged application | ✅ MET | separate repo; the build gate greps for internal imports and all app + 3 WP112 agent copies are clean |
| **G8-2** Evolvable data | ✅ MET | 7 immutable migrations, checksum-guarded (tamper **refused** live), ≥1 backfill + an expand/contract deployment |
| **G8-3** Concurrent product correctness | ✅ MET | two-user conflict → 409; blocked queries + pool saturation → fast 503; SSE notify + reconnect; no silent last-write |
| **G8-4** Operable failure | ✅ MET (core cells) | process kill, PG restart, graceful restart, malformed input — each detected, bounded, recovered with the declared invariant. Network/upload-interruption cells deferred behind the soak |
| **G8-5** Bounded resources | ◑ PENDING soak-final | named caps measured (pool 8, max_body 4 MiB, attachment 50 MiB, streams); post-drill counters return to baseline; **soak RSS plateau strong but the ≥4h final number is pending** |
| **G8-6** Joy | ◑ agents MET / human PENDING | 3 agent conditions completed canonical tasks from the public surface without a second architecture; the **human** condition is the owner's |
| **G8-7** Honest positioning | ✅ on track | see §6; capability claims below match the evidence |

---

## 3. Hypotheses (plan §6 / WP102 §7) — outcomes

1. *A contributor needs only the five core concepts + explicit app services* —
   **supported** (WP112: agents used a small, named public set; no internal reach).
2. *Concurrent handlers don't confuse state when services own synchronization* —
   **supported** (the hub owns its mutex; WP108 clean under concurrency).
3. *Explicit SQL stays readable at the real query count* — **supported** (named
   SQL throughout; the query count is legible, no builder needed).
4. *Migrations evolve schema without boot coupling* — **supported** (7 migrations
   as deploy steps; server never migrates on boot; expand/contract live).
5. *Streamed notifications need no backend/internal access* — **supported**
   (SSE via the public Crystal; hub is ordinary app code).
6. *Bounded pool/stream policies fail predictably under saturation* — **supported**
   (fast 503 at pool cap; liveness independent; drills bounded).
7. *One reverse-proxy deployment story suffices* — **supported** (Caddy→app→PG;
   4 deployments; the story did not need a second shape).
8. *Docs let a human and an agent implement the same canonical shapes* —
   **supported for agents** (3/3 byte-identical convergence); **human pending**.

No hypothesis was falsified. Two produced findings rather than failures
(F8-2/F8-4 capability gaps; F8-6/F8-8 DX gaps) — the intended proof-by-use yield.

---

## 4. Friction ledger disposition (F8-1..F8-8)

All recorded with nine fields; **none applied** (Phase 8 is a veto/evidence
source — corrective WPs are the owner's call, with the original gates).

| ID | One-line | Class | Provenance |
|---|---|---|---|
| **F8-1** | `web.Status` enum lacks 503/429/409/413 | capability (enum) | 2 independent apps |
| **F8-2** | no public way to set a response header (→ no `Set-Cookie`) | capability | forced bearer tokens |
| **F8-3** | no request-scoped typed state (ADR-028) → repeated auth prologue | DX/evidence | measured boilerplate |
| **F8-4** | no buffered binary responder / `Content-Disposition` → no file download | capability | confirmed F8-2 from another angle |
| **F8-5** | no stream client-disconnect signal → idle subscriber leak | DX | live (WP107) |
| **F8-6** | no optional TYPED query param (`query_int` 400s on absence) | DX | **a live bug that shipped**, caught by smoke |
| **F8-7** | `Expect: 100-continue` → 417, large uploads from default clients fail | interop | live (spool proof) |
| **F8-8** | no typed timestamp input + no date validator (→ 500 on bad date) | DX/Crystal | **3 independent WP112 agents** |

Natural batching for a corrective WP: **enum/type completions** (F8-1 + F8-8),
**response surface** (F8-2 + F8-4, a `web.set_header` + `web.bytes` pair),
**transport** (F8-7), **DX/evidence** (F8-3, F8-5, F8-6) weighed against their
ADRs.

---

## 5. Incident, drill, migration and deploy record

- **Defects found by proof-by-use, fixed:** two, both live-only (no typecheck
  could catch them) — the `query_int`-on-optional-filter 400 (F8-6) and the
  ambiguous-JOIN-column 500 on attachment metadata. Both fixed and re-verified
  (smoke 22/22).
- **Drills:** process SIGKILL, PostgreSQL restart, graceful restart, malformed
  requests (16/16), migration checksum tamper — all with declared invariants met.
- **Migrations:** 7, checksum-guarded, non-dirty; tamper refused.
- **Deployments:** 4 recorded (#1 WP103, #2 WP104–109, #3 bugfix, #4 WP111+drills)
  toward the pre-registered ≥10. **6 more are the main operational remainder.**
- **Soak:** ≥4h run in progress; RSS warmed then plateaued flat (early leak-free
  signal); final verdict pending completion.

---

## 6. Capability matrix and explicit non-capabilities

**Proven capabilities (for the exact scope tested):**
identity + opaque sessions + per-project RBAC · relational workflows with
transactions and optimistic concurrency · buffered + spooled file upload with a
compensation boundary · keyset pagination + explicit-SQL filters · SSE server-push
with reconnect · Prometheus + admin observability · bounded pool/stream with
fast, live-safe saturation · immutable checksum-guarded migrations incl.
backfill and expand/contract · supervised recovery from process/DB failure.

**Explicit non-capabilities (decisions, not gaps):**
no cookie sessions / `Set-Cookie` (F8-2 — bearer tokens instead) · no in-framework
binary file download / `Content-Disposition` (F8-4) · no WebSocket/full-duplex
(SSE only) · no in-app rendering/DOM policy · no ORM/schema auto-sync · no atomic
filesystem+DB transaction (documented compensation) · no typed timestamp input
(F8-8) · `Expect: 100-continue` not honored (F8-7).

**"Microframework" positioning (G8-7):** the evidence supports it — the app
composes from a small public surface, the core stayed frozen through a demanding
multi-user system, and every pressure became an application pattern or a recorded
finding rather than a core change. **Recommendation:** README may retain
"microframework" and may claim production-oriented data + bounded-streaming
capability **only for the exact proven scope**, listing the non-capabilities above.

---

## 7. Release-readiness recommendation (reserved to the owner)

**Engineering recommendation: controlled pilot — ready**, consistent with the
Closure verdict, for a deployment that: sits behind a reverse proxy with
`proxy_buffering off`; runs under a supervisor with `TimeoutStopSec` >
`max_drain_time` and `LimitMEMLOCK=infinity`; sizes a cgroup by the C-04 rule;
strips `Expect: 100-continue` at the proxy or client for large uploads (F8-7);
and accepts the eight recorded frictions as known, non-blocking, additive-fix
candidates. **The release/tag decision itself is the owner's.**

---

## 8. Explicitly PENDING before Phase 8 can be declared frozen

1. **Soak ≥4h final result** — read `/opt/uruquim-verify/soak.log` at completion
   (~18:14 UTC 2026-07-24); pass = no runaway RSS growth. Crossing a session-expiry
   boundary needs a shortened TTL (a parameter decision).
2. **WP112 human condition** — a human contributor implements the canonical tasks
   from public docs; compare to the agent convergence.
3. **≥6 more deployments** toward the ≥10 threshold (naturally from the corrective
   WP and continued operation).
4. **Deferred WP110 cells** — network interruption, upload interruption, proxy
   misconfiguration — run after the soak so they don't perturb its measurement.
5. **Owner's verdict** — accept the frictions' dispositions and make the release
   call.

Until (1)–(2) land and (5) is given, this is a DRAFT verdict, not a freeze.
