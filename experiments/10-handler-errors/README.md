# Experiment 10 — handler error propagation

**Question.** Should the canonical Druse handler remain
`proc(ctx: ^Context)`, return a typed error like Echo, or return an explicit
response-or-error outcome?

**Models.**

- A — current handler, direct responders, centralized typed `handle_error`.
- B — `proc(ctx) -> Handler_Error`; dispatcher formats/logs returned errors.
- C — `proc(ctx) -> Handler_Outcome`; dispatcher commits response or error.

No model uses `any`, `map[string]any`, a public `rawptr`, or a transport type.
The toy `Service_Error` enum stands in for application-domain failures and
makes the closed-world cost visible.

**Command.**

```bash
odin test . -collection:druse=../..
```

**Coverage.** Each model proves JSON success, domain 404, unknown 500 + server
log, marshal failure before commit, late error after commit without a second
write, extractor-already-responded behavior, middleware auth short-circuit,
and exact `ok`/`json(.OK)` delegation.

**Executed result.** `PASS` on `dev-2026-07-nightly:819fdc7`: four test
procedures, all successful.

Two reproducible probes add the decisive compiler evidence:

- `ignored_results.odin` compiles: Odin permits silently discarding a returned
  `Handler_Error` or `Handler_Outcome`.
- `bare_return.odin` fails intentionally with
  `Expected 1 return values, got 0`: an unnamed returned result breaks the
  canonical extractor `if !ok { return }` flow.

**Finding.** All three shapes are mechanically viable, so compilation alone
does not justify changing the public handler. Model B is the closest to Echo
and centralizes returned failures, but it introduces a framework-owned closed
error vocabulary, changes handlers, middleware, responders, dispatcher, and
every example, and still requires application-domain errors to be mapped at a
boundary. Model C adds a second response representation plus an
`Already_Responded` state and is the most ceremonial. Model A preserves the
already-ratified API and can centralize formatting/logging through a typed
error event without claiming arbitrary Go-like error propagation.

**Recommendation.** Keep Model A for the Phase-1 canonical handler. Schedule a
typed error observer/policy for the Phase-2 error/recovery work. Reconsider a
returned `Handler_Error` only as a separately gated major API change after
real application evidence; do not expose both handler shapes.
