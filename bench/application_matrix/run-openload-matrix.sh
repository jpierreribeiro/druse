#!/usr/bin/env bash
# Application matrix under an EQUAL OFFERED RATE, open loop.
#
# The matrix in this directory is driven by `wrk`, which is closed-loop: it
# offers exactly as much load as the server can absorb, so each server is
# measured at its own attained throughput and the latency it reports mixes
# service time with queueing. The README already says so about the peer table —
# "`--latency` prints a histogram, it does not correct for coordinated
# omission" — and that caveat applies here too.
#
# This runner drives every server at the SAME fixed rate with ops/soak/openload,
# whose latency clock starts at the request's intended schedule time. A server
# that falls behind shows it as latency and as goodput below the offered rate,
# instead of quietly being asked for less.
#
# It measures nothing about which server is "faster" in the abstract. It answers
# one question: at a rate all of them can nominally serve, what does each one's
# latency distribution and goodput look like, and where does that break?
#
#   usage: run-openload-matrix.sh OUT_DIR [RATE] [SECONDS] [REPEATS]
#
# REQUIRES A DEDICATED, IDLE HOST. On a shared machine this produces numbers
# about the machine. planning/benchmark-methodology.md is the standard; the
# short version is the four rules this script implements: pinned CPUs, repeats,
# alternating order, and a recorded manifest.
set -euo pipefail

OUT="${1:?usage: run-openload-matrix.sh OUT_DIR [RATE] [SECONDS] [REPEATS]}"
RATE="${2:-20000}"
SECONDS_PER_RUN="${3:-10}"
REPEATS="${4:-5}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MATRIX="$ROOT/bench/application_matrix"
ODIN_BIN="${DRUSE_ODIN_BIN:-odin}"
SERVER_CPUS="${DRUSE_BENCH_SERVER_CPUS:-0-3}"
LOAD_CPUS="${DRUSE_BENCH_LOAD_CPUS:-4-7}"
# Every server in this matrix binds a fixed port in its own source: Druse 8080,
# every peer 8081. They are not configurable, and pretending otherwise is how a
# runner reports "did not become ready" for a server that was running fine.
DRUSE_PORT=8080
PEER_PORT=8081
PORT="$DRUSE_PORT"
LANES="${DRUSE_BENCH_LANES:-4}"

mkdir -p "$OUT"/{bin,runs}

fail() { echo "MATRIX-FAIL: $*" >&2; exit 1; }

# --- build everything up front, so a broken peer fails before any measurement
echo "building..."
"$ODIN_BIN" build "$MATRIX/druse" -collection:druse="$ROOT" -o:speed \
  -out:"$OUT/bin/druse" || fail "the Druse matrix server does not build"
(cd "$ROOT/ops/soak/openload" && go build -buildvcs=false -trimpath \
  -o "$OUT/bin/openload" main.go) || fail "openload does not build"
# The Go peers pin go 1.26 in their go.mod. A host with an older toolchain that
# cannot fetch one is a real situation, and building them elsewhere is a
# legitimate answer — provided the artefact says so. DRUSE_BENCH_PEER_BIN points
# at a directory of prebuilt peers, and the manifest records where they came
# from, because "which Go compiled the peer" is part of what a comparison means.
peer_build="local"
if [ -n "${DRUSE_BENCH_PEER_BIN:-}" ]; then
  cp "$DRUSE_BENCH_PEER_BIN"/{nethttp,gin,fiber} "$OUT/bin/" ||
    fail "DRUSE_BENCH_PEER_BIN=$DRUSE_BENCH_PEER_BIN does not hold nethttp, gin and fiber"
  peer_build="prebuilt:$DRUSE_BENCH_PEER_BIN"
else
  (cd "$MATRIX/peers/go" && go build -o "$OUT/bin/" ./cmd/...) ||
    fail "the Go peers do not build; set DRUSE_BENCH_PEER_BIN to a directory of prebuilt ones"
fi

have_axum=0
if [ -d "$MATRIX/peers/axum" ] && command -v cargo >/dev/null 2>&1; then
  if (cd "$MATRIX/peers/axum" && cargo build --release --locked >/dev/null 2>&1); then
    cp "$MATRIX/peers/axum/target/release/"* "$OUT/bin/axum" 2>/dev/null || true
    [ -x "$OUT/bin/axum" ] && have_axum=1
  fi
fi
have_fastify=0
if [ -d "$MATRIX/peers/fastify" ] && command -v node >/dev/null 2>&1; then
  if [ -d "$MATRIX/peers/fastify/node_modules" ] ||
     (cd "$MATRIX/peers/fastify" && npm ci --silent >/dev/null 2>&1); then
    have_fastify=1
  fi
fi

{
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # The commit, or an explicit refusal to guess. A tree copied without .git — a
  # normal way to get code onto a benchmark host — makes `git rev-parse` print
  # a fatal error to stderr and nothing to stdout, and the manifest silently
  # loses the one field that says WHAT was measured. DRUSE_BENCH_COMMIT carries
  # it in that case; absent both, the artefact says "unknown" out loud.
  echo "git_head=${DRUSE_BENCH_COMMIT:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
  echo "compiler=$("$ODIN_BIN" version 2>&1 | head -1)"
  echo "go=$(go version 2>&1)"
  echo "go_peers=$peer_build"
  if [ "$peer_build" != local ]; then
    echo "go_peers_sha256=$(sha256sum "$OUT/bin/nethttp" "$OUT/bin/gin" "$OUT/bin/fiber" | awk '{printf "%s ", $1}')"
  fi
  echo "node=$(node --version 2>&1 || echo absent)"
  echo "cargo=$(cargo --version 2>&1 || echo absent)"
  echo "kernel=$(uname -srmo)"
  echo "rate_per_second=$RATE"
  echo "seconds_per_run=$SECONDS_PER_RUN"
  echo "repeats=$REPEATS"
  echo "server_cpus=$SERVER_CPUS"
  echo "load_cpus=$LOAD_CPUS"
  echo "druse_lanes=$LANES"
  echo "axum_included=$have_axum"
  echo "fastify_included=$have_fastify"
} >"$OUT/manifest.txt"

port_of() { # server-name -> the port its source binds
  case "$1" in
    druse) echo "$DRUSE_PORT" ;;
    *)     echo "$PEER_PORT" ;;
  esac
}

start_server() { # name -> writes $OUT/server.pid
  PORT="$(port_of "$1")"
  # REFUSE to start if the port is already held. Without this the readiness
  # probe below is satisfied by SOMEBODY ELSE'S server: an orphan from a
  # previous run answers /health, the run proceeds, and every number describes a
  # process this script never started and is about to kill underneath itself.
  # Not hypothetical — it happened on this file's first smoke, and the tell was
  # conn_reused=0 with a p50 of nineteen seconds.
  if ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]"; then
    fail "port $PORT is already in use; refusing to measure a server this script did not start"
  fi
  case "$1" in
    druse)   taskset -c "$SERVER_CPUS" "$OUT/bin/druse" "$LANES" >"$OUT/runs/$1-server.log" 2>&1 & ;;
    nethttp|gin|fiber)
             taskset -c "$SERVER_CPUS" "$OUT/bin/$1" >"$OUT/runs/$1-server.log" 2>&1 & ;;
    axum)    taskset -c "$SERVER_CPUS" "$OUT/bin/axum" >"$OUT/runs/$1-server.log" 2>&1 & ;;
    fastify) (cd "$MATRIX/peers/fastify" && taskset -c "$SERVER_CPUS" node server.mjs) \
               >"$OUT/runs/$1-server.log" 2>&1 & ;;
    *) fail "unknown server $1" ;;
  esac
  echo $! >"$OUT/server.pid"
  for _ in $(seq 1 100); do
    curl -fsS --max-time 0.5 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  fail "$1 did not become ready on port $PORT"
}

stop_server() {
  local pid
  pid="$(cat "$OUT/server.pid" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$OUT/server.pid"
  # And wait for the socket to actually go away. A killed process releases its
  # port asynchronously, so starting the next server immediately is how this
  # script springs the orphan trap above on itself.
  for _ in $(seq 1 100); do
    ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]" || return 0
    sleep 0.1
  done
  fail "port $PORT is still held after stopping the server"
}

# endpoint name | path | method | payload
ENDPOINTS=(
  "health|/health|GET|"
  "json-small|/json/small|GET|"
  "json-medium|/json/medium|GET|"
  "decode-medium|/json/medium/decode|POST|medium-json"
  "extract|/api/users/42?verbose=1|GET|"
)

measure() { # server endpoint-spec repeat
  local server="$1" spec="$2" repeat="$3"
  IFS='|' read -r name path method payload <<<"$spec"
  local args=(-url "http://127.0.0.1:$PORT$path" -method "$method"
              -rate "$RATE" -duration "${SECONDS_PER_RUN}s"
              -connections 128 -timeout 5s
              -raw "$OUT/runs/$server-$name-r$repeat.csv")
  [ -n "$payload" ] && args+=(-payload "$payload")
  taskset -c "$LOAD_CPUS" "$OUT/bin/openload" "${args[@]}" \
    >"$OUT/runs/$server-$name-r$repeat.json" \
    2>"$OUT/runs/$server-$name-r$repeat.err" || true
}

SERVERS=(druse nethttp gin fiber)
[ "$have_axum" = 1 ] && SERVERS+=(axum)
[ "$have_fastify" = 1 ] && SERVERS+=(fastify)

for repeat in $(seq 1 "$REPEATS"); do
  # Alternating order: a one-directional sweep confounds the server with
  # anything that drifts over the session.
  order=("${SERVERS[@]}")
  if [ $((repeat % 2)) -eq 0 ]; then
    reversed=()
    for (( i=${#order[@]}-1; i>=0; i-- )); do reversed+=("${order[i]}"); done
    order=("${reversed[@]}")
  fi
  for server in "${order[@]}"; do
    echo "repeat $repeat: $server"
    start_server "$server"
    sleep 1
    for spec in "${ENDPOINTS[@]}"; do
      measure "$server" "$spec" "$repeat"
    done
    stop_server
    sleep 1
  done
done

python3 "$MATRIX/summarise-openload-matrix.py" "$OUT" | tee "$OUT/summary.txt"
