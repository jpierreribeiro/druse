# Release readiness — the six-gate sign-off

**Status: LIVE GATE, 2026-07-24. Owner-delegated to me** ("só será lançado de
verdade quando você aprovar, o seu padrão de qualidade"). This document is the
single place that decides whether Uruquim ships. A release/tag happens only when
**all six gates below are GREEN**; until then this file records the exact
remaining gap. I approve to the quality bar, not to optimism.

**Current overall verdict: NOT YET — 3 of 6 gates green.** The framework is
**production-verified for a controlled pilot** (Phase 8 + the Corrective Program,
live on the VPS); the three open gates are the multi-host scale evidence, two
owner decisions, and the pre-release hygiene (privacy + security re-scan + merge).

---

## Gate 1 — Corrective Program complete, workarounds dropped, RED tests green LIVE

**GREEN (2026-07-24).** All eight Phase-8 findings resolved by C1–C7, each with
the full freeze ritual and a RED→GREEN test; the board dropped every workaround
(branch `corrective-repin`) and **deployment #5 verified each in production**:

- F8-1 (C1) named `web.Status` 409/413/429/503 — on the wire.
- F8-2/F8-4 (C2) `web.set_header` + `web.bytes` — attachment **download** live
  with `Content-Disposition`.
- F8-6 (C3) `web.query_int_opt` — unfiltered list → 200 (the shipped bug's 400 gone).
- F8-5 (C4) `web.stream_live` — in the live SSE binary.
- F8-8 (C5) `pg.arg_timestamptz` + `validate.rfc3339` — `due_date` stored as
  `timestamptz` with no `::` cast; malformed → 400 not 500.
- F8-7 (C6) `Expect: 100-continue` honored — 5 MiB default-client upload → 201.
- F8-3 (C7) `web.request_state` — in the binary (see Gate 4).

Public ledger: application 80 + test-support 2 = union 82. Core `phase8`
`03c2bce`, crystals `corrective` `7c64d47`, board `corrective-repin` `c5e1dfd`.

## Gate 2 — Multi-host scale & robustness evidence

**OPEN.** The single 2-CPU/1.6 GiB VPS proved *correctness and leak-freedom* (soak
PASS: 4 h, RSS flat, errors=0) but not *capacity at scale*. Needs the stronger
hardware the owner offered. Deliverable: `planning/corrective-scale-report.md` —
the same suites on ≥2 host sizes, plus the owed demos: **3,000 concurrent
real-socket SSE**, an **hours-long soak with a shortened session TTL** (to cross
the expiry boundary the 24h-TTL soak could not), pool/lane saturation and the
deferred WP110 cells (network interruption, upload interruption, proxy misconfig)
on hardware that can generate the load. Pass = no unclassified failure + a stated
capacity/cost envelope. **Blocked on: owner-provided access to the larger VPS(s).**

## Gate 3 — Phase-8 operational thresholds

**PARTIAL.** MET: ≥5 immutable migrations (7, incl. backfill + expand/contract);
≥4h soak (PASS); dataset (5 projects / 600 tasks / 2400 comments / spooled
attachment); the drill set (kill, PG restart, graceful restart, malformed,
checksum-tamper). the **full WP110 drill set is now complete live** — upload interruption GREEN,
proxy misconfiguration GREEN (C-06 proven: buffering ON withholds SSE, OFF
forwards), network interruption found a real gap + shipped a `tcp_user_timeout`
mitigation (remote-DB validation → Gate 2); the **session-expiry boundary** the
soak could not cross is now exercised (drill 4/4); the intermediate **SSE capacity
point** (~300 streams, linear RSS / C-04) is recorded. OPEN: **≥10 deployments**
(**9 recorded** — an honest recount incl. the drill-fix cycles + the hardened-core
deploy; one real change away, accrues on the next deploy) and the remote-DB
partition validation (Gate 2).

## Gate 4 — Owner ratification of the ADR-028 amendment (C7)

**OPEN — owner decision.** C7 (`web.request_state`) reverses a *stated* principle
("there will not be one"). The design and the reversal are in
`planning/adr-028-amendment.md` with my **ADOPT** recommendation (narrow, typed,
type-checked, closes the measured auth-prologue cluster). This is the one
corrective change that is a philosophy call, not a gap fix, and the release cannot
tag with it in an unratified state. **Blocked on: owner confirming ADOPT or
REVERT** (C7 is built to roll back cleanly).

## Gate 5 — Pre-release hygiene: privacy, security re-scan, docs

**PARTIAL — my half DONE, privacy is the owner's.** The **targeted security
re-scan** of the new public surface is **DONE**
(`planning/corrective-security-review.md`): adversarial review of C1–C7 — no new
vulnerability, and `web.set_header`'s name is now hardened to a strict RFC 9110
token; the 14 prior findings stay pinned. **Docs:** every new symbol documented in
`docs/ai-context.md`; the capability matrix / non-capabilities updated (done); a
README positioning re-check for "microframework" (Gate 6 / G8-7). **Still OPEN:** a
**privacy review** before any real (non-synthetic) user data — the plan's standing
non-goal, owner-gated.

## Gate 6 — WP112 human condition + WP113 verdict + merge/tag

**OPEN — owner + human.** The WP112 **human** usability condition (a human
contributor implements the canonical tasks from public docs) — the agent
conditions are done (3/3 byte-identical convergence). The **WP113 verdict** is a
near-final draft (`planning/phase-8-verdict.md`); it flips from DRAFT to FINAL
when Gates 2/4/5 close. The **clean release step**: merge `phase8` → a release SHA
on `main` (core), `corrective` → `main` (crystals), `corrective-repin` → `master`
(board), re-pin the board to the merge SHAs, and **tag** — reserved to the owner's
explicit go, which this document gates.

---

## What I would need to move each open gate to GREEN

| Gate | Blocker | Who |
|---|---|---|
| 2 scale | SSH to the larger VPS(s) | owner provides; then me |
| 3 deploys | accrues via Gate 2 + operation | me (on hardware) |
| 4 ADR-028 | ADOPT / REVERT decision | owner |
| 5 hygiene | ~~scan (DONE)~~ + privacy review | owner (privacy) |
| 6 verdict/merge/tag | human WP112 + release go | owner |

**My standing recommendation:** the framework is **ready for a controlled
production pilot now** (behind a proxy with `proxy_buffering off`, a supervisor
with a kill timeout > `max_drain_time` and `LimitMEMLOCK=infinity`, a cgroup sized
by the C-04 rule). I will **approve a general release** only when Gates 2–6 are
green — that is the honest meaning of the quality bar the owner delegated.
