#!/usr/bin/env bash
# WP19 — the six required header-lookup mutation controls, as one executable
# run.
#
# The WP17/WP18 protocol, unchanged: each control re-creates a specific defect
# in a THROWAWAY copy of the shipped sources and requires the WP19 test suite
# to catch it. Every probe (a) runs its selected tests UNMUTATED first and
# requires them green with at least one test executed, (b) asserts its own
# edit applied by md5 — BROKEN PROBE otherwise, never a false verdict — and
# (c) requires the selected tests red after the mutation.
#
#   1  case-SENSITIVE name comparison        -> case-insensitivity test MUST go red
#   2  duplicates: LAST occurrence wins      -> first-wins test MUST go red
#   3  bearer trims token whitespace         -> strict-grammar test MUST go red
#   4  bearer scheme compared case-SENSITIVELY -> scheme-fold test MUST go red
#   5  overlay ignored by header()           -> overlay-shadowing test MUST go red
#   6  facade drops the OWS trim             -> line-splitting test MUST go red
#
# All six need the pinned compiler; without one this script reports BLOCKED
# and exits 2. On-demand, like the WP16-WP18 controls — not a per-gate step.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP19-CONTROL-FAIL: $*" >&2
  exit 1
}

URUQUIM_W19_ODIN="${URUQUIM_ODIN_BIN:-}"
if test -z "$URUQUIM_W19_ODIN" && command -v odin >/dev/null 2>&1; then
  URUQUIM_W19_ODIN="$(command -v odin)"
fi
if test -z "$URUQUIM_W19_ODIN" && test -x /tmp/uruquim-odin-toolchain/odin; then
  URUQUIM_W19_ODIN=/tmp/uruquim-odin-toolchain/odin
fi
if test -z "$URUQUIM_W19_ODIN"; then
  echo "WP19 CONTROLS -> BLOCKED: no Odin toolchain found (set URUQUIM_ODIN_BIN). NOTHING RAN." >&2
  exit 2
fi

URUQUIM_W19_TMP="$(mktemp -d -t uruquim-wp19-controls-XXXXXXXX)"
trap 'rm -rf "$URUQUIM_W19_TMP"' EXIT

internal_tree() { # name
  local t="$URUQUIM_W19_TMP/$1"
  mkdir -p "$t"
  cp "$URUQUIM_ROOT"/web/*.odin "$t/"
  cp "$URUQUIM_ROOT"/tests/wp19-internal/*.odin "$t/"
  printf '%s' "$t"
}

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

run_selected() { # tree test-names
  env -u ODIN_ROOT "$URUQUIM_W19_ODIN" test "$1" \
    "-collection:uruquim=$URUQUIM_ROOT" -out:"$URUQUIM_W19_TMP/runner" \
    "-define:ODIN_TEST_NAMES=$2" 2>&1
}

assert_green_baseline() { # tree test-names label
  local out
  if ! out="$(run_selected "$1" "$2")"; then
    echo "$out" >&2
    fail "BROKEN PROBE ($3): the selected tests are not green BEFORE the mutation"
  fi
  grep -qE 'Finished [1-9][0-9]* tests?' <<<"$out" ||
    { echo "$out" >&2; fail "BROKEN PROBE ($3): the selection ran no test; a stale test name would fake a pass"; }
}

must_go_red() { # tree test-names label
  local out
  if out="$(run_selected "$1" "$2")"; then
    echo "$out" >&2
    fail "control '$3' stayed GREEN under the mutation; the suite does not catch this defect"
  fi
  echo "CONTROL $3 -> RED as required"
}

# --- 1. case-SENSITIVE name comparison ---------------------------------------
# Deleting the fold turns ascii_fold_equal into a byte compare; "x-api-key"
# must then miss "X-API-KEY".
NAMES="web.wp19_header_names_are_case_insensitive_both_directions"
T="$(internal_tree casesensitive)"
assert_green_baseline "$T" "$NAMES" "1: case-sensitive compare"
H="$(md5sum "$T/header_lookup.odin" | cut -d' ' -f1)"
sed -z -i "s/\t\tif ca >= 'A' \&\& ca <= 'Z' {\n\t\t\tca += 'a' - 'A'\n\t\t}\n\t\tif cb >= 'A' \&\& cb <= 'Z' {\n\t\t\tcb += 'a' - 'A'\n\t\t}\n//" \
  "$T/header_lookup.odin"
assert_mutated "case-sensitive compare" "$T/header_lookup.odin" "$H"
must_go_red "$T" "$NAMES" "1: case-sensitive compare -> case-insensitivity test"

# --- 2. duplicates: LAST occurrence wins -------------------------------------
NAMES="web.wp19_header_scan_takes_the_first_matching_pair"
T="$(internal_tree lastwins)"
assert_green_baseline "$T" "$NAMES" "2: last occurrence wins"
H="$(md5sum "$T/header_lookup.odin" | cut -d' ' -f1)"
python3 - "$T/header_lookup.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	for pair in ctx.request.headers.private.pairs {
		if ascii_fold_equal(pair.name, name) {
			return pair.value, true
		}
	}
	return "", false"""
new = """	found_value: string
	found_any: bool
	for pair in ctx.request.headers.private.pairs {
		if ascii_fold_equal(pair.name, name) {
			found_value = pair.value
			found_any = true
		}
	}
	return found_value, found_any"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new))
PYEOF
assert_mutated "last occurrence wins" "$T/header_lookup.odin" "$H"
must_go_red "$T" "$NAMES" "2: last occurrence wins -> first-matching-pair scan test"

# --- 3. bearer trims token whitespace ----------------------------------------
# Skipping leading blanks before the scan "repairs" a doubled separator —
# exactly the tolerance the strict grammar forbids.
NAMES="web.wp19_bearer_rejects_every_malformed_shape"
T="$(internal_tree trimming)"
assert_green_baseline "$T" "$NAMES" "3: bearer trims whitespace"
H="$(md5sum "$T/header_lookup.odin" | cut -d' ' -f1)"
python3 - "$T/header_lookup.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\ttoken := raw[7:]\n\tfor i in 0 ..< len(token) {"
new = """\ttoken := raw[7:]
	for len(token) > 0 && token[0] == ' ' {
		token = token[1:]
	}
	for len(token) > 0 && token[len(token) - 1] == ' ' {
		token = token[:len(token) - 1]
	}
	for i in 0 ..< len(token) {"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new))
PYEOF
assert_mutated "bearer trims whitespace" "$T/header_lookup.odin" "$H"
must_go_red "$T" "$NAMES" "3: bearer trims whitespace -> strict-grammar test"

# --- 4. bearer scheme compared case-SENSITIVELY ------------------------------
NAMES="web.wp19_bearer_scheme_is_case_insensitive"
T="$(internal_tree schemecase)"
assert_green_baseline "$T" "$NAMES" "4: scheme case-sensitive"
H="$(md5sum "$T/header_lookup.odin" | cut -d' ' -f1)"
sed -i 's/\tif !ascii_fold_equal(raw\[:6\], "Bearer") {/\tif raw[:6] != "Bearer" {/' \
  "$T/header_lookup.odin"
assert_mutated "scheme case-sensitive" "$T/header_lookup.odin" "$H"
must_go_red "$T" "$NAMES" "4: scheme case-sensitive -> scheme-fold test"

# --- 5. overlay ignored by header() ------------------------------------------
# With the overlay branch deleted, an attacker-supplied X-Request-Id would be
# what downstream readers observe — the exact leak ADR-027's overlay exists to
# prevent.
NAMES="web.wp19_overlay_shadows_the_arrived_header,web.wp19_overlay_answers_even_when_nothing_arrived"
T="$(internal_tree nooverlay)"
assert_green_baseline "$T" "$NAMES" "5: overlay ignored"
H="$(md5sum "$T/header_lookup.odin" | cut -d' ' -f1)"
python3 - "$T/header_lookup.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	if ctx.private.overlay_set && ascii_fold_equal(ctx.private.overlay.name, name) {
		return ctx.private.overlay.value, true
	}
"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, ""))
PYEOF
assert_mutated "overlay ignored" "$T/header_lookup.odin" "$H"
must_go_red "$T" "$NAMES" "5: overlay ignored -> overlay-shadowing test"

# --- 6. facade drops the OWS trim --------------------------------------------
# The in-memory transport would then deliver " padded " where a socket
# delivers "padded" — an R-10 parity break the splitter test pins.
NAMES="web.wp19_test_request_header_lines_are_split_and_ows_trimmed"
T="$(internal_tree notrim)"
assert_green_baseline "$T" "$NAMES" "6: OWS trim dropped"
H="$(md5sum "$T/test_support.odin" | cut -d' ' -f1)"
python3 - "$T/test_support.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	for len(value) > 0 && (value[0] == ' ' || value[0] == '\\t') {
		value = value[1:]
	}
	for len(value) > 0 && (value[len(value) - 1] == ' ' || value[len(value) - 1] == '\\t') {
		value = value[:len(value) - 1]
	}
"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, ""))
PYEOF
assert_mutated "OWS trim dropped" "$T/test_support.odin" "$H"
must_go_red "$T" "$NAMES" "6: OWS trim dropped -> line-splitting test"

# H4 — the in-memory driver must JOIN a repeated header name, because the socket
# does. When these disagreed, `web.test_request` answered "first" where the wire
# answered "first, second", and a test pinned the in-memory answer — so an
# application could pass its own suite and behave differently in production on a
# duplicated header (Authorization and X-Forwarded-For among them).
grep -q 'ascii_fold_equal(pair.name, name)' "$URUQUIM_ROOT/web/test_support.odin" ||
  fail "test_request no longer merges repeated header names case-insensitively; the in-memory driver would then disagree with the socket on duplicates (H4)"
grep -q 'wp19_public_duplicates_are_joined_like_the_wire' \
  "$URUQUIM_ROOT/tests/wp19-public-surface/contract_test.odin" ||
  fail "the driver-parity case for duplicate headers is gone; nothing then keeps test_request and the socket answering alike"
grep -q 'wp19_public_a_duplicated_authorization_is_refused' \
  "$URUQUIM_ROOT/tests/wp19-public-surface/contract_test.odin" ||
  fail "the duplicated-Authorization case is gone. It is the security-relevant consequence of the join: two credentials must authenticate as NEITHER, not as whichever the framework happened to pick."

echo "PASS: all six WP19 mutation controls behaved as required"
echo "wp19: the in-memory driver joins repeated header names like the wire (H4)"
