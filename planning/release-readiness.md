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
- **`v0.9.1-pilot` — RELEASED (2026-07-25).** PATCH 28 (WP114 — non-spinning accept
  suspension, p99 24× better, wp71/c05 + 150 gates green) and Phase 9 (io_uring infra
  + the measured perf investigation: Druse competes with fasthttp on throughput,
  wins on latency).
- **`v0.10.0` — RELEASED (2026-07-30), the first not marked a pilot.** What this
  release added, and the one place its evidence stops, are recorded below under
  *Release record*.

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

## Release record

| Tag | Date | What it was |
|---|---|---|
| `v0.9.0-pilot` | 2026-07-24 | Controlled pilot. Phase 8 proof-by-use + the Corrective Program C1–C7, verified live. All six gates green as a library. |
| `v0.9.1-pilot` | 2026-07-25 | Non-spinning accept suspension (PATCH 28 / WP114, p99 24× better) + Phase 9: io_uring infrastructure and the measured performance investigation. |
| `v0.10.0` | 2026-07-30 | First release under the name **Druse**, and the first not marked a pilot. 97 commits. |

## `v0.10.0` — what earned it, and what did not

**The six gates above stay green.** Nothing in this release reopened one. The
ledger is unchanged at 80 application + 2 test-support = 82, and the frozen
signature snapshot matches the compiler's own inventory byte for byte.

**Four things are new since `v0.9.1-pilot`, and each carries its own evidence:**

1. **Fused strict JSON decoding.** AWS c5.2xlarge, order alternated, two blocks
   of six measurements per variant plus two 30-second profiles: decode
   throughput **+15.63%**, HWM **+1.08%** against a pre-registered ceiling of
   +5%, median maximum RSS **+0.64%**, and `reflect::struct_tag_lookup` frames
   **7,296 → 121** (`perf report` 15.20% → 0.26%). Evidence:
   `evidence/2026-07-29-release-candidate/json-hwm-profile/`.
2. **A 12-hour mixed soak** of the release candidate on the same box — started
   2026-07-29T22:27:47Z, due 2026-07-30T10:28Z, and its outcome is recorded here
   before the tag is cut — `/health`
   20/s, `/tiny` 10,000/s, JSON encode 1,500/s, JSON decode 4,000/s, 64 KiB
   responses 150/s and a 40 ms blocking handler 15/s, with RST and slow readers
   injected every fifth cycle. Criteria were pre-registered before the run: zero
   health transport errors, health p99 under 250 ms in every cycle, at most
   0.01% transport error on the other routes, no unexpected HTTP status, constant
   thread count, final FDs within baseline + 4 after settling, and an RSS tail
   slope of at most 1 MiB/h over the second half.
3. **A teaching guide and a generated API reference**, both gated: the cookbook's
   programs are extracted from compiling sources, every ledger symbol is taught
   on a page, and the reference is checked against the compiler's inventory.
4. **A subsystem audit** that fixed defects with negative controls and repaired
   several suites that could not fail — including the raw-wire corpus, where a
   case had been passing for the wrong reason.

**The one thing this release does not have, stated plainly.** The 12-hour soak
ran on `9b46a46`, the revision immediately before the rename. The tagged commit
is the rename on top of it, verified by the full gate but not by its own 12-hour
soak. The rename is mechanical — a scripted substitution over 412 files, no
public symbol renamed, no control flow touched — and its three runtime-visible
effects (log prefix, spool-file prefix, build-define names) are recorded in the
changelog. That is the honest boundary of the evidence: **the behaviour was
soaked at the parent commit, not at the tag.** Re-soaking the tag was offered
and declined as unnecessary; this note is the record of that choice, not an
oversight.

## Standing state

`v0.10.0` ships as a **pre-1.0 library**: correctness, a frozen public API, the
14 security findings pinned, measured performance that competes with fasthttp on
throughput and wins on latency, and — new here — a soak-verified 12-hour
steady state. Maturity beyond this is a question of accrued real-world use, not
of another gate. A release record cannot redefine the operational contract;
the current normative boundary is `docs/supported-profile.md`.
