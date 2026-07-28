#!/usr/bin/env bash
# C-04 — response size and memory retention, under control.
#
# Four executable claims:
#
#   1. the two-phase shape is intact — the suite must serve BIG responses and
#      then MANY SMALL ones on the SAME connections. Collapse it to one phase
#      and it can no longer tell retention (expected, an arena) from a leak (a
#      defect); the number it printed would then mean nothing;
#   2. the baseline is honest — the client's scratch buffer is touched before
#      RSS is first read. Without that, ~4 MiB of the CLIENT's memory is
#      reported as the framework's retention, which is how the first version of
#      this suite got 0.88x instead of 1.01x;
#   3. the decision and its sizing rule survive in the record — a delegation is
#      only acceptable while it is documented, and the number is what makes it
#      documentable;
#   4. the suite is green.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_DOC="$URUQUIM_ROOT/planning/closure-response-size-and-memory.md"
URUQUIM_SUITE="$URUQUIM_ROOT/tests/c04-response-size/soak_test.odin"

fail() {
  echo "C04-CONTROL-FAIL: $*" >&2
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
URUQUIM_TMP="$(mktemp -d -t uruquim-c04-controls-XXXXXXXX)"
trap 'rm -rf "$URUQUIM_TMP"' EXIT

test -f "$URUQUIM_DOC" || fail "planning/closure-response-size-and-memory.md is missing; it carries the delegation decision and the sizing rule"
test -f "$URUQUIM_SUITE" || fail "tests/c04-response-size/soak_test.odin is missing"

# --- 1. The two-phase shape --------------------------------------------------
grep -q 'SMALL_ROUNDS :: [0-9]' "$URUQUIM_SUITE" ||
  fail "the suite lost its small-response phase; with only the big phase it reports a number that cannot distinguish retention from a leak"
grep -q 'after_small := rss_bytes()' "$URUQUIM_SUITE" ||
  fail "the suite no longer reads RSS after the small-response phase — the leak half of the measurement is gone"
grep -q 'after_big := rss_bytes()' "$URUQUIM_SUITE" ||
  fail "the suite no longer reads RSS after the big-response phase — the retention half of the measurement is gone"
grep -q 'grew < LEAK_THRESHOLD_BYTES' "$URUQUIM_SUITE" ||
  fail "the leak assertion is gone; the suite would then print numbers and assert nothing"

# --- 2. The baseline is honest -----------------------------------------------
grep -q 'scratch\[i\] = u8(i)' "$URUQUIM_SUITE" || fail "$(cat <<'EOF'
the client scratch buffer is no longer touched before the baseline RSS reading.
RSS counts resident pages, not reservations, so an untouched buffer becomes
resident during phase 1 and is charged to the framework. The first version of
this suite did exactly that and reported 0.88x retention where the honest figure
is 1.01x — the client's own 4 MiB, attributed to the server.
EOF
)"

# --- 3. The decision and its sizing rule are on record -----------------------
URUQUIM_FLAT="$(tr '\n' ' ' <"$URUQUIM_DOC" | tr -s ' ')"
# The separator between the two factors is a multibyte `×`. `.` matches one
# CHARACTER in a UTF-8 locale but one BYTE under LC_ALL=C/POSIX, where it
# cannot span the two bytes of U+00D7 and this check fails on a document that
# is perfectly correct. Match the bytes between the factors explicitly instead,
# so the gate says the same thing in every locale.
grep -qiE 'max_connections .{1,3} \(largest response' <<<"$URUQUIM_FLAT" ||
  fail "the sizing rule is gone from the C-04 record. A delegation to a cgroup is acceptable ONLY while the operator is told what to size it to; without the rule this is an unbounded resource with a shrug."
grep -qi 'max_response_bytes' <<<"$URUQUIM_FLAT" ||
  fail "the recommended limit's specification is gone; the decision to delegate was made ON CONDITION that the alternative is specified and handed forward"
grep -qi 'hours-long soak' <<<"$URUQUIM_FLAT" ||
  fail "the owed hours-long soak is no longer recorded. An obligation in a gated document is trackable; an obligation in a reader's memory is what this phase exists to stop relying on."

# --- 4. Green ----------------------------------------------------------------
env ODIN_ROOT="$URUQUIM_ODIN_ROOT" "$URUQUIM_ODIN" test \
  "$URUQUIM_ROOT/tests/c04-response-size" \
  "-collection:uruquim=$URUQUIM_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$URUQUIM_TMP/c04"

echo "c04: the two-phase measurement is intact (retention vs leak stay distinguishable)"
echo "c04: the baseline excludes the client's own scratch buffer"
echo "c04: the delegation decision, its sizing rule and the owed soak are on record"
echo "PASS: C-04 response-size and memory-retention controls"
