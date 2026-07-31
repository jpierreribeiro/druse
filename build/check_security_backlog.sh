#!/usr/bin/env bash
# H-1 — the security-backlog reconciliation, under control.
#
# Every one of the 14 findings is fixed; the risk is a fix REGRESSING without
# anyone noticing. So this gate asserts the correspondence: each finding names a
# pinning test, and each named test still exists in the tree. Two findings (F8,
# F12) are pinned indirectly with a stated reason; the gate requires the reason
# to survive, not a test that cannot honestly exist.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_DOC="$DRUSE_ROOT/planning/security-backlog-reconciliation.md"

fail() {
  echo "H1-SECURITY-FAIL: $*" >&2
  exit 1
}

test -f "$DRUSE_DOC" || fail "planning/security-backlog-reconciliation.md is missing; the 14 findings have no reconciled record"

# --- The count is declared and matches the numbered rows ----------------------
DRUSE_DECLARED="$(sed -n 's/^<!-- h1-findings: \([0-9]\+\) -->$/\1/p' "$DRUSE_DOC")"
test -n "$DRUSE_DECLARED" || fail "the 'h1-findings' marker is gone"
DRUSE_ROWS="$(grep -cE '^\| \*\*F[0-9]+\*\* \|' "$DRUSE_DOC" || true)"
test "$DRUSE_ROWS" -eq "$DRUSE_DECLARED" ||
  fail "the doc has $DRUSE_ROWS finding rows but declares $DRUSE_DECLARED"
test "$DRUSE_DECLARED" -eq 14 ||
  fail "the scan produced 14 findings; the reconciliation carries $DRUSE_DECLARED"

# --- Every finding F1..F14 has a row ------------------------------------------
for DRUSE_N in $(seq 1 14); do
  grep -qE "^\| \*\*F$DRUSE_N\*\* \|" "$DRUSE_DOC" ||
    fail "finding F$DRUSE_N has no row in the reconciliation"
done

# --- The attack-lab series (F-001..F-007) is reconciled too --------------------
#
# A second series, from the 2026-07-23 and 2026-07-28 raw-socket sessions. It
# had no ledger until 2026-07-30: the fixes were real and their protection was a
# report, which is the exact failure mode 0 of the doc names. These assertions
# keep the rows from quietly disappearing again.
DRUSE_AL_DECLARED="$(sed -n 's/^<!-- attacklab-findings: \([0-9]\+\) -->$/\1/p' "$DRUSE_DOC")"
test -n "$DRUSE_AL_DECLARED" || fail "the 'attacklab-findings' marker is gone; the F-001..F-007 series has no reconciled record"
DRUSE_AL_ROWS="$(grep -cE '^\| \*\*F-[0-9]{3}\*\* \|' "$DRUSE_DOC" || true)"
test "$DRUSE_AL_ROWS" -eq "$DRUSE_AL_DECLARED" ||
  fail "the attack-lab section has $DRUSE_AL_ROWS rows but declares $DRUSE_AL_DECLARED"
test "$DRUSE_AL_DECLARED" -eq 7 ||
  fail "the attack lab produced 7 findings; the reconciliation carries $DRUSE_AL_DECLARED"
for DRUSE_N in 001 002 003 004 005 006 007; do
  grep -qE "^\| \*\*F-$DRUSE_N\*\* \|" "$DRUSE_DOC" ||
    fail "finding F-$DRUSE_N has no row in the attack-lab reconciliation"
done

# F-002 is the one whose fix had no test for a week. Its control must exist and
# must still be wired into the gate; a row that names a control the gate does
# not run is a row that reassures without protecting.
grep -q 'DRUSE FIX (F-002)' "$DRUSE_ROOT/build/check_c05_controls.sh" ||
  fail "check_c05_controls.sh no longer pins F-002; the use-after-free fix is back to having no named test"
grep -q 'check_c05_controls.sh' "$DRUSE_ROOT/build/check.sh" ||
  fail "the C-05 controls are no longer run by the gate, so the F-002 pin does not execute"

# --- The pinning tests named in the doc exist in the tree ---------------------
# The 12 directly-pinned findings each name a test function; that function must
# exist. A dropped test is a fix that can regress in silence.
for DRUSE_TEST in \
  wp68_over_deep_nesting_is_refused_before_parsing \
  wp9_raw_wire_corpus \
  wp48i_a_spoofed_leftmost_is_ignored_behind_a_trusted_proxy \
  wp91_secure_headers_cover_a_static_response \
  wp91_global_middleware_runs_for_a_static_file \
  wp91_an_auth_refusal_blocks_a_static_file \
  wp61_a_symlink_in_an_intermediate_segment_is_refused \
  c03_a_healthy_client_survives_an_rst_flood \
  wp68_out_of_range_integer_is_an_invalid_field \
  wp63_a_decoy_boundary_in_a_quoted_parameter_is_not_used; do
  grep -q "$DRUSE_TEST" "$DRUSE_DOC" ||
    fail "the reconciliation no longer names the pinning test $DRUSE_TEST"
  grep -rq "^$DRUSE_TEST ::" "$DRUSE_ROOT/tests" ||
    fail "the pinning test $DRUSE_TEST is named in the doc but does not exist in tests/ — a fix has lost its guard"
done

# --- The two NEW tests, specifically (H-1's own deliverable) ------------------
grep -rq '^wp61_a_symlink_in_an_intermediate_segment_is_refused ::' \
  "$DRUSE_ROOT/tests/wp61-public-surface" ||
  fail "the F7 intermediate-symlink test (H-1's deliverable) is gone from tests/wp61-public-surface"
grep -rq '^wp63_a_decoy_boundary_in_a_quoted_parameter_is_not_used ::' \
  "$DRUSE_ROOT/tests/wp63-public-surface" ||
  fail "the F13 decoy-boundary test (H-1's deliverable) is gone from tests/wp63-public-surface"

# --- The two indirect findings keep their stated reason -----------------------
DRUSE_FLAT="$(tr '\n' ' ' <"$DRUSE_DOC" | tr -s ' ')"
grep -qi 'no dedicated leak test' <<<"$DRUSE_FLAT" ||
  fail "F8's honest 'no dedicated leak test, and here is why' record is gone — a gap silently reclassified as pinned is exactly what this reconciliation exists to prevent"
grep -qi 'no public injection path' <<<"$DRUSE_FLAT" ||
  fail "F12's 'no public injection path' reason is gone; without it a reader cannot tell a real gap from a forgotten one"

echo "h1: all 14 findings reconciled; 12 pinned by an existing named test, 2 (F8, F12) indirect with a stated reason"
echo "h1: the F7 intermediate-symlink and F13 decoy-boundary tests exist"
echo "h1: the attack-lab series F-001..F-007 is reconciled; F-002 is pinned by check_c05_controls.sh and that control is wired into the gate"
echo "PASS: H-1 security-backlog reconciliation"
