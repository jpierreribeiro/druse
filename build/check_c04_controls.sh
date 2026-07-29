#!/usr/bin/env bash
# C-04 — response size, arena reclamation and RSS high-water, under control.
#
# Five executable claims:
#
#   1. the two-phase shape is intact — the suite must serve BIG responses and
#      then MANY SMALL ones on the SAME connections;
#   2. the baseline is honest — the client's scratch buffer is touched before
#      RSS is first read. Without that, ~4 MiB of the CLIENT's memory is
#      reported as the framework's RSS delta, which is how the first version of
#      this suite understated the client's contribution;
#   3. the response cleanup remains wired to free_all and the pinned growing
#      arena semantic is executable;
#   4. the corrected attribution survives in the record;
#   5. the suite is green and the arena semantic's mutant is red.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_DOC="$URUQUIM_ROOT/planning/closure-response-size-and-memory.md"
URUQUIM_SUITE="$URUQUIM_ROOT/tests/c04-response-size/soak_test.odin"
URUQUIM_RESPONSE="$URUQUIM_ROOT/vendor/odin-http/response.odin"

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
test -f "$URUQUIM_RESPONSE" || fail "vendor response cleanup is missing"

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
resident during phase 1 and is charged to the server-side delta. The first
version of this suite did exactly that: the client's own 4 MiB moved after the
baseline and was misattributed.
EOF
)"

# --- 3. The arena reclamation semantic is wired and executable ---------------
grep -q 'free_all(context.temp_allocator)' "$URUQUIM_RESPONSE" ||
  fail "clean_request_loop no longer frees the per-connection request arena"
grep -q 'c04_growing_arena_free_all_releases_oversize_blocks' "$URUQUIM_SUITE" ||
  fail "the executable growing-arena reclamation assertion is gone"
grep -q 'virtual.arena_free_all(&arena)' "$URUQUIM_SUITE" ||
  fail "the arena semantic test no longer exercises arena_free_all"

# --- 4. The corrected attribution is on record -------------------------------
URUQUIM_FLAT="$(tr '\n' ' ' <"$URUQUIM_DOC" | tr -s ' ')"
grep -qi 'do not leave body-sized live blocks' <<<"$URUQUIM_FLAT" ||
  fail "the corrected ownership result is gone: completed responses release body-sized arena blocks"
grep -qi 'allocator/process high-water' <<<"$URUQUIM_FLAT" ||
  fail "the record again risks attributing RSS to a live owner without an allocator measurement"
grep -qi 'no honest universal formula' <<<"$URUQUIM_FLAT" ||
  fail "the withdrawn max_connections-times-response formula has been promoted back into a sizing guarantee"
grep -qi 'max_response_bytes' <<<"$URUQUIM_FLAT" ||
  fail "the shipped per-response limit is gone from the corrected C-04 record"
grep -qi 'concurrent buffered-response matrix' <<<"$URUQUIM_FLAT" ||
  fail "the concurrent response-memory campaign is no longer recorded"
grep -qi 'hours-long' <<<"$URUQUIM_FLAT" ||
  fail "the owed hours-long soak is no longer recorded. An obligation in a gated document is trackable; an obligation in a reader's memory is what this phase exists to stop relying on."

# --- 5. Production green; arena-semantic mutant red --------------------------
env ODIN_ROOT="$URUQUIM_ODIN_ROOT" "$URUQUIM_ODIN" test \
  "$URUQUIM_ROOT/tests/c04-response-size" \
  "-collection:uruquim=$URUQUIM_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$URUQUIM_TMP/c04"

cp -R "$URUQUIM_ROOT/tests/c04-response-size" "$URUQUIM_TMP/mutant"
sed -i 's|^[[:space:]]*virtual\.arena_free_all(&arena)$|\t// C04 negative control: reclamation deliberately suppressed.|' \
  "$URUQUIM_TMP/mutant/soak_test.odin"
grep -q 'negative control: reclamation deliberately suppressed' "$URUQUIM_TMP/mutant/soak_test.odin" ||
  fail "the arena semantic mutation no longer applies"

set +e
URUQUIM_OUT="$(
  env ODIN_ROOT="$URUQUIM_ODIN_ROOT" "$URUQUIM_ODIN" test \
    "$URUQUIM_TMP/mutant" \
    "-collection:uruquim=$URUQUIM_ROOT" -define:ODIN_TEST_THREADS=1 \
    "-out:$URUQUIM_TMP/c04-mutant" 2>&1
)"
URUQUIM_RC=$?
set -e
test "$URUQUIM_RC" -ne 0 ||
  fail "arena_free_all was removed from the semantic test and the mutant stayed green"
grep -q 'arena_free_all retained oversize blocks' <<<"$URUQUIM_OUT" || {
  echo "$URUQUIM_OUT" >&2
  fail "the arena semantic mutant failed for the wrong reason"
}

echo "c04: the two-phase RSS measurement is intact (large-response high-water then small-response stability)"
echo "c04: the baseline excludes the client's own scratch buffer"
echo "c04: production free_all is wired; growing arena releases oversize blocks -> GREEN; call removed in copied semantic mutant -> RED"
echo "c04: corrected ownership, concurrent campaign and hours-long soak are on record"
echo "PASS: C-04 response-memory attribution controls"
