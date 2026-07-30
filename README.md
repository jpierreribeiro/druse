# Druse

*A web framework for the Joy of Programming.*

An Odin microframework for real-world JSON APIs.

**Simple by default, explicit when needed, data-oriented underneath.**

**Positioning:** internally data-oriented and allocator-aware; externally simple,
productive, and predictable — for humans and for AI coding agents. No code
generator, no mandatory CLI, no heavy metaprogramming: ergonomics come from
extractors and canonical helpers.

Druse is built on three equally important commitments:

```text
Performance
    + memory correctness
    + predictable hot path

Productivity
    + safe defaults
    + simple CRUD
    + few mandatory concepts

AI readability
    + canonical API
    + compiling examples
    + no aliases, no magic
```

The target experience:

<!-- fragment: phase1/readme-taste -->
```odin
package main

import web "druse:web"

User :: struct {
	id:   int    `json:"id"`,
	name: string `json:"name"`,
}

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	web.get(&app, "/users/:id", get_user)

	web.serve(&app, 8080)
}

get_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}

	web.ok(ctx, User{id = id, name = "Jean"})
}
```

## Minimal HTTP benchmark

This is a deliberately narrow transport benchmark, not a claim that a
four-byte response represents a complete application. Each server returned
`200`, a four-byte `pong` body, and `text/plain; charset=utf-8` over HTTP/1.1
keep-alive.

AWS c5.2xlarge (8 vCPU), Linux 6.17; server pinned to CPUs 0–3 and
`wrk -t4` pinned to CPUs 4–7. Peer values are the median of three consecutive
10-second runs; the corrected Druse default is a five-run median. Druse used Odin
`dev-2026-07-nightly:819fdc7`, `-o:speed`, four Handler lanes, and the
default dedicated-accept path.

| framework/runtime | c100 req/s | c100 p99 | c400 req/s | c400 p99 |
|---|---:|---:|---:|---:|
| fasthttp 1.72 / Go 1.26.5 | 282,625 | 1.12 ms | 292,457 | 2.59 ms |
| **Druse / Odin** | **259,233** | **0.646 ms** | **282,426** | **2.38 ms** |
| Axum 0.8.9 / Rust 1.97.1 | 250,214 | 0.706 ms | 269,230 | 2.69 ms |
| Go `net/http` 1.26.5 | 151,226 | 2.54 ms | 150,419 | 7.98 ms |
| Gin 1.12 / Go 1.26.5 | 148,958 | 2.69 ms | 149,931 | 8.49 ms |
| Fastify 5.10 / Node 26.5 | 122,769 | 2.00 ms | 123,183 | 3.85 ms |

In this workload Druse delivered 91.7% of fasthttp at c100 and 96.6% at
c400, while its measured p99 was lower. The build command, raw methodology,
syscall count, fault evidence, and limitations are in the
[dedicated-accept report](docs/reports/2026-07-25-dedicated-accept-throughput.md);
the Druse application is in
[`bench/framework_ping`](bench/framework_ping/README.md).

**Reproducibility, stated plainly.** Only the Druse server of this table is
committed. `bench/framework_ping/` holds no fasthttp, Axum, `net/http`, Gin or
Fastify `/ping` peer, no orchestration script pins each peer's worker count or
CPU affinity, and no raw `wrk` output is kept — nothing in the repository
invokes `wrk` at all. The peer numbers above therefore cannot be regenerated
from this checkout, and their toolchain versions do not match the lockfiles that
back the application matrix (`bench/application_matrix/`, which pins Fastify
5.8.5 / Node 25.1.0 / Go 1.26.1). Two further caveats belong with the latency
column: the peer medians are over three runs against Druse's five, with no
variance reported, and every figure is closed-loop `wrk` at each server's own
attained throughput — `--latency` prints a histogram, it does not correct for
coordinated omission, so these p99s mix service time with queueing and are not
an equal-offered-rate comparison. Treat the table as a recorded observation on
one box, not as a reproducible result, until the peers and an orchestrator are
committed.

What this table does **not** measure: JSON encode/decode, routing-heavy
applications, middleware chains, request bodies, streaming throughput, TLS,
connection churn, memory per connection, or application/database work. Use it
as evidence about the minimum HTTP transport path, not as a universal framework
ranking.

No allocator configuration, no transport selection, no manual context assembly.
The systems-level machinery exists — it lives behind the API, available through
an explicit advanced surface when needed.

## Transport direction

The future Odin `core:net/http` (expected to build on `core:nbio`) is the
desired canonical transport backend if and when its real API is available and
validated. Druse initially uses `laytan/odin-http` strictly behind an
internal adapter. No public Druse API exposes transport types, so migration
is confined to the adapter and conformance work; its difficulty is not assumed.

## Repository layout

```text
knowledge-base/          Normative specification (read these first)
├── 01-architecture-spec.md
├── 02-odin-idioms-guidelines.md
├── 03-development-phases.md
└── 04-local-agent-system-prompt.txt

docs/                    User- and agent-facing documentation
├── quick-start.md          Start here
├── canonical-patterns.md   The one blessed way to do each common task
├── ai-context.md           Compact API reference for coding agents
├── errors.md               The error envelope and every error code
├── middleware.md           The onion, its ordering rule, and its costs
└── transport-conformance.md  How transports are proven correct

examples/                Compiling programs (all built by the gate)
├── 01-hello-world/
├── 02-json-api/
├── 03-route-params/
├── 04-middleware/
├── 05-route-groups/
├── 06-authentication/
└── 07-app-state/
```

## Status

**Released: `v0.10.0`** — a pre-1.0 public release, no longer marked a pilot.
Two controlled pilots came before it, `v0.9.0-pilot` and `v0.9.1-pilot`. What
each release earned, and the one gap in its evidence, is recorded in
[`planning/release-readiness.md`](planning/release-readiness.md); notable
changes are in [`CHANGELOG.md`](CHANGELOG.md).

Phases 1 through 7 are complete and frozen, and Phase 8 — proof by use — has a
final verdict. Implementation finished, public contracts frozen behind a gate.
What "frozen" means, symbol by symbol and with the
evidence behind each one, is recorded in
[`planning/phase-1-freeze.md`](planning/phase-1-freeze.md),
[`planning/phase-2-freeze.md`](planning/phase-2-freeze.md) and
[`planning/phase-3-freeze.md`](planning/phase-3-freeze.md) — the Phase-2 freeze
covers not only the API but the project's claims, lifetimes and capacities, and
the Phase-3 freeze **amends** those three ledgers rather than appending to them.

**Phase 3 replaced the router wholesale and cost six public symbols.** Nine of
its work packages — the benchmark harness, the allocation audit, the
representation shootout, the radix index, registration conflict diagnostics, the
path policy, automatic HEAD and OPTIONS, multi-parameter routes and the arena
decision — shipped **zero public surface between them**. At 5,000 routes,
dispatch went from 883 µs to about 1.7 µs and is now **flat**: it costs the same
at 5 routes as at 5,000. The six symbols are `route`, `app_with_state`, `state`,
`Limits`, `DEFAULT_LIMITS` and `limits`.

**Phase 4 (production) shipped five symbols and closed two of the three
deficiencies it opened with.** Read/write request deadlines (slowloris was a
real, demonstrated hole), bounded admission with a shutdown reservation, `stop`,
trusted proxies, security headers and an observable drop policy — most of them
as FIELDS on a struct that already existed, which is why five names covered
seven capabilities. `planning/phase-4-freeze.md` records it, including what was
NOT delivered and why.

**It also fixed a defect nobody was looking for: keep-alive was broken for every
GET.** One upstream line meant every request paid a TCP handshake, with no
`Connection: close` advertised, so no client could know. The corpus proved that
a *bad* request retires a connection; nothing proved that a *good* one preserves
it.

**Phase 5 shipped the ordinary first-week surface:** CORS, secure static files,
buffered multipart forms and an absolute graceful-drain deadline. It also fixed
an upstream pending-read use-after-free found by the drain laboratory. The
freeze is [`planning/phase-5-freeze.md`](planning/phase-5-freeze.md).

**Phase 6 made conventional synchronous application I/O safe** through bounded
Handler concurrency, and built the SQL-first PostgreSQL and migration ecosystem
outside `web` — in the Crystals repository, where its half is frozen. The core
half added no public symbol. The freeze is
[`planning/phase-6-freeze.md`](planning/phase-6-freeze.md).

**Phase 7 shipped two orthogonal contracts, never one magic stream:** detached
response streaming as a public API, and an opt-in large-body path whose
bounded-memory substrate is built and tested but whose public upload API was
deferred and then delivered separately. It cost five symbols. The freeze is
[`planning/phase-7-freeze.md`](planning/phase-7-freeze.md), which also names
what did not ship.

**Phase 8 was proof by use, and it found eight things.** A real multi-user
application, built and deployed from outside the library, produced friction
findings F8-1 through F8-8; the Corrective Program C1–C7 resolved every one,
each verified running against real PostgreSQL and real clients rather than in a
test. The verdict is [`planning/phase-8-verdict.md`](planning/phase-8-verdict.md)
and the findings are in
[`planning/phase-8-friction-ledger.md`](planning/phase-8-friction-ledger.md).

**Phase 9 measured performance instead of claiming it**, on a dedicated 8-vCPU
box: the framework competes with fasthttp on throughput and wins on latency, and
the investigation is recorded — including the reproducibility problems in the
table above — in
[`planning/perf-netpoller-study-and-architecture.md`](planning/perf-netpoller-study-and-architecture.md).

The current synchronous-Handler decision is not treated as the last possible
runtime. Its four-arm future evaluation, workloads and decision checklist are
recorded in [`planning/sync-async-evaluation.md`](planning/sync-async-evaluation.md).
Broader questions that require real experiments — including when Crystals stay
elegant or should split — live in
[`planning/architecture-evidence-questions.md`](planning/architecture-evidence-questions.md).

**Before deploying, read [`docs/operations.md`](docs/operations.md)** — in
particular what the framework does and does not bound.

**What works today**

- A real HTTP server: `web.serve(&app, port)` binds a port and answers.
- Routing with static and `:param` segments; static routes win over
  parametric ones.
- Middleware with `web.use` — onion model, so code after `web.next` sees the
  response. Route groups under a prefix with `Router` and `mount`, and
  route-level middleware on the five verbs.
- Request header lookup (`web.header`, `web.bearer_token`) returning views,
  and correlation IDs (`web.request_id`) with a tested trust policy.
- One log line per request (`web.logger`) and a typed framework-error
  observer (`web.observe`) — each costs zero bytes in an application that
  does not use it, proven by `nm` in the gate.
- Path and query extractors that respond with a standardized `400` on bad
  input, so handlers only check a bool and return.
- JSON request bodies (`web.body`) with a fixed 4 MiB cap, decoded into a
  value you own.
- JSON, text and no-content responses, and the five error responders.
- Standardized error envelopes, including the automatic `404` and the `405`
  with an exact `Allow` header.
- Middleware: `web.use` and `web.next`, an onion that unwinds in exact reverse
  order and allocates nothing through the chain. Registration order is
  *enforced*, not documented — `use` after a route rejects the whole
  application and `serve` refuses to bind.
- Detached route collections: `web.router`, `web.mount`, and per-router
  middleware scope.
- Request header lookup (`web.header`) and a strict RFC 6750
  `web.bearer_token`.
- Framework-failure observability: `web.observe` with a typed
  `Framework_Event`, emitted exactly once per failure, identically on both
  transports.
- Two opt-in middlewares: `web.logger` and `web.request_id`.
- In-memory testing with `web.test_request` — real routing, no socket.
- HTTP/1 conformance: ambiguous or malformed framing is rejected and the
  connection closed, proven by a raw-wire corpus (see
  `docs/transport-conformance.md`).
- CORS middleware, secure static-file mounts with ETag/304, and bounded
  buffered multipart fields/files.
- Graceful shutdown with an absolute drain deadline.
- Bounded synchronous Handler concurrency: automatic 4..32 capacity by
  default, explicit `1` for compatibility, and no async Handler API.
- Detached response streaming (`web.stream`, `web.stream_send`,
  `web.stream_close`, `web.stream_live`) with refusal counted rather than
  silent, and an opt-in spooled upload path (`web.enable_upload`, `web.upload`,
  `web.upload_persist`) that does not hold the body in RAM.
- Server counters through `web.stats` — refusals, responses, bytes, send
  errors, write-deadline aborts, handler dwell time and the stream refusal
  reasons.
- One request-scoped typed value (`web.request_state`), and application state
  that answers whether it was there (`web.state` returns `(^T, bool)`).
- Structural bounds on JSON, not just byte bounds: `Limits.max_json_nodes`
  refuses a body whose shape costs more than its size suggests.

**Public surface:** 80 application symbols + 2 test-support symbols = 82 —
frozen. The gate compares the compiler's own exported inventory, down to every
struct field, enum member and enum backing type, against
`build/phase1-public-signatures.txt`, and the direct import set against
`build/phase1-direct-dependencies.txt`. Changing any of it now requires a spec
amendment, not a snapshot refresh.

**Phase 2 froze more than the API.** It added three ledgers the symbol count
cannot express, and the gate enforces all three: a **claim ledger**, where every
guarantee the documentation makes carries a positive test, a negative control
and a stated non-guarantee; a **lifetime ledger**, which answers who owns each
value and until when; and a **capacity ledger**, which forbids the word
"bounded" anywhere a perimeter is not named — including for the limits this
framework does *not* impose.

Internals stay replaceable: the linear route table, the request arena and the
vendored backend are implementation, and may be rewritten as long as the
observable contracts hold.

**Not yet, and named honestly**

- PostgreSQL, explicit transactions and safe migrations — Phase 6 Crystals.
- Response streaming and an opt-in large-body/spool path — separately gated
  Phase 7 work, not implied by buffered multipart.
- WebSocket, HTTP/2 and in-process TLS — outside the current core decision.

**Never, and named just as honestly**

- Panic recovery. Odin has no recoverable panic, so a faulting handler aborts
  the process and Druse expects to run under a supervisor (ADR-020). The
  guarantee it *does* make is narrower and real: a handler that commits no
  response is finalized to a standardized 500, identically in tests and over a
  socket. `docs/errors.md` documents both halves.
- A closure-based `web.group`, now or in any future phase. Refused rather than
  deferred (ADR-024): a closure cannot be returned from a procedure in Odin,
  and `web.Router` plus `web.mount` do the job with visible ownership.

What exists today is a production-minded HTTP microframework for JSON APIs,
with explicit operational boundaries and a bootstrap transport intended to be
replaced by the official Odin HTTP package after that real implementation is
available and passes the same conformance corpus. The frozen contract now
carries a version: `v0.10.0`, pre-1.0, where a breaking change moves the MINOR
and `1.0` waits on accrued real-world use rather than on another gate.

## Supported platform and toolchain

Stated honestly rather than implied:

- **Tested: Linux x86-64 only.** macOS, Windows and other architectures are
  **untested** today — they may work, and nobody has proven it.
- **The toolchain pin is part of the contract.** Odin ships monthly `dev-`
  releases with breaking changes and no package manager, so Druse pins one
  release, one commit and one asset checksum in
  [`odin-version.txt`](odin-version.txt), and the gate refuses any other
  compiler. Re-pinning is a deliberate, recorded change — not an upgrade that
  happens to you.
- **Consumption is by vendoring or a git submodule** at a pinned commit — the
  ecosystem's own convention, since Odin will never officially support a
  package manager.

**The operational contract, which the release does not soften.** These are not
a pilot's caveats to be dropped at 1.0; they are what this framework is:

- **Linux x86-64.**
- **One server per process.** `web.serve` owns the process's listening
  lifecycle; two servers in one process is not a supported topology.
- **TLS terminates at the proxy.** Druse does not terminate TLS and will not —
  the decision, and what it costs, is in `docs/operations.md`.
- **A supervisor is mandatory, not a nicety.** Odin has no recoverable panic, so
  a faulting handler aborts the process and the supervisor restarting it *is*
  the recovery mechanism. There is no other one.

The mandatory gate (`build/check.sh`) runs on the pinned toolchain and is the
single source of truth for what "passing" means in this repository.

## Where to start

- **`docs/quick-start.md`** — from nothing to a running API.
- **`examples/01-hello-world`** — the smallest complete program.
- **`examples/02-json-api`** — a CRUD-shaped JSON API.
- **`examples/03-route-params`** — path params and query extractors.
- **`examples/04-middleware`** — the onion model, short-circuits and `next`.
- **`examples/05-route-groups`** — `Router`, `mount` and shared prefixes.
- **`examples/06-authentication`** — the canonical auth pattern, with its
  revalidation cost stated instead of hidden.
- **`examples/07-app-state`** — one typed value every handler can reach, with
  the lifetime rule shown as layout rather than described.

All seven examples compile in the mandatory gate.

**Deploying it?** [`docs/operations.md`](docs/operations.md) is the one to read:
the supported topology, what is bounded and what is not, what to monitor, and a
known-limitations section that does not flatter the framework.

## Licence, security and contributing

Druse is [MIT licensed](LICENSE).

It parses HTTP from untrusted clients, so it has a real attack surface. If you
find a security problem, please report it privately — [`SECURITY.md`](SECURITY.md)
explains how, and lists what is a documented limitation rather than a
vulnerability.

[`CONTRIBUTING.md`](CONTRIBUTING.md) explains the two things that surprise
people: the public API is frozen and the build enforces it, and growing it
requires measured evidence rather than agreement.

Notable changes are recorded in [`CHANGELOG.md`](CHANGELOG.md), and the current
release is `v0.10.0` — read its **Breaking** section before upgrading from a
pilot tag. What happens next is planned in
[`planning/roadmap.md`](planning/roadmap.md).

**Consuming Druse.** Odin has no package manager
[by design](https://odin-lang.org/docs/faq/), so vendor the `web/` directory or
add this repository as a submodule, and build with `-collection:druse=<path>`.
The Odin toolchain version is part of the contract — the pinned release, commit
and asset checksum are in `odin-version.txt`.

GitHub Actions is not required: a tracked pre-push hook runs the mandatory
gate, and the project VPS repeats it from a clean commit on an enabled systemd
timer. Current work-package status lives in `planning/phase-1-plan.md`.
