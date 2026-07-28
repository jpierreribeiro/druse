# 3 — Handlers, strict input, and NULL that survives

**Assumes:** [`02-database-and-migrations.md`](02-database-and-migrations.md).

The five routes, and one handler written end to end. Every line is in
`druse-crystals/examples/notes/notes.odin`.

This chapter is the shape every handler repeats: decode strictly, validate,
acquire a connection, do the work, answer. The next one takes the harder
verbs.

## The routes

```odin
register :: proc(app: ^web.App) {
	web.post(app, "/notes", create_note)
	web.get(app, "/notes", list_notes)
	web.get(app, "/notes/:id", get_note)
	web.patch(app, "/notes/:id", patch_note)
	web.delete(app, "/notes/:id", delete_note)
}
```

These routes belong to the application, so it registers them directly. A
detached router is for a package that hands routes to *somebody else*.

A static route always wins over a parametric one, whatever the registration
order. `/notes` and `/notes/:id` do not compete.

## The type, and the one field that matters

```odin
Note :: struct {
	id:         i64            `json:"id"`,
	slug:       string         `json:"slug"`,
	title:      string         `json:"title"`,
	body:       Maybe(string)  `json:"body"`, // JSON null when the column is NULL
	created_at: string         `json:"created_at"`,
}
```

`body` is `Maybe(string)` because the column is nullable. `NULL` in the
database becomes `null` in the JSON, and neither becomes `""` in between.

## Create: decode, validate, then touch the database

```odin
create_note :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	input: Create_Note
	if !web.body(ctx, &input) {
		return // web.body already committed the strict-decode error
	}

	v := validate.validator()
	defer validate.destroy(&v)
	validate.not_empty(&v, "slug", input.slug)
	validate.string_length(&v, "slug", input.slug, min = 1, max = 64)
	validate.not_empty(&v, "title", input.title)
	validate.string_length(&v, "title", input.title, min = 1, max = 200)
	if vh.respond_if_invalid(ctx, &v) {
		return
	}
	// ...
}
```

Read the order. **Nothing reaches the database until the input is known good.**
A malformed body never costs you a connection.

`web.body` is strict: a wrong type, an undeclared key or an oversized body is
answered before your first line runs.

`validate` knows nothing about HTTP. It collects typed field errors — a stable
rule code and a field path, never the user's value. `vh.respond_if_invalid` is
the thin adapter onto the error envelope, and it returns `true` when it
answered. `validate.destroy(&v)` frees the accumulated error set: the one
`destroy` in Crystals that means a *value*, not a resource.

## Acquire, then defer, then work

```odin
	c, ae := pg.acquire(&st.db)
	if pg.is_err(ae) {
		respond_db_error(ctx, ae)
		return
	}
	defer pg.release(&st.db, &c)

	arena: virtual.Arena
	ally := handler_arena(&arena)
	defer virtual.arena_destroy(&arena)
```

Four lines that repeat in every handler. Learn them as one unit. The arena is
a per-handler allocator: everything the response is built from lives in it and
goes away whole when the handler returns.

**This is the arena hazard done right.** The rule in
[`../04-rules/ownership-and-lifetime.md`](../04-rules/ownership-and-lifetime.md)
is that an arena must not outlive the result built inside it. Here it does not:
`web.created(ctx, scan_note(&r, ally))` serializes the value *during the call*,
and only then does the deferred `arena_destroy` run. Order is what makes it
safe.

## An optional field becomes a parameter, explicitly

```odin
	body_param := pg.arg_null()
	if b, has := input.body.?; has {
		body_param = pg.arg_text(b)
	}
	r, qe := pg.query_one(
		&c,
		"notes.insert",
		"INSERT INTO notes (slug, title, body) VALUES ($1, $2, $3) RETURNING " + NOTE_COLUMNS,
		{pg.arg_text(input.slug), pg.arg_text(input.title), body_param},
	)
	defer pg.rows_close(&r)
```

`pg.arg_null()` and `pg.arg_text()` are how a value becomes a parameter. There
is no implicit conversion, and the SQL string never carries a value.

Every query is **named**. The name is what `db/sqlcheck` prepares against a real
migrated database, and what an error carries so you know which statement
failed.

## A constraint violation is a typed error, not a string match

```odin
	if pg.is_err(qe) {
		if qe.kind == .Unique_Violation {
			respond_conflict(ctx)
			return
		}
		respond_db_error(ctx, qe)
		return
	}
	web.created(ctx, scan_note(&r, ally))
```

`Unique_Violation` is a member of a closed enum. You never parse a PostgreSQL
message to find out what happened.

`Row_Not_Found` works the same way in `get_note`:

```odin
	if pg.is_err(qe) {
		if qe.kind == .Row_Not_Found {
			web.not_found(ctx, "note")
			return
		}
		respond_db_error(ctx, qe)
		return
	}
```

`query_one` refuses zero rows and refuses more than one, so you never count.

## Scanning a row

```odin
scan_note :: proc(r: ^pg.Rows, allocator: runtime.Allocator) -> Note {
	id, _ := pg.row_i64(r, 0)
	slug, _ := pg.row_text(r, 1, allocator)
	title, _ := pg.row_text(r, 2, allocator)
	body, _ := pg.row_opt_text(r, 3, allocator)
	created, _ := pg.row_text(r, 4, allocator)
	return Note{id = id, slug = slug, title = title, body = body, created_at = created}
}
```

The allocator is passed in, not assumed, so every string lives in the caller's
arena. `row_opt_text` is what keeps `NULL` alive as `NULL`; `row_text` on a null
column is `Decode_Null`, an error, not a quiet `""`.

## Next

[`04-listing-patch-and-failure.md`](04-listing-patch-and-failure.md) — the
harder verbs, and one place that maps database failure to status.
