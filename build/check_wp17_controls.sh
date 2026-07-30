#!/usr/bin/env bash
# WP17 — the seven required middleware mutation controls, as one executable run.
#
# Each control re-creates a specific defect in a THROWAWAY copy of the shipped
# sources and requires the WP17 test suite to catch it. Every probe asserts its
# own edit applied (md5 before/after) — a probe that fails to mutate reports
# BROKEN PROBE, never a false verdict — and every probe first runs its selected
# tests UNMUTATED and requires them green, so a red verdict can only come from
# the mutation, never from a stale test name or a broken selection.
#
#   1  chain flattened in reverse order        -> ordering test MUST go red
#   2  cursor advance deleted                  -> bounded-recursion test MUST go red
#   3  chain copied per request                -> tracking-allocator test MUST go red
#   4  []Handler stored at registration        -> pool-growth test MUST go red
#      (the WP12 P8 slice defect; the poisoning allocator makes it
#      deterministic — the crash IS the detection)
#   5  miss chain skipped                      -> 404-observability test MUST go red
#   6  fail-closed guard removed               -> the mis-ordered auth program
#                                                 serves the secret; MUST go red
#   7  terminal moved outside the cursor bound -> handler-runs-once test MUST go
#      red (the WP12 integrator's counter-example cursor, made permanent)
#
# All seven need the pinned compiler. Without one this script reports BLOCKED
# and exits 2 — it never reports a control it did not run. Behavioural controls
# compile the throwaway package per mutation, so a full run costs about a
# minute; it is an on-demand acceptance run, not a per-gate step (the same
# split WP16 used).
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP17-CONTROL-FAIL: $*" >&2
  exit 1
}

DRUSE_W17_ODIN="${DRUSE_ODIN_BIN:-}"
if test -z "$DRUSE_W17_ODIN" && command -v odin >/dev/null 2>&1; then
  DRUSE_W17_ODIN="$(command -v odin)"
fi
if test -z "$DRUSE_W17_ODIN" && test -x /tmp/druse-toolchain/odin; then
  DRUSE_W17_ODIN=/tmp/druse-toolchain/odin
fi
if test -z "$DRUSE_W17_ODIN"; then
  echo "WP17 CONTROLS -> BLOCKED: no Odin toolchain found (set DRUSE_ODIN_BIN). NOTHING RAN." >&2
  exit 2
fi

DRUSE_W17_TMP="$(mktemp -d -t druse-wp17-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_W17_TMP"' EXIT

# One throwaway internal package per control: the real web/ sources plus the
# real WP17 internal tests, exactly as build/check.sh assembles them.
internal_tree() { # name
  local t="$DRUSE_W17_TMP/$1"
  mkdir -p "$t"
  cp "$DRUSE_ROOT"/web/*.odin "$t/"
  cp "$DRUSE_ROOT"/tests/wp17-internal/*.odin "$t/"
  printf '%s' "$t"
}

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

run_selected() { # tree test-names -> stdout+stderr; returns odin test's exit
  env -u ODIN_ROOT "$DRUSE_W17_ODIN" test "$1" \
    "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_W17_TMP/runner" \
    "-define:ODIN_TEST_NAMES=$2" 2>&1
}

# The green baseline is part of every probe: the SAME selection must pass on
# the unmutated tree and must actually run at least one test, or the red
# verdict later would be meaningless.
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

# --- 1. chain flattened in reverse order -------------------------------------
NAMES="web.wp17_order_across_three_globals_and_exact_reverse_unwind"
T="$(internal_tree reversed)"
assert_green_baseline "$T" "$NAMES" "1: reversed flatten"
H="$(md5sum "$T/middleware.odin" | cut -d' ' -f1)"
sed -z -i 's/\tfor middleware in a.private.mw_globals {\n\t\tappend(&a.private.mw_pool, middleware)\n\t}/\tfor gi := len(a.private.mw_globals) - 1; gi >= 0; gi -= 1 {\n\t\tappend(\&a.private.mw_pool, a.private.mw_globals[gi])\n\t}/' \
  "$T/middleware.odin"
assert_mutated "reversed flatten" "$T/middleware.odin" "$H"
must_go_red "$T" "$NAMES" "1: reversed flatten -> ordering test"

# --- 2. cursor advance deleted -----------------------------------------------
# The bounded middleware turns "cursor stuck" into a wrong entry count instead
# of a stack overflow, so the runner survives to report it.
NAMES="web.wp17_the_cursor_advances_exactly_once_per_step"
T="$(internal_tree stuck)"
assert_green_baseline "$T" "$NAMES" "2: cursor advance deleted"
H="$(md5sum "$T/middleware.odin" | cut -d' ' -f1)"
sed -i 's/^\tctx.private.chain_index = i + 1$/\tctx.private.chain_index = i/' "$T/middleware.odin"
assert_mutated "cursor advance deleted" "$T/middleware.odin" "$H"
must_go_red "$T" "$NAMES" "2: cursor advance deleted -> bounded-recursion test"

# --- 3. chain copied per request ---------------------------------------------
NAMES="web.wp17_dispatch_allocates_zero_through_a_five_middleware_chain"
T="$(internal_tree copying)"
assert_green_baseline "$T" "$NAMES" "3: per-request chain copy"
H="$(md5sum "$T/middleware.odin" | cut -d' ' -f1)"
sed -z -i 's/\tctx.private.chain = a.private.mw_pool\[start:start + length\]\n\tctx.private.chain_index = 0/\tcopied := make([]Handler, length)\n\tcopy(copied, a.private.mw_pool[start:start + length])\n\tctx.private.chain = copied\n\tctx.private.chain_index = 0/' \
  "$T/middleware.odin"
assert_mutated "per-request chain copy" "$T/middleware.odin" "$H"
must_go_red "$T" "$NAMES" "3: per-request chain copy -> tracking-allocator test"

# --- 4. []Handler stored at registration (the P8 defect) ---------------------
# The route captures a slice VIEW of the pool at registration; 64 further
# registrations force the pool to move under the poisoning allocator, and the
# stored view then points at 0xAA bytes. The crash (or wrong handler) is the
# detection — WP12 P8b proved the plain heap can read back CORRECTLY, which is
# exactly why the test runs under the poisoning allocator.
NAMES="web.wp17_chains_survive_pool_growth_under_a_poisoning_allocator"
T="$(internal_tree slice)"
assert_green_baseline "$T" "$NAMES" "4: slice storage"
H="$(md5sum "$T/dispatch_table.odin" | cut -d' ' -f1)"
H2="$(md5sum "$T/dispatch_match.odin" | cut -d' ' -f1)"
sed -z -i 's/\tchain_start: int,\n\tchain_len:   int,\n}/\tchain_start: int,\n\tchain_len:   int,\n\tchain_view:  []Handler,\n}/' \
  "$T/dispatch_table.odin"
sed -z -i 's/\t\t\tchain_start = chain_start,\n\t\t\tchain_len = chain_len,\n\t\t},/\t\t\tchain_start = chain_start,\n\t\t\tchain_len = chain_len,\n\t\t\tchain_view = a.private.mw_pool[chain_start:chain_start + chain_len],\n\t\t},/' \
  "$T/dispatch_table.odin"
# Matches ONLY the chain-entry line it replaces. Anchoring on the surrounding
# statements made this probe brittle: WP20's route-identity assignment landed
# between them and the probe reported BROKEN PROBE — correctly refusing a
# verdict rather than faking one, which is why it is written narrowly now.
sed -z -i 's/\t\tchain_enter(a, ctx, entry.chain_start, entry.chain_len)\n\t\treturn/\t\tctx.private.chain = entry.chain_view\n\t\tctx.private.chain_index = 0\n\t\tnext(ctx)\n\t\treturn/' \
  "$T/dispatch_match.odin"
assert_mutated "slice storage (entry)" "$T/dispatch_table.odin" "$H"
assert_mutated "slice storage (dispatch)" "$T/dispatch_match.odin" "$H2"
must_go_red "$T" "$NAMES" "4: slice storage -> pool-growth test under the poisoning allocator"

# --- 5. miss chain skipped ---------------------------------------------------
NAMES="web.wp17_global_middleware_observe_a_404_with_the_envelope_intact"
T="$(internal_tree missless)"
assert_green_baseline "$T" "$NAMES" "5: miss chain skipped"
H="$(md5sum "$T/dispatch_match.odin" | cut -d' ' -f1)"
sed -z -i 's/\tmw_miss_prepare(a, ctx)\n\tmiss_chain_ensure(a)\n\tchain_enter(a, ctx, a.private.miss_start, a.private.miss_len)/\tmw_miss_prepare(a, ctx)\n\tmiss_terminal(ctx)/' \
  "$T/dispatch_match.odin"
assert_mutated "miss chain skipped" "$T/dispatch_match.odin" "$H"
must_go_red "$T" "$NAMES" "5: miss chain skipped -> 404-observability test"

# --- 6. fail-closed guard removed --------------------------------------------
# With the ADR-019 guard deleted, the WP12 D-12.5 mis-ordered auth program
# quietly serves the protected route again — the exact measured vulnerability.
# The security test must observe it.
NAMES="web.wp17_use_after_a_registered_route_poisons_the_app_fail_closed"
T="$(internal_tree unguarded)"
assert_green_baseline "$T" "$NAMES" "6: fail-closed guard removed"
H="$(md5sum "$T/middleware.odin" | cut -d' ' -f1)"
sed -z -i 's/\tif len(a.private.routes) > 0 || a.private.has_mounted {/\tif false {/' \
  "$T/middleware.odin"
assert_mutated "fail-closed guard removed" "$T/middleware.odin" "$H"
must_go_red "$T" "$NAMES" "6: fail-closed guard removed -> mis-ordered auth program test"

# --- 7. terminal moved outside the cursor bound ------------------------------
# The WP12 integrator's counter-example: a cursor that is STILL monotonic and
# STILL per-request, but whose exhausted state falls through to the terminal
# instead of stopping. A second next() then re-runs the route handler — the
# commit guard rejects the duplicate response, but a duplicated side effect is
# invisible to it, which is why this needs its own test (spec §3 item 3).
NAMES="web.wp17_second_next_is_a_silent_noop_and_the_handler_runs_once"
T="$(internal_tree fallthrough)"
assert_green_baseline "$T" "$NAMES" "7: terminal outside the bound"
H="$(md5sum "$T/middleware.odin" | cut -d' ' -f1)"
sed -z -i 's/\ti := ctx.private.chain_index\n\tif i >= len(ctx.private.chain) {\n\t\treturn\n\t}/\ti := ctx.private.chain_index\n\tif i >= len(ctx.private.chain) {\n\t\tctx.private.chain[len(ctx.private.chain) - 1](ctx)\n\t\treturn\n\t}/' \
  "$T/middleware.odin"
assert_mutated "terminal outside the bound" "$T/middleware.odin" "$H"
must_go_red "$T" "$NAMES" "7: terminal outside the bound -> handler-runs-once test"

echo "PASS: all seven WP17 mutation controls behaved as required"
