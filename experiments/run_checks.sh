#!/usr/bin/env bash
# Verification-only runner for the throwaway prototypes.
# It NEVER modifies sources. It only runs `odin check` / `odin run` / `odin test`
# on the pinned toolchain and reports pass/fail per experiment.
#
# Baseline note: in the authoring environment the pinned Odin toolchain
# (dev-2026-07a) was unreachable (GitHub egress blocked by policy), so every
# experiment below is currently NOT_EXECUTED. Run this where `odin` is on PATH
# and points at dev-2026-07a to produce real evidence.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
COLL="-collection:druse=$ROOT"
PASS=0; FAIL=0; SKIP=0

need_odin() {
  if ! command -v odin >/dev/null 2>&1; then
    echo "SKIP: 'odin' not found on PATH (baseline: toolchain unavailable)."
    echo "      Install the version pinned in odin-version.txt and re-run."
    exit 3
  fi
  echo "odin version: $(odin version 2>&1)"
}

check() { # dir mode label
  local dir="$1" mode="$2" label="$3"
  echo "--- $label ($mode) ---"
  case "$mode" in
    check) odin check "$HERE/$dir" $COLL ;;
    run)   odin run   "$HERE/$dir" $COLL ;;
    test)  odin test  "$HERE/$dir" $COLL ;;
  esac
  local rc=$?
  if [ $rc -eq 0 ]; then echo "PASS: $label"; PASS=$((PASS+1)); else echo "FAIL($rc): $label"; FAIL=$((FAIL+1)); fi
}

need_odin
check 01-api-shape            run  "api-shape"
check 02-generic-json-response run "generic-json-response"
check 03-body-binding         run  "body-binding"
check 04-optional-ok          run  "optional-ok"
check 05-typed-state          run  "typed-state"
check 06-request-views        run  "request-views"
check 07-middleware-chain     run  "middleware-chain"
check 08-transport-boundary   run  "transport-boundary"
check 09-test-transport       test "test-transport"
check 10-handler-errors       test "handler-errors"
check 25-marshal-parity       run  "marshal-parity"

echo "--- optional-ok plain-result discard probe (expected compile failure) ---"
DRUSE_OPTIONAL_OUTPUT="$(odin check "$HERE/04-optional-ok/probes/plain_discard.odin" -file $COLL 2>&1)"
DRUSE_OPTIONAL_EXIT=$?
if test "$DRUSE_OPTIONAL_EXIT" -ne 0 && \
   grep -q "Assignment count mismatch" <<<"$DRUSE_OPTIONAL_OUTPUT"; then
  echo "PASS: plain extractor forces capture of ok"
else
  echo "$DRUSE_OPTIONAL_OUTPUT"
  echo "FAIL: plain extractor discard diagnostic changed"
  FAIL=$((FAIL+1))
fi

echo "--- handler-errors ignored-result probe (expected compile success) ---"
if odin check "$HERE/10-handler-errors/probes/ignored_results.odin" -file $COLL; then
  echo "PASS: returned handler errors can be ignored (risk confirmed)"
else
  echo "FAIL: ignored-result probe no longer compiles"
  FAIL=$((FAIL+1))
fi

echo "--- handler-errors bare-return probe (expected compile failure) ---"
DRUSE_PROBE_OUTPUT="$(odin check "$HERE/10-handler-errors/probes/bare_return.odin" -file $COLL 2>&1)"
DRUSE_PROBE_EXIT=$?
if test "$DRUSE_PROBE_EXIT" -ne 0 && \
   grep -q "Expected 1 return values, got 0" <<<"$DRUSE_PROBE_OUTPUT"; then
  echo "PASS: bare return rejected with expected diagnostic"
else
  echo "$DRUSE_PROBE_OUTPUT"
  echo "FAIL: bare-return diagnostic changed"
  FAIL=$((FAIL+1))
fi

check 16-stream-topology/candidate-b test "stream topology candidate B (lane-polled producer)"
check 16-stream-topology/candidate-c test "stream topology candidate C (detached token stream)"
check 16-stream-topology/candidate-d test "stream topology candidate D (SSE-specific API)"
check 17-ingest-arms                 test "large-body ingest arms E/F/G/H"

echo "============================================"
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ $FAIL -eq 0 ] || exit 1
