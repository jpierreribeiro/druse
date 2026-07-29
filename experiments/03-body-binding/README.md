# Experiment 03 — body-binding

**Question.** Does `body(ctx, dst: ^$T) -> bool` bind JSON into a caller-owned
destination using `core:encoding/json`, with the request-lifetime allocator
**explicitly substituted**, correctly handling nested strings/slices and the
empty / invalid / over-limit cases (writing the error and returning `false`)?

**Hypothesis.** `json.unmarshal(data, ^$T, allocator=…)` exists and is generic
over `^$T`, so the destination-filling shape compiles and returns only `bool`.
Nested `string`/`[]string` fields are allocated in the substituted arena, not
`context.allocator`. Empty and malformed bodies return `false` with
`responded == true`; over-limit short-circuits before parsing.

**Command.**
```bash
odin run . -collection:druse=../..
odin check .
```

**Expected result (to verify).**
- Compiles clean; four cases print as:
  - `valid+nested`: `ok=true`, `name="Jean"`, `tags=["a","b"]`
  - `empty-body`: `ok=false`, `err=Invalid_Json`, `responded=true`
  - `invalid-json`: `ok=false`, `err=Invalid_Json`, `responded=true`
  - `over-limit`: `ok=false`, `err=Body_Too_Large`, `responded=true` (never parsed)
- `arena.offset > 0` after the valid case → bound strings live in the request
  allocator, proving explicit-allocator substitution works.

**Limitations.** The arena here is a stand-in for the real per-request arena
(experiment 06). Body-limit is checked on an already-materialized buffer; the
real transport enforces the limit while reading (WP7 concern). Does not test
streaming bodies (out of MVP).

**Result.** `PASS` on `819fdc7`: nested value bound successfully; empty,
invalid, and over-limit branches responded as expected; arena usage was 68
bytes.

**Conclusion.** ADR-006 and `body(ctx, &dst) -> bool` are accepted: decoded
nested data uses the request allocator. Phase 1 applies a fixed 4 MiB cap;
empty and invalid bodies use the error contract.
