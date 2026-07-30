#!/usr/bin/env bash
# WP72 — combined concurrency, shutdown and Phase-5 feature verdict.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP72-CONTROL-FAIL: $*" >&2
  exit 1
}

if test -n "${DRUSE_COMPILER:-}"; then
  DRUSE_ODIN="$DRUSE_COMPILER"
elif test -n "${DRUSE_ODIN_BIN:-}"; then
  DRUSE_ODIN="$DRUSE_ODIN_BIN"
elif command -v odin >/dev/null 2>&1; then
  DRUSE_ODIN="$(command -v odin)"
elif test -x /tmp/druse-toolchain/odin; then
  DRUSE_ODIN=/tmp/druse-toolchain/odin
else
  fail "odin compiler not found"
fi

DRUSE_ODIN="$(readlink -f "$DRUSE_ODIN")"
DRUSE_ODIN_ROOT="$(cd "$(dirname "$DRUSE_ODIN")" && pwd)"
DRUSE_TMP="$(mktemp -d -t druse-wp72-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

# Client and server sockets live in the same test process: 3,000 keep-alives
# need at least 6,000 descriptors. The default laboratory soft limit of 1,024
# fails at roughly 506 clients and says nothing about Druse.
ulimit -n 8192 2>/dev/null ||
  fail "the 3,000-connection laboratory requires a soft RLIMIT_NOFILE of 8192"
test "$(ulimit -n)" -ge 8192 ||
  fail "RLIMIT_NOFILE remained below 8192"

run_test() { # package, binary, timeout seconds, collection optional
  local package="$1" binary="$2" seconds="$3" collection="${4:-$DRUSE_ROOT}"
  timeout "$seconds" env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test "$package" \
    "-collection:druse=$collection" -define:ODIN_TEST_THREADS=1 \
    "-out:$DRUSE_TMP/$binary"
}

# Standalone execution owns the complete verdict. build/check.sh has already
# run these exact prerequisites and sets the flag to avoid paying twice.
if test "${DRUSE_WP72_PREREQS_ALREADY_GREEN:-0}" != 1; then
  env DRUSE_COMPILER="$DRUSE_ODIN" bash "$DRUSE_ROOT/build/check_wp69_controls.sh"
  env DRUSE_COMPILER="$DRUSE_ODIN" bash "$DRUSE_ROOT/build/check_wp70_controls.sh"
  env DRUSE_COMPILER="$DRUSE_ODIN" bash "$DRUSE_ROOT/build/check_wp71_controls.sh"
  run_test "$DRUSE_ROOT/tests/wp58-drain" wp58-drain 120
fi

run_test "$DRUSE_ROOT/tests/wp72-concurrent-serving/features" features 40
run_test "$DRUSE_ROOT/tests/wp72-concurrent-serving/keepalive" keepalive 90

# The scale case must own the global-admission mechanism. Reducing the server
# budget to 512 leaves the harness limit unchanged and must refuse long before
# the 3,000th completed keep-alive.
MUTANT="$DRUSE_TMP/mutant-keepalive"
mkdir "$MUTANT"
cp "$DRUSE_ROOT/tests/wp72-concurrent-serving/keepalive/keepalive_test.odin" "$MUTANT/"
sed -i 's/limits.max_connections = 4_096/limits.max_connections = 512/' \
  "$MUTANT/keepalive_test.odin"
if run_test "$MUTANT" mutant-keepalive 30 >/dev/null 2>&1; then
  fail "512-connection mutation unexpectedly admitted 3,000 keep-alives"
fi

grep -qF 'Status. ACCEPTED — bounded multi-lane synchronous serving' \
  "$DRUSE_ROOT/planning/phase-6-concurrency.md" ||
  fail "the concurrency verdict is absent or not accepted"
grep -qF '## ADR-030 — Amendment 1' "$DRUSE_ROOT/planning/adrs.md" ||
  fail "ADR-030 has no Phase-6 amendment"

echo "wp72: Phase-5 features, 404/405, middleware and request IDs stay live with three blockers"
echo "wp72: 3,000 completed idle keep-alives drain inside the declared deadline"
echo "wp72: full saturation remains explicit and non-preemptible foreign code remains outside the promise"
echo "PASS: WP72 combined concurrency/fault/shutdown gate"
