# Ownership and lifetime

**Assumes:** [`../01-concepts/shape-of-an-application.md`](../01-concepts/shape-of-an-application.md).

This chapter teaches one idea: **who owns these bytes, and how long do they
stay valid?** Every other page assumes it.

This is the largest single source of recorded defects. Seven of the thirty
friction-ledger entries are this one class, in seven different packages. Learn
the class once. Do not wait to meet each instance.

## The one idea

A string in Odin is a pointer and a length. It does not own its bytes. Two
kinds cross a package boundary here:

- A **view** points into memory some other value owns. It stays valid exactly
  as long as that owner does.
- A **copy** was allocated by an allocator you named. You own it, and you free
  it.

**A view that outlives its owner does not crash.** It keeps its length, and its
bytes become whatever the memory is reused for. The symptom is not a
segmentation fault. It is a plausible wrong value.

One recorded case: a borrowed subject outlived its record, and the corrupted
string reached a foreign key. The database rejected the write, and the handler
answered as though it had succeeded.

## The rule

**Never return a view from a procedure that owns the thing it points into.**

That sentence covers every shape below.

## Shape 1 — a view into a record

`session.Record` stores its subject inline. `session.subject` returns a view
into it:

```odin
subject :: proc(rec: ^Record) -> string   // a VIEW into rec
subject_clone :: proc(rec: ^Record, allocator := context.allocator) -> string
```

This is wrong. `rec` is a local. It dies at `return`:

```odin
who :: proc(ctx: ^web.Context) -> (string, bool) {
	rec, st := session.resolve(mgr, token)
	if st != .Authenticated {
		return "", false
	}
	return session.subject(&rec), true   // WRONG: view into a dead local
}
```

This is right:

```odin
who :: proc(ctx: ^web.Context, allocator := context.allocator) -> (string, bool) {
	rec, st := session.resolve(mgr, token)
	if st != .Authenticated {
		return "", false
	}
	return session.subject_clone(&rec, allocator), true
}
```

The caller frees the result.

The same pair exists in `auth/api_key`: same hazard, same two names.

`authorization.Principal` is different: it is bounded and inline, so the whole
value is safe to copy into a request-scoped struct. Copy the Principal.

**Why a name and not a warning.** A documented lifetime did not stop the bug. A
named safe path did. When you find a hazard like this in your own code, give
the safe path a name.

## Shape 2 — a lent resource

A connection is lent by the pool. You must give it back:

```odin
	c, e := pg.acquire(&s.pool)
	if pg.is_err(e) {
		web.internal_error(ctx, "database unavailable")
		return
	}
	defer pg.release(&s.pool, &c)
```

Register the `defer` on the line after the error check. Not later. Every path
out of the handler then returns the connection, including the early returns you
add next month.

A leaked connection is not a crash either. It is a pool that shrinks until the
next `acquire` times out, under load, in production.

## Shape 3 — a transaction takes the pool

This is the signature people guess wrong:

```odin
begin :: proc(pool: ^Pool, opts := Tx_Options{}, name := "tx", ...) -> (Tx, Error)
```

`begin` takes `^Pool`. It does not take a `^Conn`. Do not acquire a connection
and pass it: the transaction acquires its own and owns it for its whole life.

Pair `begin` with `rollback_if_open`, deferred:

```odin
	tx, e := pg.begin(&s.pool)
	if pg.is_err(e) {
		return
	}
	defer pg.rollback_if_open(&tx)

	// ... statements ...

	if e := pg.commit(&tx); pg.is_err(e) {
		return
	}
```

`rollback_if_open` after a successful `commit` does nothing. That is what makes
the deferred form safe on every path.

## Shape 4 — a cursor positioned two different ways

`query` and `query_one` both return `Rows`. They are positioned differently.

| Procedure | Cursor starts | You call `rows_next` |
|---|---|---|
| `query` | Before the first row | Yes, to reach each row |
| `query_one` | On its single row | **No.** It steps past the row |

Zero rows from `query_one` is `Row_Not_Found`. More than one is
`Too_Many_Rows`. Both are refused there, so you never check the count.

Read a `query_one` result directly:

```odin
	r, e := pg.query_one(&c, "user_by_email", sql, {pg.text(email)})
	if pg.is_err(e) { return }         // Row_Not_Found when there was none
	defer pg.rows_close(&r)

	hash, te := pg.row_text(&r, 0)     // read directly; no rows_next
```

Close the `Rows` with a `defer`, the same way you release a connection.

## Shape 5 — a decoded column is a copy you own

`row_text` and `row_bytes` allocate. They copy the column into an allocator you
name, and **you free the result**:

```odin
row_text :: proc(r: ^Rows, col: int, allocator := context.allocator, ...) -> (string, Error)
```

`row_i64`, `row_bool` and `row_f64` do not allocate. They return values.

This asymmetry is the whole rule for decoders: **a decoder that returns a
string or a slice allocated it. A decoder that returns a number did not.** See
[`bytes-and-encoding.md`](bytes-and-encoding.md).

## Shape 6 — a request-lifetime view

`web.header` and the path and query extractors return views into the request
buffer. They are valid while the handler runs, and not after.
`web.request_state(ctx, R)` is request-local, fixed storage, and the `^R` must
not escape the request either.

Do not put a request-lifetime view into an app-lived struct. If you need one to
survive, clone it.

## Shape 7 — an arena that swallows its own result

If you write your own temporary arena around a piece of work, the result of
that work is inside the arena:

```odin
	temp_begin(&a)
	out := build_the_answer(&a)   // allocated in the arena
	temp_end(&a)                  // out is now free memory
	return out                    // WRONG
```

Clone the result out before you end the arena, into an allocator that outlives
it. This was a library bug once, and it was fixed. The hazard was not: it is
reproducible in any application that writes its own arena.

## The four questions

When you write a procedure that returns a string or a slice, answer these:

1. Did I allocate it, or is it a view?
2. If it is a view, what owns it, and does that owner outlive my caller?
3. If I allocated it, which allocator, and who frees it?
4. Did I say so, in the signature or in one line above it?

A procedure that cannot answer question 2 returns a clone.
