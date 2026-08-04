#!/usr/bin/env bash
# R2-WP05 experiment 1 — is the RECONNECTION BURST the variable, or the rate?
#
#   usage: burst-sweep.sh BASE ARM LANES BURST_PERIOD_S DURATION_S
#     ARM             a label recorded in the artefact (A, B, C, D)
#     BURST_PERIOD_S  0 = one continuous generator run (a single connect event);
#                     N = restart every generator every N seconds
#
# WHY THIS EXISTS. R2-WP04 stopped because load refusals did not reach zero at
# any tested rate, and it recorded a hypothesis it could not test: the driver is
# the ~624-connection burst at each cycle edge, not the offered request rate.
# `run-soak.sh` cannot separate those two — it restarts every generator every
# cycle, always — and it is pinned by sha256 in §2.1 of the soak
# pre-registration, so changing it would create a new candidate under G1 and
# discard the five ladder steps already run.
#
# So this is a SEPARATE harness that reuses the same server, the same generator
# and the same out-of-band snapshot channel, and makes the restart period a
# PARAMETER. The pre-registration is
# planning/readiness/R2-WP05-burst-preregistration.md; the criteria there are
# frozen and this script does not grade — it measures and records.
#
# WHAT IT DELIBERATELY DOES NOT DO. No fault injection. Every refusal this
# harness observes is therefore attributable to offered load BY CONSTRUCTION,
# and it writes an empty `injected.txt` so the artefact proves that rather than
# asserting it (criterion W5).
set -euo pipefail

BASE="${1:?usage: burst-sweep.sh BASE ARM LANES BURST_PERIOD_S DURATION_S}"
ARM="${2:?arm label}"
LANES="${3:?lanes}"
BURST_PERIOD="${4:?burst period seconds, 0 = continuous}"
DURATION="${5:?duration seconds}"

REPO="$BASE/repo"
OUT="$BASE/wp05/$ARM"
PORT="${DRUSE_WP05_PORT:-8080}"
ODIN_BIN="${DRUSE_ODIN_BIN:-$HOME/odin-pinned/odin}"
SERVER_CPUS="${DRUSE_SOAK_SERVER_CPUS:-0,1,4,5}"
GENERATOR_CPUS="${DRUSE_SOAK_GENERATOR_CPUS:-2,3,6,7}"

# The §4.7 rates. Kept identical across arms — the whole design rests on rate
# being held constant while the burst structure moves.
HEALTH_RATE=20 TINY_RATE=600 JSON_ENCODE_RATE=90
JSON_DECODE_RATE=240 BYTES_64K_RATE=9 WAIT_40MS_RATE=1

rm -rf "$OUT"
mkdir -p "$OUT"/{bin,control,raw}
SERVER="$OUT/bin/server"
OPENLOAD="$OUT/bin/openload"
SNAPSHOT="$OUT/control/snapshot.txt"

# W5's proof: an empty injected.txt, written unconditionally. An absent file
# would be indistinguishable from a harness that forgot to declare injections.
: >"$OUT/control/injected.txt"

echo "building" >&2
"$ODIN_BIN" build "$REPO/ops/soak/soak-server" \
  -collection:druse="$REPO" -o:speed -out:"$SERVER"
(cd "$REPO/ops/soak/openload" && go build -buildvcs=false -trimpath -o "$OPENLOAD" main.go)

taskset -c "$SERVER_CPUS" "$SERVER" "$LANES" "$PORT" "$SNAPSHOT" \
  >"$OUT/server.log" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" >"$OUT/control/server.pid"

# THE NEGATIVE CONTROL IS STRUCTURAL, not a separate case: if the server never
# becomes ready the harness EXITS NON-ZERO instead of recording zero refusals.
# INS-013 in this repository — one absent measurement rendered as a clean result
# produced a green twelve-hour artefact with no telemetry in it.
ready=no
for _ in $(seq 1 200); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    ready=yes; break
  fi
  sleep 0.1
done
if [[ "$ready" != yes ]]; then
  echo "FATAL: server never became ready; refusing to report a measurement" >&2
  kill "$SERVER_PID" 2>/dev/null || true
  exit 3
fi

# The ADR-050 snapshot, not an HTTP scrape on the lanes under test. Guarded on
# the file EXISTING because the first edition was not: `awk` on a missing file
# exits 2, `pipefail` propagated it and `set -e` killed the harness before it
# measured anything. Eight arms died in eleven seconds each.
#
# The guard returns empty, never zero. Zero is a measurement; empty is the
# absence of one, and the callers below treat them differently.
read_refusals() {
  [[ -f "$SNAPSHOT" ]] || return 0
  awk '/^saturation_refusals /{print $2}' "$SNAPSHOT" 2>/dev/null | tail -1
}

# THE SNAPSHOT IS A PRECONDITION, NOT A CONVENIENCE. `/health` answers before
# the exporter thread has written its first file, so waiting only on readiness
# reads an absent channel as a working one. The soak analyser refuses a run whose
# snapshot is missing or stale; this harness refuses to START one.
snapshot_ready=no
for _ in $(seq 1 100); do
  if [[ -n "$(read_refusals)" ]]; then snapshot_ready=yes; break; fi
  sleep 0.2
done
if [[ "$snapshot_ready" != yes ]]; then
  echo "FATAL: the ADR-050 snapshot never appeared at $SNAPSHOT; the metric channel this run depends on is not working, and a run without it is not a measurement" >&2
  kill "$SERVER_PID" 2>/dev/null || true
  exit 5
fi

REFUSALS_BEFORE="$(read_refusals)"

# One "burst" = every generator being (re)started at the same instant. That is
# what run-soak.sh does at each cycle edge, and what this script makes optional.
launch_generators() {  # $1 = seconds this wave should run for
  local secs="$1" cpus="$GENERATOR_CPUS"
  taskset -c "$cpus" "$OPENLOAD" -url "http://127.0.0.1:$PORT/health" \
    -rate "$HEALTH_RATE" -duration "${secs}s" -connections 16 >/dev/null 2>&1 &
  taskset -c "$cpus" "$OPENLOAD" -url "http://127.0.0.1:$PORT/tiny" \
    -rate "$TINY_RATE" -duration "${secs}s" -connections 128 >/dev/null 2>&1 &
  taskset -c "$cpus" "$OPENLOAD" -url "http://127.0.0.1:$PORT/json/medium" \
    -rate "$JSON_ENCODE_RATE" -duration "${secs}s" -connections 128 >/dev/null 2>&1 &
  taskset -c "$cpus" "$OPENLOAD" -url "http://127.0.0.1:$PORT/json/medium/decode" \
    -method POST -payload medium-json \
    -rate "$JSON_DECODE_RATE" -duration "${secs}s" -connections 256 >/dev/null 2>&1 &
  taskset -c "$cpus" "$OPENLOAD" -url "http://127.0.0.1:$PORT/bytes/64k" \
    -rate "$BYTES_64K_RATE" -duration "${secs}s" -connections 64 >/dev/null 2>&1 &
  taskset -c "$cpus" "$OPENLOAD" -url "http://127.0.0.1:$PORT/wait/40ms" \
    -rate "$WAIT_40MS_RATE" -duration "${secs}s" -connections 32 >/dev/null 2>&1 &
}

STARTED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BURSTS=0
if [[ "$BURST_PERIOD" == 0 ]]; then
  # Arm A: a single connect event for the whole window.
  launch_generators "$DURATION"
  BURSTS=1
  wait $(jobs -p | grep -v "$SERVER_PID" || true) 2>/dev/null || true
  sleep 2
else
  remaining="$DURATION"
  while (( remaining > 0 )); do
    wave=$(( remaining < BURST_PERIOD ? remaining : BURST_PERIOD ))
    launch_generators "$wave"
    BURSTS=$(( BURSTS + 1 ))
    sleep $(( wave + 1 ))
    remaining=$(( remaining - wave ))
  done
  sleep 2
fi
ENDED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

REFUSALS_AFTER="$(read_refusals)"
: "${REFUSALS_AFTER:=}"
cp "$SNAPSHOT" "$OUT/raw/snapshot-final.txt" 2>/dev/null || true

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

# A snapshot that could not be read is a FAILED run, never a clean one (W4).
if [[ -z "$REFUSALS_AFTER" ]]; then
  echo "FATAL: the final snapshot carried no saturation_refusals; this run is invalid" >&2
  exit 4
fi

{
  echo "schema=wp05-burst/1"
  echo "arm=$ARM"
  echo "lanes=$LANES"
  echo "burst_period_s=$BURST_PERIOD"
  echo "bursts=$BURSTS"
  echo "duration_s=$DURATION"
  echo "started_utc=$STARTED_UTC"
  echo "ended_utc=$ENDED_UTC"
  echo "server_cpus=$SERVER_CPUS"
  echo "generator_cpus=$GENERATOR_CPUS"
  echo "health_rate=$HEALTH_RATE"
  echo "tiny_rate=$TINY_RATE"
  echo "json_encode_rate=$JSON_ENCODE_RATE"
  echo "json_decode_rate=$JSON_DECODE_RATE"
  echo "bytes_64k_rate=$BYTES_64K_RATE"
  echo "wait_40ms_rate=$WAIT_40MS_RATE"
  echo "aggregate_rate=$(( HEALTH_RATE + TINY_RATE + JSON_ENCODE_RATE + JSON_DECODE_RATE + BYTES_64K_RATE + WAIT_40MS_RATE ))"
  echo "commit=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "server_sha256=$(sha256sum "$SERVER" | awk '{print $1}')"
  echo "openload_sha256=$(sha256sum "$OPENLOAD" | awk '{print $1}')"
  echo "saturation_refusals_before=$REFUSALS_BEFORE"
  echo "saturation_refusals_after=$REFUSALS_AFTER"
  echo "saturation_refusals=$(( REFUSALS_AFTER - REFUSALS_BEFORE ))"
  echo "injections_declared=0"
} >"$OUT/manifest.txt"

cat "$OUT/manifest.txt"
