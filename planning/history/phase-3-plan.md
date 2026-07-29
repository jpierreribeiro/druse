# Phase 3 — Performance core: work package plan

**Status: DRAFT FOR HUMAN REVIEW.** Nothing here is frozen. Every signature is
marked **PROPOSED**. Phase 2 froze 44 application + 2 test-support = 46
(`planning/phase-2-freeze.md`); this plan proposes how that grows and demands
evidence for each increment.

Work packages continue the numbering: **WP26 – WP38**, mapping onto the
`P3-1 … P3-13` slots reserved in `planning/later-phases-plan.md`.

The theme is stated in one line, because it constrains every decision below:
**make it stay fast as route count and traffic grow, and let operators bound
it — with representation decisions conditioned on measurement, never on
folklore.**

---

## 0. Four findings that reshape this plan before any work package starts

All four are measured facts from Phase 2, not recollections. Three of them
invalidate something the skeleton plan in `later-phases-plan.md` assumed.

### FINDING-A — the toolchain does not build reproducibly, and RG-1 must survive that

Five builds of an **identical, unmodified** source tree produced five different
binaries: 876,304 / 876,352 / 876,352 / 876,368 / 876,360 bytes, five distinct
md5 sums. The vendored backend's use of `core:nbio` — the event loop comes from
the pinned toolchain, not the vendor tree — emits polymorphic instantiations
whose mangled parameter names vary between runs.

**Consequences for Phase 3, which is the phase that lives on measurement:**

* **Binary size has a ~100-byte noise floor.** Any regression check on binary
  size must state that floor and treat smaller deltas as "no measurable
  change". A gate that fails on a 40-byte "regression" would fail randomly.
* **Byte-identity is never a valid assertion** (WP22 Amendment 1). Where a
  work package wants to say "unchanged", it asserts a symbol count, an
  allocation count, or a behavioural equivalence — never a hash.
* **Timing needs far more than this.** If the *linker* is nondeterministic,
  code layout is too, and layout moves branch prediction and cache behaviour.
  RG-1's methodology must therefore include repeated alternating runs and
  report a distribution, not a number. A single "X is 8% faster" measurement
  taken once is not evidence and must not be accepted by the gate.

### FINDING-B — the framework cannot import a clock, and Phase 3 needs one twice

WP6 measured `core:log` at **~37 KiB added to every application**, referenced
or not, because Odin links an imported package regardless of use. That measured
rule is why `web/logger.odin` imports nothing, why `web.logger` has **no latency
field**, and why WP23's request-ID generator seeds from ASLR addresses instead
of `base:intrinsics` or `core:time`. `build/phase1-direct-dependencies.txt`
pins `web`'s direct imports at five and the freeze gate enforces it.

Phase 3 needs a clock in two places, and they are **not** the same problem:

* **The benchmark harness (WP26)** needs timing. It must live **outside**
  `package web` — in `tests/` or a separate benchmark package — so no
  application ever links it. This is not a preference; importing `core:time`
  into `web` to benchmark it would change the thing being benchmarked.
* **Timeouts (WP36)** need a clock **on the serving path**. But that path is
  `web/internal/transport`, which already imports `core:net` — and the vendored
  backend behind it (`vendor/odin-http/server.odin`) already imports `core:time`
  and `core:nbio`, so the serving path links a clock today whether or not any
  Druse package names one. The open cost question is what an *additional*
  `core:time` import into Druse's own packages costs — entirely different from
  the cost question in `web`, and it must be measured rather than assumed either
  way. **A work package that adds a `core:time` import to `web` itself needs
  owner approval and a measured justification.**

The skeleton plan did not distinguish these two. It must.

### FINDING-C — Phase 2 froze CLAIMS, so Phase 3's gate obligations are larger

`planning/phase-2-freeze.md` added three ledgers that Phase 1 did not have, and
`build/check_phase2_freeze.sh` enforces them. Every Phase-3 work package
inherits obligations no Phase-2 work package had:

* **The capacity ledger becomes wrong the moment limits are configurable.**
  Today it says the body limit is "**4 MiB**, fixed, not configurable until
  Phase 3". WP36 changes that row, and it must change it **in the same commit**
  or the freeze gate is telling a lie about the shipped code.
* **Any new strong claim needs a negative control**, in the claim ledger,
  before it can be made in prose. "The new router is faster" is a claim. So is
  "reuse does not retain a giant buffer".
* **"Bounded" stays a gated word.** WP36 makes limits configurable; it does
  **not** make the server bounded. Connections, backlog and header counts
  remain the transport's, and the gate rejects any document that says
  otherwise.

**The six-file ledger ritual still applies**, unchanged, to every work package
that adds a symbol: `check_public_api.sh`, `check_phase1_freeze.sh`,
`phase1-public-signatures.txt`, `planning/phase-1-freeze.md`, `check_docs.sh`
plus `docs/ai-context.md`, and `CHANGELOG.md` — in ONE change, or the gate
fails with a misleading cause.

### FINDING-E — the timing noise floor is ±57.6%, and WP28 must plan around it

**Added by WP26, 2026-07-20.** FINDING-A predicted the shape of this; it did not
supply the magnitude, and the magnitude is worse than this plan assumed.

Ten alternating repetitions of the **unchanged** Phase-2 dispatch path gave a
derived p95 spread of **5,763 basis points — ±57.6%** at 5 routes. The full
table is in [`planning/phase-2-baseline.md`](phase-2-baseline.md).

Consequences, none of them optional:

* **No timing-based regression gate is available at small cardinalities.** A
  change would have to make dispatch more than half again as slow before this
  machine could distinguish it from running the same binary twice. `WP26`'s gate
  step therefore asserts **allocations and instrument soundness, and no timing
  at all** — a consequence of the measurement, not a shortcut around it.
* **Noise falls as cardinality rises**: 5,763 bp at 5 routes, 1,302 bp at
  5,000, because the work grows while the jitter does not.
* **WP28 may not be decided on 5- or 50-route timings.** A candidate that wins
  at 5 routes by 20% has won nothing measurable. The cardinalities where this
  instrument discriminates are **500 and 5,000**, and the shootout's conclusions
  must come from there or be recorded as undecided. That is a stopping rule, and
  it is now derived from data rather than asserted.
* **The Phase-2 scan is linear and now has a number**: ~165 ns per registered
  route, 1.8 µs at 5 routes rising to 826 µs at 5,000. WP28's candidates have
  something concrete to beat.

### FINDING-D — the concept budget is now a measured number, and Phase 3 spends it

WP25 re-ran the usage laboratory:

| Program | Concepts |
|---|---|
| five-route CRUD, unguarded | **14** (unchanged since Phase 1) |
| the same, with middleware, router, auth, logging, request IDs | **23** |

The skeleton plan's own words: *"if a five-route CRUD service now needs 25
concepts instead of 14, that is a finding, not a footnote."* At 23, Phase 3
starts with **two concepts of headroom** before that sentence becomes true of
this project.

Three Phase-3 work packages propose public surface (WP34 route identity, WP36
limits, WP37 typed state).

**The budget is stated in CONCEPTS, not symbols, because they are not the same
unit** — an earlier draft of this plan conflated them. The usage lab counts
`web.*` names that appear *in a program*. A metrics accessor (WP34) costs a
symbol and very likely **zero** concepts, because a CRUD service never calls it;
a limits struct taken at its defaults (WP36) does the same. A symbol budget
would block a change that costs a reader nothing and wave through one that costs
three.

**So: the guarded lab program may reach at most 25 concepts, and WP38 measures
it with the instrument that produced 23.** Symbol growth stays governed by what
already governs it — G-01 (one name per operation) and G-09 (growth carries
evidence), per symbol, as in every phase so far. If the guarded number passes
25, the freeze says so in those words rather than quietly printing a longer
table.

---

## 1. Entry conditions (not work packages)

| ID | Item | Status |
|---|---|---|
| E-1 | Phase 2 frozen — ledger 46, `check_phase2_freeze.sh` green | ✅ met (`planning/phase-2-freeze.md`) |
| E-2 | The full gate exits 0 on `main` | ✅ verified after the Phase-2 merges |
| E-3 | A benchmark harness exists | ✅ **met by WP26** — `tests/support/bench`, gate step, `planning/benchmark-methodology.md`, `planning/phase-2-baseline.md` |

E-3 is the real gate. The skeleton lists "a benchmark harness exists" as an
entry condition *and* as P3-1; it is a work package, and treating it as a
prerequisite that someone else supplies is how a phase starts choosing
representations before it can measure them.

---

## 2. Work package sequence

| WP | P3 | Name | Type | Owner approval |
|---|---|---|---|---|
| 26 | P3-1 | Benchmark harness and Phase-2 baseline | TESTS | no |
| 27 | P3-3a | Allocation audit (A-8, A-12, A-13) | PROTOTYPE | no |
| 28 | P3-2 | Route representation shootout | PROTOTYPE | no — **but must not choose before measuring** |
| 29 | P3-3 | Router implementation | IMPLEMENTATION | no (internal only) |
| 30 | P3-4 | Registration conflict diagnostics | SPEC + IMPLEMENTATION | **yes** if it changes registration behaviour |
| **31a** | P3-5 | Path normalisation — **the policy** | SPEC | **yes** — observable HTTP semantics |
| **32a** | P3-6 | HEAD, OPTIONS, 501 — **the decision** | SPEC | **yes** — observable HTTP semantics |
| 31b | P3-5 | Path normalisation — implementation | IMPLEMENTATION | covered by 31a |
| 32b | P3-6 | HEAD, OPTIONS, 501 — implementation | IMPLEMENTATION | covered by 32a |
| 33 | P3-7 | Multi-param routes without a map | IMPLEMENTATION | no |
| 34 | P3-9 | Route identity accessor | SPEC + IMPLEMENTATION | **yes** — public surface |
| 35 | P3-10 | Arena, buffer reuse and oversize policy | IMPLEMENTATION | no |
| 36 | P3-11 | Configurable limits and timeouts | SPEC + IMPLEMENTATION | **yes** — public surface + capacity ledger |
| 37 | P3-12 | Typed application state, and the request-scope question | PROTOTYPE + IMPLEMENTATION | **yes** — public surface |
| 38 | P3-13 | Phase-3 freeze | FREEZE | **yes** |

**Dependencies:** 26 → {27, **31a**, **32a**}; {27, 31a, 32a} → 28 → 29;
29 → {30, 31b, 32b, 33}; 26 → 35; {26, 35} → 36; 34 and 37 are independent of
the router work and may run in parallel; all → 38.

**Note the shape:** the first three work packages produce **no user-visible
feature at all**. That is deliberate and is the single most important structural
decision in this plan — a performance phase that starts by implementing is a
performance phase that has chosen its representation by taste.

**WHY 31a AND 32a COME BEFORE THE SHOOTOUT, and this is a correction to the
first draft of this plan.** Path normalisation decides which paths are *equal*,
and OPTIONS decides which methods the table must *answer*. Both change what the
router has to match. Running the shootout first and those decisions afterwards
gives two bad outcomes and no good one: either WP29 is rewritten once the
semantics arrive, or — quieter and worse — the semantics get silently
constrained by a representation chosen without knowing about them. That would be
a design decision made by scheduling accident. So the two **specs** run before
the shootout and the two **implementations** after the router exists; the
approval each needs attaches to the spec half, where the decision actually is.

Note also that P3-8 (precomputed chains) is **absent as its own work package**;
see §4.

---

## 2b. Approvals resolved in advance (ADR-029 delegation, 2026-07-20)

The owner delegated the pending decisions (ADR-029), so the approval points in
the table above are **resolved now** and no work package stalls waiting for a
review. Every resolution is conditional in the same way: **if the work
package's own spec or prototype work contradicts the decided arm, the agent
stops and records the finding instead of proceeding.**

| WP | Decided arm | Grounds |
|---|---|---|
| **WP30** | **Diagnose-and-poison** at registration. | Fail-closed is the project default and the mechanism (ADR-019) exists and is proven. Go's precedent panics at registration; Druse poisons instead. Observable change — the spec and tests are still owed. |
| **WP31a** | **Ratify the absence of normalisation, permanently.** Bytes received are bytes matched; `/users` and `/users/` stay distinct; `web.path` params are **raw, undecoded views** — decoding is the application's explicit choice. | The security arm and the reversible arm coincide: every normalisation rule is an opportunity for two components to disagree about what a path means. The negative-control corpus is still owed and proves the mismatch behaviour. |
| **WP32a** | **Automatic HEAD** (respond as GET, suppress the body); **automatic OPTIONS** (reuse the `Allow` machinery); **no 501** — the SHOULD-deviation is ratified: an unknown method stays on the 404/405 path (WP9 D7). | HEAD is the RFC's MUST-support; OPTIONS costs no second machinery; 501 would open the method vocabulary with no demonstrated demand. |
| **WP34** | **Approved: +1 symbol.** | C-2's constraint is a MUST and the framework already holds the value. The redaction rule — the pattern, never the path — becomes a gate assertion in the same change. |
| **WP36** | **Approved**: options struct + package default **constant**; boot-derived immutable runtime. Concurrency arm: registration after `serve` begins is **REJECTED via the existing poison mechanism** — the snapshot sits beside ADR-019/023 and does not replace them. | The shape was already amended in; the vendored backend's mutable-global default (§6b) is the counter-example that confirms the constant. |
| **WP37** | Implements **ADR-004 only**. The request-scope question is closed: **ADR-028 is ACCEPTED, option A.** | See ADR-028; reopening requires a real program measured in this tree. |
| **WP38** | **Approval delegated to the gate**: the freeze proceeds if and only if every gate is green, every ledger amended, and the guarded lab program holds at ≤ 25 concepts. Any breach stops the freeze and goes to the owner. | A freeze that needs a human yes when every recorded criterion is met is ceremony; one that proceeds despite a breach is a lie. |

---

## 3. The work packages

### WP26 — Benchmark harness and Phase-2 baseline

**Type: TESTS.** Nothing else in Phase 3 may start first.

* **Public surface. None.** The harness lives outside `package web`
  (FINDING-B): an application must never link a clock because the framework
  benchmarks itself.
* **Objective.** A methodology, in the gate, plus a recorded Phase-2 baseline
  to regress against.
* **What the methodology must record**, per RG-1 and its 2026-07-20 amendment:
  hardware, warm-up, route distribution, concurrency levels, p50/p95/p99,
  allocation counts, binary size, build time, peak **and retained** memory,
  protocol version, keep-alive setting, alternating run order, core affinity
  and build mode.
* **Semantic equivalence is a GATE CONDITION, not advice.** Every candidate
  must answer the same protocol version and produce equivalent status, headers
  and body. The Tina study threw away an entire ApacheBench run because `ab`
  speaks HTTP/1.0, the strict server rejected it, and the tool reported 100%
  non-2xx **as throughput**. A load generator that gets rejected still reports
  a number, and the number looks like a number.
* **The status distribution is DATA, not hygiene.** Every run reports its
  status counts next to its latencies, and a run containing any status the
  scenario did not predict is **discarded as invalid, never averaged in**. The
  ApacheBench failure was not caught by reading the throughput number — the
  number looked fine; it was caught by reading the error column. Make the
  error column impossible to omit.
* **The harness is TWO instruments, and they are named separately.** An
  **in-process dispatch benchmark** drives the in-memory transport and owns
  every allocation count — C-5's zero-allocation claim is measured here, where
  the allocator can be instrumented and the run is deterministic. A
  **socket-level load run** owns latency and throughput distributions
  (FINDING-A). Neither can produce the other's numbers: a load generator
  cannot count allocations, and an in-process loop cannot see the kernel. The
  load generator itself is named in the methodology, and its HTTP/1.1 and
  keep-alive conformance is asserted before any of its numbers count.
* **Baselines are keyed to the hardware that produced them.** The recorded
  baseline states its machine identity — CPU model, core count, frequency
  governor, OS — and a regression comparison is valid only against a baseline
  from the same identity. On a machine with no baseline — a new CI runner, a
  different laptop — the gate re-derives baseline and tolerance first and says
  so; it never fails a build by comparing numbers from two different machines,
  which would manufacture a regression out of a hardware change.
* **FINDING-A applies directly.** Report distributions from repeated
  alternating runs, never a single figure. State the ~100-byte binary-size
  noise floor. A benchmark that cannot distinguish its own noise from a change
  is not a benchmark.
* **The tolerance is DERIVED, and here is the procedure** — an earlier draft
  said "measured, not chosen" without saying how, which is an instruction to
  pick a number and call it measured. Run the unchanged baseline **at least ten
  times, in alternating order**, and take the observed **p95 spread** as the
  tolerance floor. A later change counts as a regression only when it exceeds
  that floor. The number then comes from the machine rather than from taste, and
  it is re-derived — not inherited — whenever the hardware changes.
* **Completion criteria.** The harness runs from the gate; the Phase-2 baseline
  is committed as data; re-running on unchanged code reproduces the baseline
  within the derived tolerance above.
* **Out of scope.** Choosing anything. This work package produces numbers.

### WP27 — Allocation audit

**Type: PROTOTYPE.** RG-3.

* **Public surface. None.**
* **Objective.** Where does per-request allocation actually go? A measured list
  and a decision per item.
* **Known candidates, already named by the audit:** **A-8** (inbound headers
  materialised per request — WP19 made them *read*, but nothing measured
  whether the materialisation is worth it), **A-12** (static header pairs
  cloned needlessly), **A-13** (`Header_Pair` ↔ `transport.Header` conversions).
* **The claim it must protect.** Claim C-5 in the Phase-2 freeze says *dispatch
  through a middleware chain allocates zero bytes*, measured around
  `driver_run`/`driver_cleanup` and explicitly **not** around `test_request`.
  Any change here must keep that measurement valid and must not quietly widen
  the perimeter the claim names.
* **The instrument is named so nobody invents one:** `core:mem`'s
  `Tracking_Allocator` around the request path, plus the temp-allocator probes
  WP17 already uses — the same instruments that produced C-5's measurement, so
  the audit's numbers and the claim they protect come from the same ruler.
* **Out of scope.** Fixing them. This work package measures and decides; the
  fixes land in WP29 and WP35 where they can be regression-tested.

**DONE, 2026-07-20 — `planning/allocation-audit.md`, measured by
`tests/wp27-internal` in the gate.** A typical JSON 200 costs five allocations
on the socket path; a 405 with a request ID costs nine. Three outcomes, and one
of them is a correction rather than a schedule:

* **A-12 as filed is WITHDRAWN.** "They are static strings, so the clone is
  waste" is false for two of the three headers this framework emits. `Allow` and
  `X-Request-Id` carry values living in `Context_Internal` buffers that die at
  `driver_cleanup`, and aliasing them would hand the transport a view into freed
  memory. What survives is narrower and certain: every response header *name* is
  a package constant, so cloning names is unambiguous waste — **1 allocation per
  header per request, owner WP29**. The values must keep being cloned.
* **A-8 is half wrong in the direction that matters.** One `temp_allocator`
  slice per request, and the strings are **views, not copies**. Also stale: "no
  Phase-1 path can read them" stopped being true when WP19 shipped
  `web.header`. Handed to **WP35**, because the fix is a fixed-capacity buffer
  question the arena policy owns.
* **A-13 is confirmed exactly as filed and is being kept.** Two allocations per
  request, no string copying — the price of ADR-009's one-way boundary, now a
  number instead of an adjective. Reclassified from "cost to remove" to "cost
  accepted, with a number".

**Consequence for the sequence: WP28 inherits nothing from this.** None of the
three sits on the route-matching path; all three are request/response edges. The
shootout is not blocked by any decision here.

### WP28 — Route representation shootout

**Type: PROTOTYPE.** RG-2. **It must not choose before measuring.**

* **Public surface. None.**
* **Five candidates, all measured on Druse's own workloads:** pointer-based
  radix, index-based radix, hybrid, improved linear, and **class-bucketed
  linear** (static / `:param` / wildcard buckets, linear scan inside the
  matching bucket).
* **Cardinality sweep: 5, 50, 500 and 5,000 routes.** The only property a tree
  uniquely owns is *scaling*, so the sweep must reach far enough for scaling to
  become visible, or the shootout cannot answer the question it exists to ask.
* **The WORKLOAD SHAPE is part of the measurement, and omitting it flatters the
  incumbent.** A linear scan's cost depends entirely on *where* the answer is,
  so a benchmark that only ever hits the first route measures nothing. Every
  candidate is measured against the same matrix: a hit at the **start**, the
  **middle** and the **end** of the table; a **miss** (which scans everything);
  and a **405** (which scans everything and then builds `Allow`). Route
  composition — the static / `:param` / wildcard proportions — is stated with
  the numbers, because a bucketed candidate's advantage is a function of exactly
  that ratio. This is P-T8 in the Tina dossier (§6), and it is the difference
  between a shootout and a demo.
* **C-5 governs this work package** (`later-phases-plan.md`): the radix-router
  justification is not what folklore says. "A real, validated system does it
  this way" is not evidence about Druse's route cardinalities. Class-bucketed
  linear arrives with its own disclaimer — **it also scans linearly inside each
  bucket** — and is a hypothesis to measure, not a result to adopt.
* **The losing candidates and their numbers are RECORDED.** A shootout that
  publishes only the winner is a decision dressed as a measurement.
* **THE STOPPING RULE, stated before any number is collected so it cannot be
  chosen to fit the result:** *if no candidate beats the incumbent by more than
  the measured noise floor, at the cardinalities this project actually targets,
  **the incumbent wins**.* Given FINDING-A, that is a likely outcome at 5 and 50
  routes — which is what almost every real application has.
* **A no-op WP29 is a SUCCESS, not a wasted phase.** Without this said out loud,
  a work package named "router implementation" will produce a router
  implementation whether or not the data asked for one — which is C-5's warning
  arriving through a different door. The phase's job is to find out whether a
  change is warranted, and "it is not" is a finding worth the same as any other.
* **Deliverable.** A representation chosen from data, with the data — or a
  recorded decision to keep the current one, with the same data.

**DONE, 2026-07-20 — `planning/router-shootout.md`.** Six representations
measured; correctness proven in the gate by `tests/wp28-shootout`, which holds
all six to byte-identical answers and includes a constructible-disagreement
control.

**Chosen: `radix_idx`** — segment-keyed tree, nodes in a flat array, children by
index, static child before parametric at every level. At 5,000 mixed routes:
**1.4 us against linear's 191 us, about 136x**, and flat from 5 routes to 5,000.
Two orders of magnitude clear of FINDING-E's noise floor.

**The timing did NOT choose between `radix_idx` and `radix_ptr`** — same
algorithm, two layouts, medians differing by less than either cell's own spread.
Reading a winner there would be reading noise. The choice was made on ownership:
one free instead of N at teardown, and no pointer that can dangle when the node
array grows. That is the same class of hazard as P8, which the middleware pool's
index pairs already exist to prevent — the project has chosen indices over
pointers once before, for this reason.

**Losers, with the instructive ones named.** `linear_improved` HURT parametric
tables (290 us vs 245 us, the worst number measured): when the discriminating
byte falls inside the parameter segment the prefilter rejects nothing and every
route pays for it. `bucketed` matched linear exactly, as RG-2's own disclaimer
predicted, but its structural-precedence argument survives and the radix tree
gets that property for free. `hybrid` was the fastest single cell measured
(838 ns, flat) and degenerates to a scan the moment a parameter appears.

**THE CAVEAT WP29 MUST CARRY.** The shootout measures matchers in isolation.
Against WP26's end-to-end baseline, route matching is roughly **10% of
end-to-end p95** at 5,000 routes. WP29 may not promise an end-to-end speedup
proportional to 136x; the claim it can defend is about the matcher, and it must
name that perimeter. **Where the other ~90% goes has not been measured, and on
this evidence that is worth more than further router work.**

### WP29 — Router implementation

**Type: IMPLEMENTATION. Change classification: internal only.**

* **Public surface. None.**
* **The hard constraint:** every existing test produces a **byte-identical
  RESPONSE** — same status, same headers, same body — and those tests pass
  *unchanged and unmodified*. A test edited to accommodate a "performance"
  change is a behaviour change wearing a costume.
* **Read that word carefully:** byte-identical *responses* are testable and are
  required here. Byte-identical *binaries* are not a valid assertion anywhere in
  this project (FINDING-A). The two words look alike and mean different things;
  an implementation agent reads both in one sitting.
* **The pool invariant survives.** WP12 P8 measured a stored `[]Handler`
  dangling into `0xAAAAAAAAAAAAAAAA` the moment the pool reallocated, and P8b
  measured the same defect reading back *correctly* on the plain heap — a
  latent corruption. Index pairs are immune by construction. Any new
  representation must state, in its file comment, why it is immune or how it is
  protected.
* **Registration must stay fail-closed.** `append` in Odin does **not** panic
  when it cannot allocate: it returns `num_appended = 0`. WP18 Amendment 1
  fixed exactly this bug in `mount`. Every allocation on a registration path in
  the new representation checks its result and poisons the App on failure.
* **Mutation probes.** The existing WP17/WP18 probes must still pass — and if
  the representation changes the lines they anchor on, the probes are updated
  in the same change with their reasoning, never deleted.
* **Rollback.** HIGH while the change is internal-only: revert the commit and
  the old table returns, because no public signature and no observable
  behaviour moved. That is exactly why the "internal only" classification is
  worth defending — the moment a representation change drags an observable
  difference with it, this stops being revertible and becomes a behaviour
  change that applications may already depend on.

**WP29 DONE, 2026-07-20 — `planning/router-implementation.md`.** The flat scan
is replaced by the radix index; the flat array remains the single owner of every
pattern, handler and chain index pair, and the tree stores integers into it.
Built at registration, never at dispatch, so C-5's perimeter does not silently
acquire a first-request cost. Precedence is now structural rather than enforced
by loop order.

**End to end at 5,000 mixed routes: 883 us -> 1.5 us on p50, about 594x. And
dispatch is now FLAT** — 1,341 ns at 5 routes against 1,486 ns at 5,000, an 11%
difference that sits inside the noise floor. The framework no longer cares how
many routes an application registers.

**WP28's "matching is only ~10% of end-to-end" caveat is WITHDRAWN.** It was
approximately 99%. The shootout's `linear` entrant pre-split its patterns at
build time; the shipped `route_lookup` re-parsed the pattern string on every
comparison, so the real baseline was ~10x slower than the one measured. **A
baseline must be the shipped code, or it is a different program** — and the
correction runs in the flattering direction, which is exactly when a project is
least likely to check.

**Still owed:** registration cost was not measured, and the tree allocates a node
per distinct segment plus a map per node. That is now the largest unmeasured
thing in the router.

### WP30 — Registration conflict diagnostics

**Type: SPEC + IMPLEMENTATION.** Owner approval if registration behaviour
changes observably.

* Phase 1 deliberately does **not** diagnose a duplicate or conflicting
  registration (WP4 D5): a malformed pattern is stored, marked invalid, and
  never matches. Go panics at registration.
* **The decision to produce:** diagnose-and-poison (the ADR-019 mechanism
  already exists and is proven), diagnose-and-continue, or ratify the silence
  permanently. Fail-closed is this project's default and the burden is on any
  other answer.
* **Note the interaction with WP29:** a bucketed or tree representation makes
  some conflicts *structurally* detectable that a linear scan never noticed.
  Do not let a representation change silently become a behaviour change.
* **Rollback.** Depends on the arm chosen, and the deciding ADR must say so:
  ratifying the silence ships nothing and stays HIGH; diagnose-and-poison is
  MEDIUM and decays — withdrawing a shipped diagnostic un-breaks the programs
  it poisoned, but re-hides the conflicts it existed to surface, and programs
  written after it shipped will rely on registration failing loudly.

**WP30 DONE, 2026-07-20 — `web/dispatch_index.odin`, `tests/wp30-internal`,
`tests/wp30-public-surface`, `build/check_wp30_controls.sh`.** Diagnose-and-poison,
**decided under the ADR-029 delegation** (§2b) and implemented through the
existing ADR-019 mechanism rather than a second one. **No public symbol**: the
five verbs and `mount` keep their frozen signatures, registration still returns
void, and the ledger does not move.

**The conflict is the occupied slot**, and that is what makes the WP29 caution
answerable instead of merely noted. A linear scan could only compare pattern
TEXT, so it would have had to decide by hand that `/users/:id` and `/users/:uid`
are one route; the tree does not decide, because both walk to the same node — a
node has ONE parametric child whatever it is called. So the representation
change surfacing conflicts the scan never noticed is **shipped and tested**, not
silent. The same mechanism catches a `mount` prefix composing a pattern that
collides with a directly registered route, with nothing in `mount` comparing
strings for it.

**Decided in implementation, and recorded because the plan required it:
`Framework_Error` gains NO member.** The WP18 fail-closed family —
`mount_poison`, `mount_poison_prefix`, `router_poison_closed` — already poisons
with a static diagnostic and no enum member. The enum names failures that reach
an OBSERVER, and an observer cannot be alive to see this one: the App is already
rejected, `serve` refuses, and every dispatch answers 500 through the guard that
reports `.Use_After_Route` for the whole family. Spending a byte-pinned public
enum member on it would buy nothing and cost a signature amendment. Adding the
member later is an amendment; removing one would be a break — the reversible
arm, as the delegation requires.

**Three mutation controls**, because a diagnostic has two ways to be wrong: the
detection deleted (Phase 1 restored) turns the poison tests red; the detection
**inverted** — every route reads as a conflict — turns the *not*-a-conflict
tests red; and a `mount` that does not stop at the first diagnosis turns the
one-line test red. The second is the one worth having: a suite that only proved
conflicts are caught would stay green against an implementation that rejects
everything.

**One existing test was amended and its reason is in the file.** WP4's
`wp4_allow_has_no_duplicates` built its fixture by registering `/dup` twice, and
its own comment said why that was legal — "definitive conflict diagnostics are
Phase 3 (D5)". This is that answer, so the fixture became illegal; the property
it tested is unchanged and is now reached through two methods on one path.

**Two findings, both predating this work package.** `tests/wp33-public-surface`
shared one file-scope capture variable between two handlers on an eight-thread
runner — a data race that failed at random and did, once, under an unrelated
change; each test now owns its sink. And `docs/ai-context.md` /
`docs/canonical-patterns.md` still stated the Phase-1 answers for the WP31 path
policy and the WP33 parameter bound, both of which shipped without the docs
following; corrected in this change.

### WP31 — Path normalisation policy

**Type: SPEC + IMPLEMENTATION. Requires owner approval — observable HTTP
semantics.**

* Phase 1 normalises **nothing** on purpose: `/users` and `/users/` are
  different patterns, and percent-encoding and dot segments are not decoded.
* **This is a security decision, not an ergonomic one.** Path normalisation is
  where directory-traversal and route-confusion bugs live; every normalisation
  rule is an opportunity for two components to disagree about what a path
  means.
* **The output is a policy or a permanent ratification of its absence** — and
  either way it is written down, tested, and given a negative control.
* **The spec half decides `web.path`'s ENCODING contract too, not only path
  equality.** Whether a captured `:param` view arrives percent-decoded or raw
  is currently stated nowhere, and it is the same security decision wearing a
  different name: a decoded `%2F` inside a parameter is the classic
  route-confusion primitive. 31a states the answer; 31b implements it; the
  answer joins the lifetime ledger's view rules.
* **The negative-control corpus is named now**, so the test cannot be written
  to fit the implementation: dot segments raw and encoded (`/../`,
  `%2e%2e%2f`), an encoded slash (`%2F`) inside a segment, NUL (`%00`),
  doubled slashes, the trailing-slash pair (`/users` vs `/users/`), and
  mixed-case percent escapes (`%2f` vs `%2F`). It lives beside WP9's raw-wire
  corpus and runs against both transports (R-10).
* **Rollback. LOW once a policy ships, HIGH if the absence is ratified.** A
  normalisation rule is observable routing semantics: applications and the
  clients calling them start depending on which paths are equal, and
  withdrawing a rule later re-splits paths that had become one route.
  Ratifying the absence ships nothing and remains fully reversible — an
  asymmetry the decision must weigh, not a reason to pre-empt it here.

**31a DECIDED, owner, 2026-07-20 — `planning/phase-3-spec.md` §1: REJECT, do
not transform.** A dot segment, an interior empty segment, a percent-encoded
slash or a percent-encoded NUL is answered `400` before route matching;
everything else passes through byte-exact and undecoded, as today. Normalising
was rejected as maximising the ways Druse's view of a path can differ from a
proxy's; ratifying the silent absence was rejected because it leaves that
disagreement invisible — a 404 is not a diagnosis. **The trailing slash keeps
its Phase-1 meaning:** it is not an interior empty segment, and `/users/`
remains a legal distinct pattern. 31b implements it after WP29.

**31b DONE, 2026-07-20 — `web/path_policy.odin`, `tests/wp31-public-surface`.**
Four rules, exhaustive: a dot segment, an interior empty segment, a
percent-encoded slash, a percent-encoded NUL. The check sits on the shared
dispatch path BEFORE matching and before the chain, uses the existing
`bad_request` envelope, allocates nothing, and emits no `Framework_Event` —
a rejected path is a client error, like a 404.

**The trailing slash has its own test, because the obvious implementation of the
interior-empty-segment rule breaks it.** `/users/` ends with an empty segment,
and "reject any empty segment" would answer 400 to a legal, distinct Phase-1
pattern. `/users` and `/users/` remain two different paths.

**The other half is tested just as hard:** ordinary percent-encoding is neither
decoded nor refused, `a.txt` and `a..b` are ordinary segments rather than dot
segments, and a trailing slash on an unregistered path is still a 404 and not a
400. A rejection policy that quietly grew would break applications whose paths
were legal the day they were written.

### WP32 — HEAD, OPTIONS, and the 501 decision

**Type: SPEC + IMPLEMENTATION. Requires owner approval — observable HTTP
semantics.**

* **C-1: HEAD is effectively mandatory**, and 501 is a SHOULD that Druse
  currently declines. The vendored backend's HEAD handling is currently held
  under core control by a patch the wire corpus pins (`check_public_api.sh`).
* **The decision to produce:** automatic HEAD (respond as GET, suppress the
  body), automatic OPTIONS (built from the same `Allow` machinery a 405
  already uses), and whether an unknown method becomes 501 or stays outside the
  framework's vocabulary.
* **Interaction to respect:** the `Allow` value and its byte-exact order are
  ratified (WP4 D4) and pinned by the gate. OPTIONS reuses that machinery; it
  does not grow a second one.
* **Rollback. LOW once shipped.** Automatic HEAD and OPTIONS are visible to
  every client and intermediary; caches and health checks will depend on them
  within days of a deployment. Withdrawing either turns a 200 into a 404/405
  for traffic that never appears in a test suite. The 501 decision is the
  reversible part — declining it ships nothing.

**32a DECIDED, owner, 2026-07-20 — `planning/phase-3-spec.md` §2: automatic
HEAD and OPTIONS, no 501, and the `Method` enum does not change.** HEAD matches
as GET with the body suppressed at commit; OPTIONS answers `204` with the
existing `Allow`, and `404` where no route matches. An unrecognised method keeps
`405` with the exact `Allow`, which tells a client what it *can* do where 501
only says the server will not. Since both are resolved before a `Method` value
reaches a handler, the six-member enum stays byte-for-byte as the freeze pins
it: no public symbol, no freeze amendment, none of FINDING-D's concept budget.
**One consequence recorded rather than discovered later:** an application cannot
override OPTIONS through the route table, and the case that will meet that is
CORS preflight. 32b must VERIFY that a middleware can short-circuit the
automatic answer through the single-commit guard — stated as a requirement, not
assumed.

**32b DONE, 2026-07-20 — `web/head_options.odin`, `tests/wp32-internal`.**
HEAD matches as GET with the body suppressed on the way out; OPTIONS answers
`204` with the `Allow` the 405 already builds; an unrecognised method keeps its
405. **The `Method` enum did not change** — both are resolved from the raw token
before a `Method` value exists.

**The suite is INTERNAL, and that is the design showing through:**
`web.test_request` takes a `Method`, and `Method` has no HEAD and no OPTIONS. A
public-surface suite that COULD send either method would be evidence the enum
had grown.

**Suppression happens on the way out, not at commit**, via a driver-side view.
Blanking `response.body` would leak an allocation the Response owns and
`response_destroy` must free — so the handler's body stays intact underneath,
and a test pins that.

**The WP9 conformance matrix had to be amended, and the gate caught it.** Two
scenarios ratified the OLD behaviour — "HEAD is not silently converted to GET
(WP9 D7)" and "OPTIONS gains no early public behavior", both expecting 405.
Those expectations were Phase 1's and are deliberately reversed by the owner's
decision, not accidentally broken. Both rows stay in the matrix, rewritten,
because the property is exactly the kind that must hold identically on both
transports.

**`bare()` answers no OPTIONS**, because it installs no miss policy and
automatic OPTIONS *is* miss policy.

### WP33 — Multi-param routes without a map

**Type: IMPLEMENTATION.**

* Phase 1 supports **at most one** `:param` per pattern; more marks the pattern
  invalid.
* **The convergent design, per C-6:** a small fixed inline array of views in
  request-local storage. Not a map, not an allocation, not a bag.
* **G-03 is the boundary.** This adds capacity to an existing private slot; it
  does not add a general-purpose keyed store, and `web.path` stays the one
  canonical accessor (G-01).
* **Capacity ledger row required:** the new fixed bound joins the "fixed at
  compile time" table, with its behaviour when full stated — like every other
  bound in that table.
* **Rollback.** MEDIUM. No symbol is added, but a pattern that was *invalid*
  becomes *valid*: applications will register two-param routes, and withdrawing
  the capacity silently turns those routes into 404s. Reversible only before
  anyone ships a two-param route.

**WP33 DONE, 2026-07-20 — `tests/wp33-public-surface`.** The bound moved from
one parameter to `ROUTE_PARAM_MAX` (8), using C-6's convergent design: a fixed
inline array of views in request-local storage. Not a map, not an allocation,
not a bag.

**No public symbol.** `web.path` and `web.path_int` keep their exact signatures
and stay the one canonical accessor (G-01). What changed is how many questions
they can answer, not how you ask them. **G-03 held:** this added CAPACITY to an
existing private slot, not a general-purpose keyed store — there is still no
`ctx.params`.

**The capacity ledger has its row**, with the behaviour when full stated as that
ledger requires: a pattern declaring more than eight parameters is invalid at
registration, never matches, and never contributes to an `Allow` value. The same
fail-closed answer WP4 gave to a two-parameter pattern, at a higher bound.

**`web.path` scans rather than hashes.** At eight slots a linear scan beats a
hash, and a per-request map is exactly what C-6's design exists to avoid.

**The radix tree made this cheap**, as WP29 predicted: a second parameter is
another level, not another scan. Values are captured during the descent at each
branch's own index, so a failed branch's write is overwritten by the next branch
at the same depth before anything reads it.

### WP34 — Route identity accessor

**Type: SPEC + IMPLEMENTATION. Requires owner approval — public surface.**

* **C-2: observability is blocked on one missing accessor, and the constraint
  is a MUST.** OpenTelemetry requires `http.route` to be low-cardinality and
  MUST NOT be populated when the framework cannot supply it.
* The framework **already has** the value: `ctx.private.route` is the
  registered pattern, and `Framework_Event.route` already exposes it to
  observers. This work package is the smallest change that lets an
  *application* read it for its own metrics.
* **Public surface (PROPOSED): +1.** The name must not become a second way to
  ask a question `web.header` or the event already answers (G-01).
* **The redaction rule travels with it:** the pattern, never the path. The
  gate assertion that keeps `Framework_Event` free of request-derived strings
  has an obvious analogue here.
* **Rollback. LOW once shipped, like every public symbol.** The accessor is a
  promise kept for as long as the name exists — WP36's asymmetry argument
  applies unchanged. The redaction rule is the half that must never be
  loosened later: pattern-to-path is invisible in a type signature and
  visible in an operator's logs.

**WP34 DONE, 2026-07-20 — `web/route_identity.odin`,
`tests/wp34-public-surface`, Amendment 10 of `planning/phase-1-freeze.md`.**
`route :: proc(ctx: ^Context) -> string`, **+1 symbol, ledger 44 → 45** (union
47). Approved in advance by §2b under the ADR-029 delegation; the amendment
records that authority in those words, because an amendment that cannot say who
authorised it is not evidence.

**The redaction rule became a gate assertion, as the plan required.**
`build/check_public_api.sh` §8b pins the accessor's shape, requires its body to
be exactly `return ctx.private.route`, and requires **every** write to that slot
to be `entry.pattern`. The third is the one that matters: a behavioural test can
only check the routes someone thought to write, while the assertion checks the
assignment where the decision is made. It sits beside the §8 assertion that
keeps `Framework_Event` free of request-derived strings — the pair exists
because one procedure returning the pattern while another quietly returns the
path is exactly how a redaction rule rots.

**G-01 is tested, not asserted in prose.** `web.route(ctx)` and
`Framework_Event.route` must be the same string, and a test fails if they ever
diverge. That is why the name is `route` and not `route_pattern`.

**OQ-18 CLOSED.** It called a public accessor FUTURE with no justifying use
case; the use case arrived with WP20's observer, which gave the identity to an
observer while leaving the application that owns the request unable to obtain
it.

**The six-file ritual, rehearsed once as intended, and it needed a seventh and
an eighth file:** `build/check_public_api.sh`, `build/phase1-public-signatures.txt`,
`build/check_phase1_freeze.sh`, `planning/phase-1-freeze.md`, `docs/ai-context.md`
(+ `docs/canonical-patterns.md`), `CHANGELOG.md` — plus `build/check_docs.sh`
(three count literals) and `tests/wp10-doc-fixtures/fixtures.odin`, because a
new documented fragment needs a compiling fixture and an assertion that the
fragment's own claim holds. WP36 and WP37 should budget for eight.

**A finding on the gate itself, recorded and not silently fixed.** Freeze
evidence citations resolve with `grep -qF`, i.e. by SUBSTRING: the citation
`docs/ai-context.md::web.route` resolved green against the pre-existing text
`web.router()` before `web.route` was documented at all. The citation is real
now, but the check would have accepted a fabricated one. A prefix-shadowed
citation is exactly the "evidence that points at nothing" the check exists to
refuse. Tightening it to a word-boundary match is a one-line change; it is not
made here because it must be validated against all 153 existing citations, and
that belongs to WP38's freeze pass rather than to a symbol amendment.

**A second gate finding, this one fixed here because it BLOCKED the work.**
`build/check_phase2_freeze.sh` compared the Phase-2 freeze document's ledger
diff — `32 | +12 | **44**` — against the LIVE canonical count, and went red the
moment the live count became 45. The check was right for as long as no phase
grew the ledger after Phase 2, which is to say it had never been tested. **44 is
what Phase 2 froze: a historical fact, not a live measurement**, and a freeze
document that must be edited every time a later phase ships is not a freeze. The
check now pins the frozen totals, verifies the table's own arithmetic, and
separately requires the live ledger not to have SHRUNK below them — so a symbol
Phase 2 froze cannot be removed while this document still claims it. WP25's
control 6 was re-aimed at the new sentence and a control **6b** added for the
half a restated-total check misses: a delta edited so the table no longer adds
up. **WP38 must not repeat this shape** — `check_phase3_freeze.sh` records what
Phase 3 freezes, and that number is history the day it is written.

### WP35 — Arena, buffer reuse and oversize policy

**Type: IMPLEMENTATION.** RG-4, risk **R-16**.

* **The risk, stated as measured:** one adversarial request permanently raises
  process RSS across otherwise small traffic. Signals: retained capacity
  follows peak body size; memory does not return near baseline after a giant
  request.
* **The decision:** retain, trim, or release — **with numbers behind it**, and
  the fallback already named in the register (release oversize allocations at
  request end even if common-path buffers stay reusable).
* **This work package activates a Phase-2 test that has been waiting for it.**
  `wp23_public_an_id_never_leaks_into_the_next_request` currently passes
  *structurally* — `Context` is a fresh stack value per request, so the overlay
  starts zeroed and there is nothing to leak. WP35 is the work package that
  makes something be pooled. **That test is the tripwire**, and if it goes red
  here it has done its job; it must not be "fixed" by weakening it.
* **Peak and retained memory are reported, not only allocation counts** — the
  register asks for exactly this.
* **Rollback.** MEDIUM, and it decays. Reverting the reuse policy is a revert
  while the change is purely internal; but once something is pooled, any code
  written against the pooled lifetime — including a generational token, if one
  is introduced — has to come out with it. Keep the reuse and the token in one
  commit so they revert as one.
* **The stale-reference test comes with the reuse, and not before** (P-T7, §6).
  The moment a slot is reused, a reference held from the previous request stops
  being merely stale and starts being *wrong*. The shape of the test is already
  written down: request A arms a timeout; the slot is released; request B
  reuses it; A's timeout fires; **B must survive**. A generational token is the
  known answer. The discipline attached to it matters as much as the mechanism:
  **while nothing is pooled, do not build the abstraction** — an empty
  generational wrapper around storage that is never reused is complexity with no
  defect to catch.

**WP35 DONE, 2026-07-20 — `planning/arena-policy.md`. The decision is to change
NOTHING, and that is the finding rather than an absence of one.**

Measured: a 3 MiB body moved retained memory by ~325 bytes — about 0.01% of the
body — and a SECOND oversize request added no more. Retained capacity does not
follow peak body size, and the residual does not accumulate, which is the
sharper question a single measurement cannot answer.

**Nothing is pooled.** The arena is created lazily per request and destroyed in
`driver_cleanup`; every other request-local buffer is a fixed array on a
`Context` that is a fresh stack value. The register's own fallback — release
oversize allocations at request end — is not a change to make, it is the shipped
behaviour, now measured rather than assumed.

**No generational token was built**, per this work package's own discipline:
while nothing is pooled, do not build the abstraction. The stale-reference test
comes WITH the reuse and not before, and both must land in one commit so they
revert as one.

**The suite is a TRIPWIRE, not documentation of a happy state.** WP36's timeouts
are the likeliest thing to pool something, and if these assertions go red they
have done their job and must not be weakened.

**Named gap:** process RSS was not measured. An allocator that returns memory to
its free list without returning it to the OS satisfies every assertion here and
still raises RSS. That belongs to the allocator, not the framework.

### WP36 — Configurable limits and timeouts

**Type: SPEC + IMPLEMENTATION. Requires owner approval — public surface and a
capacity-ledger amendment.**

* **The shape is already decided** by the P3-8/P3-11 amendment: an options
  struct with a package default constant, on `core:net`'s `DEFAULT_TCP_OPTIONS`
  precedent — **not** a builder.
* **But the derivation must still be MEASURED, not assumed** (P-T6, §6). Compare
  the two shapes on real numbers — configuration consulted per request versus an
  immutable runtime derived once at boot — and report branch count, allocations,
  binary size and ergonomics. The amendment chose the second on reasoning; this
  work package is where that reasoning acquires evidence. And do not expose a
  large tuning struct before there is data to justify each field.
* **Validate once at boot, read on the hot path.** `serve` derives a private,
  immutable `Server_Runtime` holding resolved budgets — request line, header
  block, body, response bytes, timeouts, arena policy — with every cross-limit
  relationship checked once and **diagnosed at boot rather than at 3 a.m. under
  load**. Nothing on the request path re-interprets a limit or discovers a
  contradiction.
* **Keep it the smallest struct HTTP actually needs.** Do not import a general
  system-specification concept from a runtime that sizes shards, pools and
  rings; Druse sizes none of those.
* **FINDING-B applies:** timeouts need a clock on the serving path. That path
  is `web/internal/transport`, which already imports `core:net`, and the
  vendored backend behind it already links `core:time` — a different cost
  question from importing into `web`, and it must be **measured**.
* **FINDING-C applies:** the capacity ledger's "4 MiB, fixed, not configurable
  until Phase 3" row changes **in this commit**, and the claim ledger gains a
  row for whatever new promise the options make.
* **The word "bounded" is still gated.** Configurable limits bound the
  framework's own per-request working memory. They do not bound connections,
  backlog or header counts, and no document may say they do.
* **THIS WORK PACKAGE OWNS THE CONCURRENCY DECISION** (P3-8's other half, which
  an earlier draft of this plan left unassigned). The boot-time snapshot is
  taken here, so this is where it must be recorded whether registration *during
  serving* is **rejected** or **made impossible** — and the choice is written
  down rather than left to whichever happens to be true of the implementation.
  **Name the interaction with what already ships:** ADR-019 and ADR-023 already
  poison an App on `use()` after the first dispatch. A snapshot model either
  subsumes that guard or sits beside it, and the plan must say which; silently
  replacing a shipped fail-closed guarantee is the one outcome not available.
* **`test_request` must honour the same limits, and this work package owns
  that too.** R-10 parity is the property both transports exist to keep: if the
  body limit becomes configurable and the in-memory transport keeps a hard-coded
  4 MiB, then `test_request` answers 200 where a socket answers 413 — on exactly
  the kind of boundary a test suite is supposed to prove. The test-support
  ledger stays at 2; this is behaviour, not a new symbol.
* **Rollback. LOW — this is the least reversible package in the phase.** An
  options struct is a public type: once an application writes a limit, removing
  or renaming a field breaks its build, and *tightening a default* breaks its
  traffic. Ship the smallest struct that HTTP actually needs, because every
  field is a promise kept for as long as the type exists. Adding a field later
  is easy; that asymmetry is the whole argument for starting small.

**WP36 DONE, 2026-07-20 — `web/limits.odin`, `tests/wp36-public-surface`,
`build/check_wp36_controls.sh`, Amendment 12 of `planning/phase-1-freeze.md`.**
**+3 symbols, ledger 47 → 50** (union 52). Options struct + package default
CONSTANT + boot-derived runtime, exactly the §2b shape.

**TIMEOUTS DID NOT SHIP, AND THE STOP RULE IS WHY.** The plan said: prototype
first, and if deadlines need surgery in the vendored server, ship `Limits`
without timeout fields and record the finding. The prototype was conclusive.
`Server_Opts` carries `limit_request_line` and `limit_headers` and **nothing
temporal**; the only `nbio.timeout_poly` uses are a fixed close delay and a
one-second date tick; and the request read in `vendor/odin-http/scanner.odin`
still carries an unfinished-work comment asking for a timeout there. So a read
deadline is work inside the event loop, not a field. Shipping without those
fields is the reversible arm — adding a field later is an amendment, while
shipping one that silently does nothing would be a lie with a version number on
it. **The ADR-029 stop condition was honoured: the finding is recorded rather
than the arm forced.**

**THE MEASUREMENT THE PLAN REQUIRED, and it does not say what the amendment
assumed.** Consumer at `-o:speed`, one POST route binding a JSON body:
`origin/main` 744,744 B; boot-resolved budget 745,216 B; config re-derived per
request **745,216 B — byte-identical**. Zero allocations either way. The shapes
differ only in branch count (0 added versus 3) and in what a contradiction
costs: a per-request derivation can discover one under load, which is the
failure boot-time validation exists to move to boot. **The amendment chose
correctly, for a reason the measurement supports and on a cost basis it does
not.** Recorded that way rather than as a vindication.

**The concurrency decision, as the plan demanded it be written down:** `limits`
after the first dispatch is **REJECTED via the existing poison mechanism**, and
the snapshot model **sits beside ADR-019/ADR-023 rather than replacing them** —
`wp36_the_older_use_after_dispatch_guard_is_untouched` fails if a shipped
fail-closed guarantee is ever silently withdrawn. Order relative to ROUTES is
deliberately unconstrained: a limit protects every route equally, and rejecting
a safe program for resembling an unsafe one would be a worse error than the one
it prevented.

**R-10 is structural, not a coincidence, and control 2 proves it.** The budget
lives on the App and the shared driver copies it onto every request beside the
observer and the state; delete that one line and the configurable-cap tests go
red. If the cap had lived on `serve`, `test_request` would have answered 200
where a socket answers 413 — on exactly the boundary a test suite exists to
prove.

**FINDING-C discharged in this change:** the capacity ledger's body row is
amended and two rows added, and the claim ledger gains C-10 with its own
negative control. The WP35 tripwire stayed green — nothing here pools anything.

**A gate finding, fixed here because it BLOCKED the freeze.** The signature
extractor read procedures, procedure groups and types and **never constants**.
An exported constant is a public symbol whose VALUE is the contract, so
`DEFAULT_LIMITS` was invisible to the snapshot and its value changeable with the
frozen inventory unmoved — the same class of hole the proc-group branch was
written for. Constants are now read from the FULL `odin doc` view, because the
short view renders a struct constant as `Limits{...}` and elides exactly the
values that are the promise. The three numbers behind the names are separately
pinned in `check_public_api.sh`.

**A decision that emerged from the gate, recorded rather than smoothed over.**
The first cut compared directly against `ctx.private.limits.max_body`, and the
WP7 internal suite went red: those tests construct a `Context` by hand, never
through the driver, so their budget was three zeros and every body was
over-limit. The fix was NOT to edit ten test files. A zero budget on the read
path resolves to the default, because turning a framework-internal omission into
an application that refuses all traffic is not failing closed — it is broken.
The public contract is untouched: `web.limits` still refuses a partially-filled
`Limits`, so an application can never choose a zero. **The public API refuses
ambiguity; the read path is defensive.** Control 4 became a PAIR that pins both
halves — forgetful constructor must still serve, forgetful constructor with no
safety net must not.

**The ritual took twelve files.** The ten WP37 measured, plus
`planning/phase-2-freeze.md` — the first Phase-3 package to amend a Phase-2
ledger rather than only the Phase-1 signature freeze — and
`build/check_wp3_mutations.sh`, whose WP7 mutations 32-34 were all written
against the literal `BODY_LIMIT` comparison and had to be re-aimed at the
resolved budget. **WP38 should expect that shape:** a behaviour change ripples
into the mutation suites that pinned the old behaviour, and re-aiming them is
part of the change, not a follow-up.

### WP37 — Typed application state, and the request-scope question

**Type: PROTOTYPE + IMPLEMENTATION. Requires owner approval — public surface.**

**This work package must answer TWO questions that the skeleton plan conflated,
and one of them is currently being answered wrongly in shipped documentation.**

**Question 1 — application state (ADR-004, already accepted).** `web.state(ctx,
T)`: a `rawptr` + `typeid` on the `App`, with an asserted accessor. AMEND-1
applies — registration rejects nil, and access asserts registration plus exact
type before casting. This is for a database handle or configuration: **one
value, app-scoped, set before serving**.

**Question 2 — request-scoped typed state. DECIDED: it does not exist**
(ADR-028, option A, ACCEPTED 2026-07-20 under the ADR-029 delegation). It is a
different feature with a different lifetime, and the project's own research
argued *against* it:

* **C-6** finds that Go's `context.WithValue` and Rust's `http::Extensions`
  exist for type-erased, dynamically-keyed state crossing library boundaries —
  which Druse does not have — and concludes that this **supports G-03 rather
  than challenging it**.
* **G-03** forbids the context extension bag outright.
* The honest consequence is that the canonical auth pattern's revalidation cost
  (WP24) may be **permanent**.

A G-08 correction has already been merged for this: the auth example, the
CHANGELOG and the Phase-2 freeze previously said Phase 3 *would* remove that
cost, which no ADR had decided. They now say the cost stands until an ADR says
otherwise, and `check_examples.sh` rejects a comment that schedules a future
capability.

**ADR-028 decided exactly this** (ACCEPTED, option 1, 2026-07-20 under the
ADR-029 delegation). The three options it weighed:

1. **No request-scoped state, permanently.** Ratify the revalidation cost and
   the pass-it-down workaround as the answer. Costs nothing, closes the
   question, and is what C-6 points at.
2. **A small fixed `[N]{typeid, rawptr}` array in request storage.** C-6's own
   fallback if extensibility is *genuinely* required — bounded, typed at
   access, no map, no allocation. Needs a capacity-ledger row and a very
   clear reason why the existing pattern is insufficient.
3. **A typed slot for exactly one application value**, mirroring the WP19/WP23
   overlay design (one slot, known capacity, one writer ratified per phase).

**Rollback.** Option 1 is HIGH — it ships nothing, so there is nothing to
withdraw, and adding a mechanism later is a pure strengthening. Options 2 and 3
are **LOW**: once an application stores a value per request, removing the slot
breaks it at compile time and no deprecation window helps. That asymmetry is
itself an argument, and it is the reason the recommendation falls where it does.

**ADR-028 accepted option 1** and places the burden of proof for reopening on
the others. The evidence for 2 or 3 must be a real program that cannot be
written cleanly today — never a hypothetical — and option 1 is the only
reversible one: adding a mechanism later is a pure strengthening, while
shipping one and withdrawing it breaks applications.

**WP37 DONE, 2026-07-20 — `web/state.odin`, `tests/wp37-public-surface`,
`examples/07-app-state`, `build/check_wp37_controls.sh`, Amendment 11 of
`planning/phase-1-freeze.md`.** **+2 symbols, ledger 45 → 47** (union 49).
ADR-004 option A only; ADR-028 ships nothing, as decided.

**No back-pointer to the App.** The driver copies the pointer and the `typeid`
onto the Context at the start of the request, exactly as it copies the WP20
observer — one line on the shared pipeline, so both transports behave
identically (R-10) and the WP4 D3 decision stands.

**The `rawptr` ban was enforced, and enforcing it found a hole in the check.**
The exported-declaration extractor treated any declaration line not ending in
`{` as complete, so a MULTI-LINE exported signature was never scanned — a
`rawptr` parameter there would have passed. It now follows a signature to its
closing parenthesis and stops at a procedure's opening brace: a body is
implementation, a signature is surface, which is what G-03 always said in
words. Both halves were positively controlled: a `rawptr` planted in an
exported struct field is caught, and one planted in a multi-line ratified
signature is caught only after the fix.

**Two of the three guarantees are not testable from a test suite, and the
controls say so instead of pretending.** `state` asserts, and a failing assert
ABORTS — a test that could observe one and continue would be evidence the
assert was not an assert. `build/check_wp37_controls.sh` therefore compiles and
RUNS probe programs and reads their exit status.

**Control 3 produced a better result than it was written to expect, and the
finding is recorded.** Deleting only the registration assert does not stop the
abort: an App from `web.app()` has a ZERO `state_type`, which never equals
`typeid_of(T)`, so the typeid assert already catches the unregistered case.
Through the public API the registration assert is **not independently
load-bearing** — it exists for its DIAGNOSTIC, and "you built this with
web.app()" is a far more useful sentence than "the type does not match". With
BOTH asserts removed the program does not quietly succeed either: it dies from
a segmentation fault (139) instead of the assert trap (132). So the asserts do
not turn a crash into a non-crash — **they turn an undiagnosed memory fault
into a diagnosed refusal that names the mistake**, and that is what the control
now pins.

**The ritual took ten files this time**, two more than WP34 predicted:
the eight, plus `build/check_examples.sh` (the AMEND-4 ban list, the example
inventory and the "six examples" count in two scripts) and `README.md`. WP36
should budget for ten.

### WP38 — Phase-3 freeze

**Type: FREEZE. Requires owner approval.**

Everything WP25 required, plus what Phase 3 adds:

* Full ledger diff; signature snapshot refresh; **every** mutation suite re-run
  (Phase 2 ended with ten suites, all passing, each with a positive control).
* **The three ledgers amended, not appended:** the capacity ledger's fixed rows
  become configurable rows (WP36); the lifetime ledger gains any new borrowed
  value (WP33, WP34, WP37); the claim ledger gains a row per new promise **with
  a negative control**, because a claim without one does not freeze.
* **A performance regression benchmark in the gate**, with its tolerance stated
  and justified against FINDING-A's noise floor.
* **The usage laboratory re-run**, and FINDING-D's budget checked: if the
  guarded CRUD number passes 25 concepts, the freeze says so in those words.
* **`nm` measurements with positive controls** for every new "costs nothing
  when unused" claim.

**WP38 DONE, 2026-07-20 — `planning/phase-3-freeze.md`,
`build/check_phase3_freeze.sh`, `build/check_wp38_controls.sh`,
`experiments/11-usage-lab/`.** **PHASE 3 IS FROZEN: 44 → 50 application, union
52.** Approval was the gate's, under the ADR-029 delegation, and every recorded
criterion is met — so nothing stopped for the owner. `check_wp38_controls.sh`
proves that is a fact about the tree rather than about the agent: control 7
pushes the lab program past 25 concepts and the gate refuses it as a reserved
matter.

**The new freeze gate is one lesson older than its predecessor.** It pins Phase
3's totals as HISTORY from the day they are written, checks the document's own
arithmetic, and separately requires the live ledger not to have SHRUNK — which
catches what the Phase-2 gate's live comparison was actually protecting against,
without breaking the first time Phase 4 adds a symbol.

**Re-running every mutation suite found a control that had silently stopped
working, which is the whole argument for the step.** WP18's control 6 removed
`mount`'s append guard and required the fail-closed tests red; it stayed green,
because WP30's conflict detection now rejects the same application for a
different reason. Strengthening the test to assert WHICH failure it caught was
worth doing and was not enough: `mount` has four allocation guards on one path
emitting the same diagnostic, so the append guard is **not independently
observable**. Recorded, and the control re-aimed at the family.

**Two measurements failed, and the freeze says so instead of rounding.** `nm`
is blind here — the four symbols inline away and emit nothing EVEN WHEN USED,
proven by a positive control that read zero. Binary size cannot resolve it
either: the same commit measured twice differed by 4,080 bytes, because output
size quantises at a ~4 KiB page. An earlier draft of the freeze reported
"+4,768 bytes for an application that uses no Phase-3 symbol"; that was
measurement, not cost, and it is recorded as an error caught rather than
deleted. **No Phase-3 symbol carries a "costs nothing when unused" claim.**

**The benchmark shows no regression and the freeze declines to oversell it.**
Every delta sits far inside the tolerance the harness derived on this machine —
13,821 basis points, 138% — which is another way of saying the instrument
cannot tell "unchanged" from "50% slower". What it can still show holds:
dispatch is FLAT, 1,755 ns at 5 routes against 1,727 ns at 5,000. The deltas
are consistently positive and are handed to Phase 4 as a question rather than
waved away.

**The usage laboratory is now an instrument, not a number.** Phase 2 recorded
"14" and "23" without keeping the programs or the counting rule, so this re-run
had to RECONSTRUCT them and could not reproduce 23 exactly — 22 by textual
count, the difference being the `Router` type a program need never name.
Program A reproduces 14 exactly, which is what makes the reconstruction
trustworthy. Both programs and the rule now live in `experiments/11-usage-lab/`
and the gate re-runs them. **The guarded program measures 23 against a ceiling
of 25.**

---

---

## 4. What this plan deliberately does NOT include

* **P3-8 as its own work package.** "Precomputed middleware chains" is already
  what Phase 2 built: `chain_flatten` runs at registration, dispatch re-slices
  an App-owned pool through an index pair, and WP17 measured zero allocations,
  zero bytes, temp allocator untouched. The remaining half of the amendment —
  compiling the final table before serving and rejecting or preventing
  registration during serving — belongs to **WP29** (representation) and
  **WP36** (boot-time derivation), where it can be regression-tested. Listing
  it separately would create a work package whose deliverable already exists.
  **C-7 governs whatever is left:** post-`next` currently costs stack frames,
  not allocations, which is a genuine advantage over koa-compose and Axum's
  `from_fn` — and Phase 3 must not surrender it for a marginal gain.
* **A package-manager story.** C-8: Odin will never officially support one.
  `odin-version.txt` already pins a release, a commit and an asset SHA-256,
  which is stronger than anything surveyed in the ecosystem. Budget one to two
  core-library migrations per year instead.
* **Anything from Phase 4.** Graceful shutdown, trusted proxies and
  `X-Forwarded-*`, TLS, uploads, structured logging, sampling, and a stop
  procedure all stay where they are. If a Phase-3 work package finds it needs
  one of them, that is a finding to write down, not scope to absorb.

---

## 4b. A note on this plan's own review

Eight defects were found reviewing the first draft, and all eight are applied
above rather than left as commentary. Three changed the structure — the spec
halves of WP31/WP32 moved ahead of the shootout, the shootout gained a stopping
rule, and the concurrency decision gained an owner — and one, the shootout's
workload matrix, came from mapping in the Tina dossier (§6).

The rest were precision: the budget now counts concepts rather than symbols,
the benchmark tolerance has a procedure instead of an adjective, and every
implementation package carries **Rollback** again, which the Phase-2 template
had and the first draft of this one silently dropped.

Recorded because the reasoning is the reviewable part, and because a plan that
hides its own corrections teaches the next reader to hide theirs.

A **second review pass** (2026-07-20, later the same day) applied six more, at
the owner's request that this plan be improved rather than merely verified:
rollback statements for the four packages the first pass missed (WP30, WP31,
WP32, WP34 — including the two whose approval halves carry the least
reversible decisions in the phase); the status-distribution rule and the
hardware-identity rule in WP26, without which the regression gate would
manufacture a failure on any new machine — including the CI runner this same
change introduces; the two-instrument split in WP26 (allocation counts and
latency distributions cannot come from the same tool); the named instrument in
WP27; `web.path`'s encoding contract and the named negative-control corpus in
WP31; and the full P-T accounting in §6. Applied in place, recorded here, same
reasoning as before.

---

## 5. Risks this plan does not resolve

| Risk | Why it stays open |
|---|---|
| **R-16 retained giant buffer** | WP35 decides a policy, but the adversarial shape is only as good as the benchmark that models it. A hostile traffic pattern nobody thought to write is not covered by a passing test. |
| **Choosing a representation on a benchmark that flatters it** | WP28 records losing candidates and numbers, which makes a bad choice *visible*. It does not make it impossible. |
| **Timing nondeterminism (FINDING-A)** | Repeated alternating runs reduce it; they do not eliminate it. A 3% difference may never be trustworthy on this toolchain, and the freeze should say so rather than report it. |
| **Concept budget (FINDING-D)** | A budget is a constraint, not a mechanism. Only the freeze's re-run of the usage lab actually measures it, and by then the symbols are shipped. |
| **The request-scope question (WP37)** | **Decided** (ADR-028: option A, the reversible arm). The residual risk is only that real programs keep paying the revalidation cost until evidence reopens it — the cheapest failure mode on this table. |

---

## 6. The Tina dossier — how to use it, and how not to

`tina/` holds a study of **Tina**, a real runtime that was read closely and
written up. Phase 2 already took four things from it, and they were among the
better decisions in that phase: the claim / lifetime / capacity ledgers (docket
D-2), the ownership table, the ApacheBench trap in RG-1, and the warning that
"bounded" must name a perimeter.

**Read it for Phase 3.** It is the densest available source on exactly the
problems this phase has — measurement methodology, bounded pools, backpressure,
slot reuse and compiled configuration — and a second implementation that has
already hit these walls is worth more than a fresh guess.

### The rule, which has not changed

* **Tina is REFERENCE, never architecture to copy.** "Tina does it this way" is
  **never** a justification, in a commit message, an ADR or a code comment.
* **It is not a dependency and must never become one** (R-T2 in the dossier's
  own rejected list).
* Take **discipline** — how a claim is evidenced, how a bound states what it
  does when full, how a benchmark avoids measuring its own error. Do **not**
  take structure. Tina sizes shards, pools and rings; Druse sizes none of
  those, and importing a general system-specification concept would be
  cargo-culting a solution to a problem this framework does not have.
* The dossier says this about its own strongest candidate, and it is the right
  posture: *"Tina não vence por autoridade: seus buckets também fazem scan
  linear."* Its ideas enter the shootout as hypotheses, with no head start.

### `tina/` STAYS OUT OF THE REPOSITORY — owner decision, 2026-07-20

The dossier is **deliberately not versioned and will not be.** It is supplied in
the working environment of whoever is doing the work, out of band, and it is
never committed.

Three consequences, and they are requirements rather than observations:

* **No gate may check for it, ever.** A gate that tests for `tina/` would fail
  on every clean clone and in CI, which is the whole reason this is a decision
  rather than an oversight.
* **No work package may block on it.** If the directory is not there, proceed —
  everything load-bearing has already been absorbed into this plan, the ADRs and
  the gate, which is exactly why §6 lists what was absorbed instead of telling
  you to go and find it again.
* **Nothing may cite it as evidence.** A freeze citation must resolve inside the
  repository; the Phase-1 and Phase-2 evidence matrices are checked that way and
  Phase 3's will be too. Read Tina for ideas, then prove the idea *here*, with a
  test and a negative control that live in this tree.

### Where to look, per work package

Read the mapped document, not the whole folder.

| Work package | Read | What is in there |
|---|---|---|
| **WP26** benchmark | `docs/06-testes-portabilidade-e-maturidade.md`, `docs/11-…roadmap` §P3-1 | The evidence pyramid, test hygiene, and the ApacheBench failure written up in full |
| **WP28** shootout | `docs/09-propostas…` **P-T8**, `docs/11-…roadmap` §P3-2 | Cardinality datasets, and the hit-position / miss / 405 matrix this plan was missing |
| **WP29/WP30** router | `docs/07-catalogo-de-padroes.md` | Pattern catalogue, including the class-bucketed representation |
| **WP35** arena and reuse | `docs/02-memoria-ownership-e-backpressure.md`, **P-T7** | Bounded pools, the "no malloc" claim examined, and the generational-token test for slot reuse |
| **WP36** limits | **P-T6**, `docs/11-…roadmap` §P3-10/P3-11 | Compiled limits versus per-request lookup, and why the options struct stays small |
| **WP37** state | `docs/08-comparacao-com-druse.md` | Where the two designs genuinely diverge |
| **WP38** freeze | `docs/09-propostas…` P-T1/P-T2, `docs/10-limitacoes-e-questoes-abertas.md` | The ledger discipline Phase 2 already adopted, and how the study bounds its own claims |

### Already rejected, and staying rejected

The dossier keeps its own rejected list; these are settled and are not reopened
by reading it again: recovering a panic inside a handler (**R-T1** — ADR-020
proved it impossible), making Tina a dependency (**R-T2**), rewriting the HTTP
server (**R-T3**), and "zero allocation" as a slogan without a perimeter and a
test (**R-T4** — the claim ledger now enforces exactly this).

### Three items this plan has already absorbed

Recorded so nobody re-derives them: **P-T6** is folded into WP36 (measure both
shapes, do not assume the derived runtime), **P-T7** into WP35 (the stale-slot
test arrives *with* the reuse, never before it), and **P-T8** into WP28 (the
workload matrix — it is what exposed the eighth defect in this plan's own
review). **P-T5**, the deterministic transport fault plan, is **not** scheduled
here: it is a hardening lab and belongs with Phase 4, but it is named so the
Phase-4 planner finds it rather than inventing it.

The remaining P-T numbers are accounted for so nobody goes looking: **P-T1,
P-T2 and P-T4** were absorbed by Phase 2 itself (the three ledgers, the
ownership table, and WP18 Amendment 1 plus the single-commit invariant);
**P-T3** lives on as WP9's raw-wire corpus and grows in Phase 4 (P4-16);
**P-T9 and P-T10** are the product track's `druse dev` and `druse doctor`,
deliberately outside every phase.

---

## 6b. External reference programs — same discipline, smaller scale (added 2026-07-20)

Two further external sources were checked for this plan, and the Tina rule of
§6 applies to both, unchanged: **reference, never architecture; never citable
as evidence; never a dependency; absence never a blocker.** Anything taken from
them is proven here, with a test or a measurement that lives in this tree.

### `laytan/odin-http` upstream, and its documentation

https://odin-http.laytan.dev/http/ documents the package whose root server
Druse already vendors at a pinned commit (`vendor/odin-http/VENDOR.md`), so
this is the one external source that is also partly *in* the tree. Two things
are worth knowing for Phase 3:

* **WP36 has an in-tree precedent to read before designing anything:**
  `Server_Opts` with `Default_Server_Opts` (`vendor/odin-http/server.odin`) is
  an options struct with package defaults — the same shape the P3-11 amendment
  chose. Note the difference before taking anything from it: upstream's default
  is a **mutable global variable**, while the precedent this plan names —
  `core:net`'s `DEFAULT_TCP_OPTIONS` — is a constant. Keep the constant; a
  default an application can mutate is a configuration channel nobody
  validates.
* The backend already imports `core:time` and `core:nbio` on the serving path
  (FINDING-B, as stated above): the clock exists there today, and the open cost
  question is about Druse's own packages.

### `arturfil/coffees_odin` — a real application on the same backend

https://github.com/arturfil/coffees_odin is a third-party CRUD service written
against the same odin-http backend: coffees and users, Postgres, JWT auth,
hand-rolled CORS. Its value is as a **specimen** of what a real Odin web
application looks like today, and it touches four Phase-3 questions:

* **WP28 — route cardinality.** It registers **13 routes**. That is context for
  "the cardinalities this project actually targets" in the stopping rule — a
  real application sitting exactly in the 5–50 band — and it is context only,
  never evidence (C-5): Druse's numbers come from Druse's harness.
* **WP37 / ADR-028 — the revalidation pattern, observed in the wild.** Its auth
  middleware validates the JWT and **discards the claims**; its `/auth/me`
  handler then re-validates the same token itself. A real program on this exact
  backend pays the revalidation cost today, does not thread the user down as a
  parameter, and does not work around the repetition. The datapoint is recorded
  in ADR-028 as an observation; it does not move the burden of proof, which
  stays a real program **measured in this tree**.
* **WP32 — OPTIONS demand.** It hand-rolls a CORS middleware that answers
  OPTIONS preflight itself, because the framework layer offers nothing.
  Real-world demand for the automatic-OPTIONS decision, observed rather than
  hypothesised.
* **WP33 — a null result worth keeping.** None of its 13 routes uses more than
  one path parameter. One specimen proves little, but it is one more reason
  WP33 is capacity work rather than urgent demand.

---

## 7. What an implementation agent should read first

1. This document, for the work package it is doing — **including §0**, because
   three of the four findings there contradict the older skeleton, **and §2b**,
   because every approval the §2 table marks is already resolved there
   (ADR-029): no work package waits for a review.
2. `planning/later-phases-plan.md` §Phase 3 — the research gates and the C-1…C-8
   findings, which remain authoritative for the questions they cover.
3. `planning/phase-2-freeze.md` — the three ledgers it will have to amend, and
   the nine claims it must not break.
4. `planning/public-api-guardrails.md` — G-01 through G-11 are not advice.
5. `planning/adrs.md` — an ACCEPTED ADR supersedes plan text when they
   disagree. That is what happened in WP21, and this plan is not exempt.
6. **`tina/` — the mapped document only** (§6), when the environment supplies
   it. Reference, never architecture; "Tina does it this way" is never a
   justification; it is never committed, never cited as evidence, and its
   absence is never a blocker.
7. **The code and tests of the work package before it.** Never conclude from
   documents alone: this project has now had two cases where the documentation
   described behaviour the code did not have, and one of them was introduced by
   the same agent that wrote the gate against it.
