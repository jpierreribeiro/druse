#!/usr/bin/env bash
# WP68 — honest request decoding and the still-separate schema RED.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP68-CONTROL-FAIL: $*" >&2
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
DRUSE_TMP="$(mktemp -d -t druse-wp68-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

run_green() { # package, output binary
  env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
    "$1" "-collection:druse=$DRUSE_ROOT" "-out:$DRUSE_TMP/$2"
}

run_expected_red() { # package, output binary, diagnostic tokens...
  local package="$1" binary="$2"
  shift 2
  local output
  if output="$(env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
      "$package" "-collection:druse=$DRUSE_ROOT" \
      "-out:$DRUSE_TMP/$binary" 2>&1)"; then
    fail "$package unexpectedly passed before WP81 owns schema validation"
  fi
  for token in "$@"; do
    grep -qF "$token" <<<"$output" || {
      echo "$output" >&2
      fail "$package failed for the wrong reason; missing diagnostic token: $token"
    }
  done
}

run_green "$DRUSE_ROOT/tests/wp67-json-boundary/decoder" decoder-green

# The private rollback must retain the exact public semantics while the
# descriptor A/B remains reproducible.
env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
  "$DRUSE_ROOT/tests/wp67-json-boundary/decoder" \
  "-collection:druse=$DRUSE_ROOT" \
  "-define:DRUSE_JSON_FUSED_TARGET_DESCRIPTORS=false" \
  "-out:$DRUSE_TMP/descriptor-rollback-green"

run_expected_red \
  "$DRUSE_ROOT/tests/wp67-json-boundary/schema" schema-red \
  "wp67_an_explicitly_required_field_may_not_be_absent" \
  "wp67_a_declared_range_failure_is_an_invalid_field" \
  "All tests failed."

DRUSE_INTERNAL="$DRUSE_TMP/internal-package"
mkdir "$DRUSE_INTERNAL"
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_INTERNAL/"
cp "$DRUSE_ROOT"/tests/wp67-json-boundary/internal/*.odin "$DRUSE_INTERNAL/"
run_green "$DRUSE_INTERNAL" internal-green

run_green \
  "$DRUSE_ROOT/tests/wp67-json-boundary/transport-control" \
  transport-control

DRUSE_ANATOMY="$(env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" run \
  "$DRUSE_ROOT/experiments/14-json-failure-anatomy" \
  "-collection:druse=$DRUSE_ROOT" \
  "-out:$DRUSE_TMP/anatomy")"
for DRUSE_FACT in \
  "wrong scalar             status=400" \
  "nested mismatch          status=400" \
  "unknown field            status=400" \
  "required absent          status=204" \
  "validation range         status=204" \
  "decoder nil allocator    err=nil name=\"\" tags=[]"; do
  grep -qF "$DRUSE_FACT" <<<"$DRUSE_ANATOMY" ||
    fail "anatomy result drifted; missing: $DRUSE_FACT"
done

# The control is semantic rather than textual: a private mutant package drops
# unknown-field refusal, and the public decoder contract must reject it.
DRUSE_MUTANT="$DRUSE_TMP/mutant"
mkdir "$DRUSE_MUTANT"
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_MUTANT/"
ln -s "$DRUSE_ROOT/vendor" "$DRUSE_MUTANT/vendor"
sed -i 's/return json_issue_at(.Unknown_Field, path)/return Json_Decode_Issue{}/' \
  "$DRUSE_MUTANT/json_decode.odin"
if env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
    "$DRUSE_ROOT/tests/wp67-json-boundary/decoder" \
    "-collection:druse=$DRUSE_MUTANT" \
    "-out:$DRUSE_TMP/mutant" >/dev/null 2>&1; then
  fail "unknown-field mutation unexpectedly passed"
fi

# The integrated descriptor is not accepted on benchmark numbers alone. A
# second mutant zeros every resolved destination offset; the decoder contract
# must become red, proving the corpus actually traverses and checks descriptor
# targets (including the tagged/flattened precedence cases).
DRUSE_TARGET_MUTANT="$DRUSE_TMP/target-mutant"
mkdir "$DRUSE_TARGET_MUTANT"
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_TARGET_MUTANT/"
ln -s "$DRUSE_ROOT/vendor" "$DRUSE_TARGET_MUTANT/vendor"
sed -i \
  's/Json_Field_Target{name = name, offset = offset, field_type = field_type}/Json_Field_Target{name = name, offset = 0, field_type = field_type}/' \
  "$DRUSE_TARGET_MUTANT/json_decode.odin"
grep -q 'Json_Field_Target{name = name, offset = 0' \
  "$DRUSE_TARGET_MUTANT/json_decode.odin" ||
  fail "fused-target mutation was not applied"
if env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
    "$DRUSE_ROOT/tests/wp67-json-boundary/decoder" \
    "-collection:druse=$DRUSE_TARGET_MUTANT" \
    "-out:$DRUSE_TMP/target-mutant" >/dev/null 2>&1; then
  fail "zero-offset fused-target mutation unexpectedly passed"
fi

echo "wp68: syntax, type/path, unknown-field and allocator taxonomy are green"
echo "wp68: memory and real-socket paths return the same 400 envelope"
echo "wp68: fused target descriptors have rollback and a red offset mutation"
echo "wp68: requiredness and declared validation remain RED for WP81"
echo "PASS: WP68 honest request decoding controls"
