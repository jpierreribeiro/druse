# Fixes wanted

Every trap this guide documents is a trap the project has decided to keep.

Writing the guide is the last cheap moment to change the API. No application
outside these repositories depends on it yet. After the guide is published,
each item below becomes a permanent commitment.

The rule that produced this list: **when you are about to write a warning, ask
whether it can be an API change, a type, or a build check instead.** If it can,
record it here, then write the warning anyway so the page is complete.

The model of how this ends well is `subject_clone`. A documented lifetime did
not stop the bug. A named safe path plus a guard did.

Each item states the proposal and where the warning currently lives. A human
decides which ones to take.

---

## 1 — Five success names for one idea

**Where the warning lives:** [`04-rules/result-vocabularies.md`](04-rules/result-vocabularies.md).

Five packages report success five ways: `Valid` (`auth/password`), `Accepted`
(`csrf`), `Authenticated` (`auth/session`), `Ok` (`session.Store_Result`),
`Proceed` (`idempotency.Outcome`).

Each name is defensible in its own package. Together they are a table a reader
has to memorise.

**Proposal.** Rename toward two shapes, not five. A verifier reports
`Accepted`/`Rejected`. A store reports `Ok`/`Failed`. Leave `Status` and
`Outcome` alone, because they report more than success.

**Cost of not doing it.** One table in the guide, forever, and a `switch` a
reader cannot write from memory.

**Cost of doing it.** A rename across `auth/password`, `csrf` and their HTTP
adapters, plus the public ledger entries. No behaviour changes.

---

## 2 — No `var_u16`, so every port is an `int` and a cast

**Where the warning lives:** [`04-rules/configuration.md`](04-rules/configuration.md).

`config` has `var_int` with `min` and `max`, and no `var_u16`. A port is the
most common configured value in a service, and every application writes the
same bounded read and the same conversion.

**Proposal.** Add `config.var_port`, or `var_u16` with the bounds built in.
Roughly ten lines over `var_int`.

**Cost of not doing it.** Each application repeats `min = 1, max = 65535` and
gets it wrong once.

---

## 3 — Base64 padding is stripped by hand in three places

**Where the warning lives:** [`04-rules/bytes-and-encoding.md`](04-rules/bytes-and-encoding.md).

Tokens are base64url without padding. The friction ledger records the padding
being stripped and restored by hand in three separate places.

**Proposal.** One pair of helpers in a shared package. Encode without padding,
decode tolerating its absence.

**Cost of not doing it.** Every application that touches a token encoding
writes the same four lines, and a wrong one produces a token that verifies
nowhere.

---

## 4 — `subject` returns a view, and the name does not say so

**Where the warning lives:** [`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md).

`session.subject` and `api_key.subject` return a view into a record. Returning
one from a procedure whose record is a local is use-after-return, and it does
not crash — it produces a plausible wrong value.

`subject_clone` already exists as the safe path, and giving it a name was
worth more than the paragraph above it. The hazard is that the unsafe one has
the shorter, more obvious name.

**Proposal.** Consider `subject_view` for the borrowing form, leaving
`subject` free, or removing it. A reader who types `subject` and gets a
compile error has been taught the rule at the only moment it matters.

**Cost of not doing it.** The recorded defect: a corrupted subject reached a
foreign key, the database rejected the write, and the handler answered as
though it had succeeded.

---

## 5 — `query` and `query_one` return the same type, positioned differently

**Where the warning lives:** [`04-rules/ownership-and-lifetime.md`](04-rules/ownership-and-lifetime.md).

Both return `Rows`. A `query` cursor starts before the first row and needs
`rows_next`. A `query_one` cursor is already on its row, and `rows_next` steps
past it.

The two are indistinguishable at the call site by type.

**Proposal.** A distinct `Row` type for `query_one`, with no `rows_next`. The
compiler then refuses the mistake.

**Cost of not doing it.** A silent empty read on a code path that returns the
right type and the wrong data.

---

## 6 — `api_key.DEFAULT_PREFIX` is `"uru"`

**Where the warning lives:** nowhere yet. Found while writing this guide.

`auth/api_key` sets `DEFAULT_PREFIX :: "uru"`. It is derived from the former
product name, and it appears in every key a default-configured application
issues.

**Proposal.** Change it with the rename. `"dru"`, or a value the application
must choose.

**Cost of not doing it.** Keys issued in production carry the old name
permanently, and they cannot be reissued without invalidating every client.
This is the one item on this list with a deadline: it stops being reversible
the first time a real key is issued.

---

## 7 — A refusal message names a bare identifier

**Where the warning lives:** nowhere. It teaches nothing, so it is recorded
here only.

A template refusal reads `template refused at 6:1 — content`, which reads as
though `content` were the problem rather than the name of the missing slot.

**Proposal.** State the relation: `unknown slot "content"`.

**Cost of not doing it.** A confusing message. No correctness risk, and nothing
a guide page can usefully teach.

---

## 8 — The vendoring trap has no guard

**Where the warning lives:** [`01-concepts/core-and-crystals.md`](01-concepts/core-and-crystals.md).

A plain clone into `vendor/` produces an embedded repository. Git records a
gitlink, a fresh clone produces an empty directory, and nothing warns.

The second half is worse: a vendored tree carries its own `migrations/` at its
root, and a relatively resolved `MIGRATE_DIR` can find it.

**Proposal.** A build check that fails when `vendor/*/.git` exists, and a
migration runner that refuses a `MIGRATE_DIR` it did not resolve absolutely.

**Cost of not doing it.** The failure appears on a colleague's machine, not on
the machine that made it.
