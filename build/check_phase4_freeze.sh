#!/usr/bin/env bash
# Phase-4 freeze gate.
#
# Built on the WP38 shape and its lesson: **a frozen total is HISTORY.** This
# pins Phase 4's totals as of the day they were written, checks the document's
# own arithmetic, and separately requires the live ledger not to have SHRUNK —
# so Phase 5 may add freely and a removed symbol is still caught.
#
# It additionally holds the two things this phase would lose first:
#
#   * the record of what was NOT delivered. A freeze that drops those rows
#     reads as a phase that delivered everything, which is the one lie a freeze
#     document can tell just by being tidy;
#   * the record that re-running the mutation suites REPAIRED controls. Three
#     broke because the tree improved, and a freeze that reports "fifteen green"
#     without that has kept the ceremony and lost the point.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_P4="$DRUSE_ROOT/planning/phase-4-freeze.md"

fail() {
  echo "PHASE4-FREEZE-FAIL: $*" >&2
  exit 1
}

test -f "$DRUSE_P4" || fail "planning/phase-4-freeze.md is missing"
DRUSE_FLAT="$(sed -E 's/^[[:space:]]*>[[:space:]]?//' "$DRUSE_P4" | tr '\n' ' ' | tr -s ' ')"

# --- 1. The ledger diff: history, arithmetic, and a floor -------------------
DRUSE_P4_APP=55
DRUSE_P4_UNION=57
DRUSE_P4_FROM=50
DRUSE_P4_FROM_UNION=52

grep -qE "\| application \| $DRUSE_P4_FROM \| \+[0-9]+ \| \*\*$DRUSE_P4_APP\*\* \|" "$DRUSE_P4" ||
  fail "the freeze document no longer records the ledger Phase 4 froze ($DRUSE_P4_APP application). That number is history, not a live measurement."
grep -qE "\| union \| $DRUSE_P4_FROM_UNION \| \+[0-9]+ \| \*\*$DRUSE_P4_UNION\*\* \|" "$DRUSE_P4" ||
  fail "the freeze document no longer records the union Phase 4 froze ($DRUSE_P4_UNION)"

DRUSE_P4_DELTA="$(grep -oE "\| application \| $DRUSE_P4_FROM \| \+[0-9]+ \|" "$DRUSE_P4" | grep -oE '\+[0-9]+' | tr -d '+')"
test "$(( DRUSE_P4_FROM + DRUSE_P4_DELTA ))" -eq "$DRUSE_P4_APP" ||
  fail "the freeze document's own arithmetic does not hold: $DRUSE_P4_FROM + $DRUSE_P4_DELTA is not $DRUSE_P4_APP"

DRUSE_LIVE_APP="$(grep -oE 'DRUSE_APP_COUNT" -ne [0-9]+' "$DRUSE_ROOT/build/check_public_api.sh" | grep -oE '[0-9]+$' | head -1)"
test -n "$DRUSE_LIVE_APP" || fail "could not read the canonical ledger count"
test "$DRUSE_LIVE_APP" -ge "$DRUSE_P4_APP" ||
  fail "the live application ledger is $DRUSE_LIVE_APP, BELOW the $DRUSE_P4_APP Phase 4 froze. A frozen symbol was removed while this document still claims it."

for DRUSE_SYM in stop client_ip trust_proxies secure_headers refused_connections; do
  grep -qE "^\| \`$DRUSE_SYM\` \| proc \| [0-9]+ \| 1[0-9] \|" "$DRUSE_P4" ||
    fail "the freeze document does not record '$DRUSE_SYM' with its work package and freeze amendment"
done
echo "phase-4 freeze: ledger records the frozen $DRUSE_P4_APP application / $DRUSE_P4_UNION union; all five symbols named; live ledger $DRUSE_LIVE_APP has not shrunk"

# --- 2. The three deficiencies, and the one still open -----------------------
# The phase opened by DEFINING what a deficiency is. A freeze that reported
# three closed when one is partial would be the tidiest possible lie.
grep -qiE 'gap between what the framework CLAIMS and what it DOES' <<<"$DRUSE_FLAT" ||
  fail "the freeze no longer states the definition the phase was held to. Without it, 'no deficiencies' is a mood."
grep -qiE 'PARTLY CLOSED' <<<"$DRUSE_FLAT" ||
  fail "the freeze no longer records that one deficiency is only PARTLY closed. stop ships; the drain has no deadline, and saying otherwise is the lie a tidy table tells."
grep -qiE "supervisor'?s kill remains the real deadline" <<<"$DRUSE_FLAT" ||
  fail "the freeze no longer tells an operator what stands in for the missing drain deadline"

# --- 3. What was NOT delivered stays in the document ------------------------
grep -qiE '^## ([0-9]+\. )?What was NOT delivered' "$DRUSE_P4" ||
  fail "the freeze has no section recording what was NOT delivered. A freeze that drops those rows reads as a phase that delivered everything."
for DRUSE_MISSING in 'drain deadline' 'allocator audit' 'fuzzer' 'soak'; do
  grep -qiF "$DRUSE_MISSING" "$DRUSE_P4" ||
    fail "the freeze no longer records '$DRUSE_MISSING' among what was not delivered. The feature is still absent, so the document must keep saying so."
done
grep -qiE 'knob that lies is worse than an absence|worse than the unbounded wait' <<<"$DRUSE_FLAT" ||
  fail "the freeze lost the REASON the drain deadline was withdrawn. 'Not done' and 'tried, measured, and worse than nothing' are different facts."

# --- 4. The mutation re-run, and what it repaired ---------------------------
grep -qiE 'found three broken controls' <<<"$DRUSE_FLAT" ||
  fail "the freeze no longer records that re-running the suites REPAIRED controls. Reporting fifteen green without it keeps the ceremony and loses the point."
grep -qiE 'broke because the tree improved' <<<"$DRUSE_FLAT" ||
  fail "the freeze lost the observation that all three controls broke because the tree got BETTER — the healthy failure mode, and one that only shows up if somebody re-runs them"

# --- 5. Performance is reported without a new claim -------------------------
grep -qiE 'no regression, and no new claim' <<<"$DRUSE_FLAT" ||
  fail "the freeze makes or drops a performance claim without saying which. The instrument's floor is 138%; a percentile from inside it is a number about the machine."
grep -qiE 'keep-alive did not work before' <<<"$DRUSE_FLAT" ||
  fail "the freeze no longer records that the phase's one real performance change was a DEFECT FIX rather than a measurement"

# --- 6. ADR-033 goes to the owner -------------------------------------------
grep -qiE 'ADR-033 is[[:space:]]*\*\*?OPEN|ADR-033 is OPEN' <<<"$DRUSE_FLAT" ||
  fail "the freeze no longer sends ADR-033 to the owner. Three independent findings point at the vendored event loop's boundary, and that is the largest question the project has."

# --- 7. No unfinished-work markers, and no stale deferrals ------------------
if grep -nE '\b(TODO|FIXME|XXX|TBD)\b' "$DRUSE_P4"; then
  fail "planning/phase-4-freeze.md contains an unfinished-work marker"
fi
if grep -nE '^\|.*until Phase [1234]\b' "$DRUSE_P4"; then
  fail "a ledger row in the Phase-4 freeze defers to a phase that has already frozen"
fi

echo "PASS: Phase 4 freeze gate (ledger, deficiencies, what was not delivered, the repaired controls)"
