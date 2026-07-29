#!/usr/bin/env bash
# WP21 — the fault-behaviour controls, as one executable run.
#
# WP21 ships ZERO public symbols (ADR-020). Its deliverable is a GUARANTEE and
# a STATEMENT, and both are the kind of thing that rots silently: the guarantee
# because it lives in one branch of one procedure that nothing forces anyone to
# keep, the statement because prose never fails to compile. So the controls
# come in three kinds, and all three are needed:
#
#   BEHAVIOURAL (1-4) — re-create a defect in a THROWAWAY copy of the shipped
#     sources and require the WP21 suites to catch it.
#   STATIC (5-6) — re-create a defect the GATE must reject: an exported
#     `recovery`, and a document that promises recovery is coming.
#   EXECUTED (7) — the one claim no in-process test can make, because making it
#     kills the test runner: a faulting handler ABORTS THE PROCESS. It is
#     proven by building programs and running them, and its BASELINE twin must
#     exit cleanly, or the probe would "pass" on a build that was simply broken.
#
# Every probe (a) runs its selection UNMUTATED first and requires it green with
# at least one test executed, (b) asserts its own edit applied by md5 — BROKEN
# PROBE otherwise, never a false verdict — and (c) requires red afterwards.
#
#   1  driver_finalize never called      -> the driver-guarantee tests MUST go red
#   2  a fault answered 200              -> the status tests MUST go red
#   3  the request path composed into it -> the redaction tests MUST go red
#   4  the guarantee latches after one   -> the repeatability test MUST go red
#   5  `recovery` exported               -> check_public_api.sh MUST reject
#   6  a doc promises recovery (Phase 2) -> check_docs.sh MUST reject
#   7  a panicking handler               -> the PROCESS MUST DIE (and the
#                                           identical non-panicking one must not)
#
# Controls 1-4 and 7 need the pinned compiler; 5-6 are static. Without a
# toolchain this script reports BLOCKED and exits 2 — it never reports a
# control it did not run.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP21-CONTROL-FAIL: $*" >&2
  exit 1
}

URUQUIM_W21_ODIN="${URUQUIM_ODIN_BIN:-}"
if test -z "$URUQUIM_W21_ODIN" && command -v odin >/dev/null 2>&1; then
  URUQUIM_W21_ODIN="$(command -v odin)"
fi
if test -z "$URUQUIM_W21_ODIN" && test -x /tmp/uruquim-odin-toolchain/odin; then
  URUQUIM_W21_ODIN=/tmp/uruquim-odin-toolchain/odin
fi
if test -z "$URUQUIM_W21_ODIN"; then
  echo "WP21 CONTROLS -> BLOCKED: no Odin toolchain found (set URUQUIM_ODIN_BIN). NOTHING RAN." >&2
  exit 2
fi

URUQUIM_W21_TMP="$(mktemp -d -t uruquim-wp21-controls-XXXXXXXX)"
trap 'rm -rf "$URUQUIM_W21_TMP"' EXIT

internal_tree() { # name
  local t="$URUQUIM_W21_TMP/$1"
  mkdir -p "$t"
  cp "$URUQUIM_ROOT"/web/*.odin "$t/"
  cp "$URUQUIM_ROOT"/tests/wp21-internal/*.odin "$t/"
  printf '%s' "$t"
}

# root_tree copies enough of the repository that the PUBLIC suites — which
# resolve `uruquim:web` through the collection — can be compiled against a
# mutated package. A mutation to `web/` is invisible to a public suite unless
# the collection points at the mutated copy, so the copy is the probe.
root_tree() { # name
  local t="$URUQUIM_W21_TMP/$1"
  mkdir -p "$t/build" "$t/web/testing" "$t/web/internal/transport" "$t/tests" "$t/vendor" "$t/docs"
  cp "$URUQUIM_ROOT"/build/check_public_api.sh "$t/build/"
  cp "$URUQUIM_ROOT"/build/check_docs.sh "$t/build/"
  cp "$URUQUIM_ROOT"/build/check.sh "$t/build/"
  cp "$URUQUIM_ROOT"/README.md "$t/"
  cp "$URUQUIM_ROOT"/docs/*.md "$t/docs/"
  cp "$URUQUIM_ROOT"/web/*.odin "$t/web/"
  cp "$URUQUIM_ROOT"/web/testing/*.odin "$t/web/testing/"
  # REPOINTED (audit): copy ALL of web/internal, not just transport. `ingest`
  # and `stream` were added later and the transport imports them, so the copied
  # tree stopped compiling and every mutation here reported a BROKEN PROBE
  # instead of a result.
  cp -r "$URUQUIM_ROOT"/web/internal/. "$t/web/internal/"
  cp -r "$URUQUIM_ROOT"/vendor/odin-http "$t/vendor/odin-http"
  cp -r "$URUQUIM_ROOT"/tests/. "$t/tests/"
  # The docs gate resolves every `compile:` marker to a real file, and those
  # markers point into examples/. Without them the copy fails for a reason
  # that has nothing to do with the mutation under test.
  cp -r "$URUQUIM_ROOT"/examples "$t/examples"
  printf '%s' "$t"
}

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

run_selected() { # tree test-names
  env -u ODIN_ROOT "$URUQUIM_W21_ODIN" test "$1" \
    "-collection:uruquim=$URUQUIM_ROOT" -out:"$URUQUIM_W21_TMP/runner" \
    "-define:ODIN_TEST_NAMES=$2" 2>&1
}

# run_public compiles a PUBLIC suite against a mutated root copy: the collection
# points into the copy, so `import web "uruquim:web"` resolves to the mutation.
run_public() { # root-tree suite test-names
  env -u ODIN_ROOT "$URUQUIM_W21_ODIN" test "$1/tests/$2" \
    "-collection:uruquim=$1" -out:"$URUQUIM_W21_TMP/runner-public" \
    "-define:ODIN_TEST_NAMES=$3" 2>&1
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

assert_green_public_baseline() { # root-tree suite test-names label
  local out
  if ! out="$(run_public "$1" "$2" "$3")"; then
    echo "$out" >&2
    fail "BROKEN PROBE ($4): the selected public tests are not green BEFORE the mutation"
  fi
  grep -qE 'Finished [1-9][0-9]* tests?' <<<"$out" ||
    { echo "$out" >&2; fail "BROKEN PROBE ($4): the selection ran no test"; }
}

must_go_red() { # tree test-names label
  local out
  if out="$(run_selected "$1" "$2")"; then
    echo "$out" >&2
    fail "control '$3' stayed GREEN under the mutation; the suite does not catch this defect"
  fi
  echo "CONTROL $3 -> RED as required"
}

must_go_red_public() { # root-tree suite test-names label
  local out
  if out="$(run_public "$1" "$2" "$3")"; then
    echo "$out" >&2
    fail "control '$4' stayed GREEN under the mutation; the public suite does not catch this defect"
  fi
  echo "CONTROL $4 -> RED as required"
}

# --- 1. driver_finalize never called -----------------------------------------
# The whole guarantee in one line. Removing the call is not a hypothetical: the
# call sits at the end of `driver_run` with nothing above it that depends on it,
# so it is exactly the line a refactor deletes as unused.
NAMES="web.wp21_driver_run_finalizes_the_missing_response_for_both_constructors,web.wp21_the_guarantee_is_repeatable_and_does_not_latch"
T="$(internal_tree nofinalize)"
assert_green_baseline "$T" "$NAMES" "1: finalize never called"
H="$(md5sum "$T/serve.odin" | cut -d' ' -f1)"
sed -i 's/^\tdriver_finalize(ctx)$/\t_ = ctx/' "$T/serve.odin"
assert_mutated "finalize never called" "$T/serve.odin" "$H"
must_go_red "$T" "$NAMES" "1: finalize never called -> the driver-guarantee tests"

# --- 2. a fault answered 200 --------------------------------------------------
# The most dangerous shape of a broken guarantee: the response is committed, so
# every "did the driver commit something" assertion still passes, and a
# monitoring system sees a healthy service answering an empty 200.
NAMES="web.wp21_driver_run_finalizes_the_missing_response_for_both_constructors"
T="$(internal_tree fault200)"
assert_green_baseline "$T" "$NAMES" "2: a fault answered 200"
H="$(md5sum "$T/serve.odin" | cut -d' ' -f1)"
python3 - "$T/serve.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\terror_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)"
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, "\terror_commit_static(ctx, .OK, ERROR_BODY_INTERNAL)", 1))
PYEOF
assert_mutated "a fault answered 200" "$T/serve.odin" "$H"
must_go_red "$T" "$NAMES" "2: a fault answered 200 -> the status tests"

# --- 3. the request path composed into the body (STATIC-CONSTANT + PUBLIC) ----
# ADR-020's accepted cost is only acceptable because the 500 says NOTHING. The
# "helpful" mutation — tell the client which request failed — is the single
# most likely well-meant regression, and it is an information leak: the path is
# attacker-supplied and the envelope is attacker-readable.
#
# It is checked TWICE, because the two suites reject it for different reasons:
# the internal suite because the body is no longer the borrowed constant (so it
# now allocates, and a buffer exists at all), the public suite because the
# request's own text reaches the client.
NAMES="web.wp21_the_finalized_body_is_the_static_constant_not_a_copy"
T="$(internal_tree leakpath)"
assert_green_baseline "$T" "$NAMES" "3a: the path composed into the 500"
H="$(md5sum "$T/serve.odin" | cut -d' ' -f1)"
python3 - "$T/serve.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\terror_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)"
new = '\terror_commit_message(ctx, .Internal_Server_Error, "internal_error", ctx.request.path)'
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "the path composed into the 500" "$T/serve.odin" "$H"
must_go_red "$T" "$NAMES" "3a: the path composed into the 500 -> the borrowed-constant test"

PUB_NAMES="wp21_public_surface.wp21_the_driver_500_leaks_no_fault_detail,wp21_public_surface.wp21_silent_handler_is_finalized_to_the_standard_500"
R="$(root_tree leakpublic)"
assert_green_public_baseline "$R" "wp21-public-surface" "$PUB_NAMES" "3b: the path reaches the client"
H="$(md5sum "$R/web/serve.odin" | cut -d' ' -f1)"
python3 - "$R/web/serve.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\terror_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)"
new = '\terror_commit_message(ctx, .Internal_Server_Error, "internal_error", ctx.request.path)'
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "the path reaches the client" "$R/web/serve.odin" "$H"
must_go_red_public "$R" "wp21-public-surface" "$PUB_NAMES" "3b: the path reaches the client -> the redaction test"

# --- 4. the guarantee latches after the first fault --------------------------
# A server that answers the first fault correctly and every later one with a
# zero status is worse than one that never worked: it passes a smoke test. The
# mutation is a one-shot flag, which is how such a bug is actually written.
NAMES="web.wp21_the_guarantee_is_repeatable_and_does_not_latch"
T="$(internal_tree latched)"
assert_green_baseline "$T" "$NAMES" "4: the guarantee latches"
H="$(md5sum "$T/serve.odin" | cut -d' ' -f1)"
python3 - "$T/serve.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	framework_report(App, .No_Response_Committed)
	error_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)"""
new = """	if wp21_probe_latch {
		return
	}
	wp21_probe_latch = true
	framework_report(App, .No_Response_Committed)
	error_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)"""
assert old in s, "pattern not found"
s = s.replace(old, new, 1)
s += "\n@(private)\nwp21_probe_latch: bool\n"
open(p, 'w').write(s)
PYEOF
assert_mutated "the guarantee latches" "$T/serve.odin" "$H"
must_go_red "$T" "$NAMES" "4: the guarantee latches -> the repeatability test"

# --- 5. `recovery` exported (STATIC: the gate must reject) -------------------
# The Test Gate item is "no symbol named `recovery` is exported". ADR-020 is
# explicit that this is not a "not yet" but a NEVER, so the ban must be
# enforced rather than merely intended.
R="$(root_tree recoverysymbol)"
bash "$R/build/check_public_api.sh" >/dev/null 2>&1 ||
  fail "BROKEN PROBE (5: recovery symbol): the unmutated tree does not pass the public-API checker"

cat >"$R/web/wp21_probe_recovery.odin" <<'ODINEOF'
package web

// The mutation: the symbol ADR-020 says will never exist.
recovery :: proc(ctx: ^Context) {
	next(ctx)
}
ODINEOF
test -f "$R/web/wp21_probe_recovery.odin" ||
  fail "BROKEN PROBE (5: recovery symbol): the probe file was not written"

if OUT="$(bash "$R/build/check_public_api.sh" 2>&1)"; then
  echo "$OUT" >&2
  fail "control '5: recovery exported' PASSED the checker; ADR-020's zero-symbol decision is unenforced"
fi
grep -qiE 'recovery' <<<"$OUT" ||
  { echo "$OUT" >&2; fail "control 5 failed for the wrong reason; expected the checker to name 'recovery'"; }
echo "CONTROL 5: an exported \`recovery\` -> REJECTED by the gate as required"

# --- 6. a document promises recovery is coming (STATIC) ----------------------
# G-08: do not claim a default that is not delivered. This is the control for
# WP21's actual deliverable — the documentation — and it is the one that would
# otherwise have no teeth at all, because prose never fails to compile.
R="$(root_tree recoverydoc)"
bash "$R/build/check_docs.sh" >/dev/null 2>&1 ||
  fail "BROKEN PROBE (6: recovery promised): the unmutated tree does not pass the docs gate"

H="$(md5sum "$R/docs/quick-start.md" | cut -d' ' -f1)"
printf '\n- **No panic recovery.** A crash in a handler is not contained yet. (Phase 2.)\n' \
  >>"$R/docs/quick-start.md"
assert_mutated "recovery promised" "$R/docs/quick-start.md" "$H"

if OUT="$(bash "$R/build/check_docs.sh" 2>&1)"; then
  echo "$OUT" >&2
  fail "control '6: a doc promises recovery' PASSED the docs gate; G-08 is unenforced for ADR-020"
fi
grep -qiE 'promises recovery|ADR-020' <<<"$OUT" ||
  { echo "$OUT" >&2; fail "control 6 failed for the wrong reason; expected the ADR-020 documentation assertion"; }
echo "CONTROL 6: a doc promising recovery -> REJECTED by the gate as required"

# --- 7. THE EXECUTED CONTROL: a faulting handler aborts the process ----------
# The Phase-2 Test Gate item "a panic in a handler aborts the process, and the
# documentation says so" cannot be an in-process test: the process it asserts
# about is the test runner. So it is proven the only honest way — by running
# programs and reading their exit status.
#
# THE BASELINE IS THE POINT. An identical program with the fault removed must
# exit 0. Without it, a broken build, a missing collection or a link error
# would also produce a non-zero exit, and this control would "prove" the abort
# while proving nothing at all.
#
# Two fault classes are probed, because ADR-020 turns on their difference:
# `panic` reaches `assertion_failure_proc`, while a bounds-check failure is
# `proc "contextless"` and cannot consult a hook even in principle. BOTH abort.
# That is why no hook-based design could have delivered recovery.
WP21_PROBE_DIR="$URUQUIM_W21_TMP/abort"
mkdir -p "$WP21_PROBE_DIR/baseline" "$WP21_PROBE_DIR/panic" "$WP21_PROBE_DIR/bounds"

cat >"$WP21_PROBE_DIR/baseline/main.odin" <<'ODINEOF'
package wp21_abort_baseline

import web "uruquim:web"

healthy :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

main :: proc() {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/probe", healthy)
	res := web.test_request(&a, .GET, "/probe")
	if res.status != .OK {
		// A wrong status must not be mistaken for a fault: exit distinctly.
		panic("baseline did not reach the happy path")
	}
}
ODINEOF

cat >"$WP21_PROBE_DIR/panic/main.odin" <<'ODINEOF'
package wp21_abort_panic

import web "uruquim:web"

faulting :: proc(ctx: ^web.Context) {
	panic("uruquim WP21 probe: a fault inside a handler")
}

main :: proc() {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/probe", faulting)
	res := web.test_request(&a, .GET, "/probe")
	// UNREACHABLE if the documented behaviour holds. If the process is still
	// alive here it means a fault was contained, which would make the
	// documentation wrong in the direction that matters.
	_ = res
}
ODINEOF

cat >"$WP21_PROBE_DIR/bounds/main.odin" <<'ODINEOF'
package wp21_abort_bounds

import web "uruquim:web"

faulting :: proc(ctx: ^web.Context) {
	// A bounds-check failure: `bounds_check_error` is `proc "contextless"` and
	// cannot consult a context hook even in principle (ADR-020, FACT 2).
	xs := []int{1, 2, 3}
	i := len(xs) + 4
	web.text(ctx, .OK, "unreachable")
	_ = xs[i]
}

main :: proc() {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/probe", faulting)
	res := web.test_request(&a, .GET, "/probe")
	_ = res
}
ODINEOF

build_probe() { # dir out
  env -u ODIN_ROOT "$URUQUIM_W21_ODIN" build "$1" \
    "-collection:uruquim=$URUQUIM_ROOT" -out:"$2" 2>&1
}

for WP21_PROBE in baseline panic bounds; do
  if ! OUT="$(build_probe "$WP21_PROBE_DIR/$WP21_PROBE" "$WP21_PROBE_DIR/$WP21_PROBE.bin")"; then
    echo "$OUT" >&2
    fail "BROKEN PROBE (7: abort): the '$WP21_PROBE' program does not BUILD; no exit status would mean anything"
  fi
done

# The baseline must exit 0. This is what makes the two failures below evidence.
if ! "$WP21_PROBE_DIR/baseline.bin" >/dev/null 2>&1; then
  fail "BROKEN PROBE (7: abort): the fault-free baseline program did not exit 0; the abort controls would prove nothing"
fi
echo "CONTROL 7 baseline: a fault-free program exits 0 -> the probe is sound"

for WP21_PROBE in panic bounds; do
  # Run through an inner shell whose stderr is discarded. The fault kills the
  # child with a SIGNAL, and the reporting shell prints "Illegal instruction
  # (core dumped)" for it — which is the expected outcome here, not a gate
  # error, and printing it as one would train a reader to ignore the line.
  set +e
  bash -c '"$0" >/dev/null 2>&1' "$WP21_PROBE_DIR/$WP21_PROBE.bin" 2>/dev/null
  WP21_STATUS=$?
  set -e
  test "$WP21_STATUS" -ne 0 ||
    fail "control '7: $WP21_PROBE' EXITED 0; the documentation claims a faulting handler aborts the process, and it did not"
  # >128 means the process was killed by signal $((status - 128)) rather than
  # returning an error code: it did not decline to serve, it DIED. That is the
  # distinction the documentation is making, so the control reports it.
  if test "$WP21_STATUS" -gt 128; then
    echo "CONTROL 7 ($WP21_PROBE): killed by signal $((WP21_STATUS - 128)) (status $WP21_STATUS) — the process aborts, as documented"
  else
    echo "CONTROL 7 ($WP21_PROBE): exited $WP21_STATUS — non-zero, as documented"
  fi
done

echo "PASS: all seven WP21 fault-behaviour controls behaved as required"
