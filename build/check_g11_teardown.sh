#!/usr/bin/env bash
# G-11 teardown-cost gate (planning/public-api-guardrails.md).
#
# The guardrail states, as ratified in WP3:
#
#   "the recorder teardown MUST be registered lazily — a private proc-pointer
#    set only inside `test_request` — so that when `test_request` is
#    dead-code-eliminated the teardown goes with it. The gate asserts this with
#    `nm`: a minimal application that never calls `test_request` links ZERO
#    `web/testing` teardown symbols."
#
# This script IS that gate. It was promised by the guardrail but never written,
# so the claim went unenforced and the code drifted from it: `web.destroy` called
# `testing.destroy` directly, a static edge that linked the recorder teardown
# into every binary. Measured on 819fdc7 before the fix, a minimal application
# that never tests linked FOUR teardown symbols (`web_testing::destroy`,
# `recorder_destroy`, and the `delete_dynamic_array`/`delete_slice`
# instantiations) and was 608 bytes larger.
#
# It builds two real consumers and inspects their symbol tables:
#
#   NEGATIVE — an application that never calls `web.test_request` must link
#              ZERO `web/testing` teardown symbols.
#   POSITIVE — an application that DOES call it must link them.
#
# The positive control is not decoration. Without it, a typo in the symbol
# pattern would make the negative assertion pass against every possible binary,
# and the gate would certify a property it never actually measured.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "G11-FAIL: $*" >&2
  exit 1
}

test -n "${DRUSE_COMPILER:-}" ||
  fail "DRUSE_COMPILER is not set; run this through build/check.sh"
test -x "$DRUSE_COMPILER" || fail "compiler is not executable: $DRUSE_COMPILER"
DRUSE_COMPILER_DIR="$(cd "$(dirname "$DRUSE_COMPILER")" && pwd)"

command -v nm >/dev/null 2>&1 ||
  fail "nm not found; the G-11 teardown assertion cannot be measured without it"

# Any symbol from the machinery package. The teardown routines are the ones the
# guardrail names, but the generic instantiations (`delete_dynamic_array` over
# `Recorded`, `delete_slice` over `Header`) are linked by the same static edge
# and are equally a shipped cost, so the assertion covers the whole package.
DRUSE_G11_PATTERN='web_testing|recorder_destroy'

DRUSE_G11_TMP="$(mktemp -d -t druse-g11-XXXXXXXX)"
trap 'rm -rf "$DRUSE_G11_TMP"' EXIT

# Each consumer gets its own tree with a real copy of the shipped package, so
# what is measured is the package as it would actually ship.
druse_g11_build() { # label main-source-file
  # Declared separately on purpose: within a single `local` statement bash does
  # not yet see the variables assigned to its left, so `tree` would expand
  # `$label` as empty and, under `set -u`, abort.
  local label="$1"
  local main_source="$2"
  local tree="$DRUSE_G11_TMP/$label"
  mkdir -p "$tree/app" "$tree/vendor"
  cp -r "$DRUSE_ROOT/web" "$tree/web"
  # WP8: `web` imports web/internal/transport, which imports the vendored
  # backend, so a consumer tree must carry the vendor snapshot too.
  cp -r "$DRUSE_ROOT/vendor/odin-http" "$tree/vendor/odin-http"
  cp "$main_source" "$tree/app/main.odin"
  ( cd "$tree" && env ODIN_ROOT="$DRUSE_COMPILER_DIR" \
      PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
      "$DRUSE_COMPILER" build app "-collection:druse=$tree" -out:app.bin ) ||
    fail "the $label consumer did not build"
  printf '%s' "$tree/app.bin"
}

druse_g11_symbols() { # binary
  nm "$1" 2>/dev/null | grep -cE "$DRUSE_G11_PATTERN" || true
}

# --- NEGATIVE: never calls test_request -------------------------------------
cat >"$DRUSE_G11_TMP/never_tests.odin" <<'ODIN'
package main

import web "druse:web"

main :: proc() {
	app := web.app()
	defer web.destroy(&app)
	web.serve(&app, 8080)
}
ODIN

DRUSE_G11_NEG="$(druse_g11_build never-tests "$DRUSE_G11_TMP/never_tests.odin")"
DRUSE_G11_NEG_COUNT="$(druse_g11_symbols "$DRUSE_G11_NEG")"
DRUSE_G11_NEG_SIZE="$(stat -c%s "$DRUSE_G11_NEG")"

if test "$DRUSE_G11_NEG_COUNT" -ne 0; then
  echo "--- web/testing symbols linked into an application that never tests ---" >&2
  nm "$DRUSE_G11_NEG" | grep -E "$DRUSE_G11_PATTERN" | sed 's/^[0-9a-f]* //' >&2
  fail "an application that never calls test_request links $DRUSE_G11_NEG_COUNT web/testing symbol(s); the teardown must be registered lazily inside test_request so dead-code elimination removes it (planning/public-api-guardrails.md G-11)"
fi

# --- POSITIVE control: does call test_request -------------------------------
cat >"$DRUSE_G11_TMP/does_test.odin" <<'ODIN'
package main

import "core:fmt"
import web "druse:web"

main :: proc() {
	app := web.app()
	defer web.destroy(&app)
	res := web.test_request(&app, .GET, "/health")
	fmt.println(res.status, res.body)
}
ODIN

DRUSE_G11_POS="$(druse_g11_build does-test "$DRUSE_G11_TMP/does_test.odin")"
DRUSE_G11_POS_COUNT="$(druse_g11_symbols "$DRUSE_G11_POS")"
DRUSE_G11_POS_SIZE="$(stat -c%s "$DRUSE_G11_POS")"

if test "$DRUSE_G11_POS_COUNT" -eq 0; then
  fail "an application that DOES call test_request links no web/testing symbol either; the pattern /$DRUSE_G11_PATTERN/ matches nothing, so the negative assertion above proved nothing"
fi

# --- MUTATION: the gate must catch the regression it exists to prevent -------
#
# Restore the exact defect this guardrail is about — `destroy` calling
# `testing.destroy` directly instead of through the lazily-registered pointer —
# and confirm the teardown symbols come back. Without this, a future refactor
# could make the elimination accidental (or make the negative case unbuildable)
# and the gate would keep reporting PASS for the wrong reason.
mkdir -p "$DRUSE_G11_TMP/mutated" "$DRUSE_G11_TMP/mutated/vendor"
cp -r "$DRUSE_ROOT/web" "$DRUSE_G11_TMP/mutated/web"
cp -r "$DRUSE_ROOT/vendor/odin-http" "$DRUSE_G11_TMP/mutated/vendor/odin-http"
mkdir -p "$DRUSE_G11_TMP/mutated/app"
cp "$DRUSE_G11_TMP/never_tests.odin" "$DRUSE_G11_TMP/mutated/app/main.odin"

python3 - "$DRUSE_G11_TMP/mutated/web/app.odin" <<'PY'
import re
import sys

# The mutation is applied STRUCTURALLY, not against one exact spelling: the
# guarded lazy call is matched with whitespace-insensitive patterns and a
# receiver name captured rather than assumed, so reformatting `destroy` or
# renaming its private parameter does not break this probe (WP16). What it
# looks for is the shape the guardrail is about:
#
#     if <recv>.private.test_teardown != nil {
#         <recv>.private.test_teardown(&<recv>.private.test_transport)
#     }
#
# and it replaces that with the direct static edge the guardrail forbids.
path = sys.argv[1]
source = open(path).read()
pattern = re.compile(
    r"if\s+([A-Za-z_][A-Za-z0-9_]*)\.private\.test_teardown\s*!=\s*nil\s*\{\s*"
    r"\1\.private\.test_teardown\(\s*&\1\.private\.test_transport\s*\)\s*,?\s*\}"
)
m = pattern.search(source)
if m is None:
    sys.exit(
        "BROKEN PROBE: the guarded lazy-teardown call was not found in "
        "web/app.odin under any formatting; the G-11 static-edge mutation "
        "cannot be applied, so this gate would prove nothing"
    )
recv = m.group(1)
open(path, "w").write(
    source[: m.start()]
    + "testing.destroy(&%s.private.test_transport)" % recv
    + source[m.end() :]
)
PY

if ! ( cd "$DRUSE_G11_TMP/mutated" && env ODIN_ROOT="$DRUSE_COMPILER_DIR" \
    PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
    "$DRUSE_COMPILER" build app "-collection:druse=$DRUSE_G11_TMP/mutated" \
    -out:app.bin >/dev/null 2>&1 ); then
  fail "the mutated consumer did not build; the mutation check proved nothing"
fi

DRUSE_G11_MUT_COUNT="$(druse_g11_symbols "$DRUSE_G11_TMP/mutated/app.bin")"
if test "$DRUSE_G11_MUT_COUNT" -eq 0; then
  fail "reinstating the static destroy -> testing.destroy edge did NOT relink the teardown; this gate is not measuring what it claims (planning/public-api-guardrails.md G-11)"
fi

echo "G-11: application that never tests  -> 0 web/testing symbols, $DRUSE_G11_NEG_SIZE bytes"
echo "G-11: application that does test    -> $DRUSE_G11_POS_COUNT web/testing symbols, $DRUSE_G11_POS_SIZE bytes"
echo "G-11: static-edge mutation          -> $DRUSE_G11_MUT_COUNT web/testing symbols (correctly rejected)"
echo "PASS: the test-support teardown is eliminated from applications that never test (G-11)"

rm -rf "$DRUSE_G11_TMP"
trap - EXIT
