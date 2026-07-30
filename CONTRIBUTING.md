# Contributing to Druse

Two things about this project will surprise you, so they come first.

**The public API is frozen and the build enforces it.** Phase 1 ratified exactly
32 application symbols and 2 test-support symbols, and
`build/check_phase1_freeze.sh` compares the compiler's own exported inventory —
every signature, struct field, enum member and enum backing type — against a
committed snapshot. Adding a public symbol fails the build. That is intentional,
and refreshing the snapshot to make it pass will also fail, because the
assertions encode the decision rather than the current state.

**Growth requires evidence, not agreement.** A new public symbol needs an owner,
a use case, a measured binary cost, its dependencies, a compiling example, a
behaviour test, a stated ownership rule and a rollback path. This is guardrail
G-09 in `planning/public-api-guardrails.md`. "It would be convenient" is not
evidence.

If that sounds heavy: it is, and it is why a five-route CRUD service is 32 lines
with one cleanup call. The constraint is the product.

## Before you start

Read `planning/public-api-guardrails.md` (G-01 to G-11) and
`planning/phase-1-freeze.md` (what is frozen and why). If you are proposing
something for a future phase, `planning/roadmap.md` says which phase owns it and
`planning/phase-2-plan.md` says what is already planned.

Changes that are welcome without ceremony: bug fixes with a failing test,
documentation corrections, test coverage for existing behaviour, and internal
improvements that leave observable behaviour identical.

Changes that need a discussion first: anything adding a public symbol, changing
a signature, adding a dependency, or altering routing, response, body or
transport behaviour. Open an issue describing the problem — not the API you want
— before writing code.

## Setting up

Druse pins one Odin toolchain. The pinned release, commit and asset checksum
are in `odin-version.txt`, and `ops/ci/install-odin.sh` installs and verifies it.
Odin has no package manager by design, so there is nothing else to install.

Run the full gate before you push:

```sh
env -u ODIN_ROOT DRUSE_ODIN_BIN=/path/to/odin bash build/check.sh
```

Expect `PASS=10 FAIL=0 SKIP=0` and `PASS: Phase 1 freeze gate`. It takes about
two minutes. A pre-push hook runs it for you — install it with
`bash build/install-hooks.sh`. **Do not bypass the hook.** If the gate is slow
or wrong, fix the gate in its own commit.

## How work is structured

Work happens in numbered work packages, and each one lands as an auditable
sequence of commits rather than a single squashed change:

1. **SPEC** — what will be built and what is being decided
2. **TESTS FIRST** — the tests, failing, committed RED
3. **IMPLEMENTATION** — the smallest thing that turns them green
4. **REVIEW/FREEZE** — mutation probes, measurements, documentation

Do not squash RED into GREEN. The failing commit is evidence that the test tests
something; a test that has never been seen to fail is not evidence.

A work package should be reviewable by one person. Split it when it contains a
new public API, a new ownership model, a new security boundary, a new
dependency, a transport change, a benchmark-driven decision, or a lifecycle
change. Do not merge two work packages to save time.

## Writing tests

Public behaviour goes in `tests/wpN-public-surface/`, using only exported
symbols — that is the contract a user sees.

Internal behaviour goes in `tests/wpN-internal/`. These declare `package web`
but do not live in `web/`; the gate copies `web/*.odin` into a throwaway package
at build time and compiles them together. That indirection exists because an
`@(test)` procedure must compile as part of the package it tests, and doing so
in `web/` would link `core:testing` into every application binary — measured at
+41,592 bytes. You cannot run these from an editor; run `build/check.sh`.

Every behavioural claim needs a test that has been observed to fail without the
change. For anything about cost, use `nm` with a positive control — an assertion
that "this links zero symbols" proves nothing unless you have also shown the
pattern matching something.

## Code expectations

Write Odin, not Go with different syntax. `knowledge-base/02-odin-idioms-guidelines.md`
is normative; `planning/odin-fit-audit.md` explains which conventions were
checked against the standard library and why.

In practice: procedures, not methods. `(value, ok)` returns, and **never**
`#optional_ok` on anything whose failure is interesting — dropping `ok` must be
a compile error. No `any`, no `rawptr` in exported declarations, no
`map[string]any`, no context extension bag. One canonical name per operation —
no aliases, no synonyms. When you need a variant, use an explicit procedure
group, which is how `core:strings` and `core:net` do it.

Anything reachable from `ctx.request` is a view over transport memory and is
invalid after the request. Copy it to keep it. Say so in the doc comment of
anything that returns one.

Comments should explain the rule the code implements. Decision history belongs
in an ADR — `planning/adrs.md` — not at the top of a source file. Several files
currently violate this; see `planning/post-phase1-audit.md` A-18. Do not add to
it.

## Commits and pull requests

Explain what changed and why it is correct. Include the executed gate output —
not "tests pass", the actual `PASS=10 FAIL=0 SKIP=0` line. If something is
unproven, say so; a pull request that admits a gap is worth more than one that
hides it.

State plainly whether the public surface changed. If it did, the pull request
must carry the G-09 evidence for every new symbol.

Sign off commits with your own authorship. Work done with an AI assistant should
say so in a `Co-Authored-By` trailer.

## Independent review

Work packages are reviewed against `planning/qa-agent.md`, which is written to
be handed to a reviewer — human or agent — as-is. Its first rule is the one that
matters: **verify, do not trust.** Every claim in a commit message, a pull
request, a code comment or a planning document is a hypothesis until someone has
run it.

If you are reviewing, run the gate yourself and quote your own output. If you
are submitting, expect the numbers in your description to be reproduced.

## Decisions you cannot make alone

Accepting an ADR, changing a frozen contract, growing a ledger, choosing a
licence, cutting a tag or publishing a release are all owner decisions. Propose
them, with evidence and with the strongest argument against your own position,
and let the owner decide. ADRs in `planning/adrs.md` marked **PROPOSED** are
proposals — do not implement one because it looks settled.
