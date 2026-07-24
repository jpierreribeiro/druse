#!/usr/bin/env bash
# C4 — corrective WP for friction F8-5: web.stream_live, the read-only disconnect
# predicate. Ledger growth (78 -> 79) is pinned by the freeze/public-api/docs
# gates. This control pins that the registry-level is_live behaviour is WIRED
# (open→live, close/stale/out-of-range→dead) and that the public zero-value path
# is false — proven by the unit suite.
set -euo pipefail
URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_STREAM="$URUQUIM_ROOT/web/stream.odin"
URUQUIM_REG="$URUQUIM_ROOT/web/internal/stream/stream.odin"
URUQUIM_SUITE="$URUQUIM_ROOT/tests/c4-stream-live/stream_live_test.odin"
fail() { echo "C4-CONTROL-FAIL: $*" >&2; exit 1; }
URUQUIM_ODIN="${URUQUIM_ODIN_BIN:-odin}"
URUQUIM_ODIN_DIR="$(cd "$(dirname "$(readlink -f "$URUQUIM_ODIN")")" && pwd)"

grep -qE '^stream_live :: proc\(s: Stream\) -> bool' "$URUQUIM_STREAM" ||
  fail "web.stream_live is missing its ratified signature"
grep -qE '^is_live :: proc\(r: \^Registry, tok: Token\) -> bool' "$URUQUIM_REG" ||
  fail "internal/stream.is_live (the registry predicate stream_live reads) is missing"
test -f "$URUQUIM_SUITE" || fail "tests/c4-stream-live/stream_live_test.odin is missing"
env ODIN_ROOT="$URUQUIM_ODIN_DIR" "$URUQUIM_ODIN" test "$URUQUIM_ROOT/tests/c4-stream-live" \
  -collection:uruquim="$URUQUIM_ROOT" >/dev/null 2>&1 ||
  fail "the C4 stream-live suite did not pass"
echo "C4 control: stream_live + registry is_live wired (open→live, close/stale→dead, zero-value→false); suite green"
