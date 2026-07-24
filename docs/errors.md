# Error Responses

Every error Uruquim produces is JSON, with one envelope shape:

```json
{"error": {"code": "...", "message": "...", "field": "..."}}
```

- `code` is stable. Match on it, not on the message.
- `message` is human-readable and may be reworded.
- `field` is present **only** when a specific input field caused the error.
  Today that is `invalid_path_parameter`, `invalid_query_parameter`,
  `invalid_field`, and `unknown_field`. For every other code it is **omitted
  entirely**: never `null`, never `""`.

Every error carries `Content-Type: application/json`.

All examples below were captured from a running server.

## The twelve current codes

| `code` | HTTP | Producer | `field`? |
|---|---|---|---|
| `invalid_path_parameter` | 400 | `web.path_int` | yes |
| `invalid_query_parameter` | 400 | `web.query_int`, `web.query_int_or` | yes |
| `invalid_json` | 400 | `web.body` | no |
| `invalid_field` | 400 | `web.body` | yes |
| `unknown_field` | 400 | `web.body` | yes |
| `body_too_large` | 413 | `web.body` (enforced by the transport) | no |
| `bad_request` | 400 | `web.bad_request` | no |
| `unauthorized` | 401 | `web.unauthorized` | no |
| `forbidden` | 403 | `web.forbidden` | no |
| `not_found` | 404 | `web.not_found`, and the automatic route miss | no |
| `method_not_allowed` | 405 | automatic, when the path exists under another method | no |
| `internal_error` | 500 | `web.internal_error`, and the framework itself | no |

---

### `invalid_path_parameter` — 400

**Producer:** `web.path_int`. **Field:** the parameter name.

**Message:** `Path parameter '<name>' must be an integer`

Absent, empty, malformed and out-of-range all produce the SAME message. That is
deliberate: distinguishing "the route never captured that name" would describe
the server's own routing to the caller, and it is an application bug rather than
something the client can fix.

```json
{"error":{"code":"invalid_path_parameter","message":"Path parameter 'id' must be an integer","field":"id"}}
```

Integers are strict decimal: an optional `-` then ASCII digits. `+5`, `0x10`,
`1_000`, `1.5` and surrounding whitespace are all rejected.

---

### `invalid_query_parameter` — 400

**Producer:** `web.query_int` and `web.query_int_or`. **Field:** the parameter
name.

Two messages, because both are things the caller can act on:

| Condition | Message |
|---|---|
| absent (required by `query_int`) | `Query parameter '<name>' is required` |
| present but not a valid integer | `Query parameter '<name>' must be an integer` |

```json
{"error":{"code":"invalid_query_parameter","message":"Query parameter 'page' is required","field":"page"}}
```

```json
{"error":{"code":"invalid_query_parameter","message":"Query parameter 'limit' must be an integer","field":"limit"}}
```

`web.query_int_or` uses its default **only** when the key is absent. `?limit=`
is present with an empty value, so it is a 400 — not the default. `web.query`
never produces this error: it reports presence and returns.

---

### `invalid_json` — 400

**Producer:** `web.body`. **No field.**

**Message:** `Request body must be valid JSON`

```json
{"error":{"code":"invalid_json","message":"Request body must be valid JSON"}}
```

Triggered by an empty body, malformed JSON, and JSON5 constructs (comments,
unquoted keys, single-quoted strings), which strict JSON rejects.

Well-formed JSON that does not fit a declared field is `invalid_field`, not a
syntax error.

---

### `invalid_field` — 400

**Producer:** `web.body`. **Field:** the stable destination path.

**Message:** `Request field has an invalid value`

```json
{"error":{"code":"invalid_field","message":"Request field has an invalid value","field":"address.number"}}
```

The code means the JSON grammar is valid, but the value cannot be decoded into
the declared field type. Nested object fields use dot-separated paths. A wrong
root aggregate uses `$`. The response never includes the raw value, an Odin
type name, source file, or decoder diagnostic.

---

### `unknown_field` — 400

**Producer:** `web.body`. **Field:** the stable undeclared-key path.

**Message:** `Request field is not recognized`

```json
{"error":{"code":"unknown_field","message":"Request field is not recognized","field":"profile.surprise"}}
```

Canonical body decoding is strict: object keys not represented by the
destination are rejected instead of silently skipped. If several unknown keys
exist at the same object level, the selected key is deterministic.

---

### `body_too_large` — 413

**Producer:** `web.body`, but enforced by the transport as it reads. **No
field.**

**Message:** `Request body exceeds the limit of <N> bytes`, where `<N>` is the
configured limit — the default is `4194304` (4 MiB).

```json
{"error":{"code":"body_too_large","message":"Request body exceeds the limit of 4194304 bytes"}}
```

The cap defaults to 4 MiB (4·1024·1024 = 4194304 bytes) and is configurable with
`web.limits` (`Limits.max_body`); the message reports whatever limit is in
effect. Exactly the limit is accepted; only a strictly larger body is rejected.
The check happens **before** the handler runs, so the limit holds even for a
handler that never calls `web.body`.

---

### `bad_request` — 400

**Producer:** `web.bad_request(ctx, message)`. **No field.**

**Message:** your message, verbatim.

```json
{"error":{"code":"bad_request","message":"email is required"}}
```

The message reaches the client unchanged, so pass a caller-facing explanation —
never an internal diagnostic.

---

### `unauthorized` — 401 and `forbidden` — 403

**Producers:** `web.unauthorized(ctx, message)` and
`web.forbidden(ctx, message)`. **No field.** Message verbatim.

```json
{"error":{"code":"unauthorized","message":"authentication required"}}
```

```json
{"error":{"code":"forbidden","message":"insufficient permission"}}
```

---

### `not_found` — 404

**Producer:** `web.not_found(ctx, resource)`, and the automatic route miss.
**No field.**

Two messages, from two sources:

| Source | Message |
|---|---|
| `web.not_found(ctx, "user")` | `Resource 'user' not found` |
| automatic, unknown path | `Route not found` |

```json
{"error":{"code":"not_found","message":"Resource 'user' not found"}}
```

```json
{"error":{"code":"not_found","message":"Route not found"}}
```

Pass the resource NAME (`"user"`), not a sentence. The automatic 404 comes from
`web.app()`; `web.bare()` installs no automatic response.

---

### `method_not_allowed` — 405

**Producer:** automatic, when the path exists under a different method. **No
field.**

**Message:** `Method not allowed`

```json
{"error":{"code":"method_not_allowed","message":"Method not allowed"}}
```

The response also carries an `Allow` header listing only the methods registered
for that path, always in the order `GET, POST, PUT, PATCH, DELETE`, comma-and-
space separated, without duplicates. A method outside the Phase-1 set follows
the same 404/405 rules and never produces a 501.

---

### `internal_error` — 500

**Producer:** `web.internal_error(ctx)`, and the framework itself. **No field.**

**Message:** `Internal server error`

```json
{"error":{"code":"internal_error","message":"Internal server error"}}
```

`internal_error` takes no message on purpose: failure detail is logged on the
server, never returned to the client. The framework produces it in three cases,
each logged first:

- a response payload the JSON encoder cannot serialize (a pointer or a
  procedure — Phase-1 payloads are values);
- an unsupported request destination type or internal decoder/allocation
  failure (ordinary client type mismatches are `invalid_field`);
- a handler that returns without responding. HTTP has no zero status, so the
  driver logs the mistake and answers 500.

---

## Faults: what happens when a handler goes wrong

There are two different failures here and they end very differently. Uruquim
guarantees one of them and, deliberately, does not contain the other.

### A handler that commits no response — GUARANTEED

If a handler returns without producing a response, the **response driver**
answers for it: it logs the mistake and commits the standardized
`internal_error` 500 above. HTTP has no zero status, so there is nothing else a
correct server could send.

This covers the case that actually occurs — not a handler that plainly forgot
to answer, but one that answers on the happy path and returns early on some
error branch:

<!-- fragment: phase2/fault-early-return -->
```odin
show_invoice :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return // path_int already answered 400
	}

	invoice, found := lookup_invoice(id)
	if !found {
		return // BUG: nothing was committed on this branch
	}

	web.ok(ctx, invoice)
}
```

The client gets the standardized 500, not a hung connection and not an empty
reply. Four properties are guaranteed, and each is tested:

- **Identical on both transports.** `web.serve` and `web.test_request` run the
  same driver, so what you see in a test is what a socket sends.
- **Identical under `web.app()` and `web.bare()`.** `bare()` means "no default
  route policy", never "no safety". (Under `app()` an *unmatched path* is a
  404; under `bare()` it reaches the driver and becomes this 500.)
- **Repeatable.** The second fault is answered exactly like the first, and a
  healthy request in between is unaffected.
- **Silent about the cause.** The body is a compile-time constant. The path,
  the query, the route pattern, the method and any internal message stay on the
  server's log and never reach the client. `web.internal_error` takes no
  message parameter precisely so that this cannot be undone by accident.

It is a bug on your side either way. The guarantee exists so the bug is a
logged 500 instead of a protocol violation.

### A handler that FAULTS — the process aborts

A panic, a failed assertion, an out-of-bounds index, a nil dereference or a
divide-by-zero in a handler **aborts the process**. The connection closes
without a reply — `curl` reports `curl: (52) Empty reply from server` — and the
server exits for a supervisor to restart.

**There is no recovery middleware and there is no `web.recovery`**, in this
phase or any later one (ADR-020). This is not an omission, and stating it
plainly is the point: Odin has no recoverable panic. `context` is an implicit
by-value parameter, so `web.app()` cannot install a fault hook on its caller's
behalf; and most real faults never reach a hook at all, because
`bounds_check_error` is `proc "contextless"` and cannot consult one even in
principle. A "recovery" default would therefore have been a claim the framework
could not keep.

**Run Uruquim under a supervisor** — systemd, a container restart policy, or
equivalent. That is the intended deployment, not a workaround.

Evidence for every statement in this section:
`planning/phase-2-prototype-recovery.md`.

---

## Protocol errors (before a request exists)

These are **not** application errors and do **not** use the envelope above. When
the request line or headers are malformed there is no framework-owned request
yet, so the transport answers or simply closes the connection. Your handler
never runs.

| Condition | Result |
|---|---|
| `Content-Length` together with `Transfer-Encoding` | 400, connection closed |
| more than one `Content-Length` (even if identical) | 400, connection closed |
| comma-list, negative, signed, non-decimal or overflowing `Content-Length` | 400, connection closed |
| any `Transfer-Encoding` other than a single final `chunked` | 400, connection closed |
| malformed chunked body (bad size, truncated, missing CRLF or terminator) | rejected, connection closed |
| a fixed body that ends before its declared length | rejected, connection closed |
| whitespace before a header name or colon, obs-fold continuation | 400, connection closed |
| invalid request line | rejected, connection closed |
| `Expect:` with an unknown expectation (not `100-continue`) | 417, connection closed |

In every one of these cases: the handler does not run, the connection is
closed, and no trailing bytes are reinterpreted as a second request. A rejected
request may be answered with a status or closed outright — both are acceptable,
and neither carries a JSON body.

`docs/transport-conformance.md` explains the policy and how it is proven.
