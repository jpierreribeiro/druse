# Store a password

Package `crystals:auth/password`.

Never store a password. Store something you can check a password against.

## Hash on registration

```odin
	stored, err := password.hash(candidate)
	if err != .None {
		web.internal_error(ctx)
		return
	}
	defer delete(stored)
```

`stored` is a string **you own** — put it in the database and free your copy.
The salt is generated for you and travels inside it: no separate column, and
nothing for you to generate.

## Verify on login

```odin
	switch password.verify(stored, candidate) {
	case .Valid, .Valid_Needs_Rehash:
		// let them in
	case .Invalid:
		web.unauthorized(ctx, "invalid credentials")
		return
	case .Malformed_Hash:
		web.internal_error(ctx)
		return
	case .Too_Busy:
		web.set_header(ctx, "Retry-After", "1")
		web.text(ctx, .Service_Unavailable, "busy, retry shortly")
		return
	}
```

**`Invalid` is the zero value**, so a result nothing assigned denies.

**`Valid_Needs_Rehash` is a success.** The password is right and the stored hash
is below the current policy. Let them in, then rehash with the new policy and
store it — that is how a policy change reaches existing accounts.

**`Malformed_Hash` is an operator problem**, not a failed login: `401` sends
the user to reset a password that was never wrong.

## Bound the work, or it becomes a weapon

`password.hash` is **deliberately expensive** — that is what makes it worth
anything. Each call holds `memory_kib` for its duration, and `/login` is
reachable without an account. Without a bound, a POST flood is memory
exhaustion rather than a failed login:

```odin
	state.hashing = password.limiter(max_concurrent)
	// ...
	r := password.verify_limited(&state.hashing, stored, candidate)
```

`Too_Busy` means **nothing was hashed** — the limiter was full. It is a `503`,
never a `401`, because the credential was never examined. Answering "invalid"
tells a user with the correct password that it is wrong, under load.

`password.in_flight` reports how many are running, for a metric.

## Choose the ceiling deliberately

Your login memory ceiling is `max_concurrent × memory_kib`. Both are yours to
pick; the default policy is a starting point, not a measurement of your machine.

`DEFAULT_POLICY` bounds every parameter — `MIN_MEMORY_KIB`, `MAX_PASSES`,
`MAX_PARALLELISM`. A cost outside them is `Bad_Policy`, refused at the call
rather than accepted and quietly weak.

## Answer both failures the same way

A wrong user and a wrong password must be **indistinguishable**, or the endpoint
reports which accounts exist. Same status, same body, same timing as far as you
can manage.
