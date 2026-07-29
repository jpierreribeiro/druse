# Experiment 08 — transport-boundary

**Question.** Can a **minimal private** contract connect *request view →
dispatch → response sink* with a **single commit**, driven by a **test
transport**, while keeping every backend type and ABI off the public surface?

**Hypothesis.** A tiny `Transport{ data, serve, stop }` is enough for Phase 1.
A `commit` guard enforces exactly-one-commit (second call rejected). The test
transport feeds canned `Request`s and captures `Response`s with no sockets.
Handlers would see only `^Context` built from `^Request`/`^Response` — never
`Transport` or the test data type.

**Command.**
```bash
odin run . -collection:druse=../..
odin check .
```

**Expected result (to verify).**
- Compiles clean; prints:
  - `resp[0] status=200 commit=1 body=pong`
  - `resp[1] status=404 commit=1 body={"error":{"code":"not_found"}}`
- No `BUG: double commit` line → the guard rejects the second commit.
- Grep check (runner): `Transport` / `Test_Transport_Data` never appear in a
  handler-facing signature.

**Limitations.** `serve` here is synchronous over an inbox; a real event-loop
backend (`core:nbio`) may invoke `dispatch` from a callback on the loop thread
— the execution-thread question stays open (recorded, not resolved). The
`Transport` field set is deliberately **not frozen**; a second real adapter may
change it.

**Result.** `PASS`: 200 and 404 responses each committed exactly once through
the private throwaway boundary.

**Conclusion.** Accepted ADR-008 (framework-side single commit for buffered
responses) and ADR-009 (private, unfrozen transport boundary). The conceptual
contract is accept work → dispatch → commit → stop; the private shape stays
mutable until multiple real adapters force it.
