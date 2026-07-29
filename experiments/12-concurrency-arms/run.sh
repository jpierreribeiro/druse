#!/usr/bin/env bash
# Experiment 12 — measure both concurrency arms. Changes nothing in the tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ODIN="${DRUSE_ODIN_BIN:-}"
if test -z "$ODIN" && command -v odin >/dev/null 2>&1; then ODIN="$(command -v odin)"; fi
if test -z "$ODIN" && test -x /tmp/druse-toolchain/odin; then ODIN=/tmp/druse-toolchain/odin; fi
if test -z "$ODIN"; then echo "EXP12 -> BLOCKED: no Odin toolchain (set DRUSE_ODIN_BIN)." >&2; exit 2; fi

CORES="$(nproc 2>/dev/null || echo 4)"
REQUESTS=400
CLIENTS=16

TMP="$(mktemp -d -t druse-exp12-XXXXXXXX)"
trap 'rm -rf "$TMP"; pkill -f "exp12-arm" 2>/dev/null || true' EXIT

# One arm = one copy of the tree with thread_count patched.
build_arm() { # name threads port
  local name="$1" threads="$2"
  local t="$TMP/$name"
  mkdir -p "$t/druse"
  cp -r "$ROOT/web" "$ROOT/vendor" "$t/druse/"
  mkdir -p "$t/consumer"
  cp "$ROOT/experiments/12-concurrency-arms/consumer/main.odin" "$t/consumer/"

  python3 - "$t/druse/web/internal/transport/odin_http_adapter.odin" "$threads" <<'PY'
import sys
p, n = sys.argv[1], sys.argv[2]
s = open(p).read()
old = "\topts.thread_count = 1"
assert old in s, "thread_count anchor not found"
open(p, 'w').write(s.replace(old, "\topts.thread_count = %s" % n, 1))
PY

  env -u ODIN_ROOT "$ODIN" build "$t/consumer" -collection:druse="$t/druse" \
    -o:speed -out:"$TMP/exp12-arm-$name" >/dev/null 2>&1 ||
    { echo "EXP12: arm '$name' did not build" >&2; exit 1; }
  printf '%s' "$TMP/exp12-arm-$name"
}

drive() { # binary port label
  local bin="$1" port="$2" label="$3"
  "$bin" "$port" >/dev/null 2>&1 &
  local pid=$!
  # Wait for the listener rather than sleeping a fixed amount.
  for _ in $(seq 1 100); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then exec 3<&- 3>&-; break; fi
    sleep 0.05
  done

  local start end ok
  start="$(date +%s%N)"
  ok=0
  for _ in $(seq 1 "$CLIENTS"); do
    (
      per=$(( REQUESTS / CLIENTS ))
      for _ in $(seq 1 "$per"); do
        curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 \
          "http://127.0.0.1:$port/work" || echo 000
      done
    ) &
  done >"$TMP/$label.codes"
  wait $(jobs -rp | grep -v "^$pid$" 2>/dev/null) 2>/dev/null || true
  end="$(date +%s%N)"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true

  ok="$(grep -c '^200$' "$TMP/$label.codes" 2>/dev/null || echo 0)"
  local total
  total="$(grep -c . "$TMP/$label.codes" 2>/dev/null || echo 0)"
  printf '%s\t%s\t%s\t%s\n' "$label" "$(( (end - start) / 1000000 ))" "$ok" "$total"
}

echo "# experiment 12 — concurrency arms"
echo "# cores=$CORES requests=$REQUESTS clients=$CLIENTS"
echo "# columns: arm wall_ms http_200 total_responses"

A="$(build_arm single 1)"
drive "$A" 58081 "single-threaded"

B="$(build_arm threaded "$CORES")"
drive "$B" 58082 "threaded-$CORES"

echo "# A wall-clock difference smaller than FINDING-A's 138% noise floor is not"
echo "# a result. Correctness, not speed, is what decides this (see the ADR)."
