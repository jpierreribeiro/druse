#!/usr/bin/env bash
# Campaign A — make c03-fault-campaign complete, then re-establish its verdict.
#
# The suite did not finish in 25 min on the audit container, on the patched tree
# OR on pristine 61bec774 — a direct comparison confirmed it is environmental.
# So the first question is why it does not finish, not whether it passes.
#
#   run-campaign-a.sh                    three runs, expecting completion
#   URUQUIM_C03_CONTROL=1 run-campaign-a.sh   handoff limit 8, expecting failure
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_odin

STAMP="$(stamp)"
CONTROL="${URUQUIM_C03_CONTROL:-0}"
LOG="$URUQUIM_ARTIFACTS/c03-$([ "$CONTROL" = 1 ] && echo control || echo verify)-$STAMP.log"
RUNS="${URUQUIM_C03_RUNS:-3}"
TIMEOUT="${URUQUIM_C03_TIMEOUT:-1800}"

if test "$CONTROL" = 1; then
  cp "$URUQUIM_ROOT/vendor/odin-http/server.odin" "$FIX_BACKUP"
  sed -i 's/URUQUIM_ACCEPT_HANDOFF_LIMIT :: 2/URUQUIM_ACCEPT_HANDOFF_LIMIT :: 8/' \
    "$URUQUIM_ROOT/vendor/odin-http/server.odin"
  echo "control: handoff limit set to 8" >&2
  RUNS=1
fi

{
  echo "=== campaign A $STAMP (control=$CONTROL) ==="
  echo "commit=$(git -C "$URUQUIM_ROOT" rev-parse HEAD)"
  echo "runs=$RUNS timeout=${TIMEOUT}s"
  grep -n 'URUQUIM_ACCEPT_HANDOFF_LIMIT ::' "$URUQUIM_ROOT/vendor/odin-http/server.odin"
  echo
} | tee "$LOG"

for i in $(seq 1 "$RUNS"); do
  echo "--- run $i/$RUNS ---" | tee -a "$LOG"
  START="$(date +%s)"
  set +e
  timeout "$TIMEOUT" "$URUQUIM_ODIN" test "$URUQUIM_ROOT/tests/c03-fault-campaign" \
    -collection:uruquim="$URUQUIM_ROOT" -out:"$URUQUIM_BIN/c03" 2>&1 | tee -a "$LOG"
  RC="${PIPESTATUS[0]}"
  set -e
  echo "run=$i rc=$RC wall=$(( $(date +%s) - START ))s" | tee -a "$LOG"

  if test "$RC" -eq 124; then
    cat <<'MSG' | tee -a "$LOG"

DID NOT COMPLETE. Before anything else, find out WHERE. While a run is live:
  pgrep -f c03-fault-campaign
  gdb -p <pid> -batch -ex "thread apply all bt"
  ss -s ; dmesg | tail -50 ; strace -c -f -p <pid>
Report which of three it is:
  (a) resource exhaustion — name the limit that bound;
  (b) a genuine hang in the framework — STOP, that outranks everything else here;
  (c) slow but progressing — record the wall time.
MSG
    break
  fi
done

echo | tee -a "$LOG"
echo "REMINDER: the committed bar is 'at least half the healthy probes served" | tee -a "$LOG"
echo "during the flood, plus full recovery after'. Report the observed numbers" | tee -a "$LOG"
echo "AND that threshold — 58/58 is an observation, not the gate." | tee -a "$LOG"
echo "log: $LOG"
