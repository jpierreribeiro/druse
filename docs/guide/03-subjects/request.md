# Request

**Assumes:** [`../02-build-notes/01-nothing-to-hello.md`](../02-build-notes/01-nothing-to-hello.md).

Everything you can read from a request, and the one lifetime rule that governs
all of it.

## The struct

```odin
Context :: struct { request: Request, private: Context_Internal }

Request :: struct {
	method:  Method          // .GET .POST .PUT .PATCH .DELETE .UNKNOWN
	path:    string
	query:   string          // the raw string; use the extractors instead
	headers: Header_View
	body:    []u8
}
```

`ctx.request` is readable directly. There is nothing else on `ctx` — it is not
an extension bag, and `private` is off limits.

## The extractors

| Read | Call | On failure |
|---|---|---|
| Path segment, as text | `web.path(ctx, "id")` | Returns `""` |
| Path segment, as int | `web.path_int(ctx, "id")` | **Sends 400**, returns `ok = false` |
| Query, as text | `web.query(ctx, "q")` | `found = false` |
| Query, as int | `web.query_int` / `_opt` / `_or` | See the recipe |
| Header | `web.header(ctx, "X-Request-Id")` | `ok = false` |
| Bearer token | `web.bearer_token(ctx)` | `ok = false` |
| Multipart field | `web.form_field(ctx, "title")` | Sends 400 |
| Multipart file | `web.form_file(ctx, "avatar")` | `ok = false` |

**Two behaviours, and you must know which you called.** A fallible extractor
answers `400` itself — you return and write nothing. A lookup answers nothing
and hands you `ok = false` to decide.

`web.header` is case-insensitive and first-occurrence-wins. It is a pure
lookup: no response, nothing logged.

Details: [`../05-recipes/read-a-query-parameter.md`](../05-recipes/read-a-query-parameter.md).

## The body

```odin
body :: proc(ctx: ^Context, dst: ^$T) -> bool
```

```odin
	input: Create_Note
	if !web.body(ctx, &input) {
		return          // already answered
	}
```

Decoding is **strict**. Malformed JSON, a wrong field type, an undeclared key
or a body over `Limits.max_body` is refused with a `400` — or `413` — before
your first line runs. There is no lenient mode.

**Call it at most once per request.** The body is read once; a second call
decodes nothing and the observer surface reports `Body_Consumed_Twice`.

Map a nullable field to `Maybe(T)`, so JSON `null` stays distinct from a zero
value:

```odin
Create_Note :: struct {
	slug:  string        `json:"slug"`,
	title: string        `json:"title"`,
	body:  Maybe(string) `json:"body"`,
}
```

For a three-state PATCH — leave, clear, replace — use `validate.Patch(T)`. See
[`../02-build-notes/04-listing-patch-and-failure.md`](../02-build-notes/04-listing-patch-and-failure.md).

## The lifetime rule

**Every string and slice above is a view into the request buffer.** They are
valid while the handler runs, and not after.

That includes `ctx.request.path`, `ctx.request.body`, every header value, every
query value and `Uploaded_File.bytes`.

Never store one in an app-lived struct. If it must outlive the request, clone
it. This is the rule in
[`../04-rules/ownership-and-lifetime.md`](../04-rules/ownership-and-lifetime.md),
and it is the most common way to break an application built on Druse.

## The client's IP

`web.client_ip(ctx)` reports the socket peer unless you called
`web.trust_proxies` at startup. See
[`../05-recipes/serve-a-browser-app.md`](../05-recipes/serve-a-browser-app.md).
