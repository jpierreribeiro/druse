#!/usr/bin/env bash
# WP66 — Phase-6 specification and governance gate.
#
# The phase has no implementation yet. Its deliverable is that the experiment
# cannot choose its own question, threshold or ownership boundary after seeing
# a result. This gate therefore pins the entry snapshot, owner amendments,
# liveness controls and one-way ecosystem dependency before WP67/WP69 begin.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_SPEC="$DRUSE_ROOT/planning/phase-6-spec.md"
DRUSE_PLAN="$DRUSE_ROOT/planning/phase-6-plan.md"
DRUSE_PROGRAM="$DRUSE_ROOT/planning/phases-6-8-program.md"

fail() {
  echo "PHASE6-SPEC-FAIL: $*" >&2
  exit 1
}

for DRUSE_FILE in \
  "$DRUSE_SPEC" \
  "$DRUSE_PLAN" \
  "$DRUSE_PROGRAM" \
  "$DRUSE_ROOT/planning/phase-7-plan.md" \
  "$DRUSE_ROOT/planning/phase-8-plan.md"; do
  test -f "$DRUSE_FILE" || fail "missing ${DRUSE_FILE#"$DRUSE_ROOT/"}"
done

DRUSE_FLAT="$(tr '\n' ' ' < "$DRUSE_SPEC" | tr -s ' ')"
DRUSE_ASYNC="$DRUSE_ROOT/planning/sync-async-evaluation.md"
DRUSE_QUESTIONS="$DRUSE_ROOT/planning/architecture-evidence-questions.md"

test -s "$DRUSE_ASYNC" || fail "the sync/async evidence program is missing"
test -s "$DRUSE_QUESTIONS" || fail "the architecture evidence backlog is missing"
test "$(grep -cE '^### [A-D] —' "$DRUSE_ASYNC")" -eq 4 ||
  fail "the sync/async shootout does not retain exactly four arms"
grep -q 'If async wins only long-lived streaming' "$DRUSE_ASYNC" ||
  fail "the specialised-async decision arm is missing"
grep -q '## 5. Crystals architecture' "$DRUSE_QUESTIONS" ||
  fail "Crystals have no evidence-backed architecture section"
grep -q 'Blank-machine setup' "$DRUSE_QUESTIONS" ||
  fail "the Crystal installation/usability control is missing"

# Entry is history. Later phases may grow the live ledger; the spec must keep
# saying what Phase 6 actually began from.
grep -q 'Phase 5 frozen at `6b6edbc`' "$DRUSE_SPEC" ||
  fail "entry commit is not the Phase-5 freeze"
grep -q '62 application + 2' "$DRUSE_SPEC" ||
  fail "entry ledger 62 + 2 is missing"
grep -q '\*\*Status:\*\* SPEC, 2026-07-21, WP66' "$DRUSE_SPEC" ||
  fail "WP66 status is not normative SPEC"

# The work-package sequence cannot silently gain or lose a package.
test "$(grep -cE '^\| (6[6-9]|7[0-9]|8[0-4]) \|' "$DRUSE_SPEC")" -eq 19 ||
  fail "the normative WP66-WP84 table does not contain exactly 19 packages"
test "$(grep -cE '^### WP(6[6-9]|7[0-9]|8[0-4]) ' "$DRUSE_PLAN")" -eq 19 ||
  fail "the execution plan does not contain exactly WP66-WP84"
test "$(grep -cE '^### WP(8[5-9]|9[0-9]|10[01]) ' "$DRUSE_ROOT/planning/phase-7-plan.md")" -eq 17 ||
  fail "the Phase-7 plan does not contain exactly WP85-WP101"
test "$(grep -cE '^### WP(10[2-9]|11[0-3]) ' "$DRUSE_ROOT/planning/phase-8-plan.md")" -eq 12 ||
  fail "the Phase-8 plan does not contain exactly WP102-WP113"

# ADR-030 is reopened on a different experiment, without rewriting its old
# throughput result.
case "$DRUSE_FLAT" in
  *"liveness, not throughput"*) ;;
  *) fail "ADR-030 is not explicitly reopened for liveness rather than throughput" ;;
esac
grep -q 'negative control, one lane' "$DRUSE_SPEC" ||
  fail "the one-lane negative control is missing"
grep -q 'candidate, four lanes' "$DRUSE_SPEC" ||
  fail "the four-lane candidate is missing"
grep -q 'three blocked Handlers' "$DRUSE_SPEC" ||
  fail "the lanes-1 liveness condition is missing"
grep -q '250 ms' "$DRUSE_SPEC" ||
  fail "the pre-registered liveness observation window is missing"
grep -q 'unblocked baseline is' "$DRUSE_SPEC" ||
  fail "the invalid-environment baseline rule is missing"

# Database backpressure is a relationship, not a claim that threads make
# saturation disappear.
grep -q 'pool capacity of' "$DRUSE_SPEC" ||
  fail "the database capacity control is missing"
grep -q 'configured 100 ms deadline' "$DRUSE_SPEC" ||
  fail "bounded pool acquisition has no fixed lab deadline"
grep -q 'pool capacity < lane' "$DRUSE_SPEC" ||
  fail "the control-capacity relationship is missing"
case "$DRUSE_FLAT" in
  *"full saturation:"*"may prevent health progress"*) ;;
  *) fail "full lane saturation is no longer stated honestly" ;;
esac

# Core/ecosystem direction and SQL philosophy are owner decisions, not details
# an implementation WP may reverse for convenience.
grep -q 'CE-E3 remains intact' "$DRUSE_SPEC" ||
  fail "CE-E3 is not preserved"
grep -q 'No server boot automatically migrates production' "$DRUSE_SPEC" ||
  fail "the no-auto-migrate rule is missing"
grep -q 'explicit pre-serve application call' "$DRUSE_PLAN" ||
  fail "the owner-approved in-band migration path is missing"
grep -q 'ahead-of-binary history refuses by default' "$DRUSE_PLAN" ||
  fail "the ahead-of-binary migration refusal is missing"
grep -q 'expand-contract' "$DRUSE_PLAN" ||
  fail "the forward-only expand-contract discipline is missing"
grep -q 'Directory SQL and' "$DRUSE_ROOT/planning/adrs.md" ||
  fail "directory/embedded migration source parity is missing"
grep -q 'No row mismatch becomes a' "$DRUSE_SPEC" ||
  fail "fail-closed row decoding is missing"
case "$DRUSE_FLAT" in
  *"invents no compatibility shim"*) ;;
  *) fail "the unreleased official adapter is being treated as an invented API" ;;
esac

# The plain-language owner record and permanent ADR record must agree.
grep -q 'Fase 6 é a classe “primeira aplicação real”' \
  "$DRUSE_ROOT/planning/decisoes-do-dono.md" ||
  fail "owner scope amendment is absent"
grep -q 'ADR-030 — Amendment 1: reopened for blocking-I/O liveness' \
  "$DRUSE_ROOT/planning/adrs.md" ||
  fail "ADR-030 liveness amendment is absent"
grep -q 'ADR-035 — first-real-application work may precede external demand' \
  "$DRUSE_ROOT/planning/adrs.md" ||
  fail "ADR-035 is absent"
grep -q 'ADR-036 — SQL-first data stack outside `web`' \
  "$DRUSE_ROOT/planning/adrs.md" ||
  fail "ADR-036 is absent"

# The old backlog and roadmap were the two places most likely to silently
# restore the contradicted rules.
grep -q 'Phase 6 — Real applications' "$DRUSE_ROOT/planning/roadmap.md" ||
  fail "roadmap has no Phase-6 section"
grep -q 'Phase 7 — Streaming foundation' "$DRUSE_ROOT/planning/roadmap.md" ||
  fail "roadmap has no Phase-7 section"
grep -q 'Phase 8 — Proof by use' "$DRUSE_ROOT/planning/roadmap.md" ||
  fail "roadmap has no Phase-8 section"
grep -q 'PHASE 6 CRYSTALS; STILL REJECTED FOR CORE' \
  "$DRUSE_ROOT/planning/later-phases-plan.md" ||
  fail "database work is not reconciled as Phase-6 Crystals"
grep -q 'PHASE 7, SPLIT OWNERSHIP' \
  "$DRUSE_ROOT/planning/later-phases-plan.md" ||
  fail "streaming is not reconciled as the Phase-7 split boundary"

# Phase 7 must solve the limitation Phase 5 recorded, while preserving the
# simple buffered path. Server push alone is no longer the approved plan.
grep -q 'opt-in large-body contract' "$DRUSE_ROOT/planning/phase-7-plan.md" ||
  fail "Phase 7 lost inbound large-body work"
grep -q 'large multipart never requires RAM proportional' \
  "$DRUSE_ROOT/planning/phase-7-plan.md" ||
  fail "Phase 7 has no bounded-memory large-upload exit gate"
grep -q 'buffered-only application links no stream' \
  "$DRUSE_ROOT/planning/phase-7-plan.md" ||
  fail "Phase 7 lost the common-path cost control"

if grep -qE '^- \[ \]' "$DRUSE_SPEC"; then
  fail "the Phase-6 spec contains an unchecked item"
fi

echo "phase-6 spec: entry 6b6edbc, ledger 62 + 2, WP66-WP84"
echo "phase-6 spec: liveness controls and bounded database capacity are pre-registered"
echo "phase-6 spec: SQL-first Crystals remain one-way; official adapter API is not guessed"
echo "phase-6 program: WP85-WP101 and WP102-WP113 are numbered and bounded"
echo "PASS: WP66 Phase-6 spec and governance gate"
