# Soft delete, timestamps and audit

**Assumes:** [`../02-build-notes/02-database-and-migrations.md`](../02-build-notes/02-database-and-migrations.md).

None of this is framework behaviour — it is schema and SQL you write, which is
why nothing does it for you.

## Timestamps

```sql
created_at timestamptz NOT NULL DEFAULT now(),
updated_at timestamptz NOT NULL DEFAULT now()
```

Use `timestamptz`, never `timestamp`: without the zone you store a moment that
means something different depending on who reads it. Set `updated_at` in the
`UPDATE` itself, so it cannot be forgotten:

```sql
UPDATE notes SET title = $1, updated_at = now() WHERE id = $2 RETURNING ...
```

## Soft delete

```sql
deleted_at timestamptz
```

Nullable. `NULL` means alive.

```sql
UPDATE notes SET deleted_at = now() WHERE id = $1 AND deleted_at IS NULL
```

**Every other query must now exclude them**, and that is the whole cost:

```sql
SELECT ... FROM notes WHERE id > $1 AND deleted_at IS NULL ORDER BY id ASC
```

Forget it in one query and deleted rows return in one endpoint. No framework
switch adds this clause — keep it beside your column-list constant, so a new
query starts from something correct.

**A unique index must exclude them too**, or a slug can never be reused:

```sql
CREATE UNIQUE INDEX notes_slug_live ON notes (slug) WHERE deleted_at IS NULL;
```

## Which one to use

**Soft delete when you need the row back** — an audit obligation, an undo, a
foreign key pointing at it. **Hard delete otherwise.** Every query grows a
clause and the table never shrinks; choosing it because it feels safer is how a
table reaches ten million rows of which two million are dead.

A deletion request under privacy law usually means **hard** delete.

## Audit

```sql
CREATE TABLE audit_log (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    subject     text NOT NULL,
    action      text NOT NULL,
    entity_id   bigint,
    at          timestamptz NOT NULL DEFAULT now()
);
```

Write it **in the same transaction** as the change, or you get a change with no
record and a record with no change:

```odin
	tx, e := pg.begin(&s.pool)
	if pg.is_err(e) { return }
	defer pg.rollback_if_open(&tx)
	// the UPDATE and the audit INSERT, then:
	if e := pg.commit(&tx); pg.is_err(e) { return }
```

Store the **subject**, not a borrowed view of it — see
[`who-is-the-user.md`](who-is-the-user.md). Never log a value that is a secret:
an audit table is usually the one with the loosest access.
