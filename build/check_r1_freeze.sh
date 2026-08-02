#!/usr/bin/env bash
# R1-WP07 — evidence-backed controlled-pilot freeze and decision gate.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FREEZE="$ROOT/planning/readiness/R1-freeze.md"
PLAN="$ROOT/planning/readiness/R1-controlled-pilot.md"
PROFILE="$ROOT/docs/supported-profile.md"
POLICY="$ROOT/ops/deploy/pilot-profile.env"

fail() { echo "R1-FREEZE-FAIL: $*" >&2; exit 1; }
for file in "$FREEZE" "$PLAN" "$PROFILE" "$POLICY"; do
  test -s "$file" || fail "missing freeze input: ${file#$ROOT/}"
done

doc_check() {
  local file=$1
  grep -Fq '**Decision: PROMOTE TO R1 — internal, non-critical controlled pilot only.**' "$file" || {
    echo 'decision is absent or wider than the controlled pilot'; return 1;
  }
  for id in AUD-P0-001 AUD-P1-002 AUD-P1-003 AUD-P1-004 AUD-P1-005 AUD-P1-006 AUD-P1-007; do
    test "$(grep -Ec "^\\| $id \\|" "$file")" -eq 1 || {
      echo "$id does not have exactly one disposition"; return 1;
    }
  done
  test "$(grep -Ec '^\| AUD-P[01]-00[1-7] \| (CLOSED|ACCEPTED-R1) \|' "$file")" -eq 7 || {
    echo 'a P0/P1 disposition is neither CLOSED nor ACCEPTED-R1'; return 1;
  }
  grep -Fq 'AUD-P1-003 deliberately continues to' "$file" &&
    grep -Fq 'R2-WP01 repairs the soak instrument' "$file" || {
      echo 'the stale soak risk lost its R2 owner and mitigation'; return 1;
    }
  grep -Fq 'expires before any production traffic' "$file" || {
    echo 'the no-soak acceptance lost its expiry'; return 1;
  }
  grep -Fq 'response cap is not an OOM guarantee' "$file" || {
    echo 'the response-memory limitation was hidden'; return 1;
  }
  grep -Fq 'arbitrary synchronous Handler is not preempted' "$file" || {
    echo 'the Handler preemption limitation was hidden'; return 1;
  }
  grep -Fq 'What R1 still does not prove' "$file" || {
    echo 'the freeze lost its non-guarantees'; return 1;
  }
}
if ! DOC_ERROR="$(doc_check "$FREEZE")"; then fail "$DOC_ERROR"; fi

grep -Fq '**Status:** PROMOTED TO R1' "$PLAN" || fail "R1 plan is not marked promoted"
grep -Fq 'R1-WP07 | implementado; freeze e decisão verdes' "$PLAN" || fail "R1-WP07 board is not closed"
grep -Fq 'internal, non-critical controlled pilot' "$PROFILE" || fail "normative profile lost the R1 boundary"
grep -Fxq 'DRUSE_PILOT_OWNER=jpierreribeiro' "$POLICY" || fail "pilot owner drifted"

for dir in \
  evidence/2026-08-01-r1-entry \
  evidence/2026-08-01-r1-shutdown \
  evidence/2026-08-01-r1-resource-budget \
  evidence/2026-08-02-r1-real-proxy \
  evidence/2026-08-02-r1-pilot-exercise; do
  test -s "$ROOT/$dir/manifest.txt" || fail "evidence manifest missing: $dir"
done

# The two earliest packages predate SHA256SUMS, so require their manifests to be
# tracked and unchanged. Newer campaign packages verify their own file set.
for legacy in evidence/2026-08-01-r1-entry/manifest.txt evidence/2026-08-01-r1-shutdown/manifest.txt; do
  git -C "$ROOT" ls-files --error-unmatch "$legacy" >/dev/null 2>&1 || fail "legacy manifest is not tracked: $legacy"
  git -C "$ROOT" diff --quiet HEAD -- "$legacy" || fail "legacy manifest changed outside its recorded commit: $legacy"
done
for dir in evidence/2026-08-01-r1-resource-budget evidence/2026-08-02-r1-real-proxy evidence/2026-08-02-r1-pilot-exercise; do
  test -s "$ROOT/$dir/SHA256SUMS" || fail "SHA256SUMS missing: $dir"
  (cd "$ROOT/$dir" && sha256sum -c SHA256SUMS >/dev/null) || fail "evidence hashes do not verify: $dir"
done

PILOT="$ROOT/evidence/2026-08-02-r1-pilot-exercise"
value() { awk -F= -v key="$1" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$2"; }
PILOT_CANDIDATE="$(value candidate_commit "$PILOT/manifest.txt")"
PILOT_PREVIOUS="$(value previous_commit "$PILOT/manifest.txt")"
test "$(git -C "$ROOT" rev-parse "$PILOT_CANDIDATE^")" = "$PILOT_PREVIOUS" || fail "WP06 rollback is not the candidate parent"
git -C "$ROOT" merge-base --is-ancestor "$PILOT_CANDIDATE" HEAD || fail "WP06 candidate is not an ancestor"
test "$(value decision "$PILOT/manifest.txt")" = PROMOTE_TO_R1 || fail "WP06 decision drifted"
grep -Fq 'NRestarts=1' "$PILOT/raw/systemd-after-crash.txt" || fail "WP06 restart proof is absent"
grep -Fq 'campaign-complete decision=PROMOTE_TO_R1' "$PILOT/raw/timeline.tsv" || fail "WP06 did not complete"

TMP="$(mktemp -d -t druse-r1-freeze-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mutant() {
  local name=$1 expected=$2 expression=$3
  cp "$FREEZE" "$TMP/freeze.md"
  sed -i "$expression" "$TMP/freeze.md"
  if out="$(doc_check "$TMP/freeze.md")"; then fail "$name freeze mutant was accepted"; fi
  grep -Fq "$expected" <<<"$out" || fail "$name mutant failed for wrong reason: $out"
  echo "r1 freeze control: $name rejected for the expected reason"
}
mutant widened-decision 'decision is absent or wider' 's/internal, non-critical controlled pilot only/restricted production/'
mutant missing-risk 'AUD-P1-003 does not have exactly one disposition' '/^| AUD-P1-003 |/d'
mutant hidden-memory 'response-memory limitation was hidden' 's/response cap is not an OOM guarantee/response cap guarantees bounded memory/'

FREEZE_EVIDENCE="$ROOT/evidence/2026-08-02-r1-freeze"
if test ! -d "$FREEZE_EVIDENCE"; then
  test "${DRUSE_R1_FREEZE_GENERATING:-0}" = 1 || fail "freeze evidence is absent; run ops/verification/run-r1-freeze.sh from a clean commit"
  echo "r1 freeze evidence: generation mode, pending full gate"
  echo "PASS: R1-WP07 freeze inputs and controls (evidence pending in runner)"
  exit 0
fi

for file in manifest.txt verdict.md commands.txt environment.txt SHA256SUMS raw/full-gate.log \
  raw/check-supported-profile.log raw/check-supervisor-contract.log \
  raw/check-r1-shutdown-controls.log raw/check-proxy-config.log \
  raw/check-pilot-runbooks.log raw/check-pilot-exercise.log raw/check-r1-freeze.log; do
  test -s "$FREEZE_EVIDENCE/$file" || fail "freeze evidence missing: $file"
done
(cd "$FREEZE_EVIDENCE" && sha256sum -c SHA256SUMS >/dev/null) || fail "freeze evidence hashes do not verify"
FREEZE_CANDIDATE="$(value candidate_commit "$FREEZE_EVIDENCE/manifest.txt")"
FREEZE_TREE="$(value candidate_tree "$FREEZE_EVIDENCE/manifest.txt")"
test "$(git -C "$ROOT" rev-parse "$FREEZE_CANDIDATE^{tree}")" = "$FREEZE_TREE" || fail "freeze candidate tree does not match"
git -C "$ROOT" merge-base --is-ancestor "$FREEZE_CANDIDATE" HEAD || fail "freeze candidate is not an ancestor"
test "$(value decision "$FREEZE_EVIDENCE/manifest.txt")" = PROMOTE_TO_R1 || fail "freeze manifest decision drifted"
grep -Fq 'PASS: the gate left no test-runner binary in the working tree' "$FREEZE_EVIDENCE/raw/full-gate.log" || fail "freeze full gate lacks terminal marker"
for log in "$FREEZE_EVIDENCE"/raw/check-*.log; do
  grep -Fq 'PASS:' "$log" || fail "targeted freeze log has no PASS marker: ${log##*/}"
done
grep -Fq '**Decision: PROMOTE TO R1 — internal, non-critical controlled pilot only.**' "$FREEZE_EVIDENCE/verdict.md" || fail "preserved freeze verdict widened"

echo "PASS: R1-WP07 controlled-pilot freeze and preserved evidence verify"
