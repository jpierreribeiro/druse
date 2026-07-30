# Phase 3 — Freeze

**Date:** 2026-07-20. **Toolchain:** the pinned commit in `odin-version.txt`
(`819fdc7`); the gate refuses any other. **Gate:** `build/check.sh` exits 0.
**Authority:** the **ADR-029 delegation**, which resolved WP38 as *"approval
delegated to the gate: the freeze proceeds if and only if every gate is green,
every ledger amended, and the guarded lab program holds at ≤ 25 concepts. Any
breach stops the freeze and goes to the owner."* Every condition is recorded
below with its measurement. **No breach.**

This document is to Phase 3 what `planning/phase-2-freeze.md` is to Phase 2. It
does not repeat that document's ledgers; it **amends** them, which is the
difference the plan insisted on: a freeze that appends leaves two answers to one
question standing.

Everything below is measured on the pinned toolchain, in this repository, at the
commit that carries this file. Where a number could not be measured honestly, it
says so instead of rounding.

---

## 1. The ledger diff

| | Phase 2 froze | Phase 3 adds | Total |
|---|---|---|---|
| application | 44 | +6 | **50** |
| test-support | 2 | 0 | **2** |
| union | 46 | +6 | **52** |

The six, each with the work package that ratified it and the amendment that
recorded it:

| Symbol | Kind | WP | Freeze amendment |
|---|---|---|---|
| `route` | proc | 34 | 10 |
| `app_with_state` | proc | 37 | 11 |
| `state` | proc | 37 | 11 |
| `Limits` | type | 36 | 12 |
| `DEFAULT_LIMITS` | const | 36 | 12 |
| `limits` | proc | 36 | 12 |

**+6 for a phase that replaced the router wholesale.** WP26–WP33 and WP35 —
the benchmark harness, the allocation audit, the representation shootout, the
radix index, the conflict diagnostics, the path policy, automatic HEAD and
OPTIONS, multi-parameter routes and the arena decision — shipped **zero public
symbols between them**. Nine work packages, no surface. That is the number this
phase is actually about.

**Rejected and staying rejected:** request-scoped typed state (ADR-028, option 1
ACCEPTED — a mechanism is added only against a real program that cannot be
written cleanly in this tree), read and write timeouts as `Limits` fields (§5 —
the backend has no deadline to configure, and a field that does nothing is a lie
with a version number on it), `web.group` (ADR-024, refused in every phase),
`web.recovery` (ADR-020, impossible).

Every signature is pinned byte-for-byte in `build/phase1-public-signatures.txt`.
Every symbol carries a G-09 evidence row in `planning/phase-1-freeze.md`
amendments 10–12; 159 citations resolve.

**`Framework_Error` did not grow.** Phase 3 added three fail-closed refusals —
a registration conflict (WP30), a nil state (WP37), a late or invalid `Limits`
(WP36) — and none of them is an enum member, because the enum names failures
that reach an OBSERVER and an observer cannot be alive to see a boot-time
rejection. The byte-pinned public enum is unchanged.

---

## 2. The three ledgers, amended

### Claim ledger

`planning/phase-2-freeze.md` §2 gains **C-10 — "limits are configurable, and
both transports enforce the same ones"**, with its positive test, its negative
control (`check_wp36_controls.sh`) and its stated non-guarantee. A claim with no
negative control does not freeze, and this one has one that matters: deleting
the single driver line that carries the budget onto the request turns the
configurable-cap tests red, which is what makes the R-10 half of the claim
tested rather than asserted.

**No other claim was added, and that is deliberate.** WP34's `route` and WP37's
`state` make no promise beyond their signatures. In particular **no "costs
nothing when unused" claim was made for any Phase-3 symbol** — see §4, where the
attempt to measure one failed honestly.

### Lifetime ledger

`planning/phase-2-freeze.md` §3 gains the two borrowed values Phase 3
introduced. Both are already stated in `docs/canonical-patterns.md`'s ownership
table, which the docs gate requires:

* **the route pattern via `web.route(ctx)`** — App-owned, valid until
  `destroy`. It is the *same string* `Framework_Event.route` already carried, so
  the ledger's existing exception is now reachable by a second route rather than
  being a second exception.
* **application state via `web.state(ctx, T)`** — owned by **the caller**, not
  the framework. The App borrows a pointer and frees nothing; the value must
  outlive the App, and no assert can enforce that, so the rule is taught as
  layout in `examples/07-app-state`: the state and the App are both locals of
  `main`.

WP33's multi-parameter captures added **no** new lifetime: they are the same
request-scoped views `web.path` always returned, at a higher count.

### Capacity ledger

`planning/phase-2-freeze.md` §4's row *"request body — 4 MiB, fixed, not
configurable until Phase 3"* is **amended, not appended to**, and two rows are
added for the budgets WP36 exposed. FINDING-C is discharged. The "what it does
when full" sentence gained the two new answers: the body limit answers 413 *at
whatever number the application configured*, and the text budgets are refused by
the backend before the core sees the request.

`ROUTE_PARAM_MAX` (8) was added by WP33 with its own full-behaviour statement:
a pattern declaring more is invalid at registration, never matches, and never
contributes to an `Allow` value.

**The word "bounded" is still gated.** Configurable limits bound Druse's own
per-request working memory. They do not bound connections, accept backlog,
inbound header count or process memory, and `check_phase2_freeze.sh` still fails
any document that says the framework as a whole is bounded.

---

## 3. Mutation suites, all re-run

Thirteen suites, every one green at this commit. Phase 2 ended with ten; Phase 3
added three (WP30, WP36, WP37).

| Suite | Controls | Result |
|---|---|---|
| WP16 | 6 | PASS |
| WP17 | 7 | PASS |
| WP18 | 6 | PASS — **control 6 re-aimed, see below** |
| WP19 | 6 | PASS |
| WP20 | 6 | PASS |
| WP21 | 7 | PASS |
| WP22 | 7 | PASS |
| WP23 | 7 | PASS |
| WP24 | 6 | PASS |
| WP25 | 7 | PASS — **control 6 re-aimed, plus a new 6b** |
| WP30 | 3 | PASS |
| WP36 | 5 | PASS — includes a positive control |
| WP37 | 3 | PASS — two of them run subprocesses |

**RE-RUNNING THEM WAS NOT CEREMONY. It found a control that had silently stopped
working**, which is the entire argument for the step.

`check_wp18_controls.sh` control 6 removed the `append`-result guard in `mount`
and required the fail-closed mount tests to go red. At this commit it stayed
**green**. The cause is WP30: with the append guard gone, `index_insert` was
handed a stale index, found the slot occupied and raised a *conflict* — so the
application was still rejected and the test still passed, for a reason it was
never written about.

Two things were done, and the order matters. First the TEST was strengthened to
assert the diagnosis rather than merely the refusal — a fail-closed test that
does not check which failure it caught can pass for any of them. That was worth
keeping but did **not** fix the control: `mount` has four allocation guards on
one path (pattern clone, chain flatten, append, index insert) and under a
starved arena the siblings emit the *same* diagnostic. So the append guard is
**not independently observable through any public behaviour** — it is defence in
depth, not a separate guarantee, and saying so is more useful than a control
that pretends otherwise. Control 6 now removes the whole family and pins what
Amendment 1 actually promised: a partial mount must never leave a
healthy-looking application.

`check_wp25_controls.sh` control 6 was re-aimed for a different reason, recorded
in Amendment 10's neighbourhood: the Phase-2 freeze gate compared that
document's ledger diff against the **live** count, which was indistinguishable
from correct for as long as no phase grew the ledger after Phase 2 — and went
red the moment one did. 44 is what Phase 2 froze: history, not a measurement. A
**6b** was added for the half a restated-total check misses, a delta edited so
the table no longer adds up.

---

## 4. Cost measurements, including the one that failed

### The `nm` measurement the plan asked for could not be made, and the positive control is how that is known

The plan required *"`nm` measurements with positive controls for every new
'costs nothing when unused' claim."* **Phase 3 makes no such claim** — which is
the first honest answer. The measurement was attempted anyway, and it failed in
a way worth recording:

| Symbol | linked in a program that never calls it | linked in one that DOES |
|---|---|---|
| `web.route` | 0 | **0** |
| `web.state` | 0 | **0** |
| `web.app_with_state` | 0 | **0** |
| `web.limits` | 0 | **0** |

**The positive control is zero.** All four are small enough to be inlined, so
they emit no symbol *even when used*, and `nm` cannot see them either way. The
negative column is therefore worthless — it would read zero against any binary,
including one that used them on every request. This is exactly the failure mode
`check_g11_teardown.sh` documents: *"without the positive control, a typo in the
symbol pattern would make the negative assertion pass against every possible
binary, and the gate would certify a property it never actually measured."*

### Binary size cannot resolve it either

A consumer that uses **none** of the Phase-3 symbols, built at each phase point:

| Commit | Work package | Bytes |
|---|---|---|
| `b43057f` | WP30 (ledger 44) | 938,072 … 942,152 |
| `60ef9ef` | WP34 (45) | 938,048 |
| `7ceae70` | WP37 (47) | 942,352 |
| `31af384` | WP36 (50) | 942,832 … 942,880 |

**The same commit measured twice differs by 4,080 bytes** — `b43057f` gave
938,072 on one extraction and 942,152 on another, with identical inputs. Within
one extracted tree five consecutive builds spread only **8 bytes**
(942,880 ×3, 942,872 ×2), so the variance is not thermal: the output size
**quantises at roughly a 4 KiB page**, and a small change that crosses a
boundary moves the file by a whole one.

**So no per-work-package attribution is possible at this magnitude, and none is
made.** An earlier draft of this section reported "+4,768 bytes for an
application that uses no Phase-3 symbol" before the noise was quantified; that
number was measurement, not cost, and it is recorded here as an error caught
rather than deleted. This is the same conclusion the project already reached
about byte-identical builds, arriving from a different direction.

### Dispatch performance: no regression, and an instrument that cannot prove much

Re-run with the WP26 harness at this commit, against the post-WP29 baseline in
`planning/router-implementation.md` §2. Median p50 nanoseconds:

| Routes | Shape | post-WP29 | Phase-3 final | Δ |
|---:|---|---:|---:|---:|
| 5 | Mixed | 1,341 | 1,755 | +31% |
| 5,000 | Mixed | 1,486 | 1,727 | +16% |
| 5,000 | All_Static | 1,280 | 1,777 | +39% |
| 5,000 | All_Param | 1,555 | 2,332 | +50% |

**The tolerance derived on this machine in this run is 13,821 basis points —
138%.** Every delta is far inside it, so by the stated procedure there is no
regression. **That is a weak statement and this document will not dress it up:**
an instrument whose noise floor is 138% cannot distinguish "unchanged" from "50%
slower". What it *can* still show is the structural property, and that property
holds — **dispatch is flat**: 1,755 ns at 5 routes against 1,727 ns at 5,000.
The framework still does not care how many routes an application registers.

The deltas are also **consistently positive**, which a wide tolerance makes easy
to wave away and this document will not. They are recorded as a question for
Phase 4 rather than an answer here: the honest next step is a quieter machine or
a paired-run design, not a tighter number on this one (FINDING-A/E).

---

## 5. What Phase 3 deliberately did NOT do

Recorded so a later reader does not mistake absence for oversight:

* **No read or write timeouts,** and no `Limits` field reserved for them. The
  vendored server has no deadline to configure — its options carry the two text
  limits and nothing temporal, and its request read still carries an
  unfinished-work comment asking for one. Real deadlines are surgery inside the
  event loop. Adding a field later is an amendment; shipping one that silently
  does nothing would be worse than not shipping it. **No document claims
  Druse has configurable timeouts.**
* **No request-scoped typed state.** ADR-028 option 1, accepted. The canonical
  auth pattern's revalidation cost is permanent until an ADR decides otherwise,
  and `check_examples.sh` rejects a comment that schedules its removal.
* **No path normalisation.** WP31 decided to REJECT rather than transform: a dot
  segment, an interior empty segment, a percent-encoded slash or NUL is answered
  400 before matching, and everything else passes through byte-exact. `/users`
  and `/users/` remain two paths.
* **No 501.** An unknown method stays on the 404/405 path (WP32, WP9 D7).
* **No new `Framework_Error` member,** despite three new refusals.
* **No graceful shutdown, no stop procedure, no trusted proxies, no TLS.**
  Phase 4 owns all of it.

---

## 6. Usage laboratory, re-run

**The instrument that produced Phase 2's "23" was not preserved** — only the
number was — so this re-run had to RECONSTRUCT the programs from the documented
concept list. That is a finding about the previous freeze, and it is fixed here
rather than repeated: both programs and the counting rule now live in
`experiments/11-usage-lab/`, so the next freeze re-runs instead of reconstructing.

The rule, now written down: **a concept is a distinct `web.` identifier the
program names, with comments stripped first.** Comments are stripped because the
first run of this re-measurement over-counted by two — a program that says "this
deliberately does not use `web.route`" was being charged for the sentence.

| Program | Concepts | Compiles |
|---|---|---|
| A — five-route CRUD, unguarded (the Phase-1 shape) | **14** | yes |
| B — the same, guarded: middleware, router, auth, logging, request IDs | **22** | yes |
| C — B as Phase 3 would realistically write it, with application state | **23** | yes |

**Program A reproduces Phase 1's recorded 14 exactly**, which is what makes the
reconstructed instrument trustworthy for the others.

**Program B measures 22, where Phase 2 recorded 23.** The difference is the
`Router` TYPE: Phase 2 counted it as a concept a reader must hold, and the
program need never spell it (`items := web.router()` infers it). Both readings
are defensible; the discrepancy is recorded rather than reconciled by picking
the flattering one.

**The budget applies to the guarded program, and it is program C: 23 concepts
against a ceiling of 25. NO BREACH.** The plan predicted +2 if the lab gained
state and asked for it to be measured rather than assumed — measured: `+2` for
`app_with_state` and `state`, `−1` because `app_with_state` replaces `app`, for
a net **+1** over B.

**`web.route` and `web.limits` cost the lab nothing, as predicted**, and program
C deliberately does not reach for them: a CRUD service has no reason to label
telemetry by route or to change its byte budget, and adding them to the program
would have measured the phase's surface rather than a program's cost.

---

## 7. Freeze conditions

The ADR-029 delegation made this list the approval. Each is met:

* [x] `build/check.sh` exits 0 on the pinned toolchain.
* [x] 50 application + 2 test-support = 52, byte-identical to
      `build/phase1-public-signatures.txt`.
* [x] Every new symbol carries a G-09 evidence row (amendments 10–12) and every
      citation resolves.
* [x] The three ledgers **amended**: claim (+C-10, with a negative control),
      lifetime (two borrowed values), capacity (FINDING-C discharged).
* [x] All thirteen mutation suites re-run and green — including one control
      re-aimed after this step found it had stopped isolating its defect.
* [x] The regression benchmark re-run, its tolerance derived on this machine and
      stated with its limits rather than as a pass mark.
* [x] The usage laboratory re-run, its instrument preserved, and the guarded
      program at **23 ≤ 25**.
* [x] Cost claims: **none made**, and the failed measurement recorded with the
      positive control that proves it failed.

**Nothing here is reserved matter, so nothing stops for the owner.** A release
or a tag remains one, and is not part of this freeze.
