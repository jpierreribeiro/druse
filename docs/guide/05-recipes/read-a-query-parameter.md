# Read a query parameter

**Assumes:** you have a handler.

Four extractors. They differ in **what happens when the parameter is missing**,
and that is the only thing you have to get right.

```odin
query         :: proc(ctx: ^Context, name: string) -> (value: string, found: bool)
query_int     :: proc(ctx: ^Context, name: string) -> (value: int, ok: bool)
query_int_opt :: proc(ctx: ^Context, name: string) -> (value: int, present: bool, ok: bool)
query_int_or  :: proc(ctx: ^Context, name: string, default_value: int) -> (value: int, ok: bool)
```

## Which one

| You want | Use | Missing means |
|---|---|---|
| A string, optional | `query` | `found = false`. Nothing is sent. |
| An integer, **required** | `query_int` | `ok = false`, **and a 400 is already sent** |
| An integer, optional, and you must know if it was there | `query_int_opt` | `present = false`, `ok = true`. Nothing is sent. |
| An integer with a default | `query_int_or` | You get the default, `ok = true` |

**Read the second row again.** `query_int` treats a missing parameter as a
client error and answers `400` itself. The other three treat missing as normal.

## Required

```odin
	page, ok := web.query_int(ctx, "page")
	if !ok {
		return          // the 400 is already committed
	}
```

## Optional, with a default

```odin
	limit, ok := web.query_int_or(ctx, "limit", 20)
	if !ok {
		return          // present but not a number — 400 already sent
	}
	limit = clamp(limit, 1, 100)
```

`ok = false` here means the parameter **was** present and was not an integer —
still a client error, still already answered.

**Clamp the value.** A default bounds the absent case, not `?limit=1000000`.

## Optional, and absence is meaningful

```odin
	after, present, ok := web.query_int_opt(ctx, "after")
	if !ok {
		return
	}
	if present {
		// paginate from `after`
	} else {
		// first page
	}
```

Use this when zero is legitimate and cannot serve as a sentinel.

## Strings

`web.query` returns `(value, found)` and never answers for you. There is no
`query_or` for strings.

**The string is a view** into the request buffer, valid while the handler runs
and not after. Clone it if it must outlive the request — see
[`../04-rules/ownership-and-lifetime.md`](../04-rules/ownership-and-lifetime.md).

## See also

- [`error-responses.md`](error-responses.md) — why you return without writing.
