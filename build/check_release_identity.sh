#!/usr/bin/env bash
# R2-WP08 — controls for the amended deployment-identity criterion.
#
# Readiness rule G2: an instrument proves itself before it measures anything.
# `verify-deployed.sh` is the instrument behind R2-WP08's exit criterion "the
# deployed hash is the approved hash", so it needs a POSITIVE that stays green
# and MUTANTS that go red FOR THE NAMED REASON. A control that only knows how to
# refuse is indistinguishable from one that is broken.
#
# The mutants are not invented. Each one is a way a hash check stops checking:
#
#   M1 one byte flipped              — the ordinary tamper
#   M2 same size, different content  — the exact shape the rebuild measurement
#                                      produced (918,640 bytes both ways), so a
#                                      length comparison would pass it
#   M3 approval record edited        — the expectation itself is the thing under
#                                      attack when someone wants a red gate green
#   M4 deployed file absent          — an unreadable target must not be a match
#   M5 approval record without a hash— comparing against "" matches every file
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPROVE="$DRUSE_ROOT/ops/release/approve-artefact.sh"
VERIFY="$DRUSE_ROOT/ops/release/verify-deployed.sh"

WORK="$(mktemp -d -t druse-release-identity-XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "RELEASE-IDENTITY-FAIL: $*" >&2; exit 1; }

test -x "$APPROVE" || fail "ops/release/approve-artefact.sh is missing or not executable"
test -x "$VERIFY"  || fail "ops/release/verify-deployed.sh is missing or not executable"

# A stand-in artefact. The criterion is about bytes, so the bytes need not be an
# ELF for the control to exercise every branch.
head -c 4096 /dev/urandom > "$WORK/artefact.bin"

# The approval is taken with the repository's own tree state, which on a working
# branch is usually dirty — and a dirty tree is a *deliberate* refusal in
# approve-artefact.sh. The control therefore takes its approval from a scratch
# directory that is not a git repository at all, so it exercises the hash path
# rather than the provenance path. Provenance is asserted separately below.
cd "$WORK"
bash "$APPROVE" "$WORK/artefact.bin" "$WORK/approval.txt" >/dev/null 2>&1 || true
grep -q '^artefact_sha256=[0-9a-f]\{64\}$' "$WORK/approval.txt" ||
  fail "approve-artefact.sh did not record a well-formed artefact_sha256"

# --- POSITIVE: the deployed file IS the approved file ------------------------
cp "$WORK/artefact.bin" "$WORK/deployed.bin"
if ! bash "$VERIFY" "$WORK/approval.txt" "$WORK/deployed.bin" "$WORK/p.txt" >/dev/null 2>&1; then
  cat "$WORK/p.txt" >&2 || true
  fail "POSITIVE went red: an unmodified deployment must verify"
fi
grep -q '^deployed_identity=match$' "$WORK/p.txt" ||
  fail "POSITIVE did not report deployed_identity=match"

# Every mutant must go red, and the report must say WHY in the words the
# criterion uses. `|| true` on each invocation: these exit non-zero by design,
# and `set -e` would kill this script with no message at all.
expect_red() { # label report-file expected-substring
  local label="$1" report="$2" needle="$3"
  grep -q '^verify=fail$' "$report" || fail "$label did not fail"
  grep -q '^deployed_identity=mismatch$' "$report" ||
    fail "$label failed without reporting deployed_identity=mismatch"
  grep -q "$needle" "$report" ||
    fail "$label went red for the wrong reason: expected '$needle' in the report"
}

# --- M1: one byte flipped ----------------------------------------------------
cp "$WORK/artefact.bin" "$WORK/m1.bin"
printf '\xff' | dd of="$WORK/m1.bin" bs=1 seek=100 count=1 conv=notrunc status=none
bash "$VERIFY" "$WORK/approval.txt" "$WORK/m1.bin" "$WORK/m1.txt" >/dev/null 2>&1 || true
expect_red "M1 (one byte flipped)" "$WORK/m1.txt" "identical size is not identity"

# --- M2: identical size, different content -----------------------------------
# The rebuild measurement's exact shape. If the instrument ever compares length,
# this is the mutant that stays green and it must not.
head -c 4096 /dev/urandom > "$WORK/m2.bin"
test "$(stat -c %s "$WORK/m2.bin")" = "$(stat -c %s "$WORK/artefact.bin")" ||
  fail "the control built M2 wrong: it must be the same size as the approved artefact"
bash "$VERIFY" "$WORK/approval.txt" "$WORK/m2.bin" "$WORK/m2.txt" >/dev/null 2>&1 || true
expect_red "M2 (same size, different content)" "$WORK/m2.txt" "identical size is not identity"

# --- M3: the approval record itself is edited --------------------------------
sed 's/^artefact_sha256=.*/artefact_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$WORK/approval.txt" > "$WORK/m3-approval.txt"
bash "$VERIFY" "$WORK/m3-approval.txt" "$WORK/deployed.bin" "$WORK/m3.txt" >/dev/null 2>&1 || true
grep -q '^verify=fail$' "$WORK/m3.txt" || fail "M3 (edited approval) did not fail"

# --- M4: the deployed file is absent -----------------------------------------
bash "$VERIFY" "$WORK/approval.txt" "$WORK/not-deployed.bin" "$WORK/m4.txt" >/dev/null 2>&1 || true
expect_red "M4 (deployed file absent)" "$WORK/m4.txt" "deployed_missing"

# --- M5: the approval record carries no hash ---------------------------------
grep -v '^artefact_sha256=' "$WORK/approval.txt" > "$WORK/m5-approval.txt"
bash "$VERIFY" "$WORK/m5-approval.txt" "$WORK/deployed.bin" "$WORK/m5.txt" >/dev/null 2>&1 || true
expect_red "M5 (approval with no hash)" "$WORK/m5.txt" "approval_unreadable"

# --- The provenance refusal, asserted on its own ------------------------------
# An approval taken over a dirty tree names a state no commit describes. This is
# the one branch the positive above deliberately steps around, so it is checked
# here rather than left untested.
DIRTY="$WORK/dirty-repo"
mkdir -p "$DIRTY/ops/release"
git -C "$DIRTY" init -q 2>/dev/null || fail "could not create the dirty-tree fixture"
git -C "$DIRTY" config user.email c@example.invalid
git -C "$DIRTY" config user.name control
cp "$APPROVE" "$DIRTY/ops/release/approve-artefact.sh"
echo pinned > "$DIRTY/odin-version.txt"
git -C "$DIRTY" add -A && git -C "$DIRTY" commit -qm base
echo "modified" >> "$DIRTY/odin-version.txt"
head -c 128 /dev/urandom > "$DIRTY/artefact.bin"
bash "$DIRTY/ops/release/approve-artefact.sh" "$DIRTY/artefact.bin" "$WORK/dirty-approval.txt" >/dev/null 2>&1 || true
grep -q '^approval=fail$' "$WORK/dirty-approval.txt" ||
  fail "approve-artefact.sh approved an artefact over a DIRTY working tree"

# --- The amendment must stay attached to the measurement that forced it -------
# R2-WP08's criterion changed after a measurement, which readiness rule G3 only
# permits when the amendment names it. If the evidence file goes away, the
# criterion is left standing on an argument nobody can check.
REBUILD_EVIDENCE="$DRUSE_ROOT/evidence/2026-08-03-r2-wp06-assurance/raw/rebuild-two-clean-clones.txt"
test -f "$REBUILD_EVIDENCE" ||
  fail "the measurement that forced the R2-WP08 amendment is missing: $REBUILD_EVIDENCE"
grep -q '^byte_identical=no$' "$REBUILD_EVIDENCE" ||
  fail "$REBUILD_EVIDENCE no longer records byte_identical=no; if the toolchain became reproducible, the amended criterion needs re-arguing rather than keeping"

PLAN="$DRUSE_ROOT/planning/readiness/R2-restricted-production.md"
grep -q 'o hash do artefato implantado é o hash aprovado' "$PLAN" ||
  fail "R2-restricted-production.md no longer carries the amended R2-WP08 exit criterion"

echo "RELEASE-IDENTITY-OK: positive green, five mutants red for their named reasons, provenance refusal held"
