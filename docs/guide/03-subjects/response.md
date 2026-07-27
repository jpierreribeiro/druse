# Response

**Assumes:** [`../02-build-notes/01-nothing-to-hello.md`](../02-build-notes/01-nothing-to-hello.md).

## The senders

```odin
ok         :: proc(ctx: ^Context, value: $T)                                  // 200 + JSON
created    :: proc(ctx: ^Context, value: $T)                                  // 201 + JSON
no_content :: proc(ctx: ^Context)                                             // 204
json       :: proc(ctx: ^Context, status: Status, value: $T)
text       :: proc(ctx: ^Context, status: Status, s: string)
bytes      :: proc(ctx: ^Context, status: Status, content_type: string, data: []u8)
```

`json` is the single renderer. `ok` and `created` are exact shorthands over it
and never diverge from it.

```odin
	web.ok(ctx, User{id = 1, name = "Ada"})
	web.created(ctx, note)
	web.no_content(ctx)
	web.json(ctx, .Conflict, Envelope{...})
	web.text(ctx, .OK, "pong")
	web.bytes(ctx, .OK, "image/png", pixels)
```

## Pass the value, not a pointer

```odin
	web.ok(ctx, user)      // yes
	web.ok(ctx, &user)     // NO — a pointer is not an accepted payload form
```

The pinned marshaller rejects pointer-typed payloads (ADR-003). This is the
mistake people make first.

## Answer once

One response per request. A second sender call after the response is committed
does not overwrite it, and a handler that answers twice is a bug the observer
surface reports.

A fallible extractor that failed **has already answered**. Return, do not
write. See [`../05-recipes/error-responses.md`](../05-recipes/error-responses.md).

## Status is a named enum

```odin
Status :: enum int {
	OK = 200, Created = 201, Accepted = 202, No_Content = 204,
	Bad_Request = 400, Unauthorized = 401, Forbidden = 403, Not_Found = 404,
	Method_Not_Allowed = 405, Conflict = 409, Payload_Too_Large = 413,
	Too_Many_Requests = 429, Internal_Server_Error = 500,
	Service_Unavailable = 503,
}
```

**Use the name. Never cast.** `web.Status(503)` compiles, and so does
`web.Status(530)`. The enum exists so a status is a checked value.

## Headers

```odin
set_header :: proc(ctx: ^Context, name: string, value: string) -> bool
```

```odin
	web.set_header(ctx, "Retry-After", "1")
	web.text(ctx, .Service_Unavailable, "busy, retry shortly")
```

Set headers **before** you send the body. It returns `false` when the response
is already committed — check it if the value matters.

## Two things with no limit

**A response has no size cap.** `Limits.max_body` bounds what a client may
send; nothing bounds what your handler builds, and the response is buffered
whole (ADR-014). Run under a memory cgroup.

**The write timeout is off by default.** `Limits.max_write_time` is `0`. A slow
client can hold a response write open. Turn it on in production.

For a body you cannot buffer, see
[`../05-recipes/stream-a-response.md`](../05-recipes/stream-a-response.md).

## Returning without answering

The response driver finalizes it to the standardized `internal_error` 500,
logged, carrying no request detail. Identical under `web.serve` and
`web.test_request`.

Returning early is safe by design. Faulting is not — a panic aborts the
process.
