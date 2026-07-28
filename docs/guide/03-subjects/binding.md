# Binding

**Assumes:** [`request.md`](request.md).

Turning a request body into a typed value you own.

## One call

```odin
body :: proc(ctx: ^Context, dst: ^$T) -> bool
```

```odin
	input: Create_Note
	if !web.body(ctx, &input) {
		return          // already answered
	}
```

`false` means the request was refused and the response is committed. Return and
write nothing.

## Declaring the type

```odin
Create_Note :: struct {
	slug:  string        `json:"slug"`,
	title: string        `json:"title"`,
	body:  Maybe(string) `json:"body"`,
}
```

The tag names the wire field. `Maybe(T)` is how a nullable field stays distinct
from a zero value — JSON `null` becomes an empty `Maybe`, not `""`.

## Strict, with no lenient mode

| The body is | Answer |
|---|---|
| Not valid JSON | `400 invalid_json` |
| A field of the wrong type | `400 invalid_field` + the field path |
| A key you did not declare | `400 unknown_field` + the field path |
| Over `Limits.max_body` | `413 body_too_large` |

**An undeclared key is an error, not something ignored.** A client sending
`titel` gets told, rather than silently creating a note with no title.

You do not write any of these. The error envelope is the same one every
framework failure uses — see `docs/errors.md`.

## Once per request

The body is read once. A second `web.body` call decodes nothing and reports
`Body_Consumed_Twice` to the observer surface.

If two code paths both want it, decode once and pass the value.

## Then validate

Decoding proves the shape. It does not prove the values:

```odin
	v := validate.validator()
	defer validate.destroy(&v)
	validate.not_empty(&v, "slug", input.slug)
	validate.string_length(&v, "slug", input.slug, min = 1, max = 64)
	if vh.respond_if_invalid(ctx, &v) {
		return
	}
```

`validate` is transport-free: it collects a stable rule code and a field path,
**never the user's value**. `crystals:web/validate` is the thin adapter that
puts them on the wire, and it returns `true` when it answered.

`validate.destroy` frees the accumulated error set. The set is bounded by
`DEFAULT_MAX_ERRORS` and reports truncation rather than dropping silently.

**Validate before you touch the database.** A malformed request should never
cost you a connection.

## Three states, for PATCH

A PATCH must distinguish *leave it*, *clear it* and *replace it*.
`validate.Patch(T)` models exactly that — `Absent`, `Null`, `Set`:

```odin
	validate.deny_null(&v, "title", title_p.state)   // title is NOT NULL
	if title_p.state == .Set {
		validate.not_empty(&v, "title", title_p.value)
	}
```

See [`../02-build-notes/04-listing-patch-and-failure.md`](../02-build-notes/04-listing-patch-and-failure.md)
for the SQL that expresses all three in one statement.

## Forms and files

`web.body` is for JSON. For a form post use `crystals:web/form`, and for a file
use `web.form_file` or the spooled upload path.
