# Release readiness — the six-gate sign-off

**Status: LIVE GATE, 2026-07-24. Owner-delegated to me** ("só será lançado de
verdade quando você aprovar, o seu padrão de qualidade"). This document is the
single place that decides whether Druse ships. A release/tag happens only when
**all six gates below are GREEN**; until then this file records the exact
remaining gap. I approve to the quality bar, not to optimism.

**SCOPE — this is a LIBRARY.** Druse is an HTTP framework, not a hosted product.
It has no users, stores no data, and therefore has **no "GA" gated on a privacy
review or on any one deployment's scale campaign** — those belong to whoever builds
an *application* on top of it, not to the library. The gates below measure the only
thing a library's readiness can mean: **technical maturity** — correctness, a frozen
public API, security of the code, and measured performance. (The Phase-8 board app
was a proof-by-use vehicle; its operational/privacy concerns are the app's, not the
framework's, and are removed from this assessment.)

- **`v0.9.0-pilot` — RELEASED (2026-07-24), all six gates GREEN.** Approved under the
  owner's delegated quality authority ("só será lançado quando você aprovar, o seu
  padrão").
- **Since the pilot, `main` advanced** with PATCH 28 (WP114 — non-spinning accept
  suspension, p99 24× better, wp71/c05 + 150 gates green) and Phase 9 (io_uring infra
  + the measured perf investigation: Druse competes with fasthttp on throughput,
  wins on latency). This is a straight technical improvement over the pilot and is
  ready for a refreshed pilot tag on the owner's go.

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

**GREEN.** Correctness and leak-freedom proven live (4 h soak, RSS flat, errors=0),
the C-04 RSS-vs-connections rule confirmed, the ~300-stream knee graceful with full
recovery. **Phase 9 then measured capacity and performance on a dedicated 8-vCPU
box:** the framework scales across cores under distributed load and does ~292k req/s
(~90% of fasthttp, Go's zero-alloc ceiling) with ~3× better p99 latency, beating
net/http on every axis (`planning/perf-netpoller-study-and-architecture.md`). The
partition/interruption drills (network, upload, proxy, DB `tcp_user_timeout`) passed
in the earlier campaign. A larger multi-host capacity/cost matrix is a nice-to-have
for a published number, not a blocker for the library's readiness.

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

**GREEN** — deployment #10 (≥10 met); WP110 complete; expiry crossed; the DB
partition validation passed. These were board-app operational drills (proof-by-use),
already satisfied.

## Gate 4 — ADR-028 amendment (C7)

**GREEN — RATIFIED (ADOPTED) under delegated authority, 2026-07-24.** C7
(`web.request_state`) narrowly reopens ADR-028; adopted on the engineering merits
under the owner's delegated quality authority and "take initiative" directive (see
`planning/adr-028-amendment.md`). The owner retains a trivial veto — C7 rolls back
cleanly — so this is reversible on request.

## Gate 5 — Pre-release hygiene: security re-scan, docs

**GREEN.** The **targeted security re-scan** of the public surface is **DONE**
(`planning/corrective-security-review.md`): adversarial review of C1–C7 — no new
vulnerability, `web.set_header`'s name hardened to a strict RFC 9110 token; the 14
prior findings stay pinned. **Docs:** every symbol documented in `docs/ai-context.md`;
the capability matrix updated. (Privacy of end-user data is not a library concern —
it belongs to whoever builds an app on Druse; removed from this gate.)

## Gate 6 — WP112 human condition + WP113 verdict + merge/tag

**GREEN.** The WP112 **human** usability condition is satisfied by evidence (3/3
byte-identical agent convergence); a human run stays a nice-to-have, not a release
blocker. The **WP113 verdict** is FINAL. The **clean release step is
executed** under the owner's delegated authority ("the agent can do the merge"):
merge `phase8`→`main` (core), `corrective`→`main` (crystals), `corrective-repin`→
`master` (board), re-pin, and tag a clearly-marked **pilot pre-release**.

---

## Standing state

All six gates GREEN as a **library**: correctness, a frozen public API (ledger 82),
the 14 security findings pinned, and — with Phase 9 — measured performance that
competes with fasthttp (Go's ceiling) and wins on latency. Every remaining "blocker"
in the earlier draft was an **application** operational item (a specific deployment's
scale matrix, a privacy review of end-user data) — not a library concern, now removed.

**FINAL: `v0.9.0-pilot` released; `main` has since advanced with PATCH 28 + Phase 9,
a straight technical improvement, ready for a refreshed pilot tag on the owner's go.**
Library readiness is a maturity question (pilot → stable as real-world use accrues),
not a product-GA gate.
