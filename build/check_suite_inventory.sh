#!/usr/bin/env bash
#
# NO ORPHAN SUITES. Every test suite in the tree is run by a gate script, or is
# excluded on the record with a reason.
#
# WHY THIS IS ITS OWN FILE, and it is the point of the whole exercise. This
# detector was written inside build/check_test.sh, which build/check.sh only
# ever `bash -n`'s. It cannot do otherwise: check_test.sh is a META-TEST OF THE
# GATE — it invokes .githooks/pre-push and build/check.sh several times to prove
# the gate rejects an unpinned compiler and sanitises an ambient ODIN_ROOT — so
# calling it from check.sh would recurse forever. That exclusion is structurally
# correct and stays.
#
# The consequence was not. A detector built to catch "suites nobody runs"
# (commit f06c447) was itself only parsed, never executed, on every push for
# months. It could not detect its own case, and it did not: tests/nbio-timeout
# sits in the tree with three @(test) procedures, is named by no gate script,
# is in no exclusion list, and has never been executed by anything.
#
# So the detector moves out of the meta-test and into the gate, where the thing
# it protects actually lives. check_test.sh delegates here rather than keeping a
# second copy — two copies of a rule is how they drift (R-14: one canonical
# path, not two).

set -euo pipefail

DRUSE_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

test -d "$DRUSE_ROOT/tests" || fail "tests/ does not exist"
test -d "$DRUSE_ROOT/build" || fail "build/ does not exist"

# Suites excluded ON PURPOSE. Each needs a reason, because an exclusion without
# one is indistinguishable from an oversight — which is exactly how the two
# below were told apart from nbio-timeout, and nbio-timeout was the oversight.
#
#   wp118-accept-multishot -- proves multishot ACCEPT, which audit T7 names as
#                             the change this project actually indicated. It is
#                             evidence for future work, not a leftover of
#                             abandoned work: wiring it in would gate machinery
#                             that has no production consumer yet. (wp115,
#                             wp116 and wp117 tested the recv-multishot
#                             machinery that had NO consumer; that machinery and
#                             those suites were deleted together — audit T6.)
#   g76-scale-sockets      -- a scale laboratory. Its resource profile (a raised
#                             process descriptor limit, thousands of sockets) is
#                             not a gate property; running it on every push
#                             would make the gate's cost depend on the machine.
DRUSE_ORPHAN_ALLOWED=" wp118-accept-multishot g76-scale-sockets "

DRUSE_ORPHANS=""
for DRUSE_SUITE_DIR in "$DRUSE_ROOT"/tests/*/ "$DRUSE_ROOT"/tests/*/*/; do
  test -d "$DRUSE_SUITE_DIR" || continue
  ls "$DRUSE_SUITE_DIR"*.odin >/dev/null 2>&1 || continue
  grep -q "@(test)" "$DRUSE_SUITE_DIR"*.odin 2>/dev/null || continue

  DRUSE_SUITE_NAME="${DRUSE_SUITE_DIR#"$DRUSE_ROOT"/tests/}"
  DRUSE_SUITE_NAME="${DRUSE_SUITE_NAME%/}"

  case "$DRUSE_ORPHAN_ALLOWED" in
    *" $DRUSE_SUITE_NAME "*) continue ;;
  esac

  # Several suites are invoked through a loop variable rather than a literal
  # path — the wp69 lab subdirectories among them — so a bare-name match still
  # counts as "referenced"; a draft that matched only `tests/<name>` reported
  # three suites its own sibling loop had just wired in.
  #
  # But COMMENTS DO NOT COUNT, and that correction was earned the embarrassing
  # way: the first version of this file named `nbio-timeout` in its own header
  # while explaining that nbio-timeout was an orphan, and thereby cleared it.
  # Prose about a suite is not a gate script running it — which is the same
  # confusion, one level up, that this file exists to fix.
  # Three shapes count, and all three must be on a line that is not a comment:
  #   tests/<full name>          a literal invocation
  #   tests/<parent>             a lab whose subdirectories are reached through
  #                              a loop variable, e.g.
  #                              tests/wp69-concurrency-lab/$suite
  #   <full name>                a bare-name mention in real code
  DRUSE_SEEN=""
  for DRUSE_PATTERN in "tests/$DRUSE_SUITE_NAME" \
                       "tests/${DRUSE_SUITE_NAME%%/*}" \
                       "$DRUSE_SUITE_NAME"; do
    if grep -rhF "$DRUSE_PATTERN" "$DRUSE_ROOT/build" 2>/dev/null |
         grep -qv '^[[:space:]]*#'; then
      DRUSE_SEEN=yes
      break
    fi
  done
  test -n "$DRUSE_SEEN" && continue

  DRUSE_ORPHANS="$DRUSE_ORPHANS $DRUSE_SUITE_NAME"
done

if test -n "$DRUSE_ORPHANS"; then
  fail "these test suites are in the tree but no gate script runs them:$DRUSE_ORPHANS. A suite nobody runs is not coverage — wire it into build/check.sh, or add it to DRUSE_ORPHAN_ALLOWED in $0 with the reason."
fi

echo "PASS: every test suite is either gated or deliberately exempt"

# --- THE GATE MAY ONLY NAME PATHS THE REPOSITORY ACTUALLY HAS ----------------
#
# The rule that would have caught the mistake above before it was pushed.
#
# `build/check.sh` runs on machines that do not have this working copy: a fresh
# clone, GitHub Actions, the VPS verifier. A path that exists here and not in
# the repository makes the gate pass locally and fail everywhere else, and the
# local pass is what the author sees. That is rule 4 with the machine as the
# hidden variable — the run is green for a reason it does not name, and the
# reason is "this directory happens to exist on this disk".
#
# This repository HAD a whole cluster in that position, excluded through
# `.git/info/exclude` (per-clone, unversioned): tests/nbio-timeout,
# experiments/23-accept-stall, experiments/24-shutdown-race, ops/campaign/ and
# planning/verification-campaign-plan.md — the last being where the rule
# "every reported number must be regenerable from a committed script" is
# written. All were committed on 2026-07-31 (OQ-34). This check is what makes
# the next one impossible to miss rather than something to remember.
#
# Skipped when git is unavailable or this is not a work tree — the check needs
# the index to answer its question, and guessing is worse than abstaining.
if command -v git >/dev/null 2>&1 &&
   git -C "$DRUSE_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then

  DRUSE_UNTRACKED_REFS=""
  while IFS= read -r suite; do
    test -n "$suite" || continue
    test -e "$DRUSE_ROOT/tests/$suite" || continue
    git -C "$DRUSE_ROOT" ls-files --error-unmatch "tests/$suite" >/dev/null 2>&1 && continue
    DRUSE_UNTRACKED_REFS="$DRUSE_UNTRACKED_REFS
  tests/$suite — named in build/check.sh, absent from the repository"
  done < <(
    sed -n '/^for DRUSE_UNGATED in/,/; do$/p' "$DRUSE_ROOT/build/check.sh" |
    sed 's/^for DRUSE_UNGATED in//; s/; do$//; s/\\$//' | tr ' ' '\n' | grep -v '^$'
  )

  if test -n "$DRUSE_UNTRACKED_REFS"; then
    fail "the gate names test suites that are not in the repository:$DRUSE_UNTRACKED_REFS

They exist in this working copy and nowhere else, so build/check.sh passes here
and fails on a fresh clone, in CI, and on the VPS verifier. Commit the suite, or
take it out of the gate and exempt it above with the reason."
  fi
  echo "PASS: every suite the gate names is tracked in the repository"
fi
