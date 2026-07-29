# Experiment 06 — request-views

**Question.** Can `Request` expose `method/path/query/headers/body` as **views**
(strings/slices aliasing a mutable transport buffer)? Can we *demonstrate*
invalidation when the buffer is reused, and support explicit persistent copies
via a chosen allocator?

**Hypothesis.** Odin `string`/`[]byte` are pointer+len views; slicing `buf`
yields aliases with zero copy. Overwriting `buf` (simulating the transport
reusing its buffer for the next request) corrupts the views — visible proof of
the request-lifetime rule. `strings.clone(view, allocator)` produces an
independent copy that survives the reuse.

**Command.**
```bash
odin run . -collection:druse=../..
odin check .
```

**Expected result (to verify).**
- Compiles clean; first line shows correct `method/path/query/body`.
- After clobbering `buf` with `#`, the aliased `req.path` prints garbage
  (`######`), while `saved` still prints `/users`.
- This is the normative rule made physical: *do not retain request-derived
  views past the request; copy explicitly to persist.*

**Limitations.** The parser is a toy; real header/body parsing belongs to the
transport (experiment 08 / WP2). The buffer reuse is simulated manually rather
than driven by an event loop.

**Result.** First run exposed missing struct-field commas; after that recorded
syntax correction, `PASS`: buffer reuse changes the view to `######`, while
the explicit clone remains `/users`.

**Conclusion.** Accepted ADR-007: the `Request` abstraction may expose
transport-backed views with request-scoped validity. Temp allocation is for
immediate scratch only; an explicit copy to the correct allocator is required
to persist data.
