#!/usr/bin/env bash
# M9 — the counting-allocator attribution and its negative control.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_SOURCE="$URUQUIM_ROOT/vendor/odin-http/scanner.odin"
URUQUIM_SUITE="$URUQUIM_ROOT/tests/m9-attribution"

fail() {
  echo "M9-CONTROL-FAIL: $*" >&2
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
URUQUIM_TMP="$(mktemp -d -t uruquim-m9-controls-XXXXXXXX)"

restore() {
  git -C "$URUQUIM_ROOT" checkout -- vendor/odin-http/scanner.odin 2>/dev/null || true
  rm -rf "$URUQUIM_TMP"
}
trap restore EXIT

git -C "$URUQUIM_ROOT" diff --quiet -- vendor/odin-http/scanner.odin ||
  fail "scanner.odin has uncommitted changes; the control restores that file"
test -f "$URUQUIM_SUITE/attribution_test.odin" ||
  fail "the M9 attribution suite is missing"

env ODIN_ROOT="$URUQUIM_ODIN_ROOT" PATH="$URUQUIM_ODIN_ROOT:/usr/bin:/bin" \
  timeout 120 "$URUQUIM_ODIN" test "$URUQUIM_SUITE" \
  "-collection:uruquim=$URUQUIM_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$URUQUIM_TMP/baseline" >/dev/null

python3 - "$URUQUIM_SOURCE" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()
old = "\t\tdelete(s.buf)\n\t\ts.buf = nil"
new = "\t\t// M9 negative control: keep the large allocation alive.\n\t\ts.buf = s.buf"
if old not in s:
    raise SystemExit(3)
p.write_text(s.replace(old, new, 1))
PY
case $? in
  0) ;;
  3) fail "the scanner mutation no longer applies; re-point the control at the shrink" ;;
  *) fail "could not apply the scanner mutation" ;;
esac

set +e
URUQUIM_OUT="$(
  env ODIN_ROOT="$URUQUIM_ODIN_ROOT" PATH="$URUQUIM_ODIN_ROOT:/usr/bin:/bin" \
    timeout 120 "$URUQUIM_ODIN" test "$URUQUIM_SUITE" \
    "-collection:uruquim=$URUQUIM_ROOT" -define:ODIN_TEST_THREADS=1 \
    -out:"$URUQUIM_TMP/mutant" 2>&1
)"
URUQUIM_RC=$?
set -e
git -C "$URUQUIM_ROOT" checkout -- vendor/odin-http/scanner.odin

test "$URUQUIM_RC" -ne 0 ||
  fail "the scanner shrink was removed and the attribution suite stayed green"
test "$URUQUIM_RC" -ne 124 ||
  fail "the negative control timed out instead of reaching the retention assertion"
grep -qF "body-sized allocations remain live after scanner_reset" <<<"$URUQUIM_OUT" || {
  echo "$URUQUIM_OUT" >&2
  fail "the negative control failed for the wrong reason"
}

echo "M9 control: production scanner returns body-sized buffers -> GREEN"
echo "M9 control: shrink removed -> RED with live body-sized allocations"
echo "PASS: M9 allocator-attribution controls"
