# Paginate a list

**Assumes:** [`../02-build-notes/04-listing-patch-and-failure.md`](../02-build-notes/04-listing-patch-and-failure.md).

A list endpoint that returns everything works until the table has ten thousand
rows. Then it never works again.

## Paginate by key, not by offset

```odin
	rows, qe := pg.query(
		&c,
		"notes.list",
		"SELECT " + COLUMNS + " FROM notes WHERE id > $1 ORDER BY id ASC LIMIT $2",
		{pg.arg_i64(after), pg.arg_i64(limit)},
		pg.Query_Opts{max_rows = 100},
	)
```

The client sends `?after=<last id seen>`. You return the last id as
`next_after`.

**Why not `OFFSET`.** `OFFSET 10000` makes the database walk 10000 rows to throw
them away, so page 500 costs 500 times page 1. And a row inserted while the user
pages shifts every later page by one, so they see a record twice or miss one.

Keyset has neither problem. The cost of any page is the cost of the first.

**The order must be total.** `ORDER BY id` is total because `id` is unique.
`ORDER BY created_at` is not — two rows in the same second are tied, and a tie
makes the page boundary arbitrary. Sort by the column you want, then by the
primary key:

```sql
ORDER BY created_at DESC, id DESC
```

Your cursor then carries both values.

## Bound the page twice

```odin
	limit, ok := web.query_int_or(ctx, "limit", 20)
	if !ok { return }
	limit = clamp(limit, 1, 100)
```

The clamp bounds what the client asked for. `Query_Opts{max_rows = 100}` bounds
what the database may hand back **even if the SQL is wrong**. You want both.

## Say what the next page is

```odin
List_Response :: struct {
	notes:      []Note `json:"notes"`,
	next_after: i64    `json:"next_after"`,
}
```

Return the cursor. A client that has to compute it from the last element is a
client that will get it wrong when you add sorting.

## See also

- [`filter-sort-and-search.md`](filter-sort-and-search.md) — narrowing the list
  without opening an injection.
