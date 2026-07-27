# Documentation program — the teaching guide

A plan an agent can execute. The deliverable is a tree of `.md` files that
teaches a person to build a real application with Uruquim core + Crystals.

This is not the reference. The reference exists and is good. This is the
missing half: the guide that gets somebody from nothing to a working
application, and teaches the rules no single package can teach.

---

## 1. Definition of done

The guide is finished when **each of the 30 entries in the two friction
ledgers would have been avoided by a reader who followed it.**

Nothing else is the criterion. Not page count, not package coverage, not
"every exported symbol is mentioned". The ledgers are the empirical record of
what a competent builder actually gets wrong on first contact, written as it
happened. They are the curriculum.

Ledgers:

- `uruquim-miniature/FRICTION.md` — 30 numbered entries, two applications.
- The "What the application had to do that the library could have" list at the
  bottom of the same file — five items, each a recipe the guide owes the reader.

W0 produces the entry-to-file map. Every later work package is accepted against
its slice of that map.

---

## 2. Current state — measured, not assumed

| Repo | Docs | Lines |
|---|---|---|
| `uruquim-odin` (core) | 12 files | 3617 |
| `crystals` | 9 files | 2276 |

What already exists and is good — **do not rewrite**:

- `core/docs/quick-start.md` (231) — a real build-along, from nothing to a
  running API. Correct tone: "assumes you can program, but not that you know
  Odin". This is the seed of Build-along 1, not a competitor to it.
- `core/docs/canonical-patterns.md` (834), `core/docs/ai-context.md` (1049),
  `crystals/docs/crystals.md` (1120) — reference. Harvest and link. Never
  duplicate.
- `core/docs/errors.md` (351), `middleware.md` (296), `operations.md` (480).

What is missing or stale — **this is the work**:

| Gap | Evidence |
|---|---|
| `core/docs/memory-model.md` is a **7-line placeholder** | 7 of 30 friction entries are ownership/lifetime — the largest cluster by far |
| `core/docs/cookbook.md` is a **9-line stub** | 5 recipes are already named in the ledger |
| `quick-start.md` says the framework is "aimed at JSON APIs" | the whole server-rendered stack now exists — template, form, csrf, html, redirect |
| No build-along for the async half | `jobs`, `mail`, `storage/s3`, `api_key`, `idempotency`, `sse` have no narrative anywhere |
| `crystals/docs/migrations.md` names `migrate adopt` | that command does not exist; it is `schema adopt` (entry #16) |
| Vendoring is one flag in a README | a plain clone into `vendor/` produces an embedded repo that does not track (entry #23) |

---

## 3. Where it lives

**Decision: the guide lives in the core repo, at `uruquim-odin/docs/guide/`.**

Reasons: it teaches core and Crystals as one product; the core is where a
newcomer arrives; and the two biggest gaps (`memory-model`, `cookbook`) are
already core files. The Crystals repo keeps its reference and links into the
guide.

Confirm this before W1. If it is wrong, only the paths change — everything
below is unaffected.

### Tree

```
uruquim-odin/docs/
  STYLE.md                 # the writing rules (W0)
  GLOSSARY.md              # one term, one meaning (W0)
  guide/
    README.md              # map: which file answers which question
    01-concepts/
      what-this-is.md
      what-it-refuses.md         # ORM, DI, auto-migration — and the cost
      core-and-crystals.md       # the boundary, and vendoring that works
      shape-of-an-application.md # composition, detached routers, main
    02-build-notes/              # server-rendered, synchronous
      01-nothing-to-hello.md
      02-database-and-migrations.md
      03-first-page.md
      04-forms-and-csrf.md
      05-sessions-and-login.md
      06-authorization.md
      07-docker.md
    03-build-intake/             # asynchronous, worker-shaped
      01-service-and-api-keys.md
      02-jobs-and-the-worker.md
      03-storage-and-mail.md
      04-idempotency-and-sse.md
    04-rules/
      ownership-and-lifetime.md  # THE chapter — see W2
      result-vocabularies.md
      configuration.md
      bytes-and-encoding.md
      composition-and-cost.md
    05-recipes/                  # one problem per file, no narrative
      post-redirect-get.md
      layout-and-pages.md
      ...
    FIXES-WANTED.md              # see §7 — the most valuable by-product
```

Numbered prefixes are load-bearing. For a framework with no precedent, reading
order is part of the teaching.

---

## 4. Style — and the verdict on Simplified Technical English

### What STE is

ASD-STE100 is a controlled English spec from aerospace maintenance
documentation: roughly 65 writing rules plus an approved dictionary of ~900
words, each with **one** meaning and one part of speech. Representative rules:
active voice; one instruction per sentence; procedural sentences ≤20 words,
descriptive ≤25; paragraphs ≤6 sentences; no gerunds; no synonyms — you write
`start`, never `initiate` / `commence` / `begin`.

### Verdict: adopt the rules, reject the dictionary, tier by document type

It is a good reference here, for one reason that outweighs the others: **an
agent writing ~40 files will drift.** Terminology drift is the default outcome
of generated corpora, and STE's one-term-one-meaning discipline is the direct
antidote. That the repo's own audience is international, and that its author
works in Portuguese while the docs are English, makes the case stronger.

Where it does not fit, honestly:

- **The dictionary has no software vocabulary.** No `allocator`, `arena`,
  `cursor`, `borrow`, `idempotency`. STE handles this through Technical Names
  and Technical Verbs that a project defines for itself — so this is not a
  blocker, but it does mean you cannot adopt it off the shelf. You inherit the
  *mechanism* and supply your own approved terms. That is `GLOSSARY.md`.
- **The no-gerund rule and the word caps fight explanation.** The concepts
  chapters must persuade a reader that refusing an ORM is right. STE was
  designed to strip exactly the connective prose that argument needs, and its
  own scope statement targets procedural and descriptive maintenance text, not
  rationale.
- **The spec is a paid ASD document.** You cannot link contributors to it. You
  must restate the subset you adopt in your own words, in `STYLE.md`.

So: **tier the discipline by document type.**

| Document type | Discipline |
|---|---|
| `04-rules/`, `05-recipes/`, operations, every trap statement | Full: ≤20-word sentences, imperative, one action per sentence, approved terms only, no synonyms |
| `02-build-*`, `03-build-*` | Medium: active voice, ≤25 words, approved terms; connective prose allowed |
| `01-concepts/` | Light: approved terms and active voice only. Argument is the point |

### The practical stack

STE alone leaves out everything specific to software. Pair it:

1. **STE's philosophy** — controlled vocabulary, one meaning per term, short
   imperative sentences. Restated in `STYLE.md`.
2. **Google developer documentation style guide** — free, software-specific,
   and it covers what STE has no opinion on: code samples, CLI formatting, API
   naming, placeholder conventions.
3. **Vale** — the free prose linter that enforces both mechanically. Existing
   packages for Google and write-good, plus a custom `Vocab` file generated
   from `GLOSSARY.md`. Without a checker, any style guide decays within weeks.
   This is the difference between a style guide and a style aspiration.

---

## 5. Source material the agent must read before writing

In this order. The agent may not write a line before finishing this list.

1. `uruquim-miniature/FRICTION.md` — both tables, all 30 entries, plus the two
   summary lists at the end.
2. `core/docs/quick-start.md` — the tone to match.
3. `core/docs/ai-context.md` and `crystals/docs/ai-context.md` — the mental
   model, already compressed. `01-concepts/` is these two decompressed.
4. `crystals/docs/phase-6-freeze.md`, `phase-7.5-composition-freeze.md`,
   `adrs.md` — decisions already made and refused, with reasons. This is what
   keeps the guide from reopening settled questions.
5. `crystals/examples/notes/` and `uruquim-miniature/cmd/` — working code. The
   build-alongs narrate these, they do not invent new programs.

---

## 6. Work packages

Each is one agent session. Each has an acceptance check that another agent can
run without the author present.

### W0 — Terminology and rules (blocks everything)

- **Out:** `STYLE.md`, `GLOSSARY.md`, `guide/friction-map.md`.
- `GLOSSARY.md`: every term with more than one spelling in the current corpus
  gets one approved form. Start from the known collisions — `Valid` /
  `Accepted` / `Ok` / `None` for success (#4, #15), and `subject` used for
  three different borrowed views (#30).
- `friction-map.md`: a table of all 30 entries → the file that will prevent it.
  Entries closed by an upstream API change teach nothing about the API as it
  now stands, and are marked `FIXED`: #3 (layout slots), #8 (`web/redirect`),
  #25 (`crystals_http` rename). **#26 is not one of them** — the library bug is
  fixed, but the hazard it exposed (a temporary arena that outlives nothing yet
  swallows the caller's result) is reproducible in any application that writes
  its own `temp_begin` / `temp_end`, so it stays in W2 as a taught class.
- **Accept:** every one of the 30 entries maps to exactly one target file or is
  marked FIXED. No entry unassigned.

### W1 — `01-concepts/`

- **In:** both `ai-context.md`, freeze docs, ADRs.
- **Out:** four files, ≤150 lines each.
- **Accept:** no claim that is not already stated in a source document. This
  package makes no new decisions. A reviewer can trace every sentence.

### W2 — `04-rules/ownership-and-lifetime.md` — highest value

Fills a 7-line placeholder. Covers the largest friction cluster: #6, #9, #20,
#21, #26, #28, #30.

The chapter teaches **one idea**: who owns the bytes, and how long they stay
valid. Then it shows that idea in every shape it takes — a view into a struct
that dies with the struct (`session.subject`, `api_key.subject`,
`authorization.subject`), a connection you acquire and release, a transaction
that takes the pool and not the connection, a cursor that is positioned
differently by two sibling procedures, an arena that can swallow its own
return value.

Naming the class inoculates against instances not yet found. Teaching it
per-package guarantees the reader learns it three times or never.

- **Out:** the chapter, plus a runnable program under `examples/` that
  demonstrates each hazard and its correct form.
- **Accept:** the demonstration program builds and runs; a reader who has read
  only this chapter writes `who :: proc(ctx) -> (string, bool)` correctly.

### W3 — the remaining `04-rules/` chapters

`result-vocabularies.md` (#4, #10, #12, #15, #17 — one table, one page, showing
all five shapes of "did it work" that a single handler switches on),
`configuration.md` (#13, #14, #17 — including the `c := DEFAULT_CONFIG` idiom
that no document currently shows), `bytes-and-encoding.md` (#19, #24, #29),
`composition-and-cost.md` (#11, #22).

### W4 — `02-build-notes/`

- **In:** `examples/notes/`, the miniature, `quick-start.md`.
- The narrative extends `quick-start.md` into the server-rendered stack. Fix
  the "aimed at JSON APIs" framing at the same time.
- Every trap is taught **at the moment it bites**: #1 at the first mount, #6 at
  the first handler that asks who the user is, #5 and #7 at the login and the
  form, #19 at the first `<form>`, #20 at the login query, #21 at the first
  `who` helper.
- Assigned entries: **#1, #5, #6, #7, #19, #20, #21**.
- **Accept:** the code in the chapters is extracted from a program that the
  gate builds (§7). Not typed into markdown.

### W5 — `03-build-intake/`

Same method, `cmd/intake` as the source. Covers the seven packages the first
application never touched. A worker is a different shape of program from a
web service, and no document currently shows that shape.

Assigned entries: **#27** — `mail_http.open` takes the application's
`http_client` rather than building its own, so pool bound, timeouts and TLS
stay one decision in one place. The ledger flags this as better than the
natural guess and currently shown nowhere.

### W6 — `05-recipes/`

Seeded by the ledger's own list of what the application had to do that the
library could not. One problem per file. No narrative, no teaching — a reader
here already knows the framework and wants an answer.

### W7 — Wiring and truth pass

- `guide/README.md`: the map. Which file answers which question, and what each
  page assumes you have already read. One line at the top of every file
  declaring its assumption.
- Fix the stale claims found during the program: `migrate adopt` (#16), the
  vendoring gap (#23), the stray `migrations/` at the root of the vendored tree
  that silently captures `MIGRATE_DIR` (#2), the JSON-API framing.
- Assigned entries: **#2, #16, #23**. Entry **#18** (a refusal whose detail is a
  bare identifier, so `template refused at 6:1 — content` reads as though
  `content` were the problem) is a message-quality defect with nothing to teach:
  route it to `FIXES-WANTED.md`, not to a chapter.
- **Accept:** every command in every document was executed by the agent before
  it was written. Every internal link resolves.

### W8 — Mechanical enforcement

See §7.

### W9 — Acceptance test

See §8.

---

## 7. Mechanical guarantees

Three, and they are what separates this from a documentation effort that rots
in a quarter.

**Snippets are extracted, never typed.** Mark regions in real Odin source:

```odin
// guide:begin notes-login-query
...
// guide:end
```

A script inlines them into the markdown between matching markers. A gate step
re-runs the extraction and fails if the result differs from what is committed.
Documentation that cannot drift from the code is the whole point — the repo has
already been bitten twice by docs that named commands which do not exist.

**Prose is linted.** Vale, with the Google package plus a `Vocab` generated
from `GLOSSARY.md`, and per-directory severity implementing the tiering in §4.

**Links are checked.** A dead internal link in a framework guide is worse than
no guide, because the reader has no other source to fall back on.

All three run in the same gate as the code.

### FIXES-WANTED.md — the by-product that matters most

Writing the guide is the **last cheap moment to change the API.** While no
external application depends on it, `Valid` / `Accepted` / `Ok` / `None` is a
rename, the base64 padding stripped by hand in three places (#29) is one
helper, and `var_u16` (#13) is ten lines. After the guide ships, each becomes a
permanent commitment. **Every trap you document is a trap you have decided to
keep forever.**

So the rule for the agent is: **when you are about to write a warning, stop and
ask whether it can be an API change, a type, or a gate check instead.** If it
can, append it to `FIXES-WANTED.md` with the entry number and the proposed
change, and write the warning anyway so the guide is complete. The human
decides which ones to take before the guide is published.

`subject_clone` is the model of how that ends well: a documented lifetime did
not stop the bug; a named safe path plus a guard did.

---

## 8. Acceptance test — reuse the method that produced the ledger

The ledgers were produced by building a real application and recording every
stumble. **Run the same procedure against the guide instead of against the
code.**

A third application, a shape neither miniature covered, built by following
*only* the guide. The builder may not open a `.odin` file in the library. Every
time they must, that is a documentation defect, recorded in the same table
format.

Target: fewer than 5 new entries. This is the only honest test of framework
documentation, and it is cheap here because the team already knows how to run
it.

---

## 9. Rules for the executing agent

- **Never invent API.** Grep the source for every symbol before writing it. The
  ledger's first four entries are all guessed names that were wrong.
- **Never write a command you have not run.**
- **Do not rewrite `canonical-patterns.md`, `ai-context.md`, or
  `crystals.md`.** Harvest and link. Duplicated reference is guaranteed to
  diverge.
- **One file answers one question.** If a file needs an "also" section, it is
  two files.
- **Size budget:** concepts ≤150 lines per file, build-along chapters ≤250,
  rules ≤200, recipes ≤80. A guide nobody finishes teaches nothing.
- **Do not re-open decisions recorded in the freeze docs and ADRs.** If the
  guide seems to require it, stop and report instead.
- **State what the gate does not prove.** For the agent-facing summary: 35
  green negative controls did not catch four defects, all of them integration
  defects. A reader who concludes "gate green, therefore correct" has been
  taught the wrong thing.
