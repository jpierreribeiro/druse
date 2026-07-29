#!/usr/bin/env bash
# C-08 — the httprouter comparative study, under control.
#
# Four executable claims:
#
#   1. THE LICENCE NOTICE SURVIVES. httprouter is BSD 3-Clause; adapting its test
#      cases obliges us to reproduce the copyright notice, the three conditions
#      and the disclaimer. A gate is the only thing that keeps an attribution
#      from being tidied away;
#   2. the three DELIBERATE DIFFERENCES are each still pinned by a named test.
#      This corpus exists to prove every difference is intentional; losing one of
#      those tests would silently permit a regression TOWARD httprouter's
#      semantics, which is the one outcome the study must prevent;
#   3. zero public API change — C-08 is non-blocking by construction, and a
#      research package that grew the surface would not be;
#   4. the corpus is green.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_CORPUS="$DRUSE_ROOT/tests/c08-router-corpus/external_corpus_test.odin"
DRUSE_DOC="$DRUSE_ROOT/planning/closure-httprouter-study.md"

fail() {
  echo "C08-CONTROL-FAIL: $*" >&2
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
DRUSE_TMP="$(mktemp -d -t druse-c08-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

test -f "$DRUSE_CORPUS" || fail "tests/c08-router-corpus/external_corpus_test.odin is missing"
test -f "$DRUSE_DOC" || fail "planning/closure-httprouter-study.md is missing"

# --- 1. The BSD-3 attribution ------------------------------------------------
for DRUSE_CLAUSE in \
  'Copyright (c) 2013 Julien Schmidt' \
  'Redistributions of source code must retain the above copyright notice' \
  'Redistributions in binary form must reproduce the above copyright notice' \
  'may not be used to endorse or promote' \
  'THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS'; do
  grep -qF "$DRUSE_CLAUSE" "$DRUSE_CORPUS" ||
    fail "the BSD-3 notice lost: '$DRUSE_CLAUSE'. Adapting httprouter's test cases obliges us to reproduce the notice, the conditions and the disclaimer; a gate is the only thing that stops an attribution being tidied away."
done

# --- 2. The three deliberate differences stay pinned -------------------------
for DRUSE_CASE in \
  c08_static_wins_but_the_router_backtracks_to_the_parameter \
  c08_a_trailing_slash_is_a_different_path_and_is_never_redirected \
  c08_case_is_significant_and_is_never_fixed \
  c08_dot_segments_and_empty_segments_are_rejected_before_routing \
  c08_there_is_no_catch_all_wildcard \
  c08_two_differently_named_parameters_in_one_position_are_refused; do
  grep -q "^$DRUSE_CASE ::" "$DRUSE_CORPUS" ||
    fail "$(printf 'the negative-corpus case %s is gone.\nEach of these pins a DELIBERATE difference from httprouter (backtracking precedence, no path correction, no catch-all, fail-closed conflicts). Losing one silently permits a regression toward httprouter semantics, which is the single outcome this study exists to prevent.' "$DRUSE_CASE")"
done

# --- 3. No public API change -------------------------------------------------
# The corpus may only use symbols the public surface already had. `web.` calls
# in it are checked against the ratified ledger by check_public_api.sh; here we
# assert the study minted nothing of its own.
if grep -qE '^\s*(web_|druse_)' "$DRUSE_CORPUS"; then
  fail "the corpus appears to declare framework symbols; C-08 is non-blocking BY CONSTRUCTION and must change no public surface"
fi
grep -qi 'zero public API change' "$DRUSE_DOC" ||
  fail "the study record no longer states its zero-public-API-change constraint"

# --- 4. Green ----------------------------------------------------------------
env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
  "$DRUSE_ROOT/tests/c08-router-corpus" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$DRUSE_TMP/c08"

echo "c08: the BSD-3 notice, conditions and disclaimer are intact"
echo "c08: all six negative-corpus cases pin their deliberate difference"
echo "c08: zero public API change"
echo "PASS: C-08 httprouter comparative corpus controls"
