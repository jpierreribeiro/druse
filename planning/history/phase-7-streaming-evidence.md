# Phase-7 streaming evidence — the WP86 shootout record

**Status: EVIDENCE RECORD, 2026-07-23, WP86.** Disposable prototypes under
`experiments/16-stream-topology/` and `experiments/17-ingest-arms/`, run on
the pinned toolchain (dev-2026-07a). This document records the verdicts the
prototypes produced, in the format `architecture-evidence-questions.md` §1
requires. It freezes **no name and no signature** (owner caveat: names are
born from evidence and freeze only in WP101 — the lab labels here are not
ledger candidates). Prototypes are never imported by `web` and stay
executable so the verdicts remain reproducible.

---

## 1. Question one — is response streaming contained above the backend?

Trigger: Phase-7 entry (fired). Full arm-by-arm record and result table:
`experiments/16-stream-topology/README.md`.

**Verdict: yes — contained, with a bounded backend obligation list.** Every
mechanism the winning arm needed — slot registry, generation, bounded ring
queue, owner-lane drain with per-tick progress, wakeup — was built above the
connection backend. The backend owes only what WP90 already scopes as BRIDGE
patches: commit-without-body, incremental chunk write, wake-on-progress,
cancel. The refusal outcome ("minimal core stream contract or refusal") is
therefore: **minimal core stream contract.**

- **A (Handler stays alive):** paper veto, pre-registered — the frozen
  prohibition on Handler-frame ownership plus the arithmetic 3,000 required
  streams (G7-6) > 256 maximum lanes. No prototype was owed.
- **B (lane-polled producer):** semantically equivalent (ten updates in
  order) but every safety property the gates demand — bounded hand-off,
  full policy, stale refusal — is application convention, not framework
  contract; the prototype had to build its own synchronized buffer to
  function, which is the finding. Idle producers cost a poll per stream per
  tick (counted).
- **C (detached stream, stale-safe value token):** passes all pre-declared
  kill criteria: typed `{sent, full, closed, stale}` cross-thread enqueue
  with copy-on-enqueue and no dynamic allocation on the send path; refusal
  is immediate, never a wait; generation invalidated at close-accept —
  provably before queued items are released; a stale token refuses against
  the slot's new occupant; close is accepted against a full queue through
  reserved control capacity; racing producers on the final queue slot yield
  exactly one `Sent`.
- **D (SSE-specific):** reproduces C's machinery in full (registry,
  generation, queue, owner lane — nothing saved), while losing generic
  bytes: a payload containing a newline corrupts SSE framing unless the core
  learns protocol splitting. D is C's cost without C's reach, and it moves
  protocol text into the core against CE-E3.

**Decision: candidate C is the productive arm.** SSE ships as the first
Crystal over it (WP97). The single-writer control is byte accounting: the
sink (socket stand-in) contains exactly the drained events in per-producer
order — producers demonstrably never touched it. (Odin's `@(private)` is not
a tamper boundary — ADR-008's WP2 scope note — so the contract is proven by
accounting, not by pretending the language forbids the write.)

## 2. Question two — spool or direct streaming for large requests?

Full record: `experiments/17-ingest-arms/README.md`.

**Verdict: bounded spool — arm F's loop under arm G's admission.** Chunks
append where they arrive; admission is capped below lane capacity with a
typed refusal before any byte is read; the ordinary synchronous Handler runs
only when the body is Ready, receiving an explicitly owned spool.

- **E:** lane occupied for 128/128 chunks — upload concurrency becomes lane
  concurrency; vetoed by the liveness arithmetic this program exists for.
- **F:** lane occupied 0 chunks; peak tracked memory = one 64 KiB chunk
  buffer for an 8 MiB body.
- **G:** the admission contract is right; the worker tier is not — the spool
  loop is an I/O append with no CPU work to schedule. F-with-G's-admission,
  not a pool.
- **H:** arithmetically fine, structurally a second Handler model (state
  outliving framework-driven callbacks). Advanced candidate only, under the
  plan's own bar; not the Productive contract.

**Controls, outcomes as pre-registered in `phase-7-spec.md` §4.2:** quota
breach mid-body → typed result, file deleted; disconnect mid-body → typed
result, file deleted, Handler never scheduled; files `0600` under generated
`druse-spool-` names; success path verified byte-exact and cleaned.

## 3. OQ-32, answered

> Can response streaming and large-body spool share one private lifecycle
> without imposing a second Handler model?

**Yes.** The response direction is the registry/queue/wakeup substrate of
candidate C. The ingest direction needs admission, pause/resume of reads and
a spool lifecycle — but its Handler contract is unchanged: the ordinary
synchronous procedure runs once, when the body is Ready. Neither direction
required a callback Handler, a continuation or a second dispatch shape in
its Productive arm; the one arm that did (H) is exactly the one held to the
Advanced bar. The shared piece is the private lifecycle (open/derive →
bounded work → typed terminal → exactly-once cleanup under one drain
deadline), which WP87 turns into a RED corpus.

## 4. What WP87–WP94 inherit

1. WP87 writes the RED corpus against candidate C's semantics and the spool
   controls above — the contract, not the lab code.
2. WP88 implements the registry with contiguous slots, explicit free list and
   generation (the prototype's shape, hardened; forced tiny capacity stays a
   test discipline).
3. WP89 implements the cross-lane delivery with the six-step contract
   (validate → reserve → copy → publish → wake → typed result); the
   prototype's mutex-per-slot is a lab convenience, not the shipped design —
   WP89 owns the real synchronization choice under "no mutex held during a
   socket write".
4. WP90 provides commit/chunk/cancel on the vendored backend (plus the
   inherited ADR-039 and F9 work), reusing `Response_Writer` as raw material.
5. WP93/WP94 build the opt-in spool exactly as arm F+G's shape, with the §4.2
   quotas as the admission and runtime bounds.
6. The registry/queue/wakeup substrate stays executor-agnostic (spec §6.3) —
   nothing in candidate C assumed the producer was a Handler lane, and the
   implementation may not either.
