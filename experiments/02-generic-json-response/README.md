# Experiment 02 — generic-json-response

**Question.** Can `json(ctx, status, value: $T)` serialize structs, pointers to
structs, slices and large nested values via `core:encoding/json`? Do `ok` and
`created` delegate to `json` exactly once with a fixed status and no extra
behavior? What does the official marshaller reject?

**Hypothesis.** `json.marshal(value, allocator)` accepts `any`, so a parametric
`$T` wrapper compiles and covers value, pointer, and slice inputs. `ok`/
`created` are one-line delegations, so `commit_count == 1` after each. `any` is
used only *inside* the renderer as an encapsulated stdlib detail — never as
framework storage or public API.

**Command.**
```bash
odin run . -collection:druse=../..
odin check .
```

**Expected result (to verify).**
- Compiles clean; three prints show valid JSON bodies.
- `commit_count == 1` for `ok`, `created`, and `json`.
- Pointer input (`&u`) marshals identically to the value (marshaller
  dereferences) — confirms handlers may pass either.
- Intentional-failure probe (uncomment the `proc` value): `json.marshal`
  returns an error, exercising the pre-commit error path. Recorded separately
  as an **intended failure**.

**Limitations.** Uses `temp_allocator` for the marshalled bytes; real ownership
(request arena vs temp) is decided in experiments 03/06, not here. Says nothing
about streaming large bodies.

**Result.** First run failed due the recorded package/procedure name collision;
after aliasing the stdlib import, the runner passed mechanically. Struct and
large values serialize with one commit. `^User` and the separate proc probe
return `Unsupported_Type`. The human-approved ADR-003 baseline is value-only;
the toy `Bad_Request`/stale-body capture is negative evidence and is not the
production error contract.

**Conclusion.** Response by concrete `$T` value and the `ok`/`created`
exact-shorthand shape are ratified. Pointer support is not. WP6 must log a
marshal failure and render a fresh pre-commit `internal_error`, and will run a
non-blocking one-level dereference prototype before any amendment is proposed.
