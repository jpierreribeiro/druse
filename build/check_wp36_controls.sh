#!/usr/bin/env bash
# WP36 — the configurable-limits mutation controls.
#
# The WP17/WP18 protocol, unchanged: each control re-creates a specific defect
# in a THROWAWAY copy of the shipped sources and requires the WP36 suite to
# catch it. Every probe (a) runs its selected tests UNMUTATED first and requires
# them green with at least one test executed, (b) asserts its own edit applied
# by md5, and (c) requires the selected tests red after the mutation.
#
#   1  the body comparison pinned back to the fixed constant
#      -> the configurable-cap tests MUST go red
#   2  the driver line that copies the budget onto the Context deleted
#      -> the same tests MUST go red, which is what makes the R-10 claim mean
#         something rather than being two implementations that happen to agree
#   3  the after-dispatch guard deleted
#      -> the rejection test MUST go red
#   4a a constructor left with a zero Limits
#      -> the application MUST STILL SERVE, on the defaults [positive control]
#   4b the same, with the zero-budget safety net also removed
#      -> the no-configuration test MUST go red
#
# Control 2 is the one that makes the R-10 claim mean something: delete the one
# driver line that carries the budget onto the request and `test_request` stops
# agreeing with the socket. Control 4 is the pair that decides what a
# framework-internal slip should COST — see the note above it.
#
# All five need the pinned compiler; without one this script reports BLOCKED and
# exits 2. On-demand, like the WP16-WP37 controls — not a per-gate step.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP36-CONTROL-FAIL: $*" >&2
  exit 1
}

DRUSE_W36_ODIN="${DRUSE_ODIN_BIN:-}"
if test -z "$DRUSE_W36_ODIN" && command -v odin >/dev/null 2>&1; then
  DRUSE_W36_ODIN="$(command -v odin)"
fi
if test -z "$DRUSE_W36_ODIN" && test -x /tmp/druse-toolchain/odin; then
  DRUSE_W36_ODIN=/tmp/druse-toolchain/odin
fi
if test -z "$DRUSE_W36_ODIN"; then
  echo "WP36 CONTROLS -> BLOCKED: no Odin toolchain found (set DRUSE_ODIN_BIN). NOTHING RAN." >&2
  exit 2
fi

DRUSE_W36_TMP="$(mktemp -d -t druse-wp36-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_W36_TMP"' EXIT

suite_tree() { # name
  local t="$DRUSE_W36_TMP/$1"
  mkdir -p "$t/druse/web" "$t/suite"
  cp "$DRUSE_ROOT"/web/*.odin "$t/druse/web/"
  cp -r "$DRUSE_ROOT"/web/testing "$t/druse/web/"
  cp -r "$DRUSE_ROOT"/web/internal "$t/druse/web/"
  cp -r "$DRUSE_ROOT"/vendor "$t/druse/"
  cp "$DRUSE_ROOT"/tests/wp36-public-surface/*.odin "$t/suite/"
  printf '%s' "$t"
}

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

run_selected() { # tree test-names
  env -u ODIN_ROOT "$DRUSE_W36_ODIN" test "$1/suite" \
    "-collection:druse=$1/druse" -out:"$DRUSE_W36_TMP/runner" \
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

CONFIGURABLE="test_wp36_public.wp36_a_lowered_body_cap_is_enforced_exactly,test_wp36_public.wp36_a_raised_body_cap_admits_what_a_lower_one_refused"

# --- 1. the body comparison pinned back to the fixed constant ----------------
# `web.limits` then accepts a number and enforces a different one: a knob that
# lies, which is worse than no knob.
T="$(suite_tree hardcoded)"
assert_green_baseline "$T" "$CONFIGURABLE" "1: the cap is hard-coded again"
H="$(md5sum "$T/druse/web/extract.odin" | cut -d' ' -f1)"
python3 - "$T/druse/web/extract.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "	cap := ctx.private.limits.max_body"
new = "	cap := BODY_LIMIT"
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "the cap is hard-coded again" "$T/druse/web/extract.odin" "$H"
must_go_red "$T" "$CONFIGURABLE" "1: the cap is hard-coded again -> the configurable-cap tests"

# --- 2. the budget never reaches the request ---------------------------------
# THE R-10 CONTROL. The App holds the configured value and the request holds
# three zeros, so every body is over-limit. This is the line that makes
# "test_request enforces the same numbers as a socket" structural rather than a
# coincidence, and if the suite could not tell, the claim would be untested.
T="$(suite_tree uncopied)"
assert_green_baseline "$T" "$CONFIGURABLE" "2: the budget never reaches the request"
H="$(md5sum "$T/druse/web/serve.odin" | cut -d' ' -f1)"
python3 - "$T/druse/web/serve.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "	ctx.private.limits = a.private.limits"
new = "	_ = a.private.limits"
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "the budget never reaches the request" "$T/druse/web/serve.odin" "$H"
must_go_red "$T" "$CONFIGURABLE" "2: the budget never reaches the request -> the configurable-cap tests"

# --- 3. the after-dispatch guard deleted -------------------------------------
# The budget then changes under a serving application, and two clients get two
# different answers to the same body.
NAMES="test_wp36_public.wp36_limits_after_the_first_dispatch_rejects_the_application"
T="$(suite_tree unguarded)"
assert_green_baseline "$T" "$NAMES" "3: the after-dispatch guard deleted"
H="$(md5sum "$T/druse/web/limits.odin" | cut -d' ' -f1)"
python3 - "$T/druse/web/limits.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
# REPOINTED (audit): the field read became the `app_has_dispatched` accessor,
# and this pattern has not matched since.
old = """	if app_has_dispatched(a) {
		limits_poison(a, FRAMEWORK_MESSAGE_LIMITS_AFTER_DISPATCH)
		return
	}"""
new = """	_ = app_has_dispatched(a)"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "the after-dispatch guard deleted" "$T/druse/web/limits.odin" "$H"
must_go_red "$T" "$NAMES" "3: the after-dispatch guard deleted -> the rejection test"

# --- 4. a constructor forgets the default ------------------------------------
#
# A CONTROL PAIR, because the interesting answer here is not "red".
#
# 4a is a POSITIVE control. With `bare()` reverted to `App{}` — three zero
# limits — the application must STILL SERVE, because `web.body` resolves a zero
# budget to the default. That asymmetry with the public API is deliberate:
# `web.limits` refuses a partially-filled `Limits`, so an application can never
# choose a zero, and the only way one arrives is a framework-internal omission.
# Reading that as "reject every body" would turn a slip in this repository into
# an application that refuses all traffic — which is not failing closed, it is
# broken. If 4a ever goes red, that safety net has been removed.
#
# 4b is the negative half: with the net ALSO gone, the same forgetful
# constructor produces exactly the silent catastrophe — 413 to every body, while
# every test written against `app()` stays green. That is the failure
# `check_public_api.sh` §8c counts constructors to catch at the gate.
NAMES="test_wp36_public.wp36_bare_gets_the_same_budget"
T="$(suite_tree zero_default)"
assert_green_baseline "$T" "$NAMES" "4: a constructor forgets the default"
H="$(md5sum "$T/druse/web/app.odin" | cut -d' ' -f1)"
python3 - "$T/druse/web/app.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "	return App{private = App_Internal{limits = DEFAULT_LIMITS}}"
new = "	return App{}"
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "a constructor forgets the default" "$T/druse/web/app.odin" "$H"
if ! run_selected "$T" "$NAMES" >/dev/null 2>&1; then
  fail "control '4a: the zero-budget safety net' went RED. A constructor that forgets the default must still SERVE, on the framework's defaults — not answer 413 to every body."
fi
echo "CONTROL 4a: a constructor forgets the default -> still GREEN, the safety net holds [positive control]"

H="$(md5sum "$T/druse/web/extract.odin" | cut -d' ' -f1)"
python3 - "$T/druse/web/extract.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\tcap := ctx.private.limits.max_body\n\tif cap <= 0 {\n\t\tcap = BODY_LIMIT\n\t}"
new = "\tcap := ctx.private.limits.max_body"
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "the safety net removed too" "$T/druse/web/extract.odin" "$H"
must_go_red "$T" "$NAMES" "4b: a forgetful constructor AND no safety net -> the bare() budget test"

echo "PASS: all five WP36 mutation controls behaved as required"
