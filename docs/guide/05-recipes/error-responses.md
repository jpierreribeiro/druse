# Send an error response

**Assumes:** you have a handler.

## The five responders

```odin
bad_request   :: proc(ctx: ^Context, message: string)
unauthorized  :: proc(ctx: ^Context, message: string)
forbidden     :: proc(ctx: ^Context, message: string)
not_found     :: proc(ctx: ^Context, resource: string)
internal_error :: proc(ctx: ^Context)
```

That is the whole set. There is no `conflict` and no `too_many_requests`
responder — use `web.json` or `web.text` with the status you want.

```odin
	web.bad_request(ctx, "email is required")
	web.unauthorized(ctx, "sign in")
	web.forbidden(ctx, "not your note")
	web.not_found(ctx, "note")
	web.internal_error(ctx)
```

## Two that do not take a message

`not_found` takes a **resource name**, not a sentence; it builds the envelope
itself. `internal_error` takes **nothing** — a 500 must not leak why it
happened. Log the reason on the server.

## For a status with no responder

```odin
	web.json(ctx, .Conflict, Envelope{error = Message{code = "conflict", message = "slug already taken"}})
	web.text(ctx, .Service_Unavailable, "busy, retry shortly")
```

`web.Status` carries `Conflict`, `Payload_Too_Large`, `Too_Many_Requests` and
`Service_Unavailable` as named members. **Use the name, never a cast.**
`web.Status(503)` compiles, and so does `web.Status(530)`.

## Do not write the ones you get for free

The framework answers these before your handler runs:

```text
GET  /unknown-path        404   not_found
DELETE /a-GET-only-path   405   + an Allow header
GET  /users/abc           400   invalid_path_parameter
POST with broken JSON     400   invalid_json
POST with an unknown key  400   unknown_field + field path
POST with a huge body     413   body_too_large
```

A fallible extractor has **already answered** when it reports failure. Return,
and write nothing:

```odin
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return          // the 400 is already committed
	}
```

Writing your own response there produces two responses for one request.

## A handler that returns without responding

It gets the standardized `internal_error` 500, logged on the server and
carrying no detail about the request, under `web.serve` and `web.test_request`
alike. Returning early is safe. **Faulting is not** — a panic aborts the
process.

## See also

- `docs/errors.md` — the full envelope contract and every code.
- [`../04-rules/result-vocabularies.md`](../04-rules/result-vocabularies.md) —
  which failures deserve a 503 rather than a 401.
