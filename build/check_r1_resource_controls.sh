#!/usr/bin/env bash
# R1-WP02 — prove that the runtime preflight distinguishes every resource
# contract it claims to enforce.  All mutations live in a temporary directory;
# this script neither needs systemd nor changes the host's cgroup/rlimits.

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROFILE="$ROOT/ops/deploy/runtime-limits.example"
PREFLIGHT="$ROOT/ops/deploy/check-runtime-limits.sh"
DRILL="$ROOT/ops/verification/run-resource-drill.sh"
CLIENT="$ROOT/tests/r1-resource-budget/client.py"
ODIN_BIN="${DRUSE_ODIN_BIN:-${DRUSE_COMPILER:-$(command -v odin)}}"

fail() {
  echo "ERROR: R1 resource control: $*" >&2
  exit 1
}

test -r "$PROFILE" || fail "missing $PROFILE"
test -x "$PREFLIGHT" || fail "missing executable $PREFLIGHT"
test -x "$DRILL" || fail "missing executable $DRILL"
test -x "$CLIENT" || fail "missing executable $CLIENT"
bash -n "$DRILL" || fail "run-resource-drill.sh does not parse"
python3 -c 'from pathlib import Path; compile(Path("'"$CLIENT"'").read_text(), "client.py", "exec")' ||
  fail "resource drill client does not parse"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/spool" "$WORK/allowed"
printf '%s\n' 1073741824 > "$WORK/memory.max"
printf '%s\n' max > "$WORK/memory.unlimited"

"$ODIN_BIN" build "$ROOT/tests/r1-resource-budget/server" \
  -collection:druse="$ROOT" -out:"$WORK/resource-server" ||
  fail "resource-budget fixture does not compile"

set -a
# shellcheck disable=SC1090
. "$PROFILE"
set +a

BASE_ENV=(
  "DRUSE_SPOOL_DIR=$WORK/spool"
  "DRUSE_READ_WRITE_PATHS=$WORK"
  DRUSE_PREFLIGHT_NOFILE=2048
  DRUSE_PREFLIGHT_MEMLOCK_BYTES=67108864
  "DRUSE_PREFLIGHT_MEMORY_MAX_FILE=$WORK/memory.max"
)

POSITIVE="$WORK/positive.log"
env "${BASE_ENV[@]}" "$PREFLIGHT" --explain > "$POSITIVE" 2>&1 || {
  sed -n '1,120p' "$POSITIVE" >&2
  fail "canonical positive profile did not pass"
}
grep -Fq 'total=1213' "$POSITIVE" || fail "positive case did not derive the frozen 1213-FD budget"
grep -Fq 'required=999211008' "$POSITIVE" || fail "positive case did not derive measured peak plus 200% memory headroom"

expect_red() {
  local label="$1"
  local needle="$2"
  shift 2
  local log="$WORK/$label.log"
  if env "${BASE_ENV[@]}" "$@" "$PREFLIGHT" > "$log" 2>&1; then
    fail "$label mutation passed; the preflight no longer detects it"
  fi
  grep -Fq "$needle" "$log" || {
    sed -n '1,100p' "$log" >&2
    fail "$label failed for the wrong reason (expected '$needle')"
  }
}

expect_red nofile-effective 'effective soft nofile=1212' DRUSE_PREFLIGHT_NOFILE=1212
expect_red nofile-formula 'below derived requirement 1213' DRUSE_EXPECTED_NOFILE=1212
expect_red memlock 'effective memlock=16384 bytes' DRUSE_PREFLIGHT_MEMLOCK_BYTES=16384
expect_red timeout 'must be greater than DRUSE_MAX_DRAIN_TIME_SEC' DRUSE_TIMEOUT_STOP_SEC=10
expect_red inherited 'critical limits may not remain inherited' DRUSE_LIMITS_SOURCE=inherited
expect_red extrapolated-handlers 'handler count exceeds the measured memory profile' DRUSE_MAX_HANDLERS=9
expect_red missing-spool 'spool directory does not exist' DRUSE_SPOOL_DIR="$WORK/missing"
expect_red outside-spool 'is outside DRUSE_READ_WRITE_PATHS' DRUSE_READ_WRITE_PATHS="$WORK/allowed"
expect_red memory-unlimited 'memory.max is unlimited' DRUSE_PREFLIGHT_MEMORY_MAX_FILE="$WORK/memory.unlimited"

printf '%s\n' 900000000 > "$WORK/memory.too-small"
expect_red memory-headroom 'below measured peak plus headroom 999211008' \
  DRUSE_MEMORY_MAX_BYTES=900000000 \
  DRUSE_PREFLIGHT_MEMORY_MAX_FILE="$WORK/memory.too-small"

chmod 0500 "$WORK/spool"
expect_red spool-write 'spool directory is not writable' DRUSE_SPOOL_DIR="$WORK/spool"
chmod 0700 "$WORK/spool"

echo "PASS: R1 runtime preflight accepts the measured profile and rejects nofile/formula, memlock, timeout, inherited limits, unmeasured capacity, spool and cgroup mutations"
