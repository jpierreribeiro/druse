#!/usr/bin/env bash
# R2-WP06 — run the mutational raw-wire fuzz against the candidate.
#
#   usage: run-wire-fuzz.sh [OUTPUT_DIR]
#
# Starts `tests/support/wire_origin` — the same origin the proxy comparison uses,
# so `/smuggled` is present as an oracle — points the fuzzer at it, and grades
# the run against four things the server must never do (see `wire_fuzz.py`).
#
# The origin is started fresh and its counters are read at shutdown, so a hit on
# `/smuggled` belongs to THIS run and to no earlier one.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/evidence/$(date -u +%F)-r2-wire-fuzz}"
WORK="$(mktemp -d -t druse-wirefuzz-XXXXXXXX)"
PORT="${DRUSE_FUZZ_PORT:-18801}"
SERVER_PID=""

cleanup() {
  [[ -n "$SERVER_PID" ]] && kill -TERM "$SERVER_PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "WIRE-FUZZ: $*" >&2; exit 1; }

if   [[ -n "${DRUSE_COMPILER:-}" ]];     then ODIN="$DRUSE_COMPILER"
elif [[ -n "${DRUSE_ODIN_BIN:-}" ]];     then ODIN="$DRUSE_ODIN_BIN"
elif command -v odin >/dev/null 2>&1;    then ODIN="$(command -v odin)"
else fail "no Odin compiler"; fi
ODIN="$(readlink -f "$ODIN")"

mkdir -p "$OUT/raw" "$OUT/analysis"

env ODIN_ROOT="$(cd "$(dirname "$ODIN")" && pwd)" "$ODIN" build \
  "$ROOT/tests/support/wire_origin" -collection:druse="$ROOT" -o:speed \
  -out:"$WORK/origin" >"$WORK/build.log" 2>&1 ||
  { cat "$WORK/build.log" >&2; fail "origin build failed"; }
CANDIDATE_SHA="$(sha256sum "$WORK/origin" | awk '{print $1}')"

"$WORK/origin" "$PORT" >"$WORK/origin.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 200); do
  curl --noproxy '*' -fsS --max-time 1 "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1 && break
  sleep 0.1
done
curl --noproxy '*' -fsS --max-time 2 "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1 ||
  fail "the origin never became ready on port $PORT"

DRUSE_FUZZ_PORT="$PORT" \
DRUSE_FUZZ_CORPUS="$ROOT/tests/support/transport_conformance/corpus.odin" \
DRUSE_FUZZ_CASES="${DRUSE_FUZZ_CASES:-4000}" \
DRUSE_FUZZ_SEED="${DRUSE_FUZZ_SEED:-20260803}" \
  python3 "$ROOT/ops/verification/wire_fuzz.py" >"$OUT/raw/fuzz.json" 2>"$OUT/raw/fuzz.err"
FUZZ_RC=$?

# Oracle 1: the process is still alive. Checked by PID, never by a pattern —
# `pgrep -f` over ssh matches the shell's own command line and kills the session,
# which this repository has paid for twice.
if kill -0 "$SERVER_PID" 2>/dev/null; then ALIVE=yes; else ALIVE=no; fi

kill -TERM "$SERVER_PID" 2>/dev/null
for _ in $(seq 1 100); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.1; done
SERVER_PID=""
cp "$WORK/origin.log" "$OUT/raw/origin.log" 2>/dev/null || true
# `grep -a`, and the `-a` is not decoration. The fuzzer sends NUL bytes, the
# origin logs request text, so the log becomes a BINARY file to grep — which then
# matches nothing and says nothing. The oracle below read an empty string and
# reported "/smuggled was executed  time(s)". It failed closed, which is the
# right direction, but an oracle whose message has a hole where the number goes
# is one nobody can act on.
grep -ah "wire_origin_counters" "$WORK/origin.log" >"$OUT/raw/origin-counters.txt" 2>/dev/null ||
  echo "wire_origin_counters=UNAVAILABLE" >"$OUT/raw/origin-counters.txt"

# Oracle 2: `/smuggled` was never executed. The readiness probe accounts for the
# single /ping, so any smuggled hit is the fuzzer's doing.
SMUGGLED="$(grep -ao 'smuggled=[0-9]*' "$OUT/raw/origin-counters.txt" | head -n 1 | cut -d= -f2)"

{
  echo "utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
  echo "working_tree_dirty_files=$(git -C "$ROOT" status --porcelain | wc -l)"
  echo "candidate=tests/support/wire_origin"
  echo "candidate_sha256=$CANDIDATE_SHA"
  echo "odin=$("$ODIN" version 2>&1 | head -n 1)"
  echo "cases=${DRUSE_FUZZ_CASES:-4000}"
  echo "seed=${DRUSE_FUZZ_SEED:-20260803}"
  echo "oracle1_server_alive_at_end=$ALIVE"
  echo "oracle2_smuggled_executions=${SMUGGLED:-unknown}"
  echo "oracle3_4_violations=$(python3 -c "
import json,sys
try: print(len(json.load(open('$OUT/raw/fuzz.json'))['violations']))
except Exception: print('unreadable')")"
} >"$OUT/manifest.txt"

(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
echo "wire-fuzz evidence written to $OUT" >&2

[[ "$ALIVE" == "yes" ]] || fail "ORACLE 1 FAILED: the server did not survive the run"
# An unreadable counter is not a pass. Stated separately from a non-zero count
# so the two failures cannot be confused: one means the server executed a request
# nobody sent, the other means nobody can tell.
[[ "$SMUGGLED" =~ ^[0-9]+$ ]] ||
  fail "ORACLE 2 UNREADABLE: the origin's smuggled counter could not be read from $OUT/raw/origin-counters.txt; an oracle that cannot be read has not passed"
[[ "$SMUGGLED" == "0" ]] || fail "ORACLE 2 FAILED: /smuggled was executed $SMUGGLED time(s)"
exit "$FUZZ_RC"
