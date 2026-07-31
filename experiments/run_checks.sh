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

# COMPILE-ONLY, because this is a long-running measurement rather than a check:
# running it here would put a 20,000-request sweep inside a pre-push gate. Its
# own run.sh produces the number.
check 26-adr020-leak-shape check "ADR-020 leak shape (builds; run it via its own run.sh)"

# COMPILE-ONLY for the same reason: these are long-running stress harnesses, not
# checks. Running them here would put a fault campaign inside a pre-push gate.
#
# They were NOT IN THE REPOSITORY until 2026-07-31 -- excluded through
# `.git/info/exclude`, per-clone and unversioned -- while `tests/nbio-timeout`
# named them as the evidence path for three transport fixes in 44bdcda. Cited
# evidence nobody who cloned this could run. They had also stopped compiling,
# still importing `uruquim:web` from before the rename to Druse, which is what
# happens to code no instrument ever builds. Committed under OQ-34, and now
# built on every gate run so the next rename cannot rot them unnoticed.
check 23-accept-stall      check "accept-stall harness (builds)"
check 24-shutdown-race     check "shutdown-race harness (builds)"

# Also compile-only, and also unchecked until 2026-07-31. These five DO build
# today; that is a fact nothing was establishing, which is the point. They are
# not `run` because they are labs and arms whose output is a study rather than a
# verdict -- the studies are recorded in planning/, and re-running them here
# would put a measurement campaign in a pre-push gate.
check 11-usage-lab/a-crud-unguarded  check "usage lab A, unguarded CRUD (builds)"
check 11-usage-lab/b-crud-guarded    check "usage lab B, guarded CRUD (builds)"
check 12-concurrency-arms/consumer   check "concurrency arms consumer (builds)"
check 14-json-failure-anatomy        check "JSON failure anatomy (builds)"
check 15-blocking-boundary           check "blocking boundary (builds)"

# ---------------------------------------------------------------------------
# THE SET IS CLOSED, and it was not until 2026-07-31.
#
# Everything above is an explicit list, so an experiment added to the tree and
# not added here was checked by nothing -- the same asymmetry
# build/check_examples.sh had, one directory over. Eight packages were in that
# position and five of them did not compile.
#
# An exclusion needs a reason, for the reason exclusions always need one: an
# omission and a decision look identical from outside.
# ---------------------------------------------------------------------------
#
# 11-usage-lab/c-crud-phase3 -- a WP0-era usage prototype, written against
#   `web.state` before it gained `#optional_ok`, so it no longer compiles. Left
#   as it was ON PURPOSE: `count_concepts.sh` measured concepts-per-CRUD across
#   these three implementations, and editing the source would change the thing
#   that was measured. A frozen artefact, not live code.
DRUSE_EXP_EXEMPT="11-usage-lab/c-crud-phase3"

DRUSE_EXP_UNLISTED=""
for DRUSE_EXP_PKG in $(find "$HERE" -name '*.odin' -printf '%h\n' | sort -u); do
  DRUSE_EXP_NAME="${DRUSE_EXP_PKG#"$HERE"/}"
  test "$DRUSE_EXP_NAME" = "$DRUSE_EXP_PKG" && continue
  case "$DRUSE_EXP_NAME" in */probes) continue ;; esac
  case " $DRUSE_EXP_EXEMPT " in *" $DRUSE_EXP_NAME "*) continue ;; esac
  # A `check` line names the package; a parent-directory line covers a package
  # reached through a subdirectory argument.
  grep -q "^check $DRUSE_EXP_NAME[[:space:]]" "$HERE/run_checks.sh" && continue
  grep -q "^check ${DRUSE_EXP_NAME%%/*}[[:space:]]" "$HERE/run_checks.sh" && continue
  DRUSE_EXP_UNLISTED="$DRUSE_EXP_UNLISTED $DRUSE_EXP_NAME"
done
if test -n "$DRUSE_EXP_UNLISTED"; then
  echo "FAIL: these experiment packages are in the tree but nothing checks them:$DRUSE_EXP_UNLISTED"
  echo "      Add a 'check' line above, or add it to DRUSE_EXP_EXEMPT with the reason."
  echo "      An unchecked experiment is code that stops compiling and nobody finds out."
  FAIL=$((FAIL+1))
else
  echo "PASS: every experiment package is checked or exempt on the record"
fi

echo "============================================"
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ $FAIL -eq 0 ] || exit 1
