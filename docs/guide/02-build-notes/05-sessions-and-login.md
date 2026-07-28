# 5 — Sessions, login, and the borrowed subject

**Assumes:** [`04-listing-patch-and-failure.md`](04-listing-patch-and-failure.md).

This chapter narrates `druse-crystals/examples/session`, a complete signed-in
application in one file.

Six Crystals are composed here, and **none of them knows about the others**.
`config` reads the policy. `auth/password` checks the credential.
`auth/session` plus `auth/session_memory` keep the session. `web/session` moves
it in a cookie. `csrf` plus `web/csrf` stop that cookie from being usable by a
request the user did not make.

They meet in exactly one place: your `main`.

## The state, and where it lives

```odin
App_State :: struct {
	sessions:      session.Manager,
	memory:        memory.Memory,
	csrf:          csrf.Service,
	hashing:       password.Limiter,
	demo_user:     string,
	demo_password: string,
}
```

Every long-lived value in the application is a field here. **No Crystal holds
state of its own** — there is no package global inside `auth/session`, and that
is why this struct has to exist.

## Configure first, open nothing yet

```odin
	ld := config.loader("APP_")
	defer config.destroy(&ld)

	port := config.var_int(&ld, "PORT", default = 8080, min = 1, max = 65535)
	absolute_ttl := config.var_duration_ms(&ld, "SESSION_TTL", default = 30 * 24 * 3600 * 1000, min = 1000)
	max_hashes := config.var_int(&ld, "MAX_CONCURRENT_HASHES", default = password.DEFAULT_MAX_CONCURRENT, min = 1)
	csrf_key := config.var_secret(&ld, "CSRF_KEY", required = false)

	if config.failed(&ld) {
		for e in config.errors(&ld) {
			fmt.eprintfln("config: %s: %s", e.name, config.kind_string(e.kind))
		}
		os.exit(2)
	}
```

The prefix is the application's own — pick one and namespace every variable in
that one line.

Nothing is opened until this block passes. A misconfigured deployment exits
before it can half-start.

`CSRF_KEY` is a `Secret`, so it cannot reach a log by accident. **It must be
identical on every instance behind a load balancer**, or a token minted by one
is refused by the next.

The example falls back to a development key and says so loudly on stderr. Copy
the warning, not the fallback: a hardcoded signing key in production is a forged
request waiting to happen.

## Build the store at its final address

```odin
	state.memory = memory.open()
	defer memory.close(&state.memory)

	state.hashing = password.limiter(max_hashes)

	state.sessions, mgr_err = session.manager(
		session.Config{
			absolute_ttl_seconds = absolute_ttl / 1000,
			idle_ttl_seconds     = idle_ttl / 1000,
			token_bytes          = 32,
		},
		memory.store(&state.memory),
	)
	if mgr_err != .None {
		os.exit(2)
	}
```

Read the first line again. `state.memory` is assigned **at its final address**,
and only then does `memory.store(&state.memory)` take its pointer.

Build the store in a local and copy it into `state` afterwards, and the manager
holds a pointer to the local. This is
[`../04-rules/ownership-and-lifetime.md`](../04-rules/ownership-and-lifetime.md)
again, in the composition root rather than in a handler.

`session.manager` validates the policy and refuses. Check `mgr_err`.

The store is in memory, so a restart signs everybody out. Swapping in
`auth/session_postgres` is one line, at the `store` call. That is what the
`Store` contract is for.

## Login: the four answers

```odin
	if input.user != state.demo_user {
		web.text(ctx, .Unauthorized, "invalid credentials")
		return
	}

	switch password.verify_limited(&state.hashing, state.demo_password, input.password) {
	case .Valid, .Valid_Needs_Rehash:
		// Valid_Needs_Rehash would also re-hash and store here.
	case .Too_Busy:
		web.set_header(ctx, "Retry-After", "1")
		web.text(ctx, .Service_Unavailable, "busy, retry shortly")
		return
	case .Invalid:
		web.text(ctx, .Unauthorized, "invalid credentials")
		return
	case .Malformed_Hash:
		web.text(ctx, .Internal_Server_Error, "account is unusable")
		return
	}
```

Four things worth stopping on.

**A wrong user and a wrong password are answered identically.** The endpoint
does not report which accounts exist.

**`Too_Busy` is a `503`, never a `401`.** The credential was never examined, so
answering "invalid" would tell a user with the correct password that it is
wrong — under load, which is the worst possible moment. `Retry-After` makes the
answer actionable. This is the case from
[`../04-rules/result-vocabularies.md`](../04-rules/result-vocabularies.md) that
costs you real users when you get it wrong.

**`Malformed_Hash` is an operator problem, not a failed login.** The stored
value is corrupt. A `401` would send the user to reset a password that was
never wrong.

**Hashing runs under a limiter.** Each verification holds `memory_kib` for its
duration, and `/login` is reachable without an account. Without a bound, a POST
flood is a memory-exhaustion attack rather than a failed login. `password.hash`
is deliberately expensive; the limiter is what keeps that from being turned
against you.

## Establishing the session

```odin
	switch session_http.establish(ctx, &state.sessions, input.user) {
	case .Ok:
		web.text(ctx, .OK, "signed in")
	case .Too_Many_Sessions:
		web.text(ctx, .Too_Many_Requests, "too many active sessions; sign out elsewhere first")
	case .Bad_Subject, .Store_Failed, .Cookie_Refused, .Refused:
		web.text(ctx, .Internal_Server_Error, "could not start a session")
	}
```

`Too_Many_Sessions` means the password was right. Say so, and say what to do.
It is a `429`, not a `401`.

Recall from [`../04-rules/configuration.md`](../04-rules/configuration.md) that
the cap **refuses** and never evicts. That is what stops an attacker from using
repeated logins to push a real session out.

## Reading who the user is

```odin
me :: proc(ctx: ^web.Context) {
	rec, status := session_http.current(ctx, &state.sessions)
	switch status {
	case .Authenticated:
		web.text(ctx, .OK, session.subject(&rec))
	case .Anonymous, .Invalid, .Expired:
		web.text(ctx, .Unauthorized, "sign in")
	case .Store_Failed:
		web.text(ctx, .Service_Unavailable, "try again")
	}
}
```

**This is the borrowed subject, used correctly.** `session.subject(&rec)`
returns a view into `rec`, and `rec` is alive for the whole `switch`. The value
is written to the response before the handler returns.

Move that same call into a helper that *returns* the string and it becomes
use-after-return, silently. That is Shape 1 in
[`../04-rules/ownership-and-lifetime.md`](../04-rules/ownership-and-lifetime.md),
and `session.subject_clone` is the fix.

`Store_Failed` is a `503`. The backend could not answer, so refuse rather than
guess. It is not a forged token.

## CSRF: guard before anything changes

```odin
logout :: proc(ctx: ^web.Context) {
	if csrf_http.reject(ctx, &state.csrf, binding_of(ctx)) {
		return
	}
	session_http.revoke_current(ctx, &state.sessions)
	web.text(ctx, .OK, "signed out")
}
```

The guard runs **before** anything changes, and `reject` answers for you when it
returns `true`.

A session cookie is attached by the browser to requests the user did not intend
to make. Every mutating endpoint is guarded. `/login` is the deliberate
exception: there is no session to forge a request for yet, and requiring a token
before anyone can sign in only locks people out.

## What the token is bound to

```odin
binding_of :: proc(ctx: ^web.Context) -> string {
	token, result := cookie.get(ctx, "session")
	return token if result == .Found else ""
}
```

The CSRF token is bound to the session token itself. Two consequences you get
for free: a token minted for one session is refused under another, and rotating
the session invalidates every outstanding CSRF token.

The CSRF token is an HMAC over the binding, so holding it does not reveal the
session token.

## Next

The build-along stops here for now. `03-build-intake/` — jobs, mail, storage,
idempotency and SSE — is not written. See
[`../README.md`](../README.md) for what else the guide does not yet teach.
