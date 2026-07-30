# Phase 7 freeze — streaming foundation: server push, and a real protocol on top

**Status: FROZEN, 2026-07-23, under the ADR-029 delegation.** The streaming
half is frozen in this repository; the composition half's SSE Crystal is frozen
in `druse-crystals`. Nothing was left uncommitted, and nothing was left
undecided without its reason written down. A failed Phase 7 would have left
Phase 6 usable and recorded streaming as not delivered; this one delivers the
detached response-streaming contract publicly and records honestly the one
piece that is substrate-only.

Phase 7 delivered **two orthogonal contracts** (never one magic stream):
detached response streaming, now a public API; and an opt-in large-body path,
whose bounded-memory substrate is built and tested but whose public upload API
is deferred. This document freezes what shipped and names what did not.

---

## 1. The core ledger

| | Phase 6.5 froze | Phase 7 adds | Total |
|---|---|---|---|
| application | 63 | +5 | **68** |
| test-support | 2 | 0 | **2** |
| union | 65 | +5 | **70** |

**The five new application symbols** (Phase-1-freeze Amendment 30, born from
WP86 evidence, frozen here):

```
Stream        — an opaque, stale-safe value token
Stream_Send   — the closed send outcome {Sent, Full, Closed}
stream        — open a detached response, then return
stream_send   — enqueue bounded output from any thread
stream_close  — end the stream, gracefully
```

They are the fewest concepts that express open, bounded send and close (spec §5
budgeted ≤8). The core names **no backend or stream type**: the public surface
reaches the private registry (`web/internal/stream`) only through the transport
boundary, in `(slot, generation)` value pairs. A buffered-only application links
none of the streaming machinery (G7-8): the registry's per-slot rings are
allocated lazily on first open, so a server that never streams pays ~150 KiB,
not the 256 MiB an earlier eager allocation cost.

`web.stream` also takes an optional `content_type` — the one header a stream's
protocol must declare itself (`text/event-stream` for SSE) — which keeps the
signature one symbol.

---

## 2. What the phase was for

Phase 5 recorded two limitations: no incremental long-lived responses, and no
request body larger than the in-memory budget. Phase 7 closes the first as a
public contract and builds the second as a bounded substrate. The thesis,
unchanged from the plan:

> A handler may establish a long-lived response and return; later work can
> enqueue bounded output from any thread, while only the connection-owning lane
> touches the wire. Separately, a large request body may be consumed or spooled
> incrementally without occupying RAM proportional to its size.

---

## 3. The exit gates

| Gate | Verdict | Evidence |
|---|---|---|
| **G7-1** detached lifetime | PASS | `tests/wp87-stream-lifecycle` (stream outlives the Handler scope); the request arena dies at Handler return and the token is a value, not a pointer into it. |
| **G7-2** single writer | PASS | only the owner lane writes the socket; cross-lane producers only enqueue (`tests/wp88-stream-registry`, `tests/wp96-public-stream`). |
| **G7-3** stale safety | PASS | slot reuse advances the generation; a stale token refuses. The control mutation (`build/check_wp88_controls.sh`) proves removing the generation check fails the corpus. |
| **G7-4** bounded backpressure | PASS | pre-registered caps (§4.1); refusal is the canonical full result, counted not logged (`tests/wp92-backpressure`). |
| **G7-5** post-commit security | PASS | exactly one envelope even for a confused dispatch; CR/LF header values cannot split the commit; short writes never duplicate (`tests/wp91-stream-security`). |
| **G7-6** honest drain | PASS (in memory) / DEFERRED (real sockets) | `tests/wp96-scale` drains 3,000 registry streams with no leak; `tests/wp95-drain` proves the wire path at 24 streams within `max_drain_time`. The **3,000 real-socket** round awaits a quiet CI machine — recorded in §5. |
| **G7-7** ecosystem proof | PASS | SSE ships as `crystals:web/sse` using only the public surface (no core internals); the proxy lab (`tests/wp98-interop`) and the vertical slice (`tests/wp99-slice`) use only public contracts. |
| **G7-8** pay only when used | PASS | a buffered-only server links no stream code; the registry ring is lazy per slot; `tests/wp96-public-stream` shows the in-memory transport reports `ok=false` and falls back to buffered. |
| **G7-9** large-body boundedness | PASS (substrate) | `tests/wp94-multipart` streams a body at chunk sizes 1..64 to identical parts, file bytes on the spool, fields bounded in memory; `tests/wp87-body-lifecycle` proves the ownership/quota/cleanup contract. **The public upload API is deferred** — §5. |
| **G7-10** buffered compatibility | PASS | `web.body`/`form_field`/`form_file` are byte-identical; the WP87 buffered oracle stays green through every change. |

---

## 4. The design decisions worth keeping

- **Graceful close.** `web.stream_close` bumps the generation (no new producer
  can reach the slot — stale safety intact) but does NOT discard the queue: the
  owner-lane pump drains the already-queued events through a slot-based owner
  path, then writes the terminator. This is what lets an application send a
  final message and close immediately without losing it. Discovered and fixed
  when the WP99 slice's final `data: 100` vanished. The ownerless corpus close
  still discards and frees immediately (its contract, unchanged).
- **The write deadline is safe without tuning for a stream.** A detached
  response defaults `max_write_time` to 30 s even when the global setting is
  off, because an infinite response must not be unbounded (the slow-consumer
  terminal policy).
- **Detached-stream state is the application's, and lives in `App_State`**, not
  the request arena — which dies at Handler return. This is the one rule an app
  must know; it is documented in `docs/operations.md`.
- **The inherited write-deadline bug is fixed.** ADR-039 is ACCEPTED: the
  Phase-6.5 write deadline "did not fire" because a graceful close flushed
  kernel buffers to the slow reader, hiding the deadline; the enforcement now
  aborts with RST (WP90). The idle timeout and the F9 accept-error crash landed
  on the same path.
- **F4/F5/F6 closed.** `client_ip` walks XFF from the right (Phase 6.5);
  static responses now run the middleware chain, so `secure_headers` and auth
  cover files (WP91).

---

## 5. Non-deliveries and refusals, named so the freeze cannot lie by tidiness

- **The public large-body upload API is deferred.** The substrate is complete
  and tested — a fragmentation-correct streaming multipart parser, the bounded
  spool with generated `druse-spool-` files at `0600`, per-upload and process
  quotas, exactly-once cleanup, admission below lane capacity — but the public
  contract that wires it into the request path (the inbound pause/resume socket
  reads) is not shipped. Large uploads remain buffered under `max_body`. This is
  a genuine non-delivery, not a hidden one: the response direction is fully
  public, the ingest direction is substrate-only.
- **G7-6's 3,000 real-socket round is deferred to a quiet CI machine.** The
  scale claim is proven on the registry in memory and on the wire at modest
  count; a 3,000-concurrent-real-socket drain was not run on this shared
  development box, which segfaults socket suites under its baseline load. The
  owner prefers the real round eventually; it is the one scale claim not yet
  demonstrated end to end on hardware.
- **Refused by design:** WebSocket and arbitrary full-duplex protocols;
  HTTP/2/3; a template/session framework or client runtime in core; automatic
  semantic patch coalescing; a background job system (the application owns its
  worker); per-connection application pointer bags; transport types in the
  public API.

---

## 6. The composition half (Crystals)

SSE ships as `crystals:web/sse`, frozen in `druse-crystals` against this
core: `open`/`send`/`comment`/`last_event_id`/`Event`/`Send_Result`/
`MAX_EVENT_BYTES`, importing only `druse:web` — no core internals, no backend.
It proves the core streaming abstraction supports a real protocol with no
privileged access (G7-7). The `http_client` and `metrics` Crystals named in the
composition-half plan remain future Crystals-repo work; they do not depend on
streaming and do not block this freeze.

---

## 7. The vendored backend

**Twenty-two local patches** now (`vendor/odin-http/VENDOR.md`,
`planning/vendor-policy.md`). Phase 7 added four: the response write deadline
with its RST abort and send-cancellation (patch 19), the idle keep-alive
timeout (patch 20), accept-error tolerance (patch 21, F9), and the three
detached-stream hooks — chunked heading commit, request-cycle finish, unflushed
abort (patch 22). All streaming and timeout patches are marked **BRIDGE**:
deletable when `core:net/http` arrives (expected January 2027), whose adapter
must pass the same semantic, raw-wire, liveness and shutdown corpus before it
can replace this bridge (ADR-033).

---

## 8. Exit contract

Phase 7 freezes because: the public streaming surface is the fewest concepts
that express open/send/close, born from evidence and justified symbol by symbol;
every exit gate passes with the two deferrals recorded above named, not hidden;
the buffered path is byte-identical (G7-10); a buffered-only server links no
streaming code (G7-8); SSE proves the abstraction from outside the core (G7-7);
the vendored streaming hooks are BRIDGE work with a declared exit; the inherited
write-deadline bug and F4/F5/F6/F9 are closed; and the complete existing Druse
gate remains green.

After Phase 7, Druse is still a microframework. Ordinary users still see app,
route, extract, respond and serve; small bodies keep the buffered path.
Applications that want them gain bounded long-lived responses and SSE, without
learning their concepts or paying their executable-code cost.
