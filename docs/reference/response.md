# Response

Sending output. One response per request.

Generated from `build/phase1-public-signatures.txt` and the source. Do
not edit by hand — run `build/gen_reference.py`.

## `json`

```odin
json :: proc(ctx: ^Context, status: Status, value: $T)
```

json writes `value` as a JSON response with the given status.

Taught in [`03-subjects/response.md`](../guide/03-subjects/response.md).

## `text`

```odin
text :: proc(ctx: ^Context, status: Status, s: string)
```

text writes a plain-text response with the given status.

## `bytes`

```odin
bytes :: proc(ctx: ^Context, status: Status, content_type: string, data: []u8)
```

bytes writes a response with a CALLER-CHOSEN media type and a raw byte body (corrective WP C2, friction F8-4). It is the buffered binary responder Phase 1 omitted: `web.text` sends `text/plain` from a string and `web.json` marshals a value, but neither can put arbitrary bytes on the wire with a chosen type — a PDF, an image, a CSV export, an attachment download.

Taught in [`03-subjects/response.md`](../guide/03-subjects/response.md).

## `ok`

```odin
ok :: proc(ctx: ^Context, value: $T)
```

ok writes a 200 JSON response.

Taught in [`03-subjects/response.md`](../guide/03-subjects/response.md).

## `created`

```odin
created :: proc(ctx: ^Context, value: $T)
```

created writes a 201 JSON response.

## `no_content`

```odin
no_content :: proc(ctx: ^Context)
```

no_content writes a 204 response with no body.

## `set_header`

```odin
set_header :: proc(ctx: ^Context, name: string, value: string) -> bool
```

set_header records an APPLICATION response header, to ride on whatever response the handler then commits (corrective WP C2, friction F8-2). It is the public path applications need for `Set-Cookie`, `Cache-Control`, `Content-Disposition`, `Location`, and the like — the surface Phase 1 deliberately omitted.

## `Status`

```odin
Status :: enum int {OK = 200, Created = 201, Accepted = 202, No_Content = 204, Bad_Request = 400, Unauthorized = 401, Forbidden = 403, Not_Found = 404, Method_Not_Allowed = 405, Conflict = 409, Payload_Too_Large = 413, Too_Many_Requests = 429, Internal_Server_Error = 500, Service_Unavailable = 503}
```

Status is the HTTP status enumeration used by the public response helpers.

Taught in [`03-subjects/response.md`](../guide/03-subjects/response.md).

## `bad_request`

```odin
bad_request :: proc(ctx: ^Context, message: string)
```

bad_request writes a standardized 400 response.

Taught in [`05-recipes/error-responses.md`](../guide/05-recipes/error-responses.md).

## `unauthorized`

```odin
unauthorized :: proc(ctx: ^Context, message: string)
```

unauthorized writes a standardized 401 response.

## `forbidden`

```odin
forbidden :: proc(ctx: ^Context, message: string)
```

forbidden writes a standardized 403 response.

## `not_found`

```odin
not_found :: proc(ctx: ^Context, resource: string)
```

not_found writes a standardized 404 response for the named resource.

## `internal_error`

```odin
internal_error :: proc(ctx: ^Context)
```

internal_error writes a standardized 500 response.

Taught in [`05-recipes/error-responses.md`](../guide/05-recipes/error-responses.md).
