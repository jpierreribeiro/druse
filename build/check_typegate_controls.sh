#!/usr/bin/env bash
# TYPE GATE — the controls that make the adopted default an executable fact.
#
# `DRUSE_JSON_TYPE_GATE` decides whether the response body is re-parsed after
# marshalling. The pass exists to catch exactly one condition — a non-finite
# float, which the pinned marshaller writes as a BARE `NaN`/`Inf` token that is
# not valid JSON (NUM-001, `planning/numeric-contract.md`). The gate skips the
# pass for types that cannot hold a float, decided once per instantiation.
#
# Adopting it as the default means two things must stay true and be provable:
# the skip must never skip a type that CAN carry the token, and the build-time
# rollback must still be a real validation rather than a decorative branch.
#
#   0  the adopted default is pinned verbatim in the source   (static)
#   1  gate ON  — the NUM-001 contract is green as shipped     (positive)
#   2  gate OFF — the rollback is green too                    (positive)
#   3  the walk stops recognising floats -> NUM-001 MUST go red
#   4  the gate's polarity is inverted   -> NUM-001 MUST go red
#   5  the rollback branch stops validating -> NUM-001 MUST go red with the
#      flag OFF, which is what proves the rollback is not a no-op
#
# Controls 1 and 2 are the POSITIVE cases required by
# `planning/diagnosability.md`: without them a typo in a mutation would let
# every probe "pass" against a suite that never ran.
#
# Needs the pinned compiler; without one this reports BLOCKED and exits 2 — it
# never reports a control it did not run.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "TYPEGATE-CONTROL-FAIL: $*" >&2
  exit 1
}

DRUSE_TG_ODIN="${DRUSE_ODIN_BIN:-}"
if test -z "$DRUSE_TG_ODIN" && command -v odin >/dev/null 2>&1; then
  DRUSE_TG_ODIN="$(command -v odin)"
fi
if test -z "$DRUSE_TG_ODIN" && test -x /tmp/druse-toolchain/odin; then
  DRUSE_TG_ODIN=/tmp/druse-toolchain/odin
fi
if test -z "$DRUSE_TG_ODIN"; then
  echo "TYPE GATE CONTROLS -> BLOCKED: no Odin toolchain found (set DRUSE_ODIN_BIN). NOTHING RAN." >&2
  exit 2
fi
DRUSE_TG_ODIN="$(readlink -f "$DRUSE_TG_ODIN")"
DRUSE_TG_ODIN_ROOT="$(cd "$(dirname "$DRUSE_TG_ODIN")" && pwd)"

DRUSE_TG_TMP="$(mktemp -d -t druse-typegate-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TG_TMP"' EXIT

NUM001="wp6_public_surface.wp6_num001_non_finite_float_yields_a_complete_500"

# A mutable collection: `druse:web` resolves into the copy, so a mutation to
# web/ is seen by the UNMODIFIED public-surface suite. The shape is
# `check_wp71_controls.sh::make_mutant_collection`.
mutant_collection() { # name
  local dest="$DRUSE_TG_TMP/$1"
  mkdir -p "$dest/vendor"
  cp -R "$DRUSE_ROOT/web" "$dest/web"
  cp -R "$DRUSE_ROOT/vendor/odin-http" "$dest/vendor/odin-http"
  printf '%s' "$dest"
}

run_num001() { # collection, extra-define-or-empty, binary
  local defines=()
  test -z "$2" || defines+=("$2")
  timeout 120 env ODIN_ROOT="$DRUSE_TG_ODIN_ROOT" "$DRUSE_TG_ODIN" test \
    "$DRUSE_ROOT/tests/wp6-public-surface" \
    "-collection:druse=$1" -define:ODIN_TEST_THREADS=1 \
    "-define:ODIN_TEST_NAMES=$NUM001" \
    "${defines[@]}" \
    "-out:$DRUSE_TG_TMP/$3" 2>&1
}

assert_green() { # collection, define, binary, label
  local out
  if ! out="$(run_num001 "$1" "$2" "$3")"; then
    echo "$out" >&2
    fail "BROKEN PROBE ($4): the NUM-001 contract is not green BEFORE any mutation"
  fi
  grep -qE 'Finished [1-9][0-9]* tests?' <<<"$out" ||
    { echo "$out" >&2
      fail "BROKEN PROBE ($4): the selection ran no test; a stale test name would fake a pass"; }
  echo "CONTROL $4 -> GREEN as required"
}

must_go_red() { # collection, define, binary, label
  local out
  if out="$(run_num001 "$1" "$2" "$3")"; then
    echo "$out" >&2
    fail "control '$4' stayed GREEN under the mutation; the suite does not catch this defect"
  fi
  echo "CONTROL $4 -> RED as required"
}

assert_mutated() { # label, file, before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

# --- 0. the adopted default, pinned verbatim ---------------------------------
# A default with no assertion is a default that walks back on the next refactor
# and nobody notices. Same mechanism as `check_wp71_controls.sh` uses for
# DRUSE_DEDICATED_ACCEPT.
grep -qF 'JSON_TYPE_GATE :: #config(DRUSE_JSON_TYPE_GATE, true)' \
  "$DRUSE_ROOT/web/respond.odin" ||
  fail "the measured per-type validation gate must remain the adopted default"
echo "CONTROL 0 -> the adopted default is pinned in the source"

# --- 0b. the own-marshal default, pinned the same way ------------------------
# Adopted on the 2026-07-30 measurements: p50 265 -> 154 us, ceiling 26,716 ->
# 65,336/s, and 360 -> 150 us against six peers on the byte-identical row, where
# it also holds the shortest tail of the seven. A default with no assertion is a
# default that walks back on the next refactor and nobody notices.
grep -qF 'JSON_OWN_MARSHAL :: #config(DRUSE_JSON_OWN_MARSHAL, true)' \
  "$DRUSE_ROOT/web/json_encode.odin" ||
  fail "the measured Druse-owned marshal walk must remain the adopted default"
echo "CONTROL 0b -> the own-marshal default is pinned in the source"

# --- 1 & 2. the positive cases -----------------------------------------------
BASE="$(mutant_collection baseline)"
assert_green "$BASE" "" baseline-on "1: gate ON, NUM-001 green as shipped"
assert_green "$BASE" "-define:DRUSE_JSON_TYPE_GATE=false" baseline-off \
  "2: gate OFF, the rollback is green too"
assert_green "$BASE" "-define:DRUSE_JSON_OWN_MARSHAL=false" baseline-stdlib \
  "2b: own marshal OFF, the stdlib path is still green"

# --- 3. the walk stops recognising floats ------------------------------------
# The single defect the gate could introduce: answering "cannot hold a float"
# for a type that can. The pass is then skipped and the bare Inf token reaches
# the wire.
T3="$(mutant_collection blindfloat)"
H3="$(md5sum "$T3/web/respond.odin" | cut -d' ' -f1)"
python3 - "$T3/web/respond.odin" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = ("\tcase reflect.Type_Info_Float, reflect.Type_Info_Complex, "
       "reflect.Type_Info_Quaternion:\n\t\treturn true\n")
assert old in s, "pattern not found: the float arm of the walk"
open(p, "w").write(s.replace(old, old.replace("return true", "return false"), 1))
PY
assert_mutated "3: floats unrecognised" "$T3/web/respond.odin" "$H3"
must_go_red "$T3" "" blind-float "3: the walk blind to floats -> NUM-001"

# --- 4. the gate's polarity is inverted --------------------------------------
# 1 means validate and 2 means skip. Swapping them validates exactly the types
# that cannot produce the token and skips the ones that can.
T4="$(mutant_collection polarity)"
H4="$(md5sum "$T4/web/respond.odin" | cut -d' ' -f1)"
python3 - "$T4/web/respond.odin" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\t\tif gate == 1 {\n\t\t\tjson_invalid = !encoding_json.is_valid(data, .JSON)\n\t\t}\n"
assert old in s, "pattern not found: the gate's validate arm"
open(p, "w").write(s.replace(old, old.replace("gate == 1", "gate == 2"), 1))
PY
assert_mutated "4: polarity inverted" "$T4/web/respond.odin" "$H4"
must_go_red "$T4" "" polarity "4: gate polarity inverted -> NUM-001"

# --- 5. the rollback branch stops validating ---------------------------------
# The rollback exists so the adopted default can be backed out for one release.
# A rollback that silently does nothing is worse than no rollback, because it
# reports success. This proves the `else` arm is a real validation.
T5="$(mutant_collection rollback)"
H5="$(md5sum "$T5/web/respond.odin" | cut -d' ' -f1)"
python3 - "$T5/web/respond.odin" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\t} else {\n\t\tjson_invalid = !encoding_json.is_valid(data, .JSON)\n\t}\n"
assert old in s, "pattern not found: the rollback arm"
open(p, "w").write(s.replace(old, "\t} else {\n\t}\n", 1))
PY
assert_mutated "5: rollback hollowed" "$T5/web/respond.odin" "$H5"
must_go_red "$T5" "-define:DRUSE_JSON_TYPE_GATE=false" rollback-hollow \
  "5: the rollback stops validating -> NUM-001 with the flag OFF"

echo "typegate: the adopted default is pinned and both states are green"
echo "typegate: a walk blind to floats, an inverted polarity and a hollow rollback are each caught"
echo "PASS: per-type JSON validation gate controls"
