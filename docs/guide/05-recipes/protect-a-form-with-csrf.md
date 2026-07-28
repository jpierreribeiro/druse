# Protect a form with CSRF

Package `crystals:csrf`, HTTP adapter `crystals:web/csrf`.

A session cookie is attached by the browser to requests the user did not intend
to make. Every mutating endpoint reachable with one needs a token.

## In `main`

```odin
	key := config.reveal(&ld, csrf_key)
	svc, err := csrf.open(transmute([]byte)key)
	if err != .None {
		os.exit(1)
	}
	defer csrf.close(&svc)
	state.csrf = svc
```

**The signing key must be identical on every instance** behind a load balancer,
or a token minted by one is refused by the next. Read it with
`config.var_secret` so it cannot reach a log.

## Issue a token

```odin
	token, ok := csrf_http.issue(ctx, &state.csrf, binding_of(ctx))
```

Put it in the form as a hidden field named `csrf_http.FIELD`, or hand it to a
frontend that returns it in `csrf_http.HEADER`.

## Reject before anything changes

```odin
handler :: proc(ctx: ^web.Context) {
	if csrf_http.reject(ctx, &state.csrf, binding_of(ctx)) {
		return
	}
	// only now does anything change
}
```

`reject` answers for you and returns `true`. It is the first line of the
handler, not the last check before the commit.

`csrf_http.is_mutating` tells you whether a request needs the guard at all, and
`check` verifies without answering when you want to decide yourself.

## Bind the token to the session

```odin
binding_of :: proc(ctx: ^web.Context) -> string {
	token, result := cookie.get(ctx, "session")
	return token if result == .Found else ""
}
```

Binding to the session token gives you two properties free: a token minted for
one session is refused under another, and rotating the session invalidates
every outstanding CSRF token.

The CSRF token is an HMAC over the binding, so holding it does not reveal the
session token.

## Do not guard login

There is no session to forge a request for yet, and requiring a token before
anyone can sign in only locks people out.

## The result enum

`Verify_Result` is `Rejected`, `Accepted`, `Missing`, `Malformed` — and
**`Rejected` is the zero value**, so a result nothing assigned refuses the
request.
