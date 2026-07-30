#!/usr/bin/env bash
# C7 — corrective WP for friction F8-3: web.request_state, ONE typed request-scoped
# value (the narrow ADR-028 reopening). Ledger growth (79 -> 80) is pinned by the
# freeze/public-api/docs gates. This control pins what those cannot see: that the
# typed slot is WIRED (middleware writes -> handler reads), does not leak across
# requests, and enforces the single-type discipline — proven on real (in-memory
# transport) traffic.
set -euo pipefail
DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_STATE="$DRUSE_ROOT/web/state.odin"
DRUSE_SUITE="$DRUSE_ROOT/tests/c7-request-state/request_state_test.odin"
fail() { echo "C7-CONTROL-FAIL: $*" >&2; exit 1; }
DRUSE_ODIN="${DRUSE_ODIN_BIN:-odin}"
DRUSE_ODIN_DIR="$(cd "$(dirname "$(readlink -f "$DRUSE_ODIN")")" && pwd)"

grep -qE '^request_state :: proc\(ctx: \^Context, \$R: typeid\) -> \^R' "$DRUSE_STATE" ||
  fail "web.request_state is missing its ratified signature"
# The single-type discipline: a typeid stamp+assert, not an untyped bag.
grep -qE 'request_state_type == typeid_of\(R\)' "$DRUSE_STATE" ||
  fail "request_state does not assert the single-type discipline (typeid check missing)"
test -f "$DRUSE_SUITE" || fail "tests/c7-request-state/request_state_test.odin is missing"
env ODIN_ROOT="$DRUSE_ODIN_DIR" "$DRUSE_ODIN" test "$DRUSE_ROOT/tests/c7-request-state" \
  -collection:druse="$DRUSE_ROOT" >/dev/null 2>&1 ||
  fail "the C7 request-state suite did not pass"
echo "C7 control: request_state wired (mw writes -> handler reads), no cross-request leak, single-type discipline enforced; suite green"
