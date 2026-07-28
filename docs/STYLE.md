# Style

These are the writing rules for everything under `docs/`. They apply to a human
contributor and to an agent equally.

The rules come from ASD-STE100, a controlled English specification written for
aerospace maintenance documentation. That specification is a paid document. You
cannot read it, and you do not need to. This page states the subset that
applies here, in full. Cite this page, not the specification.

## 1. Language

Write English. This applies to every file under `docs/`, including headings,
code comments in samples, and table cells. Portuguese belongs in `planning/`.

## 2. One term, one meaning

`GLOSSARY.md` holds the approved terms. Each term has one meaning and one part
of speech.

Do not use a synonym for an approved term. Write `start`. Do not write
`initiate`, `commence`, `launch` or `fire up`. Write `remove`. Do not write
`delete`, `strip`, `drop` or `get rid of`.

If you need a term that `GLOSSARY.md` does not hold, add it there first. A term
introduced in one page and never approved is how a corpus drifts.

This rule is the reason the others exist. Forty files written over many
sessions drift in vocabulary before they drift in anything else.

## 3. Sentences

Write active voice. Name who does the thing.

- Write: `The application destroys the pool.`
- Do not write: `The pool is destroyed.`

Write one instruction per sentence. A sentence with `and then` is two
sentences.

Keep an instruction to 20 words. Keep a description to 25 words.

Do not use a gerund as a noun. Write `Use the pool to run a query.` Do not
write `Running a query uses the pool.`

## 4. Paragraphs

Keep a paragraph to six sentences.

Start a paragraph with its topic sentence. A reader who reads only the first
sentence of each paragraph must still get the page.

## 5. How strictly this applies

The vocabulary rules (§1, §2) and active voice apply everywhere. There is no
exception.

The length caps relax by directory:

| Directory | Sentence cap | Notes |
|---|---|---|
| `guide/03-subjects/`, `guide/04-rules/`, `guide/05-recipes/`, `operations.md`, every warning | 20 words, imperative, one action per sentence | |
| `guide/02-build-*`, `guide/03-build-*` | 25 words | Connective prose is permitted |
| `guide/01-concepts/` | Relaxed | Argument is the point. Vocabulary rules still hold |

`guide/01-concepts/` is the single concession. Those pages must persuade a
reader that a refusal is correct, and a 20-word cap removes the connective
prose an argument needs. The concession buys back sentence length. It buys back
nothing about vocabulary.

## 6. Code samples

Show the whole thing that compiles. A sample with `...` in the middle teaches a
reader to guess.

**A cookbook page never contains typed code.** It carries extraction markers,
and `build/gen_cookbook.py` inlines the program from a real example the build
check compiles. `build/check_docs.sh` fails when a page has drifted from its
source. Documentation that cannot drift from the code is the whole point.

A recipe may show the calls that matter rather than a whole program. A cookbook
page may not.

Never write a symbol you have not found in the source. Search for it first. The
most expensive documentation defect this project has recorded is a command that
does not exist.

Never write a command you have not run.

Show the error path. A sample that ignores a returned error teaches the reader
to ignore it too.

Follow the Google developer documentation style guide for what this page does
not cover: placeholder format, CLI formatting, and API reference wording. It is
free, and it is specific to software, which ASD-STE100 is not.

## 7. Structure

One file answers one question. If a file needs an `Also` section, it is two
files.

Every page starts with one line that states what it assumes you have read.

Size limits: a concepts page is 150 lines, a build-along chapter 250, a rules
page 200, a subject page 120, a recipe 80, a cookbook page 400 — most of which
is the program. `build/check_docs.sh` enforces every one. A guide nobody
finishes teaches nothing.

A subject page is the one a reader arrives at with a question — `routing.md`,
`request.md`, `response.md`. Name it for the question, not for the packages it
touches.

## 8. What the reader is told about risk

State a limit as a fact. Do not apologise for it, and do not hide it.

- Write: `The write timeout is off by default. Turn it on in production.`
- Do not write: `You may wish to consider enabling the write timeout.`

When you write a warning, stop. Ask whether the hazard can be an API change, a
type, or a build check instead. If it can, add it to `guide/FIXES-WANTED.md`,
then write the warning anyway so the page is complete.
