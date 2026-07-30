# Phase 6 freeze — real applications: concurrency, then the data stack

**Status: FROZEN, 2026-07-22, under the ADR-029 delegation.**
**Both halves are green: the concurrency half in this repository at `f51fc127`,
the data half in the Crystals repository. Nothing was left uncommitted and
nothing was left undecided without its reason written down.**

Phase 6 had two halves. The first made the synchronous Handler model safe for
real blocking dependencies. The second delivered a SQL-first data stack, entirely
in the Crystals ecosystem, and proved it with a real application. This document
freezes the first half and records where the second is frozen.

---

## 1. The core ledger

| | Phase 5 froze | Phase 6 adds | Total |
|---|---|---|---|
| application | 62 | +0 | **62** |
| test-support | 2 | 0 | **2** |
| union | 64 | +0 | **64** |

**Phase 6 added no core symbol.** Handler concurrency is a field, not a name:
`Limits.max_handlers` (WP71), on the field-cost precedent set in Phases 4 and 5.
The JSON boundary work (WP67–68) changed behaviour and stable wire codes, not the
public symbol set. No database, migration, validation or checker type entered
`web` — those live in Crystals and depend one-way on this frozen surface.

**One measured base cost:** the default concurrent-serving path adds **+5,472
bytes** to the binary. It is named here rather than hidden; a program that pins
`max_handlers = 1` does not pay the multi-lane path.

---

## 2. What the phase was for

Phase 5 made the first week of an application possible. Phase 6 made the first
**real CRUD service** possible without asking the user to invent an execution
model and a database operations discipline. The thesis, unchanged from the plan:

> Keep handlers synchronous and pleasant, remove the process-wide stall, make
> input failures honest, and provide PostgreSQL without ORM magic, unbounded
> waiting or hidden lifecycle.

---

## 3. The concurrency half (WP66–WP72, this repository)

ADR-030 was reopened for a **liveness** question, not a throughput one: while one
Handler is deliberately blocked in an external dependency, can an independent
health Handler finish before the dependency is released? The answer, measured, is
yes for the multi-lane arm and no for the one-lane arm — enough to reopen the
decision.

The delivered surface is **bounded multi-lane synchronous serving**: several
transport-owned lanes, each invoking ordinary synchronous Handlers, expressed
through the transport-neutral `Limits.max_handlers` setting. Registration stays
single-threaded and closed once serving begins; the route/middleware snapshot is
immutable; framework-owned counters and lifecycle flags are atomic or lane-owned;
request-local memory never migrates between lanes.

The gate (WP72) proved together: unique request IDs under contention; route hit /
404 / 405 / middleware order; registration rejected after serving; concurrent and
repeated stop; `max_drain_time` across every lane; the WP59 use-after-free
regression; CORS, static files and multipart under concurrency; idle keep-alive
at scale; slow clients and writers; one through `lanes − 1` blocked database-like
calls with health live; full-saturation reported as a bounded capacity boundary.

**The honest limitation:** a Handler stuck in non-cancellable foreign code can
outlive the drain deadline. The framework claims bounded blast radius and
fail-fast capacity, not preemption of arbitrary blocking code.

The input boundary (WP67–68) made JSON failures honest: a stable `400` /`500`
taxonomy with `invalid_json`, `invalid_field` (with a bounded field path) and
`unknown_field`, decoded strictly, with no body, type name or source path leaked.

---

## 4. The data half (WP73–WP83, the Crystals repository)

The SQL-first data stack ships entirely as Crystals depending one-way on this
frozen core surface; CE-E3 holds — no Crystal adds, widens or changes a core
symbol. It is frozen in `druse-crystals` at `docs/phase-6-freeze.md`: a
six-package, 125-symbol public ledger delivering PostgreSQL over libpq (bounded
pool, server-confirmed cancellation, explicit transactions, fail-closed
decoding), a fail-closed migration runner that never runs at server boot,
transport-free validation with three-state PATCH and a thin HTTP adapter, an
optional CI query checker that inspects rather than generates, and a real
reference application proving CRUD, constraints, PATCH, pagination, bounded-pool
backpressure, blocked-query health liveness, cancellation and graceful shutdown.

That freeze was verified against this exact core commit, `f51fc127`.

---

## 5. Non-deliveries and refusals

- **Refused by design:** an ORM, Active Record, a DI container, mandatory code
  generation, GraphQL, OpenAPI, WebSocket, HTTP/2, in-process TLS, a general job
  runtime, implicit transactions, production auto-migration.
- **Deferred to a later gated phase:** response streaming and the opt-in
  large-body/spool path (Phase 7); large uploads remain buffered under
  `Limits.max_body`.
- **The unreleased official transport is an exit, not a guess:** no Phase-6 symbol
  names an odin-http type. When `core:net/http` arrives it receives its own
  adapter spike and must pass the same semantic, raw-wire, liveness and shutdown
  corpus before it can replace the current bridge.

---

## 6. Exit contract

Phase 6 freezes because: the JSON matrix is green on the in-memory and real
transport paths; ADR-030 has an evidence-backed verdict; framework-owned state,
stop and every Phase-5 feature pass their fault controls; the Crystals data stack
proves CE-E3 without a core amendment; PostgreSQL execution, pool, cancellation
and transactions pass against a pinned disposable server; the migration tool is
fail-closed and never runs at web-server boot; the reference application
demonstrates the full contract; the core `62 + 2` ledger is frozen literally and
the Crystals public ledger is frozen in its own repository; every limitation and
non-delivery is recorded; and the complete existing Druse gate remains green.
