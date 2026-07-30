# Phase 6.5 — Operational table stakes (corrective, pre-Phase-7)

**Status: PROPOSED, 2026-07-23, from the production-readiness audit.** A short
corrective phase between the Phase-6 freeze and Phase 7. It closes the P0/P1
operational gaps that are **not** streaming, so Phase 8 (proof-by-use) does not
discover them by accident. Work packages **WP-6.5.1 … WP-6.5.6** (kept out of the
WP85+ Phase-7 numbering deliberately).

## Why this phase exists

The audit verdict is `PRONTO_PARA_PILOTO_CONTROLADO`: the HTTP engine is solid,
but the operational edge blocks a real microservice. Three P0 items and several
P1 items are not streaming and not composition — they are the boring, load-bearing
operational stakes a production server must have. Doing them now, against the
frozen Phase-6 core, is cheaper and safer than discovering them mid-Phase-8.

## Entry conditions

- Phase 6 frozen (core at `f51fc127`; `origin/main` past it).
- ADR-037, ADR-039, ADR-040 ratified (client-IP, timeouts, shutdown). The rest of
  the ADRs (038/041/042/043) inform but do not block the code.

## Non-goals

Response streaming, large-body spool, SSE, the outbound `http_client` Crystal,
the `metrics` Crystal — all Phase 7. This phase adds **no** new subsystem, only
closes gaps in existing ones.

## Work packages

### WP-6.5.1 — F4: client-IP resolution (ADR-037) — **P0, first**
Change `client_ip` (`web/client_address.odin:150`) to walk `X-Forwarded-For`
from the right, discarding trusted-prefix hops, returning the first untrusted
address (or the peer if all trusted). Update `tests/wp48-public-surface` — its
current assertions encode the buggy leftmost behaviour and must move. Deliberate
compatibility break; the ADR is the record. **Rollback: LOW once shipped.**

### WP-6.5.2 — write and idle timeouts (ADR-039) — **P1**
**DELIVERED BY PHASE 7's WP90 (2026-07-23), not by this phase.** The 6.5
attempt was implemented but not merged: its write deadline never observably
fired. WP90, rewriting the same vendored transport path for streaming, landed
both fields in one `Limits` amendment with the root cause fixed (the graceful
close flushed kernel buffers to the slow reader, hiding the deadline — the
shipped enforcement aborts with RST) plus the send-cancellation memory-safety
fix. G6.5-2 is satisfied by `tests/wp90-deadlines` on the raw wire; ADR-039 is
ACCEPTED. Original scope kept below for the record:
Add `max_write_time` and `max_idle_time` to `Limits` (0 = disabled). Enforce in
the vendored backend's deadline sweep as **BRIDGE** patches (mark `DRUSE PATCH`,
update `planning/vendor-policy.md` row count + `build/check_vendor_policy.sh` +
`VENDOR.md`). Add raw-wire corpus cases: a stalled write and an idle keep-alive
are each closed at their deadline. Additive public `Limits` fields → pay the
gate-amendment checklist (ledger, docs, signatures). **Rollback: MEDIUM.**

### WP-6.5.3 — graceful shutdown example + drain signal (ADR-040) — **P0**
Ship `examples/09-graceful-shutdown`: install a `SIGTERM`/`SIGINT` handler in
`main` that calls `web.stop(&app)`; the gate compiles it. Add a minimal public
read-only accessor `web.is_draining(&app) -> bool` (additive ledger) so a
readiness handler reports not-ready during drain. Document the pattern in
`docs/operations.md`. **Rollback: HIGH for example/doc, MEDIUM for the accessor.**

### WP-6.5.4 — env-config and health/readiness examples — **P2**
Ship `examples/10-config-and-health`: load host/port/limits/timeouts from
environment (12-factor; app-owned, or an ordinary Odin config library per
ADR-038), pass them to
`web.limits`/`web.serve`; register `/health` (liveness) and `/ready` (readiness,
consulting `web.is_draining`). No core change beyond WP-6.5.3's accessor.
**Rollback: HIGH.**

### WP-6.5.5 — the 413 message reflects the configured limit — **P2**
`ERROR_BODY_TOO_LARGE` (`web/errors.odin:517`) is a static "4 MiB" string even
when `max_body` is configured smaller. Make the 413 body report the actual limit
(format bytes without pulling in `core:fmt` — a small allocation-free helper into
the request-local error buffer). Update `docs/errors.md` and `wp6` accordingly.
**Rollback: MEDIUM** (touches the frozen error path — verify the wp6 envelope
tests move with the change).

### WP-6.5.6 — documentation truth-up — **P2**
- `docs/cookbook.md` (placeholder) → real recipes for the canonical tasks, or
  remove the placeholder framing.
- `docs/memory-model.md` (stub) → the arena ownership rules (already invariants
  in code; write them down).
- Add an upgrade/versioning note for consumers (vendoring + pinned toolchain
  contract; no tag before M2).
- Verify `docs/errors.md` has no remaining "Phase 3 / fixed 4 MiB" stale claims.
- (`docs/quick-start.md` "Current limitations" already truthed-up in the audit
  corrective PR.)
**Rollback: HIGH — docs only.**

## Exit gates

- G6.5-1: `client_ip` walks XFF right-to-left; `wp48` proves a spoofed leftmost
  entry is ignored behind a trusted proxy.
- G6.5-2: a stalled write and an idle keep-alive are closed at their configured
  deadline (raw-wire corpus).
- G6.5-3: `examples/09-graceful-shutdown` compiles and demonstrates
  `SIGTERM → web.stop → bounded drain`; `web.is_draining` is readable.
- G6.5-4: 413 body reflects the configured `max_body`.
- G6.5-5: full `build/check.sh` green; ledger amendments accounted; no stale
  status claim remains in `docs/`.

## Public contracts affected

- `Limits` gains `max_write_time`, `max_idle_time` (additive).
- `web.is_draining` added (additive).
- `client_ip` **semantics change** (compatibility break — ADR-037).
- 413 message text changes (behaviour, not signature).

## Definition of done

All exit gates green; ADR-037/039/040 marked ACCEPTED; the audit's P0 items and
the two P1 timeout items closed; docs truthful. This raises the audit verdict
toward `PRONTO_PARA_PRODUCAO_COM_RESTRICOES` (the remaining blocker being the
outbound `http_client`, which is Phase 7).
