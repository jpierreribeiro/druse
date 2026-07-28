# Cookies

**Assumes:** [`request.md`](request.md). Package `crystals:web/cookie`.

## Read one

```odin
get :: proc(ctx: ^web.Context, name: string) -> (value: string, result: Get_Result)
```

```odin
	token, r := cookie.get(ctx, "session")
	if r != .Found {
		web.unauthorized(ctx, "sign in")
		return
	}
```

`Get_Result` is `Absent`, `Found` or `Malformed`. **`Absent` is the zero
value**, so a result nothing assigned reads as "no cookie", never as an
authenticated one.

`Malformed` means the named cookie carried bytes a cookie value may not carry.
Treat it as absent — never as a value to parse anyway.

The returned string is a **view into the request**. Clone it if it must outlive
the handler.

## Set one

```odin
	cookie.set(ctx, cookie.Cookie{
		name      = "prefs",
		value     = "dark",
		path      = "/",
		max_age   = 3600,
		secure    = true,
		http_only = true,
		same_site = .Lax,
	})
```

Set it **before** the body. `Set_Result` tells you whether it was written.

## The one you want for a session

```odin
secure_session :: proc(name: string, value: string, max_age := 0) -> Cookie
```

```odin
	cookie.set(ctx, cookie.secure_session("session", token))
```

It fills in the attributes a session cookie needs — `Secure`, `HttpOnly`,
`SameSite`, path — so you cannot forget one. **Use it rather than building the
struct by hand**, the same way you use `subject_clone` rather than remembering
a lifetime.

`max_age = 0` makes it a session cookie that ends with the browser.

## Clear one

```odin
	cookie.clear(ctx, "session")
```

`path` and `domain` must match what you set, or the browser keeps the old one.

## Bounds

`MAX_COOKIE_HEADER_BYTES`, `MAX_COOKIE_PAIRS`, `MAX_SET_COOKIE_BYTES`. A
request carrying more pairs than the bound is refused rather than parsed.

## A cookie is attached to requests the user did not make

That is what CSRF protection is for. Every mutating endpoint reachable with a
session cookie needs a token — see
[`../02-build-notes/05-sessions-and-login.md`](../02-build-notes/05-sessions-and-login.md).

`crystals:web/session` moves a session in a cookie for you, so you rarely call
this package directly for that case.
