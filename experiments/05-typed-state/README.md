# Experiment 05 — typed-state

**Question.** For application state, compare **(A)** a `rawptr + typeid` stored
on `App` and read through an asserted `state(ctx, T)` accessor, vs **(B)** a
parametric `App(S)/Context(S)` that is type-closed by construction. Behavior
across: correct type, wrong type, `nil` state, and state lifetime.

**Hypothesis.**
- A: compiles; correct type returns a usable `^App_State` aliasing the caller's
  object (mutation visible on the original → same lifetime). Wrong type trips
  the `assert` at runtime. `nil` is the sharp edge — must be rejected at
  registration or checked in the accessor.
- B: correct case needs no runtime check (wrong type is a **compile** error),
  but every call site shows `App_State` type arguments — the generic noise the
  canonical API is trying to avoid.

**Command.**
```bash
odin run . -collection:druse=../..
odin check .
```

**Expected result (to verify).**
- Both A and B compile and print the correct `db="primary"`.
- A: `st.hits` becomes 1 after the handler mutates through the accessor →
  confirms shared lifetime (no copy).
- A wrong-type probe (uncomment): assertion fires with the spec's message.
- B: attempting a wrong-type call cannot even be written (compile error).

**Limitations.** `nil`-state handling is discussed, not fully exercised (deref
of nil is UB and would crash the run). The decision on where the nil-guard
lives is a design output, not a measurement.

**Result.** `PASS` for both correct alternatives and shared mutation lifetime.
The separate wrong-type probe exits 132 with the expected runtime assertion.
Nil policy remains AMEND-1 rather than an intentional UB execution.

**Conclusion.** ADR-004-A is accepted for the future Phase-3 Advanced API:
one sanctioned private `rawptr+typeid`, zero generic noise at call sites, and
one asserted boundary. `app_with_state` rejects nil; `state` asserts
registration and exact type. A parametric typed context remains separately
gateable.
