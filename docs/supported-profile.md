# Supported profile

**Status: NORMATIVE — R1 controlled-pilot profile.** This is the single source
of truth for what Druse supports operationally. API guides explain how to use a
capability; the readiness matrix explains resource mechanics; neither may
silently redefine this profile.

R1 authorizes only an **internal, non-critical controlled pilot**. It does not
authorize direct Internet exposure, critical data, an external SLO, or a claim
that every possible deployment topology is production-ready.

## Platform and version

- **Linux x86-64 only.** The gate deliberately verifies that the current
  transport does not build on macOS or Windows. Other architectures and
  operating systems are unsupported.
- Build with the exact Odin revision in `odin-version.txt`. A different compiler
  is a different candidate and must pass the complete gate again.
- Druse is pre-1.0. Only the latest tag and current `main` are supported; there
  are no backports or LTS branches. A breaking public change increments MINOR.
- The transport is the pinned `laytan/odin-http` snapshot. The canonical
  divergence ledger is `planning/vendor-policy.md`; it currently contains
  **43 dispositions**. `vendor/odin-http/VENDOR.md` records provenance and
  delegates the live ledger to that file.

## Network and HTTP boundary

- Druse serves **HTTP/1.1**. It does not terminate TLS and does not provide a native HTTP/2 server.
  The supported edge is a reviewed reverse proxy that
  owns TLS, public HTTP/2, HSTS, compression and edge rate limiting, then uses
  HTTP/1.1 keep-alive to Druse.
- The R1 reference is the pinned Caddy topology in `ops/proxy/caddy/`. A
  different proxy or materially different chain is unsupported until it passes
  the same real-proxy campaign.
- Streaming routes require buffering disabled at the proxy. Client identity may
  use `X-Forwarded-For` only when the immediate peer matches an explicit
  `web.trust_proxies` prefix.
- Native TLS, native HTTP/2, HTTP/3, WebSocket, OpenAPI generation and an
  application CPU/job runtime are outside this profile.

## Execution, saturation and failure domain

- Handlers are synchronous. One handler occupies one Handler lane for its full
  duration; arbitrary application or foreign code is not preempted.
- `Limits.max_handlers = 0` selects CPU count clamped to 4..32. Explicit values
  are allowed from 1 through 256. When every lane is occupied, the dedicated
  acceptor closes newly accepted sockets without writing an HTTP response and
  increments `saturation_refusals`; `max_connections` remains the separate
  server-wide admission bound.
- Core lifecycle state supports **up to 16 concurrent servers per process**.
  That is a capacity ceiling, not the R1 deployment recommendation. The R1
  measured profile uses one listener and one App per process so its FD, memory,
  memlock, failure and rollback accounting stays exact.
- A faulting handler aborts the process because Odin has no recoverable panic.
  The mandatory failure domain is an unprivileged process under a supervisor,
  behind the proxy and inside a measured memory cgroup.

## Shutdown and supervisor

- `web.stop(&app)` publishes draining, stops admission and begins a cooperative
  transport drain. `web.is_draining(&app)` is the readiness signal.
- `Limits.max_drain_time` defaults to 10 seconds and bounds transport cleanup,
  open connections, streams and uploads. It cannot unwind a blocked Handler.
- The application owns the minimal `SIGTERM`/`SIGINT` handler. The supervisor
  owns the absolute process deadline and kill. The R1 unit fixes
  `TimeoutStopSec=30`, strictly greater than the drain deadline, with
  `Restart=on-failure` and a crash-loop backstop.

## Limits and memory

The default-on protections are:

| Field | Default | Meaning |
|---|---:|---|
| `max_body` | 4 MiB | buffered request-body cap |
| `max_request_line` | 8,000 bytes | request-line cap |
| `max_headers` | 8,000 bytes | header-block cap |
| `max_request_time` | 30 s | total request-arrival deadline |
| `max_connections` | 1,024 | server-wide connection bound |
| `reserved_conns` | 16 | admission reserve for shutdown |
| `max_drain_time` | 10 s | cooperative transport drain |
| `max_json_nodes` | 100,000 | structural JSON budget |

The default-off limits are `max_write_time=0`, `max_idle_time=0` and
`max_response_bytes=0`. R1 turns all three on explicitly through the canonical
runtime profile. Spooled large-body ingestion is also opt-in through
`web.enable_upload`; the public `web.upload`/`web.upload_persist` API exists and
is bounded by per-upload, concurrency and process quotas.

`max_response_bytes` caps one committed response body and replaces an excess
with an observed 500. It **does not prevent OOM**: it does not bound temporary
Handler allocations, construction high-water, concurrent responses or process
RSS. R1 therefore fixes `max_response_bytes=8 MiB` and requires
`MemoryMax=1G`, derived from the preserved concurrent campaign, plus the
response and write-time limits.

## Optional ecosystem context

`druse-crystals` contains first-party optional Odin packages. Crystals are
ordinary explicit imports with their own construction, ownership and teardown;
there is no plugin runtime. They are useful deployment context but are **not
part of the R1 proof or support claim** unless a specific application audits
and pins the Crystal it uses.

## Authoritative supporting records

- resource mechanics and known bounds: `planning/closure-readiness-matrix.md`;
- canonical R1 runtime values: `ops/deploy/runtime-limits.example`;
- supervisor contract: `ops/deploy/druse.service`;
- proxy contract: `ops/proxy/caddy/README.md`;
- vendor provenance and dispositions: `vendor/odin-http/VENDOR.md` and
  `planning/vendor-policy.md`;
- R1 decision and evidence index: `planning/readiness/R1-controlled-pilot.md`.
