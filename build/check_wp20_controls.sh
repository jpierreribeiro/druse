#!/usr/bin/env bash
# WP20 — the six required observer mutation controls, as one executable run.
#
# The WP17-WP19 protocol, unchanged: each control re-creates a specific defect
# in a THROWAWAY copy of the shipped sources and requires the WP20 test suite
# (or, for control 6, the GATE) to catch it. Every probe (a) runs its selected
# tests UNMUTATED first and requires them green with at least one test
# executed, (b) asserts its own edit applied by md5 — BROKEN PROBE otherwise,
# never a false verdict — and (c) requires the selected tests red afterwards.
#
#   1  the raw PATH used as route identity   -> pattern-only test MUST go red
#   2  emission moved BEFORE the commit      -> committed-status test MUST go red
#   3  observer not carried onto the Context -> in-request emission MUST go red
#   4  `observe` appends instead of replacing -> last-wins test MUST go red
#   5  one report site left unpaired          -> that variant's test MUST go red
#   6  a `path: string` field on the event    -> the GATE assertion MUST reject
#
# Controls 1-5 need the pinned compiler; control 6 is static. Without a
# toolchain this script reports BLOCKED and exits 2 — it never reports a
# control it did not run.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP20-CONTROL-FAIL: $*" >&2
  exit 1
}

URUQUIM_W20_ODIN="${URUQUIM_ODIN_BIN:-}"
if test -z "$URUQUIM_W20_ODIN" && command -v odin >/dev/null 2>&1; then
  URUQUIM_W20_ODIN="$(command -v odin)"
fi
if test -z "$URUQUIM_W20_ODIN" && test -x /tmp/uruquim-odin-toolchain/odin; then
  URUQUIM_W20_ODIN=/tmp/uruquim-odin-toolchain/odin
fi
if test -z "$URUQUIM_W20_ODIN"; then
  echo "WP20 CONTROLS -> BLOCKED: no Odin toolchain found (set URUQUIM_ODIN_BIN). NOTHING RAN." >&2
  exit 2
fi

URUQUIM_W20_TMP="$(mktemp -d -t uruquim-wp20-controls-XXXXXXXX)"
trap 'rm -rf "$URUQUIM_W20_TMP"' EXIT

internal_tree() { # name
  local t="$URUQUIM_W20_TMP/$1"
  mkdir -p "$t"
  cp "$URUQUIM_ROOT"/web/*.odin "$t/"
  cp "$URUQUIM_ROOT"/tests/wp20-internal/*.odin "$t/"
  printf '%s' "$t"
}

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

run_selected() { # tree test-names
  env -u ODIN_ROOT "$URUQUIM_W20_ODIN" test "$1" \
    "-collection:uruquim=$URUQUIM_ROOT" -out:"$URUQUIM_W20_TMP/runner" \
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

# --- 1. the raw PATH used as route identity ----------------------------------
# The single most dangerous regression this work package can have: swapping the
# registered pattern for the request path turns a low-cardinality identity into
# unbounded, request-derived text in every observer (§6.2).
NAMES="web.wp20_route_is_the_pattern_for_every_parametric_path,web.wp20_marshal_failure_is_observed_once"
T="$(internal_tree rawpath)"
assert_green_baseline "$T" "$NAMES" "1: raw path as route"
H="$(md5sum "$T/dispatch_match.odin" | cut -d' ' -f1)"
sed -i 's/^\t\tctx.private.route = entry.pattern$/\t\tctx.private.route = ctx.request.path/' \
  "$T/dispatch_match.odin"
assert_mutated "raw path as route" "$T/dispatch_match.odin" "$H"
must_go_red "$T" "$NAMES" "1: raw path as route -> pattern-only identity tests"

# --- 2. emission moved BEFORE the commit -------------------------------------
# The event would then carry the status the framework had not sent yet — a
# predicted value presented as fact.
NAMES="web.wp20_missing_response_is_observed_once"
T="$(internal_tree earlyemit)"
assert_green_baseline "$T" "$NAMES" "2: emission before the commit"
H="$(md5sum "$T/serve.odin" | cut -d' ' -f1)"
python3 - "$T/serve.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	framework_report(App, .No_Response_Committed)
	error_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)
	framework_observe_request(App, ctx, .No_Response_Committed)"""
new = """	framework_report(App, .No_Response_Committed)
	framework_observe_request(App, ctx, .No_Response_Committed)
	error_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new))
PYEOF
assert_mutated "emission before the commit" "$T/serve.odin" "$H"
must_go_red "$T" "$NAMES" "2: emission before the commit -> committed-status test"

# --- 3. observer not carried onto the Context --------------------------------
# Every in-request failure would become unobservable while `serve`-path
# failures kept working — the subtle half-broken state.
NAMES="web.wp20_marshal_failure_is_observed_once,web.wp20_double_body_is_observed_once"
T="$(internal_tree nocarry)"
assert_green_baseline "$T" "$NAMES" "3: observer not carried"
H="$(md5sum "$T/serve.odin" | cut -d' ' -f1)"
sed -i 's/^\tctx.private.observer = a.private.observer$/\t_ = a.private.observer/' "$T/serve.odin"
assert_mutated "observer not carried" "$T/serve.odin" "$H"
must_go_red "$T" "$NAMES" "3: observer not carried -> in-request emission tests"

# --- 4. `observe` keeps the FIRST observer instead of the last ---------------
NAMES="web.wp20_last_observer_wins"
T="$(internal_tree firstwins)"
assert_green_baseline "$T" "$NAMES" "4: first observer wins"
H="$(md5sum "$T/observer.odin" | cut -d' ' -f1)"
python3 - "$T/observer.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
# REPOINTED (audit): `observe` gained the late-configuration guard after this
# mutation was written, so the pattern stopped matching and this control was
# inert. The mutation itself is unchanged in INTENT — a second `observe` call
# silently ignored — only in the text it edits.
old = """	a.private.observer = observer
}"""
new = """	if a.private.observer == nil {
		a.private.observer = observer
	}
}"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new))
PYEOF
assert_mutated "first observer wins" "$T/observer.odin" "$H"
must_go_red "$T" "$NAMES" "4: first observer wins -> last-wins test"

# --- 5. one report site left unpaired ----------------------------------------
# The behavioural half of the gate's report/observe count invariant: deleting
# an emission must be caught by a TEST too, not only by the static count.
NAMES="web.wp20_double_body_is_observed_once"
T="$(internal_tree unpaired)"
assert_green_baseline "$T" "$NAMES" "5: report site unpaired"
H="$(md5sum "$T/extract.odin" | cut -d' ' -f1)"
sed -i '/framework_observe_request(T, ctx, .Body_Consumed_Twice)/d' "$T/extract.odin"
assert_mutated "report site unpaired" "$T/extract.odin" "$H"
must_go_red "$T" "$NAMES" "5: report site unpaired -> that variant's test"

# --- 6. a `path: string` field on the event (STATIC: the gate must reject) ---
# The §6.2 redaction constraint. This control drives the CHECKER, not the test
# suite: the field set is a static property, and the gate is what holds it.
T="$URUQUIM_W20_TMP/redaction"
mkdir -p "$T/build" "$T/web/testing" "$T/web/internal/transport" "$T/tests" "$T/vendor"
cp "$URUQUIM_ROOT"/build/check_public_api.sh "$T/build/"
cp "$URUQUIM_ROOT"/build/check.sh "$T/build/"
cp "$URUQUIM_ROOT"/web/*.odin "$T/web/"
cp "$URUQUIM_ROOT"/web/testing/*.odin "$T/web/testing/"
# REPOINTED (audit): ALL of web/internal, not just transport. `ingest` and
# `stream` arrived later and the transport imports them, so this tree stopped
# compiling and the control reported a BROKEN PROBE rather than a result.
cp -r "$URUQUIM_ROOT"/web/internal/. "$T/web/internal/"
cp -r "$URUQUIM_ROOT"/vendor/odin-http "$T/vendor/odin-http"
cp -r "$URUQUIM_ROOT"/tests/. "$T/tests/"

# The unmutated tree must PASS the checker first, or a later rejection would
# prove nothing about the mutation.
bash "$T/build/check_public_api.sh" >/dev/null 2>&1 ||
  fail "BROKEN PROBE (6: redaction): the unmutated tree does not pass the public-API checker"

H="$(md5sum "$T/web/observer.odin" | cut -d' ' -f1)"
python3 - "$T/web/observer.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\troute:        string,"
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, old + "\n\tpath:         string,", 1))
PYEOF
assert_mutated "redaction: path field" "$T/web/observer.odin" "$H"

if OUT="$(bash "$T/build/check_public_api.sh" 2>&1)"; then
  echo "$OUT" >&2
  fail "control '6: path field on Framework_Event' PASSED the checker; the §6.2 redaction constraint is unenforced"
fi
grep -qE "Framework_Event must carry exactly|carries string data" <<<"$OUT" ||
  { echo "$OUT" >&2; fail "control 6 failed for the wrong reason; expected the Framework_Event field assertion"; }
echo "CONTROL 6: path: string on Framework_Event -> REJECTED by the gate as required"

echo "PASS: all six WP20 mutation controls behaved as required"
