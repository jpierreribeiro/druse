#!/usr/bin/env bash
# Campaign D — the long soak. Run on the SERVER box, after A and B are green.
# Drive load from the second instance with ops/campaign/soak-load.sh.
#
# State the acceptable RSS band BEFORE starting. A band chosen after seeing the
# result is not an acceptance criterion.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need_odin

HOURS="${URUQUIM_SOAK_HOURS:-12}"
PORT="${URUQUIM_SOAK_PORT:-8080}"
LANES="${URUQUIM_SOAK_LANES:-4}"
STAMP="$(stamp)"
CSV="$URUQUIM_ARTIFACTS/soak-$STAMP.csv"
LOG="$URUQUIM_ARTIFACTS/soak-$STAMP.log"

test -n "${URUQUIM_SOAK_RSS_BAND_MB:-}" || {
  cat >&2 <<'MSG'
REFUSING: set URUQUIM_SOAK_RSS_BAND_MB to the RSS band you will accept, in MB,
BEFORE the run. Example: URUQUIM_SOAK_RSS_BAND_MB=250

This is not bureaucracy. Per-connection buffers retain roughly the largest
response that connection ever served, and max_idle_time defaults to 0 (idle
connections are never reaped), so RSS is expected to ratchet toward a plateau.
A band decided after seeing the curve cannot distinguish "plateau" from
"whatever it happened to reach".
MSG
  exit 2
}

"$URUQUIM_ODIN" build "$URUQUIM_ROOT/bench/application_matrix/uruquim" \
  -collection:uruquim="$URUQUIM_ROOT" -o:speed -out:"$URUQUIM_BIN/soak-server"

{
  echo "=== campaign D $STAMP ==="
  echo "commit=$(git -C "$URUQUIM_ROOT" rev-parse HEAD)"
  echo "hours=$HOURS port=$PORT lanes=$LANES rss_band_mb=$URUQUIM_SOAK_RSS_BAND_MB"
} | tee "$LOG"

taskset -c "${URUQUIM_SOAK_SERVER_CPUS:-0-7}" "$URUQUIM_BIN/soak-server" "$PORT" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true; restore_fix' EXIT INT TERM
sleep 2

echo "ts,rss_kb,fds,threads" > "$CSV"
END=$(( $(date +%s) + HOURS * 3600 ))
while test "$(date +%s)" -lt "$END"; do
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "SERVER DIED — that is the finding" | tee -a "$LOG"; exit 1; }
  RSS="$(awk '/VmRSS/{print $2}' "/proc/$SERVER_PID/status" 2>/dev/null || echo 0)"
  FDS="$(ls "/proc/$SERVER_PID/fd" 2>/dev/null | wc -l)"
  THR="$(awk '/Threads/{print $2}' "/proc/$SERVER_PID/status" 2>/dev/null || echo 0)"
  echo "$(date -u +%s),$RSS,$FDS,$THR" >> "$CSV"
  sleep 30
done

echo "soak complete. csv=$CSV" | tee -a "$LOG"
cat >> "$LOG" <<MSG

ACCEPTANCE, checked against the band declared before the run
($URUQUIM_SOAK_RSS_BAND_MB MB):
  - RSS reaches a plateau and stays inside the band after hour 2;
  - fd count returns to baseline after each churn phase — a monotonic climb is
    a descriptor leak and is a finding, not noise;
  - zero crashes;
  - 503 rate below the stated threshold (from the load side's output).
MSG
