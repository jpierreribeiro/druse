#!/usr/bin/env bash
# WP39/WP40 — the specification-gate controls.
#
# The WP25 protocol, applied to `check_phase4_spec.sh`: each control mutates a
# THROWAWAY copy of the spec so a specific property is no longer stated, and
# requires the gate to REJECT it — for the right reason, matched on the message.
#
#   1  a lifecycle state deleted            -> rejected
#   2  a sixth state added                  -> rejected
#   3  a proof obligation deleted           -> rejected
#   4  "wait forever is not a deadline" softened -> rejected
#   5  the vendored-drain finding deleted   -> rejected
#   6  a capacity row loses its reservation cell -> rejected
#   7  the reservation rule weakened to "at zero" -> rejected
#   8  POSITIVE: the real spec passes
#
# Controls 6 and 7 are the ones worth having. **The reservation is the column
# that will be filled in with "n/a" under time pressure**, and the inequality
# ("at or below", never "at zero") is the difference between a server that can
# shut down under load and one that cannot. Both failures would leave a spec
# that still looks complete.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_DOC="planning/phase-4-spec.md"

fail() {
  echo "WP39-CONTROL-FAIL: $*" >&2
  exit 1
}

DRUSE_W39_TMP="$(mktemp -d -t druse-wp39-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_W39_TMP"' EXIT

tree_copy() { # name
  local t="$DRUSE_W39_TMP/$1"
  mkdir -p "$t"
  cp -r "$DRUSE_ROOT/build" "$DRUSE_ROOT/planning" "$t/"
  printf '%s' "$t"
}

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

assert_green() { # tree label
  bash "$1/build/check_phase4_spec.sh" >/dev/null 2>&1 ||
    fail "BROKEN PROBE ($2): the spec gate is not green BEFORE the mutation"
}

must_reject() { # tree label expected-regex
  local out
  if out="$(bash "$1/build/check_phase4_spec.sh" 2>&1)"; then
    echo "$out" >&2
    fail "control '$2' was ACCEPTED by the spec gate; the property it breaks is not actually checked"
  fi
  grep -qiE "$3" <<<"$out" ||
    { echo "$out" >&2; fail "control '$2' was rejected for the WRONG reason; expected /$3/"; }
  echo "CONTROL $2 -> REJECTED by the spec gate as required"
}

# --- 1. a lifecycle state deleted --------------------------------------------
T="$(tree_copy state_deleted)"
assert_green "$T" "1: state deleted"
H="$(md5sum "$T/$DRUSE_DOC" | cut -d' ' -f1)"
sed -i '/^| `Draining` |/d' "$T/$DRUSE_DOC"
assert_mutated "state deleted" "$T/$DRUSE_DOC" "$H"
must_reject "$T" "1: a lifecycle state is deleted" "state rows, not 5"

# --- 2. a sixth state added ---------------------------------------------------
# Exact in BOTH directions. A closed enum that quietly grows is no longer one a
# reviewer can enumerate, which is the entire property §1.1 buys.
T="$(tree_copy state_added)"
assert_green "$T" "2: sixth state added"
H="$(md5sum "$T/$DRUSE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_DOC" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "| `Failed` |"
i = s.index(anchor)
j = s.index("\n", i) + 1
s = s[:j] + "| `Paused` | An invented sixth state | no | maybe |\n" + s[j:]
open(p, "w").write(s)
PYEOF
assert_mutated "sixth state added" "$T/$DRUSE_DOC" "$H"
must_reject "$T" "2: a sixth lifecycle state is added" "state rows, not 5"

# --- 3. a proof obligation deleted -------------------------------------------
# The obligations are what WP44 is graded on. The temptation at implementation
# time is to grade against what was built, and a missing obligation makes that
# invisible rather than arguable.
T="$(tree_copy obligation_deleted)"
assert_green "$T" "3: obligation deleted"
H="$(md5sum "$T/$DRUSE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_DOC" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("**Cleanup runs exactly once.**", "**Cleanup is tidy.**", 1)
open(p, "w").write(s)
PYEOF
assert_mutated "obligation deleted" "$T/$DRUSE_DOC" "$H"
must_reject "$T" "3: a proof obligation is deleted" "cleanup exactly once"

# --- 4. the anti-pattern softened --------------------------------------------
# "Wait forever" is the vendored server's CURRENT behaviour, so dropping the
# sentence does not remove a warning — it hides a live defect.
T="$(tree_copy forever_softened)"
assert_green "$T" "4: wait-forever softened"
H="$(md5sum "$T/$DRUSE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_DOC" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('**"Wait forever" is not a deadline**', "**Waiting is discouraged**", 1)
open(p, "w").write(s)
PYEOF
assert_mutated "wait-forever softened" "$T/$DRUSE_DOC" "$H"
must_reject "$T" "4: the wait-forever anti-pattern is softened" "waiting forever is not a deadline"

# --- 5. the vendored-drain finding deleted -----------------------------------
# Without §1.2, WP44 starts from "expose what is already there", which is false
# and would ship a hang.
T="$(tree_copy finding_deleted)"
assert_green "$T" "5: vendored finding deleted"
H="$(md5sum "$T/$DRUSE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_DOC" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("drain loop has no deadline", "drain loop is straightforward", 1)
open(p, "w").write(s)
PYEOF
assert_mutated "vendored finding deleted" "$T/$DRUSE_DOC" "$H"
must_reject "$T" "5: the vendored no-deadline finding is deleted" "drain loop has NO deadline"

# --- 6. a capacity row loses its reservation ---------------------------------
# THE ONE THAT MATTERS. Under time pressure the reservation column is what gets
# emptied, and the row still looks like a row.
T="$(tree_copy row_hollowed)"
assert_green "$T" "6: reservation cell emptied"
H="$(md5sum "$T/$DRUSE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_DOC" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p).read()
m = re.search(r"^\| R-6 \|.*$", s, re.M)
assert m, "R-6 row not found"
row = m.group(0)
cells = row.split("|")
# `split("|")` is 0-indexed and the leading/trailing pipes produce empty ends,
# so the reserved-for-stop column is cells[6] -- awk's $7. The first version of
# this probe emptied cells[7], which is the TRAILING EMPTY: the file changed, so
# the md5 guard passed, and the control reported a gate hole that did not exist.
# A probe that mutates the wrong cell is worse than no probe, because it
# accuses.
assert "yes" in cells[6], "probe is aimed at the wrong column: %r" % cells[6]
cells[6] = "  "
open(p, "w").write(s[:m.start()] + "|".join(cells) + s[m.end():])
PYEOF
assert_mutated "reservation cell emptied" "$T/$DRUSE_DOC" "$H"
must_reject "$T" "6: a capacity row's reservation cell is emptied" "EMPTY column"

# --- 7. the reservation rule weakened ----------------------------------------
# "Refuse at zero" and "refuse at or below the reservation" read almost the
# same and differ by whether the server can still shut itself down.
T="$(tree_copy rule_weakened)"
assert_green "$T" "7: reservation rule weakened"
H="$(md5sum "$T/$DRUSE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_DOC" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("at or below the reservation", "at zero", 1)
open(p, "w").write(s)
PYEOF
assert_mutated "reservation rule weakened" "$T/$DRUSE_DOC" "$H"
must_reject "$T" "7: the reservation rule is weakened to 'at zero'" "AT OR BELOW the reservation"

# --- 8. POSITIVE control ------------------------------------------------------
# Controls 1-7 are all satisfied by deleting the spec. This is the half that
# requires the real document to be there and to pass.
T="$(tree_copy positive)"
bash "$T/build/check_phase4_spec.sh" >/dev/null 2>&1 ||
  fail "POSITIVE control failed: the real spec does not pass its own gate"
echo "CONTROL 8: the real spec passes its gate -> GREEN as required [positive control]"

echo "PASS: all eight WP39/WP40 specification controls behaved as required"
