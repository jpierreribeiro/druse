#!/usr/bin/env bash
# C-07 — the Closure record and verdict, under control.
#
# A verdict is worth exactly as much as the evidence still standing behind it.
# Four executable claims:
#
#   1. EVERY INSTRUMENT THE VERDICT CITES STILL EXISTS and is still gated. A
#      verdict that outlives its evidence is a claim, not a record;
#   2. THE EXIT CONDITION IS QUOTED VERBATIM, so the phase cannot be judged
#      against a softened version of its own bar;
#   3. THE RESIDUAL IS STILL NAMED. F-C03-2 is an OPEN defect; a record that
#      quietly drops it turns a qualified verdict into a false one;
#   4. THE DEFERRALS STILL CARRY TRIGGERS. Deferred work here means a
#      specification handed forward, not an open question.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_DOC="$DRUSE_ROOT/planning/closure-record-and-verdict.md"

fail() {
  echo "C07-CONTROL-FAIL: $*" >&2
  exit 1
}

test -f "$DRUSE_DOC" || fail "planning/closure-record-and-verdict.md is missing; the Closure has no verdict"
# Blockquote markers are stripped BEFORE flattening: the exit condition is
# quoted as a `>` block, so a naive flatten leaves "> " inside the sentence and
# the verbatim check fails against a document that is perfectly correct.
DRUSE_FLAT="$(sed 's/^> \?//' "$DRUSE_DOC" | tr '\n' ' ' | tr -s ' ')"

# --- 1. Every instrument the verdict cites still exists and is gated ----------
while read -r DRUSE_ARTIFACT DRUSE_GATE; do
  test -f "$DRUSE_ROOT/$DRUSE_ARTIFACT" ||
    fail "the verdict cites $DRUSE_ARTIFACT, which no longer exists"
  test -f "$DRUSE_ROOT/build/$DRUSE_GATE" ||
    fail "the verdict rests on $DRUSE_ARTIFACT being gated by build/$DRUSE_GATE, which no longer exists"
  grep -qF "$DRUSE_ARTIFACT" "$DRUSE_DOC" ||
    fail "the verdict no longer cites $DRUSE_ARTIFACT"
  grep -qF "$DRUSE_GATE" "$DRUSE_ROOT/build/check.sh" ||
    fail "build/$DRUSE_GATE is no longer wired into the full gate; the verdict's evidence would stop being re-derived"
done <<'ARTIFACTS'
planning/closure-async-op-inventory.md check_c01_controls.sh
planning/closure-readiness-matrix.md check_readiness_matrix.sh
planning/closure-fault-campaign.md check_c03_controls.sh
planning/closure-response-size-and-memory.md check_c04_controls.sh
planning/closure-saturation-and-write-observability.md check_c05_controls.sh
planning/closure-proxy-contract.md check_c06_controls.sh
planning/closure-httprouter-study.md check_c08_controls.sh
ARTIFACTS

# --- 2. The exit condition, quoted rather than paraphrased --------------------
grep -qi 'No framework-owned operation exists without an explicitly declared owner, capacity, deadline, or cancellation' <<<"$DRUSE_FLAT" ||
  fail "the verdict no longer quotes the exit condition verbatim. A phase judged against a paraphrase of its own bar is a phase that can pass by rewording."
grep -qi 'named, mandatory, documented and tested' <<<"$DRUSE_FLAT" ||
  fail "the exit condition's second half — that an unbounded or external thing must have a topology that is named, mandatory, documented AND TESTED — is gone"

# --- 3. F-C03-2 is still named, and its RESOLUTION is recorded ----------------
# It began as the one open defect; Hardening H-2 (patches 29+30) diagnosed and
# fixed it. The verdict must keep naming it AND record how it was closed — a
# resolved defect quietly dropped is as misleading as an open one hidden.
grep -q 'F-C03-2' "$DRUSE_DOC" ||
  fail "F-C03-2 is no longer named in the verdict. It was the one open defect and is now resolved by H-2 (patches 29+30); a record that drops it — open or closed — turns a verdict into a claim."
grep -qi 'patch 30' <<<"$DRUSE_FLAT" ||
  fail "the verdict no longer records that F-C03-2 was FIXED by patch 30 (the graceful serve-failure unwind). Its diagnosis-and-fix is the phase's headline; dropping it loses the resolution."
grep -qi 'graceful' <<<"$DRUSE_FLAT" ||
  fail "the verdict no longer describes the graceful unwind that closed F-C03-2"

# --- 4. Every deferral carries a trigger -------------------------------------
for DRUSE_DEFERRAL in max_response_bytes Server_Stats 'real-proxy' 'hours-long' radix_compact; do
  grep -qi "$DRUSE_DEFERRAL" <<<"$DRUSE_FLAT" ||
    fail "the deferral '$DRUSE_DEFERRAL' is no longer recorded. Deferred work in this phase means a SPECIFICATION HANDED FORWARD; an unrecorded deferral is the exact failure — a pendency that stops being trackable — that called this phase into being."
done
grep -qi 'Trigger' <<<"$DRUSE_FLAT" ||
  fail "the deferral table lost its trigger column; a deferral without a trigger is a wish"

# --- 5. The rule the phase leaves behind -------------------------------------
grep -qi 'rests on reasoning rather than on a test is not answered' <<<"$DRUSE_FLAT" ||
  fail "the phase's own methodological rule is gone — it was earned by C-01 getting a cell wrong and C-05's measurement catching it, and it is the most transferable thing here"

echo "c07: all 7 Closure artifacts exist, are cited, and are wired into the full gate"
echo "c07: the exit condition is quoted verbatim and judged"
echo "c07: F-C03-2 is named and recorded RESOLVED (patches 29+30); every deferral still carries a trigger"
echo "PASS: C-07 Closure record and verdict controls"
