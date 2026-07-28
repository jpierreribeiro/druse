#!/usr/bin/env bash
# THE FIXES MERGED IN 44bdcda MUST STAY GUARDED.
#
# The July audit merged nine defect fixes and recorded that "5 of 9 carry
# negative controls". A negative control run once, by hand, at merge time is a
# statement about that afternoon; it is not a property of the repository. This
# reverts each fix to its pre-44bdcda behaviour and requires a suite to notice.
#
# WHY IT IS WORTH THE RUNTIME, concretely: the multipart fix's only effective
# guard is `tests/multipart-content`, and that suite was in no gate script at
# all until this session wired it in. Measured with the fix reverted —
# multipart-content fails, `wp63-public-surface` passes all nine cases. So the
# audit's finding S2 was right (the wp63 case named after the defect does not
# exercise it), and for the whole period between the merge and now, the fix was
# protected by a test CI never ran. This script is what makes that stop being
# possible quietly.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$URUQUIM_ROOT"

fail() { echo "MERGED-FIX-MUTATION-FAIL: $*" >&2; exit 1; }

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
URUQUIM_TMP="$(mktemp -d -t uruquim-merged-mut-XXXXXXXX)"

URUQUIM_TOUCHED=""
restore() {
  for f in $URUQUIM_TOUCHED; do
    git -C "$URUQUIM_ROOT" checkout -- "$f" 2>/dev/null || true
  done
  rm -rf "$URUQUIM_TMP"
}
trap restore EXIT

git -C "$URUQUIM_ROOT" diff --quiet -- web vendor ||
  fail "web/ or vendor/ has uncommitted changes; this script restores by 'git checkout --' and would discard them"

# Only EXTERNAL suites here: a `package web` internal suite cannot be built
# standalone, and its build error would read as "the mutation did not compile".
run_suite() {
  env ODIN_ROOT="$URUQUIM_ODIN_ROOT" PATH="$URUQUIM_ODIN_ROOT:/usr/bin:/bin" \
    timeout 300 "$URUQUIM_ODIN" test "$URUQUIM_ROOT/tests/$1" \
    "-collection:uruquim=$URUQUIM_ROOT" -define:ODIN_TEST_THREADS=1 \
    -out:"$URUQUIM_TMP/$(echo "$1" | tr '/' '_')" 2>&1 || true
}

# must_go_red <label> <file> <old> <new> <suite>
must_go_red() {
  local label="$1" file="$2" suite="$5"
  URUQUIM_TOUCHED="$URUQUIM_TOUCHED $file"
  URUQUIM_OLD="$3" URUQUIM_NEW="$4" URUQUIM_FILE="$URUQUIM_ROOT/$file" python3 - <<'PY'
import os, sys
p = os.environ['URUQUIM_FILE']
s = open(p).read()
if os.environ['URUQUIM_OLD'] not in s:
    sys.exit(3)
open(p, 'w').write(s.replace(os.environ['URUQUIM_OLD'], os.environ['URUQUIM_NEW'], 1))
PY
  case $? in
    0) ;;
    3) fail "mutation '$label' no longer applies to $file: the fix it reverts has moved or changed shape. Re-point it at the current code — an unapplied mutation is a control that stopped controlling." ;;
    *) fail "mutation '$label' could not be applied" ;;
  esac

  local out; out="$(run_suite "$suite")"
  git -C "$URUQUIM_ROOT" checkout -- "$file"

  if grep -qE "Syntax Error|Error: " <<<"$out"; then
    fail "mutation '$label' did not compile; it must revert the fix, not break the build"
  fi
  if ! grep -qE "tests? failed|test failed" <<<"$out"; then
    fail "mutation '$label' SURVIVED: tests/$suite stayed green with that merged fix reverted. The fix is unguarded — whatever was run by hand at merge time is not protecting it now."
  fi
  echo "merged-fix: $label -> tests/$suite RED as required"
}

# 44bdcda fix 2 — integer range bypass via Float/String tokens.
must_go_red "JSON integer range bound (i8)" \
  "web/json_decode.odin" \
  'case 1:
		return signed ? (value >= -128 && value <= 127) : (value >= 0 && value <= 255)' \
  'case 1:
		return true' \
  "wp67-json-boundary/decoder"

# 44bdcda fix 5 — bare LF accepted as a line terminator.
must_go_red "bare LF refused as a line terminator" \
  "vendor/odin-http/scanner.odin" \
  "		case '\n':
			// A bare LF: the preceding byte was not a CR, or we would have taken
			// the CR branch below and consumed the pair there.
			return 0, nil, .Advanced_Too_Far, false" \
  "		case '\n':
			return i + 1, data[:i], nil, false" \
  "wp9-wire"

# 44bdcda fix 7 — HEAD announces the GET's content-length, not 0.
must_go_red "HEAD carries the suppressed body length" \
  "web/serve.odin" \
  'out.suppressed_body_len = len(ctx.private.response.body)' \
  'out.suppressed_body_len = 0' \
  "head-content-length"

# 44bdcda fix 8 — a `\r\n--` is only a delimiter when the boundary follows it.
# Guarded ONLY by tests/multipart-content; wp63-public-surface passes all nine
# of its cases with this reverted (finding S2).
must_go_red "multipart delimiter requires the boundary" \
  "web/multipart.odin" \
  'if strings.has_prefix(text[abs + 2:], delimiter) {
				content_end = abs
				break
			}' \
  'if true {
				content_end = abs
				break
			}' \
  "multipart-content"

echo "PASS: merged-fix mutation controls (4 of the 44bdcda fixes, each detected)"
