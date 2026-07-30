#!/usr/bin/env bash
# Where does the time go inside one endpoint?
#
#   usage: profile-endpoint.sh OUT_DIR ENDPOINT_PATH RATE [SECONDS] [LANES]
#
# PROFILE BELOW THE KNEE. A profile taken while the server is shedding load
# measures the queue, not the work. The 2026-07-30 sweep put Druse's knee for
# nested JSON between 20,000 and 25,000 requests per second on four lanes, so a
# profile of that endpoint belongs at 10,000 or 15,000 — where every request is
# served and the samples are the cost of serving it. This is the same mistake
# the withdrawn latency row made, one layer down, and it is worth stating in the
# script rather than in a comment nobody reads.
#
# Run it once per endpoint and diff the symbol tables. Profiling
# /json/medium against /json/medium/int is what isolates float rendering: the
# two documents are identical except for the type of one field.
#
# The encode path had never been profiled before this script existed. The
# 2026-07-25 study's profile is a decode profile taken under a POST workload,
# and no marshal symbol appears in it.
#
# REQUIRES: perf, passwordless sudo, a dedicated idle host.
set -euo pipefail

OUT="${1:?usage: profile-endpoint.sh OUT_DIR ENDPOINT_PATH RATE [SECONDS] [LANES]}"
ENDPOINT="${2:?an endpoint path}"
RATE="${3:?an offered rate, below the knee}"
DURATION="${4:-30}"
LANES="${5:-4}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MATRIX="$ROOT/bench/application_matrix"
ODIN_BIN="${DRUSE_ODIN_BIN:-odin}"
SERVER_CPUS="${DRUSE_BENCH_SERVER_CPUS:-0-3}"
LOAD_CPUS="${DRUSE_BENCH_LOAD_CPUS:-4-7}"

# Build-time defines for the server under the profiler, space separated, e.g.
#   DRUSE_BENCH_DEFINES="-define:DRUSE_JSON_OWN_MARSHAL=true"
#
# Without this the profiler could only ever profile the DEFAULT build, which
# makes it useless for the one question a variant campaign asks: did the share
# this change was aimed at actually move? The value is recorded in the manifest
# so a profile can never be mistaken for a different variant's.
DEFINES="${DRUSE_BENCH_DEFINES:-}"
PORT=8080

mkdir -p "$OUT"
fail() { echo "PROFILE-FAIL: $*" >&2; exit 1; }

command -v perf >/dev/null 2>&1 || fail "perf is not installed"
sudo -n true 2>/dev/null || fail "perf record needs passwordless sudo here"
ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]" &&
  fail "port $PORT is already in use; refusing to profile a server this script did not start"

# shellcheck disable=SC2086 # DEFINES is a deliberate word list, not one word.
"$ODIN_BIN" build "$MATRIX/druse" -collection:druse="$ROOT" -o:speed $DEFINES \
  -out:"$OUT/server" || fail "the matrix server does not build"
(cd "$ROOT/ops/soak/openload" && go build -buildvcs=false -trimpath \
  -o "$OUT/openload" main.go) || fail "openload does not build"

taskset -c "$SERVER_CPUS" "$OUT/server" "$LANES" >"$OUT/server.log" 2>&1 &
server_pid=$!
cleanup() {
  kill -TERM "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for _ in $(seq 1 100); do
  curl -fsS --max-time 0.5 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  sleep 0.1
done
curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null ||
  fail "the server did not become ready"

# The response this profile is about, recorded so the artefact says what was
# being encoded and how large it was.
curl -sS "http://127.0.0.1:$PORT$ENDPOINT" -o "$OUT/response.json"
body_bytes=$(wc -c <"$OUT/response.json")

{
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "git_head=${DRUSE_BENCH_COMMIT:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
  echo "endpoint=$ENDPOINT"
  echo "offered_rate=$RATE"
  echo "profile_seconds=$DURATION"
  echo "lanes=$LANES"
  echo "response_bytes=$body_bytes"
  echo "server_cpus=$SERVER_CPUS"
  echo "load_cpus=$LOAD_CPUS"
  echo "compiler=$("$ODIN_BIN" version 2>&1 | head -1)"
  echo "kernel=$(uname -srmo)"
  echo "server_sha256=$(sha256sum "$OUT/server" | awk '{print $1}')"
} >"$OUT/manifest.txt"

# Warm up before recording: a profile that includes first-touch page faults and
# a cold branch predictor describes a start-up, not a steady state.
taskset -c "$LOAD_CPUS" "$OUT/openload" -url "http://127.0.0.1:$PORT$ENDPOINT" \
  -rate "$RATE" -duration 5s -connections 128 -timeout 5s >/dev/null 2>&1 || true

taskset -c "$LOAD_CPUS" "$OUT/openload" -url "http://127.0.0.1:$PORT$ENDPOINT" \
  -rate "$RATE" -duration "$((DURATION + 4))s" -connections 128 -timeout 5s \
  -raw "$OUT/load.csv" >"$OUT/load.json" 2>"$OUT/load.err" &
load_pid=$!
sleep 2

sudo -n perf record -F 499 -e cycles:u -g -p "$server_pid" \
  -o "$OUT/perf.data" -- sleep "$DURATION" 2>"$OUT/perf-record.err" ||
  fail "perf record failed: $(cat "$OUT/perf-record.err")"
wait "$load_pid" 2>/dev/null || true
sudo -n chown "$(id -u):$(id -g)" "$OUT/perf.data"

perf report --stdio --no-children --sort symbol,dso -i "$OUT/perf.data" \
  >"$OUT/perf-self.txt" 2>/dev/null || true
perf report --stdio --children -i "$OUT/perf.data" \
  >"$OUT/perf-children.txt" 2>/dev/null || true
perf script -i "$OUT/perf.data" >"$OUT/perf-script.txt" 2>/dev/null || true

{
  # A sample block starts at column zero with the command name; its stack
  # frames are indented. Counting the event name instead is fragile — the
  # kernel fell back from cycles:u to task-clock:u on this host and the count
  # silently reported zero, which is a metric that lies rather than one that
  # is missing.
  echo "defines=${DEFINES:-none}"
  echo "perf_event=$(awk 'NR==1 {print $(NF-1)}' "$OUT/perf-script.txt" 2>/dev/null || echo unknown)"
  echo "perf_samples=$(grep -c '^[^[:space:]]' "$OUT/perf-script.txt" 2>/dev/null || echo 0)"
  echo "goodput=$(python3 -c "import json;print(round(json.load(open('$OUT/load.json'))['goodput_per_second']))" 2>/dev/null || echo unknown)"
  echo "served_share=$(python3 -c "import json;d=json.load(open('$OUT/load.json'));print(round(d['goodput_per_second']/$RATE*100,1))" 2>/dev/null || echo unknown)"
  echo "p50_us=$(python3 -c "import json;print(json.load(open('$OUT/load.json'))['latency_p50_us'])" 2>/dev/null || echo unknown)"
  echo "failures=$(python3 -c "import json;print(json.load(open('$OUT/load.json'))['transport_errors'])" 2>/dev/null || echo unknown)"
} >>"$OUT/manifest.txt"

sha256sum "$OUT"/* 2>/dev/null >"$OUT/SHA256SUMS" || true

echo "=== $ENDPOINT at $RATE/s, $body_bytes bytes per response ==="
grep -E "goodput|served_share|p50_us|failures|perf_samples" "$OUT/manifest.txt"
echo
echo "top self-time symbols:"
grep -E '^\s+[0-9]+\.[0-9]+%' "$OUT/perf-self.txt" | head -25
