# Future Research Backlog

Status: **PHASE-OWNED / NON-IMPLEMENTING.** Items below are questions and
disposable evidence tasks. They do not authorize production code or public API.

| Order | Topic | Owner / due | Required evidence | Promotion condition |
|---:|---|---|---|---|
| 1 | Repeated body binding | WP7, before implementation | Pinned-toolchain prototype for success, invalid first bind, empty body, and second bind | ADR-012 decided; tests written first |
| 2 | HTTP/1 framing corpus | WP9 | Same raw corpus against bootstrap and future real adapters | Wire behavior documented per adapter; no core parser ABI |
| 3 | Router layout shootout | Phase-3 Spec Gate | Pointer, indexed, and hybrid layouts on static/param/wildcard workloads; allocations, latency, footprint, build cost | Representation chosen from recorded measurements |
| 4 | Arena oversize/retention | Phase-3 Spec Gate | Normal, burst, and giant-body workloads; peak/retained memory and reset cost | Bypass and retention policy recorded without arbitrary constants |
| 5 | Request-view debug tooling | Phase-3 Test Gate | Pinned `base:sanitizer`, poison/unpoison, immediate reuse and quarantine variants | Limitations and supported platforms documented; zero release hot-path cost |
| 6 | Graceful drain | Phase-4 Spec Gate | Test transport plus one real adapter; slow headers/body/writer, keep-alive, deadline races | ADR candidate defines admission, in-flight, deadline, forced close, once-only cleanup |
| 7 | Trusted proxies | Phase-4 Spec Gate | IPv4/IPv6 CIDR corpus; direct spoofing, multiple proxies, malformed chains | ADR-013 decided before any public configuration |
| 8 | Route-pattern telemetry | Phase-4 Test Gate | 200, random 404, parametrized 405, slow/stuck exporter, bounded queue | One series per pattern; no raw-path fallback; dropped events observable |
| 9 | Multipart ownership | Phase-4 Spec Gate | Memory/file spill, partial writes, disconnect, timeout, disk-full and persist failure | Ownership, cleanup, quotas and error categories ready for ADR |
| 10 | Deterministic shedding | Phase-4 | Fixed in-flight/queue limits under cheap, slow-body and slow-writer workloads | Memory/queues bounded; rejection cheaper than admitted work |
| 11 | Adaptive overload | Future, after item 10 | Binary/scaled signals, hysteresis and recovery measurements | No oscillation; deterministic mode remains independently usable |

## Research invariants

- Every experiment is disposable and isolated from production packages.
- Compiler evidence uses the project-pinned Odin version.
- Benchmarks record hardware, workload, compiler, commit, and allocation data.
- A useful mechanism is not automatically a public API.
- A debug detector is not described as a correctness or security guarantee.
- A feature cannot move earlier merely because an external framework ships it.

## Added after the Phase-1 freeze

| # | Topic | Gate | Method | Success signal |
|---|---|---|---|---|
| 12 | Middleware execution model | Phase-2 prototype WP (ADR-016) | Build onion and pre-order on the bootstrap transport; measure per-request allocations, binary cost and the observable difference when a middleware runs work after `next` | A choice supported by measurement, with the rejected option and its numbers recorded |
| 13 | Lazily-linked default middleware | Phase-2 | `nm` on an app that uses recovery/logger/request-ID versus one that does not, with a positive control, exactly as G-11 was proven | An application that does not use a default links **zero** of its symbols |
| 14 | Deferred inbound header materialisation | Phase-2/3 | Measure the cost of building `[]Header_Pair` per request — which no Phase-1 path can read — against materialising lazily once a header accessor exists | Measured saving, no observable behaviour change |
| 15 | Gate restructuring without weakening it | Phase-2 | Derive the permitted file set from the package rather than listing filenames, while keeping the ledger and signature-snapshot assertions exact; re-run the WP11 mutation probes | Every WP11 mutation still rejected, and a private-parameter rename no longer fails |
| 16 | Route identity for observability | Phase-3/4 | Follow the OpenTelemetry HTTP semantic conventions: metrics must key on the low-cardinality route pattern, never the raw path | Bounded metric cardinality under a path-fuzzing workload |
| 17 | Vendor patch verification by behaviour | Phase-4 | Replace the code-shape greps over vendor sources with assertions that the raw-wire corpus covers each patch's case | A correct re-application of a patch, written differently, still passes |
| 18 | Sync/async application execution | After Phase 6; real trigger in Phase 8 | Run the four-arm program in `sync-async-evaluation.md` across CPU, dependency wait, PostgreSQL, connection scale and mixed workloads | Evidence selects current lanes, bounded job pool, specialised async or a general async runtime |
| 19 | Crystals packaging and compatibility | Phase 6–8 adoption trail | Blank-machine setup, unused-link cost, dependency-direction, removal and multi-core-revision compatibility tests from `architecture-evidence-questions.md` | Current shared repository remains measured best, or a package meets a recorded split trigger |
| 20 | Architecture evidence backlog | Every future spec gate | Promote only triggered question cards from `architecture-evidence-questions.md`, with baseline, arms, controls and tie rule | ADR answers one observable question without turning the backlog into implied scope |
| 21 | Configurable bind & IPv6 (dual-stack) | On real demand only — never earlier (ADR-045) | NOT "can `nbio` bind IPv6" — that is already YES (`core/nbio/impl.odin` derives the family via `family_from_endpoint`; `net.odin` re-exports `IP6_Address`/`IP6_Any`). The open evidence is whether **`IPV6_V6ONLY` can be set at all** on this stack (absent from `core:net.Socket_Option`; `nbio` owns `socket()`→bind() setting only `Reuse_Address`), and whether two independent listeners share the one event loop and the WP95 drain/shutdown lifecycle. Pinned-toolchain prototype, disposable, per the invariants above | A real friction-ledger entry demanding it **and** the `IPV6_V6ONLY`/dual-listener evidence resolved; any public contract then follows ADR-045 — structured address, explicit family, no `.Auto`, no silent fallback |
