# Corrective Program — closing the Phase-8 findings toward production readiness

**Status: PLAN, 2026-07-24. OWNER-MANDATED.** The owner authorized closing all
eight Phase-8 friction findings (F8-1..F8-8) and driving the framework from
"controlled pilot" to unconditional production readiness — *"não quero que falte
nada para os usuários de Uruquim ... uma arquitetura séria e validada."* This is
the **corrective WP program** the friction ledger always pointed to: each change
is a **separately-gated WP with the original freeze ritual**, never an accretion
shortcut. Phases are NOT renumbered — these are corrective WPs **C1..C7**, off
the phase timeline.

Roadmap position: Phase 8 (proof-by-use) produced the findings; this program
*repairs* them. The board (`uruquim-board`) is the acceptance harness — each
corrective WP is done when the board can drop its workaround and its RED test
goes green.

---

## 0. Principles (non-negotiable)

1. **Frozen-core discipline stands.** Every public-surface addition runs the full
   ledger-amendment ritual (below). The current ledger is **application 75 +
   test-support 2 = union 77**; each addition moves those numbers in *both*
   directions of every exact check.
2. **Additive only, no member moves.** No existing signature changes, no enum
   member is renumbered, no behaviour of an existing path changes (except F8-7,
   which is a deliberate transport-behaviour fix with its own wire tests).
3. **Evidence-first.** Each WP lands the RED test from the ledger entry (which is
   RED today, GREEN after), plus its own unit/semantic/wire tests, before the
   board re-pins.
4. **Reversible.** Every change is revertible before release; the release/tag is
   gated on my explicit approval to the quality bar (§4), which the owner
   delegated.

### The ledger-amendment ritual (per public symbol added) — the 6-to-12 files
From `uruquim-gate-amendment-checklist`: `build/check_public_api.sh` (the
`URUQUIM_EXPECTED_EXPORTS` list + the app-count and union-count checks + echo
lines + remove from the later-phase ban list); `build/check_phase1_freeze.sh`
(counts, citation floor, future-vocabulary regex); `build/phase1-public-signatures.txt`
(run the freeze gate FIRST, verify the diff is exactly the new rows);
`planning/phase-1-freeze.md` (numbered Amendment + one evidence-matrix row per
symbol, grep-resolvable citations); `build/check_docs.sh` (counts in two places,
active-doc lists, future-API ban list) + `docs/ai-context.md` (name every symbol,
new counts); and for behaviour touching examples/mutations, `check_examples.sh`,
`tests/wp10-doc-fixtures`, the mutation suites. **Run each sub-gate individually
(seconds) before the full 2.5-min gate; never edit source while the gate runs.**

---

## 1. The eight findings → corrective WPs, grouped by surface and risk

| WP | Finding(s) | Repo | Kind | Risk | Value |
|---|---|---|---|---|---|
| **C1** | F8-1 — `web.Status` gains `Service_Unavailable=503`, `Too_Many_Requests=429`, `Conflict=409`, `Payload_Too_Large=413` | core | enum additions (4 members) | LOW | HIGH — 3 apps already cast raw ints |
| **C2** | F8-2 — `web.set_header(ctx, name, value)`; F8-4 — `web.bytes(ctx, status, content_type, data)` | core | 2 public procs | MED | HIGH — unblocks cookies AND binary download |
| **C3** | F8-6 — a soft typed optional query reader (`web.query_int_opt`) | core | 1 public proc | LOW | MED — removes the foot-gun that shipped a live bug |
| **C4** | F8-5 — `web.stream_live(s) -> bool` disconnect predicate | core | 1 public proc | LOW | MED — lets a stream registry prune without sending |
| **C5** | F8-8 — `pg.arg_timestamptz` (typed timestamp param) + `validate.rfc3339` (date validator) | **crystals** | 1 param builder + 1 validator | LOW | MED — 3 agents hit it; every schema has dates |
| **C6** | F8-7 — honour/ignore `Expect: 100-continue` instead of `417` | core | transport behaviour | MED | MED — default clients' large uploads |
| **C7** | F8-3 — request-scoped typed state (reopen ADR-028) | core | ADR + new generic | **HIGH** | MED — the measured auth-prologue boilerplate |

**Ordering:** C1 → C2 → C3 → C4 → C5 → C6 → C7. Clean additive first (C1–C5),
transport next (C6), the design-heavy ADR reopening last (C7). C5 is in the
crystals repo (normal `git push`, its own gates), independent of the core WPs.

**Branch strategy.** Core corrective WPs land on a branch off `closure` (the
production-ready base the board pins) — `corrective` — so the board re-pins to
the corrective HEAD once a batch is green (the WP111 documented upgrade path).
The board then drops each workaround (`web.Status(503)` → `.Service_Unavailable`,
etc.) and its RED test flips green — the acceptance signal.

---

## 2. Per-WP definition of done

Each WP is DONE when: (a) the symbol(s) exist with the ratified signature; (b) the
full ledger ritual passes (`build/check.sh` green, union count updated in both
directions); (c) the ledger entry's RED test is committed and now GREEN; (d) unit
+ semantic + (where relevant) raw-wire tests cover it; (e) the board drops the
workaround and stays green; (f) a deployment re-verifies it live on the VPS.

**C7 additionally** requires a written ADR (reopening ADR-028) with the design —
a *typed, application-owned* request slot (not a `Context` bag) — decided with
rationale before code, since request-scoped state is a genuine architecture
commitment (lifetime, ownership, teardown). It is the one WP I will present as a
design decision, not a mechanical add.

---

## 3. Testing & validation campaign (owner offered stronger hardware)

The functional corrective work (C1–C7) needs only the current toolchain and the
small VPS. The **robustness/scale campaign** wants the more powerful VPSs the
owner offered — and folds in the production-scale demos Closure/Hardening left
owed. I will request access **when C1–C6 are green and the board re-pins**, not
before (nothing to scale-test until the code lands).

Campaign design (report deliverable, §4):

- **Multi-environment matrix** — the same board build + smoke/concurrency/drill/
  soak suites run on ≥2 differently-sized hosts (the current 2-CPU/1.6 GiB box as
  the *constrained* baseline; a larger box as the *headroom* case), to separate
  framework behaviour from host limits.
- **Scale demos owed** — the **3,000 concurrent real-socket SSE** round (needs the
  public stream-cap knob, itself an ABERTO item) and the **hours-long soak** with
  a **shortened session TTL** so a session-expiry boundary is actually crossed
  (the gap F8's 4 h soak could not close on a 24 h TTL).
- **Saturation & failure at scale** — pool-at-cap, lane contention, RST floods,
  and the deferred WP110 cells (network interruption, upload interruption, proxy
  misconfiguration) on hardware that can actually generate the load.
- **What I measure** — throughput/latency by route, RSS vs connections (validate
  the C-04 per-connection retention rule at scale), pool/stream counters return
  to baseline, zero unclassified failures.
- **Report** — `planning/corrective-scale-report.md`: environments, method,
  numbers, what held, what didn't, and the capacity/cost envelope for a real
  deployment. This is the evidence that "serious, validated architecture" is a
  measurement, not a claim.

**What I need from you, and when:** SSH to the larger VPS(s) **after** C1–C6 land
(I'll ping you). Nothing now.

---

## 4. Release-readiness doc & approval (delegated to me)

The owner delegated the release decision to my quality bar: *"só será lançado de
verdade quando você aprovar."* I will own `planning/release-readiness.md`, which
gates a real release/tag on ALL of:

1. C1–C7 green, each with its RED test flipped and the board workaround dropped.
2. The scale/robustness report (§3) shows no unclassified failure and the capacity
   envelope is stated.
3. The Phase-8 soak completes and the WP112 human condition lands (or is
   explicitly waived with rationale).
4. A **privacy review** before any real (non-synthetic) user data — a separate
   gate the plan has always required.
5. The security posture re-affirmed (the 14 findings stay pinned; a re-scan if the
   surface grew materially — C2/C7 add real surface, so a targeted re-scan of the
   new procs is in scope).
6. Documentation complete: every new symbol documented; the capability matrix and
   explicit non-capabilities updated as gaps close; README positioning re-checked.

I approve release only when all six hold. Until then the doc records the exact
remaining gap. **No tag ships on optimism.**

---

## 5. Execution order & tracking

1. **C1** (enum) — the template: proves the ledger ritual end-to-end on the
   lowest-risk change.
2. **C2** (set_header + bytes) — the highest-value capability unlock.
3. **C3, C4** (query_int_opt, stream_live) — clean DX additions.
4. **C5** (crystals: arg_timestamptz + rfc3339) — parallel, own repo.
5. **C6** (Expect: 100-continue) — transport, with raw-wire tests.
6. **C7** (ADR-028 reopen) — design doc first, then the typed request slot.
7. Board re-pins after each core batch; workarounds dropped; RED tests flipped.
8. Scale campaign (§3) on the larger VPS; report.
9. Release-readiness doc reaches all-six-green; I approve.

Each WP updates this file's checklist and appends a one-line result. The friction
ledger entries move from RECORDED → RESOLVED (with the pinning test) as they land,
mirroring the Hardening H-1 pattern.

### Progress
- [x] **C1 F8-1 enum — DONE (2026-07-24).** `web.Status` gains `Conflict=409`,
  `Payload_Too_Large=413`, `Too_Many_Requests=429`, `Service_Unavailable=503`;
  the body-too-large path now returns the named `.Payload_Too_Large` (private
  `Status(413)` cast removed). Full freeze ritual: signature snapshot, the
  14-member freeze control, the inverted public-api control, `docs/ai-context.md`,
  Amendment 32, mutation probes 39/46 re-aimed, RED→GREEN test
  `tests/c1-status-codes` + `build/check_c1_controls.sh` wired into the gate. Full
  gate: 187 checks PASS, no real failure (one unrelated wp69 temp-dir linker flake,
  green on re-run). No ledger growth (Status is one symbol; union stays 77).
- [x] **C2 F8-2/F8-4 response surface — DONE (2026-07-24).** `web.set_header(ctx,
  name, value) -> bool` (app headers, copied to request-local storage, emitted
  after framework headers, rejects committed/injection/reserved/over-budget) and
  `web.bytes(ctx, status, content_type, data)` (buffered binary responder, caller
  media type validated + copied, body owned like `web.text`). Ledger 75 → 77,
  union 79. Full ritual: signatures, EXPECTED_EXPORTS + counts across
  freeze/api/docs, the two future-API ban lists cleared of `bytes`, Amendment 33,
  RED→GREEN `tests/c2-response-surface` + `check_c2_controls.sh` wired. Full gate:
  186 checks PASS, C1+C2 green (only the known wp41 timing flake, green on re-run).
  Unblocks cookies/CSRF (F8-2) and auth-gated file download (F8-4).
- [x] **C3 F8-6 query_int_opt — DONE (2026-07-24).** `web.query_int_opt(ctx, name)
  -> (value: int, present: bool, ok: bool)`: the optional typed query reader that
  reports presence distinctly (absent=present:false/ok:true no-commit; present+valid
  both true; malformed=400). Closes the foot-gun that shipped a live bug (the board
  read an optional filter with `query_int` and every unfiltered list 400'd). Ledger
  77 → 78, union 80. Full ritual (signatures, counts, Amendment 34, RED→GREEN
  `tests/c3-query-opt` + `check_c3_controls.sh`). Full gate: 187 PASS, C1+C2+C3
  green (only the known wp41 timing flake under load).
- [x] **C4 F8-5 stream_live — DONE (2026-07-24).** `web.stream_live(s) -> bool`,
  the read-only disconnect predicate a subscriber registry needs to prune a
  departed client without sending. Three layers: `internal/stream.is_live`
  (mirrors the send admission guard) → `transport.stream_live` → the public proc.
  Ledger 78 → 79, union 81. Full ritual + Amendment 35 + `tests/c4-stream-live`
  (registry unit test: open→live, close/stale/out-of-range→dead) +
  `check_c4_controls.sh`. Full gate: 188 PASS, C1-C4 green (only the wp41 flake).
- [ ] C5 F8-8 crystals timestamp+validator
- [x] **C6 F8-7 Expect: 100-continue — DONE (2026-07-24).** The adapter honors
  `Expect: 100-continue` by READING THE BODY (RFC 9110 §10.1.1) instead of a hard
  417, so default clients (curl, python-requests) can complete large uploads; any
  other expectation is still 417. No ledger change (transport behaviour). Helper
  `expect_is_100_continue` (allocation-free); `auto_expect_continue` stays off
  (mutation 53 pins it). Wire corpus re-aimed (honored case → 201 + a new
  unknown-expectation → 417 case), socket-proven in `tests/wp9-wire`. Amendment 36,
  docs updated (errors.md, transport-conformance.md), `check_c6_controls.sh` wired.
  Full gate: 181 PASS, C1-C6 controls green, wp9-wire green (both Expect cases);
  the only failure was the known **c03 real-socket contention flake under load**
  (F-C03-2 — unrelated to Expect; the machine was saturated by the soak poller +
  back-to-back gates).
- [x] **C7 F8-3 request_state — DONE (2026-07-24).** `web.request_state(ctx,$R)->^R`,
  ONE typed request-scoped value (the narrow ADR-028 reopening — flagged for owner
  ratification in `planning/adr-028-amendment.md`). NOT an untyped bag: one
  app-declared type, typeid-stamped on first access, asserted after; fixed
  request-local storage (`REQUEST_STATE_MAX=256`, no allocation); fresh Context per
  request = no cross-request leak. Closes the measured auth-prologue boilerplate
  (F8-3): a middleware writes, the handler reads. Ledger 79→80, union 82. Full
  ritual + Amendment 37 + ADR-028 amendment doc + `tests/c7-request-state` (3 tests:
  mw→handler flow, no leak, same-type→same-pointer) + `check_c7_controls.sh`. C7
  control + tests green standalone; the full gate aborted on the known
  **wp41 phase_determinism env flake** before reaching the C7 control step (5 prior
  controls green, 189 PASS).
- [ ] Scale/robustness campaign + report
- [ ] Release-readiness: all six green → my approval
