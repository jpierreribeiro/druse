# Forms and redirects

**Assumes:** [`request.md`](request.md). Packages `crystals:web/form` and
`crystals:web/redirect`.

For a browser posting `application/x-www-form-urlencoded`. For a file, see
[`../05-recipes/accept-a-file-upload.md`](../05-recipes/accept-a-file-upload.md).

## Read a field

```odin
is_form :: proc(ctx: ^web.Context) -> bool
field   :: proc(ctx: ^web.Context, name: string) -> (value: string, result: Result)
```

```odin
	if !form.is_form(ctx) {
		web.bad_request(ctx, "expected a form post")
		return
	}

	email, r := form.field(ctx, "email")
	if r != .Found {
		web.bad_request(ctx, "email is required")
		return
	}
```

Check `is_form` first. It tests the content type, so a JSON body posted to a
form endpoint fails with your message rather than an empty field.

The value is a **view into the request buffer**. Clone what must outlive the
handler.

`MAX_FIELDS` and `MAX_VALUE_BYTES` bound the body. Over either, the request is
refused rather than parsed.

## Then redirect — always

```odin
see_other :: proc(ctx: ^web.Context, location: string) -> bool
to        :: proc(ctx: ^web.Context, status: web.Status, location: string) -> bool
```

```odin
	if !save(email) {
		web.internal_error(ctx)
		return
	}
	redirect.see_other(ctx, "/thanks")
```

**`see_other` is a `303`, and it is the one you want after a POST.** The
browser re-requests with `GET`, so a refresh does not repost the form.

Answering a POST with a rendered page instead is the bug this prevents: the
user refreshes and submits twice.

`to` takes any status when you need one — `SEE_OTHER`, `FOUND`,
`MOVED_PERMANENTLY`, `TEMPORARY`, `PERMANENT` are the named constants.

Both return `bool`. `false` means the response was already committed.

## Never redirect to a user-supplied location

```odin
	next, _ := web.query(ctx, "next")
	redirect.see_other(ctx, next)      // WRONG — open redirect
```

An attacker sends `?next=https://evil.example`, your site sends the user there,
and the URL bar said your domain until the last moment.

Allow-list the destinations, or accept a path only and reject anything with a
scheme or a leading `//`. `html.url_scheme_is_safe` helps when the value must
stay a URL.

## The whole form flow

CSRF on the form, the field read, the redirect after post:

1. Issue a token and put it in the form — see
   [`../02-build-notes/05-sessions-and-login.md`](../02-build-notes/05-sessions-and-login.md).
2. `csrf_http.reject(ctx, &svc, binding)` first in the handler. It answers for
   you and returns `true`.
3. Read fields, do the work.
4. `redirect.see_other(ctx, "/somewhere")`.

Nothing changes state before step 2 returns.
