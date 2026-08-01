#!/usr/bin/env bash
# R1-WP01 — signal, socket and process-exit drill without systemd.
set -euo pipefail

DRUSE_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
DRUSE_COLLECTION_ROOT="${DRUSE_COLLECTION_ROOT:-$DRUSE_ROOT}"
DRUSE_ODIN="${DRUSE_ODIN_BIN:-$(command -v odin || true)}"
DRUSE_ARM="${DRUSE_R1_ARM:-all}"

fail() {
  echo "R1-SHUTDOWN-FAIL: $*" >&2
  exit 1
}

test -n "$DRUSE_ODIN" || fail "Odin compiler not found (set DRUSE_ODIN_BIN)"
test -f "$DRUSE_ROOT/tests/r1-process-shutdown/server/main.odin" || fail "process fixture missing"
test -f "$DRUSE_ROOT/tests/r1-process-shutdown/client.py" || fail "raw client missing"

DRILL_TMP="$(mktemp -d -t druse-r1-shutdown-XXXXXXXX)"
SERVER_PID=""
CLIENT_PID=""
cleanup() {
  if test -n "$CLIENT_PID"; then kill -KILL "$CLIENT_PID" 2>/dev/null || true; fi
  if test -n "$SERVER_PID"; then kill -KILL "$SERVER_PID" 2>/dev/null || true; fi
  if test "${DRUSE_KEEP_TMP:-0}" = 1; then
    echo "R1 shutdown drill retained: $DRILL_TMP" >&2
    return
  fi
  rm -rf "$DRILL_TMP"
}
trap cleanup EXIT

"$DRUSE_ODIN" build "$DRUSE_ROOT/tests/r1-process-shutdown/server" \
  "-collection:druse=$DRUSE_COLLECTION_ROOT" -out:"$DRILL_TMP/server"

wait_file() {
  local path=$1
  local deadline=$((SECONDS + 6))
  while ! test -f "$path"; do
    test "$SECONDS" -lt "$deadline" || fail "timed out waiting for ${path##*/}"
    sleep 0.01
  done
}

wait_http() {
  local port=$1
  local deadline=$((SECONDS + 6))
  while ! curl --silent --fail --max-time 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; do
    kill -0 "$SERVER_PID" 2>/dev/null || fail "server exited before port $port became ready"
    test "$SECONDS" -lt "$deadline" || fail "port $port did not become ready"
    sleep 0.02
  done
}

start_server() {
  local arm=$1
  local port=$2
  local mode=${3:-single}
  local port_b=${4:-0}
  local dir="$DRILL_TMP/$arm"
  mkdir -p "$dir/markers" "$dir/spool"
  R1_MODE="$mode" R1_PORT="$port" R1_PORT_B="$port_b" \
    R1_MARKER_DIR="$dir/markers" R1_SPOOL_DIR="$dir/spool" \
    "$DRILL_TMP/server" >"$dir/server.log" 2>&1 &
  SERVER_PID=$!
  wait_http "$port"
}

wait_clean_exit() {
  local deadline=$((SECONDS + 6))
  while kill -0 "$SERVER_PID" 2>/dev/null; do
    test "$SECONDS" -lt "$deadline" || fail "server did not exit inside the process-drill margin"
    sleep 0.02
  done
  local status=0
  wait "$SERVER_PID" || status=$?
  SERVER_PID=""
  test "$status" -eq 0 || fail "server exited $status, expected clean exit 0"
}

run_client() {
  local arm=$1
  shift
  python3 "$DRUSE_ROOT/tests/r1-process-shutdown/client.py" "$@" \
    >"$DRILL_TMP/$arm/client.out" 2>"$DRILL_TMP/$arm/client.err" &
  CLIENT_PID=$!
}

wait_client() {
  local deadline=$((SECONDS + 7))
  while kill -0 "$CLIENT_PID" 2>/dev/null; do
    test "$SECONDS" -lt "$deadline" || fail "raw client did not finish inside its drill margin"
    sleep 0.02
  done
  local status=0
  wait "$CLIENT_PID" || status=$?
  CLIENT_PID=""
  test "$status" -eq 0 || fail "raw client exited $status"
}

arm_s0() {
  local arm=s0-readiness port=54201
  start_server "$arm" "$port"
  run_client "$arm" request "$port" "$DRILL_TMP/$arm/client-connected" /watch
  wait_file "$DRILL_TMP/$arm/markers/watch-entered"
  kill -TERM "$SERVER_PID"
  wait_client
  grep -q 'HTTP/1.1 503 ' "$DRILL_TMP/$arm/client.out" || fail "S0 did not observe readiness=503"
  grep -q 'draining' "$DRILL_TMP/$arm/client.out" || fail "S0 did not observe the draining body"
  wait_file "$DRILL_TMP/$arm/markers/watch-observed-draining"
  wait_clean_exit
  echo "R1 S0 PASS: draining became observable before serve returned"
}

arm_s1() {
  local arm=s1-keepalive port=54211
  start_server "$arm" "$port"
  run_client "$arm" keepalive "$port" "$DRILL_TMP/$arm/client-ready"
  wait_file "$DRILL_TMP/$arm/client-ready"
  kill -TERM "$SERVER_PID"
  wait_client
  wait_clean_exit
  echo "R1 S1 PASS: idle keep-alive closed and process exited cleanly"
}

arm_s2() {
  local arm=s2-short port=54221
  start_server "$arm" "$port"
  run_client "$arm" request "$port" "$DRILL_TMP/$arm/client-connected" /short
  wait_file "$DRILL_TMP/$arm/markers/short-entered"
  kill -TERM "$SERVER_PID"
  wait_client
  grep -q 'HTTP/1.1 200 ' "$DRILL_TMP/$arm/client.out" || fail "S2 in-flight short handler did not complete"
  grep -q 'short-complete' "$DRILL_TMP/$arm/client.out" || fail "S2 response body was incomplete"
  wait_clean_exit
  echo "R1 S2 PASS: short in-flight handler completed during drain"
}

arm_s3() {
  local arm=s3-slow-reader port=54231
  start_server "$arm" "$port"
  run_client "$arm" slow-read "$port" "$DRILL_TMP/$arm/client-ready"
  wait_file "$DRILL_TMP/$arm/client-ready"
  wait_file "$DRILL_TMP/$arm/markers/large-committed"
  kill -TERM "$SERVER_PID"
  wait_clean_exit
  kill -TERM "$CLIENT_PID" 2>/dev/null || true
  wait "$CLIENT_PID" 2>/dev/null || true
  CLIENT_PID=""
  echo "R1 S3 PASS: slow reader did not outlive write/drain bounds"
}

arm_s4() {
  local arm=s4-stream port=54241
  start_server "$arm" "$port"
  run_client "$arm" request "$port" "$DRILL_TMP/$arm/client-connected" /stream
  wait_file "$DRILL_TMP/$arm/markers/stream-opened"
  kill -TERM "$SERVER_PID"
  wait_client
  grep -q 'HTTP/1.1 200 ' "$DRILL_TMP/$arm/client.out" || fail "S4 stream head was not committed"
  python3 - "$DRILL_TMP/$arm/client.out" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read()
if not raw.endswith(b"0\r\n\r\n"):
    raise SystemExit("R1-SHUTDOWN-FAIL: S4 stream was force-closed without its terminating chunk")
PY
  wait_clean_exit
  echo "R1 S4 PASS: open stream drained and process exited"
}

arm_s5() {
  local arm=s5-upload port=54251
  start_server "$arm" "$port"
  run_client "$arm" slow-upload "$port" "$DRILL_TMP/$arm/client-ready"
  wait_file "$DRILL_TMP/$arm/client-ready"
  local deadline=$((SECONDS + 4))
  while ! find "$DRILL_TMP/$arm/spool" -maxdepth 1 -type f -name 'druse-spool-*' | grep -q .; do
    test "$SECONDS" -lt "$deadline" || fail "S5 never created a live spool"
    sleep 0.01
  done
  kill -TERM "$SERVER_PID"
  wait_client
  wait_clean_exit
  if find "$DRILL_TMP/$arm/spool" -maxdepth 1 -type f -name 'druse-spool-*' | grep -q .; then
    fail "S5 left an owned spool after shutdown"
  fi
  echo "R1 S5 PASS: in-progress spool was cancelled and cleaned"
}

arm_s6() {
  local arm=s6-blocked port=54261
  start_server "$arm" "$port"
  run_client "$arm" request "$port" "$DRILL_TMP/$arm/client-connected" /blocked
  wait_file "$DRILL_TMP/$arm/markers/blocked-entered"
  kill -TERM "$SERVER_PID"
  sleep 1
  kill -0 "$SERVER_PID" 2>/dev/null || fail "S6 process exited as if max_drain_time could preempt a handler"
  kill -KILL "$SERVER_PID"
  local status=0
  wait "$SERVER_PID" 2>/dev/null || status=$?
  SERVER_PID=""
  test "$status" -eq 137 || fail "S6 supervisor action produced status $status, expected SIGKILL/137"
  kill -KILL "$CLIENT_PID" 2>/dev/null || true
  wait "$CLIENT_PID" 2>/dev/null || true
  CLIENT_PID=""
  echo "R1 S6 PASS: blocked handler required explicit supervisor SIGKILL (137)"
}

arm_s7() {
  local arm=s7-repeat port=54271
  start_server "$arm" "$port"
  run_client "$arm" request "$port" "$DRILL_TMP/$arm/client-connected" /watch
  wait_file "$DRILL_TMP/$arm/markers/watch-entered"
  kill -TERM "$SERVER_PID"
  kill -TERM "$SERVER_PID" 2>/dev/null || true
  wait_client
  wait_clean_exit
  wait_file "$DRILL_TMP/$arm/markers/serve-a-returned"
  echo "R1 S7 PASS: repeated stop signal kept one clean shutdown"
}

arm_s8() {
  local arm=s8-two-apps port=54281 port_b=54282
  start_server "$arm" "$port" two "$port_b"
  wait_http "$port_b"
  kill -TERM "$SERVER_PID"
  local deadline=$((SECONDS + 4))
  while curl --silent --fail --max-time 1 "http://127.0.0.1:$port/health" >/dev/null 2>&1; do
    test "$SECONDS" -lt "$deadline" || fail "S8 App A kept accepting after SIGTERM"
    sleep 0.02
  done
  curl --silent --fail --max-time 2 "http://127.0.0.1:$port_b/health" >/dev/null || fail "S8 stopping App A affected App B"
  curl --silent --max-time 2 "http://127.0.0.1:$port_b/stop" >/dev/null || true
  wait_clean_exit
  wait_file "$DRILL_TMP/$arm/markers/serve-a-returned"
  wait_file "$DRILL_TMP/$arm/markers/serve-b-returned"
  echo "R1 S8 PASS: SIGTERM stopped App A while App B remained healthy"
}

if test "$DRUSE_ARM" = all; then
  for n in 0 1 2 3 4 5 6 7 8; do "arm_s$n"; done
else
  case "$DRUSE_ARM" in
    s0|S0) arm_s0 ;;
    s1|S1) arm_s1 ;;
    s2|S2) arm_s2 ;;
    s3|S3) arm_s3 ;;
    s4|S4) arm_s4 ;;
    s5|S5) arm_s5 ;;
    s6|S6) arm_s6 ;;
    s7|S7) arm_s7 ;;
    s8|S8) arm_s8 ;;
    *) fail "unknown DRUSE_R1_ARM=$DRUSE_ARM" ;;
  esac
fi

echo "PASS: R1 real-process shutdown drill"
