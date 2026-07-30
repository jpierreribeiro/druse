#!/usr/bin/env bash
# Phase-2 freeze gate — the CLAIMS, not only the API.
#
# `check_phase1_freeze.sh` freezes symbols, signatures and dependencies. This
# script freezes the project's own SENTENCES, which Phase 1 did not, and which
# the reference study argues is the gap that closes last: prose has no compiler, so
# it drifts while every test stays green. Druse has already lived a small
# version of that — WP21 found three documents still promising a "panic
# recovery (Phase 2)" that ADR-020 had made impossible.
#
# It enforces the three ledgers the owner accepted in docket D-2:
#
#   1. CLAIM ledger    — every strong promise carries a NEGATIVE control and an
#                        explicit statement of what it does NOT guarantee. A
#                        claim without a negative control does not freeze.
#   2. LIFETIME ledger — owner / validity / may-it-escape / cleanup, one row per
#                        value a user can touch.
#   3. CAPACITY ledger — fixed, dynamic-at-registration, bounded-per-request,
#                        and — the column that keeps the word honest — what
#                        remains UNBOUNDED or delegated to the transport.
#
# The rule this gate exists to hold: "bounded" is never claimed for the
# framework as a whole while connections, queues and header counts belong to
# the transport. Name the perimeter, or do not use the word.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_P2="$DRUSE_ROOT/planning/phase-2-freeze.md"

fail() {
  echo "PHASE2-FREEZE-FAIL: $*" >&2
  exit 1
}

test -f "$DRUSE_P2" ||
  fail "planning/phase-2-freeze.md does not exist; Phase 2 cannot be frozen without it (WP25)"

# ---------------------------------------------------------------------------
# 1. The ledger counts agree with the CANONICAL source.
#
# Read out of check_public_api.sh rather than restated, so the freeze document
# cannot drift from the package while both still look green — the same
# technique check_docs.sh uses.
# ---------------------------------------------------------------------------
DRUSE_APP_COUNT="$(grep -oE 'DRUSE_APP_COUNT" -ne [0-9]+' "$DRUSE_ROOT/build/check_public_api.sh" |
  grep -oE '[0-9]+$' | head -1)"
DRUSE_UNION_COUNT="$(grep -oE 'DRUSE_UNION" -ne [0-9]+' "$DRUSE_ROOT/build/check_public_api.sh" |
  grep -oE '[0-9]+$' | head -1)"
test -n "$DRUSE_APP_COUNT" && test -n "$DRUSE_UNION_COUNT" ||
  fail "could not read the canonical ledger counts out of build/check_public_api.sh"

# WHAT THIS DOCUMENT'S NUMBERS ARE, and WP34 is the work package that forced the
# distinction. The table records what Phase 2 FROZE — 32 + 12 = 44 — which is a
# historical fact and must not move when a later phase adds a symbol. The
# original check compared it against the LIVE canonical count, which was
# indistinguishable from correct for as long as no phase grew the ledger after
# Phase 2, and went red the moment one did. A freeze document that has to be
# edited every time a later phase ships is not a freeze.
#
# So the anti-drift force is kept and re-aimed. Three assertions:
#
#   * the recorded Phase-2 totals are exactly the frozen 44 and 46 — the doc
#     cannot be quietly restated;
#   * its own arithmetic holds (32 + delta = total, 34 + delta = union), so a
#     hand-edited delta fails;
#   * the LIVE ledger is >= the frozen total. Phase 3 may add; nothing may
#     silently remove a symbol Phase 2 froze and leave this document claiming it.
DRUSE_P2_APP=44
DRUSE_P2_UNION=46

grep -qE "\| application \| 32 \| \+[0-9]+ \| \*\*$DRUSE_P2_APP\*\* \|" "$DRUSE_P2" ||
  fail "the freeze document no longer records the ledger Phase 2 froze ($DRUSE_P2_APP application). That number is history, not a live measurement: it must not be edited to track a later phase."
grep -qE "\| union \| 34 \| \+[0-9]+ \| \*\*$DRUSE_P2_UNION\*\* \|" "$DRUSE_P2" ||
  fail "the freeze document no longer records the union Phase 2 froze ($DRUSE_P2_UNION)"

DRUSE_P2_DELTA="$(grep -oE "\| application \| 32 \| \+[0-9]+ \|" "$DRUSE_P2" | grep -oE '[0-9]+ \|$' | grep -oE '[0-9]+')"
test "$(( 32 + DRUSE_P2_DELTA ))" -eq "$DRUSE_P2_APP" ||
  fail "the freeze document's own arithmetic does not hold: 32 + $DRUSE_P2_DELTA is not $DRUSE_P2_APP"
DRUSE_P2_UNION_DELTA="$(grep -oE "\| union \| 34 \| \+[0-9]+ \|" "$DRUSE_P2" | grep -oE '[0-9]+ \|$' | grep -oE '[0-9]+')"
test "$(( 34 + DRUSE_P2_UNION_DELTA ))" -eq "$DRUSE_P2_UNION" ||
  fail "the freeze document's own arithmetic does not hold: 34 + $DRUSE_P2_UNION_DELTA is not $DRUSE_P2_UNION"

test "$DRUSE_APP_COUNT" -ge "$DRUSE_P2_APP" ||
  fail "the live application ledger is $DRUSE_APP_COUNT, BELOW the $DRUSE_P2_APP Phase 2 froze. A frozen symbol was removed while this document still claims it."
test "$DRUSE_UNION_COUNT" -ge "$DRUSE_P2_UNION" ||
  fail "the live exported union is $DRUSE_UNION_COUNT, below the $DRUSE_P2_UNION Phase 2 froze"

echo "phase-2 freeze: ledger diff records the frozen $DRUSE_P2_APP application / $DRUSE_P2_UNION union; the live ledger is $DRUSE_APP_COUNT / $DRUSE_UNION_COUNT and has not shrunk"

# ---------------------------------------------------------------------------
# 2. CLAIM ledger — every claim carries a negative control.
#
# This is the assertion that does the real work. A claim with a positive test
# and no negative control is a claim nobody has tried to break.
# ---------------------------------------------------------------------------
grep -qE '^## ([0-9]+\. )?Claim ledger' "$DRUSE_P2" || fail "the freeze document has no claim ledger (D-2)"

DRUSE_CLAIMS="$(grep -cE '^### C-[0-9]+' "$DRUSE_P2" || true)"
test "$DRUSE_CLAIMS" -ge 5 ||
  fail "the claim ledger holds only $DRUSE_CLAIMS claims; the project makes more strong promises than that"

# Each claim section must carry all four load-bearing fields. Checked per
# section, not per document: a single negative control somewhere would
# otherwise satisfy a table full of unverified claims.
DRUSE_MISSING_CONTROL=0
while IFS= read -r DRUSE_CLAIM; do
  DRUSE_SECTION="$(awk -v id="$DRUSE_CLAIM" '
    $0 ~ "^### " id " " { on = 1; next }
    on && /^### |^## / { exit }
    on { print }
  ' "$DRUSE_P2")"

  for DRUSE_FIELD in 'Negative control' 'Does NOT guarantee' 'Positive test'; do
    grep -qF "$DRUSE_FIELD" <<<"$DRUSE_SECTION" || {
      echo "    $DRUSE_CLAIM has no '$DRUSE_FIELD' entry" >&2
      DRUSE_MISSING_CONTROL=$(( DRUSE_MISSING_CONTROL + 1 ))
    }
  done
done < <(grep -oE '^### C-[0-9]+' "$DRUSE_P2" | sed 's/^### //')

test "$DRUSE_MISSING_CONTROL" -eq 0 ||
  fail "$DRUSE_MISSING_CONTROL claim field(s) are missing. A claim with no negative control does not freeze (D-2): it is a promise nobody has tried to break."
echo "phase-2 freeze: claim ledger -> $DRUSE_CLAIMS claims, each with a positive test, a negative control and a stated non-guarantee"

# Every evidence citation in the freeze document must resolve, exactly as the
# Phase-1 manifest's do. A claim pointing at a test that does not exist is
# worse than no claim.
DRUSE_BAD_REFS=0
while IFS= read -r DRUSE_REF; do
  [ -n "$DRUSE_REF" ] || continue
  test -e "$DRUSE_ROOT/$DRUSE_REF" || {
    echo "    broken citation: $DRUSE_REF (no such file)" >&2
    DRUSE_BAD_REFS=$(( DRUSE_BAD_REFS + 1 ))
  }
done < <(grep -oE '(build|tests|web|docs|planning|examples)/[A-Za-z0-9_./-]+\.(sh|odin|md|txt)' "$DRUSE_P2" |
  LC_ALL=C sort -u)
test "$DRUSE_BAD_REFS" -eq 0 ||
  fail "$DRUSE_BAD_REFS citation(s) in the freeze document do not resolve"
echo "phase-2 freeze: every claim citation resolves to a real file"

# ---------------------------------------------------------------------------
# 3. LIFETIME ledger — the four questions, again, in the frozen record.
# ---------------------------------------------------------------------------
grep -qE '^## ([0-9]+\. )?Lifetime ledger' "$DRUSE_P2" || fail "the freeze document has no lifetime ledger (D-2)"
for DRUSE_COLUMN in 'Owner' 'Valid until' 'May it escape' 'Who cleans up'; do
  grep -qF "$DRUSE_COLUMN" "$DRUSE_P2" ||
    fail "the lifetime ledger is missing the '$DRUSE_COLUMN' question"
done
grep -qiE 'only .Framework_Event. may escape' "$DRUSE_P2" ||
  fail "the lifetime ledger does not state the one-sentence rule (only Framework_Event may escape a request)"
echo "phase-2 freeze: lifetime ledger -> four questions present, one-sentence rule stated"

# ---------------------------------------------------------------------------
# 4. CAPACITY ledger — and the honest word.
#
# The unbounded column is the whole point. A capacity ledger that lists only
# what IS bounded is marketing.
# ---------------------------------------------------------------------------
grep -qE '^## ([0-9]+\. )?Capacity ledger' "$DRUSE_P2" || fail "the freeze document has no capacity ledger (D-2)"
for DRUSE_SECTION in 'Fixed at compile time' 'Dynamic at registration' 'Bounded per request' 'Unbounded, or delegated'; do
  grep -qF "$DRUSE_SECTION" "$DRUSE_P2" ||
    fail "the capacity ledger is missing its '$DRUSE_SECTION' section; all four perimeters must be named"
done

# The things this framework does NOT bound must be named, by name. Each is a way
# "bounded" could become a lie if it stopped being written down.
#
# AMENDED AT THE PHASE-4 FREEZE, and the amendment is progress rather than
# drift: **`concurrent connections` is now BOUNDED** (WP47's
# `Limits.max_connections`), so requiring the ledger to name it as unbounded had
# become a check that enforced a stale fact. It is still required to be NAMED —
# a resource that vanishes from the ledger is a resource nobody can find the
# bound for — but as a row rather than as an admission.
#
# What remains genuinely unbounded is shorter than it was, which is what a
# production phase is supposed to do to this list.
for DRUSE_UNBOUNDED in 'backlog' 'header count'; do
  grep -qiF "$DRUSE_UNBOUNDED" "$DRUSE_P2" ||
    fail "the capacity ledger does not name '$DRUSE_UNBOUNDED' as unbounded/delegated; the honest word depends on saying so"
done
# Still named, now as a bounded row.
grep -qiF 'concurrent connections' "$DRUSE_P2" ||
  fail "the capacity ledger no longer names 'concurrent connections' at all. It is BOUNDED since WP47, and a bounded resource still needs its row — otherwise nobody can find what the bound is."

# The unbounded rows must still SAY they are unbounded. Naming a resource and
# then describing it as bounded when it is not is the exact failure the section
# exists to prevent, and a name-only check cannot see it.
DRUSE_UNBOUNDED_ROWS="$(grep -cE '^\|.*(not bounded by this framework|still not bounded)' "$DRUSE_P2" || true)"
test "$DRUSE_UNBOUNDED_ROWS" -ge 2 ||
  fail "the capacity ledger has $DRUSE_UNBOUNDED_ROWS rows still declaring themselves unbounded, fewer than the 2 that genuinely are. A ledger that lists only what IS bounded is marketing."

grep -qiE 'does not bound the server|not bound(ed)? by this framework' "$DRUSE_P2" ||
  fail "the capacity ledger never states which perimeter is NOT bounded (D-2)"
echo "phase-2 freeze: capacity ledger -> four perimeters, and the unbounded ones named"

# ---------------------------------------------------------------------------
# 5. No document may claim the framework as a whole is "bounded".
#
# The rule stated as a scan. "bounded" is fine beside a named perimeter (a
# buffer, a request, a body); it is not fine as a property of the framework or
# the server.
# ---------------------------------------------------------------------------
for DRUSE_DOC in "$DRUSE_ROOT/README.md" "$DRUSE_ROOT"/docs/*.md; do
  test -f "$DRUSE_DOC" || continue
  if grep -niE '(druse|the framework|the server) (is|are) (fully )?bounded' "$DRUSE_DOC"; then
    fail "$(basename "$DRUSE_DOC") claims the framework/server as a whole is bounded; name the perimeter (D-2 capacity ledger)"
  fi
done
echo "phase-2 freeze: no document claims the framework as a whole is bounded"

# ---------------------------------------------------------------------------
# 6. The usage-laboratory finding must survive.
#
# A concept-count increase is a FINDING, not a footnote, and a later edit that
# quietly drops it turns an honest report into a flattering one.
# ---------------------------------------------------------------------------
grep -qE '^## ([0-9]+\. )?Usage laboratory, re-run' "$DRUSE_P2" ||
  fail "the freeze document does not re-run the usage laboratory (WP25)"
# Anchored to the SECTION's own heading, not to the words "is a finding": the
# document quotes the plan's "that is a finding, not a footnote" earlier on, and
# a looser pattern matched that quotation while the actual finding had been
# softened away. A control caught exactly that.
grep -qF 'The finding, stated as a finding.' "$DRUSE_P2" ||
  fail "the usage-laboratory section no longer reports its concept growth AS A FINDING; quoting the rule is not the same as obeying it"
echo "phase-2 freeze: usage laboratory re-run, concept growth reported as a finding"

echo "PASS: Phase 2 freeze gate (claims, lifetimes and capacities, not only the API)"
