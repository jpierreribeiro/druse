# Phase 2 — Composition: work package plan

**Status: DRAFT FOR HUMAN REVIEW.** Nothing here is frozen. Every signature is
marked **PROPOSED**. Phase 1 froze 32 application + 2 test-support = 34; this
plan proposes how that grows and demands evidence for each increment.

Work packages continue Phase 1's numbering: **WP12 – WP25**.

---

## 0. Two findings that reshape the plan before any work package starts

Both were checked against the pinned toolchain (`dev-2026-07-nightly:819fdc7`),
not recalled.

### FINDING-A — Odin has no recoverable panic (CONFIRMED by WP13; resolved by ADR-020)

> **Status: settled.** WP13 confirmed this and went further — `app()` cannot
> install a hook at all, and most faults never reach one. The owner accepted
> R-b: zero public symbols, driver-500 guarantee, honest documentation. The
> original analysis is kept below because it is what drove the prototype.

`base/runtime/core.odin:392`:

```odin
Assertion_Failure_Proc :: #type proc(prefix, message: string, loc: Source_Code_Location) -> !
```

The hook Odin provides for assertion and panic failure is typed **`-> !`** — it
is not permitted to return. `panic` (`base/runtime/core_builtin.odin:1690`) is
likewise `-> !`. There is **no `recover` anywhere in `base/` or `core/`**, no
unwinding and no destructor-driven cleanup. Confirmed by execution: a handler
that panics kills the process.

```
$ ./a.bin
main.odin(4:35) panic: handler exploded
Illegal instruction (core dumped)      exit=132
```

The only non-returning escape available on POSIX is `core/sys/posix/setjmp.odin`,
and a `longjmp` out of a panicking frame skips every `defer` in between — which
in Druse means leaking the request arena, the owned response body and the
connection state, per fault.

Consequences for `knowledge-base/03-development-phases.md` §Phase 2:

* the Test Gate item *"recovery converts panic to standardized 500"* is, as
  literally worded, **probably not deliverable in Odin**;
* the Scope item *"recovery middleware — becomes default-on in `web.app()`"*
  needs a redefinition of what recovery can mean in this language.

This is not a reason to drop the item. It is a reason to prototype it in its own
work package (WP13) **before** the Phase-2 specification is written, and to
expect a scope amendment requiring the owner's approval. Candidates, all to be
measured in WP13, none pre-selected here:

| Candidate | Delivers | Costs |
|---|---|---|
| R-a "last gasp" | a custom `assertion_failure_proc` writes a 500 on the in-flight connection, then aborts | the process still dies; reaching connection state from a failing frame is unproven |
| R-b "already shipped" | recovery is redefined as WP8's existing driver guarantee (uncommitted response → typed report → 500), plus documentation that Odin aborts on panic | honest and free, but does not match the phrase "recovery middleware" |
| R-c `setjmp`/`longjmp` | genuine continue-after-fault | skips every `defer`; leaks the arena, response and connection per fault; **FOREIGN_ABSTRACTION_RISK**, expected reject |
| R-d "no recovery" | remove the item from Phase 2 | the phases-doc gate checklist must be amended |

### FINDING-B — the real middleware question is narrower than "onion versus not"

The Odin-fit audit flags post-`next` semantics as `FOREIGN_ABSTRACTION_RISK`.
Working through the constraints, the *mechanism* is already forced:

* middleware returning `bool` would be a **second handler shape**, which ADR-011
  forbids;
* therefore middleware is `proc(ctx: ^Context)` — identical to `Handler` — and
  short-circuit is "return without calling `web.next(ctx)`", exactly as the
  phases doc specifies;
* given a cursor and `next`, code placed after `next(ctx)` **inevitably runs**.
  `next` is an ordinary call that returns. There is no unwind machine to adopt
  or reject.

Odin's objection to exceptions is about *hidden* control flow; a nested call
that returns is the opposite of hidden. So the genuine open question is **not
"do we build onion"** — the mechanism gives it to us — but **"what do we promise
about post-`next` code, and do we test it?"**

* **B1** — specified and tested: exact reverse unwind order; the response is
  already committed; any further response attempt is rejected by the existing
  single-commit guard; the observer sees an event.
* **B3** — documented as forbidden, untested, no guarantee (the code still runs).

B2 — "leave it unspecified" — is rejected on sight: shipping a mechanism whose
behaviour is observable but undocumented is the worst of both. WP12 gathers the
evidence; WP15 and the owner choose between B1 and B3.

---

## 1. Entry conditions (not work packages)

Phase 2 must not start until these are merged. Two of them touch every file a
Phase-2 agent will read.

| ID | Item | Type | Approval |
|---|---|---|---|
| E-1 | `LICENSE` at the repository root (audit A-2) | non-code | **owner — licence choice** |
| E-2 | Correct the eight "still a stub" comment sites (audit A-3), plus a `serve` doc-comment sentence stating Phase 1 has no stop (audit A-5) | documentation | none |

---

## 2. Work package sequence

| WP | Name | Type | Owner approval |
|---|---|---|---|
| 12 | ~~Middleware mechanism prototype~~ **DONE** — ADR-005 accepted with ADR-019 enforcement | PROTOTYPE | ✅ granted |
| 13 | ~~Fault/recovery feasibility prototype~~ **DONE** — ADR-020 accepted (R-b, zero symbols) | PROTOTYPE | ✅ granted |
| 14 | Test-support evolution: `test_request` gains `body` + `query` | SPEC (prototype-backed) | ✅ granted (ledger stays 2) |
| 15 | Phase-2 specification, ADR closure, ledger proposal | SPEC | **yes** (ledger) |
| 16 | Gate restructuring for Phase-2 growth | TESTS | no |
| 17 | `use` + `next` + flattened chains (app level) | IMPLEMENTATION | no |
| 18 | `Router` + `mount` + route-level middleware | IMPLEMENTATION | **yes** if the five verbs gain a variadic |
| 19 | Request header lookup: `header`, `bearer_token`, **and request-header injection in `test_request`** | IMPLEMENTATION | no |
| 20 | Typed framework-error observer | IMPLEMENTATION | no |
| 21 | Fault behaviour: driver-500 guarantee, documented | DOCUMENTATION + TESTS | no (decided: ADR-020) |
| 22 | `logger` middleware | IMPLEMENTATION | no |
| 23 | `request_id` middleware and its trust policy | IMPLEMENTATION | **yes** (security boundary) |
| 24 | Examples, documentation, canonical auth pattern | DOCUMENTATION | no |
| 25 | Phase-2 review, mutation gate, freeze | FREEZE | **yes** (freeze) |

Dependencies: 12 → 15; 13 → 15; 14 → 15; 15 → 16 → 17 → {18, 19, 20};
{13, 15} → 21; 17 → 22; {17, 19} → 23; all → 24 → 25.

Note the shape: **three of the first five work packages are prototypes or debt
repayment, not features.** That is deliberate — the audit found that middleware
work sits directly on top of a gate that punishes adding files, a test facility
that cannot send a body, and a commit invariant that a new responder would break.

---

## WP12 — Middleware mechanism prototype and post-`next` decision

**Type: PROTOTYPE. Requires owner approval (closes ADR-005).**
**This work package is handoff-ready: an implementation agent can be given it as
a prompt as-is.**

### Objective

Answer, with compiling and measured evidence on the pinned toolchain, every
mechanical question about a middleware chain in Druse, so that WP15 specifies
something already known to work. **No production file is modified.** The only
repository output is one findings document.

### Value delivered

None directly. It is the precondition for `web.use` being specified rather than
guessed, and it is the audit's explicit gate on `FOREIGN_ABSTRACTION_RISK`.

### Prerequisites

E-1 and E-2 merged. Baseline gate green (`PASS=10 FAIL=0 SKIP=0`, 32 + 2).

### Public surface affected

**None.** WP12 exports nothing. It *proposes* the following for WP15 to ratify —
**PROPOSED, NOT FROZEN**:

```odin
// PROPOSED — no new type: middleware IS the frozen Handler shape.
use  :: proc(a: ^App, middleware: Handler)
next :: proc(ctx: ^Context)
```

### Decisions to be produced (the agent must not assume any of them)

* **D-12.1 — is a distinct `Middleware` type needed?** Baseline proposal: no.
  Reusing `Handler` adds zero public names (G-01) and satisfies "no second
  handler shape" by construction. Counter-argument to record: `use(&app, list_users)`
  then compiles, registering a route handler as middleware. Prototype both and
  report the call-site cost of `Middleware :: distinct proc(ctx: ^Context)` —
  does `use(&app, my_mw)` still infer, or does every registration need a cast?
* **D-12.2 — chain storage that cannot dangle.** A `[]Handler` slice stored on a
  `Route_Entry` and pointing into an App-owned `[dynamic]Handler` **dangles the
  moment the dynamic array reallocates.** Confirm this, then adopt index-pair
  storage (`chain_start, chain_len: int` into an App-owned pool) or prove a safe
  alternative.
* **D-12.3 — the post-`next` promise: B1 or B3** (see FINDING-B).
* **D-12.4 — do app-level middleware run on a 404 or 405?** Flattening attaches
  chains to *routes*; a miss has no route, so naive flattening means `logger`
  never logs a 404 and `request_id` never stamps one. Prototype a second
  flattened "miss chain" terminating in the automatic 404/405 responder and
  report its cost. This is a first-class semantic decision, not an
  implementation detail.
* **D-12.5 — does `use` apply retroactively?** With registration-time
  flattening, `use` called after `get` cannot affect the earlier route without a
  second pass. Proposal to test and document: **no retroaction — `use` affects
  only registrations that follow it.** Write one deliberately mis-ordered
  program and record how confusing it is.
* **D-12.6 — `next` called twice by one middleware.** Define and measure:
  re-entering the remainder runs the handler twice and the second response is
  rejected by the commit guard. Acceptable, or must the cursor detect and report
  it through the typed report path?
* **D-12.7 — variadic route-level middleware.** Does
  `get(a: ^App, pattern: string, handler: Handler, middleware: ..Handler)`
  compile, stay source-compatible with every Phase-1 call site, and allocate
  nothing at registration? Report the exact `odin doc` delta — it mutates five
  frozen signatures.

### Probes (the actual work)

Build in `/tmp/druse-p2-mw`, using the copy-`web/*.odin`-into-a-throwaway-package
technique the gate already uses (`build/check.sh:104`). Nothing is written back
to `web/`.

| Probe | Question |
|---|---|
| P1 | cursor + `next` compiles with `Handler` reuse |
| P2 | exact pre-order across global + two nesting levels + route |
| P3 | short-circuit: middleware 2 returns without `next` → 3 and the handler never run |
| P4 | post-`next` code runs; unwind order is exact reverse |
| P5 | a post-`next` response attempt is rejected by the single-commit guard and the first response stays byte-identical (**audit A-7 territory — verify the guard; do not add a seventh unguarded scratch writer**) |
| P6 | `next` called twice |
| P7 | middleware that neither calls `next` nor responds → WP8 D5 finalization to 500 |
| P8 | dangling-slice reproduction: store `[]Handler` into a growing pool, force reallocation, observe corruption; then show index pairs are immune |
| P9 | **allocation count at dispatch** via `mem.Tracking_Allocator` around a request through a 5-middleware chain — must be **zero** |
| P10 | **stack depth**: chains of 1, 8, 64, 512; recursion is O(n) frames — find the practical bound |
| P11 | **binary cost**: minimal app with the machinery present but zero middleware registered, versus the Phase-1 baseline (`nm` + `size`) |
| P12 | variadic registration (D-12.7): compiles, no heap allocation, `odin doc` delta |
| P13 | miss chain (D-12.4): does a global middleware observe a 404? |

### RED equivalent

WP12 ships no production behaviour, so its RED discipline is that **the probes
must be able to fail**: P8 must actually reproduce the dangling-slice
corruption, and P9 must be run once against a deliberately allocating chain to
prove the tracking allocator would catch a regression. A probe that cannot fail
is not evidence.

### Mutation / negative probes

P8 negative control (slice storage corrupts) and positive (index storage does
not); P9 negative control (an allocating chain is detected); a chain where
nothing calls `next`, confirming the 500 path rather than a hang.

### Ownership and lifetime

Chains are owned by the `App` and freed by `destroy`. Nothing per-request is
allocated. One sentence per owned allocation in the findings file.

### Failure behaviour

If the cursor cannot be made allocation-free at dispatch, or if P10 shows the
practical middleware bound is embarrassingly small (< 32), the agent **stops and
reports** rather than inventing a different execution model. Silently switching
to an iterative pre-order-only model would kill `web.next`, which is required
scope.

### Security

No direct surface. For the record: ordering *is* a security mechanism once auth
middleware exists (WP24), so D-12.4 and D-12.5 have security consequences that
WP15 must restate.

### Binary cost and allocations

P9 (zero dispatch allocations) and P11 (near-zero cost with no middleware
registered) are **acceptance criteria, not observations**. A non-trivial P11
delta for an app with zero middleware is a human-review item, exactly as G-11
requires.

### Documentation

`planning/phase-2-prototype-middleware.md`: one section per probe with the
command, the output and the conclusion; a decisions table proposing D-12.1 to
D-12.7 with a recommendation **and the strongest argument against each**; an
explicit "what I could not determine" section. Readable by the owner without
running anything.

### Rollback

Delete the findings file. No production code exists to revert.

### Completion criteria

All 13 probes run on the pinned toolchain with outputs recorded verbatim; every
decision has a recommendation and a counter-argument; the full gate still green;
`git diff` touches exactly one file; the owner has an explicit ADR-005
recommendation to accept or reject.

### Explicitly out of scope

Route groups, `Router`, `mount`, recovery, logger, request ID, header lookup,
the observer, any documentation change, any change to `web/` or `build/`.

---

## WP13 — Fault/recovery feasibility prototype

**Type: PROTOTYPE. Requires owner approval (scope amendment expected).**

* **Objective.** Determine what "recovery" can honestly mean in Odin
  (FINDING-A), and recommend among R-a / R-b / R-c / R-d.
* **Value.** Prevents Phase 2 promising a Go/Rust behaviour the language cannot
  provide, and prevents `web.app()` shipping a default that does nothing.
* **Prerequisites.** None; may run in parallel with WP12.
* **Public surface: settled at ZERO.** WP13 ran; the owner accepted R-b
  (ADR-020). No `recovery` symbol exists, in this or any later Phase-2 work
  package.
* **Decisions before tests.** Does a custom `context.assertion_failure_proc`
  observe enough state to write a response on the in-flight connection? Does the
  adapter's connection object survive a failing frame? Does release mode or
  `-disable-assert` change the answer? What does a bounds-check failure do (it
  does not go through `panic`)? Which `defer`s are skipped in each candidate,
  and can the resulting leak be measured?
* **Likely files.** `/tmp/druse-p2-recovery/**`; repository output
  `planning/phase-2-prototype-recovery.md`.
* **RED tests.** A program that panics inside a handler must first be shown to
  kill the process **today** — that is the baseline any candidate must beat.
  (Already demonstrated above; the prototype re-runs it as its control.)
* **Mutation/negative probes.** For any candidate that appears to work, prove it
  is not vacuous: panic in three distinct places (handler, middleware, JSON
  marshal path) and in two build modes. Measure leaked bytes per recovered fault
  with `mem.Tracking_Allocator`; a candidate that leaks the request arena must
  say so **in bytes**.
* **Failure behaviour.** If no candidate is safe, recommend R-b or R-d and
  supply the exact phases-doc amendment text.
* **Security.** A "recovered" process that keeps serving with leaked per-request
  state is a **worse** outcome than a clean abort under a supervisor. State this
  explicitly: repeated triggered faults are then a memory-exhaustion vector.
* **Binary cost.** Whatever is recommended must be measured for the default-on
  case, since `app()` is on every application's static path — no lazy linking is
  possible for a default. Must not import `core:fmt` or `core:log` (WP6 measured
  ~37 KiB for that mistake).
* **Completion.** The owner has a recommendation with measured evidence, and the
  Phase-2 gate checklist item is either confirmed deliverable or has amendment
  text ready.
* **Out of scope.** Implementing anything; graceful shutdown (Phase 4); signal
  handling as a product feature.

---

## WP14 — Test-support evolution: `test_request` as a procedure group

**Type: SPEC (prototype-backed). APPROVED by the owner, 2026-07-19 — see
ADR-021.**

> **Objective sharpened by the approval: stay at ONE public name.** If the
> variants can be `@(private)` members of the group, the test-support ledger
> **stays at 2** and only the signature snapshot changes. If the toolchain
> forbids that, growth goes to the minimum and the number is reported before it
> is adopted. Either way this lands as a **freeze amendment** —
> `build/phase1-public-signatures.txt`, the manifest and the gate numbers
> updated together, with evidence — which is the door WP11 built, not a way
> around it.

* **Objective.** Resolve audit A-1: make body- and header-carrying requests
  testable in memory, using an explicit Odin **procedure group** — how
  `core:strings` and `core:net` add variants without creating aliases.
* **Value.** Today a user cannot reach the success path of any `web.body`
  handler without opening a socket. The audit names this the friction most
  likely to be felt by a real user.
* **Prerequisites.** None. Should land before WP17 so Phase-2 middleware tests
  can use it.
* **Public surface (PROPOSED).**

```odin
// PROPOSED — test-support ledger, not the application ledger.
Test_Request :: struct {
    method:  Method,
    path:    string,
    query:   string,
    headers: []Header_Pair,   // requires Header_Pair to be public — see D-14.2
    body:    string,
}
test_request :: proc{ test_request_path, test_request_full }
```

* **Decisions before tests.**
  * **D-14.1 — can an exported procedure group have `@(private)` members?** If
    yes, the group name is the only new export and the ledger grows by exactly
    one. If no, both members export. **Determine by compile probe before
    proposing any ledger number.**
  * **D-14.2 — how are headers expressed?** `Header_Pair` is package-private
    (`web/headers.odin:46`). Making it public grows the *application* ledger for
    a test-only need (bad); a test-support-only pair type costs one more
    test-support symbol; `headers: []string` as alternating name/value adds no
    type but weakens typing. State the cost of each.
  * **D-14.3 — does `Recorded_Response` gain headers?** Phase 2's own gate wants
    to assert `X-Request-Id` on a response. Proposal: **no** — assert it from an
    internal `package web` test in Phase 2, record the user-facing pressure as
    an open question, and let Phase 4 (CORS, cookies) pay for it. Say plainly
    that this means users cannot assert response headers in Phase 2.
  * **D-14.4 — parity.** The full variant must drive the *same* driver path as
    the simple one and as the real adapter. It must not become a second dispatch
    route with its own semantics.
* **RED tests.** A public test that POSTs a JSON body through `test_request` and
  asserts a 201, failing before implementation; a compile probe for D-14.1; a
  ledger assertion that fails at 2 and passes at the approved number.
* **Minimal implementation.** Extend `testing.build_request` to carry query,
  headers and body; the facade converts and calls the existing `driver_run`. No
  new dispatch path.
* **Mutation probes.** Drop the body in the facade → the new test fails. Bypass
  `driver_cleanup` → a leak check fails. Add a third unlisted export → the
  ledger check fails.
* **Ownership and lifetime.** `Test_Request` fields are **borrowed** for the
  duration of the call; the framework copies nothing beyond what the recorder
  already copies. `Recorded_Response.body` stays valid until `destroy(&app)`.
* **Failure behaviour.** A body over 4 MiB must produce the same
  `body_too_large` 413 the real adapter produces — parity with WP8 D3 is a test,
  not an assumption.
* **Security.** The test transport must not become a way to bypass the body cap,
  which is a real security control.
* **Binary cost.** G-11 holds absolutely: an application that never calls
  `test_request` links **zero** `web/testing` symbols, with the positive control
  in `build/check_g11_teardown.sh` still green.
* **Rollback.** The group reduces to its single Phase-1 member; existing call
  sites are untouched because the simple form is a member of the group.
* **Out of scope.** Response headers in `Recorded_Response`; a builder type with
  a lifetime; multipart; a `test_serve`.

---

## WP15 — Phase-2 specification, ADR closure, ledger proposal

**Type: SPEC. Requires owner approval — this is the Phase-2 Spec Gate.**

> **Status: APPROVED (owner, 2026-07-19, PR #30 review).** The specification
> is `planning/phase-2-spec.md`; ADR-022 … ADR-027 in `planning/adrs.md` are
> all decided — ADR-025 as **option B** (one-route `Router`; the five verbs
> stay frozen, so WP18's "owner approval if the verbs gain a variadic" case
> does not arise). `phase-2-spec.md` §9 now supersedes §3 of this plan as the
> ledger of record — §9 also corrects an arithmetic slip in §3's
> application-ledger range and folds in the WP14 outcome (test-support stayed
> at 2 by default parameter, ADR-021 as amended). Approved ledger: 44
> application + 2 test-support = **46**.

Turns WP12/13/14 evidence into normative text. Decisions to close:

* **ADR-005** moves from PROPOSED to ACCEPTED, recording the B1/B3 choice.
* **Ordering rule**, stated exactly: global (in `use` order) → each mounted
  router's middleware outermost-first → route-level middleware → handler.
* **Miss chain** (D-12.4) and **no retroaction** (D-12.5), written normatively.
* **Group/router design.** Recommendation, with its G-01 argument, is
  **`Router` + `router()` + `mount()` and no `web.group`**: once a detached
  `Router` can be mounted at a prefix, `group(&app, "/admin")` is sugar for
  "make a router, mount it here" — a second canonical way to do one operation,
  which G-01 rejects. Adopting this **requires amending
  `knowledge-base/03-development-phases.md` §Phase 2**, which lists `web.group`,
  and the alternative must be written up fairly so the owner is choosing rather
  than rubber-stamping.
* **Route-level `use`**: variadic on the five verbs (D-12.7, mutates five frozen
  signatures) versus a one-route `Router` (no signature change, more typing).
* **Framework event** fields, redaction policy, observer isolation, behaviour
  after commit.
* **Request-ID trust policy** (client-supplied versus always generated).
* **Recovery definition** per WP13.

Every specified clause must name the work package that will pay for it and the
measurement that will prove it — G-08 forbids claiming a default before it is
delivered. Completion: every Phase-2 Spec Gate checkbox in the phases doc is
ticked with a pointer to the clause that ticks it, and the ledger in §3 is
accepted, amended or rejected by the owner.

---

## WP16 — Gate restructuring for Phase-2 growth

**Type: TESTS. No approval required.**

> **Status: DELIVERED, pending one full-gate run on the pinned toolchain.**
> The web/ and web/testing file sets are derived from in-file ledger markers
> (`// druse:file application|test-support|test-machinery`) instead of
> enumerated; the adapter is derived as the single backend importer; the
> vendor code-shape greps are replaced by wire-corpus coverage assertions;
> private declaration pins (`response_commit`, `dispatch`) are
> parameter-name-agnostic; every sed mutation self-asserts its edit and
> reports BROKEN PROBE instead of accusing the guardrail; and the six WP16
> acceptance controls are executable (`build/check_wp16_controls.sh`, plus
> permanent cases 56–61 in `build/check_wp3_mutations.sh`). Ledger counts,
> the `odin doc` snapshots, the compile probes and the G-11 `nm` gate are
> unchanged. The freeze manifest's G-06 evidence row now cites the derived
> check.

Implements audit A-6 **before** Phase 2 adds files. The gate enumerates
permitted filenames (`check_public_api.sh:62-77`) and pins exact declaration
lines and parameter names, so roughly a third of it fails on behaviour-preserving
refactors. Phase 2 adds about five files and will not survive that.

**Contract — keep, exact:** ledger counts and membership; the `odin doc`
signature snapshot; the compile probes; the mutation suite; the `nm`
measurements (G-11).
**Text — derive instead of listing:** the permitted `web/*.odin` file set.
**Text — delete:** the vendor patch code-shape greps (audit A-10 — the raw-wire
corpus is the real evidence), replaced by an assertion that
`tests/wp9-wire/` covers each of the five patch cases.
**Text — soften:** exact parameter-name pinning, superseded by the `odin doc`
snapshot, which already covers signatures semantically.

**Mutation controls:** (a) a stray `web/oops.odin` must fail; (b) an extra
export must fail; (c) renaming a private parameter must now **pass** — that is
the point; (d) deleting a ledger entry must fail. Also fix the misleading
"mutation was ACCEPTED" report at `check_wp3_mutations.sh:135`, which lies when
its `sed` fails to match.

A failing gate must tell a maintainer **what contract broke**, not accuse them of
needing a spec amendment for a rename. Track gate runtime: ~2 minutes today, and
Phase 2 adds roughly nine suites — if it passes ~4 minutes the pre-push hook
becomes something people bypass.

---

## WP17 — `use` + `next` + flattened chains at app level

**Type: IMPLEMENTATION.**

* **Objective.** Ship `web.use(&app, mw)` and `web.next(ctx)` with chains
  flattened at registration and dispatch that allocates nothing.
* **Public surface (PROPOSED).** `use`, `next`. **+2.** No `Middleware` type
  (D-12.1).
* **Likely files.** `web/middleware.odin` (new), with small additions to
  `dispatch_table.odin` (`chain_start`/`chain_len` on `Route_Entry`),
  `dispatch_match.odin` (set cursor, invoke first), `context.odin` (private
  cursor), `app.odin` (pool + teardown). Layout not frozen; the gate must accept
  a derived file set (WP16).
* **RED tests.** Order across three global middleware; short-circuit stops
  downstream *and* the handler; post-`next` behaviour per the ratified B1/B3;
  `next` from a handler; middleware with neither `next` nor a response → 500;
  global middleware observed on 404 and 405 (D-12.4); `use` after `get` does not
  wrap retroactively (D-12.5); `destroy` frees the pool exactly once; `bare()`
  runs user middleware but installs no defaults.
* **Minimal implementation.** One `[dynamic]Handler` pool on `App_Internal`;
  `use` appends to a pending stack; `route_register` copies the pending stack
  into the pool and records `(start, len)`; dispatch sets the cursor and calls
  the first entry; `next` advances. **Index pairs, never slices** (D-12.2, P8).
* **Mutation probes.** Reverse the flattening order → order test fails. Make
  `next` not advance → the bounded-recursion test catches it. Allocate a chain
  per request → the tracking-allocator test fails. Store a slice → the
  pool-growth test corrupts. Skip the miss chain → the 404-observability test
  fails.
* **Ownership.** Pool owned by the `App`, freed once. The cursor is three `int`s
  on `Context_Internal`, request-scoped, never escaping. Middleware are plain
  procedure values — no closures, nothing to free.
* **Security — ENFORCED, not documented (ADR-019, accepted 2026-07-19).**
  Ordering is the security boundary: WP12 measured a mis-ordered program
  serving `/admin/users` with `200 OK` to an unauthenticated caller, with no
  error and no runtime symptom. Documentation alone was rejected: for security,
  prose is not enforcement. **`use()` after any route has been registered is a
  boot failure, fail-closed** — a one-line guard at registration. RED tests must
  include the mis-ordered auth program *failing to start*, not merely a comment
  warning about it. Sub-decisions (does it apply inside a `Router`; is `mount()`
  a registration; the exact failure mechanism and message; does `bare()` enforce
  it too) are listed in ADR-019 and settled by WP15 before this work package
  writes tests.
* **Binary cost.** Zero-middleware apps pay at most the WP12 P11 measurement;
  dispatch allocations through a 5-chain are **zero**, asserted by a test shown
  able to fail.
* **Rollback.** Additive: a route with `chain_len == 0` is exactly the Phase-1
  path.

---

## WP18 — `Router` + `mount` + route-level middleware

**Type: IMPLEMENTATION. Owner approval required if the five verbs gain a
variadic.**

* **Value.** A module exports its routes (`users_router :: proc() -> web.Router`)
  and an application mounts them under a prefix with middleware inherited.
* **Public surface (PROPOSED).** `Router`, `router`, `mount` — **+3**. The five
  verbs, `use` and `destroy` become **procedure groups**, which adds **zero**
  names: the Odin-native way to add variants.
* **Decisions.** Does `mount` consume or copy? (Proposal: copy; the caller
  destroys its own router — one ownership rule, same as `App`.) Mount twice?
  (Proposal: yes, producing two independent flattened sets.) Router into router?
  (Proposal: yes — nesting is where outer-then-inner ordering comes from.)
  Prefix grammar: must begin with `/`, must not end with `/`, `"/"` is identity,
  nothing normalised (consistent with WP4 D5).
* **RED tests.** Prefix concatenation exactness including `"/"`; nested ordering;
  the same router mounted twice; `Allow` for a mounted path; a WP4-invalid
  pattern stays invalid after prefixing; `destroy(&router)` after `mount` does
  not invalidate mounted routes (the App cloned the patterns); destroying a
  never-mounted router leaks nothing.
* **Minimal implementation.** `Router` holds pending registrations; `mount`
  walks them, concatenates prefixes and calls the same private `route_register`
  the verbs use — exactly one registration path.
* **Ownership.** Two owned values now exist (`App`, `Router`), each destroyed
  once, neither ever copied — the *same* rule restated. This is the phase's one
  new ownership model, which is why it is its own work package.
* **Security.** Prefix concatenation is path construction; a bug here mounts
  routes at unintended paths. Test `"//"`, empty prefix, a prefix containing a
  `:param`, and a prefix that swallows a trailing segment.
* **Out of scope.** `web.group` unless the owner rejects the WP15
  recommendation; route-info accessors; conflict diagnostics (Phase 3).

### Amendment 1 (2026-07-20) — `mount` is fail-OPEN on allocation failure

**Status: RESOLVED. Owner accepted option (A) — poison on failure — on
2026-07-20 (docket D-1). Implemented in the same change as this status update;
`web/router.odin` now checks every allocation and rejects the application
fail-closed, with `build/check_wp18_controls.sh` control 6 proving a
regression goes red.**

`mount` validates the prefix, the poisoned flag and the closed flag **before**
the publication loop, which is correct. The loop itself, however, publishes with
`strings.concatenate` and `append` and **checks neither result**. In Odin an
`append` that cannot allocate does **not** panic: `_append_elem` returns
`num_appended = 0` and reports the failure through
`#optional_allocator_error`, which every call site in `mount` discards.

**Measured**, with a `mem.Arena` of fixed capacity installed in
`context.allocator` — a legal, documented Odin practice, and the same shape
Phase 3's arena work (P3-10) will make more common:

```text
12 routes, arena 1024..1536 B -> App has  8/12 routes, poisoned = false
 5 routes, arena  256.. 512 B -> App has  0/5  routes, poisoned = false,
                                 Router closed = true, mw_pool = 10 orphans
```

So routes vanish with **no diagnostic**, the App reports **healthy**, `serve`
binds, and every lost route answers 404. The Router is left `closed`, so the
mount cannot even be retried. This is fail-open in the one place ADR-019 exists
to make fail-closed, and it is an undeclared exception to this project's own
rule.

The recommended repair is the **smaller** one: check the results and **poison
the App** through the mechanism WP17/WP18 already own. Once poisoned the App
refuses `serve` and answers 500 on both transports, so the partial state stops
being observable — full transactional rollback buys atomicity the poison
already renders moot. RED proof: the arena probe above, asserting
`poisoned = true` and a `serve` refusal.

**Delivered.** `mount` now checks `make`, `strings.concatenate` and every
`append` — including the ones inside `mount_chain_flatten`, where a missing
step would run a protected route with an auth guard silently absent, which is
the security face of the same bug. Any failure rejects the application through
the existing WP17/WP18 poison. RED evidence, recorded before the fix:
`/api/a12` answered **404** — a route the developer wrote, indistinguishable
from one that never existed. After: 500 on every path, and `serve` refuses.

Two follow-ups this amendment deliberately does NOT do:

* it does not add a `Framework_Error` member for the failure. Poison
  diagnostics are logged and not observed today (WP17/WP18 precedent), and a
  new enum member is a public-surface change requiring its own approval;
* it does not make the failure recoverable. The application is rejected, not
  repaired — consistent with every other member of the ADR-019 family.

---

## WP19 — Request header lookup: `header`, `bearer_token`

**Type: IMPLEMENTATION.**

* **Public surface (PROPOSED).** `header(ctx, name) -> (string, bool)`,
  `bearer_token(ctx) -> (string, bool)`. **+2.** Both `(value, ok)`; the audit
  classes them `ODIN_NATIVE`, and `#optional_ok` is **not** used, consistent
  with ADR-002 and core practice.
* **Decisions.** Case-insensitivity (HTTP field names are case-insensitive —
  must be, ASCII-only folding, allocation-free). Duplicates: **first occurrence
  wins**, matching WP5 D4's query rule — one rule, one mental model; joining
  would allocate. Empty value: present, `ok == true`. `bearer_token` grammar:
  scheme compared case-insensitively, exactly one space, non-empty token, no
  trailing-whitespace tolerance — say so and test it. Whether `header` reads a
  middleware-writable overlay (needed by WP23) or strictly what arrived.
* **This work package owns audit A-8.** Inbound headers are currently
  materialised into `[]Header_Pair` and read by nothing; Phase 2 is when they
  become read, so this is where that cost becomes purposeful or is deferred with
  a measurement.
* **RED tests.** Present/absent; case-insensitive both directions; empty value;
  duplicates; `Bearer`/`bearer`/`BEARER`; missing scheme; no token;
  `Bearer  x` (two spaces); a token with spaces; `Basic`; no `Authorization` at
  all; the returned value is a **view** invalidated at request end (port of the
  WP2 view test).
* **Failure behaviour.** **No response side effect** — these are pure lookups,
  unlike the extractors, which commit a 400. That asymmetry must be stated
  explicitly in the docs; the justification is that an absent header is
  routinely *not* an error.
* **Security.** Header values are attacker-controlled. Nothing may be logged —
  the audit's refuted log-leakage concern must **stay** refuted, so do not
  import `core:log` or `core:fmt` here. `bearer_token` must not trim or
  normalise the token, because normalising comparisons invite secret-handling
  bugs upstream.
* **Out of scope.** Setting response headers publicly; cookies (Phase 4);
  forwarding headers (Phase 4, ADR-013).

---

## WP20 — Typed framework-error observer

**Type: IMPLEMENTATION.**

* **Objective.** Deliver ADR-011's promised Phase-2 typed observer: one closed
  event, never `any`, no change to the handler shape.
* **Public surface (PROPOSED).** `Framework_Error` (the existing private enum,
  made public), `Framework_Event` (closed struct), `observe`. **+3.**
* **Decisions.** Exact field set — and the external research is decisive here:
  the event must carry **low-cardinality route identity (the pattern), never the
  raw path**, per the OpenTelemetry HTTP conventions, or it becomes both a
  cardinality explosion and a PII leak. Does the event carry a message string?
  **Proposal: no** — `framework_report` today takes a `typeid` and a closed enum
  and emits one of six compile-time constants, and that property is precisely
  why the audit could refute the log-leakage concern outright. Do not surrender
  it. One observer, last registration wins — a list adds an allocation and an
  ordering question for no evidenced need.
* **RED tests.** Every `Framework_Error` variant observed exactly once; an
  observer that responds cannot produce a second write and the first response
  stays byte-identical; no observer → identical behaviour to today; `bare()`
  installs none; the event contains no raw path and no header, body or query
  value.
* **Ownership.** The event is passed **by value**, and every string in it is a
  static constant or an App-owned pattern — never a request view. So an observer
  that stores the event cannot dangle. State this: it is the property that makes
  the design safe.
* **Security.** Redaction is the whole point. Add a gate assertion that
  `Framework_Event`'s field types admit no request-derived string.
* **Out of scope.** Metrics and tracing hooks (Phase 4); application-domain
  error mapping, which stays a plain `switch` in user code — the audit found it
  needs no framework concept.

---

## WP21 — Recovery: default in `app()`, absent in `bare()`

**Type: DOCUMENTATION + TESTS. Shape decided: ADR-020 (R-b), zero public
symbols.**

* **Public surface: ZERO symbols (ADR-020, accepted 2026-07-19).** WP13 ran;
  the owner accepted **R-b**. There is no `recovery` symbol and no recovery
  middleware. Phase 2's guarantee is the WP8 driver behaviour — a handler that
  commits no response is finalized to a standardized 500 — plus documentation
  stating plainly that a panic aborts the process. The phases-doc amendment has
  already landed; this work package delivers the documentation and the tests.
* **RED tests.** `app()` installs it and `bare()` does not, asserted through
  observable behaviour rather than by reading internals; whatever fault class
  WP13 proved recoverable produces the standardized 500 envelope; a second fault
  behaves like the first.
* **Mutation probes.** Remove the install from `app()` → default test fails. Add
  it to `bare()` → fails. Return 200 on fault → fails. Emit a message containing
  the fault text → the redaction test fails; an internal fault message must
  never reach the client, which is exactly what `internal_error(ctx)` taking no
  message already encodes.
* **Failure behaviour.** If the fault is unrecoverable, the process aborts and
  the documentation says so plainly. **G-08: do not claim a default that is not
  delivered.**
* **Binary cost.** A default-on middleware is on `app()`'s static path and
  therefore **cannot** be lazily linked the way the test-support facade is. The
  cost is unavoidable, must be measured with `nm` and `size`, and is
  human-reviewed. Hard rule: no `core:fmt`, no `core:log`.
* **Out of scope.** Signal handling; graceful shutdown; supervisor integration.

---

## WP22 — `logger` middleware

**Type: IMPLEMENTATION.**

* **Public surface (PROPOSED).** `logger :: Handler`. **+1.** Opt-in via
  `web.use(&app, web.logger)` — **not** default-on; the phases doc makes only
  recovery default-on, and G-08 forbids inventing defaults.
* **The constraint that dominates the design.** WP6 measured that importing
  `core:log` added ~37 KiB to *every* application, because Odin links an
  imported package whether or not it is referenced. `logger` must therefore
  write through `context.logger` with a fixed request-local buffer and manual
  integer formatting (the WP5 escaper is the precedent), or the framework
  regains the 37 KiB. Also: a latency-measuring logger needs post-`next` — so
  `logger` is the concrete case that makes the B1/B3 decision matter, and it
  must be built the way WP15 ratified.
* **RED tests.** Logs once per request; logs a 404 (requires the miss chain);
  records status and method; **never** emits a query string, header or body
  byte; ordering relative to other middleware.
* **Ownership — this work package implements audit R-9.** Its fixed
  request-local buffer is aliased by the committed response, so it must consult
  `committed` **before** writing. Route scratch writes through **one helper**
  that checks the guard, rather than creating a seventh hand-written guard.
* **Security.** Route pattern, not raw path. No header values. No body. Per
  OWASP's logging guidance, CR/LF must be escaped in anything echoed.
* **Binary cost.** An application that never references `web.logger` links zero
  logger symbols and its binary is byte-identical to WP17's baseline.
* **Truncation is OBSERVABLE (amendment, 2026-07-20).** A fixed request-local
  buffer has a boundary, and what happens at that boundary is a contract, not
  an implementation detail. A route pattern or a line that exceeds the buffer
  must be truncated in a way a TEST can detect — never grown silently (which
  would defeat the fixed buffer and re-import the allocation the buffer exists
  to avoid) and never dropped without a signal (which would make a logger
  quietly lie about traffic it saw). Pick one, write it down, and prove it.
  This is the reference discipline "a bounded resource states what it does when
  full" applied at the smallest scale the framework has.
* **Out of scope.** Structured logging, sinks, sampling, levels (Phase 4). No
  log ring, queue, drop policy or non-blocking sink in the framework now: those
  are Phase-4 observability, and building them here would put an unbounded
  queue behind a "bounded buffer" claim.

### Amendment 1 (2026-07-20, WP22) — "byte-identical binary" is NOT TESTABLE; the claim is the SYMBOL COUNT

The bullet above asks that an application which never references `web.logger`
have a binary "byte-identical to WP17's baseline". **That property cannot be
tested on the pinned toolchain, and the requirement is withdrawn** — replaced
by a stronger-in-practice one that can be.

**The measurement.** Five consecutive builds of an *identical, unmodified*
source tree produced five *different* binaries: 876,304 / 876,352 / 876,352 /
876,368 / 876,360 bytes, five distinct md5 sums. The compiler does not build
reproducibly here — the vendored `nbio` emits polymorphic instantiations whose
mangled parameter names vary from run to run (`_poly_cb:proc(C:$proc(_:^nbio::
Operation,...))` versus `...(op:^nbio::Operation,conn:...)`). Byte-identity
therefore fails for a tree compared against **itself**, so a gate asserting it
would flake rather than guard.

**What ships instead**, in `build/check_wp22_controls.sh` control 7: `nm` over
two real consumers. An application that never names `web.logger` links
**zero** symbols from `web/logger.odin`, and — the positive control, without
which a typo in the pattern would make the zero-assertion vacuous — an
application that *does* use it links **six**. The count is stable: 0 across all
five rebuilds above. The symbol pattern must match BOTH `web::logger` (the
public entry) and `web::[logger.odin]::*` (the helpers); an earlier version
matched only the file-qualified form and would have missed a regression that
linked the public procedure while dead-stripping its helpers.

**The general lesson, for WP23-WP25.** "Byte-identical binary" is not a
provable claim in this project and must not be written into another work
package. Where a phases document or plan says it, read it as "links zero
symbols, measured with a positive control" — and if a future claim needs
reproducible builds, that is its own work package, not a line item inside
another one. This is the "measure instead of assert" rule catching a
requirement the plan itself had asserted.

---

## WP23 — `request_id` middleware and its trust policy

**Type: IMPLEMENTATION. Requires owner approval — new security boundary.**

* **Public surface (PROPOSED).** `request_id :: Handler`. **+1.** Reading it is
  `web.header(ctx, "X-Request-Id")`, which requires the middleware to write into
  a private request-header **overlay** that `header` consults. If the owner
  rejects the overlay as too implicit, the alternative is a second symbol
  (`request_id_value`), making it +2. Recommend the overlay, and document
  `web.header` from WP19 as "the effective request header" so the coupling is
  declared rather than discovered.
* **Trust policy (the security boundary).** Is a client-supplied `X-Request-Id`
  echoed? Proposal: accepted only if it matches a strict charset
  (`[A-Za-z0-9._-]`) and length (1..64); otherwise a fresh ID is generated and
  the client's value is discarded and **never logged**, since it is
  attacker-controlled.
* **ID generation.** `core:crypto` is heavy and unnecessary — a request ID is
  not a secret and must not be mistaken for one. A counter plus process-start
  entropy suffices and must be documented as **not unguessable**. Fixed-size,
  allocation-free encoding into request-local storage.
* **RED tests.** Absent inbound → generated, present on the response, readable
  by the handler; valid inbound → echoed; oversized → replaced; **CR/LF →
  replaced (header injection)**; non-ASCII → replaced; two requests get
  different IDs; `bare()` without the middleware sets no header; the ID appears
  on a 404.
* **Mutation probes.** Echo without validation → the CR/LF test fails. Reuse one
  ID → uniqueness fails. Allocate per request → the tracking-allocator test
  fails. Emit the header twice → a duplicate-header test fails.
* **Reuse, proven before it can break (amendment, 2026-07-20).** Add a RED test
  that two consecutive requests on the same application never let the second
  observe the first's ID. Today the property is STRUCTURAL and the test passes
  on arrival: `Context` is a fresh stack value in `serve_dispatch` and in
  `test_request`, so the overlay starts zeroed every time and there is nothing
  to leak. Write it anyway — Phase 3 (P3-10) plans buffer reuse and Phase 4
  plans connection slots, and this is the test that turns a structural accident
  into a defended invariant on the day something starts being pooled. The
  overlay stays ONE slot with known capacity: the phase needs a request-ID slot,
  never a general-purpose map (G-03).
* **Security.** This is the work package's centre of gravity. Header injection
  via CR/LF is the concrete attack; the ID must never be treated as
  authentication.
* **Out of scope.** Trusted proxies and `X-Forwarded-*` (Phase 4, ADR-013);
  `traceparent` propagation (Phase 4).

---

## WP24 — Examples, documentation, and the canonical auth pattern

**Type: DOCUMENTATION.**

* **Public surface. None.** `require_auth` and `current_user` are **application
  code in the example**, not framework symbols. That is the point: the framework
  provides `bearer_token`; the application provides its own typed gate and typed
  lookup.
* **The decision this work package must confront honestly.** With G-03
  forbidding a context bag and Phase 3 owning typed state, `require_auth`
  **cannot hand the user object to the handler**. The documented pattern is
  therefore:
  * `require_auth(ctx)` — gate only: `bearer_token` → validate → on failure
    `web.unauthorized(ctx, ...)` and return without `next`; on success `next`.
  * `current_user(ctx) -> (User, bool)` — an application procedure that
    **re-derives** the user from the token.

  Cost: one revalidation per handler call. The documentation must say this
  plainly, say why (no dynamic request-local storage exists until Phase 3), and
  say what Phase 3 will change. Pretending the cost is not there would be the
  dishonest version.
* **Deliverables.** Examples `04-middleware`, `05-route-groups`,
  `06-authentication`; full doc parity; and audit recommendations R-3 (never
  copy an `App` or `Router`, naming `strings.Builder` as the analogy an Odin
  programmer already knows), R-4 (the zero-value `App` contract), R-10 (exactly
  one server per process, no stop until Phase 4).
* **Mutation probes.** A `user_data`-shaped field in the example → the guardrail
  scan fails. `require_auth` registered *after* the protected route → the
  example's own test must fail loudly, making the D-12.5 hazard visible.
* **Binary cost.** Extend the audit's pay-for-what-you-use table with
  middleware, router, header lookup, logger and request ID.
* **The ownership table (amendment, 2026-07-20).** Phase 2 handed the user five
  new things that are borrowed rather than owned, and "copy it if it must
  outlive the request" is currently spread across a dozen doc comments. WP24
  gathers it into ONE canonical table, and the docs gate requires it. One row
  per value the user can touch, and every row answers the same four questions —
  **owner, valid until, may it escape, who cleans up**:

  | Value | Owner | Valid until | May escape? | Cleanup |
  |---|---|---|---|---|
  | route pattern | App | `destroy(&app)` | only as a documented view | App |
  | inbound header value | transport | end of the request | no, copy first | transport |
  | path/query parameter | request arena | end of the request | no, copy first | driver |
  | effective request ID | Context overlay | end of the request | no, copy first | driver |
  | `Framework_Event` | the value itself | unbounded | **yes**, by value | none needed |
  | middleware pool | App | `destroy(&app)` | no | App |

  This is the single most transferable idea from the reference study: a framework
  that hands out borrowed memory owes its users a table, not a habit of
  mentioning it. Teach ownership, limits and the failure model — never the
  external concepts that produced the discipline.

---

## WP25 — Phase-2 review, mutation gate, and freeze

**Type: FREEZE. Requires owner approval.**

Full ledger diff; `odin doc` signature snapshot refresh; the complete mutation
suite re-run (Phase 1 ended with 50+ rejected cases; Phase 2 adds its own and
all must still be rejected); `nm` measurements for every "costs nothing when
unused" claim made in WP17–WP23, **each with a positive control**; a written
G-09 evidence row per new symbol; and a re-run of the audit's usage laboratory
with middleware and groups added.

That last item is the honest check: if a five-route CRUD service now needs 25
concepts instead of 14, **that is a finding**, not a footnote.

Any symbol without all its G-09 evidence stays private or is removed before
freeze. Any unexplained binary cost is a human-review blocker, as G-11 requires.
Output: `planning/phase-2-freeze.md`, mirroring `phase-1-freeze.md`.

### Amendment 1 (2026-07-20) — freeze the CLAIMS, not only the API

**Status: ACCEPTED (owner, 2026-07-20, docket D-2) — all three ledgers, with
the scope limit below.** This is now part of WP25's definition of done: the
freeze does not pass without them.

Phase 1 froze symbols, signatures and dependencies. It did not freeze the
project's own *sentences*. The reference study is the argument for closing that gap,
and the argument is empirical rather than theoretical: an equally careful
project was measured against its own README and **six of its public claims came
back "imprecisa" or "não demonstrada"** — not because anyone was dishonest, but
because prose has no compiler and drifts while every test stays green. Druse
has already lived a small version of this: WP21 found three active documents
still promising a "panic recovery (Phase 2)" that ADR-020 had made impossible.

WP25 therefore freezes three further ledgers. They add **zero public symbols**;
the cost is documentation and gate.

**1. Claim ledger.** One row per strong promise the project makes out loud, in
`README.md`, `docs/` or `CHANGELOG.md`. Each row carries: the exact sentence,
its scope, where it is implemented, the positive test, the **negative control**
that fails when the property is removed, the environment it was measured in,
and — the column that does the real work — **what it explicitly does NOT
guarantee**. A claim with no negative control does not freeze.

Deliberately bounded: only claims the project ALREADY makes. Do not invent
claims to fill the table.

**2. Lifetime ledger.** The WP24 ownership table, promoted to frozen evidence:
owner, validity, may-it-escape, cleanup, one row per value.

**3. Capacity ledger.** What is fixed, what is dynamic at registration, what is
bounded per request, and what remains unbounded or delegated to the backend.
This ledger exists to keep an honest word honest: **"bounded" must never be
claimed for the framework as a whole** while connections, queues and header
counts belong to the transport. Say which perimeter is bounded, or do not use
the word — the same discipline that forbids "zero allocation" as a slogan
without a perimeter and a test.

---

## 3. Proposed Phase-2 public ledger

Phase 1 froze **32 application + 2 test-support = 34**. Recommended additions,
each justified against G-01 (no second canonical way) and G-09 (growth carries
evidence):

### Application ledger — +11 recommended

| Symbol | Kind | WP | G-01 justification |
|---|---|---|---|
| `use` | proc group | 17, 18 | the only way to register middleware; the group adds variants without a second name |
| `next` | proc | 17 | the only way to continue a chain; short-circuit is its absence, so no second "abort" symbol |
| `Router` | type | 18 | the only route-aggregate type |
| `router` | proc | 18 | constructor mirroring `app()`; `destroy` is a group, so no `router_destroy` |
| `mount` | proc | 18 | the only way to attach a `Router` |
| `header` | proc | 19 | the only request-header lookup |
| `bearer_token` | proc | 19 | **not** a spelling variant of `header`: it encodes an RFC 6750 parse (case-insensitive scheme, exactly one space, non-empty token) that every application would otherwise reimplement, with security consequences when done wrong |
| `observe` | proc | 20 | the only framework-event registration |
| `Framework_Event` | type | 20 | the closed event ADR-011 promised; the alternative is `any` |
| `Framework_Error` | enum | 20 | the event's `kind` must be typed; already exists privately |
| `logger` | `Handler` value | 22 | the only built-in logger |

### Conditional — +2, each decided by its own work package

| Symbol | Condition |
|---|---|
| ~~`recovery`~~ | **RESOLVED — does not exist.** WP13 ran and the owner accepted R-b (ADR-020). Recovery is the WP8 driver guarantee plus documentation; zero symbols. |
| `request_id` | +1 as a middleware value; +2 if the owner rejects the `header` overlay and a `request_id_value` accessor is required. |

### Explicitly rejected

* **`web.group`** — with `Router` + `mount`, `group(&app, "/admin")` is exactly
  "make a router, mount it here". G-01 rejects a second canonical way. Rejecting
  it requires amending the phases doc and is a WP15 owner decision, not a
  unilateral one.
* **`Middleware` type** — middleware is the frozen `Handler` shape (D-12.1).
  Zero names, and ADR-011 is satisfied by construction rather than by policing.
* **`require_auth` / `current_user`** — application code in example
  `06-authentication`. The phases doc calls them a *documented pattern*, which is
  the correct reading.
* **`Route_Info`, route accessors, `abort`, `set_header`, `Middleware_Group`,
  `Chain`, and anything shaped like `user_data`/`locals`/`map[string]any`.**
* **Per-verb middleware names** (`get_with`, `use_route`) — route-level
  middleware is a variadic on the existing verbs or a one-route `Router`; either
  way, zero new names.

### Test-support ledger — +1 recommended

`Test_Request`, the payload struct for the `test_request` procedure group.
**Depends on D-14.1**: if an exported procedure group cannot have `@(private)`
members on the pinned toolchain, this becomes +2. `test_request` and
`Recorded_Response` keep their names, and `Recorded_Response` does **not** gain
headers in Phase 2 (D-14.3).

### Resulting counts

| Ledger | Phase 1 | Phase 2 Δ | Total |
|---|---|---|---|
| Application | 32 | +11 recommended, +12 if `request_id` needs an accessor | **43 – 44** |
| Test-support | 2 | +1 (possibly +2) | **3 – 4** |
| **Union** | **34** | **+12 – +14** | **46 – 48** |

**Narrowed by ADR-020.** The upper bound dropped from 49 to 48 because recovery
is now known to add nothing. One of the three contingencies is closed.

The number the gate asserts is decided in WP15 and frozen in WP25. It is still stated
as a range on purpose: two increments remain contingent on outcomes (WP14,
WP23), and pre-committing to a single number would be exactly the "claim a
default before it is delivered" failure G-08 forbids. WP13's contingency is now
closed at zero.

For scale: roughly 35% growth of the application surface buys middleware, route
organisation, request headers and the typed observer — four of the six things
the audit's usage laboratory found impossible in Phase 1. The remaining two
(response headers, shutdown) stay unbought, by design.

---

## 4. Risks this plan does not resolve

1. ~~**Recovery may be undeliverable as specified**~~ — **RESOLVED.** WP13 ran
   and confirmed it: `app()` can never install a hook (`context` is by-value),
   and bounds-check, nil-deref and divide-by-zero faults never reach a hook at
   all. The owner accepted R-b (ADR-020): recovery is the WP8 driver guarantee
   plus honest documentation, at zero public symbols. The accepted cost is that
   a panicking handler closes the connection and the process falls over for a
   supervisor to restart.
2. ~~**Registration-order middleware semantics** is a footgun~~ — **RESOLVED,
   and more strongly than this plan originally proposed.** WP12 measured the
   footgun as a live `200 OK` to an unauthenticated caller. The owner rejected
   the documentation-only mitigation outright and accepted enforcement
   (ADR-019): `use()` after any registered route is a boot failure. What remains
   is scope, not principle — whether the rule extends to `Router`, `mount` and
   `bare()`, and what the failure message says. WP15 settles those.
3. **Route-level middleware may require mutating five frozen signatures**
   (D-12.7). If the owner refuses, it is delivered as a one-route `Router` and
   the phases doc is amended.
4. **Gate growth** (audit A-6). The gate already equals the framework in size.
   WP16 slows that, but Phase 2 adds about nine suites; if the gate passes ~4
   minutes, the pre-push hook becomes something people bypass.
5. **`Recorded_Response` header pressure** (D-14.3). Phase 2 ships middleware
   whose primary output is a response header that users cannot assert. Accepted,
   recorded, and expected to force a Phase-4 decision early.
