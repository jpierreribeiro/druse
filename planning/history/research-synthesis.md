# External Research Synthesis

Status: **REVIEWED PLANNING INPUT.** This document integrates external reports
archived outside this repository without promoting them to specification.
Where a recommendation changes a contract, the owning ADR and phase gate still
control the decision.

## Source discipline

- Generated citation tokens in raw reports are not auditable citations.
- Protocol and security claims must be checked against RFCs or official
  implementation documentation before entering normative text.
- Performance claims are hypotheses until measured on the pinned Odin
  toolchain and representative Druse workloads.
- Go, Rust, Zig, C, NGINX, Envoy, and other frameworks are comparative
  evidence, not Odin-language evidence.

Primary references retained for future ratification:

- [RFC 9110 — HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110)
- [RFC 9112 — HTTP/1.1](https://www.rfc-editor.org/rfc/rfc9112)
- [RFC 7239 — Forwarded](https://www.rfc-editor.org/rfc/rfc7239)
- [Odin `base:sanitizer`](https://pkg.odin-lang.org/base/sanitizer/)
- [NGINX real IP module](https://nginx.org/en/docs/http/ngx_http_realip_module.html)
- [Envoy overload manager](https://www.envoyproxy.io/docs/envoy/latest/configuration/operations/overload_manager/overload_manager)
- [Envoy draining](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/draining.html)
- [OpenTelemetry HTTP metrics](https://opentelemetry.io/docs/specs/semconv/http/http-metrics/)

## Conclusions accepted as planning direction

### Routing and low-cardinality identity

- Phase 3 must benchmark pointer-radix, index-radix, and hybrid/data-oriented
  layouts before choosing the production router representation.
- The public routing API and precedence remain unchanged: static beats param;
  param beats terminal wildcard.
- A successful match retains an internal stable route identity and pattern.
  A 405 retains the matched pattern and method set for `Allow`; a 404 has no
  route pattern. No public route-pattern accessor is authorized.
- Claims that a flattened radix is universally superior are **UNVALIDATED**.

### Request memory and debug tooling

- The request arena remains the ownership model. Phase 3 must benchmark an
  oversize allocation bypass plus a retention cap so one giant request cannot
  permanently enlarge reusable storage.
- ASan poison/unpoison, delayed buffer reuse, and context epochs may be
  prototyped as debug tooling. They do not prove that request views never
  escape and must add no production hot-path checks.
- JSON bodies never spill implicitly to disk. Multipart spill belongs to a
  future optional upload facility with explicit ownership and quotas.

### Body extraction

- Repeated typed body binding requires an explicit contract before WP7. A
  buffered transport making replay technically possible does not make replay
  the canonical semantic.
- The preferred hypothesis is a single-consumer body state, because it is
  predictable and avoids hidden caching. ADR-012 remains PROPOSED until the
  WP7 prototype determines diagnostics and failure behavior.

### Transport conformance and defensive parsing

- Semantic conformance applies to the in-memory test transport and every real
  adapter: request conversion, lifetimes, normalization, commit, and stop.
- Wire/framing conformance applies only to real HTTP adapters. A test transport
  cannot prove rejection of ambiguous HTTP/1 framing.
- The Phase-1 corpus must cover ambiguous length framing, invalid chunks,
  truncation, invalid whitespace, body disposal/connection reuse, and
  `Expect: 100-continue` behavior without leaking parser types into the core.

### Production controls

- Trusted proxy headers are ignored by default. A Phase-4 security ADR must
  define peer address, effective client address, allowlisted proxy networks,
  chain traversal, malformed input, and preservation of the original peer.
- Graceful drain must be transport-neutral: stop admission, allow admitted
  work to finish, impose an absolute deadline, close remaining work, and clean
  each lifecycle exactly once. The ADR follows a two-transport prototype.
- Deterministic bounded admission/shedding precedes any adaptive overload
  controller. Adaptive thresholds and hysteresis remain research.
- Observability uses stable route identity and bounded, non-blocking delivery.
  Exporters do not run as arbitrary blocking callbacks in the request hot path.

## Rejected or deferred suggestions

- No `web.hijack`, public socket, backend handle, or transport-specific escape
  hatch is added to the canonical API.
- No arbitrary 64 KiB arena, multipart threshold, queue size, or overload
  threshold is frozen from external research.
- No public `route_pattern(ctx)` accessor is added in Phase 3 or 4 merely for
  instrumentation owned by the framework.
- No adaptive overload manager is implemented before deterministic shedding.
- No raw request path may be used as a metrics label fallback.
- No external framework's returned-error model overrides ADR-011.

## Impact on current work

- WP7 gains a disposable repeated-body-binding prototype and ADR-012 gate.
- WP9 gains separate semantic and wire/framing conformance matrices.
- Phase 3 gains router-layout, allocator-retention, and debug-lifetime probes.
- Phase 4 gains security and lifecycle gates for trusted proxies, drain,
  uploads, observability, and shedding.
- No Phase-1 public symbol, handler signature, or transport boundary changes.
