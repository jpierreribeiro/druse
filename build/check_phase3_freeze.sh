#!/usr/bin/env bash
# Phase-3 freeze gate.
#
# It checks `planning/phase-3-freeze.md` the way `check_phase2_freeze.sh` checks
# its own document: not that the file exists, but that it still SAYS the things
# a freeze is only worth having if it says.
#
# WHAT IT LEARNED FROM ITS PREDECESSOR, and this is the reason it is written
# this way rather than copied. The Phase-2 gate compared that document's ledger
# diff against the LIVE symbol count. That was indistinguishable from correct
# for as long as no phase grew the ledger afterwards — and went red the moment
# WP34 did, because 44 is what Phase 2 FROZE: a historical fact, not a live
# measurement. A freeze document that must be edited whenever a later phase
# ships is not a freeze.
#
# So this gate pins Phase 3's totals as history from the day they are written,
# checks the document's own arithmetic, and separately requires the LIVE ledger
# not to have SHRUNK below them — which catches the thing the live comparison
# was actually protecting against: a frozen symbol quietly removed while a
# document still claims it. Phase 4 may add freely.
#
# The rest is the Phase-2 shape: a freeze that no longer records its ledger
# amendments, its mutation re-run, its cost measurements or its usage-lab number
# has become a title page.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_P3="$DRUSE_ROOT/planning/phase-3-freeze.md"

fail() {
  echo "PHASE3-FREEZE-FAIL: $*" >&2
  exit 1
}

test -f "$DRUSE_P3" || fail "planning/phase-3-freeze.md is missing"

# ---------------------------------------------------------------------------
# 1. The ledger diff: Phase 3's own totals, its arithmetic, and the live floor.
# ---------------------------------------------------------------------------
DRUSE_P3_APP=50
DRUSE_P3_UNION=52
DRUSE_P3_FROM=44
DRUSE_P3_FROM_UNION=46

grep -qE "\| application \| $DRUSE_P3_FROM \| \+[0-9]+ \| \*\*$DRUSE_P3_APP\*\* \|" "$DRUSE_P3" ||
  fail "the freeze document no longer records the ledger Phase 3 froze ($DRUSE_P3_APP application, from $DRUSE_P3_FROM). That number is history, not a live measurement."
grep -qE "\| union \| $DRUSE_P3_FROM_UNION \| \+[0-9]+ \| \*\*$DRUSE_P3_UNION\*\* \|" "$DRUSE_P3" ||
  fail "the freeze document no longer records the union Phase 3 froze ($DRUSE_P3_UNION)"

DRUSE_P3_DELTA="$(grep -oE "\| application \| $DRUSE_P3_FROM \| \+[0-9]+ \|" "$DRUSE_P3" | grep -oE '\+[0-9]+' | tr -d '+')"
test "$(( DRUSE_P3_FROM + DRUSE_P3_DELTA ))" -eq "$DRUSE_P3_APP" ||
  fail "the freeze document's own arithmetic does not hold: $DRUSE_P3_FROM + $DRUSE_P3_DELTA is not $DRUSE_P3_APP"

# The live counts, read out of check_public_api.sh rather than restated, so the
# floor cannot drift from the package while both still look green.
DRUSE_LIVE_APP="$(grep -oE 'DRUSE_APP_COUNT" -ne [0-9]+' "$DRUSE_ROOT/build/check_public_api.sh" |
  grep -oE '[0-9]+$' | head -1)"
DRUSE_LIVE_UNION="$(grep -oE 'DRUSE_UNION" -ne [0-9]+' "$DRUSE_ROOT/build/check_public_api.sh" |
  grep -oE '[0-9]+$' | head -1)"
test -n "$DRUSE_LIVE_APP" && test -n "$DRUSE_LIVE_UNION" ||
  fail "could not read the canonical ledger counts out of build/check_public_api.sh"
test "$DRUSE_LIVE_APP" -ge "$DRUSE_P3_APP" ||
  fail "the live application ledger is $DRUSE_LIVE_APP, BELOW the $DRUSE_P3_APP Phase 3 froze. A frozen symbol was removed while this document still claims it."
test "$DRUSE_LIVE_UNION" -ge "$DRUSE_P3_UNION" ||
  fail "the live exported union is $DRUSE_LIVE_UNION, below the $DRUSE_P3_UNION Phase 3 froze"

# Every frozen symbol is named, with its amendment. A symbol dropped from the
# table is a symbol whose evidence nobody can find.
for DRUSE_SYM in route app_with_state state Limits DEFAULT_LIMITS limits; do
  grep -qE "^\| \`$DRUSE_SYM\` \| (proc|type|const) \| [0-9]+ \| 1[0-2] \|" "$DRUSE_P3" ||
    fail "the freeze document does not record '$DRUSE_SYM' with its work package and freeze amendment"
done
echo "phase-3 freeze: ledger diff records the frozen $DRUSE_P3_APP application / $DRUSE_P3_UNION union; all six symbols named; the live ledger is $DRUSE_LIVE_APP / $DRUSE_LIVE_UNION and has not shrunk"

# ---------------------------------------------------------------------------
# 2. The three ledgers were AMENDED, not appended to.
#
# The plan's word, and the distinction it protects: a freeze that appends leaves
# two answers to one question standing. Each is required by name, and the
# Phase-2 document must actually carry the amendment.
# ---------------------------------------------------------------------------
grep -qiE '^### Claim ledger' "$DRUSE_P3" ||
  fail "the freeze document does not record a claim-ledger amendment"
grep -qiE '^### Lifetime ledger' "$DRUSE_P3" ||
  fail "the freeze document does not record a lifetime-ledger amendment"
grep -qiE '^### Capacity ledger' "$DRUSE_P3" ||
  fail "the freeze document does not record a capacity-ledger amendment"

DRUSE_P2="$DRUSE_ROOT/planning/phase-2-freeze.md"
grep -qE '^### C-10' "$DRUSE_P2" ||
  fail "planning/phase-2-freeze.md has no C-10; Phase 3's new promise must join the CLAIM LEDGER itself, not only be described in the Phase-3 document"
grep -qiE 'negative control' "$DRUSE_P2" ||
  fail "the claim ledger lost its negative-control column"
grep -qiE 'web\.state|application state' "$DRUSE_P2" ||
  fail "the lifetime ledger does not carry the WP37 borrowed value"
grep -qiE 'configurable' "$DRUSE_P2" ||
  fail "the capacity ledger still records the body cap as fixed; FINDING-C is not discharged"
grep -qE '4 MiB, fixed, not configurable until Phase 3' "$DRUSE_P2" &&
  fail "the capacity ledger still carries the pre-WP36 row verbatim; the row had to be AMENDED, not left beside a new one"
echo "phase-3 freeze: the claim, lifetime and capacity ledgers are amended in place"

# ---------------------------------------------------------------------------
# 3. The mutation re-run, and what it found.
#
# "Every suite re-run" is only worth recording if the record survives. This
# additionally requires the document to keep the finding: a control that had
# STOPPED isolating its defect. A freeze that reports thirteen green suites and
# drops the one thing the re-run discovered has kept the ceremony and lost the
# point.
# ---------------------------------------------------------------------------
grep -qiE 'mutation suites?, all re-run|mutation suites re-run' "$DRUSE_P3" ||
  fail "the freeze document does not record the mutation-suite re-run"
grep -qE '\bWP3[67]\b' "$DRUSE_P3" ||
  fail "the mutation table does not list the suites Phase 3 added"
grep -qiE 're-aimed|stopped isolating|stayed \*\*green\*\*|stayed green' "$DRUSE_P3" ||
  fail "the freeze document no longer records that re-running the suites found a control that had stopped working. That finding is the reason the step exists; dropping it turns the re-run into ceremony."
echo "phase-3 freeze: mutation suites re-run, and the control the re-run repaired is recorded"

# ---------------------------------------------------------------------------
# 4. Cost measurements, INCLUDING the one that failed.
#
# The plan asked for `nm` with positive controls. The honest outcome was that
# the measurement could not be made — the symbols inline away and emit nothing
# even when used, which the positive control is how anyone knows. A freeze that
# quietly dropped that would be claiming a measurement it does not have.
# ---------------------------------------------------------------------------
grep -qiE 'positive control' "$DRUSE_P3" ||
  fail "the freeze document does not record a positive control for its cost measurement"
grep -qiE 'could not be made|could not resolve|cannot resolve|failed' "$DRUSE_P3" ||
  fail "the freeze document no longer records that a cost measurement FAILED. A freeze may not upgrade an unmeasurable property into a silent one."
grep -qiE 'no such claim|makes no such claim|none made' "$DRUSE_P3" ||
  fail "the freeze document must state plainly that Phase 3 makes no 'costs nothing when unused' claim; an unbacked cost claim is exactly what the nm step exists to prevent"
echo "phase-3 freeze: cost measurements recorded, including the one that could not be made"

# ---------------------------------------------------------------------------
# 5. The regression benchmark, with its tolerance AND its limits.
# ---------------------------------------------------------------------------
grep -qiE 'tolerance' "$DRUSE_P3" ||
  fail "the freeze document does not state the benchmark tolerance"
grep -qiE 'basis points|\bbp\b' "$DRUSE_P3" ||
  fail "the benchmark tolerance is not stated in the units the harness derives"
grep -qiE 'flat' "$DRUSE_P3" ||
  fail "the freeze document no longer records the flat-dispatch property, which is the one structural claim the benchmark can still support"
echo "phase-3 freeze: regression benchmark re-run, tolerance derived and its limits stated"

# ---------------------------------------------------------------------------
# 6. The usage laboratory, its budget, and its preserved instrument.
#
# The budget is the ADR-029 delegation's own stopping condition: over 25
# concepts and the freeze goes to the owner. The number must therefore be in the
# document, and the instrument must be in the repository — Phase 2 kept only the
# number, which is why this re-run had to reconstruct the programs.
# ---------------------------------------------------------------------------
grep -qiE '^## ([0-9]+\. )?Usage laboratory' "$DRUSE_P3" ||
  fail "the freeze document does not re-run the usage laboratory"
grep -qE '\bNO BREACH\b|\bno breach\b' "$DRUSE_P3" ||
  fail "the freeze document does not state the budget outcome. If the guarded program exceeded 25 concepts the document must SAY SO in those words and stop for the owner (ADR-029)."
test -d "$DRUSE_ROOT/experiments/11-usage-lab" ||
  fail "experiments/11-usage-lab/ is missing; the usage-laboratory instrument must be preserved so the next freeze re-runs instead of reconstructing"
test -x "$DRUSE_ROOT/experiments/11-usage-lab/count_concepts.sh" ||
  fail "the usage-laboratory counting rule is not preserved as an executable instrument"
DRUSE_LAB_GUARDED="$(bash "$DRUSE_ROOT/experiments/11-usage-lab/count_concepts.sh" \
  "$DRUSE_ROOT/experiments/11-usage-lab/c-crud-phase3" | cut -f1)"
test -n "$DRUSE_LAB_GUARDED" ||
  fail "the usage-laboratory instrument produced no count"
test "$DRUSE_LAB_GUARDED" -le 25 ||
  fail "the guarded usage-lab program now needs $DRUSE_LAB_GUARDED concepts, past the 25 the delegation set as a stopping condition. This is a RESERVED MATTER: it goes to the owner, not into a raised ceiling."
grep -qE "\| \*\*$DRUSE_LAB_GUARDED\*\* \|" "$DRUSE_P3" ||
  fail "the freeze document does not record the guarded program's measured count ($DRUSE_LAB_GUARDED); the instrument and the document must agree"
echo "phase-3 freeze: usage laboratory re-run from a PRESERVED instrument -> guarded program $DRUSE_LAB_GUARDED concepts, budget 25"

# ---------------------------------------------------------------------------
# 7. What Phase 3 deliberately did NOT do.
#
# The Phase-1 freeze gate requires its forwarded-items table by name, for the
# reason it states: deleting a row is how a limitation quietly becomes a claim.
# Same rule, Phase 3's items. Timeouts are the one that matters most — the
# absence is a decision with evidence behind it, not an oversight.
# ---------------------------------------------------------------------------
for DRUSE_ABSENT in 'timeout' 'request-scoped' 'normalis' '501' 'graceful'; do
  grep -qiE "$DRUSE_ABSENT" "$DRUSE_P3" ||
    fail "the freeze document no longer records '$DRUSE_ABSENT' among what Phase 3 did not do. The feature is still absent, so the document must keep saying so; dropping the row turns an absent feature into an implied one."
done
# Read FLATTENED. These are prose assertions, and prose wraps: the sentence this
# looks for spans two lines in the document, and a line-based grep would have
# reported it missing while it was sitting right there.
DRUSE_P3_FLAT="$(tr '\n' ' ' <"$DRUSE_P3" | tr -s ' ')"
grep -qiE 'no document claims druse has configurable timeouts' <<<"$DRUSE_P3_FLAT" ||
  fail "the freeze document does not forbid the timeout claim it exists to prevent"
echo "phase-3 freeze: the deliberate absences are recorded, timeouts among them"

# ---------------------------------------------------------------------------
# 7b. NO LEDGER MAY DEFER TO A PHASE THAT HAS ALREADY FROZEN.
#
# The defect this catches, found by reading the shipped freeze rather than by a
# gate: the capacity ledger carried "read/write timeouts — not configurable
# until Phase 3". That sentence was true when written and became a LIE the day
# Phase 3 froze without them, because it now reads as a promise that was kept.
# Nothing failed: the row was accurate prose about the past, and no check looks
# at tense.
#
# A deferral is a debt with a due date. When the date passes, the row must say
# what actually happened — shipped, or not shipped and why — never leave the
# reader to infer the happier one.
# ---------------------------------------------------------------------------
# Only LEDGER ROWS are scanned — lines beginning with a table pipe. Prose may
# legitimately QUOTE a retired deferral in order to say it was retired, and an
# amendment that could not name the sentence it replaced would be a worse
# document. The row is the promise; the paragraph about the row is not.
DRUSE_STALE_DEFERRALS="$(grep -nE '^\|.*(until Phase [123]\b|in Phase [123]\b.*(will|becomes))' "$DRUSE_P2" \
  "$DRUSE_ROOT/planning/phase-1-freeze.md" "$DRUSE_P3" 2>/dev/null || true)"
if test -n "$DRUSE_STALE_DEFERRALS"; then
  echo "$DRUSE_STALE_DEFERRALS" >&2
  fail "a frozen ledger still defers to a phase that has already frozen. When the due date passes the row must state the OUTCOME — shipped, or not shipped and why — because a deferral left standing reads as a promise that was kept."
fi
echo "phase-3 freeze: no ledger defers to a phase that has already frozen"

# ---------------------------------------------------------------------------
# 8. Unfinished work has no place in a frozen contract.
# ---------------------------------------------------------------------------
if grep -nE '\b(TODO|FIXME|XXX|TBD)\b' "$DRUSE_P3"; then
  fail "planning/phase-3-freeze.md contains an unfinished-work marker. A frozen contract cannot have open work in it."
fi

echo "PASS: Phase 3 freeze gate (ledgers amended, suites re-run, costs measured or honestly not)"
