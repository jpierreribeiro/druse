# Risk Register

Status: **COMPLETE.** Each risk: probability · impact · early signals ·
mitigation · fallback · resolution phase.

Scale: probability/impact ∈ {Low, Med, High}.

## R-01 · Pinned toolchain / VPS egress blocked
- **Prob** High · **Impact** High (blocks all ratification and WP0/WP8).
- **Signals.** `curl` 403/truncated download; VPS cannot fetch dev-2026-07a,
  the public repository, or the future vendored adapter.
- **Mitigation.** SHA-verified installer with retries; cache a verified
  artifact; vendor odin-http; local pre-push remains authoritative if the VPS
  is temporarily unavailable.
- **Fallback.** perform ratification on a developer machine; commit the runner
  output as evidence; keep the audit/plan (compiler-independent) as the
  deliverable meanwhile.
- **Resolution.** WP0 closed: local compiler and real VPS verifier are proven;
  the VPS stores the SHA/commit-verified distribution under `/opt`, and the
  timer is enabled. A truncated archive is rejected before extraction.
  Adapter vendoring remains WP8.

## R-02 · odin-http is beta / API-unstable
- **Prob** Med · **Impact** Med (WP8 churn).
- **Signals.** compile breaks against the vendored version; routing/pattern
  differences.
- **Mitigation.** confine to the adapter; pin the exact odin-http commit;
  conformance suite (WP9) catches behavior drift.
- **Fallback.** the test transport proves the core with no odin-http at all;
  ship Phase 1' on the test transport if the adapter slips.
- **Resolution.** WP8.

## R-03 · `core:net/http` never arrives / arrives with a hostile model
- **Prob** Med · **Impact** Med (Phase 5, not Phase 1).
- **Signals.** no release; an API that forces async handlers or backend types.
- **Mitigation.** conceptual boundary + conformance suite already isolate this;
  handler API stays synchronous from the app view.
- **Fallback.** odin-http (or a core:net adapter) remains the backend
  indefinitely; migration stays optional.
- **Resolution.** Phase 5.

## R-04 · Request/Response ownership wrong (dangling views)
- **Prob** Med · **Impact** High (memory bugs).
- **Signals.** exp-06 shows a retained view surviving; sanitizer/UB in tests.
- **Mitigation.** view-invalidation test in WP2; normative "copy to persist";
  request arena freed once.
- **Fallback.** copy request fields up front (perf cost) if views prove unsafe.
- **Resolution.** WP2 / exp-06.

## R-05 · Response committed before an error is known
- **Prob** Med · **Impact** Med (garbled responses).
- **Signals.** marshal error after headers written; double-commit in tests.
- **Mitigation.** single-commit guard (exp-08); render into a buffer, commit
  once, errors resolved pre-commit.
- **Fallback.** for streaming (future) define a separate contract.
- **Resolution.** WP6 / exp-08.

## R-06 · `json.unmarshal` ignores the substituted allocator for nested data
- **Prob** Low · **Impact** Med (leaks / wrong lifetime).
- **Signals.** exp-03 `arena.offset == 0` after a nested bind; leaks under
  tracking allocator.
- **Mitigation.** verify in exp-03; if true, copy nested strings into the arena
  post-unmarshal.
- **Fallback.** WP7 adds an explicit copy pass.
- **Resolution.** WP7 / exp-03.

## R-07 · `#optional_ok` enables silent error-drop (resolved policy)
- **Prob** Med · **Impact** Med (correctness holes in user handlers).
- **Signals.** exp-04 confirms the bool is droppable; reviews find `id :=
  path_int(...)` in the wild.
- **Mitigation.** Accepted ADR-002 drops the directive for HTTP extractors;
  the compiler rejects capturing only one of two results. Examples enforce
  `if !ok`.
- **Fallback.** none needed; a negative compile probe guards the policy.
- **Resolution.** Policy resolved at the Spec Gate; WP5 implements/tests it.

## R-08 · App by-value double-free (accepted invariant)
- **Prob** Low · **Impact** Med.
- **Signals.** exp-01 double-free under `defer destroy`.
- **Mitigation.** exp-01 passed; App is non-copyable by contract, stores no
  pre-return self-pointer, and only the caller-owned original is destroyed.
- **Fallback.** `app_init` form (already designed).
- **Resolution.** WP1 / exp-01.

## R-09 · Docs overpromise `web.app()` defaults (resolved specification)
- **Prob** High (present now) · **Impact** Low-Med (user trust).
- **Signals.** Phase-1 build returns 200 for oversized body / no 405 while docs
  promise 413/405.
- **Mitigation.** Accepted split: Phase 1 fixed 4 MiB cap plus minimal 405 with
  `Allow`; later defaults are phase-marked in normative docs.
- **Fallback.** gate fails if implementation/tests do not match this split.
- **Resolution.** Specification resolved; behavior lands in WP4/WP7.

## R-10 · Contract vs conformance suite divergence (test transport lies)
- **Prob** Low · **Impact** High (green tests, broken sockets).
- **Signals.** behavior differs between test transport and odin-http.
- **Mitigation.** conformance suite from Phase 1 (WP9); a small e2e suite over a
  real socket.
- **Fallback.** expand e2e coverage.
- **Resolution.** WP9.

## R-11 · Freeze-discipline violation (freezing un-ratified signatures)
- **Prob** Med · **Impact** Med (spec decouples from language).
- **Signals.** a signature marked frozen with no executed experiment.
- **Mitigation.** WP11 computes the gate from *executed* runner output only.
- **Fallback.** un-freeze pre-1.0.
- **Resolution.** WP11.

## R-12 · Scope creep into Phase 1 (middleware/radix/typed-state)
- **Prob** Med · **Impact** Med (delays the slice).
- **Signals.** PRs adding `use`/groups/radix under Phase 1.
- **Mitigation.** scope-review categories; gate rejects category-2/4 items.
- **Fallback.** move work to its phase branch.
- **Resolution.** ongoing; enforced at WP11.

## R-13 · Official JSON rejects pointer payloads (baseline resolved)
- **Prob** High when callers pass pointers · **Impact** Med (unexpected 500 or
  pressure for reflection-heavy behavior).
- **Signals.** exp-02 `^User -> Unsupported_Type`; pinned stdlib rejects
  `runtime.Type_Info_Pointer` except JSON `Null`.
- **Mitigation.** Accepted value-only baseline; canonical/AI docs explicitly
  reject `&value` and pointer-typed payload variables. Marshal failure is
  logged server-side before one complete pre-commit `internal_error`.
- **Fallback.** WP6 prototypes one-level dereference. It is adopted only after
  clean compiler evidence and an approved spec amendment.
- **Resolution.** Baseline resolved at the Spec Gate; ergonomic probe in WP6.

## R-14 · Convenience-driven public API accretion
- **Prob** Med · **Impact** High (cognitive load, agent hallucination, lock-in,
  and irreversible pre-1.0 compatibility pressure).
- **Signals.** synonyms; helpers without behavior tests; `web.Context` in
  domain packages; dynamic state bags; backend nouns in exports; later-phase
  features appearing in quick starts; optional dependencies entering core.
- **Mitigation.** `planning/public-api-guardrails.md`; exact export inventory
  in WP1/WP11;
  same-change compiling example, behavior test, docs, ownership, dependency,
  and rollback evidence for every public change.
- **Fallback.** keep the proposal private/advanced, move it to its owning
  phase, or remove it before 1.0 rather than preserve a second canonical path.
- **Resolution.** continuous; audited at every WP gate and frozen at WP11.

## R-15 · Repeated body binding has ambiguous semantics
- **Prob** Med · **Impact** Med (surprising replay, repeated parsing, or double
  error response).
- **Signals.** two calls to `web.body` both decode; invalid first bind leaves an
  undocumented state; test and real transports behave differently.
- **Mitigation.** ADR-012 plus a disposable WP7 state-machine prototype before
  implementation; pin the second-call contract in behavior tests.
- **Fallback.** single-consumer body capability with explicit programmer-error
  diagnostics and the existing single-commit guard.
- **Resolution.** WP7 before production body binding.

## R-16 · Reusable request storage retains a giant allocation
- **Prob** Med · **Impact** High (one adversarial request permanently raises
  process RSS across otherwise small traffic).
- **Signals.** retained capacity follows peak body size; memory does not return
  near baseline after a giant request and arena reset.
- **Mitigation.** Phase-3 benchmark of oversize bypass and retention caps;
  record peak and retained memory, not only allocation count.
- **Fallback.** release oversize allocations at request end even if common-path
  buffers remain reusable.
- **Resolution.** Phase-3 allocator gate.

## R-17 · HTTP framing differs between real adapters
- **Prob** Med · **Impact** High (request smuggling, connection desynchronization,
  or green in-memory tests masking unsafe wire behavior).
- **Signals.** adapters disagree on `CL+TE`, duplicate lengths, bad chunks,
  truncation, whitespace, or unread request bodies.
- **Mitigation.** separate semantic and raw-wire conformance matrices in WP9;
  use RFC 9110/9112 as protocol authority.
- **Fallback.** close the connection on ambiguous/unconsumed framing rather
  than attempt reuse; quarantine a non-conforming adapter.
- **Resolution.** WP9 and every future adapter gate.

## R-18 · Raw request paths create unbounded observability cardinality
- **Prob** Med · **Impact** High (metrics memory growth and exporter overload).
- **Signals.** `/users/1`, `/users/2`, and random 404 paths become distinct
  metric series; exporter queue grows under path scans.
- **Mitigation.** retain stable route identity internally; 404 has no route
  pattern, 405 retains the matched pattern; bounded non-blocking delivery.
- **Fallback.** omit the route attribute when no match exists; drop bounded
  events with an explicit dropped-events counter.
- **Resolution.** Phase-3 router contract / Phase-4 observability.

## R-19 · Forwarded client address is trusted automatically
- **Prob** Low before feature exists · **Impact** High (spoofed audit, rate
  limits, allowlists, or security decisions).
- **Signals.** direct clients can change the effective address with
  `Forwarded`/`X-Forwarded-For`; private CIDRs are implicitly trusted.
- **Mitigation.** ADR-013; connected peer is authoritative by default; explicit
  CIDR allowlist and right-to-left chain evaluation; preserve original peer.
- **Fallback.** ignore all forwarding headers.
- **Resolution.** Phase-4 security gate before implementation.

## Heat summary

| Risk | Prob | Impact | Phase |
|---|---|---|---|
| R-01 egress | Med (CI/vendor remains) | High | WP0/WP8 |
| R-04 ownership | Med | High | WP2 |
| R-10 suite divergence | Low | High | WP9 |
| R-02 odin-http beta | Med | Med | WP8 |
| R-05 commit ordering | Med | Med | WP6 |
| R-07 optional_ok | Med | Med | WP5 |
| R-09 doc overpromise | High | Low-Med | WP4/7/10 |
| R-03 net/http | Med | Med | P5 |
| R-06 unmarshal alloc | Low | Med | WP7 |
| R-08 app double-free | Low | Med | WP1 |
| R-11 freeze violation | Med | Med | WP11 |
| R-12 scope creep | Med | Med | WP11 |
| R-13 pointer JSON | High when used | Med | WP1/WP6 |
| R-14 API accretion | Med | High | Every WP / WP11 |
| R-15 body replay ambiguity | Med | Med | WP7 |
| R-16 retained giant buffer | Med | High | P3 |
| R-17 framing divergence | Med | High | WP9/every adapter |
| R-18 metric cardinality | Med | High | P3/P4 |
| R-19 trusted-proxy spoofing | Low before feature | High | P4 |
| R-20 transport globals | Low (needs 2 servers) | High | P2 doc / P4 fix |
| R-21 responder scratch aliasing | Med as responders grow | High | P2 |
| R-22 gate obstructs refactors | High | Med | P2 |
| R-23 vendor patch drift | Med | High | P4 |
| R-24 no licence | Certain until fixed | High (blocks all use) | correction PR |
| R-25 registration during dispatch | Low | Med | P2 |

The local R-01 condition and all blockers from the original Phase-1 Spec Gate
are resolved. Newly identified R-15/OQ-15 is explicitly owned and blocks only
WP7 implementation until its prototype and human decision. Remaining risks are
owned by their implementation work packages or later phase gates. External
research created no permission to implement future-phase features early.

## Added after the Phase-1 freeze (post-Phase-1 audit)

R-20 to R-25 come from the post-Phase-1 audit and the Odin-fit audit; see
`post-phase1-audit.md` for the file:line evidence behind each. None is a Phase-1
blocker — Phase 1 froze with no open blocker assigned to it — and none is a P0.

- **R-20** `web/internal/transport` keeps package-level `g_server`/`g_config`;
  a second `serve()` cross-wires dispatch to the wrong App, and `g_server`
  briefly holds a stack address read non-atomically. Reaching it requires
  deliberately starting two servers. Document the single-server constraint in
  Phase 2; replace with per-server state in Phase 4.
  **Status, 2026-07-31 — MOSTLY CLOSED, and the residue changed shape.** WP43
  removed `g_config`, so the cross-wire this entry describes cannot happen; WP70
  protects `g_server`'s pointer lifetime, so the stack-address read is gone too.
  What remains is one process-wide slot, and the blocker on removing it is no
  longer an implementation fact but the **frozen signatures** of `web.stats` and
  `web.refused_connections`. It did not land in Phase 4 as this entry directed.
  ADR-018 is now accepted and **WP123** owns the remainder.
- **R-21** Three request-local scratch arrays are aliased by the committed
  response, and safety rests on six hand-written `committed` guards rather than
  on `response_commit`. Phase 2 adds responders, which is exactly the scenario
  that breaks it; make the invariant structural.
- **R-22** About a third of the gate pins implementation text (exact parameter
  names, exact declaration lines, exact file sets), so honest refactors fail
  with a message accusing the maintainer of needing a spec amendment. Phase 2
  adds files and will meet this immediately.
- **R-23** Five hand-applied vendor security patches with no upstreaming path,
  verified by code-shape greps rather than by behaviour. The raw-wire corpus is
  the real evidence.
- **R-24** No `LICENSE` file: the repository is legally unusable by anyone.
  Owner decision, corrective PR, before any external adoption.
- **R-25** Route registration is unguarded during dispatch; the "table is
  stable" invariant is comment-only while `web.get` is public and callable from
  a handler.
