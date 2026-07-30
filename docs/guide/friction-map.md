# Friction map — the 30 entries against the guide

W0's deliverable, produced late: the guide was written before this map existed,
so this is both the map W0 specified and an audit of what the finished pages
actually cover.

The programme's definition of done is that **each of the 30 entries in
`druse-miniature/FRICTION.md` would have been avoided by a reader who followed
the guide.** This table is the measurement of that claim, entry by entry.

Every entry maps to exactly one target page or is marked `FIXED`. No entry is
unassigned. The verdict column is the audit: whether the page as written today
would actually have prevented the entry, checked by reading it, not by finding
the symbol on it.

## Verdicts

| Verdict | Count | Meaning |
|---|---|---|
| `COVERED` | 19 | The page states the rule, and a reader who followed it would not have hit the entry. |
| `FIXED` | 5 | Closed by an API change. Teaches nothing about the API as it now stands. |
| `PARTIAL` | 1 | The rule is taught, but not for every case the entry names. |
| `GAP` | 4 | Nothing in the guide would have prevented it. |
| `NO PAGE` | 1 | Correctly absent — the entry teaches nothing a page could carry. |

## The map

| # | The friction | Target page | Verdict |
|---|---|---|---|
| 1 | Guessed a route helper; it returns a detached Router you mount | [`04-rules/composition-and-cost.md`](04-rules/composition-and-cost.md) | COVERED |
| 2 | A vendored tree's own `migrations/` can win a relative `MIGRATE_DIR` | [`03-subjects/installation.md`](03-subjects/installation.md) | COVERED |
| 3 | `web/template` could not express a layout | — | FIXED (PR #15) |
| 4 | `Verify_Result` in two packages, different success names | [`04-rules/result-vocabularies.md`](04-rules/result-vocabularies.md) | COVERED |
| 5 | `session_http.current` threads the manager and returns a 5-state enum | [`05-recipes/who-is-the-user.md`](05-recipes/who-is-the-user.md) | COVERED |
| 6 | `subject` is an accessor over an inline buffer, not a field | [`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md) | COVERED |
| 7 | `csrf_http.reject` takes the service and the binding, and re-verifies | [`05-recipes/protect-a-form-with-csrf.md`](05-recipes/protect-a-form-with-csrf.md) | COVERED |
| 8 | The core could not redirect | — | FIXED (`web/redirect`) |
| 9 | `pg.acquire` / `pg.release` ownership, and every call takes a `^Conn` | [`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md) | COVERED |
| 10 | `pg.row_text` returns an `Error`; `pg.rows_next` returns a bool | [`04-rules/bytes-and-encoding.md`](04-rules/bytes-and-encoding.md) | COVERED |
| 11 | **At most ONE `:param` per route** | [`03-subjects/routing.md`](03-subjects/routing.md) | **GAP** |
| 12 | Five result vocabularies in one handler | [`04-rules/result-vocabularies.md`](04-rules/result-vocabularies.md) | COVERED |
| 13 | `pg.Config`: `u16` port, `ssl_mode`, and plaintext needs two opt-ins | [`02-build-notes/02-database-and-migrations.md`](02-build-notes/02-database-and-migrations.md) | COVERED |
| 14 | **`rate_limit.Config` is `capacity` + `refill` + `window_seconds`** | [`05-recipes/rate-limit.md`](05-recipes/rate-limit.md) | **GAP** |
| 15 | `.None` vs `.Ok` across the storage family | — | FIXED (see below) |
| 16 | The runbook named a command in the wrong binary | — | FIXED (see below) |
| 17 | `Bad_Config` names the category, not the field | [`04-rules/configuration.md`](04-rules/configuration.md) | COVERED |
| 18 | A template refusal detail is a bare identifier | — | NO PAGE ([`FIXES-WANTED.md`](FIXES-WANTED.md) #7) |
| 19 | The CSRF field name cannot reach a template, because templates are strings | [`05-recipes/protect-a-form-with-csrf.md`](05-recipes/protect-a-form-with-csrf.md) | COVERED |
| 20 | `pg.query_one` forbids the `pg.rows_next` that `pg.query` requires | [`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md) | COVERED |
| 21 | A borrowed subject outlived its record — silent corruption | [`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md) | COVERED |
| 22 | **An opened-but-never-called Crystal is invisible** | [`04-rules/composition-and-cost.md`](04-rules/composition-and-cost.md) | **GAP** |
| 23 | A plain clone into `vendor/` makes an embedded repository | [`03-subjects/installation.md`](03-subjects/installation.md) | COVERED |
| 24 | **`web.query` does not percent-decode; `form.field` does** | [`05-recipes/read-a-query-parameter.md`](05-recipes/read-a-query-parameter.md) | **GAP** |
| 25 | Two vendored trees, one `package http` | — | FIXED (`crystals_http`) |
| 26 | A temporary arena freed the result it returned | [`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md) | COVERED |
| 27 | `mail_http.open` takes the application's HTTP client | [`05-recipes/send-email.md`](05-recipes/send-email.md) | COVERED |
| 28 | `pg.begin` takes the pool, not a connection | [`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md) | COVERED |
| 29 | Base64 padding is stripped by hand in three places | [`04-rules/bytes-and-encoding.md`](04-rules/bytes-and-encoding.md) | COVERED |
| 30 | The borrowed-view shape is in THREE packages | [`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md) | **PARTIAL** |

## Two entries the programme still lists as open, and are not

The plan named #3, #8 and #25 as closed by upstream API changes. Two more have
closed since, and both were verified against the current source rather than
against the ledger's account of it.

**#15 is FIXED.** The entry records `storage.Error_Kind` using `.Ok` while
`storage_filesystem.Error_Kind` used `.None` — two packages in one family with
opposite conventions. Both now use `.None`. The polarity rule survives as
general teaching in
[`04-rules/result-vocabularies.md`](04-rules/result-vocabularies.md), but the
collision the entry describes no longer exists to teach.

**#16 is FIXED, and the record of it is wrong in two places.** The entry says
`docs/migrations.md` told a reader to type a command that lived in a different
binary. That document now names `schema adopt` and `schema check`, `cmd/schema`
accepts both, and following it works.

[`FIXES-WANTED.md`](FIXES-WANTED.md) #11 says of the same entry: "Neither
exists." That is not right either — `cmd/schema` exists and accepts `adopt`.
What was stale was the programme's note about the runbook, and the note about
the note is now the stale one. Worth fixing both, since #11 currently asks a
reader to re-check a document that is already correct.

## The four gaps

Each of these is an entry the guide would not have prevented. They are small —
a paragraph each, on a page that already exists.

**#11 — at most one `:param` per route.** [`03-subjects/routing.md`](03-subjects/routing.md)
documents `:param` segments and that a static segment beats a parametric one at
the same position. It does not say that `/users/:uid/notes/:nid` is refused. The
core enforces this in `pattern_classify` and the refusal is loud, but the entry's
own point is that this is a rule you need **before** designing URLs, not after
the router rejects them. It is the cheapest gap to close and the one most likely
to cost a reader a redesign.

**#14 — `rate_limit.Config`.** The ledger's guess was `refill_per_second`; the
real shape is `capacity` + `refill` + `window_seconds`, which is more
expressive. The entry says the wrong guess came from documentation that said
"token bucket" without showing the struct.
[`05-recipes/rate-limit.md`](05-recipes/rate-limit.md) still does not show the
struct.

**#22 — an opened-but-never-called Crystal is invisible.** Nothing catches it:
not the compiler, since the manager is a struct field and therefore "used"; not
a lint; not a startup check. An application can carry the configuration surface
and the connection cost of a Crystal it never calls.
[`04-rules/composition-and-cost.md`](04-rules/composition-and-cost.md) is the
right page — it already teaches what composition costs per request — and this is
the cost that shows up in `main` and nowhere else.

**#24 — `web.query` does not percent-decode.** The same bytes read two ways give
two different strings: `?q=John%20Doe+here` is `"John Doe here"` through
`form.field` and stays encoded through `web.query`. Neither name says which.
[`05-recipes/read-a-query-parameter.md`](05-recipes/read-a-query-parameter.md) is
thorough about what missing means to each of the four extractors, and about the
returned string being a view — and says nothing about encoding. An application
that stores a query parameter directly stores the encoded form. The entry was
found by writing a test that asserted the opposite and passed.

## The one partial

**#30 — the borrowed-view shape is in three packages.**
[`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md) teaches
the shape properly: Shape 1 gives the wrong version and the right one side by
side, and [`04-rules/bytes-and-encoding.md`](04-rules/bytes-and-encoding.md)
tabulates `session.subject` and `api_key.subject` against their `_clone` forms.

`authorization.subject` appears nowhere in the guide. That is precisely the gap
the entry names: the lifetime was documented for the one package an application
had already got wrong, and the other two were left as the same undocumented
trap. One is now documented. The third is still not.

Adding the row costs a line. The reason it matters is that this class of defect
is the one the ledger calls its most serious: the corrupted subject reached a
foreign key, the write was rejected, and the handler answered as though it had
succeeded.

## The one with no page

**#18 — a template refusal detail is a bare identifier.** A refusal reads
`template refused at 6:1 — content`, which reads as though `content` were the
problem rather than the name of a slot that does not exist.

There is no page for this and there should not be.
[`FIXES-WANTED.md`](FIXES-WANTED.md) #7 records it and says so directly: it
teaches nothing, so it is recorded there only. The fix is one message string.

This is worth stating because W0's acceptance rule — "every entry maps to
exactly one target file or is marked FIXED" — has no category for an entry that
is neither. One of the thirty is a defect to fix rather than a lesson to teach,
and forcing it onto a page would have produced a paragraph explaining a message
that is about to change.

## The five recipes the ledger asked for

The "What the application had to do that the library could have" list, which the
programme counts as part of the curriculum:

| What the application had to do | Where it landed |
|---|---|
| Concatenate its own page shell | FIXED upstream — layout slots |
| Concatenate the CSRF field name into template source | [`05-recipes/protect-a-form-with-csrf.md`](05-recipes/protect-a-form-with-csrf.md) |
| Write its own redirect | FIXED upstream — [`03-subjects/forms-and-redirects.md`](03-subjects/forms-and-redirects.md) |
| Clone a subject before returning it | [`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md) |
| Know that one cursor form forbids the step the other requires | [`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md) |

All five are covered or fixed.

## What the audit does not prove

The verdicts are from reading the pages, not from running them. `COVERED` means
the page states the rule a reader needed. It does not mean a reader would find
it — the entries cluster heavily on
[`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md),
which carries seven of the thirty on its own, and a rule on a page nobody reaches
prevents nothing.

The programme's own criterion is stronger than this table can check: that the
entry **would have been avoided**. Only another application, built by somebody
following the guide, tests that. This map narrows what such a run would be
looking for.
