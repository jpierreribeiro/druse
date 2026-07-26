#!/usr/bin/env bash
# WP71 — bounded, transport-neutral synchronous Handler concurrency.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP71-CONTROL-FAIL: $*" >&2
  exit 1
}

if test -n "${URUQUIM_COMPILER:-}"; then
  URUQUIM_ODIN="$URUQUIM_COMPILER"
elif test -n "${URUQUIM_ODIN_BIN:-}"; then
  URUQUIM_ODIN="$URUQUIM_ODIN_BIN"
elif command -v odin >/dev/null 2>&1; then
  URUQUIM_ODIN="$(command -v odin)"
elif test -x /tmp/uruquim-odin-toolchain/odin; then
  URUQUIM_ODIN=/tmp/uruquim-odin-toolchain/odin
else
  fail "odin compiler not found"
fi

URUQUIM_ODIN="$(readlink -f "$URUQUIM_ODIN")"
URUQUIM_ODIN_ROOT="$(cd "$(dirname "$URUQUIM_ODIN")" && pwd)"
URUQUIM_TMP="$(mktemp -d -t uruquim-wp71-controls-XXXXXXXX)"
trap 'rm -rf "$URUQUIM_TMP"' EXIT

run_test() { # package, collection, binary
  timeout 25 env ODIN_ROOT="$URUQUIM_ODIN_ROOT" "$URUQUIM_ODIN" test "$1" \
    "-collection:uruquim=$2" -define:ODIN_TEST_THREADS=1 \
    -define:URUQUIM_DEDICATED_ACCEPT=true \
    "-out:$URUQUIM_TMP/$3"
}

run_test "$URUQUIM_ROOT/tests/wp71-concurrent-serving/validation" "$URUQUIM_ROOT" validation
run_test "$URUQUIM_ROOT/tests/wp71-concurrent-serving/auto" "$URUQUIM_ROOT" auto
run_test "$URUQUIM_ROOT/tests/wp71-concurrent-serving/one" "$URUQUIM_ROOT" one
run_test "$URUQUIM_ROOT/tests/wp71-concurrent-serving/vendor_suspend" "$URUQUIM_ROOT" vendor-suspend
run_test "$URUQUIM_ROOT/tests/wp71-concurrent-serving/admission" "$URUQUIM_ROOT" admission

# Private adapter policy is tested in a throwaway package containing the exact
# shipped transport sources; no private helper is widened for the test.
URUQUIM_TRANSPORT="$URUQUIM_TMP/transport"
mkdir "$URUQUIM_TRANSPORT"
cp "$URUQUIM_ROOT"/web/internal/transport/*.odin "$URUQUIM_TRANSPORT/"
cp "$URUQUIM_ROOT/tests/wp71-concurrent-serving/adapter_internal_test.odin" "$URUQUIM_TRANSPORT/"
run_test "$URUQUIM_TRANSPORT" "$URUQUIM_ROOT" adapter-policy

make_mutant_collection() { # destination
  local destination="$1"
  mkdir -p "$destination/tests/support"
  cp -R "$URUQUIM_ROOT/web" "$destination/web"
  mkdir "$destination/vendor"
  cp -R "$URUQUIM_ROOT/vendor/odin-http" "$destination/vendor/odin-http"
  cp -R "$URUQUIM_ROOT/tests/support/web_blocking_lab" "$destination/tests/support/web_blocking_lab"
  cp -R "$URUQUIM_ROOT/tests/support/blocking_lab" "$destination/tests/support/blocking_lab"
}

# Control 1: automatic capacity is behavioural, not a constant asserted only
# by a private test. Collapsing auto to one lane must lose health liveness.
AUTO_MUTANT="$URUQUIM_TMP/mutant-auto"
make_mutant_collection "$AUTO_MUTANT"
sed -i 's/AUTO_HANDLER_CONCURRENCY_MIN :: 4/AUTO_HANDLER_CONCURRENCY_MIN :: 1/; s/AUTO_HANDLER_CONCURRENCY_MAX :: 32/AUTO_HANDLER_CONCURRENCY_MAX :: 1/' \
  "$AUTO_MUTANT/web/internal/transport/odin_http_adapter.odin"
if run_test "$URUQUIM_ROOT/tests/wp71-concurrent-serving/auto" "$AUTO_MUTANT" mutant-auto \
    >/dev/null 2>&1; then
  fail "automatic-capacity mutation unexpectedly passed"
fi

# Control 2: 256 is a real fail-before-listen ceiling. Relaxing it must make
# the public validation corpus reject the mutant.
LIMIT_MUTANT="$URUQUIM_TMP/mutant-limit"
make_mutant_collection "$LIMIT_MUTANT"
sed -i 's/MAX_HANDLER_CONCURRENCY :: 256/MAX_HANDLER_CONCURRENCY :: 512/' \
  "$LIMIT_MUTANT/web/limits.odin"
if run_test "$URUQUIM_ROOT/tests/wp71-concurrent-serving/validation" "$LIMIT_MUTANT" mutant-limit \
    >/dev/null 2>&1; then
  fail "maximum-capacity mutation unexpectedly passed"
fi

# Control 3: the dedicated acceptor must distribute new connections across
# available lanes. Pinning every handoff to lane zero makes the second blocker
# wait behind the first and the behavioural corpus catches it.
SUSPEND_MUTANT="$URUQUIM_TMP/mutant-suspend"
make_mutant_collection "$SUSPEND_MUTANT"
sed -i 's/i := (s.next_lane + offset) % n/i := 0/' \
  "$SUSPEND_MUTANT/vendor/odin-http/server.odin"
if run_test "$URUQUIM_ROOT/tests/wp71-concurrent-serving/auto" "$SUSPEND_MUTANT" mutant-suspend \
    >/dev/null 2>&1; then
  fail "single-lane dedicated-accept mutation unexpectedly passed"
fi

# Control 4: `max_connections` is one server budget, not one budget per lane.
# Reinstating the pre-WP71 lane-local comparison must serve the fifth client
# and fail the reservation assertion.
ADMISSION_MUTANT="$URUQUIM_TMP/mutant-admission"
make_mutant_collection "$ADMISSION_MUTANT"
sed -i 's/if active_connections > budget {/if len(td.conns) >= budget {/' \
  "$ADMISSION_MUTANT/vendor/odin-http/server.odin"
if run_test "$URUQUIM_ROOT/tests/wp71-concurrent-serving/admission" "$ADMISSION_MUTANT" mutant-admission \
    >/dev/null 2>&1; then
  fail "lane-local admission mutation unexpectedly passed"
fi

grep -qF 'max_handlers:     int' "$URUQUIM_ROOT/web/internal/transport/boundary.odin" ||
  fail "Handler capacity does not cross the neutral transport boundary"
grep -qF 'This names application capacity, never backend threads or event loops.' \
  "$URUQUIM_ROOT/web/limits.odin" ||
  fail "public capacity contract does not state its transport-neutral meaning"
grep -qF 'URUQUIM_DEDICATED_ACCEPT :: #config(URUQUIM_DEDICATED_ACCEPT, true)' \
  "$URUQUIM_ROOT/vendor/odin-http/server.odin" ||
  fail "the measured dedicated-accept path must remain the adopted default"

echo "wp71: automatic capacity and explicit four-lane liveness are green"
echo "wp71: explicit one-lane saturation and recovery are green"
echo "wp71: one dedicated acceptor keeps accepts off blocked Handler lanes"
echo "wp71: max_connections remains one server-wide budget across lanes"
echo "wp71: dedicated accept is the adopted default; the old path remains a build-time rollback"
echo "PASS: WP71 bounded Handler-concurrency controls"
