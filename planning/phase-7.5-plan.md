# Phase 7.5 — composition, hardening, and the deferred surfaces (pre-Phase-8 corrective)

**Status: DRAFT PLAN, 2026-07-23.** Owner-directed after the Phase-7 freeze:
combine three otherwise-separate tracks into one corrective phase between the
Phase-7 freeze and Phase 8, because **Phase 8 as written is blocked** — two of
its entry conditions are unmet — and two of the gaps sit exactly on the owner's
stated use case (thousands of simultaneous SSE connections).

This is a **plan only**. No code is authored under it until the owner says to
ship; artifacts stay working files.

---

## 0. Why this phase exists — the blocked entry conditions

`planning/phase-8-plan.md` §3:

- **E8-7** requires the Phase-7 **composition Crystals frozen**: `http_client`
  (outbound HTTP/1.1 with TLS + certificate verification) and `metrics`
  (Prometheus exposition). **Neither exists.** They were "the Crystals half of
  Phase 7" that was to run in parallel; only the SSE Crystal (WP97) shipped.
- **E8-2** requires "large-body ingestion and the large-transfer vertical slice
  green." The slice is green but uses the **buffered** upload path; the
  large-body **public upload API is deferred** (substrate-only — the spool and
  fragmentation-invariant multipart parser are built and tested internally, but
  nothing wires them into the request path).

`http_client` is additionally the **P0** of the production-readiness audit
(`production-readiness-audit-2026-07-23`) and the "outbound gap" that started
the composicional-BOM analysis. Phase 8's reference app must make "one real
outbound call" (E8-7), so `http_client` is a hard prerequisite, not a nicety.

**Entry:** Phase 7 frozen (`planning/phase-7-freeze.md`).
**Exit:** E8-2 and E8-7 satisfiable; the Phase-8 refresh (WP102) can begin.

---

## 1. Scope decisions taken up front (so a WP does not relitigate them)

- **F-001 is NOT open work.** The negative-chunk-size DoS the security report
  named is already fixed on `main` by vendored **patch 14 (F3)**
  (`vendor/odin-http/body.odin`: `if !ok || size < 0`). What remains is a minor
  integer-overflow hardening on the `builder_len + size > max_length` compare
  (fold into Track B, not a WP of its own).
- **TLS is FFI, not vendored crypto.** `libssl.so.3` / `libcrypto.so.3` are
  present system libraries; the client binds them via `foreign import`, the
  same pattern the PostgreSQL crystal uses for `libpq`. No crypto is written.
- **The `http_client` bridge decision is A1's to make, with a recommendation on
  the table:** `laytan/odin-http` upstream ships a tested HTTP/1.1 **client**
  and an **OpenSSL** binding (`client/`, `openssl/` — deliberately omitted when
  the server was vendored). The recommended path is to **vendor those two trees
  as a BRIDGE** (mirroring the server side under ADR-033, whose declared exit is
  the future `core:net/http` client, Jan 2027) and wrap them in the bounded /
  cancellable / drain-integrated / pool-limited contract the BOM requires —
  rather than reimplement HTTP/1.1 + TLS from scratch over `core:net`. A1
  records the choice with its rationale and the vendor-policy row.
- **Concurrency follows the recorded guidance** (`odin-outbound-concurrency-
  guidance`): non-blocking I/O + event loop (`core:nbio`) OR a small hard-capped
  worker pool with a typed `Full`; never thread-per-task, never an unbounded
  queue. Retry + backup is **at-least-once**, stated honestly. Deadline /
  cancellation is manual (no `context.Context`), tied to drain.

---

## 2. Work packages

Three tracks. **A is the E8-7 blocker (highest priority) and independent of B/C.
C needs vendored-backend work like WP90. B runs when a quiet machine is
available for the 3,000-socket round.**

### Track A — Composition Crystals (`druse-crystals`), unblocks E8-7

| WP | Name | Type | Deliverable |
|---|---|---|---|
| **7.5-A1** | `http_client` contract + bridge decision + RED | SPEC + TESTS | The contract (bounded pool, per-request + connect timeouts, deadline budget, cancellation on drain, bounded retry = at-least-once, outbound TLS with **real** certificate verification as an inseparable part). The vendor-bridge decision (recommend: vendor upstream `client/`+`openssl/` as BRIDGE) with its vendor-policy row. RED tests against a sentinel: connect/timeout/refusal, pool exhaustion typed `Full`, cancellation, and a TLS cert-verification failure that must REFUSE (a bad/self-signed cert is not "worked"). |
| **7.5-A2** | `http_client` over the bridge | IMPLEMENTATION | Connect, send request, read response; bounded connection pool with a typed exhaustion result; per-connect and per-request timeouts; explicit close/drain cancellation. Plaintext (`http://`) path first, green against a local origin. |
| **7.5-A3** | Outbound TLS + certificate verification | IMPLEMENTATION | `https://` over the OpenSSL binding: SNI, hostname + chain verification against the system trust store, a verification FAILURE that refuses (proven against a self-signed / wrong-host cert), TLS handshake under the same timeout budget. **Never promised separately from the client.** |
| **7.5-A4** | `metrics` Prometheus exposition | IMPLEMENTATION | A Crystal that renders the existing observer counters as Prometheus text over an ordinary handler/route; the WP20 redaction rules preserved (route pattern, never path; no request-derived bytes). Bounded output; one canonical exposition format. |
| **7.5-A5** | Composition freeze + BOM reclassification | FREEZE + DOCS | Freeze `http_client` and `metrics` in `druse-crystals` (ledgers, gate, `docs/`); reclassify both in `production-service-bom.md` ABERTO/candidate → **CRYSTAL** with the evidence that fired the trigger; confirm no unclassified / trigger-less-ABERTO item remains. **This is the E8-7 satisfaction.** |

### Track B — Hardening for SSE at scale — MOVED TO THE CLOSURE

**Superseded, 2026-07-23.** The hardening items (RST-flood liveness wedge, the
memory/soak work, the chunked-`max_length` overflow residue) **moved into the
Production Readiness Closure** (`planning/production-readiness-closure.md`,
C-03/C-04), because they are review-by-resource findings, not feature work — the
same kind of systemic gap the write deadline was. The one item kept flexible is
the **3,000 real-socket SSE round** (a G7-6 wire proof): run it once, wherever a
quiet CI machine first becomes available; it is referenced in both plans and
must not be run twice. Phase 7.5 therefore narrows to the two feature tracks
below (A and C).

### Track C — Public large-body upload (core `druse`), closes E8-2

| WP | Name | Type | Deliverable |
|---|---|---|---|
| **7.5-C1** | Inbound streaming hooks (vendored) | IMPLEMENTATION | The WP90 **inbound** half deferred with WP94: pause/resume of socket reads by spool/consumer capacity, stop-reading and retire/cancel on early refusal, surfacing bounded inbound chunks without materializing the whole body. Numbered BRIDGE patches in the vendor ledger, deletable with the adapter. |
| **7.5-C2** | Public opt-in upload API | IMPLEMENTATION | The public contract wiring `web/internal/ingest` (spool + streaming multipart, already built) into the request path: the smallest surface that expresses "consume this large body to an owned spool" and hands the Handler an explicitly owned upload resource, with the §4.2 quotas/cleanup enforced. Pays the ledger/gate-amendment checklist; frozen in a later WP or Phase-8 entry. |
| **7.5-C3** | Vertical slice on the real spool | TESTS | Upgrade the WP99 slice: the upload goes through the **spool** path (a body larger than `max_body`), quota/metadata/persistence-transfer validated explicitly, then the streaming download — proving both directions compose over the now-public contracts. Closes the E8-2 gap the buffered slice left. |

---

## 3. Ordering and exit

```text
Phase-7 freeze
  ├─ Track A: A1 → A2 → A3 → A4 → A5   (E8-7)      [crystals repo; start here]
  ├─ Track B: B1(+B3) → B2             (hardening) [core; B2 needs a quiet box]
  └─ Track C: C1 → C2 → C3             (E8-2)      [core; vendored-backend work]

{A5, C3} → Phase 7.5 exit → Phase 8 refresh (WP102) may begin
```

Track A is the immediate priority (it is the hard Phase-8 gate and the P0
production blocker). B and C proceed as capacity allows; B2's 3,000-real-socket
round is the one item explicitly gated on a quiet CI machine.

**Exit condition:** the composition Crystals are frozen (E8-7), the public
large-body upload ships with its vertical slice green (E8-2), the RST-flood
wedge is closed, and the full core gate plus the crystals gate are green. Then —
and only then — Phase 8 (`planning/phase-8-plan.md`, WP102–113) refreshes and
begins.

---

## 4. Rollback

Every track is additive and independently revertible. Track A ships in the
Crystals repo (zero core change; CE-E3). Track B's wedge fix and C's inbound
hooks are BRIDGE patches to the vendored backend, deletable at the
`core:net/http` transition. The public upload API (C2) is the one frozen public
surface once shipped; until then, uploads remain buffered under `max_body`,
exactly as they are today.
