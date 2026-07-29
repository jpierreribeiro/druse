# Filter, sort and search

**Assumes:** [`paginate-a-list.md`](paginate-a-list.md).

Three ways to narrow a list, and the one rule that keeps all three safe: **a
client value is a parameter, never syntax.**

## Filter with parameters, never with concatenation

```odin
	sql := "SELECT " + COLUMNS + " FROM notes WHERE id > $1 AND author = $2 ORDER BY id ASC LIMIT $3"
	rows, qe := pg.query(&c, "notes.by_author", sql, {pg.arg_i64(after), pg.arg_text(author), pg.arg_i64(limit)})
```

**A value never enters the SQL string.** `pg.arg_text` makes it a parameter, and
a parameter cannot become syntax — that is what closes SQL injection, and it is
closed by construction rather than by escaping carefully.

The SQL text itself is a compile-time constant. Concatenating a *value* into it
is the bug; concatenating a column list constant is not.

## Sort from an allow-list

A column name cannot be a parameter — it is syntax, not a value. So an allow-list
is the only safe way:

```odin
order_clause :: proc(sort: string) -> string {
	switch sort {
	case "oldest": return " ORDER BY id ASC"
	case "newest": return " ORDER BY id DESC"
	}
	return " ORDER BY id ASC"      // the default, for anything unrecognised
}
```

**Never interpolate a client string into `ORDER BY`.** A `switch` returning a
constant is the whole defence, and it costs four lines.

Return the default for an unknown value rather than a `400`, unless your API
promises otherwise — a client sending `?sort=newst` gets a list, not a puzzle.

## Search

For a prefix or substring, use a parameter and let PostgreSQL do the work:

```sql
WHERE title ILIKE $2 || '%'
```

Keep the wildcard in the SQL and the user's text in the parameter. Building
`'%' + input + '%'` in Odin puts user bytes next to syntax again.

For real full-text search, use `tsvector` and an index. `ILIKE` without an index
scans the table, which is fine for a thousand rows and not for a million.

## See also

- [`../04-rules/bytes-and-encoding.md`](../04-rules/bytes-and-encoding.md) —
  `db/sqlcheck` prepares each named query against a real schema.
