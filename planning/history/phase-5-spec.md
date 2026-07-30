# Phase 5 spec — close the drain, ship the table stakes

**Status:** SPEC, 2026-07-21, under the ADR-029 delegation.
**Entry:** Phase 4 frozen (`phase-4-freeze.md`), ledger 55 + 2, main at `ab01ce1`.
**Owner amendments carried by this document:** five, all recorded in §1.

---

## 0. What this phase is, and why it is not the one the roadmap wrote

The roadmap's Phase 5 is *Ecosystem* — "the optional pieces I need exist, without bloating
the core", each item gated on "a real user request" (`roadmap.md:117`).

That criterion cannot be satisfied. The project has no users. There is no demand to point at
because there is nobody to generate it, and there will be nobody until the framework has the
pieces that demand would have asked for. Followed literally, the rule freezes the project
permanently in a state that is technically excellent and unadopted.

This is not a reason to abandon the discipline. It is a reason to notice that one rule was
written for a project that already had users, and to amend it for the project that exists.

So Phase 5 does two things, in this order:

1. **Closes the drain.** It is the only open deficiency, it was withdrawn in Phase 4 for
   bounding nothing, and it is the one gap a reverse proxy does not absorb. Static files and
   CORS can be fronted by nginx; a request cut off mid-flight during deploy cannot be fronted
   by anything.
2. **Ships the table stakes.** Static files, CORS, uploads. Not sophistication — the things
   a person needs in the first week of a real application.

### The comparison that sets the bar

Gin is roughly eighty thousand stars of convenience over `net/http`. It does not implement
TLS, HTTP/2, keep-alive, the HTTP/1.1 parser, timeouts, graceful shutdown, streaming, or the
connection lifecycle. Go's standard library does, and Gin stands on it.

Druse has no such foundation to stand on, which is why roughly forty percent of this
project is a server nobody else wrote. That asymmetry is the honest frame for every
comparison: where Druse is behind Gin, it is usually behind `net/http`, not behind Gin.

It also explains where Druse is *ahead*. Gin does not implement timeouts (ADR-031 recorded
this) and does not state its per-request memory cost, because it never had to think about
either. Druse bounds its per-request working memory, ships read deadlines in the core, and
documents what it does not bound. That is the differentiator, and Phase 5 must not spend it.

**The bar for this phase:** a person arriving from Gin should not feel that something is
missing. Where a gap remains, it is named in `docs/operations.md` with its reason — never
discovered at runtime.

---

## 1. Owner amendments

Five decisions, all made by the owner on **2026-07-21**, all reversing or narrowing
something already written down. They are recorded here and in `decisoes-do-dono.md` because
the conditionality clause (`decisoes-do-dono.md:53`) requires that a contradiction of a
recorded decision **stops and is registered**, never followed silently.

### AMEND-P5-1 — The table stakes belong in the core

`decisoes-do-dono.md:51` records, under the delegation, that **CORS, uploads and static
files stay outside the core** as future optional packages. `later-phases-plan.md` classifies
P4-8, P4-10 and P4-11 the same way, and `roadmap.md:160` governing rule 4 says "Uploads,
static files, TLS, OpenAPI, WebSocket and streaming are candidates for separate packages,
not core growth".

**Reversed for three of those six.** Static files, CORS and uploads land in `web/`, with
ledger growth, paying G-09 in full.

The grounds: a microframework missing all three is not a microframework, it is a routing
library. The original decision was made while Phase 4 was fighting for its scope, and
deferring them was correct *then* — it is not correct as a permanent position.

**TLS, OpenAPI, WebSocket and streaming keep rule 4 unchanged.** This amendment names three
items and no others.

### AMEND-P5-2 — Demand-driven is waived for this class, and only this class

`roadmap.md:117` requires a real user request per item. Waived for the three items in
AMEND-P5-1, on the grounds recorded in §0: the criterion is unsatisfiable at zero users and
its literal application is self-defeating.

**What is not waived:** G-09. Every symbol still carries all eight evidences. What is waived
is the wait for an external request, not the evidence for the design.

**Scope of the waiver, stated so it cannot be stretched:** it covers static files, CORS and
uploads. It does not cover WebSocket, streaming, HTTP/2, OpenAPI, templates, database
integration, or the Advanced API. Those keep the demand-driven gate. A waiver that grows to
fit whatever is being proposed is not a waiver, it is the absence of a rule.

### AMEND-P5-3 — `core:net/http` lands in January 2027, and it is now a design constraint

The owner reports that Odin's standard library gains an official `core:net/http` in
**January 2027**, expected with limitations.

`later-phases-plan.md:362` currently records this package as *"NEEDS_PROTOTYPE, unscheduled —
the package does not exist… Treat as a hypothesis with no date."* It now has a date.

Two consequences, both binding on this phase:

1. **ADR-033 arm C (own the connection layer) is economically dead.** Building a second
   connection layer over six months, to be superseded by the standard library, is work that
   loses either way. ADR-033 should close on **keep and patch, with the transition as the
   declared exit** — not on own.
2. **Every work package acquires a second acceptance criterion: it must not make the swap
   harder.** Concretely:
   - Nothing in `web/` may learn anything about the backend. This is already G-06 and
     already gate-scanned; Phase 5 must not weaken it.
   - The multipart parser lives in `web/` and consumes `[]u8`. It never reads from a socket,
     never names a backend type, never assumes how the body arrived.
   - Static file serving produces bytes into `Outbound` like every other response. It does
     not acquire a privileged write path.
   - **The vendored drain patches are declared bridge work.** They are worth building
     because the gap is now, and they are expected to be deleted when the new adapter lands.
     `vendor-policy.md` records them as such so a future reader does not mistake them for
     foundation.

The transport boundary was designed for exactly this and says so
(`web/internal/transport/boundary.odin:9-11`): only the conceptual contract — accept →
dispatch → commit → stop — is frozen, and the record shapes "may change freely when a second
adapter lands". Phase 5's job is to keep that sentence true.

### AMEND-P5-4 — The CE-E4 gate has opened, and nothing recorded it

ADR-032 Decision 2 gated ecosystem work on "after WP44", not on the Phase 4 freeze, because
the recommended first Crystal was a restart-on-save watcher and the core could not shut down.

WP44 merged 2026-07-21 (PR #77). Phase 4 froze at PR #86. **The condition is met and no
document in the tree says so.** Recorded here.

This changes nothing about Phase 5's contents — no ecosystem work is scheduled here — but an
unrecorded open gate is how a condition quietly stops being checked.

### AMEND-P5-5 — CE-E3 stands, unamended

ADR-032 Decision 1: no ecosystem work may add, widen or change a core symbol.

Nothing in Phase 5 is ecosystem work. The core grows here by a core decision, through the
front door, paying the core's own evidence rules. CE-E3 is not bent, invoked, or worked
around — it is simply not the applicable rule.

Stated explicitly because the failure mode it guards against is precisely the one available
here: shipping core growth while calling it something else.

---

## 2. Pre-registered criteria

Fixed **before** measurement, because a threshold set after the number is a rationalisation.
This is the rule that saved ADR-030, where a 31% timing difference sat inside a 138% noise
floor and the pre-registered arm decided instead.

### 2.1 The drain (WP58 measures, WP59 builds)

The Phase-4 record names `nbio.run()` (`vendor/odin-http/server.odin:349`) as the cause. The
exploration found **three** unbounded waits on the shutdown path, not one:

| # | Site | What it waits for |
|---|---|---|
| 1 | `server.odin:340` | `nbio.tick()` with no timeout, inside the drain loop |
| 2 | `server.odin:349` | `nbio.run()` — every pending operation, by definition |
| 3 | `server.odin:392`/`:464` | `Conn_Close_Delay`, 500 ms **per connection** |

And a fourth fact: `server_deadline_sweep` returns early when `closing` is set
(`server.odin:773`) and does not reschedule. The read deadline — the only defence against a
slow client — switches itself off at exactly the moment the drain needs it.

**WP58 must name which site dominates, with a number, before WP59 patches anything.** The
instrument is `nbio.num_waiting()` (`nbio.odin:166`), which reports what is actually
outstanding. Patching without this measurement repeats WP44's mistake with fresh mechanisms.

**Success for WP59:** with a client holding a connection open and not sending, `web.stop`
returns within `max_drain_time`, verified at 1 connection and at 3.000.

**Failure is a legitimate outcome, and its handling is fixed now:** if no contained mechanism
makes `stop` terminate reliably, `Limits.max_drain_time` **is not shipped**. Phase 4 withdrew
this exact field rather than ship a knob that bounds nothing, and that was the right call. A
button that lies is worse than a documented limitation.

**Containment is measured, not argued:** `git diff --stat` against `vendor/` is the number
that goes into ADR-033. The precedent is the ADR's own: WP46's patch was contained (an option
field, a struct field, a periodic sweep) and closed it; WP44's was not and reopened it.

### 2.2 The table stakes

| Item | Ships only if | Named risk |
|---|---|---|
| CORS | preflight correct; a non-permitted origin receives no header; reflected-origin-with-credentials is refused **at registration**, not at request time | the classic hole is a permissive default; the API must make it hard to write |
| Static files | traversal corpus green (`..`, double encoding, Windows separators, NUL, symlink escaping the root, dotfiles); ETag/Last-Modified and 304 work | responses are fully buffered (ADR-014) — a 100 MB file costs 100 MB of RAM. A declared size ceiling with a clear refusal, never a pretence of serving anything |
| Uploads | WP62 answers all seven OQ-20 questions first | if honest uploads require streaming, **WP63 is declined this phase**, with the reason recorded |

The uploads path is where AMEND-P5-3 bites hardest: whatever WP62 decides about temporary
file ownership must still be true when the body arrives from a different adapter.

---

## 3. Work packages

| WP | Type | Name | Ledger |
|---|---|---|---|
| 57 | SPEC | This document, and the five amendments | — |
| 58 | TESTS | Drain anatomy; obligation 3 restored, committed RED | — |
| 59 | IMPLEMENTATION | The drain deadline | `Limits.max_drain_time` (field, no name cost) |
| 60 | IMPLEMENTATION | CORS | +2 |
| 61 | IMPLEMENTATION | Static files | +2 |
| 62 | SPEC | Uploads — OQ-20 answered | — |
| 63 | IMPLEMENTATION | Multipart and uploads | +3, conditional on WP62 |
| 64 | DOCS | Operations, and the new surfaces | — |
| 65 | FREEZE | The verdict | — |

Estimated ledger: **55 → ~62** application symbols, test-support unchanged at 2.

Every ledger-growing WP amends the full set together — `build/check_public_api.sh`,
`build/phase1-public-signatures.txt`, a numbered Amendment in `phase-1-freeze.md` carrying
all eight G-09 evidences, `docs/ai-context.md`, `docs/canonical-patterns.md`, `build/check.sh`,
and the `// druse:file application` marker in each new file. Missing one is a red gate.

Each WP follows `CONTRIBUTING.md:61` — SPEC → TESTS committed RED → IMPLEMENTATION → REVIEW —
and enters by its own PR against `main`.

---

## 4. What Phase 5 does not do

- **No streaming, WebSocket, HTTP/2 or OpenAPI.** The `Dispatch_Proc`/`Outbound`
  boundary is not touched.
- **No ecosystem work.** CE-E3 stands, PR #49 stays draft, and the first Crystal is not this
  phase — even though AMEND-P5-4 records that its gate opened.
- **No concurrency change.** ADR-030 stays single-threaded; none of its three reopening
  conditions has been met.
- **No TLS.** Still terminated at the reverse proxy.
- **No second transport adapter.** AMEND-P5-3 makes that January's work, not this phase's.

---

## 5. Documentation drift corrected by this WP

Found while writing this spec. Each is a place where the tree contradicts itself:

1. **`later-phases-plan.md:372` says ADR-010 is "still PROPOSED"**; `adrs.md:202` records it
   ACCEPTED 2026-07-20 under the delegation.
2. **`decisoes-do-dono.md:59` says the owner's open-decision queue is "empty"**; it predates
   ADR-031 Amendment 1, ADR-032, ADR-033's reopening, and the Phase-4 freeze.
3. **`later-phases-plan.md:362` calls `core:net/http` a hypothesis with no date.** It has one
   (AMEND-P5-3).
4. **PR #49 (`crystals-ecosystem-plan`) is decaying exactly as ADR-032 predicted**: its
   documents still record CE-E3 and CE-E4 as "not met", ADR-C006 as blocked on a WP37 that
   shipped, Q-3 as unverified when it was verified byte-identical, and still recommend
   `dev/watch` as the first Crystal after ADR-032 Decision 3 overrode it. Not fixed here —
   the branch is not this phase's work — but recorded so the decay is known rather than
   discovered.
