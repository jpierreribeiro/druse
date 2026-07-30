# Experiment 04 — optional-ok

**Question.** Is `#optional_ok` valid on the value-producing extractor
(`-> (value: int, ok: bool)`)? Can the `ok` be discarded (single-result call)?
What diagnostic does the compiler give? How does it compare with the plain
two-result form that lacks the directive — and what is the risk that a human or
LLM silently drops the bool?

**Hypothesis.** `#optional_ok` is legal for a proc whose two results end in
`bool`. With it, `id := path_int(ctx,"id")` compiles (bool discarded); without
it, discarding is a compile error. The canonical HTTP rule remains "always
check `ok`", precisely because `#optional_ok` makes silent-drop *possible*.

**Command.**
```bash
odin run . -collection:druse=../..
odin check .
```

**Expected result (to verify).**
- Compiles clean; `checked`, `discarded`, and `missing` lines print.
- `discarded` line proves the bool can be dropped under `#optional_ok`.
- The separate `probes/plain_discard.odin` intentionally discards the plain
  form and must fail with `Assignment count mismatch`. The runner executes and
  verifies this negative probe without modifying the green comparison source.

**Limitations.** This measures compiler behavior, not human behavior. The
"LLM/human risk" is a design judgment informed by the fact that `#optional_ok`
*permits* silent drop; the experiment can only confirm the mechanism, not the
misuse rate.

**Result.** First run stopped at a disabled dynamic literal; after explicit map
allocation, `PASS`. `#optional_ok` silently discards the bool. The separate
plain-form probe is executed by `run_checks.sh` and fails with
`Assignment count mismatch '1' = '2'` as required.

**Conclusion.** ADR-002 option 2 is accepted. HTTP extractors omit
`#optional_ok`, so the compiler forces handlers to capture and check `ok`.
The canonical call site remains unchanged.
Either way the *call-site* canonical form is unchanged.
