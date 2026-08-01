#!/usr/bin/env bash
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_EXPECTED_COMMIT="819fdc7"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

test -f "$DRUSE_ROOT/odin-version.txt" || fail "odin-version.txt is missing"
grep -qx "release=dev-2026-07a" "$DRUSE_ROOT/odin-version.txt" ||
  fail "release pin is missing"
grep -qx "commit=$DRUSE_EXPECTED_COMMIT" "$DRUSE_ROOT/odin-version.txt" ||
  fail "commit pin is missing"
grep -qx "linux_amd64_sha256=32a7678abc66f1af7353abb5b0b5da47d94b7e663f6d250df29bc9117e864c10" \
  "$DRUSE_ROOT/odin-version.txt" || fail "release digest pin is missing"

test -f "$DRUSE_ROOT/build/check.sh" || fail "build/check.sh is missing"
test -x "$DRUSE_ROOT/.githooks/pre-push" || fail "pre-push hook is missing or not executable"
test -f "$DRUSE_ROOT/build/install-hooks.sh" || fail "hook installer is missing"
test ! -f "$DRUSE_ROOT/.github/workflows/ci.yml" ||
  fail "GitHub Actions workflow must not be an active gate"

for DRUSE_CI_FILE in run.sh status.sh install-odin.sh; do
  test -f "$DRUSE_ROOT/ops/ci/$DRUSE_CI_FILE" ||
    fail "missing VPS verifier file: ops/ci/$DRUSE_CI_FILE"
  bash -n "$DRUSE_ROOT/ops/ci/$DRUSE_CI_FILE"
done
grep -Fq 'cd "$DRUSE_CI_WORK"' "$DRUSE_ROOT/ops/ci/run.sh" ||
  fail "VPS verifier does not compile from its clean writable archive"

DRUSE_REAL_OUTPUT="$(DRUSE_ODIN_BIN="${DRUSE_ODIN_BIN:-}" \
  bash "$DRUSE_ROOT/.githooks/pre-push")" ||
  fail "pre-push gate rejected the pinned toolchain"
grep -q "toolchain commit: $DRUSE_EXPECTED_COMMIT" <<<"$DRUSE_REAL_OUTPUT" ||
  fail "check output did not report the pinned commit"
# A PINNED COUNT ROTS, and this line is the proof: it read `PASS=10` while the
# tree had produced `PASS=15` for a long time, so it would have failed on any
# run -- and it never ran, because nothing executed this file (see the header
# note on build/check_gate_inventory.sh). It is the fifth instance of the
# failure check.sh already records: "FOUR were broken, and had been for as long
# as nobody had looked."
#
# So the assertion stops pinning a number it cannot maintain and asserts the
# property it actually wanted: the prototypes ran, and none of them failed.
# `experiments/run_checks.sh` now closes its own set, so "how many" is its
# question to answer, not this file's.
grep -qE "PASS=[0-9]+ FAIL=0 SKIP=0" <<<"$DRUSE_REAL_OUTPUT" ||
  fail "check output did not report a clean prototype sweep (expected PASS=<n> FAIL=0 SKIP=0)"
grep -q "PASS=0 FAIL=0 SKIP=0" <<<"$DRUSE_REAL_OUTPUT" &&
  fail "the prototype sweep reported zero passes; run_checks.sh ran nothing, which is not the same as everything passing"

if ! ODIN_ROOT=/tmp/druse-invalid-ambient-odin-root \
  DRUSE_ODIN_BIN="${DRUSE_ODIN_BIN:-/tmp/druse-toolchain/odin}" \
  bash "$DRUSE_ROOT/build/check.sh" >/dev/null 2>&1; then
  fail "build/check.sh did not sanitize ambient ODIN_ROOT"
fi

if DRUSE_ODIN_BIN="/bin/echo" \
  bash "$DRUSE_ROOT/build/check.sh" >/dev/null 2>&1; then
  fail "build/check.sh accepted a divergent compiler"
fi

# ---------------------------------------------------------------------------
# A TEST SUITE MUST BE ABLE TO FAIL.
#
# `testing.expect`, `expectf` and `expect_value` report a failure by calling
# `log.errorf` through `context.logger` (core/testing/testing.odin). A suite
# that installs a logger which discards those records is green no matter what
# it asserts. TWO suites shipped that way and both were found only by asking
# the question directly:
#
#   tests/wp9-wire            dropped every `.Error` record. A case demanding
#                             status 999 passed. Decorative since the commit
#                             that created it.
#   tests/wp67-.../internal   set `context.logger = {}` with a DEFERRED restore,
#                             so the nil logger covered all three assertions.
#
# Two shapes, one rule: silencing the logger is legitimate ONLY around the call
# whose diagnostic is expected, and it must be restored before anything is
# asserted. A deferred restore always spans the assertions, so it is banned
# outright — the narrow form is just as easy to write.
DRUSE_DEFERRED_SILENCE="$(grep -rn 'defer context\.logger = ' \
  "$DRUSE_ROOT/tests" --include='*.odin' || true)"
if test -n "$DRUSE_DEFERRED_SILENCE"; then
  echo "$DRUSE_DEFERRED_SILENCE" >&2
  fail "$(cat <<'EOF'
a test defers its context.logger restore. That keeps the substituted logger
installed for the REST OF THE TEST, including every assertion after it, and
`testing.expect*` reports failures THROUGH that logger — so the suite cannot
fail. Restore it immediately after the call whose diagnostic is being
suppressed, not at proc exit.
EOF
)"
fi

# The unconditional form of the same defect: a filter that drops every Error
# record rather than only the framework's own.
DRUSE_BLIND_FILTER="$(grep -rn -A 2 'if level == .Error {' \
  "$DRUSE_ROOT/tests" --include='*.odin' | grep -c 'return' || true)"
if test "$DRUSE_BLIND_FILTER" -gt 0; then
  fail "a test logger filter drops EVERY .Error record. That includes core:testing's own assertion failures, so the suite is green whatever it asserts (this is what tests/wp9-wire did). Filter by origin or by message marker, never by level alone."
fi

# A STOP REACHES ONLY ITS OWN SERVER (WP123 / ADR-018), and this check is the
# INVERSE of the one it replaces.
#
# It used to require that `tests/wp58-drain` run with
# `-define:ODIN_TEST_THREADS=1`, because `web.stop` shut down the process-global
# server regardless of which App it was handed: a sibling test's stop killed the
# server the other test was measuring. Measured then: 3 failures in 15 parallel
# runs ("expected held to be 8, got 0"), 0 in 15 serialized.
#
# WP123 removed the shared slot — `web.stop(&app)` now names one server — so the
# requirement is not merely obsolete, it is BACKWARDS: leaving it in place would
# make the codebase defend the defect's workaround. Re-measured on the same
# suite after the change: 15 parallel runs, 15 green, 0 failures.
#
# What replaces it is the claim that made the deletion legal. The suite must run
# PARALLEL, so that a stop reaching the wrong server shows up here instead of
# being hidden by serialization — the workaround, restored, would silence the
# very regression this now catches.
DRUSE_CHECK_JOINED="$(awk '{ if (sub(/\\$/, "")) { buf = buf $0; next } print buf $0; buf = "" }' \
  "$DRUSE_ROOT/build/check.sh")"
for DRUSE_PARALLEL_SUITE in wp58-drain wp123-two-servers; do
  DRUSE_INVOCATION="$(grep -E "\" test \".*tests/$DRUSE_PARALLEL_SUITE\"" <<<"$DRUSE_CHECK_JOINED" || true)"
  test -n "$DRUSE_INVOCATION" ||
    fail "build/check.sh no longer runs tests/$DRUSE_PARALLEL_SUITE"
  grep -q 'ODIN_TEST_THREADS=1' <<<"$DRUSE_INVOCATION" &&
    fail "tests/$DRUSE_PARALLEL_SUITE was serialized with -define:ODIN_TEST_THREADS=1. Since WP123 a stop reaches only the server its App started, and running these suites in PARALLEL is what proves it — serializing them hides exactly the regression they exist to catch. If they became flaky, the fault is in the per-server state, not in the runner."
done

echo "test hygiene: no suite silences the logger across its own assertions"
# NO NEW ORPHANS — the rule moved out of this file, and that move is the point.
#
# This detector was written here, and this file is a META-TEST OF THE GATE: it
# invokes .githooks/pre-push and build/check.sh several times over, so check.sh
# can only ever `bash -n` it — calling it from there would recurse. The
# exclusion is correct. Its consequence was not: a detector built to catch
# "suites nobody runs" was itself a script nobody ran, on every push for months,
# and therefore could not detect its own case. tests/nbio-timeout sat in the
# tree with three @(test) procedures, executed by nothing.
#
# So it lives in build/check_suite_inventory.sh now, which build/check.sh runs.
# This file delegates rather than keeping a second copy: two copies of a rule is
# how the two drift apart (R-14 — one canonical path, not two).
bash "$DRUSE_ROOT/build/check_suite_inventory.sh" "$DRUSE_ROOT"

echo "test hygiene: the server-driving suites run serially (one server per process)"
echo "PASS: WP0 toolchain and repository baseline"
