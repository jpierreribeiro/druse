#!/usr/bin/env bash
# WP51 — the vendor maintenance policy gate.
#
# The policy's own rules, made checkable. It holds three things a vendored
# dependency loses first and silently:
#
#   1. the PROVENANCE — a snapshot with no commit behind it is a fork nobody
#      declared;
#   2. the PATCH LEDGER — a patch that stops being listed is a divergence
#      nobody can re-apply at the next re-vendor;
#   3. the EVIDENCE RULE — that patches are proven by corpus, never by grep
#      over vendored text, because a correct re-application written differently
#      must still pass.
#
# It deliberately does NOT diff the vendored sources against upstream. That
# would need network access in the gate, and a gate that fails when GitHub is
# slow is a gate people learn to skip.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_POLICY="$DRUSE_ROOT/planning/vendor-policy.md"
DRUSE_VENDOR_DOC="$DRUSE_ROOT/vendor/odin-http/VENDOR.md"

fail() {
  echo "VENDOR-POLICY-FAIL: $*" >&2
  exit 1
}

test -f "$DRUSE_POLICY" || fail "planning/vendor-policy.md is missing; WP51 is the precondition for any package that patches the vendored server"
test -f "$DRUSE_VENDOR_DOC" || fail "vendor/odin-http/VENDOR.md is missing; the vendored snapshot has no provenance"

DRUSE_FLAT="$(sed -E 's/^[[:space:]]*>[[:space:]]?//' "$DRUSE_POLICY" | tr '\n' ' ' | tr -s ' ')"

# --- 1. Provenance -----------------------------------------------------------
# The pinned commit must appear in BOTH documents. A policy that names no commit
# is about a dependency in general; a vendor record with no commit is a copy.
grep -qF '112c49b' "$DRUSE_VENDOR_DOC" ||
  fail "vendor/odin-http/VENDOR.md no longer records the pinned upstream commit"
grep -qF '112c49b' "$DRUSE_POLICY" ||
  fail "the vendor policy no longer names the commit it governs"

# --- 2. The patch ledger is exact in both directions -------------------------
# The policy's disposition table and the vendored sources must agree, or one of
# them has drifted and nobody can tell which.
#
# DERIVED, NOT PINNED (Closure C-01). This test used to assert a literal count,
# which meant every new patch edited the gate to say a bigger number — a gate
# rewritten by the change it is supposed to judge tests nothing. Two derived
# invariants replace it, and neither needs touching when a patch is added:
#
#   a. the disposition table is a contiguous 1..N with no duplicate and no gap
#      — a removed row cannot hide behind a renumbering;
#   b. every NUMBERED marker in the vendored sources has a row in that table —
#      a patch applied without a disposition is one nobody knows whether to
#      re-apply. (Patches 1-5 predate numbered markers and carry the
#      `DRUSE PATCH (WP9 D…)` form, so the source side is checked as a
#      subset, never as an equality.)
DRUSE_POLICY_NUMS="$(grep -oE '^\| [0-9]+ \| .* \| .* \| \*\*(OFFER UPSTREAM|CARRY|APPEARS FIXED UPSTREAM)' "$DRUSE_POLICY" |
  awk -F'|' '{gsub(/ /, "", $2); print $2}' | sort -n)"
DRUSE_POLICY_ROWS="$(printf '%s\n' "$DRUSE_POLICY_NUMS" | grep -c . || true)"
test "$DRUSE_POLICY_ROWS" -gt 0 ||
  fail "the vendor policy carries no patch dispositions at all"
if ! diff <(printf '%s\n' "$DRUSE_POLICY_NUMS") <(seq 1 "$DRUSE_POLICY_ROWS") >/dev/null; then
  fail "the vendor policy's patch numbers are not exactly 1..$DRUSE_POLICY_ROWS (duplicate, gap or removed row)"
fi

DRUSE_SRC_NUMS="$(grep -rhoE 'DRUSE PATCH [0-9]+' "$DRUSE_ROOT"/vendor/odin-http/*.odin |
  awk '{print $3}' | sort -n -u)"
test -n "$DRUSE_SRC_NUMS" ||
  fail "no numbered 'DRUSE PATCH N' marker was found in the vendored sources; a divergence that is not marked at its site cannot be re-applied"
for DRUSE_N in $DRUSE_SRC_NUMS; do
  test "$DRUSE_N" -le "$DRUSE_POLICY_ROWS" ||
    fail "the vendored sources mark patch $DRUSE_N but the policy's disposition table stops at $DRUSE_POLICY_ROWS. A patch with no recorded disposition is one nobody knows whether to re-apply."
done

DRUSE_PATCH_MARKS="$(grep -rc 'DRUSE PATCH' "$DRUSE_ROOT"/vendor/odin-http/*.odin 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"
test "$DRUSE_PATCH_MARKS" -gt 0 ||
  fail "no 'DRUSE PATCH' marker was found in the vendored sources; a divergence that is not marked at its site cannot be re-applied"

# --- 3. Every patch states whether it is upstream's bug -----------------------
# The column that does the work: two of five are upstream bugs and three are
# deliberate divergences, and that ratio is what makes re-vendoring predictable.
grep -qiE 'is it upstream.s bug' "$DRUSE_POLICY" ||
  fail "the disposition table lost the column that says whether each patch fixes an UPSTREAM bug or encodes a deliberate divergence. Without it, a re-vendor cannot tell which patches might already be gone."

# --- 4. The corpus rule survives ---------------------------------------------
# This is the one most likely to be "improved" back into a grep, because a grep
# is easier to write.
grep -qiE 'proven by CORPUS, never by grep' <<<"$DRUSE_FLAT" ||
  fail "the policy no longer states that patches are proven by corpus rather than by grep over vendored text"
grep -qiE 'written differently, must still pass' <<<"$DRUSE_FLAT" ||
  fail "the policy lost the sentence explaining WHY: a correct re-application written differently must still pass. Without the reason, the rule reads as a preference and gets reversed."

DRUSE_CORPUS="$DRUSE_ROOT/tests/support/transport_conformance/corpus.odin"
test -f "$DRUSE_CORPUS" ||
  fail "the raw-wire corpus is missing; it is the executable evidence the policy points at"

# --- 5. The watch obligation is on the gate, not on memory -------------------
grep -qiE 'at every phase freeze' <<<"$DRUSE_FLAT" ||
  fail "the policy no longer places the upstream re-check at a phase freeze. An obligation on nobody in particular is an obligation nobody performs."
grep -qiE 'between freezes there is no watch' <<<"$DRUSE_FLAT" ||
  fail "the policy no longer admits that nothing watches upstream between freezes. Implying a vigilance nobody performs is worse than declaring the gap."

# --- 6. The rules a patch must satisfy ---------------------------------------
grep -qiE 'not a patch, it is a preference' <<<"$DRUSE_FLAT" ||
  fail "the policy lost its test for whether something is a patch at all: a change whose necessity no failing corpus case demonstrates"

if grep -nE '\b(TODO|FIXME|XXX|TBD)\b' "$DRUSE_POLICY"; then
  fail "the vendor policy contains an unfinished-work marker"
fi

echo "vendor policy: provenance pinned at 112c49b; $DRUSE_POLICY_ROWS patch dispositions recorded; $DRUSE_PATCH_MARKS in-source markers; corpus rule intact"
echo "PASS: vendor maintenance policy gate (WP51)"
