#!/usr/bin/env bash
# WP69 — deterministic blocking boundary. WP70 amended drain GREEN; WP71
# promoted the measured candidate through the public, transport-neutral gate.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP69-CONTROL-FAIL: $*" >&2
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
DRUSE_TMP="$(mktemp -d -t druse-wp69-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

run_green() {
  local suite="$1"
  timeout 20 env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
    "$DRUSE_ROOT/tests/wp69-concurrency-lab/$suite" \
    "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
    "-out:$DRUSE_TMP/$suite"
}

for DRUSE_SUITE in candidate negative saturation slow-io repeatability drain; do
  run_green "$DRUSE_SUITE"
done

DRUSE_REPORT="$(timeout 20 env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" run \
  "$DRUSE_ROOT/experiments/15-blocking-boundary" \
  "-collection:druse=$DRUSE_ROOT" "-out:$DRUSE_TMP/report")"
for DRUSE_FACT in \
  "one-lane, one blocker      health_before_release=false" \
  "four lanes, three blockers health_before_release=true" \
  "four lanes, four blockers  health_before_release=false" \
  "job-pool arm                 not viable"; do
  grep -qF "$DRUSE_FACT" <<<"$DRUSE_REPORT" || fail "report drifted: $DRUSE_FACT"
done

DRUSE_MUTANT="$DRUSE_TMP/mutant"
mkdir "$DRUSE_MUTANT"
cp "$DRUSE_ROOT/tests/wp69-concurrency-lab/candidate/candidate_test.odin" "$DRUSE_MUTANT/"
sed -i 's/50970, 4/50970, 1/' "$DRUSE_MUTANT/candidate_test.odin"
if timeout 20 env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
    "$DRUSE_MUTANT" "-collection:druse=$DRUSE_ROOT" \
    -define:ODIN_TEST_THREADS=1 "-out:$DRUSE_TMP/mutant-bin" >/dev/null 2>&1; then
  fail "one-lane mutation unexpectedly preserved candidate liveness"
fi

if test -f "$DRUSE_ROOT/planning/phase-6-concurrent-serving.md"; then
  grep -qF "opts.thread_count = handler_concurrency" \
    "$DRUSE_ROOT/web/internal/transport/odin_http_adapter.odin" ||
    fail "WP71 no longer maps the measured capacity through the adapter"
  grep -qF "max_handlers:     int" \
    "$DRUSE_ROOT/web/internal/transport/boundary.odin" ||
    fail "WP71 no longer carries Handler capacity through the neutral boundary"
else
  grep -qF "opts.thread_count = 1" \
    "$DRUSE_ROOT/web/internal/transport/odin_http_adapter.odin" ||
    fail "before WP71, WP69 must not ship speculative public concurrency"
fi

echo "wp69: one lane loses health; four lanes retain it at three blocked handlers"
echo "wp69: idle/partial/slow-write I/O and repeated lifecycle controls are green"
echo "wp69: multi-lane drain is GREEN after WP70 made shutdown ownership exact-once"
echo "wp69: WP71 promotes the measured arm through a neutral Handler-capacity field"
echo "PASS: WP69 blocking-boundary controls"
