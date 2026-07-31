#!/usr/bin/env bash
# Campaign B2 — the shutdown use-after-destroy race. ASan is the oracle.
#
#   run-campaign-b2.sh control   revert the fix, expect an ASan report
#   run-campaign-b2.sh verify    restore the fix, 50k iterations clean
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_odin

MODE="${1:-}"
case "$MODE" in control|verify) ;; *) echo "usage: $0 control|verify" >&2; exit 1 ;; esac

# Without this, ASan + io_uring reproduces F-C03-2 (a startup assert) instead of
# the bug under test — which looks like a finding and is not one.
if test "$(ulimit -l)" != "unlimited"; then
  echo "REFUSING: ulimit -l is $(ulimit -l), not unlimited." >&2
  echo "Run ops/campaign/prepare-host.sh first, in this shell's session." >&2
  exit 2
fi

STAMP="$(stamp)"
LOG="$URUQUIM_ARTIFACTS/b2-$MODE-$STAMP.log"

export URUQUIM_RACE_LANES="${URUQUIM_RACE_LANES:-2}"
export URUQUIM_RACE_SWEEP_NS="${URUQUIM_RACE_SWEEP_NS:-400000}"
export URUQUIM_RACE_SWEEP_STEP_NS="${URUQUIM_RACE_SWEEP_STEP_NS:-971}"
if test "$MODE" = control; then
  export URUQUIM_RACE_ITERATIONS="${URUQUIM_RACE_ITERATIONS:-20000}"
  revert_b2_fix
else
  export URUQUIM_RACE_ITERATIONS="${URUQUIM_RACE_ITERATIONS:-50000}"
fi

"$URUQUIM_ODIN" build "$URUQUIM_ROOT/experiments/24-shutdown-race" \
  -collection:uruquim="$URUQUIM_ROOT" -sanitize:address -out:"$URUQUIM_BIN/b2-$MODE"

{
  echo "=== campaign B2 ($MODE) $STAMP ==="
  echo "commit=$(git -C "$URUQUIM_ROOT" rev-parse HEAD)"
  echo "build=-sanitize:address"
  env | grep '^URUQUIM_RACE_' | sort
  echo
} | tee "$LOG"

set +e
ASAN_OPTIONS="detect_leaks=0:abort_on_error=0:halt_on_error=1" \
  "$URUQUIM_BIN/b2-$MODE" 2>&1 | tee -a "$LOG"
RC="${PIPESTATUS[0]}"
set -e

echo | tee -a "$LOG"
if grep -qE "ERROR: AddressSanitizer|SUMMARY: AddressSanitizer" "$LOG"; then
  if test "$MODE" = control; then
    echo "CONTROL REPORTED — the harness measures what it claims. Now: $0 verify" | tee -a "$LOG"
  else
    echo "VERIFY REPORTED AN ASan ERROR. That is a live defect with the fix in place. STOP." | tee -a "$LOG"
  fi
else
  if test "$MODE" = control; then
    echo "CONTROL DID NOT REPORT. Say so in these words: 'the race was not" | tee -a "$LOG"
    echo "reproduced on this hardware; the fix stands on the code argument alone.'" | tee -a "$LOG"
  else
    echo "VERIFY CLEAN (meaningful only if the control above reported)" | tee -a "$LOG"
  fi
fi
echo "exit=$RC log: $LOG"
