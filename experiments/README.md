# Druse — Throwaway Prototypes

These experiments exist to **ratify or refute** proposed Phase-1 public
signatures with real Odin, per the freeze discipline: *specification text
proposes; compiling prototypes ratify.*

**They are throwaway.** No product package imports them. They are not the
framework; they are evidence.

## Status: EXECUTED — EXTENDED SUITE 10/10

The suite passes on the pinned `dev-2026-07a` toolchain (commit `819fdc7`). The
historical first-run transcript and preliminary audit are archived outside the
repository; `experiments/run_checks.sh` is the reproducible evidence that
remains here.

The accepted Phase-1 JSON baseline uses concrete payload values; pointer
payloads remain unsupported. WP6 owns a non-blocking one-level
pointer-dereference prototype before that restriction can be reconsidered.

## How to produce real evidence

```bash
# 1. install dev-2026-07a into an isolated prefix and put it on PATH
export PATH="/tmp/druse-toolchain:$PATH"
odin version    # current binary prints dev-2026-07-nightly:819fdc7

# 2. run the verification-only runner (never modifies sources)
bash experiments/run_checks.sh
```

The runner exits `3` if `odin` is absent (records the baseline), `1` if any
experiment fails, `0` if all pass.

## Experiment → decision map

| Experiment | Ratifies signature / contract | ADR |
|---|---|---|
| 01-api-shape | `app()` by value, `destroy(&app)`, `^App` ops | ADR-001 |
| 02-generic-json-response | `json(ctx,status,$T)`, `ok`/`created` exact shorthand | ADR-003 |
| 03-body-binding | `body(ctx, ^$T) -> bool`, request-allocator ownership | ADR-006 |
| 04-optional-ok | `#optional_ok` for value extractors, silent-drop risk | ADR-002 |
| 05-typed-state | `state(ctx,T)` rawptr+typeid vs parametric | ADR-004 |
| 06-request-views | request views + explicit persist copy | ADR-007 |
| 07-middleware-chain | cursor `next`, onion vs pre-order, commit timing | ADR-005 / ADR-008 |
| 08-transport-boundary | minimal private `Transport`, single commit | ADR-008 / ADR-009 |
| 09-test-transport | contract-suite prototype (behavior, not sockets) | — |
| 10-handler-errors | void handler vs typed error vs explicit outcome | ADR-011 |

Intended-failure probes remain commented and were not counted in the first
run. exp-05's wrong-type probe is an expected runtime assertion, despite older
text loosely grouping it with compile failures.
