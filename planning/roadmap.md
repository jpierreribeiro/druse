# Druse roadmap — Phases 2 to 8 and the release track

Living document. Written after the Phase-1 freeze (`a7d2e9e`) from the evidence
in [`post-phase1-audit.md`](post-phase1-audit.md) and
[`odin-fit-audit.md`](odin-fit-audit.md).

Detail remains **proportional to distance**. Phases 1–5 are complete and
frozen. The next executable program is mapped by
[`phases-6-8-program.md`](phases-6-8-program.md): Phase 6 has a normative spec
and hand-off plan; Phases 7 and 8 have deliberately revisable plans whose first
WP must refresh them against the preceding freeze. No future signature is
frozen merely because the program names a capability.

## Where the project is

*(Updated 2026-07-21, after the Phase-5 freeze.)*

Phases 1–5 are complete and frozen at `6b6edbc`: **62 application symbols + 2
test-support symbols**. Druse now has indexed routing, middleware, typed
application state, configurable limits, production lifecycle, proxy-aware
operation, deadlines, observability, drain, CORS, static files and bounded
in-memory multipart. The full gate protects public signatures, claims,
lifetimes, capacities, raw-wire behaviour and mutation controls. Large uploads
still cannot exceed the buffered request-body model; Phase 7 now owns the
opt-in spool/stream solution. No release has been made.

## What each phase is for, in plain terms

| Phase | The user-visible promise | Why it exists |
|---|---|---|
| **2 — Composition** | "I can share behaviour across routes: auth, logging, request IDs, and I can group routes under a prefix." | Today every handler repeats itself. There is no way to require authentication once, or to log every request, without copying code into each handler. |
| **3 — Performance core** | "It stays fast as my route table and traffic grow, and I can tune the limits." | The route table is a linear scan and every limit is fixed. Neither is wrong today; both stop being fine at scale. |
| **4 — Production** | "I can run this facing real traffic: shut it down cleanly, sit behind a proxy, bound its resources, and see what it is doing." | Today there is no way to stop the server, no timeouts, no proxy handling, and no observability. This is the phase that makes deployment defensible. |
| **5 — Table stakes** | "Deploys drain, and my first app has CORS, static files and bounded multipart." | The original demand gate was circular at zero users; the owner rescoped the phase and each symbol still paid G-09. |
| **6 — Real applications** | "I can write a conventional PostgreSQL service with synchronous handlers, honest input errors and safe deploy migrations." | Ordinary blocking dependencies currently stall the single lane, and the data lifecycle has no accepted contract. |
| **7 — Streaming foundation** | "I can push bounded incremental responses and receive large bodies without RAM proportional to body size." | Incremental responses and large uploads require lifecycle, backpressure, partial-write and spool ownership that buffered request/response cannot express. |
| **8 — Proof by use** | "The framework has survived a real multi-user product, repeated evolution, deploys and faults using only public APIs." | Examples prove syntax; a separately deployed system proves composition, operations and Joy of Programming. |

## Sequencing, and why this order

```
Phase 1 (frozen)
   │
   ├── C-1  licence + product files      ─┐ small corrective PRs,
   ├── C-2  stale-comment correction     ─┘ before Phase 2 starts
   │
Phase 2 — Composition
   │   debt first: gate restructuring, test-support body, commit invariant
   │   then: middleware prototype (onion decision) → chain → groups → defaults
   │
Phase 3 — Performance core            requires Phase 2's chains to exist
   │   research gate (benchmarks) → router representation → limits/timeouts
   │
Phase 4 — Production                  requires Phase 3's limits and timeouts
   │   lifecycle/shutdown → proxies → observability → hardening
   │
Phase 5 — table stakes               drain + CORS + static + bounded multipart
   │
Phase 6 — real applications          JSON + bounded lanes + data Crystals
   │
Phase 7 — streaming foundation       response streams + large-body spool
   │
Phase 8 — proof by use               separate real system, evolved and faulted
```

Three dependencies are hard and worth stating:

* **Phase 3 cannot precede Phase 2.** Precomputed middleware chains are a
  Phase-3 optimisation target, and they cannot be optimised before they exist.
* **Phase 4 cannot precede Phase 3.** Graceful shutdown with a deadline is
  meaningless without timeouts, and load shedding is meaningless without limits.
* **Phase 2 cannot start on middleware.** Three items of Phase-1 debt sit
  directly underneath it (audit §5): a gate that punishes adding files, a test
  facility that cannot send a body, and a response-commit invariant held together
  by hand-written guards that a new responder would break.

## Value, risk and effort

Relative, not absolute. "Effort" is measured in work packages, since a WP is
sized to be reviewable by one person.

| Phase | Value to users | Risk | Effort | Biggest risk in one line |
|---|---|---|---|---|
| C-1/C-2 corrections | **High** (unblocks any use at all) | Low | 2 small PRs | none; the licence is an owner decision |
| **Phase 2** | **High** | **Medium-High** | ~12 WPs | onion middleware is a foreign abstraction risk; prototype before committing |
| **Phase 3** | Medium | Medium | ~10 WPs | choosing a router representation before measuring |
| **Phase 4** | **High** for anyone deploying | **High** | ~14 WPs | security surface: proxies, limits, uploads, TLS |
| **Phase 5** | Low per item, high in aggregate | Low | per-item | scope creep — everything wants to be in core |
| **Phase 6** | **High** | **High** | 19 WPs | concurrency safety and database lifecycle must compose without entering `web` |
| **Phase 7** | **High** | **Very high** | 17 WPs | partial I/O, stale identity, backpressure and spool cleanup are one lifecycle |
| **Phase 8** | **High evidence value** | Medium | 12 WPs | a demo can look real while avoiding evolution and operational failure |

Phase 2 carries more risk than its size suggests, because it is where the API
shape for everything after it gets set. Phase 4 carries the most absolute risk,
because it is where mistakes become remotely exploitable rather than merely
inconvenient.

## Entry and exit criteria

A phase may not start until its entry criteria hold, and may not be declared
complete until its exit criteria are gate-verified — the same discipline WP11
applied to Phase 1.

### Phase 2 — Composition

**Entry:** Phase 1 frozen and merged ✅; the independent verifier green on the
merged commit; C-1 and C-2 landed.
**Exit:** the onion-vs-pre-order decision is recorded as an accepted ADR with a
prototype behind it; middleware ordering, short-circuit and unwind are
behaviour-tested; recovery/logger/request-ID cost **zero bytes** in an app that
does not use them, proven by `nm` as G-11 was; the Phase-2 ledger is frozen with
per-symbol evidence; documentation parity holds; full gate green with no skips.

### Phase 3 — Performance core

**Entry:** Phase 2 frozen; a benchmark harness exists with recorded hardware,
warm-up, route distribution, concurrency and p50/p95/p99 methodology.
**Exit:** the router representation is chosen **from measurements**, not
preference, with the losing candidates recorded; observable routing behaviour is
byte-identical to Phase 1 for every existing test; configurable limits and
timeouts exist with an options struct and a package default constant; a
regression benchmark runs in the gate.

### Phase 4 — Production

**Entry:** Phase 3 frozen; limits and timeouts exist.
**Exit:** shutdown with an absolute deadline, admission stop and exactly-once
cleanup, all tested; per-server state replaces the transport globals (audit
A-4); trusted-proxy handling with ADR-013 accepted; fuzzing and a soak test in
CI; observability using **low-cardinality route identity**, never raw paths;
an operations document.

### Phase 5 — Close the drain, ship the table stakes

**Rescoped 2026-07-21** by owner amendment (`phase-5-spec.md` §1). The original
scope — *Ecosystem*, gated on "a real user request for each item" — could not be
satisfied: the project has no users, and it will not acquire any until it has the
pieces that demand would have asked for. The criterion is kept for everything
except the three items named below.

**Entry:** Phase 4 frozen.
**Exit:** `web.stop` terminates within a declared deadline with connections held
open by a client, or the field is not shipped and the reason is recorded; static
files, CORS and uploads exist in the core, each paying G-09 in full; every gap
that remains is named in `docs/operations.md` with its reason; nothing in `web/`
has learned anything about the backend, so the January 2027 `core:net/http`
transition stays as cheap as the boundary was designed to make it.

**Still ecosystem, still demand-driven:** TLS in-process, OpenAPI, WebSocket,
streaming, HTTP/2, templates, database integration. The waiver names three items
and no others.

### Phase 6 — Real applications

**Owner amendment 2026-07-21:** the demand wait is waived for the bounded
“first real application” class, recorded in ADR-035. The full evidence burden
remains. Normative gate: [`phase-6-spec.md`](phase-6-spec.md). Execution plan:
[`phase-6-plan.md`](phase-6-plan.md).

**Entry:** Phase 5 frozen at `6b6edbc`, ledger 62 + 2; owner amendments and
pre-registered thresholds recorded by WP66.

**Exit:** request-decoding failures are classified honestly; ADR-030 has a
liveness-based verdict; synchronous blocking dependencies have bounded blast
radius or the concurrency surface is refused; PostgreSQL, transactions,
migrations and validation live outside `web` with bounded capacity and typed
failures; a real reference application proves CRUD, cancellation, migrations,
shutdown and health progress; all new ledgers and non-deliveries are frozen.

### Phase 7 — Streaming foundation

**Planned, not signature-frozen.** Response streaming and large-body ingestion
are one bidirectional lifecycle problem with two different public paths. The
ordinary buffered `web.body`/multipart path remains the simple default; an
opt-in bounded spool path supports bodies larger than memory limits. SSE
remains an ecosystem consumer of the smallest core primitive.

**Entry:** Phase 6 frozen; WP85 refreshes every threshold and ADR against its
actual output. **Exit:** detached response ownership, partial-write security,
bounded backpressure, safe multipart spool, drain, proxy interoperability and
the large-transfer vertical proof all pass without backend types escaping.

### Phase 8 — Proof by use

**Planned, separate repository.** Build and operate one collaborative
multi-user product using only public, pinned contracts. Repeated migrations,
deploys, reconnects, concurrency, large attachments, fault drills and a human/
agent usability study become the evidence for future API improvements and any
1.0 discussion.

## Release and adoption track

This runs alongside the phases, not after them. A framework nobody may legally
use is not a framework.

| Milestone | Contents | Gate |
|---|---|---|
| **M0 — usable by others** (before Phase 2) | `LICENSE`, `SECURITY.md` + reporting channel, `CONTRIBUTING.md`, `CHANGELOG.md` | ✅ done — all four files exist; MIT chosen by the owner |
| **M1 — Phase 2 shipped** | middleware, groups, header lookup; docs and examples updated | Phase-2 exit criteria |
| **M2 — honest preview** | supported-Odin-version policy; platform support stated honestly (only Linux x86-64 is tested today); upgrade guide | policy documented, not implied |
| **M3 — Phase 4 shipped** | operations doc, security policy exercised, soak/fuzz results | Phase-4 exit criteria |
| **M4 — external users** | full CRUD example, a Postgres example, beginner documentation, cookbook | examples compile in the gate |
| **M5 — 1.0 candidate** | user study (`odin-fit-audit.md` §13) run and acted on; `planning/`, `experiments/` and the knowledge base retired from the public tree per the local cleanup plan | study completed; tree matches the target layout |

**Versioning stays a human decision.** Odin has no official package manager by
design, so consumption is by vendoring or submodule and the pinned toolchain
version is part of the contract. No tag should be cut before M2 at the earliest,
and 1.0 should not be cut before the user study in M5.

## Governing rules for all future phases

Carried forward from Phase 1 because they are why Phase 1 stayed small:

1. **The 32+2 freeze is not an allowance to grow freely.** Every phase declares
   its own ledger, and every new symbol carries owner, use case, binary cost,
   dependencies, an example, a behaviour test, ownership and a rollback path.
2. **No aliases, no second canonical way.** This is Odin's own stated rule.
3. **Defaults must be lazily linked** — an application that does not use a
   feature pays zero bytes for it, proven by `nm`, as G-11 established.
4. **Optional means optional** — for the things that are genuinely optional.
   TLS, OpenAPI and WebSocket are candidates for separate packages,
   not automatic core growth. **Amended 2026-07-21:** uploads, static files and CORS were
   on this list and are not any more. They are table stakes, not options: a
   microframework missing all three is a routing library. They land in the core
   in Phase 5, paying G-09 in full. The amendment names three items; the rule is
   unchanged for every other. **Further owner amendment:** Phase 6's
   first-real-application class and Phase 7's minimal streaming/body primitives
   have their own explicit spec gates. PostgreSQL and SSE remain Crystals;
   only semantics that a transport/core alone can own may enter `web`.
5. **Measurements decide performance questions**, not preference — and the
   losing options get recorded.
6. **Decisions are made under the ADR-029 delegation (owner, 2026-07-20).**
   The executing agent decides PROPOSED matters and work-package approvals,
   records each with its grounds, and takes the most reversible arm when
   evidence does not clearly favour another. The mission — *A web framework
   for the Joy of Programming* — is the tie-breaker, below discipline and
   above convenience. Reserved matters still stop for the owner: releases,
   tags and versions; `LICENSE`; the mission itself; Tina as a dependency or
   in the tree; rewriting published history. ADR-010, ADR-013 and ADR-028
   were accepted under this delegation on 2026-07-20; the plain-language
   record is [`decisoes-do-dono.md`](decisoes-do-dono.md).
