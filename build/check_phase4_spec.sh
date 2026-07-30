#!/usr/bin/env bash
# Phase-4 specification gate — WP39 (lifecycle) and WP40 (capacity ledger).
#
# WHY A SPEC NEEDS A GATE AT ALL. Phase 2's WP21 taught this: a zero-symbol work
# package still needs one, because its deliverable is a guarantee plus a
# statement, and an unchecked statement decays into folklore. The Phase-3 freeze
# taught the sharper half — a document can be accurate prose about the past and
# still mislead, and no check catches that unless one is written to.
#
# So this gate holds the SHAPE of `planning/phase-4-spec.md`, not its wording.
# It refuses the four ways a spec like this rots:
#
#   1. the state machine gains a state, loses one, or grows a boolean
#   2. a proof obligation quietly disappears before WP44 has to satisfy it
#   3. a capacity row appears without all five columns — especially the
#      reservation, which is the column the whole section exists for
#   4. the deadline stops being absolute, or "wait forever" creeps back in
#
# It runs in the main gate because a spec that only runs on demand is a spec
# nobody re-reads.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_P4S="$DRUSE_ROOT/planning/phase-4-spec.md"

fail() {
  echo "PHASE4-SPEC-FAIL: $*" >&2
  exit 1
}

test -f "$DRUSE_P4S" || fail "planning/phase-4-spec.md is missing"

# Prose wraps, and every assertion below is about prose. Read flattened, or a
# sentence that spans two lines reads as absent while sitting right there — the
# defect the Phase-3 freeze gate hit and fixed.
#
# BLOCKQUOTE MARKERS ARE STRIPPED FIRST, and that is not cosmetic: the load-
# bearing sentences in this spec are deliberately pulled out as block quotes, so
# flattening without stripping '>' turns exactly the most important lines into
# the ones the gate cannot see. Found by this gate failing on its own document.
DRUSE_FLAT="$(sed -E 's/^[[:space:]]*>[[:space:]]?//' "$DRUSE_P4S" | tr '\n' ' ' | tr -s ' ')"

# ---------------------------------------------------------------------------
# 1. The lifecycle is FIVE states, closed, and named.
#
# Exact in both directions: a sixth state is as much a defect as a missing one,
# because the point of a closed enum is that a reviewer can enumerate it.
# ---------------------------------------------------------------------------
for DRUSE_STATE in Configuring Serving Draining Stopped Failed; do
  grep -qF "\`$DRUSE_STATE\`" "$DRUSE_P4S" ||
    fail "the lifecycle no longer names the state '$DRUSE_STATE'. Five states, and a state machine you cannot enumerate is one you cannot audit."
done

# COUNTED IN BOTH DIRECTIONS, and the first version of this check was only
# counting one. It matched the five states BY NAME, so a sixth state invented
# under any other name left the count at five and passed — the gate could see a
# deletion and was blind to an addition. Found by control 2, which is exactly
# what a control is for. The count is now over every state-shaped row in the
# table, and the five names are verified separately above.
DRUSE_STATE_ROWS="$(grep -cE '^\| `[A-Z][A-Za-z_]*` \| .* \| (yes|no|\*\*yes\*\*|\*\*no\*\*) \|' "$DRUSE_P4S" || true)"
test "$DRUSE_STATE_ROWS" -eq 5 ||
  fail "the lifecycle table has $DRUSE_STATE_ROWS state rows, not 5. Adding a state is a spec amendment, not an edit — and a closed enum that quietly grows is no longer one a reviewer can enumerate."

# The whole point of §1.1: data, not booleans.
grep -qiE 'never a set of booleans|not a set of booleans' <<<"$DRUSE_FLAT" ||
  fail "the spec no longer says the lifecycle is data rather than booleans. That sentence IS the decision — three independent flags admit eight combinations, five of them nonsense."

# One-way transitions. A resumable drain is the convenience this refuses.
grep -qF 'Draining → Serving' "$DRUSE_P4S" ||
  fail "the spec no longer refuses the Draining -> Serving transition by name. A refusal that stops being written down is a refusal a later package adds back as a convenience."

# ---------------------------------------------------------------------------
# 2. The proof obligations survive to WP44.
#
# Each is written as a FAILURE in the spec so a test can trip it. This check
# exists because obligations are what a shutdown implementation is graded on,
# and the temptation at implementation time is to grade against what was built.
# ---------------------------------------------------------------------------
grep -qiE 'admission stops first' <<<"$DRUSE_FLAT" ||
  fail "proof obligation 1 (admission stops first, observably) is missing"
grep -qiE 'close-after-send, never close-mid-send' <<<"$DRUSE_FLAT" ||
  fail "proof obligation 2 (close-after-send) is missing"
grep -qiE 'deadline is ABSOLUTE' <<<"$DRUSE_FLAT" ||
  fail "proof obligation 3 (an absolute deadline) is missing"
grep -qiE 'cleanup runs exactly once' <<<"$DRUSE_FLAT" ||
  fail "proof obligation 4 (cleanup exactly once) is missing"
grep -qiE 'reservation still holds in .Draining.' <<<"$DRUSE_FLAT" ||
  fail "proof obligation 5 (the reservation holds while draining) is missing — the easiest to forget and the hardest to diagnose in production"

# "Wait forever" must stay named as the anti-pattern, not softened into silence.
grep -qiE '"Wait forever" is not a deadline' <<<"$DRUSE_FLAT" ||
  fail "the spec no longer states that waiting forever is not a deadline. It is the vendored server's CURRENT behaviour, so dropping the sentence hides a live defect."

# ---------------------------------------------------------------------------
# 3. What was READ rather than assumed stays in the document.
#
# §1.2 is the finding that changed what WP44 has to build: the vendored drain
# loop has no deadline. If that paragraph goes, WP44 starts from "expose what is
# already there", which is false and would ship a hang.
# ---------------------------------------------------------------------------
grep -qF '112c49b' "$DRUSE_P4S" ||
  fail "§1.2 no longer cites the vendored commit it was read against. A claim about someone else's code with no commit behind it is a memory, not a reading."
grep -qiE 'drain loop has no deadline' <<<"$DRUSE_FLAT" ||
  fail "the spec no longer records that the vendored drain loop has NO deadline. That gap is why WP44 is not merely 'expose what exists'."

# ---------------------------------------------------------------------------
# 4. The capacity ledger: every row answers all five questions.
#
# The table is parsed rather than eyeballed. A row with an empty cell is the
# failure mode this whole section exists to prevent — and the reservation column
# is the one that will be left blank, because it is the one that is hard.
# ---------------------------------------------------------------------------
DRUSE_ROWS="$(grep -E '^\| R-[0-9]+ \|' "$DRUSE_P4S" || true)"
DRUSE_ROW_COUNT="$(grep -c . <<<"$DRUSE_ROWS" || true)"
test "$DRUSE_ROW_COUNT" -ge 9 ||
  fail "the capacity ledger has $DRUSE_ROW_COUNT rows, fewer than the 9 the spec ratified. A resource that loses its row loses its bound."

while IFS= read -r DRUSE_ROW; do
  test -n "$DRUSE_ROW" || continue
  # 5 content columns between 6 pipes; a trailing pipe closes the row.
  DRUSE_CELLS="$(awk -F'|' '{print NF-2}' <<<"$DRUSE_ROW")"
  test "$DRUSE_CELLS" -eq 6 ||
    { echo "$DRUSE_ROW" >&2; fail "a capacity row does not carry exactly the id plus five columns (capacity, behaviour-when-full, diagnostic, cleanup owner, reserved-for-stop)"; }
  for DRUSE_COL in 3 4 5 6 7; do
    DRUSE_CELL="$(awk -F'|' -v c="$DRUSE_COL" '{gsub(/^[ \t]+|[ \t]+$/, "", $c); print $c}' <<<"$DRUSE_ROW")"
    test -n "$DRUSE_CELL" ||
      { echo "$DRUSE_ROW" >&2; fail "a capacity row has an EMPTY column. A row is not complete until it answers all five questions — and the blank one will be 'reserved for stop', because that is the hard one."; }
  done
done <<<"$DRUSE_ROWS"

# The reservation rule itself, and the inequality that makes it work.
grep -qiE 'at or below the reservation' <<<"$DRUSE_FLAT" ||
  fail "the reservation rule no longer states that admission is refused AT OR BELOW the reservation rather than at zero. 'When it reaches zero' is the bug this rule exists to prevent."
grep -qiE 'running out and having none left to shut down with' <<<"$DRUSE_FLAT" ||
  fail "§2.1 no longer states why the reservation column exists. Without that sentence the column reads as bookkeeping and gets filled in with 'n/a'."

# ---------------------------------------------------------------------------
# 5. The overload-diagnostic rule.
#
# Ten thousand refused connections must not produce ten thousand log lines. This
# is a denial of service the framework would perform on itself, and it is the
# kind of rule that is obvious in a spec and forgotten in an implementation.
# ---------------------------------------------------------------------------
grep -qiE 'amplifier, not a diagnostic' <<<"$DRUSE_FLAT" ||
  fail "§2.5's rule against per-event logging under overload is gone. A log line per refused connection turns a load spike into an I/O storm."

# ---------------------------------------------------------------------------
# 6. "Bounded" stays gated, and the rows do not over-claim.
# ---------------------------------------------------------------------------
grep -qiE 'they do not bound a handler.s own allocations' <<<"$DRUSE_FLAT" ||
  fail "the spec no longer disclaims what its rows do NOT bound. Server bounds are not framework bounds, and the gated word depends on that distinction holding."

# ---------------------------------------------------------------------------
# 6b. THE REDACTION POLICY (§3, WP50).
#
# The property this holds is not "no secrets" but "NO REQUEST-DERIVED BYTE",
# and the difference is what makes it enforceable: a do-not-log LIST can be
# incomplete and needs maintaining against attackers who read it too, while the
# rule needs no list and fails closed.
# ---------------------------------------------------------------------------
grep -qiE 'no request-derived byte reaches a log line' <<<"$DRUSE_FLAT" ||
  fail "§3 no longer states the redaction rule in its strong form. 'Do not log secrets' needs a definition of secret and a list somebody maintains; 'nothing derived from the request' needs neither and fails closed."

DRUSE_PERMITTED="$(grep -cE '^\| (the|a|framework) .*\*\*.* \| .* \|$' "$DRUSE_P4S" || true)"
test "$DRUSE_PERMITTED" -ge 7 ||
  fail "the permitted-to-record table has $DRUSE_PERMITTED rows, fewer than the 7 ratified. A row that vanishes is a field nobody can justify recording — or one nobody has to."

grep -qiE 'never be recorded' <<<"$DRUSE_FLAT" ||
  fail "§3 no longer states what may NEVER be recorded. A permitted list without its complement reads as guidance."

# The OWASP relationship, stated rather than implied. Without this sentence a
# later reader adds an `is_password_like()` check that gives false comfort.
grep -qiE 'recorded as motivation and the rule is what is enforced' <<<"$DRUSE_FLAT" ||
  fail "§3 no longer records that OWASP's do-not-log list is MOTIVATION and the strong rule is the MECHANISM. Enforcing the list instead of the rule would be weaker than what already ships."

grep -qiE 'forges additional log records' <<<"$DRUSE_FLAT" ||
  fail "§3 lost the log-injection half: a CR or LF in a permitted field turns a reader's evidence into an attacker's writing surface"

grep -qiE 'a metric that silently stops being emitted is worse than no metric' <<<"$DRUSE_FLAT" ||
  fail "§3.5 no longer requires the drop policy to be observable"
grep -qiE 'may never apply backpressure to a request' <<<"$DRUSE_FLAT" ||
  fail "§3.5 no longer forbids a logger applying backpressure to the serving path. Observation exists to describe the system, never to become the reason it is slow."
echo "phase-4 spec: the redaction rule is stated in its strong form; $DRUSE_PERMITTED permitted fields, each with a reason"

# ---------------------------------------------------------------------------
# 7. Unfinished work has no place in a ratified spec.
# ---------------------------------------------------------------------------
if grep -nE '\b(TODO|FIXME|XXX|TBD)\b' "$DRUSE_P4S"; then
  fail "planning/phase-4-spec.md contains an unfinished-work marker. A ratified spec cannot have open work in it."
fi

echo "phase-4 spec: lifecycle is 5 closed states with 5 proof obligations; $DRUSE_ROW_COUNT capacity rows, each answering all five questions"
echo "PASS: Phase-4 specification gate (WP39 lifecycle, WP40 capacity ledger)"
