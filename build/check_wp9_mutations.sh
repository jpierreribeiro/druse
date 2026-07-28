#!/usr/bin/env bash
# WP9 raw-wire corpus — MUTATION CONTROLS.
#
# WHY THIS EXISTS. `tests/wp9-wire` could not report a failure from the commit
# that created it until the logger filter was fixed, so not one of its 38
# smuggling cases had ever been shown to catch anything. Green told us nothing.
# This weakens the product guards the corpus names, one at a time, and requires
# the corpus to go RED for each. A case that cannot detect the removal of the
# rule it is named after is the S2 defect — "a test whose name is broader than
# its evidence" — and this is how that gets measured instead of assumed.
#
# It already found one: "whitespace before the header colon is rejected" sent
# `Host : localhost`, so with the rule removed the name parsed as "Host " and
# the request was refused for having NO HOST HEADER instead. It passed with the
# guard and without it. The case now spaces a non-Host header.
#
# NOT EVERY GUARD IS LISTED, and the omissions are deliberate. Two mutations
# were measured as behaviourally INERT — with `_is_plain_decimal` neutered and
# with the obs-fold check neutered, the malformed requests still get the same
# 400, because another rule catches them first. A gate cannot require the
# corpus to notice a change that changes nothing. They are redundant
# defence-in-depth, which is fine; they are simply not mutation-testable here.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$URUQUIM_ROOT"

fail() { echo "WP9-MUTATION-FAIL: $*" >&2; exit 1; }

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

URUQUIM_TMP="$(mktemp -d -t uruquim-wp9-mut-XXXXXXXX)"

# The mutations edit the real sources, so the restore must survive any exit —
# an interrupted run must never leave a weakened guard in the tree.
URUQUIM_TOUCHED=""
restore() {
  for f in $URUQUIM_TOUCHED; do
    git -C "$URUQUIM_ROOT" checkout -- "$f" 2>/dev/null || true
  done
  rm -rf "$URUQUIM_TMP"
}
trap restore EXIT

git -C "$URUQUIM_ROOT" diff --quiet -- vendor/odin-http ||
  fail "vendor/odin-http has uncommitted changes; this script restores by 'git checkout --' and would discard them"

run_corpus() {
  env ODIN_ROOT="$URUQUIM_ODIN_ROOT" PATH="$URUQUIM_ODIN_ROOT:/usr/bin:/bin" \
    timeout 300 "$URUQUIM_ODIN" test "$URUQUIM_ROOT/tests/wp9-wire" \
    "-collection:uruquim=$URUQUIM_ROOT" -define:ODIN_TEST_THREADS=1 \
    -out:"$URUQUIM_TMP/corpus" 2>&1 || true
}

# must_go_red <label> <file> <old> <new>
must_go_red() {
  local label="$1" file="$2"
  URUQUIM_TOUCHED="$URUQUIM_TOUCHED $file"
  URUQUIM_OLD="$3" URUQUIM_NEW="$4" URUQUIM_FILE="$URUQUIM_ROOT/$file" python3 - <<'PY'
import os, sys
p = os.environ['URUQUIM_FILE']
s = open(p).read()
old = os.environ['URUQUIM_OLD']
if old not in s:
    sys.exit(3)
open(p, 'w').write(s.replace(old, os.environ['URUQUIM_NEW'], 1))
PY
  case $? in
    0) ;;
    3) fail "mutation '$label' no longer applies to $file: the guard it weakens has moved or changed shape. Re-point it at the current code rather than deleting it — an unapplied mutation is a control that stopped controlling." ;;
    *) fail "mutation '$label' could not be applied" ;;
  esac

  local out
  out="$(run_corpus)"
  git -C "$URUQUIM_ROOT" checkout -- "$file"

  if grep -qE "Syntax Error|Error: " <<<"$out"; then
    fail "mutation '$label' did not compile; it must weaken the guard, not break the build"
  fi
  if ! grep -qE "tests? failed|test failed" <<<"$out"; then
    fail "$(printf 'mutation %s SURVIVED: the raw-wire corpus stayed green with that guard removed.\nEither no case exercises it, or the case named after it is passing for a different reason — which is exactly what "whitespace before the header colon" did (it spaced the Host header, so the request was refused for a missing Host instead).' "'$label'")"
  fi
  echo "wp9-mutation: $label -> corpus RED as required"
}

must_go_red "Content-Length 19-digit overflow guard removed" \
  "vendor/odin-http/body.odin" \
  'if sig > 19 {' \
  'if false {'

must_go_red "CL+TE smuggling pair accepted" \
  "vendor/odin-http/request.odin" \
  'if headers_has_unsafe(headers^, "transfer-encoding") && headers_has_unsafe(headers^, "content-length") {
		return false
	}' \
  'if false {
		return false
	}'

must_go_red "chunk size accepts non-hex" \
  "vendor/odin-http/body.odin" \
  "if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') {
			continue
		}
		return false" \
  "if true {
			continue
		}
		return false"

must_go_red "whitespace before the header colon accepted" \
  "vendor/odin-http/http.odin" \
  "(line[colon - 1] != ' ') or_return" \
  "(true) or_return"

must_go_red "transfer-coding matched by suffix instead of token (H3)" \
  "vendor/odin-http/request.odin" \
  'return count == 1 && last_is_chunked' \
  'return strings.has_suffix(enc, "chunked")'

echo "PASS: WP9 raw-wire corpus mutation controls (5 guards, each detected)"
