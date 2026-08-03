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

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DRUSE_ROOT"

fail() { echo "WP9-MUTATION-FAIL: $*" >&2; exit 1; }

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

DRUSE_TMP="$(mktemp -d -t druse-wp9-mut-XXXXXXXX)"

# The mutations edit the real sources, so the restore must survive any exit —
# an interrupted run must never leave a weakened guard in the tree.
DRUSE_TOUCHED=""
restore() {
  for f in $DRUSE_TOUCHED; do
    git -C "$DRUSE_ROOT" checkout -- "$f" 2>/dev/null || true
  done
  rm -rf "$DRUSE_TMP"
}
trap restore EXIT

git -C "$DRUSE_ROOT" diff --quiet -- vendor/odin-http ||
  fail "vendor/odin-http has uncommitted changes; this script restores by 'git checkout --' and would discard them"

run_corpus() {
  env ODIN_ROOT="$DRUSE_ODIN_ROOT" PATH="$DRUSE_ODIN_ROOT:/usr/bin:/bin" \
    timeout 300 "$DRUSE_ODIN" test "$DRUSE_ROOT/tests/wp9-wire" \
    "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
    -out:"$DRUSE_TMP/corpus" 2>&1 || true
}

# must_go_red <label> <file> <old> <new>
must_go_red() {
  local label="$1" file="$2"
  DRUSE_TOUCHED="$DRUSE_TOUCHED $file"
  DRUSE_OLD="$3" DRUSE_NEW="$4" DRUSE_FILE="$DRUSE_ROOT/$file" python3 - <<'PY'
import os, sys
p = os.environ['DRUSE_FILE']
s = open(p).read()
old = os.environ['DRUSE_OLD']
if old not in s:
    sys.exit(3)
open(p, 'w').write(s.replace(old, os.environ['DRUSE_NEW'], 1))
PY
  case $? in
    0) ;;
    3) fail "mutation '$label' no longer applies to $file: the guard it weakens has moved or changed shape. Re-point it at the current code rather than deleting it — an unapplied mutation is a control that stopped controlling." ;;
    *) fail "mutation '$label' could not be applied" ;;
  esac

  local out
  out="$(run_corpus)"
  git -C "$DRUSE_ROOT" checkout -- "$file"

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

# Audit H1. The narrowed form is the interesting mutation, not deletion: it is
# what the code ACTUALLY said before patch 38 was written for the egress sink
# (CR/LF/NUL only, on the reasoning that those are the splitting bytes). If the
# corpus only noticed the check being deleted entirely, it would not be holding
# the rule this patch is named after.
must_go_red "field-line control check narrowed to the splitting bytes (H1)" \
  "vendor/odin-http/http.odin" \
  "		if b < 0x20 || b == 0x7f {
			return true
		}" \
  "		if b == 0 && false {
			return true
		}"

# Audit H2, and BOTH halves of it. The second mutation is the one worth having:
# it removes the `OPTIONS *` exemption rather than the check, so the corpus is
# held to the exemption being load-bearing and not merely present. A rule that
# refuses the legal server-capabilities ping would otherwise ship green.
must_go_red "absolute-form authority no longer reconciled with Host (H2)" \
  "vendor/odin-http/server.odin" \
  'if has_host && !ascii_equal_fold(host_field, l.req.url.host) {' \
  'if false && has_host && !ascii_equal_fold(host_field, l.req.url.host) {'

must_go_red "OPTIONS * exemption removed from the authority check (H2)" \
  "vendor/odin-http/server.odin" \
  'is_options_star := rline.method == .Options && rline.target.(string) == "*"' \
  'is_options_star := false && rline.method == .Options && rline.target.(string) == "*"'

# Security F-005, R2-WP06. The mutation restores the exact defect: a header
# block that overruns the budget before any complete line exists goes back to a
# silent close. The corpus case must go red on the STATUS being absent, not on
# some other assertion — `Rejected` in this corpus permits a bare close (WP9
# D6), which is why the case uses `Rejected_With_Status` and why this mutation
# is worth having: without the new outcome, a corpus case for F-005 would have
# been green against the vulnerable server.
must_go_red "oversized header block closes silently again (F-005)" \
  "vendor/odin-http/server.odin" \
  'if err == .Too_Long {' \
  'if false && err == .Too_Long {'

echo "PASS: WP9 raw-wire corpus mutation controls (9 guards, each detected)"
