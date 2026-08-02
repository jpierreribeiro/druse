#!/usr/bin/env bash
# R1-WP07 — run the frozen command set against a clean commit and preserve it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT="$ROOT/evidence/$(date -u +%F)-r1-freeze"
fail() { echo "R1-FREEZE-RUN-FAIL: $*" >&2; exit 1; }
test -z "$(git -C "$ROOT" status --porcelain)" || fail "candidate working tree is dirty"
test ! -e "$OUTPUT" || fail "output already exists: $OUTPUT"

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
TREE="$(git -C "$ROOT" rev-parse HEAD^{tree})"
WORK="$(mktemp -d -t druse-r1-freeze-run-XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT
START="$(date -u +%FT%T.%3NZ)"

run() {
  local name=$1; shift
  DRUSE_R1_FREEZE_GENERATING=1 "$@" > "$WORK/$name.log" 2>&1 || {
    tail -n 80 "$WORK/$name.log" >&2
    fail "$name failed"
  }
}

run check-supported-profile bash "$ROOT/build/check_supported_profile.sh"
run check-supervisor-contract bash "$ROOT/build/check_supervisor_contract.sh"
run check-r1-shutdown-controls bash "$ROOT/build/check_r1_shutdown_controls.sh"
run check-proxy-config bash "$ROOT/build/check_proxy_config.sh"
run check-pilot-runbooks bash "$ROOT/build/check_pilot_runbooks.sh"
run check-pilot-exercise bash "$ROOT/build/check_pilot_exercise.sh"
run check-r1-freeze bash "$ROOT/build/check_r1_freeze.sh"
run full-gate bash "$ROOT/build/check.sh"
grep -Fq 'PASS: the gate left no test-runner binary in the working tree' "$WORK/full-gate.log" || fail "full gate terminal marker missing"

mkdir -p "$OUTPUT/raw"
cp "$WORK"/*.log "$OUTPUT/raw/"
END="$(date -u +%FT%T.%3NZ)"
cat > "$OUTPUT/manifest.txt" <<EOF
campaign=R1-WP07-freeze
start_utc=$START
end_utc=$END
candidate_commit=$COMMIT
candidate_tree=$TREE
pilot_candidate_commit=$(awk -F= '$1 == "candidate_commit" {print $2}' "$ROOT/evidence/2026-08-02-r1-pilot-exercise/manifest.txt")
owner=jpierreribeiro
decision=PROMOTE_TO_R1
production_authorized=false
EOF
cat > "$OUTPUT/commands.txt" <<'EOF'
bash build/check_supported_profile.sh
bash build/check_supervisor_contract.sh
bash build/check_r1_shutdown_controls.sh
bash build/check_proxy_config.sh
bash build/check_pilot_runbooks.sh
bash build/check_pilot_exercise.sh
bash build/check_r1_freeze.sh
bash build/check.sh
EOF
{
  uname -a
  odin version
  systemd --version | head -n 1
  docker version --format 'docker={{.Server.Version}}'
} > "$OUTPUT/environment.txt"
cat > "$OUTPUT/verdict.md" <<EOF
# R1-WP07 freeze verdict

**Decision: PROMOTE TO R1 — internal, non-critical controlled pilot only.**

Candidate \`$COMMIT\` passed the frozen command set and the integral gate. All
seven P0/P1 findings have a closed or explicit R1-only disposition, the WP06
rollback campaign verifies, and the profile retains an owner and abort policy.

This is not critical or general production approval. R2 remains blocked on its
own soak instrument, immutable-candidate soak, capacity, security and canary
evidence.
EOF
(
  cd "$OUTPUT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
  sha256sum -c SHA256SUMS >/dev/null
)
echo "PASS: R1-WP07 freeze campaign"
echo "evidence: $OUTPUT"
