#!/usr/bin/env bash
# Where does each server's knee sit?
#
# A latency comparison taken at one rate compares whatever queues happened to
# exist at that rate. On 2026-07-30 the matrix reported a p50 of 113 ms for
# Druse against 145 us for the peers on nested JSON — a number that turned out
# to describe how far a queue had grown, not what a request cost. Five repeats
# of it spanned 101 ms to 199 ms while the peers held 144-145 us with a spread
# of one microsecond, which is the difference between a server past its knee and
# three servers nowhere near theirs.
#
# This sweeps the offered rate for one endpoint and reports, per server and per
# rate: goodput, the share of the offered rate it served, p50, p99, and
# failures. The knee is the rate where goodput stops tracking the offer. Below
# it, p50 is a service time and comparable; above it, p50 is a queue depth and
# is not.
#
#   usage: run-rate-sweep.sh OUT_DIR ENDPOINT_PATH [SECONDS] [REPEATS] [RATES...]
#
#   run-rate-sweep.sh /tmp/sweep /json/medium/int 10 3 5000 10000 15000 20000 25000
#
# Use the byte-identical endpoint for a cross-server claim. /json/medium is 960
# bytes larger on Druse than on the Go peers, so its rows compare payloads as
# well as servers.
#
# REQUIRES A DEDICATED, IDLE HOST, for the same reason the matrix does.
set -euo pipefail

OUT="${1:?usage: run-rate-sweep.sh OUT_DIR ENDPOINT_PATH [SECONDS] [REPEATS] [RATES...]}"
ENDPOINT="${2:?an endpoint path, e.g. /json/medium/int}"
SECONDS_PER_RUN="${3:-10}"
REPEATS="${4:-3}"
shift 4 2>/dev/null || shift $#
RATES=("$@")
[ ${#RATES[@]} -eq 0 ] && RATES=(5000 10000 15000 20000 25000 30000)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MATRIX="$ROOT/bench/application_matrix"
ODIN_BIN="${DRUSE_ODIN_BIN:-odin}"
SERVER_CPUS="${DRUSE_BENCH_SERVER_CPUS:-0-3}"
LOAD_CPUS="${DRUSE_BENCH_LOAD_CPUS:-4-7}"
DRUSE_PORT=8080
PEER_PORT=8081
LANES="${DRUSE_BENCH_LANES:-4}"

mkdir -p "$OUT"/{bin,runs}
fail() { echo "SWEEP-FAIL: $*" >&2; exit 1; }

"$ODIN_BIN" build "$MATRIX/druse" -collection:druse="$ROOT" -o:speed \
  -out:"$OUT/bin/druse" || fail "the Druse matrix server does not build"
(cd "$ROOT/ops/soak/openload" && go build -buildvcs=false -trimpath \
  -o "$OUT/bin/openload" main.go) || fail "openload does not build"
if [ -n "${DRUSE_BENCH_PEER_BIN:-}" ]; then
  cp "$DRUSE_BENCH_PEER_BIN"/{nethttp,gin,fiber} "$OUT/bin/" ||
    fail "DRUSE_BENCH_PEER_BIN does not hold the three Go peers"
else
  (cd "$MATRIX/peers/go" && go build -o "$OUT/bin/" ./cmd/...) ||
    fail "the Go peers do not build; set DRUSE_BENCH_PEER_BIN"
fi

{
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "git_head=${DRUSE_BENCH_COMMIT:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
  echo "endpoint=$ENDPOINT"
  echo "rates=${RATES[*]}"
  echo "seconds_per_run=$SECONDS_PER_RUN"
  echo "repeats=$REPEATS"
  echo "server_cpus=$SERVER_CPUS"
  echo "load_cpus=$LOAD_CPUS"
  echo "druse_lanes=$LANES"
  echo "compiler=$("$ODIN_BIN" version 2>&1 | head -1)"
  echo "kernel=$(uname -srmo)"
} >"$OUT/manifest.txt"

port_of() { case "$1" in druse) echo "$DRUSE_PORT" ;; *) echo "$PEER_PORT" ;; esac; }

start_server() {
  PORT="$(port_of "$1")"
  ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]" &&
    fail "port $PORT is already in use; refusing to measure a server this script did not start"
  case "$1" in
    druse) taskset -c "$SERVER_CPUS" "$OUT/bin/druse" "$LANES" >"$OUT/runs/$1-server.log" 2>&1 & ;;
    *)     taskset -c "$SERVER_CPUS" "$OUT/bin/$1" >"$OUT/runs/$1-server.log" 2>&1 & ;;
  esac
  echo $! >"$OUT/server.pid"
  for _ in $(seq 1 100); do
    curl -fsS --max-time 0.5 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  fail "$1 did not become ready on port $PORT"
}

stop_server() {
  local pid; pid="$(cat "$OUT/server.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$OUT/server.pid"
  for _ in $(seq 1 100); do
    ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]" || return 0
    sleep 0.1
  done
  fail "port $PORT is still held after stopping the server"
}

SERVERS=(druse nethttp gin fiber)

for repeat in $(seq 1 "$REPEATS"); do
  order=("${SERVERS[@]}")
  if [ $((repeat % 2)) -eq 0 ]; then
    reversed=(); for (( i=${#order[@]}-1; i>=0; i-- )); do reversed+=("${order[i]}"); done
    order=("${reversed[@]}")
  fi
  for server in "${order[@]}"; do
    start_server "$server"
    sleep 1
    # Rates ascend within a server visit, so a server is never asked for a high
    # rate on a cold cache while another gets a warm one.
    for rate in "${RATES[@]}"; do
      echo "repeat $repeat: $server at $rate/s"
      taskset -c "$LOAD_CPUS" "$OUT/bin/openload" \
        -url "http://127.0.0.1:$PORT$ENDPOINT" -method GET \
        -rate "$rate" -duration "${SECONDS_PER_RUN}s" -connections 128 -timeout 5s \
        -raw "$OUT/runs/$server-$rate-r$repeat.csv" \
        >"$OUT/runs/$server-$rate-r$repeat.json" \
        2>"$OUT/runs/$server-$rate-r$repeat.err" || true
      sleep 1
    done
    stop_server
    sleep 1
  done
done

python3 "$MATRIX/summarise-rate-sweep.py" "$OUT" | tee "$OUT/summary.txt"
