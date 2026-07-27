# Authenticate with an API key

Package `crystals:auth/api_key`, HTTP adapter `crystals:web/api_key`.

For machine callers. For humans in a browser, use a session — see
[`../02-build-notes/05-sessions-and-login.md`](../02-build-notes/05-sessions-and-login.md).

## Issue

```odin
	issued, err := api_key.issue(&mgr, subject, label)
	if err != .None {
		return
	}
	defer api_key.destroy_issued(&issued)
```

**`Issued` carries the only copy of the secret.** Show it to the caller once
and never again — the store keeps a hash, not the key.

`destroy_issued` frees it. Call it.

## Verify

```odin
	rec, status := api_key.verify(&mgr, presented)
	switch status {
	case .Authenticated:
	case .Anonymous, .Invalid, .Expired, .Revoked:
		web.unauthorized(ctx, "invalid key")
		return
	case .Store_Failed:
		web.text(ctx, .Service_Unavailable, "try again")
		return
	}
```

`Status` puts `Anonymous` at zero, so an unassigned status is not an
authenticated caller.

`Store_Failed` is a `503`, not a `401` — the backend could not answer, so refuse
rather than guess.

## The subject is borrowed

```odin
	s := api_key.subject_clone(&rec, allocator)     // to keep it
	_ = api_key.subject(&rec)                       // view; dies with rec
```

Identical hazard and identical fix to `auth/session`. See
[`who-is-the-user.md`](who-is-the-user.md).

`label` and `label_clone` are the same pair.

## Scopes

```odin
	if !api_key.has_scope(&rec, "notes:write") {
		web.forbidden(ctx, "insufficient scope")
		return
	}
```

`scope_count` and `scope_at` iterate; `set_scopes_csv` sets them when issuing.
Scopes are bounded and stored inline, so a `Record` stays a plain value with
nothing to free.

## Revoke

`revoke` ends one key; `revoke_all` ends every key for a subject. Both are what
you reach for when a key leaks, so make sure an operator can run them without
you.

## The prefix

`DEFAULT_PREFIX` prefixes every issued key. It is how somebody scanning a leaked
config file recognises what they found — and how a secret scanner matches it.

Set it to something specific to your service.
