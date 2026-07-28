#!/usr/bin/env bash
# C-05 — combined saturation and the write-observability gap, under control.
#
# Four executable claims:
#
#   1. THE INSTRUMENT SURVIVES. The lab's whole value is that it tells the
#      refusal kinds APART — a 503 (the Handler lane) from a connected-then-EOF
#      (the admission budget) from a failed connect (the backlog). Collapse
#      those into "error" and the suite can no longer name a binding constraint,
#      which is the one thing it exists to do;
#   2. THE F-C05-1 FIX cannot be silently reverted: the accept-cancel wait stays
#      bounded, and it still refuses to reattach on expiry;
#   3. the measurement and the specification survive in the record — perimeter 7
#      was DEFERRED on condition that its API is specified and handed forward;
#   4. the lab is green, which now also means the server still shuts down.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_DOC="$URUQUIM_ROOT/planning/closure-saturation-and-write-observability.md"
URUQUIM_SUITE="$URUQUIM_ROOT/tests/c05-saturation/saturation_test.odin"
URUQUIM_SERVER="$URUQUIM_ROOT/vendor/odin-http/server.odin"

fail() {
  echo "C05-CONTROL-FAIL: $*" >&2
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
URUQUIM_TMP="$(mktemp -d -t uruquim-c05-controls-XXXXXXXX)"
trap 'rm -rf "$URUQUIM_TMP"' EXIT

test -f "$URUQUIM_DOC" || fail "planning/closure-saturation-and-write-observability.md is missing"
test -f "$URUQUIM_SUITE" || fail "tests/c05-saturation/saturation_test.odin is missing"

# --- 1. The instrument -------------------------------------------------------
for URUQUIM_KIND in Served Lane_Refused Admission_Refused Connect_Failed Timed_Out Malformed; do
  grep -q "$URUQUIM_KIND" "$URUQUIM_SUITE" ||
    fail "$(printf 'the saturation lab lost the outcome %s.\nThe six outcomes are the instrument: an admission refusal ACCEPTS the connection and then closes it unwritten, so a client that counts only "errors" cannot tell it from a backlog drop. Collapse them and the suite can no longer name which resource bound first.' "$URUQUIM_KIND")"
done
grep -q 'FIRST BINDING CONSTRAINT' "$URUQUIM_SUITE" ||
  fail "the lab no longer reports which resource bound first — that report IS the deliverable of perimeter 6"
grep -q 'total_malformed == 0' "$URUQUIM_SUITE" ||
  fail "the malformed-reply assertion is gone; under saturation every outcome must be one the design NAMES, and that assertion is the only thing checking it"

# --- 1b. H-4: every lane 503 carries Retry-After -----------------------------
grep -q 'total_lane_503_no_retry == 0' "$URUQUIM_SUITE" ||
  fail "the Retry-After assertion is gone. A 503 lane refusal that does not tell the client when to come back invites an immediate retry onto the same contended pool, which collides again. The ramp reliably produces 503s, so the property is checked over real refusals."
# The ramp must demonstrably overwhelm the server, and a run that produced no
# 503 must SAY so. Two earlier forms of this both gated on the scheduler rather
# than on the code:
#   `total_lane_503 > 0`  — no 503 in six of nine measured runs.
#   `total_refused > 0`   — a gate run served 36 of 88 and refused NONE; the
#                           other 52 timed out, because under dedicated accept
#                           saturation presents as queueing, not refusal. That
#                           assertion contradicted Campaign C's own thesis.
# What holds by arithmetic is that 88 clients cannot all be served on a 20-slot
# budget with 40 ms handlers. Whether the excess is refused or merely made to
# wait is the scheduling detail that must not gate.
grep -q "total_served < total_driven" "$URUQUIM_SUITE" ||
  fail "the assertion that the ramp actually saturates the server is gone; without it every refusal and dwell assertion below can pass on a run that was never under load"
grep -q 'NOT exercised\|NOT be evidence\|NOT evidence' "$URUQUIM_SUITE" ||
  fail "the suite no longer reports when a run produced no lane 503. Retry-After is then checked over an empty set and the run reads as evidence for a property it never exercised."
# Campaign C — the dwell counter must be OBSERVABLE and WIRED, replacing the
# retired lane_collisions. Asserted in two places: the suite compares
# handler_dwell_ns against served dispatches, and the accumulator lives at the
# dispatch bracket.
grep -q 'stats.handler_dwell_ns >= i64(total_served)' "$URUQUIM_SUITE" ||
  fail "the dwell-vs-served assertion is gone, or it is no longer built from the SERVED count. A saturation signal that stays flat while clients wait out hundreds of handler dwells is as decorative as lane_collisions was; this ties handler_dwell_ns to real work. It must be bounded by requests actually dispatched — bounding it by clients DRIVEN over-demands dwell by 2-3x under refusal and fails on correct code."
grep -q 'total_served += tally\[.Served\]' "$URUQUIM_SUITE" ||
  fail "the served count is no longer accumulated from the per-level tallies; the dwell floor would then be built from a number the run did not measure"
grep -q 'res._conn.server.handler_dwell_ns' "$URUQUIM_ROOT/web/internal/transport/odin_http_adapter.odin" ||
  fail "the dwell accumulator is no longer fed at the dispatch bracket in dispatch_exchange; web.stats().handler_dwell_ns would then stay zero (Campaign C)."
# MONOTONIC. `time.now`/`time.since` is CLOCK_REALTIME and signed, so an NTP
# step backward during a dispatch subtracts from a counter operators read as
# monotonically increasing. `tick_now`/`tick_since` is CLOCK_MONOTONIC_RAW.
grep -q 'i64(time.tick_since(dispatch_started))' "$URUQUIM_ROOT/web/internal/transport/odin_http_adapter.odin" ||
  fail "the dispatch bracket no longer measures elapsed monotonic time; without it, handler_dwell_ns counts nothing (Campaign C)."
grep -q 'dispatch_started := time.tick_now()' "$URUQUIM_ROOT/web/internal/transport/odin_http_adapter.odin" ||
  fail "the dispatch bracket's start timestamp is not tick_now(). A wall-clock start makes the dwell delta signed: an NTP step back during a dispatch decrements handler_dwell_ns and an operator differencing it sees a negative rate."
grep -q 'Retry-After' "$URUQUIM_ROOT/web/internal/transport/odin_http_adapter.odin" ||
  fail "the lane-refusal 503 no longer sets Retry-After (H-4). The refusal path at dispatch_exchange must add the header before respond()."

# --- 2. The F-C05-1 fix, now STRONGER: PATCH 28 removed the spin entirely -----
# Patch 27 bounded the accept-cancel spin at 250ms/request to stop the wedge.
# PATCH 28 (perf) deletes the spin: handler_lane_enter cancels the accept and
# pushes it to the kernel with a single non-blocking nbio.tick(0), so no lane
# thread ever waits. The wedge is now impossible by CONSTRUCTION (no wait), not
# merely bounded — a strictly stronger property than F-C05-1 required — and the
# 250ms/request tail it caused (measured p99 517ms → 151µs) is gone. The
# behavioural proof is part 4 below: the saturation lab, which reproduced the
# wedge, now shuts down cleanly.
if grep -qE 'for +target\.accept\.client == 0' "$URUQUIM_SERVER"; then
  fail "the accept-cancel SPIN is back in handler_lane_enter. PATCH 28 removed it because it was the p99 tail and the C-05 wedge (a lane parked in the spin never observes s.closing). Do not reintroduce a lane-thread wait; cancel + a single non-blocking nbio.tick(0) is the suspension."
fi
grep -q 'PATCH 28' "$URUQUIM_SERVER" ||
  fail "the PATCH 28 non-spinning accept suspension is gone. handler_lane_enter must still cancel the accept before a synchronous handler (the WP71 guarantee), just without the spin."
grep -q 'nbio.tick(0)' "$URUQUIM_SERVER" ||
  fail "the non-blocking cancel push (nbio.tick(0)) is gone; without it the async_cancel is only enqueued in userspace and is not submitted to the kernel before the handler runs, so the accept stays live and the WP71 suspension does not take effect"

# --- 3. The measurement and the specification --------------------------------
URUQUIM_FLAT="$(tr '\n' ' ' <"$URUQUIM_DOC" | tr -s ' ')"
grep -qi 'binding constraint is the Handler lane' <<<"$URUQUIM_FLAT" ||
  fail "the perimeter-6 finding is gone from the record. That the LANE binds first — and at four concurrent clients, far below the twenty-slot connection budget — is the result; without it an operator tunes max_connections, which is not the constraint."
grep -qi 'Server_Stats' <<<"$URUQUIM_FLAT" ||
  fail "the perimeter-7 API specification is gone. Shipping it was DEFERRED on the explicit condition that it is specified and handed forward; without the specification this is an unowned gap again."
grep -qi 'aborted_slow' <<<"$URUQUIM_FLAT" ||
  fail "the record no longer names the stream counters that exist internally and are reachable from no public API — the concrete half of the observability gap"

# --- 4. Green ----------------------------------------------------------------
env ODIN_ROOT="$URUQUIM_ODIN_ROOT" "$URUQUIM_ODIN" test \
  "$URUQUIM_ROOT/tests/c05-saturation" \
  "-collection:uruquim=$URUQUIM_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$URUQUIM_TMP/c05"

echo "c05: the six refusal outcomes stay distinguishable; the binding constraint is still reported"
echo "c05: the accept-cancel spin is GONE (PATCH 28) — the wedge is impossible by construction, not merely bounded (F-C05-1 superseded)"
echo "c05: the perimeter-6 finding and the perimeter-7 Server_Stats specification are on record"
echo "PASS: C-05 combined-saturation and write-observability controls"
