#!/usr/bin/env bash
# C2 — corrective WP for frictions F8-2 (set a response header) and F8-4 (buffered
# binary responder). The ledger growth (75 -> 77) is pinned by the freeze/public-
# api/docs gates. This control pins what those cannot see: that the two symbols
# are WIRED (a set_header that never reaches the wire, or a bytes that drops its
# type, is a decorative signature), and that the injection/reserved-name guards
# actually fire — proven on real (in-memory transport) traffic.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_RESP="$URUQUIM_ROOT/web/respond.odin"
URUQUIM_SUITE="$URUQUIM_ROOT/tests/c2-response-surface/contract_test.odin"

fail() { echo "C2-CONTROL-FAIL: $*" >&2; exit 1; }

URUQUIM_ODIN="${URUQUIM_ODIN_BIN:-odin}"
URUQUIM_ODIN_DIR="$(cd "$(dirname "$(readlink -f "$URUQUIM_ODIN")")" && pwd)"

# 1. The two public procs exist with the ratified signatures.
grep -qE '^set_header :: proc\(ctx: \^Context, name: string, value: string\) -> bool' "$URUQUIM_RESP" ||
  fail "web.set_header is missing its ratified signature"
grep -qE '^bytes :: proc\(ctx: \^Context, status: Status, content_type: string, data: \[\]u8\)' "$URUQUIM_RESP" ||
  fail "web.bytes is missing its ratified signature"

# 2. The injection guard exists (CR/LF/NUL rejected) and reserved names are refused.
grep -qE "b == '\\\\r' \|\| b == '\\\\n' \|\| b == 0" "$URUQUIM_RESP" ||
  fail "the header control-byte (CR/LF/NUL) injection guard is missing"
grep -q 'header_name_is_reserved' "$URUQUIM_RESP" ||
  fail "the reserved-header-name guard is missing"

# 3. The RED test exists and passes on real (in-memory transport) traffic:
#    set_header rides on the wire, injection/reserved are refused, bytes carries a
#    typed binary body, a control-byte content type is a 500.
test -f "$URUQUIM_SUITE" || fail "tests/c2-response-surface/contract_test.odin is missing"
env ODIN_ROOT="$URUQUIM_ODIN_DIR" "$URUQUIM_ODIN" test "$URUQUIM_ROOT/tests/c2-response-surface" \
  -collection:uruquim="$URUQUIM_ROOT" >/dev/null 2>&1 ||
  fail "the C2 response-surface suite did not pass"

echo "C2 control: set_header + bytes wired (header on the wire, typed binary body); injection/reserved-name guards fire; suite green"
