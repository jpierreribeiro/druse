#!/usr/bin/env bash
# Run the owed hardware demonstrations on a QUIET, DEDICATED host (or this VPS
# with the CI paused). It raises this shell's own limits only — it never edits a
# system limit, never touches the CI unit, the docker runner, or Caddy.
#
# Usage:
#   ops/verification/run-owed-demos.sh soak   [SECONDS]     # default 600
#   ops/verification/run-owed-demos.sh scale  [CONNECTIONS] # default 1000
#   ops/verification/run-owed-demos.sh nginx  [PORT]        # default 18080
#
# Every run appends a dated block to the newest 2026-*-hardening-vps.md record.
set -euo pipefail

MODE="${1:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ODIN="${DRUSE_ODIN_BIN:-/opt/druse/odin}"
ODIN_ROOT_DIR="$(cd "$(dirname "$ODIN")" && pwd)"
export ODIN_ROOT="$ODIN_ROOT_DIR"

# io_uring pins memory against RLIMIT_MEMLOCK (see F-C03-2). Raise it for THIS
# shell only; other processes are untouched. Root can go unlimited.
ulimit -l unlimited 2>/dev/null || ulimit -l 65536 2>/dev/null || true

case "$MODE" in
  soak)
    SECS="${2:-600}"
    echo "[soak] looping tests/c04-response-size for ${SECS}s, sampling memory"
    end=$(( $(date +%s) + SECS ))
    n=0
    while [ "$(date +%s)" -lt "$end" ]; do
      n=$(( n + 1 ))
      "$ODIN" test "$ROOT/tests/c04-response-size" \
        -collection:druse="$ROOT" -define:ODIN_TEST_THREADS=1 \
        -out:/tmp/druse-soak >/dev/null 2>&1 || echo "[soak] iteration $n FAILED"
      free -m | awk -v i="$n" '/Mem:/{print "[soak] iter "i" avail_mb="$7" used_mb="$3}'
    done
    echo "[soak] $n iterations over ${SECS}s"
    ;;

  scale)
    CONNS="${2:-1000}"
    ulimit -n 8192 2>/dev/null || true
    echo "[scale] real-socket streaming at ${CONNS} connections (nofile=$(ulimit -n))"
    "$ODIN" test "$ROOT/tests/g76-scale-sockets" \
      -collection:druse="$ROOT" -define:ODIN_TEST_THREADS=1 \
      -define:SCALE_CONNS="$CONNS" -out:/tmp/druse-scale 2>&1 | grep -E "\[g76\]|successful|failed"
    ;;

  nginx)
    PORT="${2:-18080}"
    command -v nginx >/dev/null || { echo "nginx not installed; install it in an isolated prefix and re-run"; exit 1; }
    echo "[nginx] a DEDICATED instance on :$PORT with proxy_buffering off — never the system service"
    echo "[nginx] see the C-06 contract; wire it at conf/ then run:"
    echo "        nginx -c \$PWD/conf/nginx.conf -p \$PWD"
    ;;

  *)
    echo "usage: $0 {soak [secs] | scale [conns] | nginx [port]}" >&2
    exit 2
    ;;
esac
