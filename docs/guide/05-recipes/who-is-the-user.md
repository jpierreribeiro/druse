# Find out who the user is

**Assumes:** [`../02-build-notes/05-sessions-and-login.md`](../02-build-notes/05-sessions-and-login.md).

The single most defect-prone helper in an application built on Druse. Write it
once, correctly, and copy it.

## Use it inside the handler

```odin
me :: proc(ctx: ^web.Context) {
	rec, status := session_http.current(ctx, &state.sessions)
	if status != .Authenticated {
		web.unauthorized(ctx, "sign in")
		return
	}
	web.text(ctx, .OK, session.subject(&rec))   // safe: rec is still alive
}
```

`rec` lives until the handler returns, and the response is written first.

## Return it from a helper — the wrong way

```odin
who :: proc(ctx: ^web.Context) -> (string, bool) {
	rec, st := session_http.current(ctx, &state.sessions)
	if st != .Authenticated {
		return "", false
	}
	return session.subject(&rec), true      // WRONG
}
```

`rec` is a local and dies at `return`. The string keeps its length; its bytes
become whatever the stack is reused for.

**This does not crash.** It produces a plausible wrong value. The recorded
case: the corrupted subject reached a foreign key, the database rejected the
write, and the handler answered as though it had succeeded.

## Return it from a helper — the right way

```odin
who :: proc(ctx: ^web.Context, allocator := context.allocator) -> (string, bool) {
	rec, st := session_http.current(ctx, &state.sessions)
	if st != .Authenticated {
		return "", false
	}
	return session.subject_clone(&rec, allocator), true
}
```

The caller owns the result. Pass the handler's arena as the allocator and it
goes away with the request.

## Handle the four statuses, not two

```odin
	switch status {
	case .Authenticated:
	case .Anonymous, .Invalid, .Expired:
		web.unauthorized(ctx, "sign in")
		return
	case .Store_Failed:
		web.text(ctx, .Service_Unavailable, "try again")   // NOT a 401
		return
	}
```

`Store_Failed` means the backend could not answer. Refuse rather than guess: a
`401` there tells a signed-in user they are not.

`auth/api_key` has the identical pair — `subject` borrows, `subject_clone`
copies. Same hazard, same fix.

## See also

- [`../04-rules/ownership-and-lifetime.md`](../04-rules/ownership-and-lifetime.md)
  — the rule this recipe is one instance of.
