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

# ONE SERVER PER PROCESS. `web.stop` calls `transport.request_stop()`, which
# shuts down the process-global server regardless of which App it was given, so
# a package holding a server-driving test alongside ANY test that calls `stop`
# is unsound under the parallel runner. Both such packages must be invoked
# serially, and the invocation is what has to be checked — the suites cannot
# enforce it themselves.
URUQUIM_CHECK_JOINED="$(awk '{ if (sub(/\\$/, "")) { buf = buf $0; next } print buf $0; buf = "" }' \
  "$URUQUIM_ROOT/build/check.sh")"
for URUQUIM_SERIAL_SUITE in wp58-drain; do
  URUQUIM_INVOCATION="$(grep -E "\" test \".*tests/$URUQUIM_SERIAL_SUITE\"" <<<"$URUQUIM_CHECK_JOINED" || true)"
  test -n "$URUQUIM_INVOCATION" ||
    fail "build/check.sh no longer runs tests/$URUQUIM_SERIAL_SUITE"
  grep -q 'ODIN_TEST_THREADS=1' <<<"$URUQUIM_INVOCATION" ||
    fail "tests/$URUQUIM_SERIAL_SUITE runs under the PARALLEL runner. Its sibling test calls web.stop, which shuts down the process-global server the other test is measuring — measured 3 failures in 15 runs ('expected held to be 8, got 0'), 0 in 15 when serialized. Restore -define:ODIN_TEST_THREADS=1."
done

echo "test hygiene: no suite silences the logger across its own assertions"
# NO NEW ORPHANS. A suite in the tree that no gate script runs is not coverage,
# and several were being cited as coverage anyway — the freeze ledger named
# tests/wp7_5-c2-upload as the behaviour evidence for three frozen symbols while
# nothing executed it. Eleven such suites were found; the six with a citation
# are now in build/check.sh. The five below are excluded ON PURPOSE and are
# listed here so the exclusion is a decision on record rather than an oversight:
# the four multishot suites cover machinery with no production consumer at all
# (audit T6/T7 — wiring their tests into the gate would enforce dead code), and
# g76-scale-sockets is a scale lab whose resource profile is not a gate
# property. Anything else new must be wired in or added here deliberately.
URUQUIM_ORPHAN_ALLOWED=" wp115-buf-ring wp116-multishot wp117-nbio-multishot wp118-accept-multishot g76-scale-sockets "
URUQUIM_ORPHANS=""
for URUQUIM_SUITE_DIR in "$URUQUIM_ROOT"/tests/*/ "$URUQUIM_ROOT"/tests/*/*/; do
  test -d "$URUQUIM_SUITE_DIR" || continue
  ls "$URUQUIM_SUITE_DIR"*.odin >/dev/null 2>&1 || continue
  grep -q "@(test)" "$URUQUIM_SUITE_DIR"*.odin 2>/dev/null || continue
  URUQUIM_SUITE_NAME="${URUQUIM_SUITE_DIR#"$URUQUIM_ROOT"/tests/}"
  URUQUIM_SUITE_NAME="${URUQUIM_SUITE_NAME%/}"
  case "$URUQUIM_ORPHAN_ALLOWED" in
    *" $URUQUIM_SUITE_NAME "*) continue ;;
  esac
  # Several suites are invoked through a loop variable rather than a literal
  # path — the wp69 lab subdirectories, and the previously-ungated block in
  # check.sh — so a bare-name match counts as "referenced". This asks whether
  # anyone THOUGHT about the suite, which is the question worth gating; the
  # first draft of this check matched only `tests/<name>` and reported three
  # suites its own sibling loop had just wired in.
  grep -rq "tests/$URUQUIM_SUITE_NAME" "$URUQUIM_ROOT/build" 2>/dev/null && continue
  grep -rq "tests/${URUQUIM_SUITE_NAME%%/*}" "$URUQUIM_ROOT/build" 2>/dev/null && continue
  grep -rqF "$URUQUIM_SUITE_NAME" "$URUQUIM_ROOT/build" 2>/dev/null && continue
  URUQUIM_ORPHANS="$URUQUIM_ORPHANS $URUQUIM_SUITE_NAME"
done
if test -n "$URUQUIM_ORPHANS"; then
  fail "these test suites are in the tree but no gate script runs them:$URUQUIM_ORPHANS. A suite nobody runs is not coverage — wire it into build/check.sh, or add it to URUQUIM_ORPHAN_ALLOWED here with the reason."
fi

echo "test hygiene: the server-driving suites run serially (one server per process)"
echo "test hygiene: every test suite is either gated or deliberately exempt"
echo "PASS: WP0 toolchain and repository baseline"
