#!/usr/bin/env bash
# M9 — the counting-allocator attribution and its negative control.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_SOURCE="$DRUSE_ROOT/vendor/odin-http/scanner.odin"
DRUSE_SUITE="$DRUSE_ROOT/tests/m9-attribution"

fail() {
  echo "M9-CONTROL-FAIL: $*" >&2
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
DRUSE_TMP="$(mktemp -d -t druse-m9-controls-XXXXXXXX)"

restore() {
  git -C "$DRUSE_ROOT" checkout -- vendor/odin-http/scanner.odin 2>/dev/null || true
  rm -rf "$DRUSE_TMP"
}
trap restore EXIT

git -C "$DRUSE_ROOT" diff --quiet -- vendor/odin-http/scanner.odin ||
  fail "scanner.odin has uncommitted changes; the control restores that file"
test -f "$DRUSE_SUITE/attribution_test.odin" ||
  fail "the M9 attribution suite is missing"

env ODIN_ROOT="$DRUSE_ODIN_ROOT" PATH="$DRUSE_ODIN_ROOT:/usr/bin:/bin" \
  timeout 120 "$DRUSE_ODIN" test "$DRUSE_SUITE" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_TMP/baseline" >/dev/null

python3 - "$DRUSE_SOURCE" <<'PY'
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
DRUSE_OUT="$(
  env ODIN_ROOT="$DRUSE_ODIN_ROOT" PATH="$DRUSE_ODIN_ROOT:/usr/bin:/bin" \
    timeout 120 "$DRUSE_ODIN" test "$DRUSE_SUITE" \
    "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
    -out:"$DRUSE_TMP/mutant" 2>&1
)"
DRUSE_RC=$?
set -e
git -C "$DRUSE_ROOT" checkout -- vendor/odin-http/scanner.odin

test "$DRUSE_RC" -ne 0 ||
  fail "the scanner shrink was removed and the attribution suite stayed green"
test "$DRUSE_RC" -ne 124 ||
  fail "the negative control timed out instead of reaching the retention assertion"
grep -qF "body-sized allocations remain live after scanner_reset" <<<"$DRUSE_OUT" || {
  echo "$DRUSE_OUT" >&2
  fail "the negative control failed for the wrong reason"
}

echo "M9 control: production scanner returns body-sized buffers -> GREEN"
echo "M9 control: shrink removed -> RED with live body-sized allocations"
echo "PASS: M9 allocator-attribution controls"
