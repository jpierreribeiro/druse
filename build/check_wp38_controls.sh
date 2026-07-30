#!/usr/bin/env bash
# WP38 — the Phase-3 freeze-gate controls.
#
# A freeze gate that cannot fail is a title page with a green tick on it. The
# WP25 protocol, applied to `check_phase3_freeze.sh`: each control mutates a
# THROWAWAY copy of the tree so that a specific freeze condition is no longer
# met, and requires the gate to REJECT it — for the right reason, matched on the
# message.
#
#   1  the ledger total restated          -> rejected
#   2  the delta no longer adds up        -> rejected
#   3  a frozen symbol dropped from the table -> rejected
#   4  the mutation-re-run FINDING softened   -> rejected
#   5  the failed cost measurement deleted    -> rejected
#   6  the usage-lab instrument removed       -> rejected
#   7  the guarded lab program pushed past 25 -> rejected (the ADR-029 stop)
#   8  POSITIVE: the real tree freezes
#
# Control 7 is the one the delegation itself turns on. ADR-029 made the freeze
# self-approving ONLY while the recorded criteria hold; a budget breach is a
# reserved matter that goes to the owner. If the gate did not actually stop, the
# delegation would have been a way of skipping the owner rather than a way of
# not stalling.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_DOC="planning/phase-3-freeze.md"

fail() {
  echo "WP38-CONTROL-FAIL: $*" >&2
  exit 1
}

DRUSE_W38_TMP="$(mktemp -d -t druse-wp38-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_W38_TMP"' EXIT

tree_copy() { # name
  local t="$DRUSE_W38_TMP/$1"
  mkdir -p "$t"
  cp -r "$DRUSE_ROOT/build" "$DRUSE_ROOT/planning" "$DRUSE_ROOT/experiments" "$t/"
  printf '%s' "$t"
}

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

assert_green() { # tree label
  bash "$1/build/check_phase3_freeze.sh" >/dev/null 2>&1 ||
    fail "BROKEN PROBE ($2): the freeze gate is not green BEFORE the mutation"
}

must_reject() { # tree label expected-message-regex
  local out
  if out="$(bash "$1/build/check_phase3_freeze.sh" 2>&1)"; then
    echo "$out" >&2
    fail "control '$2' was ACCEPTED by the freeze gate; the condition it breaks is not actually checked"
  fi
  grep -qiE "$3" <<<"$out" ||
    { echo "$out" >&2; fail "control '$2' was rejected for the WRONG reason; expected /$3/"; }
  echo "CONTROL $2 -> REJECTED by the freeze gate as required"
}

# --- 1. the ledger total restated --------------------------------------------
T="$(tree_copy restated)"
assert_green "$T" "1: ledger total restated"
H="$(md5sum "$T/$DRUSE_DOC" | cut -d' ' -f1)"
sed -i 's/| application | 44 | +6 | \*\*50\*\* |/| application | 44 | +6 | **51** |/' "$T/$DRUSE_DOC"
assert_mutated "ledger total restated" "$T/$DRUSE_DOC" "$H"
must_reject "$T" "1: the ledger total is restated" "records the ledger Phase 3 froze"

# --- 2. the delta no longer adds up ------------------------------------------
T="$(tree_copy arithmetic)"
assert_green "$T" "2: broken arithmetic"
H="$(md5sum "$T/$DRUSE_DOC" | cut -d' ' -f1)"
sed -i 's/| application | 44 | +6 | \*\*50\*\* |/| application | 44 | +5 | **50** |/' "$T/$DRUSE_DOC"
assert_mutated "broken arithmetic" "$T/$DRUSE_DOC" "$H"
must_reject "$T" "2: the delta no longer adds up" "arithmetic does not hold"

# --- 3. a frozen symbol dropped from the table -------------------------------
T="$(tree_copy dropped)"
assert_green "$T" "3: symbol dropped"
H="$(md5sum "$T/$DRUSE_DOC" | cut -d' ' -f1)"
sed -i '/^| `DEFAULT_LIMITS` | const | 36 | 12 |$/d' "$T/$DRUSE_DOC"
assert_mutated "symbol dropped" "$T/$DRUSE_DOC" "$H"
must_reject "$T" "3: a frozen symbol is dropped from the table" "does not record 'DEFAULT_LIMITS'"

# --- 4. the mutation-re-run finding softened ---------------------------------
# The suites still all pass; only the record of what re-running them FOUND is
# removed. That is the softening a freeze is most tempted by, because the
# remaining sentence ("thirteen suites, all green") is still true.
T="$(tree_copy softened)"
assert_green "$T" "4: re-run finding softened"
H="$(md5sum "$T/$DRUSE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_DOC" <<'PYEOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
for word in ("re-aimed", "stopped isolating", "stayed **green**", "stayed green"):
    s = s.replace(word, "reviewed")
open(p, "w").write(s)
PYEOF
assert_mutated "re-run finding softened" "$T/$DRUSE_DOC" "$H"
must_reject "$T" "4: the mutation-re-run finding is softened" "found a control that had stopped working"

# --- 5. the failed cost measurement deleted ----------------------------------
T="$(tree_copy costdrop)"
assert_green "$T" "5: failed measurement deleted"
H="$(md5sum "$T/$DRUSE_DOC" | cut -d' ' -f1)"
python3 - "$T/$DRUSE_DOC" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
for word in ("positive control", "Positive control", "POSITIVE CONTROL"):
    s = s.replace(word, "check")
open(p, "w").write(s)
PYEOF
assert_mutated "failed measurement deleted" "$T/$DRUSE_DOC" "$H"
must_reject "$T" "5: the failed cost measurement loses its positive control" "positive control"

# --- 6. the usage-lab instrument removed -------------------------------------
# Phase 2 kept only the number, which is why this re-run had to reconstruct the
# programs. Losing the instrument again must not be silent.
T="$(tree_copy noinstrument)"
assert_green "$T" "6: instrument removed"
rm -f "$T/experiments/11-usage-lab/count_concepts.sh"
must_reject "$T" "6: the usage-laboratory instrument is removed" "instrument"

# --- 7. the guarded lab program pushed past the budget -----------------------
# THE DELEGATION'S OWN STOPPING CONDITION. Over 25 concepts is a reserved
# matter: it goes to the owner, never into a raised ceiling.
T="$(tree_copy overbudget)"
assert_green "$T" "7: budget breached"
cat >>"$T/experiments/11-usage-lab/c-crud-phase3/main.odin" <<'ODIN'

// Three more concepts, to prove the budget is enforced rather than reported.
budget_probe :: proc(ctx: ^web.Context) {
	_ = web.route(ctx)
	_ = web.header(ctx, "X-Probe")
	web.bad_request(ctx, "probe")
}
ODIN
must_reject "$T" "7: the guarded program passes 25 concepts" "RESERVED MATTER|reserved matter"

# --- 8. POSITIVE control ------------------------------------------------------
# Controls 1-7 are all satisfied by deleting the freeze document. This is the
# half that requires the real thing to be there and to pass.
T="$(tree_copy positive)"
bash "$T/build/check_phase3_freeze.sh" >/dev/null 2>&1 ||
  fail "POSITIVE control failed: the real tree does not pass its own freeze gate"
echo "CONTROL 8: the real tree freezes -> GREEN as required [positive control]"

echo "PASS: all eight WP38 freeze-gate controls behaved as required"
