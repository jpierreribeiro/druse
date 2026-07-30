#!/usr/bin/env bash
# C-01 — the async-operation inventory, under control.
#
# The inventory only works if it CANNOT go stale. Five executable claims:
#
#   1. the CENSUS holds — the number of `nbio.*_poly*(` operation-creating call
#      sites in the tree equals the number `planning/closure-async-op-inventory.md`
#      declares on its `c01-op-sites` marker. An operation added without a row
#      fails the build. The number lives in the LEDGER, never here: a gate
#      rewritten by the change it judges tests nothing;
#   2. the ten questions are still the ten questions — an inventory that quietly
#      drops "can the callback touch freed memory?" is an inventory that would
#      have missed the WP58 use-after-free;
#   3. the F-C01-1 guard is present at BOTH accept re-arm sites. The behavioural
#      trigger is fd exhaustion (`EMFILE`), which a test suite cannot induce
#      without endangering the runner, so this claim is structural ON PURPOSE
#      and says so;
#   4. the F-C01-6 trigger has not been pulled — `respond_file` stays unreachable
#      from `web/`, because wiring it in would inherit three uncancellable
#      operations whose callbacks dereference a freed `^Connection`;
#   5. the four interruption phases exist by name and the suite is green.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_INVENTORY="$DRUSE_ROOT/planning/closure-async-op-inventory.md"
DRUSE_SUITE="$DRUSE_ROOT/tests/c01-async-ops/async_ops_test.odin"

fail() {
  echo "C01-CONTROL-FAIL: $*" >&2
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
DRUSE_TMP="$(mktemp -d -t druse-c01-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

test -f "$DRUSE_INVENTORY" ||
  fail "planning/closure-async-op-inventory.md is missing; C-01 is the precondition for the C-02 matrix"
test -f "$DRUSE_SUITE" || fail "tests/c01-async-ops/async_ops_test.odin is missing"

# --- 1. The census -----------------------------------------------------------
DRUSE_SITES="$(grep -rhoE 'nbio\.[a-z_]+_poly[0-9]*\(' \
  "$DRUSE_ROOT"/vendor/odin-http/*.odin \
  "$DRUSE_ROOT"/web/*.odin \
  "$DRUSE_ROOT"/web/internal/*/*.odin 2>/dev/null | wc -l)"
DRUSE_DECLARED="$(sed -n 's/^<!-- c01-op-sites: \([0-9]\+\) -->$/\1/p' "$DRUSE_INVENTORY")"
test -n "$DRUSE_DECLARED" ||
  fail "the inventory lost its 'c01-op-sites' marker; without it the census cannot be checked and the table can go stale silently"
test "$DRUSE_SITES" -eq "$DRUSE_DECLARED" || fail "$(cat <<EOF
the tree has $DRUSE_SITES nbio operation-creating call sites but the inventory declares $DRUSE_DECLARED.
An async operation with no row in planning/closure-async-op-inventory.md is an operation
whose owner, cancellation and deadline nobody has stated — which is the exact condition
that let the orphaned recv (WP58) and the missing write deadline (WP90) survive.
Add the row, answer the ten questions, then update the marker.
EOF
)"

# --- 2. The ten questions ----------------------------------------------------
# Flattened: the questions are prose and wrap across lines, and a line-based
# grep would report a question missing because a paragraph was re-filled.
DRUSE_FLAT="$(tr '\n' ' ' <"$DRUSE_INVENTORY" | tr -s ' ')"
for DRUSE_Q in \
  'Who creates it' \
  'Where is the handle stored' \
  'Who can cancel it' \
  'Can the callback fire after cancellation' \
  'Can the callback touch freed memory' \
  'Who cleans up on success' \
  'Who cleans up on error' \
  'Who cleans up at shutdown' \
  'Is there a maximum deadline' \
  'Is there a test'; do
  grep -qi "$DRUSE_Q" <<<"$DRUSE_FLAT" ||
    fail "the inventory no longer asks: '$DRUSE_Q'. The ten questions are the instrument; dropping one is dropping the class of defect it finds."
done

# --- 3. The F-C01-1 guard, at BOTH accept re-arm sites -----------------------
# Structural by necessity: the trigger is accept returning .Insufficient_Resources
# (EMFILE/ENFILE), and a suite that exhausted the process's descriptors to prove
# it would take the test runner down with it. The claim is therefore that the
# guard is written, and the reasoning for why it must be is in the inventory.
DRUSE_GUARDS="$(grep -c 'td.accept == nil && !td.handler_active' \
  "$DRUSE_ROOT/vendor/odin-http/server.odin" || true)"
test "$DRUSE_GUARDS" -ge 2 || fail "$(cat <<'EOF'
fewer than two accept re-arm guards in vendor/odin-http/server.odin.
Both delayed re-arms — the .Insufficient_Resources one-second retry and the
Patch-21 transient ten-millisecond retry — must re-arm only when the lane has no
accept and is not inside a Handler. Without the guard the re-arm overwrites
td.accept, the earlier accept becomes unreachable, and it survives
nbio.remove(td.accept) at shutdown: num_waiting() never reaches zero and the
drain never ends. See F-C01-1.
EOF
)"

# --- 4. The F-C01-6 trigger is not pulled ------------------------------------
if grep -rn 'respond_file' "$DRUSE_ROOT/web" --include='*.odin' >/dev/null 2>&1; then
  fail "$(cat <<'EOF'
web/ now references respond_file. That chain (open -> stat -> read) discards all
three operation handles and its callbacks dereference ^Response, which lives
inside ^Connection — and connection_close/connection_abort cancel only
pending_recv and pending_send. Making it reachable inherits the WP58
use-after-free on a third path. Give those operations stored, cancellable
handles and add rows 15-17 to the inventory first. See F-C01-6.
EOF
)"
fi

# --- 5. The phases exist by name, and the suite is green ---------------------
for DRUSE_PHASE in \
  phase_the_clean_stop_floor_is_the_date_timer \
  phase_a_recv_holding_a_partial_token_is_cancelled \
  phase_a_send_in_flight_is_ended_by_the_drain_not_the_write_deadline \
  phase_a_stop_after_a_write_deadline_abort_is_prompt; do
  grep -q "^$DRUSE_PHASE ::" "$DRUSE_SUITE" ||
    fail "interruption phase dropped: $DRUSE_PHASE"
done

# The write-deadline inequality is the instrument of P3: if LONG_WRITE_TIME ever
# stops exceeding the drain deadline, the phase still passes and proves nothing.
grep -q 'LONG_WRITE_TIME :: i64(5 \* 1_000_000_000)' "$DRUSE_SUITE" ||
  fail "P3's write deadline is no longer five times the drain deadline; the phase can then no longer distinguish 'ended by the drain' from 'ended by the sweep' (F-C01-2)"

env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
  "$DRUSE_ROOT/tests/c01-async-ops" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$DRUSE_TMP/c01"

echo "c01: $DRUSE_SITES nbio operation sites, all $DRUSE_DECLARED accounted for in the inventory"
echo "c01: the ten ownership/cancel/cleanup questions are intact"
echo "c01: both accept re-arms are guarded (F-C01-1); respond_file stays unreachable (F-C01-6)"
echo "c01: recv mid-token, send in flight and post-abort stops are all bounded and measured"
echo "PASS: C-01 async-operation inventory controls"
