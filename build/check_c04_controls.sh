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

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_DOC="$DRUSE_ROOT/planning/closure-response-size-and-memory.md"
DRUSE_SUITE="$DRUSE_ROOT/tests/c04-response-size/soak_test.odin"
DRUSE_RESPONSE="$DRUSE_ROOT/vendor/odin-http/response.odin"

fail() {
  echo "C04-CONTROL-FAIL: $*" >&2
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
DRUSE_TMP="$(mktemp -d -t druse-c04-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

test -f "$DRUSE_DOC" || fail "planning/closure-response-size-and-memory.md is missing; it carries the delegation decision and the sizing rule"
test -f "$DRUSE_SUITE" || fail "tests/c04-response-size/soak_test.odin is missing"
test -f "$DRUSE_RESPONSE" || fail "vendor response cleanup is missing"

# --- 1. The two-phase shape --------------------------------------------------
grep -q 'SMALL_ROUNDS :: [0-9]' "$DRUSE_SUITE" ||
  fail "the suite lost its small-response phase; with only the big phase it reports a number that cannot distinguish retention from a leak"
grep -q 'after_small := rss_bytes()' "$DRUSE_SUITE" ||
  fail "the suite no longer reads RSS after the small-response phase — the leak half of the measurement is gone"
grep -q 'after_big := rss_bytes()' "$DRUSE_SUITE" ||
  fail "the suite no longer reads RSS after the big-response phase — the retention half of the measurement is gone"
grep -q 'grew < LEAK_THRESHOLD_BYTES' "$DRUSE_SUITE" ||
  fail "the leak assertion is gone; the suite would then print numbers and assert nothing"

# --- 2. The baseline is honest -----------------------------------------------
grep -q 'scratch\[i\] = u8(i)' "$DRUSE_SUITE" || fail "$(cat <<'EOF'
the client scratch buffer is no longer touched before the baseline RSS reading.
RSS counts resident pages, not reservations, so an untouched buffer becomes
resident during phase 1 and is charged to the server-side delta. The first
version of this suite did exactly that: the client's own 4 MiB moved after the
baseline and was misattributed.
EOF
)"

# --- 3. The arena reclamation semantic is wired and executable ---------------
grep -q 'free_all(context.temp_allocator)' "$DRUSE_RESPONSE" ||
  fail "clean_request_loop no longer frees the per-connection request arena"
grep -q 'c04_growing_arena_free_all_releases_oversize_blocks' "$DRUSE_SUITE" ||
  fail "the executable growing-arena reclamation assertion is gone"
grep -q 'virtual.arena_free_all(&arena)' "$DRUSE_SUITE" ||
  fail "the arena semantic test no longer exercises arena_free_all"

# --- 4. The corrected attribution is on record -------------------------------
DRUSE_FLAT="$(tr '\n' ' ' <"$DRUSE_DOC" | tr -s ' ')"
grep -qi 'do not leave body-sized live blocks' <<<"$DRUSE_FLAT" ||
  fail "the corrected ownership result is gone: completed responses release body-sized arena blocks"
grep -qi 'allocator/process high-water' <<<"$DRUSE_FLAT" ||
  fail "the record again risks attributing RSS to a live owner without an allocator measurement"
grep -qi 'no honest universal formula' <<<"$DRUSE_FLAT" ||
  fail "the withdrawn max_connections-times-response formula has been promoted back into a sizing guarantee"
grep -qi 'max_response_bytes' <<<"$DRUSE_FLAT" ||
  fail "the shipped per-response limit is gone from the corrected C-04 record"
grep -qi 'concurrent buffered-response matrix' <<<"$DRUSE_FLAT" ||
  fail "the concurrent response-memory campaign is no longer recorded"
grep -qi 'hours-long' <<<"$DRUSE_FLAT" ||
  fail "the owed hours-long soak is no longer recorded. An obligation in a gated document is trackable; an obligation in a reader's memory is what this phase exists to stop relying on."

# --- 5. Production green; arena-semantic mutant red --------------------------
env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
  "$DRUSE_ROOT/tests/c04-response-size" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$DRUSE_TMP/c04"

cp -R "$DRUSE_ROOT/tests/c04-response-size" "$DRUSE_TMP/mutant"
sed -i 's|^[[:space:]]*virtual\.arena_free_all(&arena)$|\t// C04 negative control: reclamation deliberately suppressed.|' \
  "$DRUSE_TMP/mutant/soak_test.odin"
grep -q 'negative control: reclamation deliberately suppressed' "$DRUSE_TMP/mutant/soak_test.odin" ||
  fail "the arena semantic mutation no longer applies"

set +e
DRUSE_OUT="$(
  env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
    "$DRUSE_TMP/mutant" \
    "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
    "-out:$DRUSE_TMP/c04-mutant" 2>&1
)"
DRUSE_RC=$?
set -e
test "$DRUSE_RC" -ne 0 ||
  fail "arena_free_all was removed from the semantic test and the mutant stayed green"
grep -q 'arena_free_all retained oversize blocks' <<<"$DRUSE_OUT" || {
  echo "$DRUSE_OUT" >&2
  fail "the arena semantic mutant failed for the wrong reason"
}

echo "c04: the two-phase RSS measurement is intact (large-response high-water then small-response stability)"
echo "c04: the baseline excludes the client's own scratch buffer"
echo "c04: production free_all is wired; growing arena releases oversize blocks -> GREEN; call removed in copied semantic mutant -> RED"
echo "c04: corrected ownership, concurrent campaign and hours-long soak are on record"
echo "PASS: C-04 response-memory attribution controls"
