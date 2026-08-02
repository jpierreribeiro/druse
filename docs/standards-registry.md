# Standards registry

**Status: ADOPTED for R1.** The external standards Druse adopts, the
scope of each adoption, and where the evidence lives. The honest framing:

> Druse defines selected contracts informed by IEEE, ISO/IEC/IEEE, IETF and W3C
> standards, with explicit test evidence and documented deviations.

Druse does **not** claim "IEEE compliant" or "POSIX compliant." It adopts the
*contracts* it can verify, names the *deviations* it takes, and points every
adoption at *executable evidence*. A conformance seal without evidence would be
the exact ceremony this project refuses.

`docs/supported-profile.md` remains authoritative for platform and deployment
support; this registry only states the standards scope inside it.

## Registry

| Standard | Scope | Adoption | Evidence |
|---|---|---|---|
| **RFC 9110** (HTTP Semantics) | methods, status, `Allow`, conditional/semantic rules | Normative | semantic corpus (`tests/support/transport_conformance/semantic.odin`) |
| **RFC 9112** (HTTP/1.1 messaging) | framing, `Content-Length`/chunked, keep-alive, smuggling | Normative | raw-wire corpus (`tests/support/transport_conformance/corpus.odin`, `tests/wp9-wire`) |
| **RFC 8259** (JSON) | JSON grammar; no `NaN`/`Infinity` | Normative | JSON boundary tests (`tests/wp6-*`, `tests/wp67-json-boundary`) + `planning/numeric-contract.md` |
| **RFC 6750** (Bearer token) | `Authorization: Bearer` parsing | Normative | `web.bearer_token`, `examples/06-authentication` |
| **IEEE 754-2019** | numbers crossing the JSON/DB boundary | Selected boundary profile | `planning/numeric-contract.md` (NUM-001…005) |
| **IEEE 1003.1-2024** (POSIX) | signals, monotonic clocks, sockets, files | Selected profile | `docs/platform-contract.md` + the platform gate (Linux x86-64) |
| **ISO/IEC/IEEE 29148-2018** (requirements) | requirement quality & traceability | Process (light) | the traceability method below + the claim ledger + ADRs |
| **W3C Trace Context** | `traceparent`/`tracestate` propagation | Future (Crystal) | ADR-042; enabled by `web.header`, forwarded by the `http_client` Crystal |
| **RFC 9457** (Problem Details) | error interop | Future (optional Crystal adapter) | ADR-041 |
| ISO/IEC/IEEE 1012-2024 (V&V) | integrity levels | Before-release (process) | deferred — see below |
| ISO/IEC/IEEE 29119 (testing) | uniform test-evidence format | Before-release (process) | deferred — see below |
| IEEE/ISO/IEC 42010-2022 (architecture) | viewpoints | Before-release (process) | deferred — see below |
| IEEE 730 / ISO/IEC/IEEE 12207 | QA & lifecycle | Release/maintenance | deferred — see below |

## Requirement traceability (ISO/IEC/IEEE 29148, light)

Druse already has the pieces 29148 asks for — normative `SHALL`/`MUST` prose, a
frozen public **claim ledger**, **ADRs**, per-WP **gate controls** and **negative
controls**. Rather than bolt a second, parallel `REQ-XXXX` bureaucracy on top of
that (which would create two sources of truth), the adoption is a **traceability
method**: every load-bearing requirement is traceable through the artifacts that
already exist —

```text
requirement (SHALL/MUST, in a spec or ADR)
   → architectural decision (planning/adrs.md)
   → implementation (web/<file>:<symbol>)
   → positive test (tests/wpNN-*)
   → negative control (a gate mutation that MUST fail)
   → public documentation (docs/<file>)
```

A stable `REQ-` identifier is minted **only** where no existing anchor (an ADR
number, a gate control name, a claim-ledger symbol) already serves. Example of a
fully-traced requirement using existing anchors:

```text
Requirement:  Admission SHALL stop before draining begins.
Decision:     ADR (drain/shutdown lifecycle) + phase-4/6 freeze
Implementation: web/lifecycle.odin (web.stop → transport.request_stop)
Positive test:  tests/wp58-drain/
Negative control: a transport that keeps admitting during drain MUST fail the gate
Documentation:  docs/operations.md §4
```

The families that get identifiers when needed: `REQ-HTTP-*`, `REQ-JSON-*`,
`REQ-NUM-*` (= the `NUM-*` in `numeric-contract.md`), `REQ-LIFETIME-*`,
`REQ-CAPACITY-*`, `REQ-SHUTDOWN-*`, `REQ-SEC-*`. This document is the index; the
requirement text stays in its spec/ADR, not duplicated here.

## Deferred adoptions (with the trigger that promotes each)

Scheduled by the owner's recommended order; not adopted now to avoid premature
ceremony.

- **IEEE 1012 (V&V — integrity levels).** *Before first release.* Assign
  integrity A/B/C so the HTTP parser and migrations get more negative testing,
  fault injection and independent verification than a text helper. Trigger: the
  pre-release V&V pass.
- **ISO/IEC/IEEE 29119 (testing).** *Before first release.* A minimal uniform
  header per test corpus — objective / risk / input space / invariant / negative
  control / environment / pass-fail / evidence — over the corpora that already
  prove these properties. Trigger: same pre-release pass.
- **IEEE/ISO/IEC 42010 (architecture).** *Before first release.* Six viewpoints
  (framework user, transport implementer, Crystal author, operator, security, AI
  agent) over the existing architecture spec. Trigger: the architecture-doc
  consolidation.
- **IEEE 730 / 12207 (QA & lifecycle).** *At the first public release.* The
  release-readiness checklist (toolchain pinned, gate green, API inventory
  unchanged, claims verified, limitations reviewed, migration path, security
  policy, supported platforms, dependency provenance, tested rollback) — most of
  which the gate and the production gate already enforce. Trigger: the M2/M5
  release decision.

## The point

For a web framework the **most important** specs are IETF and W3C (RFC 9110/9112,
RFC 8259, W3C Trace Context), not IEEE — and those are already the project's
normative corpora. The IEEE/ISO adoptions above are selected, evidence-backed
contracts and a traceability discipline, not compliance seals. Every row names
its evidence or its trigger; a row with neither does not belong here.
