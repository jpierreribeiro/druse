# 4 — Listing, PATCH, and one place for failure

**Assumes:** [`03-handlers-and-validation.md`](03-handlers-and-validation.md).

The three verbs that are not a plain read, and the procedure every one of them
calls when the database says no.

## Listing: bound the page, and bound the query

```odin
	limit, _ := web.query_int_or(ctx, "limit", 20)
	if limit < 1  { limit = 1 }
	if limit > 100 { limit = 100 }
	after, _ := web.query_int_or(ctx, "after", 0)

	rows, qe := pg.query(
		&c,
		"notes.list",
		"SELECT " + NOTE_COLUMNS + " FROM notes WHERE id > $1 ORDER BY id ASC LIMIT $2",
		{pg.arg_i64(i64(after)), pg.arg_i64(i64(limit))},
		pg.Query_Opts{max_rows = 100},
	)
	defer pg.rows_close(&rows)
```

Two independent bounds, and you want both. The clamp bounds what the client
asked for. `Query_Opts{max_rows = 100}` bounds what the database may hand back
even if the SQL is wrong.

Keyset pagination, not `OFFSET`: `WHERE id > $1 ORDER BY id ASC`. The order is
total on the primary key, so a page is stable while rows are inserted.

```odin
	list := make([dynamic]Note, ally)
	next_after := i64(after)
	for pg.rows_next(&rows) {
		n := scan_note(&rows, ally)
		next_after = n.id
		append(&list, n)
	}
	web.ok(ctx, List_Response{notes = list[:], next_after = next_after})
```

`make([dynamic]Note, ally)` puts the slice in the arena too, so nothing is
freed by hand. This is a `query` cursor, so `rows_next` is correct — a
`query_one` result is positioned differently.

## PATCH: three states, one statement

A PATCH has to distinguish three intents per field: leave it, clear it, replace
it. `validate.Patch(T)` models exactly that — `Absent`, `Null`, `Set`:

```odin
	validate.deny_null(&v, "title", title_p.state) // title is not nullable
	if title_p.state == .Set {
		validate.not_empty(&v, "title", title_p.value)
		validate.string_length(&v, "title", title_p.value, min = 1, max = 200)
	}
```

`title` is `NOT NULL` in the schema, so `deny_null` refuses an explicit `null`
at the edge rather than letting the database refuse it later.

All three intents go into one statement:

```odin
	"UPDATE notes SET " +
	"title = CASE WHEN $2 THEN $1 ELSE title END, " +
	"body = CASE WHEN $4 THEN $3 ELSE body END " +
	"WHERE id = $5 RETURNING " + NOTE_COLUMNS
```

One statement, no dynamic SQL assembly, a fixed parameter list. A `present`
boolean per column carries the intent.

## Delete: rows affected

```odin
	cmd, qe := pg.execute(&c, "notes.delete", "DELETE FROM notes WHERE id = $1", {pg.arg_i64(i64(id))})
	if pg.is_err(qe) {
		respond_db_error(ctx, qe)
		return
	}
	if cmd.rows_affected == 0 {
		web.not_found(ctx, "note")
		return
	}
	web.no_content(ctx)
```

`execute` is for a statement with no result set, and `rows_affected` is how you
learn the row was not there.

## One place that maps database failure to status

```odin
respond_db_error :: proc(ctx: ^web.Context, e: pg.Error) {
	#partial switch e.kind {
	case .Pool_Exhausted, .Timeout, .Canceled, .Connection_Lost:
		// the service is temporarily unavailable — 503
	case:
		web.internal_error(ctx)
	}
}
```

Read which errors are grouped. Pool exhaustion, a timeout, a cancellation and a
lost connection are all **temporary**, and they are a `503`. Everything else is
a `500`.

That distinction is what lets a load balancer do the right thing. A `500` says
the request is broken. A `503` says come back.

> **The reference program is one revision behind here.** It writes
> `web.Status(503)` and `web.Status(409)` as raw casts. The named members
> `.Service_Unavailable` and `.Conflict` now exist in `web.Status`, added by
> corrective WP C1. Write the named members. The cast compiles and any typo in
> it compiles too.

## Next

[`05-sessions-and-login.md`](05-sessions-and-login.md) — who the user is, and
the borrowed string that must not escape.
