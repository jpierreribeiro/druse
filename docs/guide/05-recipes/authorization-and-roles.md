# Authorization and roles

Package `crystals:authorization`, HTTP adapter `crystals:web/authorization`.

Authentication asks *who are you*; authorization asks *may you do this*. They
are different packages for that reason.

## A policy is a procedure

**No DSL, no policy registry.** A policy takes what it needs and returns a
`Decision`:

```odin
can_edit :: proc(p: ^authorization.Principal, note_owner: string) -> authorization.Decision {
	return authorization.require_owner(p, note_owner, {"admin"})
}
```

A rules language would re-invent conditionals and comparison, be unreadable in
a debugger, and could not see your own types.

## Build the principal from the identity you resolved

```odin
	p, ok := authorization.principal(subject)
	if !ok {
		p = authorization.anonymous()
	}
	authorization.grant_role(&p, "editor")
	authorization.grant_scope(&p, "notes:write")
```

A `Principal` is bounded and stored **inline** — so it is a plain value with no
ownership question. Copy it freely.

**Grant roles from your user table, per request.** A role frozen into a session
row means a revoked privilege keeps working until the session expires.

## The five rules you get

| Call | Denies when |
|---|---|
| `require_authenticated` | There is no principal |
| `require_role(p, "admin")` | The role is absent |
| `require_any_role(p, {"a","b"})` | None of them is held |
| `require_scope(p, "notes:write")` | The token lacks the scope |
| `require_owner(p, owner, {"admin"})` | Not the owner, and no override role |

**An empty set in `require_any_role` denies.** Reading "any of nothing" as
*allow* would turn a mistakenly empty list into an open door.

`all_of` returns the **first** denial, so the reason survives:

```odin
	d := authorization.all_of(
		authorization.require_authenticated(&p),
		authorization.require_scope(&p, "notes:write"),
		authorization.require_owner(&p, note.owner, {"admin"}),
	)
```

## Answer with the adapter

```odin
	if authz.reject(ctx, d) {
		return
	}
```

It answers `401` for `Anonymous` and `403` otherwise, returning `true` when it
answered.

## The reason never reaches the client

`Decision` carries a `Reason` — `Not_Owner`, `Missing_Role`, `Missing_Scope` —
and it is a **closed enum so it cannot become a string in a response body**.

Telling a caller *why* leaks the shape of your authorization model, and
sometimes that a record exists at all. `web/authorization` never puts it on the
wire. Log it — that is what it is for.

## Why a struct and not a bool

`if d.allowed` reads unambiguously at every call site; `if !can_edit(...)` on a
bare bool inverts too easily. `Reason.Unspecified` is the zero value and pairs
with `allowed = false`, so a `Decision` nothing assigned **denies**.
