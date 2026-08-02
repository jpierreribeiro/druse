#!/usr/bin/env bash
# R1-WP05 — controlled-pilot policy, runbooks and entry/exit checklist.
set -euo pipefail

VERIFY_ONLY=0
if test "${1:-}" = --verify-only; then
  VERIFY_ONLY=1
  shift
fi
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
POLICY="$ROOT/ops/deploy/pilot-profile.env"
DEPLOY="$ROOT/docs/runbooks/pilot-deployment.md"
INCIDENT="$ROOT/docs/runbooks/incident-response.md"
ROLLBACK="$ROOT/docs/runbooks/rollback.md"
CHECKLIST="$ROOT/ops/verification/pilot-checklist.md"

fail() { echo "PILOT-RUNBOOK-FAIL: $*" >&2; exit 1; }
command -v rg >/dev/null 2>&1 || fail "rg is required for placeholder detection"
for file in "$POLICY" "$DEPLOY" "$INCIDENT" "$ROLLBACK" "$CHECKLIST"; do
  test -s "$file" || fail "missing required artifact: ${file#$ROOT/}"
done
bash -n "$POLICY" || fail "pilot-profile.env is not shell-compatible"

expect_policy() {
  grep -Fxq "$1" "$POLICY" || fail "$2"
}
expect_policy 'DRUSE_PILOT_PROFILE=r1-controlled-pilot' "profile identity changed"
expect_policy 'DRUSE_PILOT_OWNER=jpierreribeiro' "named on-call owner missing"
expect_policy 'DRUSE_PILOT_WINDOW_MINUTES=60' "attended window is not 60 minutes"
expect_policy 'DRUSE_PILOT_MAX_RPS=10' "initial load is not capped at 10 rps"
expect_policy 'DRUSE_PILOT_MAX_CONCURRENCY=20' "client concurrency is not capped at 20"
expect_policy 'DRUSE_PILOT_MAX_STREAMS=2' "stream concurrency is not capped at two"
expect_policy 'DRUSE_PILOT_MAX_UPLOADS=1' "upload concurrency is not capped at one"
expect_policy 'DRUSE_PILOT_ALLOWED_PATH_PREFIX=/pilot/' "route allowlist prefix changed"
expect_policy 'DRUSE_PILOT_DATA_CLASS=synthetic-or-reconstructible' "non-critical data class missing"
expect_policy 'DRUSE_PILOT_MAX_5XX_PERCENT=1' "5xx abort threshold changed"
expect_policy 'DRUSE_PILOT_MAX_P99_MS=500' "latency abort threshold changed"
expect_policy 'DRUSE_PILOT_MAX_MEMORY_PERCENT=80' "memory abort threshold changed"
expect_policy 'DRUSE_PILOT_MAX_SATURATION_EVENTS=0' "saturation is no longer an immediate abort"
expect_policy 'DRUSE_PILOT_ROLLBACK_MINUTES=5' "rollback objective changed"

ALL="$DEPLOY $INCIDENT $ROLLBACK $CHECKLIST"
for file in $ALL; do
  grep -Fq 'docs/supported-profile.md' "$file" ||
    fail "${file#$ROOT/} does not bind itself to the supported profile"
  if rg -n '\b(TODO|FIXME|TBD|CHANGEME)\b|<[^>]+>' "$file"; then
    fail "${file#$ROOT/} contains an unresolved placeholder"
  fi
done

deploy_flat="$(tr '\n' ' ' < "$DEPLOY" | tr -s ' ')"
incident_flat="$(tr '\n' ' ' < "$INCIDENT" | tr -s ' ')"
rollback_flat="$(tr '\n' ' ' < "$ROLLBACK" | tr -s ' ')"
checklist_flat="$(tr '\n' ' ' < "$CHECKLIST" | tr -s ' ')"

grep -Fq '## Abort criteria' "$DEPLOY" || fail "deployment abort criteria missing"
grep -Fq '10 requests/s sustained and 20 concurrent clients' <<<"$deploy_flat" ||
  fail "deployment runbook drifted from load policy"
grep -Fq '`/health`, `/ready` and `/pilot/*` only' <<<"$deploy_flat" ||
  fail "deployment route allowlist missing"
grep -Fq 'synthetic or reconstructible, non-critical' <<<"$deploy_flat" ||
  fail "deployment data restriction missing"
grep -Fq 'Required dashboards and alerts' "$DEPLOY" || fail "dashboard/alert contract missing"
for signal in 'proxy' 'application' 'supervisor' 'cgroup/process' 'spool'; do
  grep -Fq "| $signal |" "$DEPLOY" || fail "dashboard layer missing: $signal"
done

for symptom in 'bind failure' 'memlock/preflight failure' 'OOM' 'crash loop' 'blocked drain' 'saturation' 'proxy/TLS' 'spool quota/orphan'; do
  grep -Fq "| $symptom |" "$INCIDENT" || fail "incident diagnosis missing: $symptom"
done
grep -Fq 'stop admission' <<<"${incident_flat,,}" || fail "incident response does not stop admission first"

grep -Fq 'binary, `runtime-limits`, `pilot-profile`, Caddy configuration' <<<"$rollback_flat" ||
  fail "rollback does not define the coordinated bundle"
grep -Fq 'atomically repoint `current`' <<<"$rollback_flat" || fail "atomic rollback switch missing"
grep -Fq 'no irreversible data migration' <<<"$rollback_flat" || fail "irreversible migration exclusion missing"
grep -Fq 'at most five minutes' <<<"$rollback_flat" || fail "rollback objective missing"

for heading in '## Entry' '## Exercise' '## Exit'; do
  grep -Fq "$heading" "$CHECKLIST" || fail "checklist section missing: $heading"
done
grep -Fq 'binary and configuration rolled back together' <<<"$checklist_flat" ||
  fail "checklist permits split binary/config rollback"
grep -Fq '`PROMOTE TO R1`, `HOLD` or `ROLL BACK TO R0`' <<<"$checklist_flat" ||
  fail "checklist final decision set drifted"

echo "pilot runbooks: owner=jpierreribeiro window=60m load=10rps/20 clients routes=/pilot/* data=reconstructible rollback=5m"
test "$VERIFY_ONLY" -eq 0 || exit 0

TMP="$(mktemp -d -t druse-pilot-runbooks-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/ops/deploy" "$TMP/ops/verification" "$TMP/docs/runbooks"
cp "$POLICY" "$TMP/ops/deploy/"
cp "$DEPLOY" "$INCIDENT" "$ROLLBACK" "$TMP/docs/runbooks/"
cp "$CHECKLIST" "$TMP/ops/verification/"

run_mutant() {
  local name=$1 expected=$2 command=$3 target=$4
  cp "$ROOT/$target" "$TMP/$target"
  sed -i "$command" "$TMP/$target"
  if bash "$ROOT/build/check_pilot_runbooks.sh" --verify-only "$TMP" >"$TMP/$name.log" 2>&1; then
    fail "$name mutant was accepted"
  fi
  grep -Fq "$expected" "$TMP/$name.log" || {
    cat "$TMP/$name.log" >&2
    fail "$name mutant failed for the wrong reason (expected: $expected)"
  }
  cp "$ROOT/$target" "$TMP/$target"
  echo "pilot-runbook control: $name rejected for the expected reason"
}

run_mutant owner 'named on-call owner missing' \
  's/DRUSE_PILOT_OWNER=jpierreribeiro/DRUSE_PILOT_OWNER=/' \
  ops/deploy/pilot-profile.env
run_mutant load 'initial load is not capped at 10 rps' \
  's/DRUSE_PILOT_MAX_RPS=10/DRUSE_PILOT_MAX_RPS=100/' \
  ops/deploy/pilot-profile.env
run_mutant abort 'deployment abort criteria missing' \
  's/## Abort criteria/## Optional observations/' \
  docs/runbooks/pilot-deployment.md
run_mutant migration 'irreversible migration exclusion missing' \
  's/no irreversible data migration/irreversible data migration is allowed/' \
  docs/runbooks/rollback.md
run_mutant split-rollback 'checklist permits split binary/config rollback' \
  's/binary and configuration rolled back together/binary rolled back without configuration/' \
  ops/verification/pilot-checklist.md

echo "PASS: R1-WP05 controlled-pilot policy, runbooks and mutation controls"
