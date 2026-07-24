#!/usr/bin/env bash
# WP10 — the documentation parity gate.
#
# Documentation drifts silently: the code changes, the prose does not, and both
# keep looking green. This gate makes drift a build failure.
#
# THE INVENTORY IS READ FROM `build/check_public_api.sh`, never re-typed here
# (WP10 D2). A second hand-maintained list would diverge from the package while
# both files still passed their own checks — precisely the failure this exists
# to prevent.
#
# It reads only; it never edits a document.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_DOCS="$URUQUIM_ROOT/docs"

fail() {
  echo "DOCS-FAIL: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# The canonical ledgers, extracted from the API checker itself.
# ---------------------------------------------------------------------------
URUQUIM_APP_SYMBOLS="$(sed -n '/^URUQUIM_EXPECTED_EXPORTS="/,/"$/p' \
  "$URUQUIM_ROOT/build/check_public_api.sh" | sed '1s/.*="//' | sed '$s/"$//')"
URUQUIM_TS_SYMBOLS="$(sed -n '/^URUQUIM_EXPECTED_TESTSUPPORT_EXPORTS="/,/"$/p' \
  "$URUQUIM_ROOT/build/check_public_api.sh" | sed '1s/.*="//' | sed '$s/"$//')"

URUQUIM_APP_COUNT="$(grep -c . <<<"$URUQUIM_APP_SYMBOLS")"
URUQUIM_TS_COUNT="$(grep -c . <<<"$URUQUIM_TS_SYMBOLS")"
test "$URUQUIM_APP_COUNT" -eq 77 ||
  fail "the canonical application ledger is $URUQUIM_APP_COUNT, not 77; docs parity cannot be trusted"
test "$URUQUIM_TS_COUNT" -eq 2 ||
  fail "the canonical test-support ledger is $URUQUIM_TS_COUNT, not 2"

# ---------------------------------------------------------------------------
# ACTIVE documents: the ones a person or agent is meant to copy from today.
#
# `cookbook.md` and `memory-model.md` are whole-file placeholders for later
# phases; they must SAY so at the top, and are not scanned as active.
# `middleware.md` became ACTIVE with WP17.
# ---------------------------------------------------------------------------
URUQUIM_ACTIVE_DOCS=(
  "$URUQUIM_DOCS/ai-context.md"
  "$URUQUIM_DOCS/canonical-patterns.md"
  "$URUQUIM_DOCS/middleware.md"
  "$URUQUIM_DOCS/quick-start.md"
  "$URUQUIM_DOCS/errors.md"
  "$URUQUIM_ROOT/README.md"
)
URUQUIM_PLACEHOLDER_DOCS=(
  "$URUQUIM_DOCS/cookbook.md"
  "$URUQUIM_DOCS/memory-model.md"
)

for URUQUIM_DOC in "${URUQUIM_ACTIVE_DOCS[@]}"; do
  test -f "$URUQUIM_DOC" || fail "active document $URUQUIM_DOC is missing"
done

for URUQUIM_DOC in "${URUQUIM_PLACEHOLDER_DOCS[@]}"; do
  test -f "$URUQUIM_DOC" || continue
  head -n 8 "$URUQUIM_DOC" | grep -qiE 'placeholder|phase [2-4]|future' ||
    fail "$(basename "$URUQUIM_DOC") is a later-phase placeholder but does not say so in its first lines (AMEND-4)"
done

# ---------------------------------------------------------------------------
# 1. Every Odin block in an active document is CLASSIFIED (WP10 D1).
#
# The marker sits on the line immediately above the fence. Exactly four kinds
# are accepted; anything else is unclassified and fails.
# ---------------------------------------------------------------------------
uruquim_check_classification() { # file
  local file="$1"
  awk -v FILE="$file" '
    /^<!-- (compile|fragment|phase|pseudocode):/ { marker = NR; next }
    /^```odin$/ {
      if (marker != NR - 1) {
        printf "%s:%d: unclassified odin block\n", FILE, NR
        bad = 1
      }
      next
    }
    END { exit bad }
  ' "$file" || fail "an Odin block in $(basename "$file") has no classification marker (WP10 D1)"
}

for URUQUIM_DOC in "${URUQUIM_ACTIVE_DOCS[@]}"; do
  uruquim_check_classification "$URUQUIM_DOC"
done
echo "docs: every Odin block in an active document is classified"

# 1b. A `compile:` marker must name a file that exists, and a `fragment:`
#     marker must name a fixture that exists. A marker pointing at nothing is
#     worse than no marker: it claims coverage it does not have.
while IFS= read -r URUQUIM_TARGET; do
  test -f "$URUQUIM_ROOT/$URUQUIM_TARGET" ||
    fail "a doc block claims 'compile: $URUQUIM_TARGET' but that file does not exist"
done < <(grep -rhoE '<!-- compile: [^ ]+ -->' "${URUQUIM_ACTIVE_DOCS[@]}" |
  sed -E 's/<!-- compile: (.*) -->/\1/' | LC_ALL=C sort -u)

URUQUIM_FIXTURES="$URUQUIM_ROOT/tests/wp10-doc-fixtures"
while IFS= read -r URUQUIM_FRAGMENT; do
  test -d "$URUQUIM_FIXTURES" ||
    fail "a doc block claims 'fragment: $URUQUIM_FRAGMENT' but tests/wp10-doc-fixtures/ does not exist"
  grep -rqE "fragment: $URUQUIM_FRAGMENT\b" "$URUQUIM_FIXTURES" ||
    fail "the Phase-1 fragment '$URUQUIM_FRAGMENT' has no compilable fixture in tests/wp10-doc-fixtures/"
done < <(grep -rhoE '<!-- fragment: [^ ]+ -->' "${URUQUIM_ACTIVE_DOCS[@]}" |
  sed -E 's/<!-- fragment: (.*) -->/\1/' | LC_ALL=C sort -u)
echo "docs: every compile/fragment marker resolves to a real file or fixture"

# ---------------------------------------------------------------------------
# 2. Parity: the active reference names all 32 application symbols.
#
# `docs/ai-context.md` is the compact reference an agent is given. A symbol
# missing from it is a symbol an agent will not know exists.
# ---------------------------------------------------------------------------
URUQUIM_AI="$URUQUIM_DOCS/ai-context.md"
URUQUIM_AI_ACTIVE="$(awk '/^## Appendix — future phases/{exit} {print}' "$URUQUIM_AI")"
test -n "$URUQUIM_AI_ACTIVE" || fail "docs/ai-context.md has no active section"

# The search is restricted to CODE CONTEXT — fenced blocks and inline `code`
# spans. A bare-word search would be satisfied by ordinary prose: `text`, `get`,
# `body`, `path` and `query` are all common English words, so "the symbol is
# documented" would be true for a file that never actually names the API. This
# is what makes the parity check mean something.
URUQUIM_AI_CODE="$(awk '/^```/{inb=!inb; next} inb' <<<"$URUQUIM_AI_ACTIVE"
  grep -oE '`[^`]+`' <<<"$URUQUIM_AI_ACTIVE")"

while IFS= read -r URUQUIM_SYMBOL; do
  test -n "$URUQUIM_SYMBOL" || continue
  grep -qE "\b${URUQUIM_SYMBOL}\b" <<<"$URUQUIM_AI_CODE" ||
    fail "public symbol '$URUQUIM_SYMBOL' is missing from the active reference in docs/ai-context.md"
done <<<"$URUQUIM_APP_SYMBOLS"
echo "docs: all $URUQUIM_APP_COUNT application symbols appear in the active reference"

# 2b. The two test-support symbols live in their OWN section, so the ledgers
#     cannot be quietly merged into one number.
grep -qE '^## Testing' <<<"$URUQUIM_AI_ACTIVE" ||
  fail "docs/ai-context.md has no separate Testing section for the test-support ledger"
while IFS= read -r URUQUIM_SYMBOL; do
  test -n "$URUQUIM_SYMBOL" || continue
  grep -qE "\b${URUQUIM_SYMBOL}\b" <<<"$URUQUIM_AI_CODE" ||
    fail "test-support symbol '$URUQUIM_SYMBOL' is missing from docs/ai-context.md"
done <<<"$URUQUIM_TS_SYMBOLS"

# 2c. The documented counts must be the real ones.
grep -qE '\b77\b' <<<"$URUQUIM_AI_ACTIVE" ||
  fail "docs/ai-context.md does not state the 77-symbol application ledger"
grep -qE '\b79\b' <<<"$URUQUIM_AI_ACTIVE" ||
  fail "docs/ai-context.md does not state the 79-symbol union"

# ---------------------------------------------------------------------------
# 3. Method and Status members in the docs match the package.
# ---------------------------------------------------------------------------
URUQUIM_METHODS="$(awk '/^Method :: enum u8 \{/{f=1;next} /^\}/{f=0} f' \
  "$URUQUIM_ROOT/web/request.odin" | sed -E 's:^[[:space:]]*([A-Z_]+),.*:\1:' | grep -E '^[A-Z_]+$')"
while IFS= read -r URUQUIM_MEMBER; do
  grep -qE "\.${URUQUIM_MEMBER}\b" <<<"$URUQUIM_AI_ACTIVE" ||
    fail "Method member '.$URUQUIM_MEMBER' is missing from docs/ai-context.md"
done <<<"$URUQUIM_METHODS"

URUQUIM_STATUSES="$(awk '/^Status :: enum int \{/{f=1;next} /^\}/{f=0} f' \
  "$URUQUIM_ROOT/web/respond.odin" | sed -E 's:^[[:space:]]*([A-Za-z_]+)[[:space:]]*=.*:\1:' |
  grep -E '^[A-Za-z_]+$')"
while IFS= read -r URUQUIM_MEMBER; do
  grep -qE "\.${URUQUIM_MEMBER}\b" <<<"$URUQUIM_AI_ACTIVE" ||
    fail "Status member '.$URUQUIM_MEMBER' is missing from docs/ai-context.md"
done <<<"$URUQUIM_STATUSES"
echo "docs: Method and Status members match the package"

# ---------------------------------------------------------------------------
# 4. No future-phase API inside an ACTIVE section (AMEND-4).
#
# The scan stops at the appendix in ai-context, and at the first future-marked
# heading elsewhere, so a clearly-labelled future section may name them.
# ---------------------------------------------------------------------------
uruquim_active_prose() { # file
  # Drop blocks marked as future or pseudocode, and everything from the future
  # appendix onward.
  awk '
    /^## Appendix — future phases/ { exit }
    /^<!-- (phase|pseudocode):/ { skip = 1; next }
    /^```/ { if (skip && ++fences == 2) { skip = 0; fences = 0 } ; next }
    { if (!skip) print }
  ' "$1"
}

for URUQUIM_DOC in "${URUQUIM_ACTIVE_DOCS[@]}"; do
  URUQUIM_PROSE="$(uruquim_active_prose "$URUQUIM_DOC")"
  # Lines that explicitly name a later phase are allowed to mention the symbol.
  URUQUIM_PROSE="$(grep -viE 'phase [2-4]|future|unavailable|not in phase 1|later phase' <<<"$URUQUIM_PROSE" || true)"
  for URUQUIM_FUTURE in 'web\.group\b' \
    'web\.serve_with\b' 'web\.serve_transport\b' \
    'web\.body_limit\b' 'web\.redirect\b' 'web\.conflict\b'; do
    if grep -nE "$URUQUIM_FUTURE" <<<"$URUQUIM_PROSE"; then
      fail "$(basename "$URUQUIM_DOC") names future API /$URUQUIM_FUTURE/ in an ACTIVE section (AMEND-4)"
    fi
  done
done
echo "docs: no future-phase API appears in an active section"

# ---------------------------------------------------------------------------
# 5. Canonical call-site rules, everywhere in the active docs.
# ---------------------------------------------------------------------------
for URUQUIM_DOC in "${URUQUIM_ACTIVE_DOCS[@]}"; do
  # Every rule here is scoped to CODE BLOCKS, never prose. The documents must be
  # able to NAME a forbidden form in order to forbid it — "do not write
  # `or_else { }`" is guidance, not a violation.
  URUQUIM_CODE_ONLY="$(awk '/^```odin$/{inb=1;next} /^```$/{inb=0;next} inb' "$URUQUIM_DOC" |
    sed -E 's://.*$::')"
  if grep -nE 'or_else[[:space:]]*\{' <<<"$URUQUIM_CODE_ONLY"; then
    fail "$(basename "$URUQUIM_DOC") shows an 'or_else { ... }' block in code, which is not valid Odin"
  fi
  if grep -nE 'web\.(ok|created|json)\([^,)]+,[[:space:]]*&' <<<"$URUQUIM_CODE_ONLY"; then
    fail "$(basename "$URUQUIM_DOC") shows a POINTER payload; Phase-1 payloads are values (ADR-003)"
  fi
  # Comments are stripped above, so a comment that teaches ".GET, never .Get"
  # is not itself a violation.
  if grep -nE '\.(Get|Post|Put|Patch|Delete)\b' <<<"$URUQUIM_CODE_ONLY"; then
    fail "$(basename "$URUQUIM_DOC") uses a mixed-case Method member in code; they are UPPERCASE (.GET)"
  fi
done
echo "docs: canonical call-site rules hold in every active document"

# ---------------------------------------------------------------------------
# 6. No stale status claim survives (the WP10 repair list).
#
# Each of these was TRUE at some earlier work package and is FALSE now. Leaving
# one in place is worse than saying nothing: it tells a reader a working feature
# does not work.
# ---------------------------------------------------------------------------
for URUQUIM_DOC in "${URUQUIM_ACTIVE_DOCS[@]}"; do
  URUQUIM_BODY="$(cat "$URUQUIM_DOC")"
  for URUQUIM_STALE in \
    'serve.*(binds no port|does not bind|returns immediately without binding)' \
    '(responders|response helpers?).*(are|remain|still).*(inert|stubs?)' \
    'web\.body.*(is|remains|still).*(a )?(WP7 )?stub' \
    'body binding.*(does not work|is not implemented)' \
    'not a functional (HTTP )?server' \
    '(404|405).*(bodies are|body is) EMPTY' \
    '(returns|yields|is) the zero status' \
    'WP1 and WP2 are complete' \
    'production.ready'; do
    if grep -niE "$URUQUIM_STALE" <<<"$URUQUIM_BODY"; then
      fail "$(basename "$URUQUIM_DOC") contains a STALE claim matching /$URUQUIM_STALE/ (WP10 D4)"
    fi
  done
done
echo "docs: no stale pre-WP10 status claim remains"

# 6b. The delivered/future split must be present, not implied (AMEND-3).
grep -qiE 'phase 2' "$URUQUIM_AI" ||
  fail "docs/ai-context.md does not name the Phase-2 boundary (AMEND-3)"
grep -qiE '4 MiB' "$URUQUIM_AI" ||
  fail "docs/ai-context.md does not state the fixed 4 MiB body cap (AMEND-3)"

# 6b-2. WP24 — the ownership table is REQUIRED, not optional.
#
# Phase 2 handed users five new borrowed values, and the rule for each was
# spread across a dozen doc comments. A framework that hands out borrowed
# memory owes its users a table, not a habit of mentioning it. The gate
# requires the table AND its four questions, so a future edit cannot quietly
# drop a column and leave rows that answer less than they claim to.
URUQUIM_OWNERSHIP="$URUQUIM_DOCS/canonical-patterns.md"
grep -qiE '^## Who owns what' "$URUQUIM_OWNERSHIP" ||
  fail "docs/canonical-patterns.md has no ownership table (WP24); borrowed values must be answered in ONE place"
for URUQUIM_COLUMN in 'Owner' 'Valid until' 'May it escape' 'Who cleans up'; do
  grep -qF "$URUQUIM_COLUMN" "$URUQUIM_OWNERSHIP" ||
    fail "the ownership table is missing the '$URUQUIM_COLUMN' question; every row answers the same four (WP24)"
done
# Every Phase-2 borrowed value earns a row. A symbol that hands out a view and
# is absent here is exactly the gap the table exists to close.
for URUQUIM_BORROWED in 'web.header' 'bearer_token' 'X-Request-Id' 'Framework_Event' 'Router'; do
  grep -qF "$URUQUIM_BORROWED" "$URUQUIM_OWNERSHIP" ||
    fail "the ownership table has no row covering '$URUQUIM_BORROWED' (WP24)"
done
# R-3 and R-4: an App/Router is never copied, and the zero value is not usable.
grep -qiE 'strings\.Builder' "$URUQUIM_OWNERSHIP" ||
  fail "docs/canonical-patterns.md does not give the strings.Builder analogy for App/Router copying (audit R-3)"
grep -qiE 'zero value is not a usable App|zero value.*not.*usable' "$URUQUIM_OWNERSHIP" ||
  fail "docs/canonical-patterns.md does not state the zero-value App contract (audit R-4)"
# R-10: exactly one server per process, and no stop until Phase 4.
grep -qiE 'one server per process|Exactly one server' "$URUQUIM_OWNERSHIP" ||
  fail "docs/canonical-patterns.md does not state the single-server constraint (audit R-10)"
echo "docs: the ownership table is present with all four questions; R-3, R-4 and R-10 are stated"

# 6c. The Quick Start must be real, not the WP10 placeholder.
grep -qiE '^> Placeholder' "$URUQUIM_DOCS/quick-start.md" &&
  fail "docs/quick-start.md is still the placeholder (WP10 must replace it)"
# The contract is "shows a runnable server", not "uses port 8080" — the
# port number is a teaching choice, free to change without a gate edit (WP16).
grep -qE 'web\.serve\(&app, [0-9]{1,5}\)' "$URUQUIM_DOCS/quick-start.md" ||
  fail "docs/quick-start.md does not show a runnable server (a web.serve(&app, <port>) call)"

# 6d. The Quick Start teaches no internals.
for URUQUIM_INTERNAL in 'allocator' 'odin-http' 'radix' 'arena' 'Advanced API' \
  'middleware cursor' 'transport adapter'; do
  if grep -niE "^[^>]*\b$URUQUIM_INTERNAL\b" "$URUQUIM_DOCS/quick-start.md" |
    grep -viE 'internal|replaceable|behind|note'; then
    fail "docs/quick-start.md teaches an internal concept matching /$URUQUIM_INTERNAL/"
  fi
done
echo "docs: the Quick Start is real and teaches no internals"

# ---------------------------------------------------------------------------
# 6e. WP21 — THE FAULT-BEHAVIOUR STATEMENT (ADR-020, G-08).
#
# This is the half of WP21 that only a documentation gate can hold. ADR-020
# settled that Phase 2 ships NO recovery middleware and no public symbol for
# it: Odin has no recoverable panic, so the promise as written was not hard but
# impossible. What replaced it is the WP8 driver guarantee plus a plain
# statement that a faulting handler aborts the process.
#
# G-08 says a default is claimed only when it is delivered. A document that
# still lists "panic recovery (Phase 2)" among the things that are coming is
# therefore not merely out of date — it claims a default that will NEVER be
# delivered, which is the exact failure G-08 exists to prevent. Both halves are
# asserted: the promise must be gone, AND the honest statement must be present.
# ---------------------------------------------------------------------------
for URUQUIM_DOC in "${URUQUIM_ACTIVE_DOCS[@]}"; do
  URUQUIM_BODY="$(cat "$URUQUIM_DOC")"
  # A line naming recovery AND a phase number is a promise, in any order:
  # "panic recovery (Phase 2)", "recovery (Phase 2)", "Phase 2: ... recovery".
  # The ADR is allowed to be cited on such a line, because a line that names
  # ADR-020 is stating the decision, not making the promise.
  if grep -niE 'recovery' <<<"$URUQUIM_BODY" |
    grep -viE 'ADR-020|no recovery|never|does not exist|not.*recoverable|no recoverable' |
    grep -iE 'phase [2-4]|coming|still ahead|to come|not.*yet'; then
    fail "$(basename "$URUQUIM_DOC") still promises recovery as a future default; ADR-020 says it will NEVER exist (G-08)"
  fi
done

# The positive half. Three documents carry the statement, each for its own
# audience: the error reference, the middleware contract, and the agent
# reference. A reader who lands on any one of them must learn the truth without
# needing the other two.
for URUQUIM_PAIR in \
  "$URUQUIM_DOCS/errors.md" \
  "$URUQUIM_DOCS/middleware.md" \
  "$URUQUIM_DOCS/ai-context.md"; do
  grep -qiE 'abort(s|ed)? the process|process abort' "$URUQUIM_PAIR" ||
    fail "$(basename "$URUQUIM_PAIR") does not state plainly that a faulting handler aborts the process (ADR-020, G-08)"
  grep -qiE 'ADR-020' "$URUQUIM_PAIR" ||
    fail "$(basename "$URUQUIM_PAIR") states the fault behaviour without citing ADR-020, so a reader cannot check it"
done

# The other half of the guarantee — the one that IS delivered — must be stated
# where a reader looks up a 500. A document that says only "a panic aborts"
# would leave them believing an unanswered request produces nothing at all.
grep -qiE 'commits? no response|without responding|no response is committed' "$URUQUIM_DOCS/errors.md" ||
  fail "docs/errors.md does not document the driver guarantee (a dispatch that commits no response becomes the standardized 500)"

# The name is banned as vocabulary, not only as a symbol. "Last-gasp
# responder" is Phase-4 vocabulary and ADR-020 is explicit that it must never
# be shortened to "recovery" — the shortening is how an accepted limitation
# turns back into an unkept promise.
for URUQUIM_DOC in "${URUQUIM_ACTIVE_DOCS[@]}"; do
  if grep -niE 'last.gasp' "$URUQUIM_DOC" | grep -iE 'recovery|recover' |
    grep -viE 'never|not called|must not'; then
    fail "$(basename "$URUQUIM_DOC") calls the Phase-4 last-gasp responder a form of recovery (ADR-020 forbids the shortening)"
  fi
  # The adjacent vocabulary falls with it. "Fault isolation" and "crash
  # recovery" describe a containment boundary Uruquim does not have: a fault
  # takes the process, so there is nothing to isolate it from. Banning the
  # PROMISE while leaving the words that imply it would let the promise back in
  # through the phrasing.
  for URUQUIM_FAULT_WORD in 'fault isolation' 'crash recovery' 'panic recovery'; do
    if grep -niE "$URUQUIM_FAULT_WORD" "$URUQUIM_DOC" |
      grep -viE 'no |never|not |ADR-020|does not exist'; then
      fail "$(basename "$URUQUIM_DOC") uses the phrase '$URUQUIM_FAULT_WORD' affirmatively; a fault aborts the process and nothing is isolated (ADR-020)"
    fi
  done
done
echo "docs: the fault-behaviour statement is present and no document promises recovery (ADR-020)"

# ---------------------------------------------------------------------------
# 7. A discarded speculative product must not return through documentation.
#
# Keep the fragments separated here so the checker does not create the very
# tracked vocabulary it rejects. Ordinary uses of "live" and "rendering" are
# intentionally not banned.
# ---------------------------------------------------------------------------
URUQUIM_REMOVED_PRODUCT_PATTERN='live''view|uruquim[ -]?''live|phoenix[ -]+''live|hot''wire|server[ -]''driven'
if git -C "$URUQUIM_ROOT" grep -I -n -i -E "$URUQUIM_REMOVED_PRODUCT_PATTERN" -- .; then
  fail "discarded speculative product vocabulary returned to a tracked file"
fi
echo "docs: discarded speculative product remains absent"

# ---------------------------------------------------------------------------
# 8. No GitHub Actions workflow (owner decision; the gate is local/VPS).
# ---------------------------------------------------------------------------
if test -d "$URUQUIM_ROOT/.github/workflows"; then
  fail ".github/workflows exists; GitHub Actions is not a mandatory gate for this project"
fi

echo "PASS: documentation parity (ledgers $URUQUIM_APP_COUNT + $URUQUIM_TS_COUNT = $((URUQUIM_APP_COUNT + URUQUIM_TS_COUNT)))"
