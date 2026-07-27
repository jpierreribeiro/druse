# Bytes and encoding

**Assumes:** [`ownership-and-lifetime.md`](ownership-and-lifetime.md).

Who allocated this, and what encoding is it in? Two questions, one page.

## Which calls allocate

The rule from
[`ownership-and-lifetime.md`](ownership-and-lifetime.md), stated as a table:

| Call | Allocates | You free it |
|---|---|---|
| `pg.row_text`, `pg.row_bytes` | Yes | Yes |
| `pg.row_opt_text` | Yes, when not null | Yes |
| `pg.row_i64`, `row_i32`, `row_f64`, `row_bool` | No | No |
| `session.subject`, `api_key.subject` | No — a view | No |
| `session.subject_clone`, `api_key.subject_clone` | Yes | Yes |
| `web.header`, `web.path`, `web.query` | No — a request view | No |
| `config.var_string`, `var_enum` | The loader owns it | No |

**A call that takes an `allocator` parameter allocates.** That is the signal in
the signature. Look for it before you look for documentation:

```odin
row_text :: proc(r: ^Rows, col: int, allocator := context.allocator, ...) -> (string, Error)
```

A call without one either returns a value or returns a view.

## An optional column is a `Maybe`, not an empty string

SQL `NULL` and the empty string are different. The optional decoders keep them
apart:

```odin
	nickname, e := pg.row_opt_text(&r, 2)
	if pg.is_err(e) { return }

	if name, ok := nickname.?; ok {
		// the column had a value; you own `name`
	} else {
		// the column was NULL
	}
```

`row_text` on a `NULL` column is `Decode_Null`, an error. It does not return
`""`. That is deliberate: a silent empty string is how a null reaches a NOT
NULL column three tables away.

The optional decoders still fail closed on a type mismatch or an overflow. A
`Maybe` means "this column may be null". It does not mean "read this loosely".

## Decoders fail closed on type

`row_i64` on a text column is `Decode_Type_Mismatch`. It does not parse the
text. `row_bool` accepts exactly what PostgreSQL emits for a boolean, and
nothing else.

An unknown column name from `pg.column` is `Decode_Shape`, never a silent `-1`.

Check the error on every decode. A decoder's error is the only thing standing
between a schema change and a wrong value in a response.

## Base64

Tokens are base64url without padding. `csrf` fixes the encoded length at 43
bytes for exactly that reason: a verifier can check the length before it does
any work.

If you encode or decode a token yourself, you must strip or restore the
padding. There is no shared helper, and the friction ledger records this being
done by hand in three separate places.

This is in [`../FIXES-WANTED.md`](../FIXES-WANTED.md). One helper replaces
three hand-written strippings.

## Bounded inline values

Several records store their strings inline, in a fixed array, with a length:

| Constant | Package | Value |
|---|---|---|
| `MAX_SUBJECT_BYTES` | `auth/session`, `auth/api_key`, `authorization` | 64 |
| `MAX_ROLE_BYTES` | `authorization` | 32 |
| `MAX_SCOPE_BYTES` | `authorization` | 64 |
| `MIN_TOKEN_BYTES` / `MAX_TOKEN_BYTES` | `auth/session` | 16 / 64 |
| `TOKEN_STRING_BYTES` | `csrf` | 43 |

This is why a `Record` is a plain value with no ownership question. No store
has to allocate, and no caller has to free.

It is also a limit. A subject longer than 64 bytes is refused with
`Bad_Subject`. Check it when your subject is an email address or an external
identifier, not an integer id.

**Count bytes, not characters.** These bounds are byte counts. A 40-character
subject with non-ASCII characters can exceed 64 bytes.

## Bytes on the wire

`web.bytes` sends a body you built. `web.text` sends a string. Neither
transcodes anything.

A response has no size limit. `Limits.max_body` caps what a client may send;
nothing caps what your handler may build, and the response is buffered whole
(ADR-014). Run under a memory cgroup.

## The check to run

`db/sqlcheck` prepares each named query against a real migrated database and
compares the parameter and result metadata PostgreSQL infers against what you
declared.

It catches the class this page is about: a column you decode as `i64` that the
schema made `text`. Run it in your build. A query PostgreSQL cannot prepare
statically is reported `Unchecked`, never falsely certified.
