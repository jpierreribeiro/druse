#!/usr/bin/env bash
# Phase-5 freeze gate.
#
# Built on the WP38/WP56 shape and its lesson: **a frozen total is HISTORY.**
# This pins Phase 5's totals as of the day they were written, checks the
# document's own arithmetic, and separately requires the live ledger not to have
# SHRUNK — so a later phase may add freely while a removed symbol is still
# caught.
#
# It additionally holds the four things this phase would lose first:
#
#   * the record of what was NOT delivered, and large uploads in particular. A
#     freeze that drops those rows reads as a phase that delivered everything,
#     which is the one lie a freeze document can tell just by being tidy;
#   * the record that guardrail 3 was VIOLATED and then fixed. The measurement
#     is the only reason anyone knows the pointer indirection is load-bearing,
#     and a tidy-up that deleted it would leave the next author free to call the
#     file server directly again;
#   * the drain's two defects, because "the drain deadline shipped" is a much
#     smaller statement than "shutdown could hang or crash, and both are fixed";
#   * ADR-033's closure ON ITS STATED TERMS — keep and patch, with the January
#     transition as the declared exit rather than a hypothetical.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_P5="$DRUSE_ROOT/planning/phase-5-freeze.md"

fail() {
  echo "PHASE5-FREEZE-FAIL: $*" >&2
  exit 1
}

test -f "$DRUSE_P5" || fail "planning/phase-5-freeze.md is missing"
DRUSE_FLAT="$(sed -E 's/^[[:space:]]*>[[:space:]]?//' "$DRUSE_P5" | tr '\n' ' ' | tr -s ' ')"

# --- 1. The ledger: history, arithmetic, and a floor ------------------------
grep -qE '\| application \| 55 \| \+7 \| \*\*62\*\* \|' "$DRUSE_P5" ||
  fail "the ledger diff row (55 -> 62) is missing or has been edited"
grep -qE '\| union \| 57 \| \+7 \| \*\*64\*\* \|' "$DRUSE_P5" ||
  fail "the union row (57 -> 64) is missing or has been edited"

# The live ledger must not have shrunk below what this phase froze.
DRUSE_LIVE_APP="$(sed -n '/^DRUSE_EXPECTED_EXPORTS="/,/"$/p' \
  "$DRUSE_ROOT/build/check_public_api.sh" | sed '1s/.*="//' | sed '$s/"$//' | grep -c .)"
test "$DRUSE_LIVE_APP" -ge 62 ||
  fail "the live application ledger is $DRUSE_LIVE_APP, below the 62 Phase 5 froze; a symbol was removed"

# --- 2. The seven symbols are named, individually ---------------------------
for DRUSE_SYM in cors Cors_Options static Static_Options form_field form_file Uploaded_File; do
  grep -q "\`$DRUSE_SYM\`" "$DRUSE_P5" ||
    fail "the freeze does not name '$DRUSE_SYM'; a ledger row without its symbol is a number nobody can check"
done

# `max_drain_time` cost no name and is the phase's headline: it must still be
# named, or the freeze reads as though the drain was never closed.
grep -q 'max_drain_time' "$DRUSE_P5" ||
  fail "the freeze does not name Limits.max_drain_time, which is the deficiency this phase existed to close"

# --- 3. What was NOT delivered stays recorded -------------------------------
case "$DRUSE_FLAT" in
  *"What was NOT delivered"*) ;;
  *) fail "the NOT-delivered section is gone; a freeze without it reads as a phase that delivered everything" ;;
esac
case "$DRUSE_FLAT" in
  *"cannot be accepted at any setting that is not itself a memory problem"*) ;;
  *) fail "the large-upload limitation is no longer stated in its own words" ;;
esac
case "$DRUSE_FLAT" in
  *"CE-E3 stands unamended"*) ;;
  *) fail "the record that CE-E3 was not bent is missing" ;;
esac

# --- 4. Guardrail 3: the violation, the measurement, the fix ----------------
grep -q '20 176' "$DRUSE_P5" ||
  fail "the measured guardrail-3 violation (20,176 bytes) is gone; without it the proc-pointer indirection looks optional"
case "$DRUSE_FLAT" in
  *"proc pointer whose only assignment is inside"*) ;;
  *) fail "the description of the guardrail-3 fix is missing" ;;
esac

# --- 5. The drain's two defects ---------------------------------------------
case "$DRUSE_FLAT" in
  *"unreachable and therefore uncancellable"*) ;;
  *) fail "the drain's root cause (a discarded operation handle) is no longer stated" ;;
esac
case "$DRUSE_FLAT" in
  *"free(): invalid pointer"*) ;;
  *) fail "the use-after-free finding is gone; 'the drain deadline shipped' is a much smaller claim" ;;
esac
case "$DRUSE_FLAT" in
  *"upstream's bug"*) ;;
  *) fail "the record that patch 10 fixes an UPSTREAM defect is missing; it decides whether it is offered upstream" ;;
esac

# --- 6. ADR-033 closed on its stated terms ----------------------------------
case "$DRUSE_FLAT" in
  *"keep and patch"*) ;;
  *) fail "ADR-033's closure is not recorded" ;;
esac
case "$DRUSE_FLAT" in
  *"declared exit"*) ;;
  *) fail "ADR-033 closed without the January transition as its declared exit; that is a different decision" ;;
esac
grep -qE 'BRIDGE' "$DRUSE_P5" ||
  fail "the bridge-patch status of the drain patches is unrecorded; a future reader would mistake a bridge for a foundation"

# --- 7. The controls -------------------------------------------------------
DRUSE_CONTROLS="$(grep -oE 'check_wp[0-9]+_controls\.sh' "$DRUSE_ROOT/build/check.sh" | sort -u | grep -c .)"
test "$DRUSE_CONTROLS" -ge 15 ||
  fail "only $DRUSE_CONTROLS mutation-control scripts are wired into the gate; Phase 4 froze with fifteen"
case "$DRUSE_FLAT" in
  *"none needed repair"*) ;;
  *) fail "the controls section no longer states the outcome; 'sixteen green' without the comparison is ceremony" ;;
esac

# --- 8. The checklist is complete ------------------------------------------
if grep -qE '^- \[ \]' "$DRUSE_P5"; then
  grep -nE '^- \[ \]' "$DRUSE_P5" | sed 's/^/    /' >&2
  fail "the freeze checklist has unticked items"
fi

echo "phase-5 freeze: ledger 62 + 2 = 64, pinned as history with a floor at 62"
echo "phase-5 freeze: the NOT-delivered rows, the guardrail-3 measurement and the two drain defects are all recorded"
echo "phase-5 freeze: ADR-033 closed on keep-and-patch with the January transition as its declared exit"
echo "PASS: Phase 5 is frozen"
