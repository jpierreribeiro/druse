#!/usr/bin/env bash
# Campaign B1 — the accept stall. See ops/campaign/README.md.
#
#   run-campaign-b1.sh control   revert the fix and try to REPRODUCE the stall
#   run-campaign-b1.sh verify    restore the fix and run long and clean
#
# Run `control` FIRST. Until it has failed, `verify` is not evidence.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_odin

MODE="${1:-}"
case "$MODE" in control|verify) ;; *) echo "usage: $0 control|verify" >&2; exit 1 ;; esac

STAMP="$(stamp)"
LOG="$URUQUIM_ARTIFACTS/b1-$MODE-$STAMP.log"

# Aggressive by default: the window is nanoseconds wide, so cycles-per-second is
# the only lever that matters. A 4-core container reached ~17 cycles/s at these
# values and did NOT reproduce in 3,135 cycles — budget hours, not minutes.
export URUQUIM_STALL_LANES="${URUQUIM_STALL_LANES:-2}"
export URUQUIM_STALL_DWELL_MS="${URUQUIM_STALL_DWELL_MS:-3}"
export URUQUIM_STALL_QUIET_MS="${URUQUIM_STALL_QUIET_MS:-30}"
export URUQUIM_STALL_WAVE="${URUQUIM_STALL_WAVE:-16}"
export URUQUIM_STALL_CANARY_MS="${URUQUIM_STALL_CANARY_MS:-2000}"
if test "$MODE" = control; then
  export URUQUIM_STALL_MINUTES="${URUQUIM_STALL_MINUTES:-240}"   # 4 h of attempts
  revert_b1_fix
else
  export URUQUIM_STALL_MINUTES="${URUQUIM_STALL_MINUTES:-360}"   # 6 h clean
fi

"$URUQUIM_ODIN" build "$URUQUIM_ROOT/experiments/23-accept-stall" \
  -collection:uruquim="$URUQUIM_ROOT" -o:speed -out:"$URUQUIM_BIN/b1-$MODE"

{
  echo "=== campaign B1 ($MODE) $STAMP ==="
  echo "commit=$(git -C "$URUQUIM_ROOT" rev-parse HEAD)"
  env | grep '^URUQUIM_STALL_' | sort
  echo
} | tee "$LOG"

set +e
taskset -c "${URUQUIM_CAMPAIGN_CPUS:-0-7}" "$URUQUIM_BIN/b1-$MODE" 2>&1 | tee -a "$LOG"
RC="${PIPESTATUS[0]}"
set -e

echo | tee -a "$LOG"
if test "$MODE" = control; then
  if test "$RC" -eq 1; then
    echo "CONTROL REPRODUCED THE STALL — the harness measures what it claims." | tee -a "$LOG"
    echo "Record the cycle count above, then run: $0 verify" | tee -a "$LOG"
  else
    echo "CONTROL DID NOT REPRODUCE. Report this in these words:" | tee -a "$LOG"
    echo "  'the harness ran N cycles without reproducing the defect on reverted" | tee -a "$LOG"
    echo "   code, so it bounds nothing; the fix stands on the memory-model" | tee -a "$LOG"
    echo "   argument alone.'" | tee -a "$LOG"
    echo "Do NOT present a clean verify run as proof on its own." | tee -a "$LOG"
  fi
else
  test "$RC" -eq 0 \
    && echo "VERIFY CLEAN (meaningful only if the control above reproduced)" | tee -a "$LOG" \
    || echo "VERIFY FAILED — a stall with the fix in place is a live defect. STOP." | tee -a "$LOG"
fi
echo "log: $LOG"
