# Synchronous versus asynchronous execution — evidence program

**Status:** RESEARCH CONTRACT, 2026-07-22. This document authorizes disposable
experiments, not an async public API. The shipped decision remains bounded
concurrent synchronous Handlers (`planning/phase-6-concurrency.md`).

**Owner direction:** a fully asynchronous Druse is a desirable long-term arm
to evaluate, but is too ambitious to select without a runtime, database and
streaming prototype. Preference is a hypothesis; measurements and ownership
decide.

## 1. Terms, so different mechanisms are not given one name

| Layer | Current Druse | Meaning |
|---|---|---|
| connection I/O | asynchronous/non-blocking | `core:nbio` waits for socket readiness without one Handler/thread per idle connection |
| application Handler | synchronous | one ordinary procedure runs until it returns |
| application concurrency | bounded multi-lane | several synchronous Handlers may run concurrently |
| dependency I/O | normally blocking | libpq, filesystem and most C libraries hold their calling lane |
| streaming | not shipped | Phase 7 owns a specialised long-lived response lifecycle |
| general task runtime | absent | no Future, Promise, async/await, continuation scheduler or implicit worker pool |

The current design already captures one major async benefit: idle keep-alive,
partial request input and slow response readers do not consume a Handler unit.
The remaining question is narrower:

> Is suspending application work while it waits for dependencies worth the
> runtime, ownership and API cost for Druse's measured workloads?

## 2. What is known today

- The route path is flat: the WP29 in-process p50 was about 1.3–1.6 µs from 5
  through 5,000 routes. This is not a socket throughput number.
- The old one-versus-eight-thread experiment reported 1,861 ms versus 1,288 ms
  for 400 requests, but its 31% difference sat inside a 138% noise floor and is
  inconclusive.
- The WP69/WP72 liveness result is decisive but not a speed result: with four
  Handler units, health progresses while one through three are latch-blocked;
  full four-of-four saturation stops Handler progress until release.
- The Phase-4 live laboratory held 6,000 connections at about 4.6 KiB each.
  WP72 drained 3,000 completed idle keep-alives in 557.887815 ms.
- The recorded real-wire load is 800 requests over eight reused connections,
  zero failures. It is not a soak and supplied no trustworthy p99 or req/s.
- Middleware dispatch and route lookup allocate nothing in their frozen
  perimeters. A whole-server allocation/RSS audit is still incomplete.

Therefore the repository does **not** currently support claims that sync is
faster, async is faster, or Druse beats another framework end to end.

## 3. Arms a future shootout must implement

### A — current bounded synchronous lanes

The shipped baseline. Ordinary procedures, blocking dependency calls,
`max_handlers` capacity and fail-fast dependent pools.

### B — event lanes plus bounded job pool

Connection ownership stays on the event lane; blocking dependency work moves
to workers. The prototype must copy request-derived input, return an owned
result and resume response construction on the owning lane. A worker queue is
hard-capped and reports `Full`/timeout.

The canonical form of this arm runs the **whole Handler** on the worker while
the event lane keeps only the connection; a variant that splits the Handler
before/after the dependency is arm C in disguise and is evaluated there.
Phase 7's detached-stream machinery — registry, bounded cross-lane delivery,
owner-lane wakeup — is the natural substrate for this arm and must be reused,
not duplicated.

### C — fully asynchronous application execution

Non-blocking PostgreSQL and outbound I/O register readiness with an executor.
Handlers become state machines/continuations and do not retain a native thread
while waiting. This arm is invalid if a blocking call quietly runs on the event
executor or if it hides an unbounded task queue.

### D — synchronous-looking facade over fibers/coroutines

Application code keeps direct-style procedures while a runtime suspends logical
stacks. This arm must account for stack/frame memory, `defer`, thread-local
context, FFI blocking, scheduler fairness and cancellation; “looks sync” is not
evidence that the runtime is simple.

An arm may be killed before performance measurement if it cannot pass the same
ownership, cancellation, backpressure and shutdown semantics.

## 4. Functional equivalence gate

Every arm must first return byte-equivalent observable results for:

- routing, middleware order and code after `next`;
- strict JSON and error envelopes;
- CORS, static and buffered multipart;
- request IDs, route-pattern telemetry and redaction;
- PostgreSQL execute/query, NULL, typed decode errors and transactions;
- client disconnect before send, while waiting and during response;
- query completion racing cancellation;
- stop during idle, active, queued and suspended work;
- exactly-once cleanup of every request, task, result and connection;
- bounded admission, Handler/task capacity and dependent-pool capacity.

A faster arm that changes work, returns errors, drops cancellation or retains
memory emits no usable performance result.

## 5. Workloads

Run all application-execution arms against the same verified workload set:

1. **Empty Handler:** lower bound for scheduling/dispatch overhead.
2. **Small JSON:** parse, validate and encode with no external wait.
3. **CPU:** deterministic 1, 10 and 100 ms work; proves whether an executor
   supplies real multicore progress rather than only concurrency.
4. **Synthetic wait:** dependency latency 1, 10, 100 and 500 ms, with no server
   CPU, to expose the best async case.
5. **PostgreSQL:** fast indexed query, `pg_sleep`, lock wait, cancellation,
   pool exhaustion and connection loss using the pinned Phase-6 harness.
6. **Outbound HTTP:** fast, delayed, truncated and never-completing upstream.
7. **Connection scale:** 1k, 6k and the largest FD/RSS-valid idle keep-alive
   count; separately, active long-poll/stream counts after Phase 7.
8. **Mixed production shape:** health, JSON CRUD, slow query, static, upload and
   long-lived response together, not in isolated benchmark worlds.

Concurrency sweeps are 1, 4, 16, 32, 128 and then 1k+ only for workloads whose
capacity makes that meaningful. Database concurrency never exceeds the pinned
pool unnoticed; queueing is a reported result, not hidden load.

## 6. Measurements

Every cell records:

- verified success/error/cancellation counts;
- throughput plus p50/p95/p99/max latency;
- CPU time, utilisation per core and scheduler context switches;
- RSS peak/retained, bytes per connection and bytes per suspended operation;
- allocation count/bytes in a named perimeter;
- runnable/queued/suspended work and every capacity rejection;
- database pool wait and active connection distribution;
- fairness: maximum delay of an independent health/control request;
- disconnect cleanup and time to drain/forced termination;
- binary size, build time and public concepts required by the example.

Record compiler commit, core commit, hardware, kernel, build mode, affinity,
warm-up, repetition count, load-generator placement and protocol version.
Use `-o:speed` for product performance and a separate debug/fault run. The load
generator must be shown not to be the bottleneck.

Load is generated **open-loop**: arrivals continue at the configured rate while
the server slows, so coordinated omission cannot hide collapse. A closed-loop
client that waits for each response before sending the next is not acceptable
evidence at or near saturation (amendment, 2026-07-22).

## 7. Decision rule

Before seeing shootout results, the executing WP derives a noise floor on the
target machine and registers a material-improvement threshold above it.

The **expected-win envelope** is pre-registered with that threshold: async can
win materially only where dependency wait ≫ service time, concurrent demand
exceeds the lane cap, and the database pool is not the binding constraint. A
workload that cannot satisfy that conjunction on paper kills the shootout arm
early, by arithmetic, before implementation (amendment, 2026-07-22).

- Correctness, bounds and exactly-once lifecycle are vetoes, not scores.
- If all performance differences lie inside noise, keep the current model.
- If async wins only long-lived streaming, ship the specialised Phase-7 path;
  do not replace ordinary Handlers.
- If a job pool wins blocking dependencies without a second Handler API,
  prefer it over a general async runtime.
- A general async model is eligible only if it materially improves at least one
  Phase-8 real workload, preserves or improves the others, and its user-facing
  concept/lifetime cost passes the usability laboratory.
- A synchronous facade is not preferred merely for syntax; its hidden runtime
  pays the same safety and capacity evidence as an explicit async API.

The tie arm is current bounded synchronous lanes because it is shipped,
understood and reversible through `max_handlers = 1`.

## 8. Questions the final report must answer

- Where is time spent: CPU, database, kernel, scheduler or queues?
- At what dependency latency/concurrency do synchronous lanes saturate?
- Does async reduce tail latency or only admit more queued work?
- How many bytes does one suspended operation retain?
- Can one blocking FFI call stall an async executor, and how is it isolated?
- Does cancellation have one terminal result in every race?
- Can middleware and request views retain their current ownership contract?
- Does the async arm make slow consumers cheaper without creating unbounded
  output queues?
- Does database capacity, rather than Handler capacity, dominate the real app?
- Can a new Odin user debug the winning model from an ordinary stack trace?
- Can the official future HTTP adapter implement the semantics without leaking
  its executor into public signatures?

## 9. Future execution checklist

- [ ] Phase 6 frozen and real PostgreSQL app available.
- [ ] Phase 7 streaming lifecycle frozen or explicitly isolated from the test.
- [ ] Dedicated quiet/paired benchmark environment established.
- [ ] Tier-2 socket harness replaces process-spawning clients.
- [ ] Baseline noise and material threshold pre-registered.
- [ ] Arms A–D either build or carry a recorded early veto.
- [ ] Functional equivalence and mutation controls pass first.
- [ ] Every workload and concurrency sweep runs in alternating order.
- [ ] Whole-process memory and context-switch collection validated.
- [ ] Fault/cancellation/drain matrix runs independently from speed runs.
- [ ] Phase-8 application supplies at least one recorded production-shaped trace.
- [ ] Results, losing arms and non-results are committed.
- [ ] ADR chooses common sync, specialised async, job pool or general async.
- [ ] Public API work begins only after the ADR.
