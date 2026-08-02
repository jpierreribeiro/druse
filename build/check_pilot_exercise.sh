#!/usr/bin/env bash
# R1-WP06 — deployment fixture/campaign controls and preserved-evidence audit.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG="$ROOT/ops/proxy/caddy/pilot.Caddyfile"
CAMPAIGN="$ROOT/ops/verification/run-pilot-exercise.sh"
SERVER="$ROOT/tests/r1-pilot-deployment/server"
CLIENT="$ROOT/tests/r1-pilot-deployment/client.py"
ODIN_BIN="${DRUSE_COMPILER:-${DRUSE_ODIN_BIN:-$(command -v odin || true)}}"

fail() { echo "PILOT-EXERCISE-FAIL: $*" >&2; exit 1; }
for file in "$CONFIG" "$CAMPAIGN" "$SERVER/main.odin" "$CLIENT"; do
  test -s "$file" || fail "missing WP06 artifact: ${file#$ROOT/}"
done
bash -n "$CAMPAIGN" || fail "pilot campaign has invalid shell syntax"
python3 - "$CLIENT" <<'PY'
import pathlib, sys
compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")
PY
test -x "$ODIN_BIN" || fail "Odin compiler is unavailable"
"$ODIN_BIN" check "$SERVER" "-collection:druse=$ROOT" -define:R1_PILOT_RELEASE=gate

config_check() {
  local file=$1
  grep -Fq 'handle /pilot/stream' "$file" || { echo 'stream route missing'; return 1; }
  grep -Fq 'flush_interval -1' "$file" || { echo 'stream flush policy missing'; return 1; }
  grep -Fq 'handle /pilot/*' "$file" || { echo 'pilot route allowlist missing'; return 1; }
  grep -Fq 'respond "outside R1 pilot allowlist" 404' "$file" || { echo 'fallback route is not rejected at proxy'; return 1; }
  grep -Fq 'health_uri /ready' "$file" || { echo 'active readiness check missing'; return 1; }
  ! grep -Eq 'lb_retries[[:space:]]+[1-9]' "$file" || { echo 'proxy retries enabled'; return 1; }
  test "$(grep -Ec 'lb_retries[[:space:]]+0' "$file")" -eq 4 || { echo 'zero-retry policy missing'; return 1; }
  grep -Fq 'request>headers delete' "$file" || { echo 'request headers enter access logs'; return 1; }
  grep -Fq 'resp_headers delete' "$file" || { echo 'response headers enter access logs'; return 1; }
  grep -Fq 'DRUSE_BUNDLE_ID:unconfigured' "$file" || { echo 'bundle configuration marker missing'; return 1; }
}
if ! CONFIG_ERROR="$(config_check "$CONFIG")"; then fail "$CONFIG_ERROR"; fi

# Syntax-adapt with the pinned image when it is already present; the gate never
# pulls implicitly. The full campaign performs caddy validate with real certs.
# shellcheck disable=SC1091
. "$ROOT/ops/proxy/caddy/image.env"
if docker image inspect "$DRUSE_CADDY_IMAGE" >/dev/null 2>&1; then
  docker run --rm --platform "$DRUSE_CADDY_PLATFORM" \
    -v "$CONFIG:/etc/caddy/Caddyfile:ro" "$DRUSE_CADDY_IMAGE" \
    caddy adapt --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
fi

TMP="$(mktemp -d -t druse-pilot-config-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mutant() {
  local name=$1 expected=$2 expression=$3
  cp "$CONFIG" "$TMP/Caddyfile"
  sed -i "$expression" "$TMP/Caddyfile"
  if out="$(config_check "$TMP/Caddyfile")"; then
    fail "$name config mutant was accepted"
  fi
  grep -Fq "$expected" <<<"$out" || fail "$name config mutant failed for wrong reason: $out"
  echo "pilot config control: $name rejected for the expected reason"
}
mutant buffering 'stream flush policy missing' '/flush_interval -1/d'
mutant fallback 'fallback route is not rejected at proxy' 's/respond "outside R1 pilot allowlist" 404/reverse_proxy {$DRUSE_UPSTREAM}/'
mutant retry 'proxy retries enabled' '0,/lb_retries 0/s//lb_retries 1/'
mutant logs 'request headers enter access logs' '/request>headers delete/d'

for token in \
  'git -C "$ROOT" worktree add --detach "$PREVIOUS_SOURCE" "$PREVIOUS_COMMIT"' \
  'mv -Tf .next current' \
  'systemd-run --user' \
  '--property=Restart=on-failure' \
  '--property=TimeoutStopSec=30s' \
  '--property=MemoryMax=1G' \
  'proxy-application-ready-after-drain' \
  'systemd-journal.failure.txt' \
  'coredumpctl --no-pager info' \
  'switch_bundle previous' \
  'decision=PROMOTE_TO_R1' \
  'sha256sum -c SHA256SUMS'; do
  grep -Fq -- "$token" "$CAMPAIGN" || fail "campaign lost required mechanism: $token"
done

echo "pilot exercise implementation: fixture builds, Caddy allowlist, real systemd/core and atomic rollback are wired"

EVIDENCE="$(find "$ROOT/evidence" -mindepth 1 -maxdepth 1 -type d -name '*-r1-pilot-exercise' | sort | tail -n 1)"
if test -z "$EVIDENCE"; then
  echo "pilot exercise evidence: pending clean committed campaign"
  echo "PASS: R1-WP06 implementation controls (evidence pending)"
  exit 0
fi

for file in manifest.txt verdict.md environment.txt commands.txt SHA256SUMS \
  raw/full-gate.log raw/timeline.tsv raw/low-load.json raw/coredump-info.txt \
  raw/systemd-after-drain.txt raw/systemd-after-crash.txt raw/systemd-after-rollback.txt \
  raw/systemd-final.txt raw/rollback-process.txt raw/smoke-candidate.body \
  raw/smoke-candidate.headers raw/smoke-previous.body raw/smoke-previous.headers; do
  test -s "$EVIDENCE/$file" || fail "preserved evidence missing: ${file}"
done
(
  cd "$EVIDENCE"
  sha256sum -c SHA256SUMS >/dev/null
) || fail "preserved evidence SHA256SUMS does not verify"
if find "$EVIDENCE" -type f \( -name '*key*' -o -name '*.key' \) -print -quit | grep -q .; then
  fail "private-key-shaped file entered preserved evidence"
fi

value() { awk -F= -v key="$1" '$1 == key {print substr($0, index($0, "=") + 1); exit}' "$EVIDENCE/manifest.txt"; }
CANDIDATE="$(value candidate_commit)"
PREVIOUS="$(value previous_commit)"
test -n "$CANDIDATE" && git -C "$ROOT" cat-file -e "$CANDIDATE^{commit}" || fail "candidate commit is not in repository history"
test -n "$PREVIOUS" && test "$(git -C "$ROOT" rev-parse "$CANDIDATE^")" = "$PREVIOUS" || fail "rollback artifact is not the candidate's actual parent"
git -C "$ROOT" merge-base --is-ancestor "$CANDIDATE" HEAD || fail "campaign candidate is not an ancestor of the audited tree"
test "$(value candidate_binary_sha256)" != "$(value previous_binary_sha256)" || fail "binary did not change across rollback"
test "$(value candidate_proxy_sha256)" != "$(value previous_proxy_sha256)" || fail "proxy config did not change across rollback"
test "$(value decision)" = PROMOTE_TO_R1 || fail "campaign decision is not PROMOTE_TO_R1"
test "$(value rollback_seconds)" -le 300 || fail "rollback exceeded five minutes"

grep -Fq 'PASS: the gate left no test-runner binary in the working tree' "$EVIDENCE/raw/full-gate.log" ||
  fail "campaign candidate full gate was not preserved green"
grep -Fq '"errors": 0' "$EVIDENCE/raw/low-load.json" || fail "low-load campaign had transport errors"
grep -Fq '"unexpected": 0' "$EVIDENCE/raw/low-load.json" || fail "low-load campaign had unexpected responses"
grep -Fq 'NRestarts=0' "$EVIDENCE/raw/systemd-after-drain.txt" || fail "normal drain restarted"
grep -Eq 'NRestarts=[1-9][0-9]*' "$EVIDENCE/raw/systemd-after-crash.txt" || fail "Handler fault did not restart"
grep -Fq 'Signal: 6 (ABRT)' "$EVIDENCE/raw/coredump-info.txt" || fail "fault core is not classified SIGABRT"
grep -Fq 'bundle=previous' "$EVIDENCE/raw/rollback-process.txt" || fail "rollback did not select previous bundle"
grep -Fq 'release=candidate sentinel=r1-integrity-v1' "$EVIDENCE/raw/smoke-candidate.body" || fail "candidate sentinel missing"
grep -Fq 'release=previous sentinel=r1-integrity-v1' "$EVIDENCE/raw/smoke-previous.body" || fail "rollback sentinel missing"
grep -iq '^x-r1-bundle: candidate' "$EVIDENCE/raw/smoke-candidate.headers" || fail "candidate config marker missing"
grep -iq '^x-r1-bundle: previous' "$EVIDENCE/raw/smoke-previous.headers" || fail "rollback config marker missing"
grep -Fq 'ActiveState=inactive' "$EVIDENCE/raw/systemd-final.txt" || fail "campaign did not leave the unit stopped"
for event in full-gate-pass previous-bundle-baseline-verified normal-drain-inactive handler-fault-recovered rollback-smoke-pass campaign-complete; do
  grep -Fq "$event" "$EVIDENCE/raw/timeline.tsv" || fail "timeline event missing: $event"
done
grep -Fq '**Decision: PROMOTE TO R1 — internal, non-critical controlled pilot only.**' "$EVIDENCE/verdict.md" ||
  fail "verdict widened or lost the R1 decision"

echo "PASS: R1-WP06 deploy, crash/restart, drain and rollback evidence verifies"
