#!/usr/bin/env bash
# C-05 — combined saturation and the write-observability gap, under control.
#
# Four executable claims:
#
#   1. THE INSTRUMENT SURVIVES. The lab's whole value is that it tells the
#      refusal kinds APART — a 503 (the Handler lane) from a connected-then-EOF
#      (the admission budget) from a failed connect (the backlog). Collapse
#      those into "error" and the suite can no longer describe how saturation
#      presented in that run;
#   2. THE F-C05-1 FIX cannot be silently reverted: the accept-cancel wait stays
#      bounded, and it still refuses to reattach on expiry;
#   3. the measurement and the specification survive in the record — perimeter 7
#      was DEFERRED on condition that its API is specified and handed forward;
#   4. the lab is green, which now also means the server still shuts down.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_DOC="$DRUSE_ROOT/planning/closure-saturation-and-write-observability.md"
DRUSE_SUITE="$DRUSE_ROOT/tests/c05-saturation/saturation_test.odin"
DRUSE_SERVER="$DRUSE_ROOT/vendor/odin-http/server.odin"

fail() {
  echo "C05-CONTROL-FAIL: $*" >&2
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
DRUSE_TMP="$(mktemp -d -t druse-c05-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

test -f "$DRUSE_DOC" || fail "planning/closure-saturation-and-write-observability.md is missing"
test -f "$DRUSE_SUITE" || fail "tests/c05-saturation/saturation_test.odin is missing"

# --- 1. The instrument -------------------------------------------------------
for DRUSE_KIND in Served Lane_Refused Admission_Refused Connect_Failed Timed_Out Malformed; do
  grep -q "$DRUSE_KIND" "$DRUSE_SUITE" ||
    fail "$(printf 'the saturation lab lost the outcome %s.\nThe six outcomes are the instrument: an admission refusal ACCEPTS the connection and then closes it unwritten, so a client that counts only "errors" cannot tell it from a backlog drop. Collapse them and the suite can no longer distinguish how saturation presented in that run.' "$DRUSE_KIND")"
done
grep -q 'FIRST OBSERVED REFUSAL' "$DRUSE_SUITE" ||
  fail "the lab no longer reports the first observed refusal. It is diagnostic and scheduler-dependent, but losing it would hide which face saturation took in a run."
grep -q 'total_malformed == 0' "$DRUSE_SUITE" ||
  fail "the malformed-reply assertion is gone; under saturation every outcome must be one the design NAMES, and that assertion is the only thing checking it"

# --- 1b. PATCH 42: no HTTP before a request is parsed ------------------------
grep -q 'total_lane_503 == 0' "$DRUSE_SUITE" ||
  fail "the assertion rejecting pre-request HTTP is gone. The dedicated acceptor has no parsed request and must refuse saturation at the transport layer."
grep -q 'saturation_after - saturation_before == 8' "$DRUSE_SUITE" ||
  fail "the deterministic saturation_refusals delta assertion is gone; a published counter that never moves is decorative."
grep -q 'atomic_add(&s.refused_saturation_total, 1)' "$DRUSE_SERVER" ||
  fail "the acceptor saturation refusal no longer increments its dedicated counter."
if grep -q 'ACCEPT_OVERLOAD_RESPONSE' "$DRUSE_SERVER"; then
  fail "the acceptor again owns a raw HTTP response. HTTP may only be emitted after request parsing and association."
fi
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
grep -q "total_served < total_driven" "$DRUSE_SUITE" ||
  fail "the assertion that the ramp actually saturates the server is gone; without it every refusal and dwell assertion below can pass on a run that was never under load"
# Campaign C — the dwell counter must be OBSERVABLE and WIRED, replacing the
# retired lane_collisions. Asserted in two places: the suite compares
# handler_dwell_ns against served dispatches, and the accumulator lives at the
# dispatch bracket.
grep -q 'stats.handler_dwell_ns >= i64(total_served)' "$DRUSE_SUITE" ||
  fail "the dwell-vs-served assertion is gone, or it is no longer built from the SERVED count. A saturation signal that stays flat while clients wait out hundreds of handler dwells is as decorative as lane_collisions was; this ties handler_dwell_ns to real work. It must be bounded by requests actually dispatched — bounding it by clients DRIVEN over-demands dwell by 2-3x under refusal and fails on correct code."
grep -q 'total_served += tally\[.Served\]' "$DRUSE_SUITE" ||
  fail "the served count is no longer accumulated from the per-level tallies; the dwell floor would then be built from a number the run did not measure"
grep -q 'res._conn.server.handler_dwell_ns' "$DRUSE_ROOT/web/internal/transport/odin_http_adapter.odin" ||
  fail "the dwell accumulator is no longer fed at the dispatch bracket in dispatch_exchange; web.stats().handler_dwell_ns would then stay zero (Campaign C)."
# MONOTONIC. `time.now`/`time.since` is CLOCK_REALTIME and signed, so an NTP
# step backward during a dispatch subtracts from a counter operators read as
# monotonically increasing. `tick_now`/`tick_since` is CLOCK_MONOTONIC_RAW.
grep -q 'i64(time.tick_since(dispatch_started))' "$DRUSE_ROOT/web/internal/transport/odin_http_adapter.odin" ||
  fail "the dispatch bracket no longer measures elapsed monotonic time; without it, handler_dwell_ns counts nothing (Campaign C)."
grep -q 'dispatch_started := time.tick_now()' "$DRUSE_ROOT/web/internal/transport/odin_http_adapter.odin" ||
  fail "the dispatch bracket's start timestamp is not tick_now(). A wall-clock start makes the dwell delta signed: an NTP step back during a dispatch decrements handler_dwell_ns and an operator differencing it sees a negative rate."
grep -q 'Retry-After' "$DRUSE_ROOT/web/internal/transport/odin_http_adapter.odin" ||
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
if grep -qE 'for +target\.accept\.client == 0' "$DRUSE_SERVER"; then
  fail "the accept-cancel SPIN is back in handler_lane_enter. PATCH 28 removed it because it was the p99 tail and the C-05 wedge (a lane parked in the spin never observes s.closing). Do not reintroduce a lane-thread wait; cancel + a single non-blocking nbio.tick(0) is the suspension."
fi
grep -q 'PATCH 28' "$DRUSE_SERVER" ||
  fail "the PATCH 28 non-spinning accept suspension is gone. handler_lane_enter must still cancel the accept before a synchronous handler (the WP71 guarantee), just without the spin."
grep -q 'nbio.tick(0)' "$DRUSE_SERVER" ||
  fail "the non-blocking cancel push (nbio.tick(0)) is gone; without it the async_cancel is only enqueued in userspace and is not submitted to the kernel before the handler runs, so the accept stays live and the WP71 suspension does not take effect"

# --- 3. The measurement and the specification --------------------------------
DRUSE_FLAT="$(tr '\n' ' ' <"$DRUSE_DOC" | tr -s ' ')"
grep -qi 'scheduler-dependent' <<<"$DRUSE_FLAT" ||
  fail "the record again implies a deterministic first refusal. Ten current runs produced Lane_Refused first in 8 and Admission_Refused first in 2; the ordering must remain documented as scheduler-dependent."
grep -qiE 'lanes.{0,8}(÷|/|divided by).{0,8}dwell' <<<"$DRUSE_FLAT" ||
  fail "the deterministic capacity rule is gone. Refusal ordering varies, but synchronous handler capacity remains lanes divided by mean dwell."
grep -qi 'Server_Stats' <<<"$DRUSE_FLAT" ||
  fail "the perimeter-7 API specification is gone. Shipping it was DEFERRED on the explicit condition that it is specified and handed forward; without the specification this is an unowned gap again."
grep -qi 'aborted_slow' <<<"$DRUSE_FLAT" ||
  fail "the record no longer names the stream counters that exist internally and are reachable from no public API — the concrete half of the observability gap"

# --- 4. Green ----------------------------------------------------------------
env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
  "$DRUSE_ROOT/tests/c05-saturation" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$DRUSE_TMP/c05"

# PATCH 42 negative control: restore the forbidden acceptor-side HTTP write in
# an isolated tree. The behavioural corpus must go red specifically because it
# observed pre-request 503 bytes; a shape-only grep is not evidence.
DRUSE_MUT="$DRUSE_TMP/pre-request-http-mutant"
mkdir -p "$DRUSE_MUT/tests"
cp -R "$DRUSE_ROOT/web" "$DRUSE_MUT/"
cp -R "$DRUSE_ROOT/vendor" "$DRUSE_MUT/"
cp -R "$DRUSE_ROOT/tests/c05-saturation" "$DRUSE_MUT/tests/"
perl -0pi -e 's@(\tsync\.atomic_store_explicit\(&s\.pending_waiting, false, \.Release\)\n)(\tnet\.close\(sock\))@$1\tdata := transmute([]u8)string("HTTP/1.1 503 Service Unavailable\\r\\nContent-Length: 0\\r\\nConnection: close\\r\\nRetry-After: 1\\r\\n\\r\\n")\n\t_, _ = net.send_tcp(sock, data)\n$2@' \
  "$DRUSE_MUT/vendor/odin-http/server.odin"
grep -q 'HTTP/1.1 503 Service Unavailable' \
  "$DRUSE_MUT/vendor/odin-http/server.odin" ||
  fail "the pre-request HTTP mutation no longer applies"

set +e
DRUSE_MUT_OUT="$(
  env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
    "$DRUSE_MUT/tests/c05-saturation" \
    "-collection:druse=$DRUSE_MUT" -define:ODIN_TEST_THREADS=1 \
    "-out:$DRUSE_TMP/c05-pre-request-mutant" 2>&1
)"
DRUSE_MUT_RC=$?
set -e
test "$DRUSE_MUT_RC" -ne 0 ||
  fail "the acceptor emitted HTTP before parsing a request and the saturation corpus stayed green"
grep -q 'HTTP 503 responses were emitted before a request was parsed' \
  <<<"$DRUSE_MUT_OUT" || {
    echo "$DRUSE_MUT_OUT" >&2
    fail "the pre-request HTTP mutant failed for the wrong reason"
  }

echo "c05: the six outcomes stay distinguishable; first observed refusal is reported without pretending its ordering is deterministic"
echo "c05: the accept-cancel spin is GONE (PATCH 28) — the wedge is impossible by construction, not merely bounded (F-C05-1 superseded)"
echo "c05: acceptor saturation is transport-only and counted; restoring pre-request HTTP makes the corpus RED"
echo "PASS: C-05 combined-saturation and write-observability controls"
