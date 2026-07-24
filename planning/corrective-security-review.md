# Security re-scan of the corrective public surface (release Gate 5)

**Status: DONE (autonomous half of Gate 5), 2026-07-24.** The Corrective Program
added real attack surface — a way to write response headers, a way to emit
arbitrary bytes, request-scoped state, and a typed timestamp param. This is an
adversarial review of each addition against the threat model (an application that
passes UNTRUSTED input into these APIs, plus the framework's own redaction/
injection invariants). The 14 prior findings stay pinned by their tests
(`planning/security-backlog-reconciliation.md`); this covers only what C1–C7 add.

**Verdict: no new vulnerability. One hardening applied** (`set_header` name is now
a strict RFC 9110 token, not merely control-byte-free). The privacy review before
real user data remains the owner's, and a full `/claude-security` re-scan is the
owner's call — this is the targeted review of the delta.

---

## C2 — `web.set_header(ctx, name, value) -> bool`

**Threat: response-splitting / header injection.** An app that does
`set_header(ctx, user_name, user_value)`.

- **Value CR/LF/NUL** → rejected (`header_field_has_control`). Test:
  `c2_set_header_refuses_reserved_and_injection` (`"a\r\nInjected: yes"`).
- **Name CR/LF/NUL** → rejected. Previously via the same control check; **now via
  the stricter `header_name_is_token`** (RFC 9110 §5.1 `tchar`), which also rejects
  a name with a space, `:`, or any separator — a name that could produce a
  malformed/ambiguous header line a proxy might reparse. **Hardening applied
  2026-07-24**; tests added (`"X Bad"`, `"X:Bad"`, `"X\r\nSet-Cookie"`).
- **Framework/transport-owned names** (`Content-Type`, `Content-Length`,
  `Transfer-Encoding`, `Connection`, `X-Request-Id`) → rejected case-insensitively,
  so an app cannot corrupt content typing or the wire framing. Test asserts
  `Content-Type: text/evil` does not appear.
- **Resource exhaustion** → bounded: `APP_HEADER_MAX` pairs and `APP_HEADER_BUFFER`
  bytes, fixed request-local storage; over-budget returns `false`, no allocation.
- **Ordering** → app headers emitted AFTER framework headers, so an app header can
  never shadow a framework-owned one.
- **Redaction** → `set_header` writes nothing to logs/metrics; the observability
  redaction budget is unaffected.

**Residual:** none. A trusted app can still set a semantically unwise header (e.g.
a permissive `Access-Control-Allow-Origin`), but that is application policy, not a
framework vulnerability — and `web.cors` remains the guided path.

## C2 — `web.bytes(ctx, status, content_type, data)`

- **Content-Type injection** → the media type is control-byte-checked and length-
  bounded (`CONTENT_TYPE_MAX`); an invalid one is a clean 500, never a split
  header. Test: `c2_bytes_rejects_control_content_type`.
- **Body ownership** → the `[]u8` is copied into a Response-owned allocation and
  released by `response_destroy`, exactly like `web.text`; no use-after-free, no
  double-free (the single-commit guard + `owned_body`).
- **Data content** → bytes are opaque to the framework; the app chooses the media
  type. An app serving attacker-controlled bytes must set `Content-Disposition`
  (the board's download does) so the browser does not render them inline — an
  application responsibility the C2 pairing now makes expressible.

**Residual:** none at the framework layer.

## C7 — `web.request_state(ctx, $R) -> ^R`

- **Type confusion** → the first access stamps the `typeid`; every later access
  asserts it, so reading as the wrong type aborts (ADR-020), never reinterprets
  bytes. Test: the suite uses one type; a mismatched type is a compile-independent
  runtime assert.
- **Cross-request leak** → a fresh `Context` per request (`serve_dispatch`,
  `test_request`) means `request_state_set` starts false; the first access zeroes
  the buffer. Test: `c7_request_state_does_not_leak_across_requests`.
- **Bounds** → `#assert(size_of(R) <= REQUEST_STATE_MAX)` at compile time; no
  overflow of the fixed buffer.
- **No escape** → the storage is the Context's; a `^R` that outlives the request is
  a use-after-free, documented as the caller's contract (same class as
  `web.state`'s lifetime rule). Not a framework-introducible bug.

**Residual:** the lifetime contract is documentation-enforced, as `web.state`'s
already is — consistent with the existing model, no new hazard class.

## C5 — `pg.arg_timestamptz(v: string)` + `validate.rfc3339`

- **SQL injection** → NONE: `arg_timestamptz` is a BOUND parameter (PQexecParams);
  the value crosses the wire separately from the SQL and is typed by OID 1184. It
  can never become SQL structure — the same guarantee as every other `arg_*`.
- **Type-confusion at the DB** → the OID pins the type; a value that is not a valid
  timestamp is rejected by PostgreSQL (and, at the app boundary, by
  `validate.rfc3339` → 400 before the query).
- **`rfc3339` DoS** → the validator is O(n) over a bounded input, no allocation, no
  backtracking (a hand-written char scan, not a regex) — no catastrophic
  backtracking vector.

**Residual:** none.

## C1 / C3 / C4 / C6 — no new attack surface

- **C1** (enum members) — pure additions; a status code is a number on the wire.
- **C3** (`query_int_opt`) — a read that commits a standardized 400; same redaction
  as the other extractors.
- **C4** (`stream_live`) — read-only predicate; no injection, no state change.
- **C6** (`Expect: 100-continue`) — the adapter now READS the body it previously
  refused; the body still passes every existing framing/limit guard (max_body,
  CL/TE ambiguity, chunk validation). Honoring the expectation does not bypass any
  admission or size check — verified by `tests/wp9-wire` (the honored case is an
  ordinary 201 through the normal body path; an over-limit body is still 413).

**Residual:** none.

---

## Remaining Gate-5 items (owner)

- **Privacy review** before any real (non-synthetic) user data — the plan's
  standing non-goal; owner-gated.
- A full **`/claude-security` re-scan** if the owner wants defence-in-depth beyond
  this targeted review — owner's call (the owner declined the Hardening-phase
  re-scan in favour of test-pinned guarantees; the same choice applies here).
