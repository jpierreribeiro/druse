#!/usr/bin/env bash
# WP30 — the registration-conflict mutation controls, as one executable run.
#
# The WP17/WP18 protocol, unchanged: each control re-creates a specific defect
# in a THROWAWAY copy of the shipped sources and requires the WP30 suite to
# catch it. Every probe (a) runs its selected tests UNMUTATED first and requires
# them green with at least one test executed, (b) asserts its own edit applied
# by md5 — BROKEN PROBE otherwise, never a false verdict — and (c) requires the
# selected tests red after the mutation.
#
# WHY THREE AND NOT ONE. A diagnostic has two ways to be wrong and both cost an
# application its boot, so both are controlled:
#
#   1  the detection deleted (silent first-registration-wins, i.e. Phase 1)
#      -> the poison tests MUST go red
#   2  the detection inverted (every route reads as a conflict)
#      -> the "this is NOT a conflict" tests MUST go red
#   3  mount does not stop at the first diagnosis
#      -> the one-line test MUST go red
#
# Control 2 is the one worth having. A rejection rule is only as good as the
# larger set it leaves alone, and a suite that only proves conflicts are caught
# would stay green against an implementation that rejects everything.
#
# All three need the pinned compiler; without one this script reports BLOCKED
# and exits 2. On-demand, like the WP16-WP25 controls — not a per-gate step.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP30-CONTROL-FAIL: $*" >&2
  exit 1
}

DRUSE_W30_ODIN="${DRUSE_ODIN_BIN:-}"
if test -z "$DRUSE_W30_ODIN" && command -v odin >/dev/null 2>&1; then
  DRUSE_W30_ODIN="$(command -v odin)"
fi
if test -z "$DRUSE_W30_ODIN" && test -x /tmp/druse-toolchain/odin; then
  DRUSE_W30_ODIN=/tmp/druse-toolchain/odin
fi
if test -z "$DRUSE_W30_ODIN"; then
  echo "WP30 CONTROLS -> BLOCKED: no Odin toolchain found (set DRUSE_ODIN_BIN). NOTHING RAN." >&2
  exit 2
fi

DRUSE_W30_TMP="$(mktemp -d -t druse-wp30-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_W30_TMP"' EXIT

internal_tree() { # name
  local t="$DRUSE_W30_TMP/$1"
  mkdir -p "$t"
  cp "$DRUSE_ROOT"/web/*.odin "$t/"
  cp "$DRUSE_ROOT"/tests/wp30-internal/*.odin "$t/"
  printf '%s' "$t"
}

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

run_selected() { # tree test-names
  env -u ODIN_ROOT "$DRUSE_W30_ODIN" test "$1" \
    "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_W30_TMP/runner" \
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

# --- 1. the detection deleted ------------------------------------------------
# Exactly Phase 1's behaviour restored: the occupied slot keeps its first
# registrant and nothing is said. This is the defect WP30 exists to remove, so
# it is the control that has to exist.
NAMES="web.wp30_a_duplicate_method_and_pattern_poisons_the_app,web.wp30_parameter_names_do_not_distinguish_two_routes,web.wp30_a_conflicted_app_answers_500_everywhere"
T="$(internal_tree deleted)"
assert_green_baseline "$T" "$NAMES" "1: detection deleted"
H="$(md5sum "$T/dispatch_index.odin" | cut -d' ' -f1)"
python3 - "$T/dispatch_index.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	if a.private.route_index.nodes[node].by_method[entry.method] != ROUTE_NODE_NONE {
		route_conflict_poison(a, entry.method, entry.pattern)
		return true
	}
	a.private.route_index.nodes[node].by_method[entry.method] = entry_index"""
new = """	if a.private.route_index.nodes[node].by_method[entry.method] == ROUTE_NODE_NONE {
		a.private.route_index.nodes[node].by_method[entry.method] = entry_index
	}"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "detection deleted" "$T/dispatch_index.odin" "$H"
must_go_red "$T" "$NAMES" "1: detection deleted -> the poison tests"

# --- 2. the detection inverted ----------------------------------------------
# Every registration now reads as a conflict, so the application is rejected the
# moment it registers anything. A suite that only proved conflicts are CAUGHT
# would stay green here, which is why the "not a conflict" half is tested at all.
NAMES="web.wp30_the_same_pattern_under_two_methods_is_not_a_conflict,web.wp30_static_and_parametric_siblings_are_not_a_conflict,web.wp30_a_trailing_slash_is_still_a_distinct_pattern,web.wp30_two_prefixes_are_not_a_conflict"
T="$(internal_tree inverted)"
assert_green_baseline "$T" "$NAMES" "2: detection inverted"
H="$(md5sum "$T/dispatch_index.odin" | cut -d' ' -f1)"
python3 - "$T/dispatch_index.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	if a.private.route_index.nodes[node].by_method[entry.method] != ROUTE_NODE_NONE {"""
new = """	if true {"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "detection inverted" "$T/dispatch_index.odin" "$H"
must_go_red "$T" "$NAMES" "2: detection inverted -> the not-a-conflict tests"

# --- 3. mount does not stop at the first diagnosis ---------------------------
# The copy walks on into an application it has already rejected and emits one
# sentence per colliding route. The whole ADR-019 family's rule is that the
# FIRST diagnosis stands; a wall of them buries the one a developer must read.
NAMES="web.wp30_a_conflict_during_mount_stops_at_the_first_diagnosis"
T="$(internal_tree unstopped)"
assert_green_baseline "$T" "$NAMES" "3: mount does not stop"
H="$(md5sum "$T/router.odin" | cut -d' ' -f1)"
python3 - "$T/router.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """		if a.private.poisoned {
			return
		}
	}
}"""
new = """		_ = a.private.poisoned
	}
}"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "mount does not stop" "$T/router.odin" "$H"
must_go_red "$T" "$NAMES" "3: mount does not stop -> the one-diagnosis test"

echo "PASS: all three WP30 mutation controls behaved as required"
