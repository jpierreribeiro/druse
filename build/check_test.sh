#!/usr/bin/env bash
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_EXPECTED_COMMIT="819fdc7"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

test -f "$URUQUIM_ROOT/odin-version.txt" || fail "odin-version.txt is missing"
grep -qx "release=dev-2026-07a" "$URUQUIM_ROOT/odin-version.txt" ||
  fail "release pin is missing"
grep -qx "commit=$URUQUIM_EXPECTED_COMMIT" "$URUQUIM_ROOT/odin-version.txt" ||
  fail "commit pin is missing"
grep -qx "linux_amd64_sha256=32a7678abc66f1af7353abb5b0b5da47d94b7e663f6d250df29bc9117e864c10" \
  "$URUQUIM_ROOT/odin-version.txt" || fail "release digest pin is missing"

test -f "$URUQUIM_ROOT/build/check.sh" || fail "build/check.sh is missing"
test -x "$URUQUIM_ROOT/.githooks/pre-push" || fail "pre-push hook is missing or not executable"
test -f "$URUQUIM_ROOT/build/install-hooks.sh" || fail "hook installer is missing"
test ! -f "$URUQUIM_ROOT/.github/workflows/ci.yml" ||
  fail "GitHub Actions workflow must not be an active gate"

for URUQUIM_CI_FILE in run.sh status.sh install-odin.sh; do
  test -f "$URUQUIM_ROOT/ops/ci/$URUQUIM_CI_FILE" ||
    fail "missing VPS verifier file: ops/ci/$URUQUIM_CI_FILE"
  bash -n "$URUQUIM_ROOT/ops/ci/$URUQUIM_CI_FILE"
done
grep -Fq 'cd "$URUQUIM_CI_WORK"' "$URUQUIM_ROOT/ops/ci/run.sh" ||
  fail "VPS verifier does not compile from its clean writable archive"

URUQUIM_REAL_OUTPUT="$(URUQUIM_ODIN_BIN="${URUQUIM_ODIN_BIN:-}" \
  bash "$URUQUIM_ROOT/.githooks/pre-push")" ||
  fail "pre-push gate rejected the pinned toolchain"
grep -q "toolchain commit: $URUQUIM_EXPECTED_COMMIT" <<<"$URUQUIM_REAL_OUTPUT" ||
  fail "check output did not report the pinned commit"
grep -q "PASS=10 FAIL=0 SKIP=0" <<<"$URUQUIM_REAL_OUTPUT" ||
  fail "check output did not report all prototype passes"

if ! ODIN_ROOT=/tmp/uruquim-invalid-ambient-odin-root \
  URUQUIM_ODIN_BIN="${URUQUIM_ODIN_BIN:-/tmp/uruquim-odin-toolchain/odin}" \
  bash "$URUQUIM_ROOT/build/check.sh" >/dev/null 2>&1; then
  fail "build/check.sh did not sanitize ambient ODIN_ROOT"
fi

if URUQUIM_ODIN_BIN="/bin/echo" \
  bash "$URUQUIM_ROOT/build/check.sh" >/dev/null 2>&1; then
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
URUQUIM_DEFERRED_SILENCE="$(grep -rn 'defer context\.logger = ' \
  "$URUQUIM_ROOT/tests" --include='*.odin' || true)"
if test -n "$URUQUIM_DEFERRED_SILENCE"; then
  echo "$URUQUIM_DEFERRED_SILENCE" >&2
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
URUQUIM_BLIND_FILTER="$(grep -rn -A 2 'if level == .Error {' \
  "$URUQUIM_ROOT/tests" --include='*.odin' | grep -c 'return' || true)"
if test "$URUQUIM_BLIND_FILTER" -gt 0; then
  fail "a test logger filter drops EVERY .Error record. That includes core:testing's own assertion failures, so the suite is green whatever it asserts (this is what tests/wp9-wire did). Filter by origin or by message marker, never by level alone."
fi

echo "test hygiene: no suite silences the logger across its own assertions"
echo "PASS: WP0 toolchain and repository baseline"
