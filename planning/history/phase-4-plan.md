# Phase 4 — Production: work package plan

**Status: DRAFT, written 2026-07-20 — before Phase 3 has run, and on purpose.**
The shape of Phase 4 is already fixed by research that Phase 3 cannot change
(C-1…C-8 and the RG-P4 gates in `later-phases-plan.md`), so writing the shape
now costs nothing and lets the Phase-3 agent see where its outputs land. The
details Phase 3 **will** change are collected in §0 as a mandatory refresh, and
E-4 makes that refresh an entry condition. **Nothing here freezes a signature**
— precision about unstarted work would be false precision, and this plan does
not pretend to it.

Work packages continue the numbering: **WP39 – WP56**, mapping the
`P4-1 … P4-20` slots (with the consolidations §4 records).
`later-phases-plan.md` stays authoritative for the research findings; this
plan supersedes its Phase-4 table for sequencing and scope.

The theme in one line: **make deployment defensible — this is the phase where
mistakes stop being inconvenient and become remotely exploitable, so
fail-closed stops being a preference and becomes the whole method.**

---

## 0. The hand-over: what WP38 must deliver into this plan

Mandatory refresh, applied and recorded before any Phase-4 package starts
(that is E-4). Each row names what can invalidate what.

| Phase-3 output | What in this plan it feeds or can change |
|---|---|
| WP36's options struct and derived `Server_Runtime` | WP46 builds **on** it — connection, queue and ingress limits become new rows in the same boot-derivation, never a second mechanism. If the shape shipped differently, WP46 is amended first. |
| WP35's arena policy and the R-16 outcome | WP54's audit baseline — and whether **slot reuse exists at all**, which decides if generational tokens are in scope (P-T7's rule: no reuse, no abstraction). |
| WP29's router representation | Feeds WP41's fault menu (what conflict diagnostics exist to trip) — by design it changes nothing else here, because it was internal-only. |
| WP34's route identity accessor | WP50 depends on it existing; observability keys on the pattern, never the path. |
| FINDING-A's status on the then-pinned toolchain | Every measurement methodology in WP53; if the toolchain was re-pinned, the nondeterminism finding is re-verified, not inherited. |
| The concept-budget headroom after WP38's lab re-run | The budget WP44's public stop/shutdown surface spends from. |
| Any ADR accepted or amended during Phase 3 | The §2b table below is re-checked row by row. |

---

## 0b. The hand-over, APPLIED — E-4 discharged 2026-07-20

Phase 3 is frozen (`planning/phase-3-freeze.md`, ledger 50 + 2 = 52). Every row
of §0 is re-checked below against what actually shipped, which is what E-4 asked
for. **A plan that skips its refresh is folklore with a section number.**

| §0 row | What Phase 3 actually delivered | Effect on this plan |
|---|---|---|
| WP36's options struct and derived runtime | Shipped as designed: `Limits` + `DEFAULT_LIMITS` constant + boot-derived, validated once, copied onto each request. **But with three BYTE budgets and no time budget.** | **WP46 is amended** (§3): it inherits the mechanism unchanged AND gains read/write deadlines as new rows in it (ADR-031). No second mechanism. |
| WP35's arena policy and R-16 | The decision was to change nothing; **no slot reuse exists.** | **WP54 loses its generational-token contingency.** P-T7's rule applies literally: no reuse, no abstraction. It returns only if Phase 4 introduces reuse. |
| WP29's router representation | Internal-only, as predicted — and WP30 added registration-conflict poisoning on top of it. | **WP41's fault menu gains a row**: a conflict diagnostic is now a trippable boot failure, not only a dispatch outcome. |
| WP34's route identity accessor | Shipped as `web.route(ctx)`, with the pattern-never-path rule enforced at every write to the slot. | **WP50 may depend on it**, and inherits the gate assertion rather than restating the rule. |
| FINDING-A on the pinned toolchain | Re-verified and **worse than recorded**: the WP26 harness derived a tolerance floor of **13,821 bp (138%)** on this machine, and binary size quantises at roughly a 4 KiB page. | **WP53 inherits a hard constraint:** any Phase-4 performance claim needs a paired-run design or a quieter machine. A single-figure comparison is not evidence here, and WP47's "rejection is cheaper than admitted work" claim is the first one this bites. |
| Concept-budget headroom after WP38 | Guarded lab program at **23 of 25**. | **WP44 has two concepts of headroom for the entire stop/shutdown surface.** That is the budget, and it is tight on purpose — see §2b. |
| Any ADR accepted or amended in Phase 3 | ADR-028 ACCEPTED (option 1, no request-scoped state); ADR-029 delegation in force; **ADR-031 accepted here.** | §2b re-checked row by row below; two rows amended, one added. |

**One row of §0 turned out to be missing, and it is recorded rather than
quietly added:** nothing in §0 anticipated that Phase 3 would ship a *hole*
(timeouts) rather than a shape. The hand-over table assumed Phase 3's outputs
would feed Phase 4; it had no row for a Phase-3 output that Phase 4 must
**repair**. ADR-031 is that repair, and future phase plans should carry a
"what did the previous phase leave undone" row explicitly.

---

## 1. Entry conditions (not work packages)

| ID | Item | Status, 2026-07-20 |
|---|---|---|
| E-1 | Phase 3 frozen — WP38 merged, full gate green on `main` | ✅ **met** — `planning/phase-3-freeze.md`, ledger 50 + 2 = 52 |
| E-2 | Configurable limits and timeouts exist (WP36 shipped) — the roadmap's hard dependency: shutdown with a deadline is meaningless without timeouts | ⚠️ **HALF MET, and this is the one that had to be decided.** Limits shipped; **timeouts did not.** See the resolution immediately below. |
| E-3 | The full gate exits 0 on `main` at the moment Phase 4 starts | ✅ **met** |
| E-4 | **This plan re-reviewed against §0**, amendments applied and recorded | ✅ **met** — §0b above |

**E-2, resolved 2026-07-20 under the ADR-029 delegation.** The condition was
written expecting WP36 to ship both halves. It shipped one, for a measured
reason. There were two ways to satisfy the condition and only one of them is
honest:

* **Amend E-2 away** — accept that shutdown deadlines come from the reverse
  proxy, and let the entry condition read as met. This was the arm previously
  recommended, on the grounds that it is reversible and ships nothing.
* **Satisfy E-2 by building the missing half.** ← **chosen (ADR-031).**

The deciding argument is not preference, it is what the condition was *for*.
E-2 exists because *"shutdown with a deadline is meaningless without
timeouts"* — and that reasoning does not care where the timeout comes from
until you notice that **a proxy's read timeout cannot drain the framework's own
in-flight work.** The proxy can stop feeding the process; it cannot tell WP44's
shutdown that a handler has been running for four minutes. Delegating the
deadline delegates the *defence* while leaving the *lifecycle* without the
clock it was specified against.

So E-2 is met **by construction rather than by exception**: WP46 grows the
deadline rows, WP44 gets a real clock to bound its drain with, and the entry
condition is discharged the way it was written. `E-2 → WP51 → WP46 → WP44` is
the new critical path; see the sequencing amendment in §2c.

**And the foundation itself became the question (ADR-033).** Checking the
upstream to see whether a timeout could be contributed there turned up the
larger fact: `laytan/odin-http` describes itself as *beta software* whose author
*"does not hesitate to push API changes"*. Combined with the observation that
**WP44–WP47 and WP52 are all server work rather than framework work**, that
makes "keep, patch, or own the transport" the real Phase-4 decision, and WP41 —
already first in the sequence — is where the evidence for it arrives. Recorded
as ADR-033, OPEN with its criteria fixed in advance.

**Amended the same day (ADR-031 Amendment 1).** The first version of this
resolution also fixed the MECHANISM — patch the vendored connection read. That
was decided before WP41 exists to say how that server behaves, and it was
reached partly from an inferred design constraint rather than from evidence.
**The requirement stands and the mechanism returns to WP46**, where upstreaming
is attempted first and a carried patch is the fallback. The comparison that
settles the framing: **Gin does not implement timeouts either** — they come from
`net/http`'s server. The gap here is a foundation gap, not a framework-design
gap, and the fix belongs at the foundation.



---

## 2. Work package sequence

| WP | P4 | Name | Type | Approval |
|---|---|---|---|---|
| 39 | RG-P4-A | Lifecycle state machine | SPEC | resolved (§2b) |
| 40 | RG-P4-B | Capacity and overload ledger | SPEC | resolved (§2b) |
| 41 | RG-P4-C | Deterministic transport fault laboratory | TESTS | resolved (§2b) |
| 42 | P4-1 | Concurrency model | PROTOTYPE + ADR-030 | **deliberately open — see §2b** |
| 43 | P4-3 | Per-server state replaces the transport globals | IMPLEMENTATION | internal only |
| 44 | P4-2 | Lifecycle: stop, shutdown, deadline, cleanup | SPEC + IMPLEMENTATION | resolved in principle (§2b); surface sized at spec time |
| 45 | P4-4 | Connection lifetime: keep-alive, drain-or-close, staged close | IMPLEMENTATION | behaviour per RFC (C-3) |
| 46 | P4-5 | Limits: connections, queue, headers, ingress rate | SPEC + IMPLEMENTATION | builds on WP36; ledger amendment |
| 47 | P4-6 | Deterministic load shedding | IMPLEMENTATION | resolved (§2b) |
| 48 | P4-7 | Trusted proxies | SPEC + IMPLEMENTATION | ADR-013, already accepted in direction |
| 49 | P4-9 | Secure headers and cookies | SPEC + IMPLEMENTATION | forces the D-14.3 header decision |
| 50 | P4-12+13 | Observability with the redaction policy as its spec half | SPEC + IMPLEMENTATION | resolved (§2b) |
| 51 | P4-15 | Vendor maintenance policy | SPEC | resolved (§2b) |
| 52 | P4-16 | Fuzzing and the extended framing corpus | TESTS | resolved (§2b) |
| 53 | P4-17 | Load, soak and fault-injection tests | TESTS | methodology inherits WP26 |
| 54 | P4-18 | Allocator and lifetime audit, whole-system | TESTS | resolved (§2b) |
| 55 | P4-19 | Operations documentation | DOCS | resolved (§2b) |
| 56 | P4-20 | Phase-4 freeze | FREEZE | delegated to the gate, WP38-style |

**Dependencies:** {39, 40, 41} first — the same structural decision as Phase 3,
for the same reason: a production phase that starts by implementing has chosen
its failure modes by taste. Then 42 → {44, 45, 46, 47} (the concurrency
decision shapes all four); 43 → 44 (there is nothing to stop until state is
per-server); 44 → 45; {36 (Phase 3), 40} → 46 → 47; 48, 49, 50 and 51 are
independent of each other once 42 lands; 52 and 53 run against whatever
exists and grow with it; all → 54 → 55 → 56.

---

## 2b. Approvals resolved in advance (ADR-029), and the one that is not

Same regime as the Phase-3 plan's §2b, same condition on every row: **if the
work package's own spec or prototype work contradicts the decided arm, the
agent stops and records the finding instead of proceeding.**

| Matter | Decided arm | Grounds |
|---|---|---|
| **CORS (P4-8), uploads (P4-10), static files (P4-11)** | **Out of core, ratified.** Each becomes an optional package, spec-gated Phase-5 style, and the core never grows them. | Each is a security surface of its own; the recorded constraints (Fetch spec for CORS, OWASP for uploads, traversal/symlinks/ranges for static files) travel with the packages, in `later-phases-plan.md`. The mission keeps the core small; G-04 already said optional means optional. |
| **TLS (P4-14)** | **Reverse-proxy termination is the supported deployment**, documented as such in WP55. In-process TLS is at most a future optional package, unscheduled. | The common deployment is free and removes an enormous attack surface from the core. Terminating TLS in-process would import exactly the class of risk this phase exists to reduce. |
| **Trusted proxies (WP48)** | ADR-013's accepted direction: peer address by default, explicit trust configuration, `Forwarded` never echoed. | Decided 2026-07-20; the fail-closed arm. WP48 owns signatures and the CIDR corpus, not the direction. |
| **The three gates (WP39–41)** | Approved as specs and tests — they add no public surface and no capability. | They are the phase's instruments; refusing them is refusing to look. |
| **WP44 stop/shutdown surface** | Approved **in principle**: real demand exists (there is no way to stop a server today). The exact symbols are sized at spec time under G-09 evidence, smallest surface that gives admission stop, an absolute deadline and exactly-once cleanup. | A promise made now about symbol names would be the false precision this plan refuses. |
| **WP47 shedding** | Deterministic, bounded admission **before** any adaptive controller; rejection measured cheaper than admitted work. | Research item 10 before 11; an adaptive controller on top of unmeasured shedding is two unknowns multiplied. |
| **WP50** | Redaction policy is the spec half and lands **first**; observability keys on the route pattern, never the raw path; drop policy observable. | Separating redaction from observability invites shipping them in the wrong order. Phase 1's "nothing reaches a log line" property is preserved deliberately, not by accident. |
| **WP56 freeze** | Delegated to the gate, WP38-style: freeze if and only if every gate is green, every ledger amended, seeds and soak results recorded. Any breach stops and goes to the owner. | Same reasoning as WP38: criteria met and refused is ceremony; criteria breached and passed is a lie. |
| **Read and write deadlines (ADR-031, as amended)** | **The REQUIREMENT is fixed; the MECHANISM is WP46's to choose, after WP41.** Deadlines are the framework's problem and not the proxy's — but which mechanism (upstream to `odin-http`, a carried vendored patch, or the transport WP42/WP43 leaves behind) is decided with the fault lab's evidence in hand. **Upstream is attempted first; a carried patch is the fallback.** Until it ships, direct exposure without a proxy is not a supported deployment, and WP55 says so. | Byte budgets cannot reach slowloris — the request never gets large, only slow — and a proxy's timeout cannot bound the framework's own in-flight work, which is what WP44 needs a clock for. But the first draft of this row fixed the mechanism *before* the lab existed to say how the server behaves under a slow client, which inverts this project's method. Code we do not own is code we do not maintain; and per-connection timers have cancellation semantics the concurrency decision changes, so building them first means building them twice. |
| **WP42 concurrency — THE OPEN ONE** | **Not pre-resolved, deliberately.** Whether `serve` stays single-threaded by construction is the phase's architectural decision (audit A-4, A-14), and deciding it today, without prototypes, would be taste wearing a delegation. What is written instead is the **procedure**: prototype both arms — the current single-threaded event loop, and a threaded model — measure both under WP53's workloads (including slow-client and slow-writer), and decide by **ADR-030** with the losing arm's numbers recorded. Two constraints bind whichever wins: fail-closed (no shared-mutable `App` state without a guard equivalent to the existing poison mechanism), and the Phase-3 decision that registration after `serve` begins is rejected — WP42 inherits that, it does not reopen it. | C-5's lesson generalises: "real systems use threads" is not evidence about Druse's workloads. The mission's tie-breaker applies only after the measurements. |

**WP42 stays open, and the delegation does not change that.** ADR-029 hands over
*approvals*; it does not manufacture *evidence*. Deciding the concurrency model
today would be exactly the "taste wearing a delegation" this row already
refuses, and it would be the one decision in the phase that cannot be walked
back cheaply.

**What IS decided now, because it is decidable without a prototype, is the
default and the stopping rule:**

1. **The default arm is single-threaded** — the status quo, `thread_count = 1`.
   It is what ships today, it is what every existing test and every measured
   number describes, and it is the only arm that is free to abandon.
2. **The burden of proof is on threading.** A threaded model is adopted only if
   WP53's workloads show a material improvement *and* WP41's fault lab shows the
   threaded arm surviving the same seeded faults. "Material" is defined before
   the run, against FINDING-A's re-verified noise floor — which on this machine
   is **138%**, so a threaded arm that wins by 20% has not won anything this
   instrument can see.
3. **An inconclusive prototype means single-threaded.** Written down in advance
   precisely because the temptation at that moment will be to read a wide noise
   band as a mild preference. A tie goes to the arm already shipping.
4. **Two constraints bind either arm** (unchanged): fail-closed — no
   shared-mutable `App` state without a guard equivalent to the existing poison
   mechanism — and the Phase-3 decision that registration after `serve` begins
   is **rejected**. WP42 inherits that; it does not reopen it.

---

## 2c. Sequencing amendment (2026-07-20)

**WP51 moves before WP46.** WP51 is the vendor maintenance policy; ADR-031 makes
WP46 the package that patches the vendored connection read. **A patch that
predates the policy governing patches is how a fork starts** — and this
repository already carries five vendored patches whose behaviour, not text, the
WP9 corpus asserts. That method has to be written down as policy before it is
applied to the hottest code in the tree, not afterwards.

The critical path is therefore: **{39, 40, 41} → 42 → 43 → 51 → 46 → 44 → 45 →
47**, with 48, 49, 50 independent once 42 lands, 52/53 growing alongside, and
all → 54 → 55 → 56.

WP44 moving after WP46 is the second consequence, and it is the point of
ADR-031: shutdown-with-a-deadline is specified against a clock, and now there is
one to specify it against.

---

## 3. The work packages

Concise on purpose — full per-package prose is written at E-4 time, when the
Phase-3 outputs are real. What is fixed now is each package's **contract**:
objective, the research that binds it, and rollback.

### WP39 — Lifecycle state machine (RG-P4-A)

**DONE, 2026-07-20 — `planning/phase-4-spec.md` §1, `build/check_phase4_spec.sh`,
`build/check_wp39_controls.sh`.** Five closed states, five proof obligations,
gate-enforced with eight controls including a positive one.

**Writing the spec before the implementation earned its keep immediately.**
Reading the vendored server rather than assuming it found that a lifecycle
already exists there — `Server_State`, `Connection_State`, `Will_Close`,
one-way transitions, a real drain — **and that its drain loop has NO deadline:
it waits for active connections forever.** So WP44 is not "expose what is
already there"; the deadline is the part that does not exist, and the framework's
`Draining` must impose it AROUND the vendored loop rather than inside it.

**SPEC.** `Configuring → Serving → Draining → Stopped`, plus `→ Failed`, as
**data, not booleans** — the failure this prevents is `stopping`, `draining`
and `failed` as flags admitting combinations no reviewer can enumerate. Same
reasoning that made `Framework_Error` a closed union. Proof obligations that
travel to WP44: admission stop, close-after-send, an absolute deadline, and
cleanup that runs exactly once. **Rollback: HIGH** — a spec ships nothing.

### WP40 — Capacity and overload ledger (RG-P4-B)

**DONE, 2026-07-20 — `planning/phase-4-spec.md` §2.** Nine rows (R-1…R-9), each
answering all five questions, with the fifth column — **reserved for stop** —
parsed by the gate rather than eyeballed, because that is the cell that gets
filled with "n/a" under time pressure. The reservation rule is an inequality on
purpose: **admission is refused at or below the reservation, never at zero.**

**SPEC.** One row per resource — connections, accept queue, ingress, response
buffers, timers — each stating capacity, behaviour when full, the diagnostic,
who owns cleanup, and **the minimum reserved for stop/close**. The reservation
is the point: the fatal failure is not running out of capacity, it is running
out and having none left to shut down with. Rows land in the capacity ledger
at WP56. **Rollback: HIGH.**

### WP41 — Deterministic transport fault laboratory (RG-P4-C)

**DONE, 2026-07-21 — `tests/support/fault_lab/`, `tests/wp41-fault/`,
`build/check_wp41_controls.sh`.** Both halves of the success criterion are met:
**the same seed replays the same trail**, and the lab **found a defect the
existing tests miss.**

**THE FINDING, and it is the evidence ADR-031 and ADR-033 were waiting for.**
Every case in the WP9 corpus is a COMPLETE transmission — bytes arrive, the
parser rejects them, the connection is retired. None of them ever asks what
happens when the bytes simply **stop**. They stop here, and the server:

> never responds, never closes, and holds the connection open until the LAB
> runs out of patience.

Two shapes, both live: a client that sends a valid prefix and says nothing more,
and a client that trickles one byte at a time. **One socket, no bandwidth, held
indefinitely, and nothing counts it, bounds it or ends it.** That is slowloris,
and it is now a test rather than an inference.

**Recorded for ADR-033's decision at this package:** the lab did NOT have to
reach into the connection loop to make these faults reachable — a hostile client
over a real socket was sufficient. That is evidence toward the **keep/patch**
arm rather than the own-it arm, and it is one input rather than the verdict;
§2c's criterion also asks whether the deadline patch stays contained, which is
WP46's to answer.

**One defect in the lab itself, recorded because it is the same defect:** the
first version hung, because `net.recv_tcp` blocks and a patience loop around a
blocking read never re-evaluates its own deadline. **The lab reproduced, in its
own client, exactly the unbounded-wait bug it exists to find in the server.** A
timeout set on only one side of a connection is a timeout somebody is relying on
the other side to have.

**TESTS.** This is **P-T5**, deferred here by name from the Phase-3 plan.
Seeded and reproducible: fragmentation, slow reader/writer, timeout before and
after completion, concurrent close, failure after N bytes, slot reuse, an
artificially small pool, shutdown during a request. **Added at E-4:** a
registration-conflict poisoning (WP30) is now a trippable boot failure, so the
menu covers boot-time refusals and not only dispatch-time ones. Success criterion, stated
before it is built: **replay the same seed and get the same trail, and find at
least one mutation the current tests miss** — a lab that cannot demonstrate a
missed mutation has not earned its complexity. **Rollback: HIGH** (tests only).

### WP42 — Concurrency model (ADR-030)

**DONE, 2026-07-21 — `planning/phase-4-concurrency.md`,
`experiments/12-concurrency-arms/`, ADR-030 ACCEPTED. Decision:
SINGLE-THREADED**, with the burden of proof left on threading and the reopening
conditions written down.

**The timing did not decide and the pre-registered rule said what to do about
that.** Threaded finished ~31% sooner (1,288 ms vs 1,861 ms, both 400/400), and
31% sits far inside FINDING-A's 138% noise floor. Inconclusive means
single-threaded — a rule fixed before the prototype ran, precisely because at
this moment the temptation is to read a wide noise band as a mild preference.

**What decided it was correctness.** `thread_count > 1` is a ONE-LINE change in
the adapter, and it silently falsifies three shipped guarantees: the
non-atomic request-ID counter (whose own comment says so), the lazily-built miss
chain (a check-then-act into an append-only pool — a WRONG CHAIN, not a wrong
label), and the shared `dispatched`/`web.state` writes. Four amendments to
shipped guarantees in exchange for a speed-up this machine cannot measure.

**Recorded honestly: a collision was NOT observed**, and an apparent finding —
141 of 300 empty responses under threading — **evaporated against its control**,
which produced 133 of 300 single-threaded. The empties were the probe's own
shell redirection. That control is the only reason it did not ship as a defect.

**PROTOTYPE + ADR.** See §2b — the procedure is the deliverable, plus the
decision it produces. Resolves the direction of audit A-4 (package-level
transport globals) jointly with WP43. **Rollback: decays fast** — this is why
it precedes every package it shapes.

### WP43 — Per-server state replaces the transport globals

**DONE, 2026-07-21 — `web/internal/transport/odin_http_adapter.odin`,
`build/check_public_api.sh` §8d.** Internal only, **zero public change**, and
**every existing test passed unchanged and unmodified**, which was the
package's own condition.

**The defect it removes has the worst possible shape.** `web.serve` wrote its
`Config` into a package global that the backend handler read on every request.
With one server per process that is fine. With two it is a **silent
cross-wire**: the second `serve` overwrites the first's dispatch pointer, and
requests to one application run the other's — with nothing diagnosing it,
because from each server's own point of view nothing is wrong.

**No vendored change was needed.** The backend's `Handler` already carries a
`user_data: rawptr`; the capability was there and unused. The config now travels
WITH the handler, in a `Server_Runtime` that lives in `serve`'s own frame — no
allocation, no teardown, and no slot for a second server to overwrite.

**`g_server` deliberately remains, and is now the ONE NAMED exception** in the
gate rather than an unremarked survivor. `request_stop` asks a process-wide
question that only WP44's public surface can answer properly; removing it here
would mean inventing half of WP44 inside an internal package. Naming it is what
stops a second such global arriving quietly — proven by a negative control.

**IMPLEMENTATION, internal only.** ADR-018's direction; the prerequisite for
two servers in one process, for embedded use, and for WP44 having something
coherent to stop. Existing tests pass unchanged and unmodified. **Rollback:
HIGH while internal — defend that classification exactly as WP29 does.**

### WP44 — Lifecycle: stop, shutdown with a deadline, exactly-once cleanup

**PARTIALLY DONE, 2026-07-21 — `web/lifecycle.odin`, Amendment 14.
`stop` SHIPS (+1 symbol, ledger 50 → 51). THE DEADLINE DOES NOT.**

**What ships.** `web.stop(&app)`: admission ceases, in-flight work finishes,
`serve` returns when the drain completes. It returns IMMEDIATELY rather than
joining — the shape a signal handler needs, since a `stop` that blocked could
not be called from one. Idempotent and thread-safe, which is how obligation 4
(cleanup exactly once) is satisfied: the test calls `stop` twice and requires
the serve thread to still join.

**Obligations 1 and 4 are MET.** Obligation 2 (close-after-send) is inherited
from the vendored `Will_Close` state and is unchanged.

**OBLIGATION 3 IS UNMET, AND IS NAMED AS UNMET.** An absolute drain deadline was
attempted as a vendored patch and **withdrawn**. Bounding the drain loop is not
enough: the `nbio.run()` that follows it waits on every pending operation, and a
connection a client holds open has one. Closing those connections hard at the
deadline did not help either. **The measured result was a drain that never
terminated — worse than the unbounded wait it was meant to replace.**

Shipping a `max_drain_time` field anyway would have been the knob that lies this
project refuses — the same rule that made WP36 ship without timeout fields. So
the budget's second concept was NOT spent.

**ADR-033 IS REOPENED on this result.** It closed hours earlier on WP46's
contained patch; this is the counter-evidence it named in advance. One contained
patch and one uncontained one is not a verdict — it locates the boundary
somewhere between "a periodic sweep beside an existing tick" and "the operation
lifecycle of the event loop", and WP45 is the next test of where the line falls.

**A SECOND FINDING, and it belongs to ADR-030 rather than here.** A handler that
BLOCKS — `time.sleep`, a synchronous call — blocks the event loop, and therefore
blocks the drain and any deadline check running on it. The first version of the
obligation-3 test used a sleeping handler and measured 3.3 s against an 800 ms
deadline; no deadline could have helped, because the code that checks it never
ran. That is a documented consequence of the single-threaded decision, and it is
now in `docs/ai-context.md` where an application author will meet it.

**Still outstanding:** the drain deadline, and with it the last third of the
lifecycle spec.

**SPEC + IMPLEMENTATION, public surface.** The smallest surface that gives:
admission stop first, an **absolute** deadline (never "wait forever"), and
cleanup proven exactly-once by the WP41 lab. G-09 evidence per symbol at spec
time. **Rollback: LOW once shipped** — operators build scripts and systemd
units on a stop command within days; size it like WP36 sized its options
struct, because every symbol is a promise.

### WP45 — Connection lifetime: keep-alive, drain-or-close, staged close

**DONE, 2026-07-21 — DRUSE PATCH 7, two new phases in `tests/wp41-fault`.
Zero public symbols.**

**IT FOUND THAT KEEP-ALIVE WAS BROKEN FOR EVERY GET**, which is most traffic.

The gap that hid it is worth stating, because it is a shape rather than an
oversight: **the WP9 corpus proves that a BAD request retires a connection, and
nothing proved that a GOOD one preserves it.** A server that closed after every
single response would have passed the entire existing suite. The two phases
added here close that: two requests on one connection must both be answered,
and a rejected request must still RECEIVE its 4xx before the connection goes.

**The cause was an upstream defect, one line.** `_body_length` sets
`_body_ok = false` at entry — the flag `response_must_close` reads as "the body
read failed" — and a request with **no** `Content-Length` returned through the
SUCCESS path without correcting it. So every GET looked like a failed body read
and had its connection retired. **No `Connection: close` was advertised**, so a
client had no way to know it was paying a TCP handshake per request while
HTTP/1.1 promised persistence. Measured before the patch: request one answered,
request two met an orderly close. After: three sequential requests, three 200s.

**This is the fourth upstream bug among seven carried patches**, and the
plainest — it has nothing to do with Druse's policies and breaks persistent
connections for anyone building on that server. Offered upstream under WP51.

**FOR ADR-033, which WP44 reopened:** this patch is one line in one procedure.
It is the most contained of the three so far, and it does not move the boundary
WP44 located — a body-flag fix is not the operation lifecycle of the event loop.
The evidence still reads: contained at the edges, uncontained at the loop.

**IMPLEMENTATION.** C-3 binds it three times over: 400-and-close on framing
errors, drain-or-close after every early rejection (§9.3 — leftover bytes are
the next request smuggled), and the staged close of §9.6, because a 400 the
client never receives is a real failure mode. Extends the WP9 corpus with
connection-lifetime assertions. **Rollback: MEDIUM** — observable wire
behaviour, but behind spec-recorded RFC obligations rather than taste.

### WP46 — Limits: connections, queue depth, headers, minimum ingress rate

**PARTIALLY DONE, 2026-07-21 — the READ DEADLINE ships.**
`Limits.max_request_time` (default 30 s), DRUSE PATCH 6 in the vendored
server, Amendment 13, claim-ledger row C-11, capacity-ledger row amended.
**Zero new symbols — a field, not a name.**

**It closed the hole WP41 found**, and the same laboratory is the proof: the
truncated-and-trickling phases still assert a connection is held open against a
server with NO deadline, and two new phases assert it is CLOSED against one that
configures a deadline. **The two behaviours sit side by side in one suite**, so
"the deadline works" cannot be satisfied by a server that closes everything.

**A REQUEST deadline, not an idle timeout.** An idle timer is reset by every
byte, so a client trickling one byte per second resets it forever — which is
precisely the attack. The clock starts when a request begins arriving and stops
when it has arrived, and it does not bound a slow HANDLER.

**A sweep, not a timer per connection.** A per-connection timer must be
cancelled when the request completes, and a timer outliving what it guarded is a
use-after-free waiting for a slot to be reused. One periodic sweep per thread
has no cancellation problem and no timer-capacity question, at the cost of
granularity — [deadline, deadline + 250 ms] — which for a defence measured in
seconds is not a cost.

**ADR-033 CLOSED on this result: KEEP AND PATCH.** The patch stayed contained —
one option field, one struct field, one sweep, two timestamp lines — and did not
spread across the read path, keep-alive and close, which was the named evidence
for owning the connection layer.

**STILL OUTSTANDING in this package:** connection count, accept-queue depth,
minimum ingress rate, inbound header COUNT (rows R-1, R-2, R-3, R-8), and a
WRITE deadline. The read deadline shipped first and alone because it is the
security fix, and bundling a security fix with a tuning surface is how a
security fix waits.

**SPEC + IMPLEMENTATION. Amended 2026-07-20 by ADR-031: this package now also
carries READ AND WRITE DEADLINES**, the half WP36 could not ship. They are rows
in the same `Limits` value, derived and validated at boot exactly like the byte
budgets, and they are the reason WP51 now precedes this package — enforcing them
requires patching the vendored connection read, and the primitive to do it
(`core:nbio`'s `timeout` and `close`) is already used by that server.

The deadline fields are **named at spec time, against WP41's fault menu rather
than against a wish list**, and sized by WP36's rule: every field is a promise
kept for as long as the type exists. A deadline is proven by a **seeded slow
client in the WP41 lab**, never by a unit test, and enters the claim ledger with
an unbounded-read negative control.

New rows in WP36's boot-derived runtime — the same
validate-once pattern, never a second mechanism. The slowloris mitigation is a
minimum ingress rate **on top of the deadline, not instead of it**: a deadline
bounds one connection's total patience, an ingress rate bounds the trickle that
stays inside it; OWASP names the technique and no numbers, so the chosen
numbers are recorded **as judgement, not as citation** (the C-5 honesty rule),
in the capacity ledger with behaviour-when-full. **Rollback: MEDIUM** — a
default, once shipped, is a promise about traffic.

### WP47 — Deterministic load shedding

**DONE, 2026-07-21 — DRUSE PATCH 8, `Limits.max_connections` and
`Limits.reserved_conns`, Amendment 15, claim-ledger row C-12, capacity rows R-1
and R-2 amended. Zero new symbols — two fields.**

**THE THIRD DEFICIENCY IS CLOSED.** Concurrent connections were bounded only by
the operating system's descriptor limit; the framework's own refusal now arrives
before the kernel's, which is the entire point of having a limit rather than
inheriting one.

**The reservation is an inequality, and the test proves the GAP rather than the
ceiling:** with a budget of 6 and 2 reserved, the fifth connection is refused
while two slots are still free. Testing at zero would have proved the wrong
rule.

**Deterministic, as the plan required — no adaptive controller.** The decision
is a comparison against a boot-validated number; there is no feedback loop, no
sampling and no hysteresis. Research item 10 before 11.

**On "rejection is cheaper than admitted work":** the plan asked for that claim
with a measurement. **It is NOT claimed**, and therefore not measured — the
instrument's noise floor is 138%, so a per-connection cost comparison here would
be theatre. What C-12 claims instead is the bound and the reservation, both of
which are observable without a stopwatch.

**IMPLEMENTATION.** Bounded admission per WP40's reservation rows. The claim
"rejection is cheaper than admitted work" enters the claim ledger **with a
measurement and a negative control**. **Rollback: MEDIUM.**

### WP48 — Trusted proxies

**DONE, 2026-07-21 — `web/client_address.odin`, `tests/wp48-public-surface`,
Amendment 16. +2 symbols, ledger 51 → 53.** ADR-013's fail-closed arm.

**`client_ip` returns the CONNECTED PEER**, never a header, unless that peer
matches a prefix registered with `trust_proxies`. `X-Forwarded-For` is a request
header — any client can send one — and rate limits, audit logs and allow-lists
built on a forged value are an authorization bypass. **Trusting the header by
default is not a convenience with a caveat.**

**PREFIXES RATHER THAN CIDR, and the asymmetry is the argument.** A wrong CIDR
mask can trust a network you did not mean to trust; a wrong prefix can only fail
to trust one you did. The simpler design's failure mode points the safe way, and
CIDR remains a strengthening a later package can add against evidence.

**The plan asked for an IPv4/IPv6 CIDR corpus. It is NOT delivered**, because
there is no CIDR arithmetic to test — that is the scope change above, stated
rather than quietly reinterpreted. The direct-spoof negative controls the plan
also asked for ARE delivered, and they are most of the suite.

**Registration fails closed twice:** an empty prefix (which would match every
peer) and more than the bound of eight (truncation would leave the operator's
configuration quietly untrue).

**SPEC + IMPLEMENTATION** under ADR-013's accepted direction. IPv4/IPv6 CIDR
corpus; direct-spoof negative controls; both peer and effective addresses kept
internally; `Forwarded` never echoed. **Rollback: LOW once anyone's audit or
rate-limit policy depends on it — which is exactly why the ADR preceded the
implementation.**

### WP49 — Secure headers and cookies

**DONE, 2026-07-21 — `web/secure.odin`, `tests/wp49-public-surface`, Amendment
17. +1 symbol, ledger 53 → 54, plus a FIELD on `Recorded_Response`.**

**D-14.3 IS DECIDED, and this package is what forced it.** Phase 2 kept
`Recorded_Response` at two fields and recorded the pressure as an open question.
`secure_headers` ends it: the feature exists so an APPLICATION can assert its
own security posture, and an application that cannot observe the headers it
asked for has to test through a socket — the thing `test_request` exists to
avoid.

**Three headers, chosen by a harsh rule:** one correct value, no configuration,
cannot break an ordinary application. **CSP and HSTS are deliberately absent** —
CSP is pure policy and a wrong one breaks the app; HSTS belongs to whatever
terminates TLS, which this framework does not. **Cookies: there is no cookie
API, so there is nothing to secure**, and inventing one to have somewhere to put
`SameSite` would be accretion. That half of the package's title is answered by
refusing it.

**A gate defect found on the way:** the `Recorded_Response` field extractor used
a bare `sed` substitution, which passes non-matching lines through — so a struct
with doc comments yielded comment text as field names. Unnoticed because the
struct had no comments until a field arrived that needed explaining.

**SPEC + IMPLEMENTATION.** Forces the `Recorded_Response` header decision that
Phase 2 deferred (D-14.3) — resolve it in the spec half, not in passing.
**Rollback: MEDIUM.**

### WP50 — Observability, with redaction as its spec half

**DONE, 2026-07-21 — `planning/phase-4-spec.md` §3 (the policy),
`web/observability.odin` (+1 symbol, ledger 54 → 55), Amendment 18, three gate
controls.** The spec half landed first, as the plan required.

**THE POLICY IS STRONGER THAN THE ONE THE PLAN ASKED FOR, and the difference is
what makes it enforceable.** The plan named OWASP's do-not-log list — tokens,
session identifiers, passwords, connection strings, keys, PII, payment data.
**Every item on it is already excluded by the rule that no REQUEST-DERIVED BYTE
is recorded at all.** A list can be incomplete and needs maintaining against
attackers who read it too; the rule needs no list and fails closed. So the list
is recorded as MOTIVATION and the rule is the mechanism — stated explicitly, so
a later reader does not add an `is_password_like()` check that gives false
comfort.

**MOST OF IT WAS ALREADY TRUE, and the spec says so rather than claiming new
work.** `Framework_Event` admits no request-derived string but `route`;
`web.route` is gate-asserted at every write; the logger escapes the pattern and
derives its bound; `request_id` DISCARDS an invalid client value rather than
sanitising it. **The property was preserved package by package before there was
a policy naming it** — §3.5's standing rule is what stops that being luck from
here on.

**The implementation half is one integer**, and it exists because §3.5 demands
it: WP47 could refuse a connection, and that discard was invisible. A server
under admission pressure looked exactly like a server nobody was talking to.

**SPEC + IMPLEMENTATION.** The redaction policy lands first: OWASP's
do-not-log list made concrete (tokens, session identifiers, passwords,
connection strings, keys, PII, payment data), CR/LF escaping against log
injection, and the standing rule that metrics and spans key on the **route
pattern from WP34's accessor, never the raw path**. Non-blocking, with an
observable drop policy — a logger that can apply backpressure to requests has
inverted the hierarchy. **Rollback: MEDIUM.**

### WP51 — Vendor maintenance policy

**DONE, 2026-07-21 — `planning/vendor-policy.md`,
`build/check_vendor_policy.sh`.** Three negative controls run.

**Checking upstream, rather than assuming it, produced the useful finding.**
Of the five carried patches, **two fix upstream's own bugs and three are
deliberate divergences** — and that ratio is what makes a re-vendor predictable.
Read against upstream `main` on 2026-07-21:

* **Patch 2's bug appears ALREADY FIXED upstream** — the chunked path now
  reports through its error callback instead of asserting. The patch is likely
  to become unnecessary at the next re-vendor, and its corpus case stays
  regardless, because the case proves the behaviour whoever implements it.
* **Patch 1's bug appears STILL PRESENT** — `_body_length` still parses
  `Content-Length` with `strconv.parse_int` and guards only with
  `max_length > -1 && ilen > max_length`, which a negative value passes. That is
  a remote process kill in a general-purpose HTTP server, not a Druse-specific
  concern, and it is the one worth reporting upstream.

**The evidence rule is the load-bearing part**, and the gate protects it because
it is the one most likely to be "improved" back into a grep: patches are proven
by CORPUS, never by grep over vendored text, because **a correct re-application
written differently must still pass.**

**The watch obligation sits on the phase freeze, and the policy admits that
nothing watches between freezes** rather than implying a vigilance nobody
performs. A commit pin does not change under you; the risk is staleness, not
surprise.

**SPEC. MOVED BEFORE WP46 (§2c), because ADR-031 makes WP46 a patching
package** and a patch that predates the policy governing patches is how a fork
starts. This package's output is therefore a precondition, not a retrospective.

Audit A-9/A-10: upstream the security patches or record why not;
replace code-shape greps over vendored sources with corpus assertions (a
correct re-application of a patch, written differently, must still pass);
name who watches upstream and how often. **Rollback: HIGH.**

### WP52 — Fuzzing and the extended framing corpus

**DONE, 2026-07-21 — one new corpus case, one case renamed, and one case
WITHDRAWN with its reason.** The withdrawal is the useful part.

**A RESPONSE-FRAMING AXIS THE CORPUS DID NOT HAVE.** Every case before this one
was about a request the server must refuse; none asked whether the server's own
RESPONSE is framed correctly. A 204 carrying a body desynchronizes a persistent
connection exactly as a malformed request does — the direction is reversed and
the failure is the same.

**A CASE WAS TRIED AND WITHDRAWN, and the reason is an instrument boundary
rather than an oversight.** WP45 found that SEQUENTIAL keep-alive was broken
while the corpus's keep-alive case — which sends both requests in ONE write —
passed for the whole life of the project, because the second request's bytes
were already buffered. That case is now renamed to say `PIPELINED`, because **a
case whose name is broader than its evidence reads as coverage it does not
have.**

A sequential case was then added here and **it did not go red when WP45's fix
was reverted.** The wire harness is single-exchange by construction — one write,
then read until the stream goes quiet — so a case layered on top of it cannot
express "and then, later, ask again". **A corpus case that passes either way is
worse than no case.** It was withdrawn, and sequential keep-alive is tested in
`tests/wp41-fault`, which owns a connection across time.

**The split is now explicit: this corpus owns BYTES, the fault lab owns TIME.**
That is the same boundary WP46 found from the other side, when a deadline could
not be expressed as a byte sequence.

**NO FUZZER SHIPS.** The plan's title says fuzzing; what a fuzzer needs and this
project does not have is a corpus-minimising harness and a crash oracle beyond
"the process died". `tests/wp41-fault`'s seeded generator is the closest thing
and it is deterministic on purpose — a fuzzer's value is finding inputs nobody
imagined, and its cost is findings nobody can replay. Recorded as not delivered
rather than counted as done.

**TESTS.** Extends WP9's raw-wire corpus to response framing and the C-3
cases. Body policy (HEAD, 1xx, 204, 304) stays internally separate from
framing (fixed length, chunked, close-delimited) so the combinations remain
enumerable — neither concept becomes public API. **Rollback: HIGH.**

### WP53 — Load, soak and fault-injection tests

**PARTIALLY DONE, 2026-07-21 — `experiments/13-soak/`,
`planning/phase-4-soak.md`.**

**800 requests over 8 keep-alive connections: 400 × 200, 400 × 201, zero
failures.** The keep-alive shape is what makes it worth having — a hundred
requests per connection exercises exactly the path WP45 repaired, and before
that fix this load would have failed on request two.

**No latency percentiles, and none will come from this harness.** FINDING-A's
noise floor is 138%; a p99 from inside that band is a number about the machine.

**RSS was not usefully captured** — the process had been terminated before the
second read, so the reported growth is meaningless. **Recorded as a broken
measurement rather than as an improvement**, which is what the arithmetic would
otherwise have claimed.

**And the run is short.** 800 requests is a smoke test with a plural; the honest
word for what ran is *load*, not *soak*.

**TESTS.** Includes a slow-client and a slow-writer workload. Methodology
inherits WP26 wholesale: two instruments, status distribution reported,
hardware-keyed baselines, distributions never single figures. **Rollback:
HIGH.**

### WP54 — Allocator and lifetime audit, whole-system

**NOT DELIVERED, 2026-07-21, with the reason recorded rather than the box
ticked** — see `planning/phase-4-soak.md`.

**The serve path does not run under an allocator this process controls.** The
vendored server owns per-connection arenas and a per-thread temp allocator, and
`web.serve` hands it a `Config`, not an allocator. A tracking allocator over
that path means either patching the vendored allocator plumbing — **precisely
the uncontained kind of patch WP44 hit, and what ADR-033 is reopened over** — or
measuring only the part Druse already owns, which WP27 and WP35 measured
twice.

**This is the same finding arriving a third time:** what this project can
observe cheaply stops at the boundary of the vendored event loop. Three
independent packages now say it — WP44's drain, WP46's containment result, and
this — and it belongs to ADR-033's decision rather than to a test.

**TESTS.** Tracking allocator over the full serve path; baseline is WP35's
shipped policy. Generational tokens for slots and timers **only if reuse
exists by now** — P-T7's discipline restated: the abstraction arrives with the
reuse, never before.

**Resolved at E-4:** WP35 decided to change nothing and **no slot reuse
exists**, so the contingency is OUT of scope as this plan stands. It returns
only if a Phase-4 package introduces reuse — and ADR-031's per-connection timers
are the one candidate, so WP46 owns the finding if it creates any. **Rollback:
HIGH.**

### WP55 — Operations documentation

**DONE, 2026-07-21 — `docs/operations.md`.**

**Written for whoever has to deploy this and be woken up by it**, which is why
§3 ("what the framework does NOT bound") and §10 ("known limitations") are the
two longest sections. A deployment guide that only lists features is a guide
that gets someone paged.

It states the supported topology (proxy + supervisor), the bounds and their
defaults, **the shutdown edge WP44 could not close**, the single-threaded
consequence for blocking handlers, what to monitor and what the framework will
never log, and the ten-point checklist. Every limitation carries WHY it is a
limitation rather than only that it is one.

**DOCS.** How to deploy — reverse-proxy TLS termination as the documented
topology (§2b) — what to bound, what to monitor, what is **not** hardened, and
the supervisor expectation stated for operators (ADR-020: a faulting handler
aborts the process; that is the contract, not a bug). Points at `druse
doctor` on the product track. **Rollback: HIGH.**

### WP56 — Phase-4 freeze

**DONE, 2026-07-21 — `planning/phase-4-freeze.md`,
`build/check_phase4_freeze.sh`, three controls. PHASE 4 IS FROZEN: 50 → 55
application, union 57.**

**Approval was the gate's, under the ADR-029 delegation.** The one
breach-shaped item is not a breach: two packages are recorded as NOT DELIVERED
with their reasons. The delegation's condition is that criteria are met, not
that every box is ticked — and **a package that records why it could not be
built is a criterion met, while one that ships a knob that lies is not.**

**Re-running all fifteen mutation suites repaired three controls**, and every
one of them broke because the tree IMPROVED: WP23's probe lost its anchor when
WP49 inserted a block; WP25's control targeted a row WP47 had bounded; WP41's
count was two and WP45 made it three. That is the healthy failure mode, and it
only shows up if somebody re-runs them.

**ONE MATTER GOES TO THE OWNER: ADR-033 is OPEN.** Whether Druse eventually
owns the HTTP/1.1 connection layer is now backed by three independent findings —
WP44's drain, WP46's containment result and WP54's allocator seam — all stopping
at the same place. It is the largest question the project has.

**FREEZE.** Everything WP38 required, plus: a capacity-ledger row for every
WP40 resource; the fault-lab seeds recorded as data; a claim-ledger row with a
negative control for every shed/stop/drain promise; soak results recorded; the
usage lab re-run — the concept budget conversation does not end at Phase 3.
Approval delegated to the gate exactly as WP38's was.

---

## 3b. What "no deficiencies" means here, and what it does not

The owner's instruction for this phase is a framework **without deficiencies**,
accepting hard architecture to get there. That is a real constraint and it
needs a definition, or it becomes a licence to build everything.

**A deficiency is a gap between what the framework CLAIMS and what it DOES.**
That is the standard this phase is held to, and by it the current tree has
exactly three:

1. **No deadline of any kind.** The capacity ledger says Druse bounds its own
   per-request working memory; it bounds the *bytes* and not the *time*, and a
   slow client walks through the byte budget untouched. → ADR-031, WP46.
2. **No way to stop.** `web.serve` blocks until the process ends, so the only
   shutdown is a kill, and in-flight requests are cut. → WP39, WP44.
3. **No bound on connections, accept queue or header count.** The ledger says
   so plainly today, which makes it honest rather than a lie — but honest about
   a hole is still a hole. → WP40, WP46, WP47.

**An absence is NOT a deficiency when it is stated, reasoned, and belongs to
someone else.** In-process TLS, CORS, uploads, static files, WebSocket and
streaming are absent by decision, with the reasoning recorded and the surface
assigned to optional packages or to the deployment. Building them into the core
would not remove a deficiency; it would add attack surface to a framework whose
value proposition is a small, frozen, gate-enforced one — and the mission's
precedence puts discipline above convenience for exactly this case.

**The one place the distinction is uncomfortable, stated rather than hidden:**
panic aborts the process (ADR-020). That is not a deficiency — Odin has no
recoverable panic, so it is a property of the language, and the framework's
duty is to say so and to make the supervisor expectation explicit (WP55). A
framework that pretended otherwise would have a deficiency; this one has a
constraint it documents.

**The test for the phase, then:** at WP56, every row of the capacity ledger
states a bound and a behaviour-when-full, every claim in the claim ledger has a
negative control, and no document describes a limit the framework does not
enforce. That is "no deficiencies" made checkable, which is the only form of it
worth promising.

---

## 4. Deliberately not in this phase

* **CORS, uploads, static files** — out of core by §2b; their recorded
  constraints travel with the future optional packages.
* **In-process TLS** — §2b; the ops doc documents proxy termination instead.
* **Adaptive overload control** — only after WP47's deterministic shedding has
  shipped and been measured (research items 10 → 11, in that order).
* **HTTP/2, WebSocket, streaming** — Phase-5 backlog, spec-gated, may be
  declined.
* **Rewriting the HTTP server** — R-T3, rejected and staying rejected **as a
  rewrite**. ADR-033 asks a narrower question with evidence attached: whether
  Druse eventually owns the HTTP/1.1 connection layer over `core:nbio` as a
  SECOND ADAPTER behind the ADR-009 boundary, gated on the conformance matrix.
  That is not a rewrite and not a big-bang replacement, and it is decided at
  WP41 or not at all.
* **Anything Phase 5 wants early.** A Phase-4 package that finds it needs one
  writes the finding down; it does not absorb the scope.

---

## 5. Risks this plan does not resolve

| Risk | Why it stays open |
|---|---|
| **The concurrency decision invalidates WP44–47 details** | That is why WP42 precedes them and why E-4 forces the refresh; the §3 prose is deliberately contract-level until then. |
| **The fault menu is finite** | A real network invents faults nobody seeded. WP53's soak is the partial answer; humility in the freeze wording is the rest. |
| **Slowloris numbers are judgement** | OWASP gives none. The ledger records them as engineering judgement, revisable with operational evidence — never as citation. |
| **Timing claims inherit FINDING-A** | Unless the toolchain changed and was re-verified (§0), every timing claim in this phase is a distribution or it is not made. |
| **The stop surface is LOW-reversibility** | WP44 ships the smallest surface for exactly this reason, and the spec half exists to be argued with before anything is promised. |

---

## 6. The Tina dossier — Phase-4 mapping

The rules of the Phase-3 plan's §6 apply unchanged and are not repeated in
full: **reference, never architecture; never a dependency; never committed;
never cited as evidence; its absence never blocks.** Phase 4 is where the
dossier is at its most useful — a runtime that supervises faults for a living
has answered these questions explicitly — and at its most dangerous, because
its answers are sized for a runtime Druse is not.

| Work package | Read | What is in there |
|---|---|---|
| **WP39, WP44** | `docs/03-io-scheduler-e-lifecycle.md` | Lifecycle states, cancellation, completion ordering |
| **WP40, WP46, WP47** | `docs/02-memoria-ownership-e-backpressure.md` | Backpressure, bounded pools, behaviour-when-full discipline |
| **WP41** | `docs/04-supervisao-falhas-e-dst.md` | Deterministic fault testing — this is P-T5's home |
| **WP42** | `docs/01-arquitetura-do-runtime.md` | The thread-per-core design — **first entry on the not-adopt list; read to understand, not to copy** |
| **WP52** | `docs/05-tina-http.md` | A second HTTP implementation's framing decisions |
| **WP54** | `docs/02-…` P-T7 | Generational tokens, arriving only with reuse |
| **WP56** | `docs/09-…` P-T1/P-T2, `docs/10-…` | Claim discipline and self-bounding, as in every freeze |

Not adopted, restated from the dossier's own impact document: thread-per-core
as a requirement, isolate-per-connection in the API, global arenas, signal
recovery, a messaging protocol, the Tina backend in core.

---

## 7. What an implementation agent should read first

1. **§0 and E-4 of this document.** If the refresh has not been applied, the
   first work package is the refresh.
2. `planning/later-phases-plan.md` §Phase 4 — C-1…C-8 and the RG-P4 gates
   remain authoritative for the questions they cover.
3. `planning/phase-3-plan.md` §2b and **ADR-029** — how approvals work now;
   the reserved matters that still stop for the owner.
4. `planning/phase-2-freeze.md`, and the Phase-3 freeze once it exists — the
   ledgers this phase amends and the claims it must not break.
5. `planning/adrs.md` — an ACCEPTED ADR supersedes plan text when they
   disagree; ADR-013 and ADR-020 bind this phase directly.
6. `tina/` — the mapped document only (§6), when the environment supplies it.
7. **The code and tests of the work package before it** — this project has had
   documented behaviour the code did not have; never conclude from documents
   alone.
