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

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_DOCS="$DRUSE_ROOT/docs"

fail() {
  echo "DOCS-FAIL: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# The canonical ledgers, extracted from the API checker itself.
# ---------------------------------------------------------------------------
DRUSE_APP_SYMBOLS="$(sed -n '/^DRUSE_EXPECTED_EXPORTS="/,/"$/p' \
  "$DRUSE_ROOT/build/check_public_api.sh" | sed '1s/.*="//' | sed '$s/"$//')"
DRUSE_TS_SYMBOLS="$(sed -n '/^DRUSE_EXPECTED_TESTSUPPORT_EXPORTS="/,/"$/p' \
  "$DRUSE_ROOT/build/check_public_api.sh" | sed '1s/.*="//' | sed '$s/"$//')"

DRUSE_APP_COUNT="$(grep -c . <<<"$DRUSE_APP_SYMBOLS")"
DRUSE_TS_COUNT="$(grep -c . <<<"$DRUSE_TS_SYMBOLS")"
test "$DRUSE_APP_COUNT" -eq 80 ||
  fail "the canonical application ledger is $DRUSE_APP_COUNT, not 80; docs parity cannot be trusted"
test "$DRUSE_TS_COUNT" -eq 2 ||
  fail "the canonical test-support ledger is $DRUSE_TS_COUNT, not 2"

# ---------------------------------------------------------------------------
# ACTIVE documents: the ones a person or agent is meant to copy from today.
#
# `cookbook.md` and `memory-model.md` are whole-file placeholders for later
# phases; they must SAY so at the top, and are not scanned as active.
# `middleware.md` became ACTIVE with WP17.
# ---------------------------------------------------------------------------
DRUSE_ACTIVE_DOCS=(
  "$DRUSE_DOCS/ai-context.md"
  "$DRUSE_DOCS/canonical-patterns.md"
  "$DRUSE_DOCS/middleware.md"
  "$DRUSE_DOCS/quick-start.md"
  "$DRUSE_DOCS/errors.md"
  "$DRUSE_ROOT/README.md"
)
DRUSE_PLACEHOLDER_DOCS=(
  "$DRUSE_DOCS/cookbook.md"
  "$DRUSE_DOCS/memory-model.md"
)

for DRUSE_DOC in "${DRUSE_ACTIVE_DOCS[@]}"; do
  test -f "$DRUSE_DOC" || fail "active document $DRUSE_DOC is missing"
done

for DRUSE_DOC in "${DRUSE_PLACEHOLDER_DOCS[@]}"; do
  test -f "$DRUSE_DOC" || continue
  head -n 8 "$DRUSE_DOC" | grep -qiE 'placeholder|phase [2-4]|future' ||
    fail "$(basename "$DRUSE_DOC") is a later-phase placeholder but does not say so in its first lines (AMEND-4)"
done

# ---------------------------------------------------------------------------
# 1. Every Odin block in an active document is CLASSIFIED (WP10 D1).
#
# The marker sits on the line immediately above the fence. Exactly four kinds
# are accepted; anything else is unclassified and fails.
# ---------------------------------------------------------------------------
druse_check_classification() { # file
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

for DRUSE_DOC in "${DRUSE_ACTIVE_DOCS[@]}"; do
  druse_check_classification "$DRUSE_DOC"
done
echo "docs: every Odin block in an active document is classified"

# 1b. A `compile:` marker must name a file that exists, and a `fragment:`
#     marker must name a fixture that exists. A marker pointing at nothing is
#     worse than no marker: it claims coverage it does not have.
while IFS= read -r DRUSE_TARGET; do
  test -f "$DRUSE_ROOT/$DRUSE_TARGET" ||
    fail "a doc block claims 'compile: $DRUSE_TARGET' but that file does not exist"
done < <(grep -rhoE '<!-- compile: [^ ]+ -->' "${DRUSE_ACTIVE_DOCS[@]}" |
  sed -E 's/<!-- compile: (.*) -->/\1/' | LC_ALL=C sort -u)

DRUSE_FIXTURES="$DRUSE_ROOT/tests/wp10-doc-fixtures"
while IFS= read -r DRUSE_FRAGMENT; do
  test -d "$DRUSE_FIXTURES" ||
    fail "a doc block claims 'fragment: $DRUSE_FRAGMENT' but tests/wp10-doc-fixtures/ does not exist"
  grep -rqE "fragment: $DRUSE_FRAGMENT\b" "$DRUSE_FIXTURES" ||
    fail "the Phase-1 fragment '$DRUSE_FRAGMENT' has no compilable fixture in tests/wp10-doc-fixtures/"
done < <(grep -rhoE '<!-- fragment: [^ ]+ -->' "${DRUSE_ACTIVE_DOCS[@]}" |
  sed -E 's/<!-- fragment: (.*) -->/\1/' | LC_ALL=C sort -u)
echo "docs: every compile/fragment marker resolves to a real file or fixture"

# ---------------------------------------------------------------------------
# 2. Parity: the active reference names all 32 application symbols.
#
# `docs/ai-context.md` is the compact reference an agent is given. A symbol
# missing from it is a symbol an agent will not know exists.
# ---------------------------------------------------------------------------
DRUSE_AI="$DRUSE_DOCS/ai-context.md"
DRUSE_AI_ACTIVE="$(awk '/^## Appendix — future phases/{exit} {print}' "$DRUSE_AI")"
test -n "$DRUSE_AI_ACTIVE" || fail "docs/ai-context.md has no active section"

# The search is restricted to CODE CONTEXT — fenced blocks and inline `code`
# spans. A bare-word search would be satisfied by ordinary prose: `text`, `get`,
# `body`, `path` and `query` are all common English words, so "the symbol is
# documented" would be true for a file that never actually names the API. This
# is what makes the parity check mean something.
DRUSE_AI_CODE="$(awk '/^```/{inb=!inb; next} inb' <<<"$DRUSE_AI_ACTIVE"
  grep -oE '`[^`]+`' <<<"$DRUSE_AI_ACTIVE")"

while IFS= read -r DRUSE_SYMBOL; do
  test -n "$DRUSE_SYMBOL" || continue
  grep -qE "\b${DRUSE_SYMBOL}\b" <<<"$DRUSE_AI_CODE" ||
    fail "public symbol '$DRUSE_SYMBOL' is missing from the active reference in docs/ai-context.md"
done <<<"$DRUSE_APP_SYMBOLS"
echo "docs: all $DRUSE_APP_COUNT application symbols appear in the active reference"

# 2b. The two test-support symbols live in their OWN section, so the ledgers
#     cannot be quietly merged into one number.
grep -qE '^## Testing' <<<"$DRUSE_AI_ACTIVE" ||
  fail "docs/ai-context.md has no separate Testing section for the test-support ledger"
while IFS= read -r DRUSE_SYMBOL; do
  test -n "$DRUSE_SYMBOL" || continue
  grep -qE "\b${DRUSE_SYMBOL}\b" <<<"$DRUSE_AI_CODE" ||
    fail "test-support symbol '$DRUSE_SYMBOL' is missing from docs/ai-context.md"
done <<<"$DRUSE_TS_SYMBOLS"

# 2c. The documented counts must be the real ones.
grep -qE '\b80\b' <<<"$DRUSE_AI_ACTIVE" ||
  fail "docs/ai-context.md does not state the 80-symbol application ledger"
grep -qE '\b82\b' <<<"$DRUSE_AI_ACTIVE" ||
  fail "docs/ai-context.md does not state the 82-symbol union"

# ---------------------------------------------------------------------------
# 3. Method and Status members in the docs match the package.
# ---------------------------------------------------------------------------
DRUSE_METHODS="$(awk '/^Method :: enum u8 \{/{f=1;next} /^\}/{f=0} f' \
  "$DRUSE_ROOT/web/request.odin" | sed -E 's:^[[:space:]]*([A-Z_]+),.*:\1:' | grep -E '^[A-Z_]+$')"
while IFS= read -r DRUSE_MEMBER; do
  grep -qE "\.${DRUSE_MEMBER}\b" <<<"$DRUSE_AI_ACTIVE" ||
    fail "Method member '.$DRUSE_MEMBER' is missing from docs/ai-context.md"
done <<<"$DRUSE_METHODS"

DRUSE_STATUSES="$(awk '/^Status :: enum int \{/{f=1;next} /^\}/{f=0} f' \
  "$DRUSE_ROOT/web/respond.odin" | sed -E 's:^[[:space:]]*([A-Za-z_]+)[[:space:]]*=.*:\1:' |
  grep -E '^[A-Za-z_]+$')"
while IFS= read -r DRUSE_MEMBER; do
  grep -qE "\.${DRUSE_MEMBER}\b" <<<"$DRUSE_AI_ACTIVE" ||
    fail "Status member '.$DRUSE_MEMBER' is missing from docs/ai-context.md"
done <<<"$DRUSE_STATUSES"
echo "docs: Method and Status members match the package"

# ---------------------------------------------------------------------------
# 4. No future-phase API inside an ACTIVE section (AMEND-4).
#
# The scan stops at the appendix in ai-context, and at the first future-marked
# heading elsewhere, so a clearly-labelled future section may name them.
# ---------------------------------------------------------------------------
druse_active_prose() { # file
  # Drop blocks marked as future or pseudocode, and everything from the future
  # appendix onward.
  awk '
    /^## Appendix — future phases/ { exit }
    /^<!-- (phase|pseudocode):/ { skip = 1; next }
    /^```/ { if (skip && ++fences == 2) { skip = 0; fences = 0 } ; next }
    { if (!skip) print }
  ' "$1"
}

for DRUSE_DOC in "${DRUSE_ACTIVE_DOCS[@]}"; do
  DRUSE_PROSE="$(druse_active_prose "$DRUSE_DOC")"
  # Lines that explicitly name a later phase are allowed to mention the symbol.
  DRUSE_PROSE="$(grep -viE 'phase [2-4]|future|unavailable|not in phase 1|later phase' <<<"$DRUSE_PROSE" || true)"
  for DRUSE_FUTURE in 'web\.group\b' \
    'web\.serve_with\b' 'web\.serve_transport\b' \
    'web\.body_limit\b' 'web\.redirect\b' 'web\.conflict\b'; do
    if grep -nE "$DRUSE_FUTURE" <<<"$DRUSE_PROSE"; then
      fail "$(basename "$DRUSE_DOC") names future API /$DRUSE_FUTURE/ in an ACTIVE section (AMEND-4)"
    fi
  done
done
echo "docs: no future-phase API appears in an active section"

# ---------------------------------------------------------------------------
# 5. Canonical call-site rules, everywhere in the active docs.
# ---------------------------------------------------------------------------
for DRUSE_DOC in "${DRUSE_ACTIVE_DOCS[@]}"; do
  # Every rule here is scoped to CODE BLOCKS, never prose. The documents must be
  # able to NAME a forbidden form in order to forbid it — "do not write
  # `or_else { }`" is guidance, not a violation.
  DRUSE_CODE_ONLY="$(awk '/^```odin$/{inb=1;next} /^```$/{inb=0;next} inb' "$DRUSE_DOC" |
    sed -E 's://.*$::')"
  if grep -nE 'or_else[[:space:]]*\{' <<<"$DRUSE_CODE_ONLY"; then
    fail "$(basename "$DRUSE_DOC") shows an 'or_else { ... }' block in code, which is not valid Odin"
  fi
  if grep -nE 'web\.(ok|created|json)\([^,)]+,[[:space:]]*&' <<<"$DRUSE_CODE_ONLY"; then
    fail "$(basename "$DRUSE_DOC") shows a POINTER payload; Phase-1 payloads are values (ADR-003)"
  fi
  # Comments are stripped above, so a comment that teaches ".GET, never .Get"
  # is not itself a violation.
  if grep -nE '\.(Get|Post|Put|Patch|Delete)\b' <<<"$DRUSE_CODE_ONLY"; then
    fail "$(basename "$DRUSE_DOC") uses a mixed-case Method member in code; they are UPPERCASE (.GET)"
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
for DRUSE_DOC in "${DRUSE_ACTIVE_DOCS[@]}"; do
  DRUSE_BODY="$(cat "$DRUSE_DOC")"
  for DRUSE_STALE in \
    'serve.*(binds no port|does not bind|returns immediately without binding)' \
    '(responders|response helpers?).*(are|remain|still).*(inert|stubs?)' \
    'web\.body.*(is|remains|still).*(a )?(WP7 )?stub' \
    'body binding.*(does not work|is not implemented)' \
    'not a functional (HTTP )?server' \
    '(404|405).*(bodies are|body is) EMPTY' \
    '(returns|yields|is) the zero status' \
    'WP1 and WP2 are complete' \
    'production.ready'; do
    if grep -niE "$DRUSE_STALE" <<<"$DRUSE_BODY"; then
      fail "$(basename "$DRUSE_DOC") contains a STALE claim matching /$DRUSE_STALE/ (WP10 D4)"
    fi
  done
done
echo "docs: no stale pre-WP10 status claim remains"

# 6b. The delivered/future split must be present, not implied (AMEND-3).
grep -qiE 'phase 2' "$DRUSE_AI" ||
  fail "docs/ai-context.md does not name the Phase-2 boundary (AMEND-3)"
grep -qiE '4 MiB' "$DRUSE_AI" ||
  fail "docs/ai-context.md does not state the fixed 4 MiB body cap (AMEND-3)"

# 6b-2. WP24 — the ownership table is REQUIRED, not optional.
#
# Phase 2 handed users five new borrowed values, and the rule for each was
# spread across a dozen doc comments. A framework that hands out borrowed
# memory owes its users a table, not a habit of mentioning it. The gate
# requires the table AND its four questions, so a future edit cannot quietly
# drop a column and leave rows that answer less than they claim to.
DRUSE_OWNERSHIP="$DRUSE_DOCS/canonical-patterns.md"
grep -qiE '^## Who owns what' "$DRUSE_OWNERSHIP" ||
  fail "docs/canonical-patterns.md has no ownership table (WP24); borrowed values must be answered in ONE place"
for DRUSE_COLUMN in 'Owner' 'Valid until' 'May it escape' 'Who cleans up'; do
  grep -qF "$DRUSE_COLUMN" "$DRUSE_OWNERSHIP" ||
    fail "the ownership table is missing the '$DRUSE_COLUMN' question; every row answers the same four (WP24)"
done
# Every Phase-2 borrowed value earns a row. A symbol that hands out a view and
# is absent here is exactly the gap the table exists to close.
for DRUSE_BORROWED in 'web.header' 'bearer_token' 'X-Request-Id' 'Framework_Event' 'Router'; do
  grep -qF "$DRUSE_BORROWED" "$DRUSE_OWNERSHIP" ||
    fail "the ownership table has no row covering '$DRUSE_BORROWED' (WP24)"
done
# R-3 and R-4: an App/Router is never copied, and the zero value is not usable.
grep -qiE 'strings\.Builder' "$DRUSE_OWNERSHIP" ||
  fail "docs/canonical-patterns.md does not give the strings.Builder analogy for App/Router copying (audit R-3)"
grep -qiE 'zero value is not a usable App|zero value.*not.*usable' "$DRUSE_OWNERSHIP" ||
  fail "docs/canonical-patterns.md does not state the zero-value App contract (audit R-4)"
# R-10: exactly one server per process, and no stop until Phase 4.
grep -qiE 'one server per process|Exactly one server' "$DRUSE_OWNERSHIP" ||
  fail "docs/canonical-patterns.md does not state the single-server constraint (audit R-10)"
echo "docs: the ownership table is present with all four questions; R-3, R-4 and R-10 are stated"

# 6c. The Quick Start must be real, not the WP10 placeholder.
grep -qiE '^> Placeholder' "$DRUSE_DOCS/quick-start.md" &&
  fail "docs/quick-start.md is still the placeholder (WP10 must replace it)"
# The contract is "shows a runnable server", not "uses port 8080" — the
# port number is a teaching choice, free to change without a gate edit (WP16).
grep -qE 'web\.serve\(&app, [0-9]{1,5}\)' "$DRUSE_DOCS/quick-start.md" ||
  fail "docs/quick-start.md does not show a runnable server (a web.serve(&app, <port>) call)"

# 6d. The Quick Start teaches no internals.
for DRUSE_INTERNAL in 'allocator' 'odin-http' 'radix' 'arena' 'Advanced API' \
  'middleware cursor' 'transport adapter'; do
  if grep -niE "^[^>]*\b$DRUSE_INTERNAL\b" "$DRUSE_DOCS/quick-start.md" |
    grep -viE 'internal|replaceable|behind|note'; then
    fail "docs/quick-start.md teaches an internal concept matching /$DRUSE_INTERNAL/"
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
for DRUSE_DOC in "${DRUSE_ACTIVE_DOCS[@]}"; do
  DRUSE_BODY="$(cat "$DRUSE_DOC")"
  # A line naming recovery AND a phase number is a promise, in any order:
  # "panic recovery (Phase 2)", "recovery (Phase 2)", "Phase 2: ... recovery".
  # The ADR is allowed to be cited on such a line, because a line that names
  # ADR-020 is stating the decision, not making the promise.
  if grep -niE 'recovery' <<<"$DRUSE_BODY" |
    grep -viE 'ADR-020|no recovery|never|does not exist|not.*recoverable|no recoverable' |
    grep -iE 'phase [2-4]|coming|still ahead|to come|not.*yet'; then
    fail "$(basename "$DRUSE_DOC") still promises recovery as a future default; ADR-020 says it will NEVER exist (G-08)"
  fi
done

# The positive half. Three documents carry the statement, each for its own
# audience: the error reference, the middleware contract, and the agent
# reference. A reader who lands on any one of them must learn the truth without
# needing the other two.
for DRUSE_PAIR in \
  "$DRUSE_DOCS/errors.md" \
  "$DRUSE_DOCS/middleware.md" \
  "$DRUSE_DOCS/ai-context.md"; do
  grep -qiE 'abort(s|ed)? the process|process abort' "$DRUSE_PAIR" ||
    fail "$(basename "$DRUSE_PAIR") does not state plainly that a faulting handler aborts the process (ADR-020, G-08)"
  grep -qiE 'ADR-020' "$DRUSE_PAIR" ||
    fail "$(basename "$DRUSE_PAIR") states the fault behaviour without citing ADR-020, so a reader cannot check it"
done

# The other half of the guarantee — the one that IS delivered — must be stated
# where a reader looks up a 500. A document that says only "a panic aborts"
# would leave them believing an unanswered request produces nothing at all.
grep -qiE 'commits? no response|without responding|no response is committed' "$DRUSE_DOCS/errors.md" ||
  fail "docs/errors.md does not document the driver guarantee (a dispatch that commits no response becomes the standardized 500)"

# The name is banned as vocabulary, not only as a symbol. "Last-gasp
# responder" is Phase-4 vocabulary and ADR-020 is explicit that it must never
# be shortened to "recovery" — the shortening is how an accepted limitation
# turns back into an unkept promise.
for DRUSE_DOC in "${DRUSE_ACTIVE_DOCS[@]}"; do
  if grep -niE 'last.gasp' "$DRUSE_DOC" | grep -iE 'recovery|recover' |
    grep -viE 'never|not called|must not'; then
    fail "$(basename "$DRUSE_DOC") calls the Phase-4 last-gasp responder a form of recovery (ADR-020 forbids the shortening)"
  fi
  # The adjacent vocabulary falls with it. "Fault isolation" and "crash
  # recovery" describe a containment boundary Druse does not have: a fault
  # takes the process, so there is nothing to isolate it from. Banning the
  # PROMISE while leaving the words that imply it would let the promise back in
  # through the phrasing.
  for DRUSE_FAULT_WORD in 'fault isolation' 'crash recovery' 'panic recovery'; do
    if grep -niE "$DRUSE_FAULT_WORD" "$DRUSE_DOC" |
      grep -viE 'no |never|not |ADR-020|does not exist'; then
      fail "$(basename "$DRUSE_DOC") uses the phrase '$DRUSE_FAULT_WORD' affirmatively; a fault aborts the process and nothing is isolated (ADR-020)"
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
DRUSE_REMOVED_PRODUCT_PATTERN='live''view|druse[ -]?''live|phoenix[ -]+''live|hot''wire|server[ -]''driven'
if git -C "$DRUSE_ROOT" grep -I -n -i -E "$DRUSE_REMOVED_PRODUCT_PATTERN" -- .; then
  fail "discarded speculative product vocabulary returned to a tracked file"
fi
echo "docs: discarded speculative product remains absent"



# ---------------------------------------------------------------------------
# 9. The teaching guide (docs/guide/), added on main by the documentation
#    programme. Four checks it brought with it, kept as it wrote them.
#
#    They arrived in a rewrite that replaced this file wholesale, dropping
#    sections 1-8 above. Every document those sections guard is still shipped,
#    so the guarantees were not retired with their subject matter -- they were
#    simply lost. Both sets run here now, which is what this file's own opening
#    line has always claimed.
# ---------------------------------------------------------------------------
cd "$DRUSE_ROOT"
python3 build/check_docs_symbols.py
python3 build/check_docs_arity.py
python3 build/check_docs_coverage.py
python3 build/gen_cookbook.py --check
python3 build/gen_reference.py --check
python3 - <<'PY'
import re,os,glob,sys
bad=[]
for p in glob.glob('docs/**/*.md',recursive=True):
    d=os.path.dirname(p)
    for m in re.finditer(r'\]\(([^)#][^)]*)\)', open(p).read()):
        t=m.group(1)
        if t.startswith(('http','mailto')): continue
        if not os.path.exists(os.path.normpath(os.path.join(d,t))): bad.append(f"{p} -> {t}")
print("internal links:", "\n  ".join(bad) if bad else "  every link resolves")
sys.exit(1 if bad else 0)
PY
python3 - <<'PY'
import glob,sys,os
CAP={'01-concepts':150,'02-build-notes':250,'03-subjects':120,'04-rules':200,
     '05-recipes':90,'06-cookbook':400}
bad=[]
for p in glob.glob('docs/guide/**/*.md',recursive=True):
    d=os.path.basename(os.path.dirname(p))
    n=sum(1 for _ in open(p))
    if d in CAP and n > CAP[d]: bad.append(f"{p}: {n} > {CAP[d]}")
print("size budgets:", "\n  ".join(bad) if bad else "  every page within budget")
sys.exit(1 if bad else 0)
PY

echo "PASS: documentation parity (ledgers $DRUSE_APP_COUNT + $DRUSE_TS_COUNT = $((DRUSE_APP_COUNT + DRUSE_TS_COUNT)))"
echo "documentation checks: all green"
