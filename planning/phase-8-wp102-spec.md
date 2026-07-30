# WP102 — Phase 8 system spec, hypotheses and evidence thresholds

**Status: SPEC, 2026-07-24.** The pre-code contract for Phase 8 (proof-by-use).
Written before any application code, per `planning/phase-8-plan.md` §6 WP102.
Rollback: HIGH — docs only. This document refreshes the program plan against the
Phase 7 and 7.5 freezes and records the entry verification (E8-7 gate).

---

## 1. Entry verification (the E8 gate, checked against the tree, not annotations)

Verified 2026-07-24 against the actual repositories, not the memory or BOM prose
— which is the WP102 discipline. One item (E8-7 `metrics`) *appeared* missing
because the PR-#13 squash-merge is titled "A1-A3"; checking the merged tree
showed it carries A1-A5 in full. That is exactly why entry is verified by
content.

| ID | Status | Evidence |
|---|---|---|
| **E8-1** Phase 6 frozen (PG runtime, migrations, reference app) | ✅ | crystals `main` `36db55c`: `docs/phase-6-freeze.md` **FROZEN**; `db/postgres`, `db/migrate`, `examples/notes` (WP83) present and gated |
| **E8-2** Phase 7 frozen (streams, SSE, large-body ingest, transfer slice) | ✅ | core `closure`: `web.stream`/spool/`web.enable_upload`; crystals `web/sse` (WP97) on main |
| **E8-3** Pinned consumption for core + every Crystal; no branch-relative hidden dependency | ◑ **decided below (§2)** | app pins **fixed commit SHAs** — core `closure` HEAD and crystals `main` `36db55c` — via the `druse`/`crystals` collections. A fixed SHA is not a branch-relative dependency |
| **E8-4** Deployment target, reverse proxy, supervisor, **dedicated PostgreSQL** | ⚠️ **prerequisite for WP103** | VPS `45.32.215.234` has Caddy (proxy) + systemd (supervisor); **PostgreSQL is NOT installed/running** (inactive, no container, no `:5432`). Provisioning a dedicated instance is the first WP103 task, isolated under `/opt/druse-verify` conventions, never touching the CI/Caddy already there |
| **E8-5** Security/retention scope written before real user data; synthetic default | ✅ **this doc §5** | — |
| **E8-6** Observability distinguishes route/query/pool/stream/failure without PII | ✅ | core `web.observe`/`Framework_Event`, `web.stats()` (Hardening H-3), `web.refused_connections()`; crystals `metrics` + `db/postgres` pool stats |
| **E8-7** Composition Crystals frozen (`http_client` w/ fail-closed TLS, `metrics`) + BOM has no unclassified/ABERTO-without-trigger item | ✅ **VERIFIED** | crystals `main`: `http_client` (20 symbols, TLS corpus vs real `s_server` peers), `web/metrics` (install/routes, WP20 redaction by construction, test green against the CURRENT core), `docs/phase-7.5-composition-freeze.md` **FROZEN**. BOM: every row classified; every ABERTO carries a trigger (verified row by row) |

**Entry conclusion:** the composition gate (E8-7) and the frozen-foundation gates
(E8-1/2) are satisfied. Two items are **carried as WP103 prerequisites, not
blockers**: provision the dedicated PostgreSQL (E8-4) and pin the two upstream
SHAs (E8-3). Neither is ABERTO-without-trigger; both have a named owner (WP103).

---

## 2. Where the application lives — DECISION: a separate third repository

The plan (§0, §1, §2, WP103) and the exit gates (E8-3, G8-1) are emphatic and
consistent: the application depends **only on released or pinned public
contracts**, receives **no friend imports, test-only privileges or core
exceptions**, and makes **no core-repository relative import**. The owner's
directive restates the fork: *third repo or under `examples/` — WP102 decides;
never put application code in the frozen core.*

**Decision: a separate repository — `druse-board`.** Rationale, and the
alternative refused:

- An app under `examples/` inside a framework repo can reach `druse:web`
  through the collection **as a sibling of the source it imports**, so a slip
  into a relative/internal import would compile. That silently defeats the one
  thing proof-by-use exists to prove: that the framework composes through its
  **public, pinned** surface. The `examples/notes` app (WP83) is a *controlled
  integration in the crystals repo*, not proof-by-use, and its scope is smaller.
- A separate repo makes E8-3 and G8-1 **structural**: it physically cannot see
  a core internal, and it must pin core and crystals as fixed SHAs. A friction
  item that would need an internal import becomes a recorded framework finding
  instead of a quiet reach-through — which is the entire evidence model (§2 of
  the plan).

The repo is created in **WP103**, not here. It pins:

- `druse` collection → the core `closure` HEAD commit (production-ready:
  Closure C-01..C-08 + Hardening H-1..H-5, full gate green bar the environmental
  wp41 flake). *Clean release step, owner's call: merge `closure` → core `main`
  and pin the merge; either way the pin is a fixed SHA.*
- `crystals` collection → crystals `main` `36db55c`.

The WP102 **spec** (this file) lives in the core `planning/` alongside the other
phase docs; only application CODE is barred from the core, and this is not code.

---

## 3. The product — a collaborative operations/project board

Not an admin generator. A real multi-user board where teams run projects, and
every capability is pulled by a genuine workflow rather than invented as a
benchmark endpoint.

### 3.1 Actors and roles

- **Account** — a person with credentials and sessions.
- **Project membership roles** (per project, RBAC): `owner`, `maintainer`,
  `member`, `viewer`. Roles gate mutations; `viewer` is read + subscribe only.

### 3.2 Workflows (each maps to a plan-required capability)

| Workflow | Pulls | Plan link |
|---|---|---|
| Register / log in / log out; session expiry & revocation | identity, opaque session tokens, CSRF | WP104 |
| Create project; invite member with a role | RBAC, transactions | WP104/105 |
| Create/edit/assign/transition task; comment | relational workflows, status machine, audit | WP105 |
| Two users edit one task | **optimistic conflict detection** (version column → 409) | WP105/108 |
| Attach a file to a task; attach a **> `max_body`** file | buffered multipart AND the **spool path** (`web.enable_upload`/`upload`/`upload_persist`) | WP106 |
| Filter/search tasks; page through them | dynamic filters (explicit SQL first), **stable cursor pagination** | WP106 |
| Watch a board live | **SSE notifications** (crystals `web/sse`), reconnect, `Last-Event-ID` | WP107 |
| Deploy while a client watches | reconnect-after-deploy, drain | WP107/110 |
| Operate it | `/health`, `/ready`, `/metrics` (crystals `metrics`), `web.stats()` | WP109 |
| Notify an external system on task events | **outbound webhook** via crystals `http_client` (bounded pool, timeout budget, bounded retry, drain cancel, fail-closed TLS) | WP105/113 |

### 3.3 Explicit non-capabilities (recorded now so they are decisions, not gaps)

- No WebSocket / full-duplex — SSE covers server push (ADR-014 / core scope).
- No in-app rendering/DOM policy — the notification says *what changed*; the
  client refreshes through an explicit application contract (plan §WP107).
- No ORM / schema auto-sync — explicit named SQL and immutable migrations.
- No atomic filesystem+DB transaction — the file/DB boundary is a documented
  compensation with an orphan-cleanup procedure (plan §WP106).

---

## 4. Data model (initial; migrations evolve it — see §7)

Explicit tables, explicit named SQL. `version` columns carry optimistic
concurrency. Timestamps are `timestamptz`. IDs are surrogate `bigint`/UUID
(decided in WP105 with the query evidence).

- `accounts(id, email unique, password_hash, created_at, ...)`
- `sessions(id, account_id fk, token_hash unique, created_at, expires_at, revoked_at null)`
- `projects(id, name, owner_id fk, created_at, version)`
- `memberships(project_id fk, account_id fk, role, created_at, PRIMARY KEY(project_id, account_id))`
- `tasks(id, project_id fk, title, body, status, assignee_id fk null, created_at, updated_at, version)`
- `comments(id, task_id fk, author_id fk, body, created_at)`
- `attachments(id, task_id fk, filename, byte_size, storage_path, spooled bool, created_at)`
- `audit_log(id, project_id fk, actor_id fk, action, target_kind, target_id, at, detail jsonb)`
- `webhooks(id, project_id fk, url, secret, created_at)` + `webhook_deliveries(id, webhook_id fk, event, status, attempts, last_at)`

The status machine (`tasks.status`) is a closed set with declared legal
transitions, enforced in the handler, audited on change.

---

## 5. Threat model and data-retention scope (E8-5)

**Synthetic, non-sensitive data is the default and the only data used in this
phase.** No real personal data enters the system before a separate privacy
review (plan §8 non-goal). Concretely:

- **Identity:** passwords hashed with a memory-hard KDF (argon2id if available
  via a Crystal/FFI; else a documented bcrypt-class fallback — the choice and
  its threat model recorded in WP104). Session tokens are **opaque**, stored as
  a hash, with expiry and explicit revocation.
- **Transport:** TLS terminated at Caddy; `proxy_buffering off` (the C-06
  contract) so SSE is not withheld. The app trusts `X-Forwarded-For` only from
  the proxy hop (`web.trust_proxies`), the F4-pinned behaviour.
- **CSRF:** browser mutations carry a double-submit or same-site cookie policy,
  decided at the proxy/app boundary in WP104.
- **Redaction:** logs and metrics carry route pattern, query name, pool/stream
  state and failure class — **never** a path, header, body, bound value or
  password. `web.observe`/`Framework_Event` already redact by construction;
  application logs must uphold the same budget (E8-6).
- **Retention:** the dataset is generated and owned for the test (plan §4
  operational). Destructive drills (WP110) run only against this scoped data.

---

## 6. Deployment topology (proven, not described — WP103/110)

```
client ──TLS──▶ Caddy (reverse proxy, proxy_buffering off, XFF)
                  │  http, keep-alive
                  ▼
              druse-board  (systemd: Restart=always, TimeoutStopSec > max_drain_time)
                  │  bounded pool (crystals db/postgres)
                  ▼
              PostgreSQL  (dedicated instance; migrations run as a deploy STEP, never on boot)
```

- Reverse proxy: **Caddy** (already on the VPS; the app uses a dedicated high
  port, never the CI/Caddy config in place).
- Supervisor: **systemd**, `Restart=always`, `TimeoutStopSec` set above the
  app's `max_drain_time` so the framework drain runs before the kill (the
  Hardening H-4 rule; matches `docs/operations.md`).
- Memory: a cgroup sized from the corrected C-04 concurrent response campaign;
  large downloads use the spool/stream path so memory scales with the bounded
  stream window rather than total output length.
- PostgreSQL: a dedicated instance, isolated under `/opt/druse-verify` on the
  VPS, provisioned in WP103; **the server never migrates on boot** — migrations
  are a separate, checksum-guarded deploy step (crystals `db/migrate`).
- The first deploy serves a **boring health page** before any domain feature, to
  prove lifecycle and delivery independently (plan §WP103).

---

## 7. Hypotheses under test (plan §6)

1. an ordinary contributor needs only the five core concepts plus explicit
   application services;
2. concurrent handlers do not make application state confusing when mutable
   services own their synchronization;
3. explicit SQL stays readable at the board's real query count;
4. migrations evolve the schema without server-boot coupling;
5. streamed notifications need no backend/internal access;
6. bounded pool and stream policies fail predictably under saturation;
7. one reverse-proxy deployment story suffices;
8. docs let a human and a coding agent implement the same canonical shapes.

Each hypothesis is falsifiable and tied to a WP; a failure is a recorded
framework finding (§9), never a silent workaround.

---

## 8. Pre-registered evidence thresholds (the gate; counts, not calendar time)

These numbers are fixed **now**, before code, so the phase cannot be declared
done by moving the bar.

| Evidence | Threshold |
|---|---|
| **Deployments** | ≥ **10** recorded, **≥ 3 with active SSE clients** across the deploy |
| **Forward migrations** | ≥ **5**, immutable (checksum-guarded), including **≥ 1 backfill** and **≥ 1 expand/contract** rename-or-type transition |
| **Restart drills** | app kill+restart, graceful deploy, forced supervisor kill, PostgreSQL restart mid-transaction, network interruption — each recorded with expected/observed/detection/recovery/invariant (WP110) |
| **Soak** | a sustained run **≥ 4 hours** (pre-registered here), crossing at least one **session-expiry** boundary and one **connection-recycle** boundary; pass = no monotonic RSS growth beyond the C-04 threshold and no counter that fails to return to baseline |
| **Dataset** | a non-trivial persistent dataset — **≥ 5 projects, ≥ 500 tasks, ≥ 2000 comments, ≥ 50 attachments (≥ 1 spooled > `max_body`)** — generated and owned for the test |
| **Concurrency** | two-client conflict → **409 or resync, never silent last-write**; pool-at-cap → **fast 503 while `/health` stays live < 250 ms**; slow consumer → stream `Full` refusal, fast consumers unaffected (WP108) |
| **Usability (WP112)** | 1 human + ≥ 2 coding-agent conditions each complete the 5 canonical tasks from **public docs only**; record concepts used, iterations, invented aliases/internal imports (target: **zero**), ownership mistakes |
| **Friction ledger** | **every** friction item classified per §9 — none forgotten |

**Stopping rules.** The phase stops (verdict WP113) when: all deterministic
gates (G8-1..G8-7) are green; the counts above are met; and either the friction
ledger is empty of unresolved *blocking* items or each remaining item is
explicitly accepted with rationale. The phase stops **early with a NEGATIVE
finding** if any hypothesis is falsified in a way that requires a core change —
that change goes to a separately-gated corrective WP, not an accretion here.

---

## 9. Friction-ledger format (plan §2 — the evidence instrument)

Every friction item, in `planning/phase-8-friction-ledger.md` (created when the
first item appears), carries all nine fields:

1. task the user attempted;
2. public API used;
3. boilerplate / concepts required;
4. safety or ownership problem;
5. workaround, if any;
6. whether the problem is application-specific;
7. smallest candidate improvement;
8. public cost and reversibility;
9. a RED test that would distinguish improvement from preference.

Core/Crystal changes happen only in a separately reviewed corrective WP with its
original gates. Phase 8 is a veto and evidence source, not an accretion
exception (plan §2).

---

## 10. What WP103 does next

1. Provision the dedicated PostgreSQL on the VPS (E8-4), isolated, never
   touching the CI/Caddy already running.
2. Create the `druse-board` repository pinning the two SHAs (§2, E8-3).
3. Explicit config load + validation; `application_init`/`destroy` owning the
   pool and services in one typed `App_State` (the `examples/notes` canonical
   shape, extended); migrations as a deploy step; a boring health page as the
   first deploy.

No application code is written under WP102.
