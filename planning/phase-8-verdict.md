# WP113 — Phase 8 product verdict, capability matrix and freeze

**Status: FINAL (CONTROLLED-PILOT) VERDICT, 2026-07-24.** Phase 8 (proof-by-use) is complete and
**the Corrective Program (C1–C7) that resolved all eight findings is live-verified
in production** (deployment #5). The ≥4h soak PASSED. What remains before this
flips DRAFT→FINAL and a release tags is owner/hardware-gated, tracked in
`planning/release-readiness.md`: the multi-host scale campaign (Gate 2), owner
ratification of the ADR-028 amendment (Gate 4), pre-release hygiene (Gate 5), and
the WP112 human condition + merge/tag (Gate 6). This document does not itself
freeze or tag anything.

The reference application is `jpierreribeiro/uruquim-board`; the deployment-#5
line is board `corrective-repin` `c5e1dfd` on the corrective core (`phase8`
`03c2bce`) + crystals (`corrective` `7c64d47`). Framework findings and their
resolutions live in `planning/phase-8-friction-ledger.md`.

**Headline:** every one of the eight friction findings F8-1..F8-8 is RESOLVED and
**verified running against real PostgreSQL and real clients** — including the two
facets that could only be runtime-checked (the `arg_timestamptz` OID typing and
the `Expect: 100-continue` socket behaviour). The framework moved from "controlled
pilot" toward general readiness; the release itself waits on the scale evidence and
the owner's sign-offs.

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
| **G8-4** Operable failure | ✅ MET | the FULL WP110 drill set live: process kill, PG restart, graceful restart, malformed input, checksum tamper, upload interruption, proxy misconfiguration (proxy_buffering on withholds SSE / off forwards it — C-06 proven), network interruption (readiness gap found + mitigated with tcp_user_timeout; remote-DB validation → scale campaign). Each detected, bounded, recovered |
| **G8-5** Bounded resources | ✅ MET | named caps measured (pool 8, max_body 4 MiB, attachment 50 MiB, streams); post-drill counters return to baseline; **≥4h soak PASSED (2026-07-24): 2750 cycles, 16745 responses, errors=0, RSS plateaued flat at 41,780 kB after a 12→41 MB warm-up — no runaway growth (<64 MiB); session-expiry boundary then crossed by ops/session-expiry-drill.sh: fresh→200, aged-past-now()→401, re-login→200, revoke→401)** |
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

## 4. Friction ledger disposition (F8-1..F8-8) — ALL RESOLVED

Recorded in Phase 8 as evidence; **all eight RESOLVED by the Corrective Program
(C1–C7)**, each an additive, separately-gated change with the original freeze
ritual and a RED→GREEN test, and each **verified live in deployment #5**.

| ID | One-line | Corrective WP | Verified live |
|---|---|---|---|
| **F8-1** | `web.Status` lacks 409/413/429/503 | **C1** | 409/503/413 on the wire |
| **F8-2** | no way to set a response header (→ no `Set-Cookie`) | **C2** `set_header` | header on the wire |
| **F8-3** | no request-scoped typed state (ADR-028) | **C7** `request_state` | in binary; ADR ratification pending |
| **F8-4** | no buffered binary responder / `Content-Disposition` | **C2** `bytes` | download → 200 + disposition |
| **F8-5** | no stream client-disconnect signal | **C4** `stream_live` | registry-tested; in binary |
| **F8-6** | no optional TYPED query param | **C3** `query_int_opt` | unfiltered list → 200 |
| **F8-7** | `Expect: 100-continue` → 417 | **C6** (transport) | 5 MiB default upload → 201 |
| **F8-8** | no typed timestamp input + no date validator | **C5** `arg_timestamptz`+`rfc3339` | stored timestamptz no cast; bad → 400 |

The one that is more than a gap fix: **C7 reverses ADR-028's stated "there will
not be one"** — a narrow, typed reopening recorded in `planning/adr-028-amendment.md`
with an ADOPT recommendation, awaiting the owner's ratification (release Gate 4).

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

1. **Soak ≥4h** — ✅ DONE. PASSED 2026-07-24 (4 h, 2750 cycles, errors=0, RSS flat
   at 41,780 kB steady-state). Crossing a session-expiry boundary needs a shortened
   TTL (a parameter decision) — a follow-up, not a blocker.
2. **WP112 human condition** — a human contributor implements the canonical tasks
   from public docs; compare to the agent convergence.
3. **≥6 more deployments** toward the ≥10 threshold (naturally from the corrective
   WP and continued operation).
4. **Deferred WP110 cells** — network interruption, upload interruption, proxy
   misconfiguration — run after the soak so they don't perturb its measurement.
5. **Owner's verdict** — accept the frictions' dispositions and make the release
   call.

Until (1)–(2) land and (5) is given, this is a DRAFT verdict, not a freeze.
