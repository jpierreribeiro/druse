#!/usr/bin/env bash
# C4 — corrective WP for friction F8-5: web.stream_live, the read-only disconnect
# predicate. Ledger growth (78 -> 79) is pinned by the freeze/public-api/docs
# gates. This control pins that the registry-level is_live behaviour is WIRED
# (open→live, close/stale/out-of-range→dead) and that the public zero-value path
# is false — proven by the unit suite.
set -euo pipefail
DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_STREAM="$DRUSE_ROOT/web/stream.odin"
DRUSE_REG="$DRUSE_ROOT/web/internal/stream/stream.odin"
DRUSE_SUITE="$DRUSE_ROOT/tests/c4-stream-live/stream_live_test.odin"
fail() { echo "C4-CONTROL-FAIL: $*" >&2; exit 1; }
DRUSE_ODIN="${DRUSE_ODIN_BIN:-odin}"
DRUSE_ODIN_DIR="$(cd "$(dirname "$(readlink -f "$DRUSE_ODIN")")" && pwd)"

grep -qE '^stream_live :: proc\(s: Stream\) -> bool' "$DRUSE_STREAM" ||
  fail "web.stream_live is missing its ratified signature"
grep -qE '^is_live :: proc\(r: \^Registry, tok: Token\) -> bool' "$DRUSE_REG" ||
  fail "internal/stream.is_live (the registry predicate stream_live reads) is missing"
test -f "$DRUSE_SUITE" || fail "tests/c4-stream-live/stream_live_test.odin is missing"
env ODIN_ROOT="$DRUSE_ODIN_DIR" "$DRUSE_ODIN" test "$DRUSE_ROOT/tests/c4-stream-live" \
  -collection:druse="$DRUSE_ROOT" >/dev/null 2>&1 ||
  fail "the C4 stream-live suite did not pass"
echo "C4 control: stream_live + registry is_live wired (open→live, close/stale→dead, zero-value→false); suite green"
