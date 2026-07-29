#!/usr/bin/env bash
# C3 — corrective WP for friction F8-6: the optional typed query reader
# web.query_int_opt. The ledger growth (77 -> 78) is pinned by the freeze/public-
# api/docs gates. This control pins what those cannot see: that the three-state
# behaviour is WIRED — absent is not a 400, present-valid carries the value, and a
# malformed value IS a 400 — proven on real (in-memory transport) traffic.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_EXTRACT="$DRUSE_ROOT/web/extract.odin"
DRUSE_SUITE="$DRUSE_ROOT/tests/c3-query-opt/contract_test.odin"

fail() { echo "C3-CONTROL-FAIL: $*" >&2; exit 1; }

DRUSE_ODIN="${DRUSE_ODIN_BIN:-odin}"
DRUSE_ODIN_DIR="$(cd "$(dirname "$(readlink -f "$DRUSE_ODIN")")" && pwd)"

grep -qE '^query_int_opt :: proc\(ctx: \^Context, name: string\) -> \(value: int, present: bool, ok: bool\)' "$DRUSE_EXTRACT" ||
  fail "web.query_int_opt is missing its ratified signature"

test -f "$DRUSE_SUITE" || fail "tests/c3-query-opt/contract_test.odin is missing"
env ODIN_ROOT="$DRUSE_ODIN_DIR" "$DRUSE_ODIN" test "$DRUSE_ROOT/tests/c3-query-opt" \
  -collection:druse="$DRUSE_ROOT" >/dev/null 2>&1 ||
  fail "the C3 query-opt suite did not pass"

echo "C3 control: query_int_opt reports presence (absent≠400, present carries value, malformed=400); suite green"
