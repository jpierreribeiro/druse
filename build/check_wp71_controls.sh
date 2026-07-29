#!/usr/bin/env bash
# WP71 — bounded, transport-neutral synchronous Handler concurrency.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP71-CONTROL-FAIL: $*" >&2
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
DRUSE_TMP="$(mktemp -d -t druse-wp71-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

run_test() { # package, collection, binary
  timeout 25 env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test "$1" \
    "-collection:druse=$2" -define:ODIN_TEST_THREADS=1 \
    -define:DRUSE_DEDICATED_ACCEPT=true \
    "-out:$DRUSE_TMP/$3"
}

run_test "$DRUSE_ROOT/tests/wp71-concurrent-serving/validation" "$DRUSE_ROOT" validation
run_test "$DRUSE_ROOT/tests/wp71-concurrent-serving/auto" "$DRUSE_ROOT" auto
run_test "$DRUSE_ROOT/tests/wp71-concurrent-serving/one" "$DRUSE_ROOT" one
run_test "$DRUSE_ROOT/tests/wp71-concurrent-serving/vendor_suspend" "$DRUSE_ROOT" vendor-suspend
run_test "$DRUSE_ROOT/tests/wp71-concurrent-serving/admission" "$DRUSE_ROOT" admission

# Private adapter policy is tested in a throwaway package containing the exact
# shipped transport sources; no private helper is widened for the test.
DRUSE_TRANSPORT="$DRUSE_TMP/transport"
mkdir "$DRUSE_TRANSPORT"
cp "$DRUSE_ROOT"/web/internal/transport/*.odin "$DRUSE_TRANSPORT/"
cp "$DRUSE_ROOT/tests/wp71-concurrent-serving/adapter_internal_test.odin" "$DRUSE_TRANSPORT/"
run_test "$DRUSE_TRANSPORT" "$DRUSE_ROOT" adapter-policy

make_mutant_collection() { # destination
  local destination="$1"
  mkdir -p "$destination/tests/support"
  cp -R "$DRUSE_ROOT/web" "$destination/web"
  mkdir "$destination/vendor"
  cp -R "$DRUSE_ROOT/vendor/odin-http" "$destination/vendor/odin-http"
  cp -R "$DRUSE_ROOT/tests/support/web_blocking_lab" "$destination/tests/support/web_blocking_lab"
  cp -R "$DRUSE_ROOT/tests/support/blocking_lab" "$destination/tests/support/blocking_lab"
}

# Control 1: automatic capacity is behavioural, not a constant asserted only
# by a private test. Collapsing auto to one lane must lose health liveness.
AUTO_MUTANT="$DRUSE_TMP/mutant-auto"
make_mutant_collection "$AUTO_MUTANT"
sed -i 's/AUTO_HANDLER_CONCURRENCY_MIN :: 4/AUTO_HANDLER_CONCURRENCY_MIN :: 1/; s/AUTO_HANDLER_CONCURRENCY_MAX :: 32/AUTO_HANDLER_CONCURRENCY_MAX :: 1/' \
  "$AUTO_MUTANT/web/internal/transport/odin_http_adapter.odin"
if run_test "$DRUSE_ROOT/tests/wp71-concurrent-serving/auto" "$AUTO_MUTANT" mutant-auto \
    >/dev/null 2>&1; then
  fail "automatic-capacity mutation unexpectedly passed"
fi

# Control 2: 256 is a real fail-before-listen ceiling. Relaxing it must make
# the public validation corpus reject the mutant.
LIMIT_MUTANT="$DRUSE_TMP/mutant-limit"
make_mutant_collection "$LIMIT_MUTANT"
sed -i 's/MAX_HANDLER_CONCURRENCY :: 256/MAX_HANDLER_CONCURRENCY :: 512/' \
  "$LIMIT_MUTANT/web/limits.odin"
if run_test "$DRUSE_ROOT/tests/wp71-concurrent-serving/validation" "$LIMIT_MUTANT" mutant-limit \
    >/dev/null 2>&1; then
  fail "maximum-capacity mutation unexpectedly passed"
fi

# Control 3: the dedicated acceptor must distribute new connections across
# available lanes. Pinning every handoff to lane zero makes the second blocker
# wait behind the first and the behavioural corpus catches it.
SUSPEND_MUTANT="$DRUSE_TMP/mutant-suspend"
make_mutant_collection "$SUSPEND_MUTANT"
sed -i 's/i := (s.next_lane + offset) % n/i := 0/' \
  "$SUSPEND_MUTANT/vendor/odin-http/server.odin"
if run_test "$DRUSE_ROOT/tests/wp71-concurrent-serving/auto" "$SUSPEND_MUTANT" mutant-suspend \
    >/dev/null 2>&1; then
  fail "single-lane dedicated-accept mutation unexpectedly passed"
fi

# Control 4: `max_connections` is one server budget, not one budget per lane.
# Reinstating the pre-WP71 lane-local comparison must serve the fifth client
# and fail the reservation assertion.
ADMISSION_MUTANT="$DRUSE_TMP/mutant-admission"
make_mutant_collection "$ADMISSION_MUTANT"
sed -i 's/if active_connections > budget {/if len(td.conns) >= budget {/' \
  "$ADMISSION_MUTANT/vendor/odin-http/server.odin"
if run_test "$DRUSE_ROOT/tests/wp71-concurrent-serving/admission" "$ADMISSION_MUTANT" mutant-admission \
    >/dev/null 2>&1; then
  fail "lane-local admission mutation unexpectedly passed"
fi

grep -qF 'max_handlers:     int' "$DRUSE_ROOT/web/internal/transport/boundary.odin" ||
  fail "Handler capacity does not cross the neutral transport boundary"
grep -qF 'This names application capacity, never backend threads or event loops.' \
  "$DRUSE_ROOT/web/limits.odin" ||
  fail "public capacity contract does not state its transport-neutral meaning"
grep -qF 'DRUSE_DEDICATED_ACCEPT :: #config(DRUSE_DEDICATED_ACCEPT, true)' \
  "$DRUSE_ROOT/vendor/odin-http/server.odin" ||
  fail "the measured dedicated-accept path must remain the adopted default"

echo "wp71: automatic capacity and explicit four-lane liveness are green"
echo "wp71: explicit one-lane saturation and recovery are green"
echo "wp71: one dedicated acceptor keeps accepts off blocked Handler lanes"
echo "wp71: max_connections remains one server-wide budget across lanes"
echo "wp71: dedicated accept is the adopted default; the old path remains a build-time rollback"
echo "PASS: WP71 bounded Handler-concurrency controls"
