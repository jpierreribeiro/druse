#!/usr/bin/env bash
# WP68 — honest request decoding and the still-separate schema RED.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP68-CONTROL-FAIL: $*" >&2
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
URUQUIM_TMP="$(mktemp -d -t uruquim-wp68-controls-XXXXXXXX)"
trap 'rm -rf "$URUQUIM_TMP"' EXIT

run_green() { # package, output binary
  env ODIN_ROOT="$URUQUIM_ODIN_ROOT" "$URUQUIM_ODIN" test \
    "$1" "-collection:uruquim=$URUQUIM_ROOT" "-out:$URUQUIM_TMP/$2"
}

run_expected_red() { # package, output binary, diagnostic tokens...
  local package="$1" binary="$2"
  shift 2
  local output
  if output="$(env ODIN_ROOT="$URUQUIM_ODIN_ROOT" "$URUQUIM_ODIN" test \
      "$package" "-collection:uruquim=$URUQUIM_ROOT" \
      "-out:$URUQUIM_TMP/$binary" 2>&1)"; then
    fail "$package unexpectedly passed before WP81 owns schema validation"
  fi
  for token in "$@"; do
    grep -qF "$token" <<<"$output" || {
      echo "$output" >&2
      fail "$package failed for the wrong reason; missing diagnostic token: $token"
    }
  done
}

run_green "$URUQUIM_ROOT/tests/wp67-json-boundary/decoder" decoder-green

# The private rollback must retain the exact public semantics while the
# descriptor A/B remains reproducible.
env ODIN_ROOT="$URUQUIM_ODIN_ROOT" "$URUQUIM_ODIN" test \
  "$URUQUIM_ROOT/tests/wp67-json-boundary/decoder" \
  "-collection:uruquim=$URUQUIM_ROOT" \
  "-define:URUQUIM_JSON_FUSED_TARGET_DESCRIPTORS=false" \
  "-out:$URUQUIM_TMP/descriptor-rollback-green"

run_expected_red \
  "$URUQUIM_ROOT/tests/wp67-json-boundary/schema" schema-red \
  "wp67_an_explicitly_required_field_may_not_be_absent" \
  "wp67_a_declared_range_failure_is_an_invalid_field" \
  "All tests failed."

URUQUIM_INTERNAL="$URUQUIM_TMP/internal-package"
mkdir "$URUQUIM_INTERNAL"
cp "$URUQUIM_ROOT"/web/*.odin "$URUQUIM_INTERNAL/"
cp "$URUQUIM_ROOT"/tests/wp67-json-boundary/internal/*.odin "$URUQUIM_INTERNAL/"
run_green "$URUQUIM_INTERNAL" internal-green

run_green \
  "$URUQUIM_ROOT/tests/wp67-json-boundary/transport-control" \
  transport-control

URUQUIM_ANATOMY="$(env ODIN_ROOT="$URUQUIM_ODIN_ROOT" "$URUQUIM_ODIN" run \
  "$URUQUIM_ROOT/experiments/14-json-failure-anatomy" \
  "-collection:uruquim=$URUQUIM_ROOT" \
  "-out:$URUQUIM_TMP/anatomy")"
for URUQUIM_FACT in \
  "wrong scalar             status=400" \
  "nested mismatch          status=400" \
  "unknown field            status=400" \
  "required absent          status=204" \
  "validation range         status=204" \
  "decoder nil allocator    err=nil name=\"\" tags=[]"; do
  grep -qF "$URUQUIM_FACT" <<<"$URUQUIM_ANATOMY" ||
    fail "anatomy result drifted; missing: $URUQUIM_FACT"
done

# The control is semantic rather than textual: a private mutant package drops
# unknown-field refusal, and the public decoder contract must reject it.
URUQUIM_MUTANT="$URUQUIM_TMP/mutant"
mkdir "$URUQUIM_MUTANT"
cp "$URUQUIM_ROOT"/web/*.odin "$URUQUIM_MUTANT/"
ln -s "$URUQUIM_ROOT/vendor" "$URUQUIM_MUTANT/vendor"
sed -i 's/return json_issue_at(.Unknown_Field, path)/return Json_Decode_Issue{}/' \
  "$URUQUIM_MUTANT/json_decode.odin"
if env ODIN_ROOT="$URUQUIM_ODIN_ROOT" "$URUQUIM_ODIN" test \
    "$URUQUIM_ROOT/tests/wp67-json-boundary/decoder" \
    "-collection:uruquim=$URUQUIM_MUTANT" \
    "-out:$URUQUIM_TMP/mutant" >/dev/null 2>&1; then
  fail "unknown-field mutation unexpectedly passed"
fi

# The integrated descriptor is not accepted on benchmark numbers alone. A
# second mutant zeros every resolved destination offset; the decoder contract
# must become red, proving the corpus actually traverses and checks descriptor
# targets (including the tagged/flattened precedence cases).
URUQUIM_TARGET_MUTANT="$URUQUIM_TMP/target-mutant"
mkdir "$URUQUIM_TARGET_MUTANT"
cp "$URUQUIM_ROOT"/web/*.odin "$URUQUIM_TARGET_MUTANT/"
ln -s "$URUQUIM_ROOT/vendor" "$URUQUIM_TARGET_MUTANT/vendor"
sed -i \
  's/Json_Field_Target{name = name, offset = offset, field_type = field_type}/Json_Field_Target{name = name, offset = 0, field_type = field_type}/' \
  "$URUQUIM_TARGET_MUTANT/json_decode.odin"
grep -q 'Json_Field_Target{name = name, offset = 0' \
  "$URUQUIM_TARGET_MUTANT/json_decode.odin" ||
  fail "fused-target mutation was not applied"
if env ODIN_ROOT="$URUQUIM_ODIN_ROOT" "$URUQUIM_ODIN" test \
    "$URUQUIM_ROOT/tests/wp67-json-boundary/decoder" \
    "-collection:uruquim=$URUQUIM_TARGET_MUTANT" \
    "-out:$URUQUIM_TMP/target-mutant" >/dev/null 2>&1; then
  fail "zero-offset fused-target mutation unexpectedly passed"
fi

echo "wp68: syntax, type/path, unknown-field and allocator taxonomy are green"
echo "wp68: memory and real-socket paths return the same 400 envelope"
echo "wp68: fused target descriptors have rollback and a red offset mutation"
echo "wp68: requiredness and declared validation remain RED for WP81"
echo "PASS: WP68 honest request decoding controls"
