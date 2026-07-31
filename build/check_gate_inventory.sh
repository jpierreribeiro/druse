#!/usr/bin/env bash
#
# Every control script in build/ is EXECUTED by the gate, or exempt on the record.
#
# WHY THIS EXISTS. build/check.sh opens with a block of `bash -n` lines. A
# syntax check proves a script PARSES; it proves nothing about whether the
# mutation still applies, whether the probe tree still compiles, or whether the
# suite still detects what the script is named after. check.sh already carries
# that lesson in prose: "Seventeen control scripts were `bash -n`'d at the top of
# this gate and never run by it. An audit executed them: FOUR were broken, and
# had been for as long as nobody had looked."
#
# Seventeen were then wired into a loop. Four scripts are still outside it, and
# the audit that produced this file had to work out, one by one, which were
# DECISIONS and which was an OMISSION — because from outside they look the same.
# Three were decisions (a forwarder, a fifteen-minute baseline producer, and a
# meta-test that would recurse). One was an omission, and it stings: the ORPHAN
# DETECTOR lived inside check_test.sh, the meta-test. That detector exists to
# catch test suites no gate script runs (commit f06c447, "six suites nobody
# ran"), and it was itself never run, so it could not detect its own case —
# tests/nbio-timeout sat in the tree with three @(test) procedures, executed by
# nothing at all. It is now wired in, and the detector moved to
# build/check_suite_inventory.sh where the gate can reach it.
#
# Writing the reason down is the whole mechanism. An exemption with a reason is
# a decision; an exemption without one is the next nbio-timeout.
#
# So the rule stops being "remember to wire it in" and becomes a check.
#
# WHAT IT ASSERTS. For every build/check_*.sh on disk: check.sh must invoke it
# somewhere OTHER than in a `bash -n` line, or it must appear below with a
# stated reason. A new control script that nobody wires in fails the gate on the
# run that adds it, which is the only moment the omission is cheap to fix.
#
# USAGE. Takes the tree root as $1 so the gate can run it against a mutated copy
# and require red -- a positive case alone is what commit 0b1fea8 proved nothing
# with (planning/diagnosability.md rule 4).

set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GATE="$ROOT/build/check.sh"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

test -f "$GATE" || fail "build/check.sh is missing; there is no gate to take inventory of"

# Scripts the gate deliberately does not execute. Each needs a reason.
#
#   check.sh                -- it IS the gate; it cannot invoke itself.
#   check_test.sh           -- a META-TEST OF THE GATE, and the exclusion is
#                              structural rather than an oversight. It invokes
#                              .githooks/pre-push and build/check.sh several
#                              times over, to prove the gate rejects a divergent
#                              compiler and sanitises an ambient ODIN_ROOT;
#                              calling it from check.sh would recurse forever.
#                              Run it by hand, or from CI outside the gate:
#                                  bash build/check_test.sh
#                              Its orphan detector used to live inside it and
#                              therefore never ran; that detector is now
#                              build/check_suite_inventory.sh, which the gate
#                              does run. Nothing else in this file may be
#                              exempted for "it is slow" or "it is awkward" --
#                              recursion is the only reason accepted here.
#   check_gate_inventory.sh -- this file; invoked by check.sh, listed here so it
#                              does not have to reason about itself.
#   check_wp67_controls.sh  -- a deliberate forwarder, not a control. WP67's RED
#                              anatomy was consumed by WP68; the file survives
#                              only so a run that walks every historical control
#                              by name cannot execute pre-implementation
#                              expectations. Its whole body is
#                              `exec bash check_wp68_controls.sh`, and check.sh
#                              runs check_wp68_controls.sh directly. Wiring the
#                              forwarder in would run WP68's controls twice.
#   check_wp26_bench.sh     -- a baseline PRODUCER, not a control, and out of the
#                              gate by a decision its own header argues: the
#                              alternating sweep a derived tolerance needs takes
#                              about fifteen minutes, and "a gate nobody runs
#                              measures nothing at all". The soundness of the
#                              instrument is gated instead, by tests/wp26-bench,
#                              which finishes in milliseconds and DOES run.
DRUSE_LINT_ONLY_ALLOWED=" check.sh check_test.sh check_gate_inventory.sh check_wp67_controls.sh check_wp26_bench.sh "

# --- the set the gate actually runs ------------------------------------------
#
# Two invocation shapes, and the second is why a naive grep gets this wrong:
#   1. literal   -- bash "$DRUSE_ROOT/build/check_docs.sh"
#   2. by loop   -- bash "$DRUSE_ROOT/build/check_${druse_control}_controls.sh"
#                   over an explicit list of stems
# Shape 2 means the string `check_wp21_controls.sh` never appears in check.sh at
# all, so the loop's stem list is expanded here rather than pattern-matched.

DRUSE_EXECUTED=""

# Shape 1: a real invocation — `bash` and the path on the same line, the line is
# not a comment, and it is not the `bash -n` lint. Mentioning a script in prose
# does not run it: the first draft of this check counted check.sh's own comment
# about `build/check_test.sh` as an invocation and therefore cleared the very
# script whose absence prompted the check.
while IFS= read -r script; do
  name="$(basename "$script")"
  if grep -F "build/$name" "$GATE" |
       grep -v '^[[:space:]]*#' |
       grep -v 'bash -n' |
       grep -q '\bbash\b'; then
    DRUSE_EXECUTED="$DRUSE_EXECUTED $name"
  fi
done < <(find "$ROOT/build" -maxdepth 1 -name 'check_*.sh' -o -maxdepth 1 -name 'check.sh' | sort)

# Shape 2: expand the mutation-control loop's stem list.
DRUSE_LOOP_STEMS="$(
  sed -n '/^for druse_control in /,/; do$/p' "$GATE" |
  sed 's/^for druse_control in //; s/; do$//; s/\\$//'
)"
if test -n "$DRUSE_LOOP_STEMS"; then
  for stem in $DRUSE_LOOP_STEMS; do
    DRUSE_EXECUTED="$DRUSE_EXECUTED check_${stem}_controls.sh"
  done
fi

# --- every script on disk is accounted for -----------------------------------

DRUSE_UNRUN=""
for script in "$ROOT"/build/check*.sh; do
  name="$(basename "$script")"

  case "$DRUSE_LINT_ONLY_ALLOWED" in
    *" $name "*) continue ;;
  esac
  case " $DRUSE_EXECUTED " in
    *" $name "*) continue ;;
  esac

  DRUSE_UNRUN="$DRUSE_UNRUN
  build/$name"
done

if test -n "$DRUSE_UNRUN"; then
  fail "these control scripts are in build/ but the gate never executes them:$DRUSE_UNRUN

A script the gate only parses is a control that has stopped controlling — it
cannot tell you its mutation went stale, its probe tree stopped compiling, or
the suite it is named after stopped detecting. Wire it into build/check.sh, or
add it to DRUSE_LINT_ONLY_ALLOWED in $0 with the reason it does not run."
fi

DRUSE_COUNT="$(printf '%s' "$DRUSE_EXECUTED" | wc -w)"
echo "PASS: every control script in build/ is executed by the gate ($DRUSE_COUNT run, 5 exempt on the record)"
