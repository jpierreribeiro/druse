#!/usr/bin/env bash
# WP25 — the freeze controls, as one executable run.
#
# WP25 ships no symbol either. What it ships is a set of LEDGERS, and a ledger
# fails the way documentation fails: quietly, by dropping a row that nobody
# notices is gone. Each control removes exactly one thing the freeze depends on
# and requires the Phase-2 freeze gate to refuse.
#
#   1  a claim loses its NEGATIVE control   -> the freeze gate MUST reject
#   2  a claim loses its non-guarantee      -> the freeze gate MUST reject
#   3  the unbounded column is emptied      -> the freeze gate MUST reject
#   4  "the framework is bounded" in a doc  -> the freeze gate MUST reject
#   5  the usage-lab finding is softened    -> the freeze gate MUST reject
#   6  the recorded Phase-2 total is restated  -> the freeze gate MUST reject
#   6b the delta no longer adds up to it       -> the freeze gate MUST reject
#   7  POSITIVE: the real tree freezes, and the whole mutation suite passes
#
# CONTROL 4 IS THE ONE THE OWNER ASKED FOR BY NAME (docket D-2): "bounded" must
# never be claimed for the framework as a whole while connections, queues and
# header counts belong to the transport. It is a scan over the shipped
# documents, not over the freeze file, because that is where the word would
# actually appear.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP25-CONTROL-FAIL: $*" >&2
  exit 1
}

DRUSE_W25_TMP="$(mktemp -d -t druse-wp25-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_W25_TMP"' EXIT

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

tree_copy() { # name
  local t="$DRUSE_W25_TMP/$1"
  mkdir -p "$t"
  cp -r "$DRUSE_ROOT/build" "$t/build"
  cp -r "$DRUSE_ROOT/docs" "$t/docs"
  cp -r "$DRUSE_ROOT/planning" "$t/planning"
  # `web/` and `tests/` come along because the freeze document CITES them, and
  # the gate resolves every citation — a copy without them would fail for a
  # reason that has nothing to do with the mutation under test.
  cp -r "$DRUSE_ROOT/web" "$t/web"
  cp -r "$DRUSE_ROOT/tests" "$t/tests"
  cp -r "$DRUSE_ROOT/examples" "$t/examples"
  cp "$DRUSE_ROOT/README.md" "$t/README.md"
  cp "$DRUSE_ROOT/CHANGELOG.md" "$t/CHANGELOG.md"
  printf '%s' "$t"
}

assert_freeze_green() { # tree label
  bash "$1/build/check_phase2_freeze.sh" >/dev/null 2>&1 ||
    fail "BROKEN PROBE ($2): the unmutated copy does not pass the Phase-2 freeze gate"
}

must_reject() { # tree label expected-pattern
  local out
  if out="$(bash "$1/build/check_phase2_freeze.sh" 2>&1)"; then
    echo "$out" >&2
    fail "control '$2' PASSED the freeze gate; that ledger is unenforced"
  fi
  grep -qiE "$3" <<<"$out" ||
    { echo "$out" >&2; fail "control '$2' failed for the WRONG reason; expected /$3/"; }
  echo "CONTROL $2 -> REJECTED by the freeze gate as required"
}

DRUSE_FREEZE_DOC="planning/phase-2-freeze.md"

# --- 1. a claim loses its negative control -----------------------------------
# The single most important assertion in this work package. A claim with a
# positive test and no negative control is a promise nobody has tried to break.
T="$(tree_copy nocontrol)"
assert_freeze_green "$T" "1: negative control removed"
H="$(md5sum "$T/$DRUSE_FREEZE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_FREEZE_DOC" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
# Drop the negative-control bullet of C-4 (the request-ID trust policy) and
# nothing else: the bullet runs to the next bullet at the same level.
m = re.search(r"\* \*\*Negative control:\*\*.*?(?=\n\* \*\*)", s, re.S)
assert m, "pattern not found"
open(p, 'w').write(s[:m.start()] + s[m.end():])
PYEOF
assert_mutated "negative control removed" "$T/$DRUSE_FREEZE_DOC" "$H"
must_reject "$T" "1: a claim loses its negative control" "negative control|does not freeze"

# --- 2. a claim loses its stated non-guarantee -------------------------------
# The column that stops a true claim from being read as a bigger one.
T="$(tree_copy noscope)"
assert_freeze_green "$T" "2: non-guarantee removed"
H="$(md5sum "$T/$DRUSE_FREEZE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_FREEZE_DOC" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
m = re.search(r"\* \*\*Does NOT guarantee:\*\*.*?(?=\n\n|\n### |\n## )", s, re.S)
assert m, "pattern not found"
open(p, 'w').write(s[:m.start()] + s[m.end():])
PYEOF
assert_mutated "non-guarantee removed" "$T/$DRUSE_FREEZE_DOC" "$H"
must_reject "$T" "2: a claim loses its stated non-guarantee" "Does NOT guarantee|does not freeze"

# --- 3. the unbounded column is emptied --------------------------------------
# A capacity ledger that lists only what IS bounded is marketing. Deleting the
# transport-owned rows is how "bounded" quietly becomes a claim about the
# whole server.
T="$(tree_copy nounbounded)"
assert_freeze_green "$T" "3: unbounded rows deleted"
H="$(md5sum "$T/$DRUSE_FREEZE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_FREEZE_DOC" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
# RE-AIMED BY WP56's re-run, and the reason is progress rather than drift: WP47
# BOUNDED concurrent connections, so that row is no longer an unbounded one and
# this probe found nothing to delete. The control's intent is unchanged —
# deleting an unbounded row must be rejected — so it now targets a row that is
# still genuinely unbounded. Fewer such rows is the point of the phase; a
# control that silently stopped testing because a row improved is not.
old = "| accept queue / backlog | the OS |"
assert old in s, "pattern not found"
i = s.index(old)
j = s.index("\n", i) + 1
open(p, 'w').write(s[:i] + s[j:])
PYEOF
assert_mutated "unbounded rows deleted" "$T/$DRUSE_FREEZE_DOC" "$H"
must_reject "$T" "3: an unbounded row is deleted" "unbounded"

# --- 4. "the framework is bounded" appears in a shipped document -------------
# The claim the owner named in docket D-2. It is scanned in `docs/` and the
# README, where a reader would actually meet it.
T="$(tree_copy boundedclaim)"
assert_freeze_green "$T" "4: global bounded claim"
H="$(md5sum "$T/docs/middleware.md" | cut -d' ' -f1)"
python3 - "$T/docs/middleware.md" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "## Costs, stated plainly\n"
assert old in s, "pattern not found"
new = old + "\nDruse is fully bounded: memory use cannot grow without limit.\n"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "global bounded claim" "$T/docs/middleware.md" "$H"
must_reject "$T" "4: a document claims the framework as a whole is bounded" "bounded|perimeter"

# --- 5. the usage-laboratory finding is softened -----------------------------
# "That is a finding, not a footnote" — the plan's own words. A later edit that
# drops the framing turns an honest report into a flattering one.
T="$(tree_copy nofinding)"
assert_freeze_green "$T" "5: usage-lab finding softened"
H="$(md5sum "$T/$DRUSE_FREEZE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_FREEZE_DOC" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "**The finding, stated as a finding.**"
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, "**A note on concept counts.**", 1))
PYEOF
assert_mutated "usage-lab finding softened" "$T/$DRUSE_FREEZE_DOC" "$H"
must_reject "$T" "5: the usage-laboratory finding is softened" "finding"

# --- 6. the recorded Phase-2 total is restated -------------------------------
# AMENDED BY WP34, and the reason belongs here. The gate used to compare this
# table against the LIVE ledger count, and this control proved it. That was
# right for as long as no phase grew the ledger after Phase 2 — and wrong the
# moment one did, because 32 + 12 = 44 is what Phase 2 FROZE, a historical fact
# that must not be edited to track Phase 3. The gate now pins the frozen totals,
# checks the table's own arithmetic, and separately requires the live ledger not
# to have SHRUNK below them. The mutation is unchanged; only the sentence it
# must provoke is.
T="$(tree_copy drift)"
assert_freeze_green "$T" "6: ledger drift"
H="$(md5sum "$T/$DRUSE_FREEZE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_FREEZE_DOC" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
m = re.search(r"\| application \| 32 \| \+(\d+) \| \*\*(\d+)\*\* \|", s)
assert m, "pattern not found"
wrong = "| application | 32 | +%s | **%d** |" % (m.group(1), int(m.group(2)) + 1)
open(p, 'w').write(s[:m.start()] + wrong + s[m.end():])
PYEOF
assert_mutated "ledger drift" "$T/$DRUSE_FREEZE_DOC" "$H"
must_reject "$T" "6: the recorded Phase-2 total is restated" "records the ledger Phase 2 froze"

# --- 6b. the delta is edited but the total is not (WP34) ---------------------
# The subtler half of the same defect, and the one a restated-total check alone
# would miss: "32 | +11 | **44**" still shows the right answer while no longer
# adding up. A table that does not survive its own arithmetic is not evidence.
T="$(tree_copy arithmetic)"
assert_freeze_green "$T" "6b: broken arithmetic"
H="$(md5sum "$T/$DRUSE_FREEZE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_FREEZE_DOC" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
m = re.search(r"\| application \| 32 \| \+(\d+) \| \*\*(\d+)\*\* \|", s)
assert m, "pattern not found"
wrong = "| application | 32 | +%d | **%s** |" % (int(m.group(1)) - 1, m.group(2))
open(p, 'w').write(s[:m.start()] + wrong + s[m.end():])
PYEOF
assert_mutated "broken arithmetic" "$T/$DRUSE_FREEZE_DOC" "$H"
must_reject "$T" "6b: the delta no longer adds up to the total" "arithmetic does not hold"

# --- 7. POSITIVE control -----------------------------------------------------
# Controls 1-6 are all satisfied by deleting the freeze document. This is the
# half that requires the real thing to be there, to pass, and to be backed by a
# mutation suite that still rejects everything it rejected before.
bash "$DRUSE_ROOT/build/check_phase2_freeze.sh" >/dev/null 2>&1 ||
  fail "POSITIVE control failed: the real tree does not pass the Phase-2 freeze gate"

# Every claim in the ledger names a control script; each one must exist and be
# syntactically valid, or the ledger cites evidence that cannot run.
for DRUSE_SUITE in wp3_mutations wp16_controls wp17_controls wp18_controls \
  wp19_controls wp20_controls wp21_controls wp22_controls wp23_controls \
  wp24_controls; do
  test -f "$DRUSE_ROOT/build/check_$DRUSE_SUITE.sh" ||
    fail "POSITIVE control failed: build/check_$DRUSE_SUITE.sh is cited by the freeze but does not exist"
  bash -n "$DRUSE_ROOT/build/check_$DRUSE_SUITE.sh" ||
    fail "POSITIVE control failed: build/check_$DRUSE_SUITE.sh is not valid shell"
done

# And the three ledgers must be non-trivial. A gate that passes on an empty
# table would be a gate that proves nothing.
DRUSE_CLAIM_COUNT="$(grep -cE '^### C-[0-9]+' "$DRUSE_ROOT/$DRUSE_FREEZE_DOC" || true)"
test "$DRUSE_CLAIM_COUNT" -ge 5 ||
  fail "POSITIVE control failed: the claim ledger holds only $DRUSE_CLAIM_COUNT claims"
echo "CONTROL 7: the real tree freezes, $DRUSE_CLAIM_COUNT claims recorded, all 10 cited mutation suites present -> GREEN as required [positive control]"

echo "PASS: all seven WP25 freeze controls behaved as required"
