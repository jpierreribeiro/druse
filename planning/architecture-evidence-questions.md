# Architecture questions that require experiments

**Status:** LIVING EVIDENCE BACKLOG, 2026-07-22. These are questions, not
scheduled features. A row authorizes investigation only when its trigger is
met; it never authorizes public surface by itself.

The project has repeatedly found defects by building instruments before
mechanisms: the router baseline exposed a 594× avoidable scan, the drain lab
found an upstream use-after-free, and the concurrency lab found server-wide
admission had accidentally become lane-local. This document preserves that
method for decisions still ahead.

## 1. Required question format

Every promoted question receives a small spec with:

1. the observable decision, not a preferred implementation;
2. current baseline and the exact claim it does **not** support;
3. at least two arms, including shipped behaviour;
4. semantic equivalence criteria before timing;
5. workload, scale, faults and negative control;
6. measured capacities, ownership and cleanup;
7. environment and noise floor;
8. predeclared kill/tie/promotion rules;
9. losing-arm numbers and non-results;
10. an ADR before public API or dependency changes.

## 2. Execution and scheduling

| Question | Trigger | Required experiment | Decision output |
|---|---|---|---|
| Should ordinary Handlers become async? | Phase-8 trace shows lane wait dominates useful work | `sync-async-evaluation.md` arms A–D | keep sync, add job pool, specialised async or general async |
| Is lane assignment fair under mixed keep-alive traffic? | tail latency or starvation appears with free capacity | pinned clients mapped across lanes; blockers plus reused/new connections | adapter scheduling rule and fairness non-guarantee |
| What should automatic `max_handlers` be? | real app runs on 2, 8, 32+ core machines | CPU/I/O/mixed sweep across capacities, with pool fixed below lanes | revised bounded auto policy or current 4..32 |
| Should CPU-heavy work have a separate bounded executor? | password hashing/rendering delays unrelated requests | direct lanes versus capped CPU pool with cancellation/shutdown | application pattern or optional Service Crystal |
| Can arbitrary blocking FFI be isolated? | a required dependency lacks cancellation | stuck-call laboratory across lane, worker and process isolation | explicit supported topology; never pretend to preempt |

## 3. Transport and long-lived I/O

| Question | Trigger | Required experiment | Decision output |
|---|---|---|---|
| Can official `core:net/http` replace the bridge? | the real package is released | same semantic, raw-wire, 3k drain, liveness and fault corpus on both adapters | adopt, carry both temporarily or reject release |
| Is response streaming contained above the connection backend? | Phase-7 entry | short writes, stale identity, backpressure, disconnect and drain prototype | minimal core stream contract or refusal |
| Are large requests better served by spool or direct streaming? | buffered cap blocks a real use | memory/disk/quota/disconnect shootout | opt-in spool policy and ownership |
| Is WebSocket needed beyond SSE? | a real bidirectional product cannot fit HTTP/SSE | equivalent product slice over SSE and WebSocket, including proxy/drain costs | Crystal, separate package or refusal |
| Does HTTP/2 add product value behind the supported proxy? | measured deployment/protocol need | proxy HTTP/2 versus in-process candidate under real multiplex workload | remain proxy-only or package plan |
| Can outbound HTTP live as a Crystal without a second lifecycle model? | Phase-7 composition half (owner, 2026-07-22) | bounded-pool client over `core:net` with TLS/certificate verification, deadline budget, cancellation and drain corpus; official `core:net/http` client as declared replacement | `http_client` Crystal contract or recorded refusal |

## 4. Data path

| Question | Trigger | Required experiment | Decision output |
|---|---|---|---|
| Should libpq execution become non-blocking? | WP83/Phase 8 shows DB wait consuming lanes | blocking libpq, async libpq and worker arms with identical pool/server | retain sync, specialised async connection or scheduler work |
| Is result buffering bounded enough? | large rowsets appear | single-row mode versus complete `PGresult`, limits, cancellation and decode failure | canonical iteration/buffering policy |
| What pool/lane ratio preserves control progress? | real query distribution exists | fixed DB capacity with pool 1..lanes, health and p99 | capacity guidance, never universal magic default |
| Are prepared statements worth lifecycle cost? | repeated named queries dominate traces | parameter query versus prepared across reconnect/schema change | first-class lifecycle or remain optional/internal |
| Is atomic migration batching worth adding? | self-hosted user needs all-pending atomicity | per-migration versus batch transaction, lock duration and `no_transaction` | explicit policy or keep one-per-migration |
| Is optional SQL checking useful without generation? | WP80 runtime API exists | real app queries, dynamic exclusions, schema drift and diagnostics | WP82 checker or evidence-backed refusal |

## 5. Crystals architecture

### Working hypothesis

The current model is the most balanced option for Druse today:

```text
core repository                 first-party Crystals repository
small mandatory HTTP core  ←──  ordinary optional Odin packages/tools
                               one-way public dependency
```

It is elegant because there is no plugin runtime, registry, discovery hook,
dynamic ABI or extension container. A Crystal is an ordinary package with
explicit construction, ownership and teardown. Native/database/tooling costs
are absent unless imported, and CE-E3 stops optional packages from growing the
core through a back door.

It is not cost-free. With no mature Odin package manager, a second repository
adds checkout/version/collection configuration. A shared Crystals repository
can also couple releases and eventually become a miscellaneous “extras” bin.

### Alternatives that remain testable

| Arm | Benefit | Principal cost |
|---|---|---|
| one first-party Crystals repository (current) | coherent discovery, one compatibility matrix, independent from core | shared cadence and repository growth |
| optional packages inside the core repository | simplest checkout and atomic changes | release coupling, CE-E3 pressure and accidental link/import growth |
| one repository per Crystal | independent ownership, native dependencies and cadence | fragmentation and version/discovery burden |
| runtime plugin/registry system | late discovery/configuration | ABI, hidden lifecycle, dynamic failure and foreign abstraction |
| application-local packages only | zero ecosystem governance | every application reinvents security/lifecycle contracts |

The runtime-plugin arm is rejected unless a real deployment needs late-loaded
code; convenience is not enough to introduce an ABI.

### Crystal tests before ecosystem expansion

- [ ] Blank-machine setup: time and steps to pin core plus Crystals and build an
      example without undocumented environment state.
- [ ] Unused-cost: a Hello World importing no Crystal links no PostgreSQL,
      migration, validation, SSE or tool code.
- [ ] Removal: deleting a Crystal import and explicit lifecycle calls removes
      it without changing core configuration or registries.
- [ ] Compatibility: supported core/Odin commit matrix runs for every released
      Crystal package.
- [ ] Dependency direction: no core import/discovery of Crystals and no Crystal
      access to core internals.
- [ ] Native isolation: libpq/OpenSSL/tool-only dependencies do not affect an
      application that uses only `web/health` or no Crystal.
- [ ] Lifecycle: every Service states create, readiness, capacity, close and
      failure; every Tool remains absent from the server binary unless reused
      deliberately as a Library engine.
- [ ] Discoverability: a human and an AI agent can find the canonical package,
      example, compatibility pin and limitations without repository knowledge.
- [ ] Independent evolution: exercise a Crystal release compatible with two
      core revisions without a core source change.
- [ ] Split trigger: extract a package when native dependencies, licence,
      maintainer, users or release cadence materially differ; do not split by
      aesthetic preference.

### Questions the Crystal report must answer

- Does a Crystal remain an ordinary Odin package, or has it invented a plugin
  protocol?
- Is the capability reusable outside one application?
- Does it need HTTP knowledge? If not, why is it under `web`?
- Can it use only the frozen public core surface?
- Who owns its resources and what happens when capacity is full?
- Is a Tool sharing a transport-free engine, or has deploy machinery entered
  the HTTP process?
- Does the package need its own repository/release, or would that only create
  fragmentation?
- Can an application replace it with its own package without forking core?

## 6. Memory, capacity and overload

| Question | Trigger | Required experiment | Decision output |
|---|---|---|---|
| What is whole-server retained memory? | official adapter or allocator seam exists | hours-long soak, RSS plus allocator/connection/task attribution | honest memory model and leak threshold |
| Does arena retention need size classes/replacement? | Phase-8 body distribution shows retained peaks | normal/burst/giant cycles and reset cost | keep simple arena or bounded retention policy |
| Is deterministic shedding sufficient? | refused capacity causes unstable recovery | fixed limits versus adaptive controller with hysteresis | retain deterministic or optional adaptive policy |
| Which queue is first to saturate? | real app has lanes, DB, stream and spool queues | mixed overload with every queue metric | ordering and capacity-planning guidance |

## 7. Safety, lifecycle and observability

| Question | Trigger | Required experiment | Decision output |
|---|---|---|---|
| Can shutdown bound every framework-owned operation? | each new async/stream/tool lifecycle | stop at every state transition plus stale completion | state machine, deadline and non-guarantee |
| Is process-abort still the right handler-fault policy? | Odin gains supported recovery or real product evidence demands isolation | abort, process worker and any supported recovery mechanism | preserve supervisor model or new ADR |
| Are redacted metrics sufficient to diagnose production failure? | Phase-8 incident cannot be explained | incident replay with current events/counters and no request-derived bytes | smallest safe observability amendment |
| Which defaults remain safe across platforms? | macOS/Windows/other arch support begins | complete conformance, fault, descriptor and timing corpus | support matrix and platform-specific limits |
| Is a scrapeable metrics exposition needed beyond observer hooks? | Phase-7 composition half (owner, 2026-07-22) | Prometheus text exposition as a Crystal over existing hooks, redaction rules preserved | `metrics` Crystal or documented per-app pattern |
| Can one request deadline budget propagate to dependencies? | the `http_client` Crystal exists | request deadline → pool wait → query → outbound call budget laboratory, including cancellation races | deadline-budget contract or per-dependency documented limits |

## 8. Developer experience and Odin fit

| Question | Trigger | Required experiment | Decision output |
|---|---|---|---|
| Is the project still a microframework? | Phase 8 complete | three real programs, concept count, dependency/link inspection | keep or change positioning honestly |
| Can newcomers implement common changes from docs alone? | each phase freeze | blinded human/AI tasks using only public docs and examples | docs/API correction, not hidden guidance |
| Has an abstraction become foreign to Odin? | futures, annotations, codegen, plugin ABI or reflection proposed | side-by-side application code, failure diagnostics and ownership map | accept only if measured value pays concept cost |
| Is there still one canonical path? | aliases/convenience helpers accumulate | API inventory plus real app call-site audit | remove/deprecate duplicates or justify distinct semantics |

## 9. Promotion checklist

- [ ] Trigger is real and linked to evidence, not framework comparison envy.
- [ ] Baseline is shipped code, not a faster/slower reimplementation.
- [ ] Question and thresholds are written before the result.
- [ ] Controls can produce the failure under study.
- [ ] Performance candidates do byte-equivalent work.
- [ ] Every capacity and queue has a full policy.
- [ ] Ownership during failure/cancellation is enumerated.
- [ ] Result distinguishes “not observed” from “impossible”.
- [ ] A non-result inside noise is recorded as inconclusive.
- [ ] The simplest/tie arm is named in advance.
- [ ] ADR and ledgers change before production API.
- [ ] Experiment remains disposable and is never imported by `web`.
