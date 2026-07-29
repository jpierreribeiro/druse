# Experiment 07 — middleware-chain

**Question.** Do both a **pre-order** chain and an **onion** (code before *and*
after `next`) chain work over global/group/route/handler with short-circuit and
unwind? How much per-request state does the cursor model need, and **where does
the response commit** relative to the middleware "after" code? *(No Phase-2
decision is taken here — this only gathers evidence.)*

**Hypothesis.** A single cursor (`handlers` slice + `index`) drives both styles.
Onion "after" code runs during stack unwind, i.e. **after** the terminal
handler has committed — which is exactly the commit-timing subtlety the spec
flagged. Per-request state is one slice header + a few scalars; no per-hop heap.

**Command.**
```bash
odin run . -collection:druse=../..
odin check .
```

**Expected result (to verify).**
- Onion order: `global:before, group:before, route:auth, handler:commit,
  route:after, group:after, global:after`.
- `committed == true` set at `handler:commit`, with `route/group/global:after`
  running afterwards → confirms onion "after" is **post-commit**.
- Pre-order order: `preorder:run, preorder:run, handler:commit` (no after).
- Printed state cost: `slice + index + aborted + committed`, no per-hop alloc.

**Limitations.** This is a synchronous, in-memory chain. Whether the real
transport can *safely* let code run after commit (headers already flushed,
buffer released) is precisely what experiment 08 / the Phase-2 gate must decide.
The abort branch is present but wired off (flip the `== 999` guard to exercise).

**Result.** `PASS`: exact onion and pre-order sequences printed; onion unwind
occurs after handler commit. No Phase-2 policy was selected.

**Conclusion (pending ratification).** Feeds ADR-005 (middleware) and ADR-008
(response commit) with evidence, but **deliberately reaches no Phase-2
verdict**: the onion "after runs post-commit" fact is the reason the spec makes
post-`next` semantics conditional on transport guarantees. Phase 1 needs only
the cursor mechanism; the onion/pre-order choice stays open per the freeze
discipline.
