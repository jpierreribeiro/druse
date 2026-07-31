# Phase 2 — Specification (the WP15 Spec Gate)

**Status: APPROVED (owner, 2026-07-19, PR #30 review).** ADR-022, -023, -024,
-026 and -027 were accepted as recommended. **ADR-025 was decided as option
B** — route-level middleware is a one-route `Router`, the five Phase-1
registration signatures stay frozen — against the WP15 recommendation; the
clauses below are updated to the decided state. The owner's review also
independently re-verified the §9.1 ledger correction and ran the full gate
green on `9f7e64a` + the WP15 commit (`GATE_EXIT=0`, `PASS=10 FAIL=0 SKIP=0`,
126s). The PROPOSED/NORMATIVE labels below are retained with their outcomes so
the decision trail stays readable.

This document turns the WP12, WP13 and WP14 evidence into normative Phase-2
text. It has two kinds of clause, and every clause is labelled:

* **NORMATIVE (settled)** — the clause restates a decision the owner already
  accepted (ADR-005, ADR-019, ADR-020, ADR-021 and their sub-decisions). It is
  written as specification because the decision exists; this document adds only
  the exact wording, the owning work package, and the test that will prove it.
* **PROPOSED (owner decision required)** — the clause depended on a decision
  the owner had not yet made when this document was first presented. Each such
  clause points at an ADR in `planning/adrs.md` (ADR-022 … ADR-027) that
  presents the question, the options, a recommendation, the strongest argument
  against that recommendation, the public impact and the reversibility. **All
  six are now decided (2026-07-19); each clause below records its outcome.**

Every clause names the work package that implements it and the test or
measurement that will prove it, because G-08 forbids claiming a behaviour
before a test delivers it. Where a number is quoted, its source is the recorded
WP12/WP13/WP14 evidence (`planning/phase-2-prototype-middleware.md`,
`planning/history/phase-2-prototype-recovery.md`, `planning/phase-1-freeze.md`
amendments 1–2), which carries the verbatim commands and outputs.

§9 of this document now supersedes `planning/phase-2-plan.md` §3 as the ledger
of record, and the amendment texts in §10 have been applied to
`knowledge-base/03-development-phases.md` (§10.2 in its option-B form, per the
ADR-025 outcome).

---

## 1. What Phase 2 is, in one paragraph

Phase 2 adds middleware (`use`, `next`), route organisation (`Router`,
`router`, `mount`, route-level middleware), request-header lookup (`header`,
`bearer_token`), a typed framework-error observer (`observe`,
`Framework_Event`, `Framework_Error`), and two built-in middleware (`logger`,
`request_id`) — all expressed with the frozen `Handler` shape, zero new handler
forms, zero recovery symbols (ADR-020), and zero dispatch-time allocations
(WP12 P9, an acceptance criterion with a demonstrated negative control).

---

## 2. Execution order — NORMATIVE (ADR-005 + ADR-019; nesting order settled by ADR-024, ACCEPTED)

### 2.1 The order

For a request that matches a route, middleware and the handler run in exactly
this order, and unwind in exactly the reverse order:

1. **App-level middleware**, in `use` order. Because ADR-019 rejects `use()`
   after any registration, every app-level middleware applies to **every**
   route — a partially-wrapped route table is not a state a legal program can
   reach.
2. **Each enclosing `Router`'s middleware, outermost router first**, each
   router's own list in its `use` order (ADR-024, ACCEPTED). A route
   registered directly on the App has no enclosing router and skips this
   step. Under ADR-025 option B (ACCEPTED) there is no separate route-level
   position: a route needing its own guard is a one-route `Router` mounted at
   the path, so "route-level middleware" is simply the innermost router's
   `use` list — one ordering rule, not two.
3. **The handler.**

Short-circuit is returning without calling `next` (frozen vocabulary from the
phases doc): everything downstream — later middleware *and* the handler — does
not run, and every already-entered middleware still unwinds. Evidence shape:
WP12 P3 measured `A>STOP<A` with no `C>` and no `H`, and the short-circuiting
middleware's own response is what the client receives.

* Implementation: WP17 (steps 1, 3), WP18 (step 2).
* Proof: WP17 RED test asserting the exact order string `A>B>C>H<C<B<A` across
  three globals (P2's measurement made permanent); WP18 RED test for nested
  routers (outer `use` before inner `use` before handler, including the
  one-route-Router guard shape ADR-025 option B makes canonical); a
  short-circuit test asserting the downstream middleware count is zero and
  the committed response is the short-circuiter's.

### 2.2 Registration-time flattening

Chains are flattened at registration into one App-owned `[dynamic]Handler`
pool; each route stores the index pair `chain_start, chain_len: int` — **never
a `[]Handler`**. WP12 P8 reproduced the dangling-slice use-after-free under a
poisoning allocator (`0xaaaaaaaaaaaaaaaa` where a procedure pointer should be)
and, worse, P8b showed the same defect reading back *correctly* on the plain
heap — a latent corruption. Index pairs are immune by construction.

The invariant that makes index pairs sound is: **the pool is append-only and is
never compacted or cleared before `destroy`.** This is a stated contract, not
an assumption — WP12's D-12.2 counter-argument is that indices are a
hand-rolled pointer the compiler cannot check.

* Implementation: WP17.
* Proof: WP17 mutation probe — switching a route to slice storage must turn the
  pool-growth test red under the poisoning allocator; a gate comment-level
  assertion is not sufficient. Dispatch-time allocation is asserted zero by a
  `mem.Tracking_Allocator` test with P9's negative control (a deliberately
  copying chain must be caught: measured 1 allocation / 48 bytes).

### 2.3 Cost statements (measured, to be re-proven when WP17 lands)

* Zero allocations at dispatch through a 5-middleware chain (P9: `allocations=0
  temp_allocations=0 bytes=0`, negative control caught).
* Binary rent for an application registering no middleware: **+1,832 bytes**
  default build, **+1,048 bytes** `-o:speed` (P11). This is a G-11 human-review
  number and the owner accepts it by approving this specification. A lazier
  pool design could remove most of it (WP12 "could not determine" #3); WP17 may
  attempt it but is not required to.
* Flattening is quadratic in globals × routes: 20 routes × 5 globals = 120 pool
  slots = 960 bytes (P12). Stated so nobody is surprised; no action required at
  realistic sizes.
* Recursion consumes ~80 bytes per middleware (debug) / ~16 bytes (`-o:speed`);
  the practical bound is ~105,000 on an 8 MiB stack and ~6,200 on a 512 KiB
  stack (P10). Exceeding it is a **segfault, not a diagnostic** — the
  documentation must say so in one sentence (WP24).

---

## 3. The post-`next` promise — NORMATIVE (ADR-022 ACCEPTED: B1)

B2 ("leave it unspecified") was rejected on sight, as the plan already
rejected it: a mechanism whose behaviour is observable but undocumented is the
worst of both. The owner accepted **B1** (specified and tested). The normative
text:

1. **Code after `next(ctx)` runs**, exactly once per middleware, as that
   middleware's frame resumes; the unwind order is the exact reverse of entry
   order (P4).
2. At unwind time the response is ordinarily already committed. **A response
   attempt after commit is rejected by the existing single-commit guard on
   both commit paths, and the first response survives byte-identically** —
   status and body (P5 and P5b). Middleware introduces no new response writer
   (audit A-7 stays answered).
3. **A second `next()` call by one middleware is a silent no-op and the
   handler runs exactly once.** This is a DESIGN CONSTRAINT, not a free
   property: the WP12 integrator built a counter-example cursor — also
   monotonic, also per-request — that runs the handler **twice** because its
   terminal handler sits outside the index bound. The constraint is therefore
   stated structurally: **the terminal handler is the last step INSIDE the
   cursor's index bound, never a fall-through after it.** The commit guard
   would reject the duplicate response, but a duplicated database write is
   invisible to it — which is why this needs its own test, not the guard.
4. **`next()` from a handler** (the last chain step) finds the chain exhausted
   and is a no-op. WP12 predicted this from the same mechanism but did not
   test it ("could not determine" #6); WP17 must test it rather than inherit
   the prediction.

* Implementation: WP17.
* Proof: WP17 RED tests for each numbered item, including a mutation test that
  moves the terminal handler outside the index bound and must observe the
  handler running twice (the integrator's counter-example made permanent), and
  P5's byte-identity assertion on both commit paths.

(The rejected B3 alternative and its hidden price — descoping WP22's
latency-measuring logger — are recorded in ADR-022.)

---

## 4. Miss-chain behaviour for 404/405 — NORMATIVE (ADR-023 ACCEPTED: middleware observe misses, in `bare()` too)

D-12.4 asks: do app-level middleware observe a request that matches no route
(404) or no method (405)? WP12 P13 prototyped the answer "yes" via a second
flattened chain — the app-level globals terminating in the automatic 404/405
responder — and measured `A>B><B<A` around both the 404 and the 405, with the
standard envelopes byte-identical and the 405 `Allow` header intact.

ADR-023 carries the full cost sheet (P13 measured a real wart: the
terminal-as-Handler design needs an App back-pointer on the Context that
`context.odin` documents as deliberately absent; WP17 may instead special-case
the miss terminal in the dispatcher at the cost of a branch in `next`). The
normative text:

1. App-level middleware run on every miss, in `use` order, with the automatic
   404/405 as the terminal step. Route-level and router-level middleware do
   **not** run on a miss — a miss has no route and no router. (Security note,
   restated from WP12: once audit/rate-limit middleware exist, "misses are
   invisible" is exactly the hole an attacker probes.)
2. **`bare()` runs the same miss chain with a no-op terminal.** P13 measured
   the inconsistency: under `bare()` the prototype's middleware observed
   nothing on a miss. The accepted rule extends ADR-019's own principle —
   "`bare()` means no default policy, not no safety": the *policy* (what a
   miss answers) stays absent; the *mechanism* (middleware observe the
   request) stays on. The driver's existing 500 finalization then applies
   unchanged when nothing responds.
3. The miss chain is built lazily at the first miss. ADR-019 removes most of
   P13's invalidation cost — `use()` after any registration is already a boot
   failure, so the set of globals is fixed before any route exists. One edge
   remains: `use()` after a *dispatch* but before any registration (an app
   that serves a miss in a test, then registers). ADR-023's accepted
   sub-decision closes it: **the fail-closed guard also rejects `use()` after
   the first dispatch**, with the same mechanism and diagnostic family as
   ADR-019. The miss chain is therefore built at most once per App and never
   invalidated — P13's rebuild-on-invalidation pool growth (`[3, 6, 10, 15]`)
   does not ship.

* Implementation: WP17.
* Proof: WP17 RED tests — a global middleware observes a 404 and a 405 with
  the standard envelope and `Allow` intact (P13 made permanent); a `bare()`
  miss enters and unwinds the same middleware while committing nothing (the
  driver 500 asserted); a mutation probe that skips the miss chain must turn
  the 404-observability test red.

---

## 5. Fail-closed registration order — NORMATIVE (settled by ADR-019; diagnostic text below owner-approved 2026-07-19)

ADR-019 and all four sub-decisions are settled and are not reopened: `use()`
after any registered route is a boot failure; the rule applies inside a
`Router`; `mount()` counts as a registration; `bare()` enforces it too. The
mechanism must satisfy the three settled properties:

* **(a)** identical on both transports — it lives on the dispatch path, not
  only in `serve()`; otherwise `test_request` answers 200 where the socket
  answers 500, breaking R-10 parity on exactly the security property the two
  transports exist to keep identical;
* **(b)** observable to a test — a private "poisoned app" predicate rather
  than an abort that kills the test runner (`use()` returns void and cannot
  signal by return);
* **(c)** a diagnostic that names the offending pattern and says what to do.

Poison-the-App versus a cured abort remains a WP17 prototype, per ADR-019.

**Approved diagnostic text.** On the offending `use()` call, through the
existing static-message report path (`context.logger`, no `core:fmt`, no
`core:log` — the WP6 measured rule):

> `druse: web.use was called after a route was already registered; ordered
> middleware cannot protect routes registered before it (ADR-019). Register
> every web.use before the first web.get/post/put/patch/delete/mount. This
> application is rejected fail-closed: every request will answer 500 and
> web.serve will refuse to start.`

Property (c) requires naming the offending pattern. The message above is a
compile-time constant; the pattern is App-owned (cloned at registration), so a
WP17 mechanism that appends it must write through a fixed request-independent
buffer, the WP5-escaper precedent — **not** by importing `core:fmt`. If WP17
cannot name the pattern without formatting machinery, it reports that finding
rather than silently shipping a weaker diagnostic; the fallback wording names
the *count* of already-registered routes, which is an integer with a bounded
manual encoding.

* Implementation: WP17 (guard + mechanism prototype), extended to `Router` and
  `mount` by WP18.
* Proof: WP17 RED tests — the mis-ordered auth program from D-12.5 (measured:
  `/admin/users` answered `200 OK` to an unauthenticated caller) must FAIL to
  serve, on **both** transports, asserted through observable behaviour; a
  correctly-ordered program is unaffected; `bare()` enforces identically. A
  new `Framework_Error` variant (proposed name: `Use_After_Route`) is observed
  through the WP20 observer once both land.

---

## 6. Typed framework-error observer — NORMATIVE (ADR-026 ACCEPTED)

ADR-011 promised a Phase-2 typed observer: one closed event, never `any`, no
change to the handler shape. ADR-026 fixes the field set. The normative text:

### 6.1 Surface (+3: `observe`, `Framework_Event`, `Framework_Error`)

```odin
// ACCEPTED for Phase 2 (ADR-026); frozen only at WP25. Framework_Error is
// today's private closed enum
// (None, Response_Marshal_Failed, Body_Decode_Failed, Body_Consumed_Twice,
// No_Response_Committed, Invalid_Serve_Port, Serve_Listen_Failed), made
// public; it grows only when a work package ratifies a new member.

Framework_Event :: struct {
	kind:         Framework_Error,
	method:       Method,
	route:        string, // the REGISTERED PATTERN, App-owned; "" when no route matched
	status:       Status, // the status the framework committed for this failure
	payload_type: typeid, // as today's private report; never the value
}

observe :: proc(a: ^App, observer: proc(event: Framework_Event))
```

### 6.2 The redaction constraint — HARD

The event carries **low-cardinality route identity — the registered pattern —
and never the raw path**, per the OpenTelemetry HTTP conventions: `http.route`
MUST be low-cardinality, MUST NOT be populated when the framework cannot
supply it, and the URI path cannot substitute for it. Concretely:

* on a miss (404/405) there is no route, so `route` is `""` — populated by
  nothing, never by the path;
* no field carries a message string. Today's report path emits one of six
  compile-time constants precisely so no request byte can reach a log line —
  the property that let the audit refute the log-leakage concern outright is
  not surrendered;
* no header, body, query or token byte is reachable from the event, **by
  type**: the only `string` field is `route`, and its value is either a static
  constant or an App-owned pattern. The event is passed **by value**, so an
  observer that stores it cannot dangle.

### 6.3 Semantics

* One observer per App; a later `observe` replaces the earlier (last wins). A
  list adds an allocation and an ordering question for no evidenced need.
* Every framework-detected failure is observed exactly once, after the report
  and before or at the commit, on both transports identically.
* An observer that attempts to respond cannot produce a second write: the
  single-commit guard applies and the first response stays byte-identical.
* No observer registered → behaviour identical to today. `bare()` installs
  none (it installs nothing).

* Implementation: WP20.
* Proof: WP20 RED tests — every `Framework_Error` variant observed exactly
  once; the responding-observer byte-identity test; the no-observer parity
  test; and a **gate assertion that `Framework_Event`'s field types admit no
  request-derived string** (WP16 owns wiring it into the gate once WP20
  lands). A mutation probe adding a `path: string` field must fail the gate.

---

## 7. Request-ID trust policy — NORMATIVE (ADR-027 ACCEPTED; a security boundary, decided by the owner)

ADR-027 fixes the boundary. The normative text:

1. A client-supplied `X-Request-Id` is **accepted only if** it matches the
   charset `[A-Za-z0-9._-]` and length 1..64. Otherwise a fresh ID is
   generated; the client's value is discarded and **never logged or echoed** —
   it is attacker-controlled bytes. CR/LF header injection is impossible by
   charset, and the test asserts it anyway.
2. Generation is a counter plus process-start entropy, fixed-size, encoded
   allocation-free into request-local storage, and documented as **not
   unguessable** — a request ID is not a secret and must never be treated as
   authentication.
3. The middleware writes the effective ID into a private request-header
   **overlay** that `web.header` consults, and sets the response header
   (accepted shape; +1 symbol: `request_id`). The acceptance obliges WP19 to
   document `web.header` as "the effective request header", so the coupling is
   declared rather than discovered. The rejected accessor alternative
   (`request_id_value`, +2) returns only if implementation evidence reopens
   ADR-027 with owner approval.
4. The ID appears on the response for every request through the chain,
   including a 404 — deliverable because ADR-023's miss chain is accepted; the
   two decisions were presented and taken together.

* Implementation: WP23 (WP19 for the overlay read path).
* Proof: WP23 RED tests as already enumerated in the plan — absent → generated
  + present on response + readable via `header`; valid → echoed; oversized /
  CR-LF / non-ASCII → replaced; two requests → distinct IDs; `bare()` without
  the middleware sets no header; mutation probes for echo-without-validation
  and allocate-per-request.

Phase-2's own gate wants to assert the response header `X-Request-Id`, and
`Recorded_Response` still exposes only `status` and `body` (D-14.3, reaffirmed
by freeze Amendment 2). The assertion therefore runs as an internal
`package web` test in Phase 2; the user-facing pressure stays recorded as the
open question the plan already carries (risk 5).

---

## 8. Recovery — NORMATIVE (settled by ADR-020; not reopened)

Restated only for completeness of the specification; the phases doc is already
amended and the wording is already accepted:

* Phase 2 ships **no recovery middleware and no public symbol for it**.
* The guarantee is the WP8 driver behaviour: a handler that commits no
  response — including an early-return branch — is finalized to the logged,
  standardized `internal_error` 500, identically under `web.serve` and
  `web.test_request`, in default and `-o:speed` builds, repeatably.
* A handler that faults aborts the process; the documentation says so plainly;
  Druse is expected to run under a supervisor. A "last-gasp responder" is
  Phase 4 vocabulary and is never called recovery.

* Implementation: WP21 (documentation + the two Test Gate items).
* Proof: the phases-doc Test Gate items as amended by ADR-020, already present
  in `knowledge-base/03-development-phases.md` §Phase 2.

---

## 9. The Phase-2 public ledger — APPROVED (owner, 2026-07-19; this is the ledger WP16 encodes)

### 9.1 A correction to the plan's arithmetic, stated before the numbers

`planning/phase-2-plan.md` §3 lists **11** recommended application symbols in
its table, then a conditional `request_id` at +1/+2, but totals the application
ledger at "43–44" — which double-counts nothing and undercounts `request_id`:
32 + 11 + 1 = 44, and 32 + 11 + 2 = 45. Separately, WP14 has since landed with
ADR-021 as amended: growth by **default parameter**, so the test-support ledger
stayed at **2**, not the "+1 (possibly +2)" the plan projected. Both
corrections are applied below; the plan's §3 yields to this section on
approval.

### 9.2 Application ledger

| Symbol | Kind | WP | Decided by |
|---|---|---|---|
| `use` | proc (a group once WP18 adds the `Router` variant — see the guard note below) | 17, 18 | ADR-005/019 (settled) |
| `next` | proc | 17 | ADR-005 (settled) |
| `Router` | type | 18 | ADR-024 (ACCEPTED) |
| `router` | proc | 18 | ADR-024 (ACCEPTED) |
| `mount` | proc | 18 | ADR-024 (ACCEPTED) |
| `header` | proc | 19 | plan WP19 (no new decision) |
| `bearer_token` | proc | 19 | plan WP19 (no new decision; not a spelling variant — it encodes the RFC 6750 parse) |
| `observe` | proc | 20 | ADR-026 (ACCEPTED) |
| `Framework_Event` | type | 20 | ADR-026 (ACCEPTED) |
| `Framework_Error` | enum (existing private, made public) | 20 | ADR-026 (ACCEPTED) |
| `logger` | `Handler` value | 22 | plan WP22 (no new decision) |
| `request_id` | `Handler` value | 23 | ADR-027 (ACCEPTED with the overlay: exactly +1) |

Application ledger: **32 + 12 = 44**. The 45 case exists only if
implementation evidence reopens ADR-027's overlay, which requires owner
approval — it is a reopen path, not an open contingency.

No `Middleware` type (D-12.1: a distinct proc type converts implicitly in both
directions on this toolchain — no call-site cost, no protection either). No
`web.group` (ADR-024). No `recovery` (ADR-020, closed at zero). No per-verb
middleware names. ADR-025 option B adds **zero names** and mutates **zero**
frozen signatures.

**A guard note WP18 must not sleepwalk past.** The plan projects the five
verbs, `use` and `destroy` becoming **procedure groups** so `Router` variants
add zero names. ADR-021 (as amended) measured that `odin doc` renders a group
as member names only, so a group over `@(private)` members is unfreezable —
and `build/check_phase1_freeze.sh` now **rejects that construct outright**.
WP18 therefore cannot use private-member groups as projected; it must either
export the members (ledger growth to be priced then) or find another shape,
decided at the WP18 boundary with a compile probe first. Recorded here so the
collision is met on purpose, not discovered by a red gate.

### 9.3 Test-support ledger

**2, unchanged** — the WP14 outcome, already frozen by Amendments 1–2. WP19's
request-header injection into `test_request` follows the same accepted
mechanism (a fully visible default parameter; `Header_Pair` stays private, no
test-only header type). Contingency, stated because G-08 demands it: if the
pinned toolchain cannot express header injection as a default parameter
without a new public type, the number is reported to the owner **before** it
is adopted, exactly as ADR-021 required of WP14.

### 9.4 Union and the gate policy

| Ledger | Phase 1 | Phase 2 | Total |
|---|---|---|---|
| Application | 32 | +12 | **44** |
| Test-support | 2 | +0 (contingency stated above) | **2** |
| **Union** | **34** | **+12** | **46** |

The approved end-state target is **46**. The outer bound **47** exists only
through the two named reopen paths (the ADR-027 overlay, the §9.3
test-support default-parameter contingency), each of which requires owner
approval before the number moves — so WP16's assertions treat 46 as the
target and 46–47 as the never-exceed envelope, exactly as the owner's review
directed ("46–47, not 46–48").

**The gate never asserts a number this document has not yet earned.**
Operationally:

* each work package that grows a ledger updates the gate's expected inventory
  **in the same change**, with G-09 evidence, exactly as WP14 did;
* WP16 restructures the gate so a ledger increment is a one-table change, and
  its own mutation controls (extra export MUST FAIL, deleted entry MUST FAIL)
  keep holding at every intermediate count;
* the final Phase-2 number is frozen by WP25, not before.

### 9.5 Scale, restated honestly

+12 on 32 is ~38% growth of the application surface, buying middleware, route
organisation, request headers and the typed observer — four of the six things
the audit's usage laboratory found impossible in Phase 1. Response headers and
shutdown stay unbought, by design. WP25 re-runs the usage laboratory; if a
five-route CRUD service then needs 25 concepts instead of 14, that is a
finding, not a footnote.

---

## 10. Amendments to `knowledge-base/03-development-phases.md` §Phase 2 — APPLIED (owner approval 2026-07-19)

The ADR-020 amendments were already in the file and are not repeated here.
Applied with the approval:

### 10.1 ADR-024 (Router + mount, no `web.group`) — applied

In **§Scope (required)**, replaced
`- route groups: web.router, web.group, web.mount` with:

```
- route organisation: `web.Router`, `web.router`, `web.mount` — and NO
  `web.group`: once a detached Router can be mounted at a prefix,
  `group(&app, "/admin")` is a second canonical way to perform one operation,
  which G-01 rejects (ADR-024)
```

### 10.2 ADR-025 decided as option B — applied in its option-B form

The originally drafted amendment assumed option A (the variadic) and was
**not** applied. In **§Scope (required)**, replaced
`- web.use at app, group, and route level` with:

```
- `web.use` at app and router level; route-level middleware is expressed as a
  one-route `Router` mounted at the path (ADR-025, option B — the five Phase-1
  registration signatures stay frozen; a variadic tail remains available later
  by freeze amendment if real usage proves the need)
```

### 10.3 ADR-023 (miss chain) — applied

Added to **§Test Gate checklist**:

```
- [ ] app-level middleware observe a 404 and a 405, in `bare()` too, with the
      standard envelopes and the 405 `Allow` header unchanged (ADR-023)
```

### 10.4 Spec Gate checklist — ticked

Every §Phase 2 Spec Gate checkbox is ticked in the phases doc with a pointer
into this document, per the WP15 completion criterion in
`planning/phase-2-plan.md`.

---

## 11. Spec Gate checklist mapping

The phases-doc §Phase 2 Spec Gate items, each pointed at the clause that ticks
it. All boxes are now ticked in the phases doc itself (§10.4).

| Phases-doc Spec Gate item | Clause here | Status |
|---|---|---|
| exact ordering rules (global → outer routers → inner → handler) | §2.1 | settled; nesting order via ADR-024 (ACCEPTED), one rule under ADR-025 option B |
| onion decision (post-`next` semantics, prototyped on the bootstrap transport) | §3 | ADR-022 ACCEPTED — B1 (ADR-005's option-C condition was met by WP12 P4/P5) |
| chain flattening at registration time specified | §2.2 | settled by ADR-005 evidence; invariant stated |
| fault-behaviour documentation (ADR-020) | §8 | settled; not reopened |
| request ID source/generation | §7 | ADR-027 ACCEPTED |
| `use()`-before-routes enforcement: mechanism, message, `Router`/`mount`/`bare()` scope | §5 | scope settled by ADR-019; diagnostic text approved; mechanism is a WP17 prototype per ADR-019 |
| error-event fields, redaction policy, observer isolation, behaviour after commit | §6 | ADR-026 ACCEPTED |

Two items this specification added beyond the printed checklist, for the same
gate: the miss-chain decision (§4, ADR-023 ACCEPTED) and the ledger (§9,
approved).

---

## 12. The decisions, as taken (owner, 2026-07-19)

Six decisions were presented, each carried by an ADR in `planning/adrs.md`
with question, options, recommendation, strongest argument against, public
impact and reversibility. The outcomes:

| ADR | Decision | Outcome |
|---|---|---|
| ADR-022 | post-`next` promise: B1 or B3 | **ACCEPTED — B1**, as recommended |
| ADR-023 | do app-level middleware observe 404/405, and does `bare()` join | **ACCEPTED — yes, both**, miss chain per P13, `use()`-after-first-dispatch closed fail-closed |
| ADR-024 | `Router`+`router`+`mount`, rejecting `web.group` | **ACCEPTED** — Router/mount adopted, `group` rejected (G-01) |
| ADR-025 | route-level middleware: variadic on the five verbs, or a one-route Router | **ACCEPTED — option B (one-route Router)**, against the WP15 recommendation: the only LOW-reversibility item, five frozen signatures preserved; B → A later stays HIGH |
| ADR-026 | `Framework_Event` field set and redaction | **ACCEPTED** — the §6.1 shape: pattern-only route identity, no message string |
| ADR-027 | request-ID trust policy and the header overlay | **ACCEPTED** — strict charset/length, never echo invalid, overlay (+1) |

The §9 ledger is approved — application 44, test-support 2, union **46**
(47 only via a named, owner-approved reopen) — and supersedes plan §3. The §5
fail-closed diagnostic text is approved as written.

The owner's review also independently confirmed the §9.1 arithmetic
correction against the actual tables, and ran the full gate on
main + the WP15 commit: `GATE_EXIT=0`, `PASS=10 FAIL=0 SKIP=0`, 126s,
freeze ledgers 32 + 2 = 34 byte-identical.
