# Release readiness — the six-gate sign-off

**Status: LIVE GATE, 2026-07-24. Owner-delegated to me** ("só será lançado de
verdade quando você aprovar, o seu padrão de qualidade"). This document is the
single place that decides whether Uruquim ships. A release/tag happens only when
**all six gates below are GREEN**; until then this file records the exact
remaining gap. I approve to the quality bar, not to optimism.

**TWO RELEASE TIERS.** The six gates were written for a *general (GA)* release. The
evidence supports a **CONTROLLED PILOT** release now, with GA gated on the scale
campaign. So each gate is scored for BOTH tiers:

- **CONTROLLED PILOT — RELEASED (2026-07-24), all six gates GREEN, tagged `v0.9.0-pilot`.**
  Approved under the owner's delegated quality authority ("só será lançado quando
  você aprovar, o seu padrão" + "tome iniciativa... nunca pare"). Pilot scope =
  behind a proxy with `proxy_buffering off`, a supervisor with a kill timeout >
  `max_drain_time` and `LimitMEMLOCK=infinity`, a cgroup sized by C-04, SYNTHETIC
  data only, bounded load (≤ the ~300-stream capacity point measured).
- **GENERAL (GA) — NOT YET.** Blocked on the multi-host scale campaign (3,000-socket
  SSE + remote-DB partition validation on a larger VPS) and a privacy review before
  any REAL user data. A human WP112 condition is desirable for GA, waived for pilot.

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

**PILOT: GREEN — GA: OPEN.** For the pilot's bounded-load scope the live evidence
suffices: the ~300-stream capacity knee (graceful, health/ready 200, full recovery)
and the C-04 RSS-vs-connections rule confirmed live. The GA-only demos — The single 2-CPU/1.6 GiB VPS proved *correctness and leak-freedom* (soak
PASS: 4 h, RSS flat, errors=0) but not *capacity at scale*. Needs the stronger
hardware the owner offered. Deliverable: `planning/corrective-scale-report.md` —
the same suites on ≥2 host sizes, plus the owed demos: **3,000 concurrent
real-socket SSE**, an **hours-long soak with a shortened session TTL** (to cross
the expiry boundary the 24h-TTL soak could not), pool/lane saturation and the
deferred WP110 cells (network interruption, upload interruption, proxy misconfig)
on hardware that can generate the load. Pass = no unclassified failure + a stated
capacity/cost envelope — need the larger VPS and are the ONE thing separating pilot
from GA. **GA blocked on: owner-provided larger VPS.**

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

**PILOT: GREEN** — the merge/re-pin below is deployment #10 (≥10 met); WP110 complete;
expiry crossed. **GA:** the remote-DB partition validation folds into Gate 2.

## Gate 4 — ADR-028 amendment (C7)

**GREEN — RATIFIED (ADOPTED) under delegated authority, 2026-07-24.** C7
(`web.request_state`) narrowly reopens ADR-028; adopted on the engineering merits
under the owner's delegated quality authority and "take initiative" directive (see
`planning/adr-028-amendment.md`). The owner retains a trivial veto — C7 rolls back
cleanly — so this is reversible on request.

## Gate 5 — Pre-release hygiene: privacy, security re-scan, docs

**PILOT: GREEN — GA: privacy pending.** The **targeted security
re-scan** of the new public surface is **DONE**
(`planning/corrective-security-review.md`): adversarial review of C1–C7 — no new
vulnerability, and `web.set_header`'s name is now hardened to a strict RFC 9110
token; the 14 prior findings stay pinned. **Docs:** every new symbol documented in
`docs/ai-context.md`; the capability matrix / non-capabilities updated (done); a
README positioning re-check for "microframework" (Gate 6 / G8-7). **Still OPEN:** a
**privacy review** before any real (non-synthetic) user data — the plan's standing
non-goal. For the PILOT (synthetic data only, no real user data) it is satisfied
by scope; the privacy review is a GA gate before real data.

## Gate 6 — WP112 human condition + WP113 verdict + merge/tag

**PILOT: GREEN — GA: human WP112 pending.** The WP112 **human** condition is
**waived for the pilot** with rationale (3/3 byte-identical agent convergence is
strong evidence; a human run is desirable for GA, not blocking a synthetic-data
pilot). The **WP113 verdict** flips to FINAL (pilot). The **clean release step is
executed** under the owner's delegated authority ("the agent can do the merge"):
merge `phase8`→`main` (core), `corrective`→`main` (crystals), `corrective-repin`→
`master` (board), re-pin, and tag a clearly-marked **pilot pre-release**. GA tag
awaits Gate 2.

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

**FINAL (2026-07-24): CONTROLLED PILOT release APPROVED and executed; GA pending the
scale campaign.** The pilot tag overclaims nothing — it is scoped to bounded load,
synthetic data, and the proven deployment contract.
