# Result vocabularies

**Assumes:** [`../01-concepts/core-and-crystals.md`](../01-concepts/core-and-crystals.md).

One handler can switch on five different result enums. They do not share a
success name. This page is the table that tells you which is which.

## The one rule they do share

**The zero value is always the safe one.**

A result that nothing assigned — because a branch was missed, or a struct was
default-initialized — denies, refuses or reports failure. It never grants and
never reports success.

This is a rule about correctness under a mistake, not about style. Read it as a
guarantee you can rely on: an uninitialized `Verify_Result` will not log
somebody in.

## The table

| Package | Type | Zero value | Success value | Other values |
|---|---|---|---|---|
| `auth/password` | `Verify_Result` | `Invalid` | `Valid` | `Valid_Needs_Rehash`, `Malformed_Hash`, `Too_Busy` |
| `csrf` | `Verify_Result` | `Rejected` | `Accepted` | `Missing`, `Malformed` |
| `auth/session` | `Status` | `Anonymous` | `Authenticated` | `Expired`, `Invalid`, `Store_Failed` |
| `auth/session` | `Store_Result` | `Failed` | `Ok` | `Not_Found`, `Conflict` |
| `idempotency` | `Outcome` | `Failed` | `Proceed` | `In_Progress`, `Replay`, `Conflict` |
| `authorization` | `Decision` | `allowed = false` | `allowed = true` | `reason: Reason` |

Five success names for the same idea: `Valid`, `Accepted`, `Authenticated`,
`Ok`, `Proceed`. There is no `Success` and there is no shared alias.

This is recorded in [`../FIXES-WANTED.md`](../FIXES-WANTED.md). Until it is
resolved, read the table.

## Why they are not one enum

Each type is closed around what its package can actually report. A single
shared enum would have to hold every member of every package, and then every
`switch` would carry cases that cannot happen.

The cost is this page. The benefit is that a `switch` on `Verify_Result` is
exhaustive and the compiler checks it.

## Handle every case, not just the success one

Each non-success value means something different, and two of them are not
failures of the credential:

```odin
	switch password.verify(&limiter, stored_hash, candidate) {
	case .Valid:
		// proceed
	case .Valid_Needs_Rehash:
		// proceed, AND rehash at the current policy
	case .Too_Busy:
		// the limiter was full; NOTHING was verified. This is a 503, not a 401.
	case .Malformed_Hash:
		// the stored value is not a hash this package can read
	case .Invalid:
		// wrong password
	}
```

Read `Too_Busy` again. It is not a wrong password. Answering `401` for it tells
a user their correct password is wrong, under load, which is the worst possible
moment.

`Valid_Needs_Rehash` is a success. The password is correct and the stored hash
is below the current policy. Let the user in, then rehash.

The same shape applies to `session.Status`:

- `Store_Failed` means the backend could not answer. Treat it as
  unauthenticated. Do not treat it as a forged token.
- `Expired` and `Invalid` are different facts. `Expired` existed and its time is
  up. `Invalid` was presented and no such session exists — revoked, or forged.

## A decision carries its reason, and the reason stays home

`authorization.Decision` is a struct, not a bool:

```odin
Decision :: struct {
	allowed: bool,
	reason:  Reason,
}
```

It is a struct for two reasons. A denial can carry its reason to a log without
a second return value. And `if d.allowed` reads unambiguously at every call
site, where `if !can_edit(...)` on a bare bool inverts too easily.

**The reason never goes to the client.** `Reason` is a closed enum so that it
cannot become a string in a response body. Telling a caller why they were
denied leaks the shape of your authorization model, and sometimes leaks that a
record exists.

The HTTP adapter in `web/authorization` never puts it on the wire. Log it.

## Errors are a separate thing

`Error_Kind` is not a result. A result reports the outcome of an operation that
worked. An `Error_Kind` reports that the call could not be made:

```odin
Error_Kind :: enum {
	None,
	Bad_Config,
	Bad_Subject,
	Too_Many_Sessions,
	Store_Failed,
}
```

`None` is the zero value here, and it means no error. That is the opposite
polarity from a result enum, and it is correct for the same reason: a zeroed
`Error_Kind` beside an unassigned result yields "no error, and a result that
denies".

Do not switch on an `Error_Kind` to decide whether a user is authenticated.
Switch on the `Status`.

## What to do when you add your own

Follow the rule at the top. Put the safe value at zero. Name it for what it
means in your domain, not `Success` — the framework's own five names are
different because their domains are.
