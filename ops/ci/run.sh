#!/usr/bin/env bash
set -euo pipefail

DRUSE_CI_REPO_URL="${DRUSE_CI_REPO_URL:-https://github.com/jpierreribeiro/druse.git}"
DRUSE_CI_BRANCH="${DRUSE_CI_BRANCH:-main}"
DRUSE_CI_ROOT="${DRUSE_CI_ROOT:-/opt/druse-ci}"
DRUSE_CI_STATE_DIR="${DRUSE_CI_STATE_DIR:-/var/lib/druse-ci}"
DRUSE_ODIN_BIN="${DRUSE_ODIN_BIN:-/opt/druse/odin}"
DRUSE_CI_MIRROR="$DRUSE_CI_ROOT/mirror.git"
DRUSE_CI_STATUS="$DRUSE_CI_STATE_DIR/status"
DRUSE_CI_LOG="$DRUSE_CI_STATE_DIR/latest.log"

mkdir -p "$DRUSE_CI_ROOT" "$DRUSE_CI_STATE_DIR"

if test ! -d "$DRUSE_CI_MIRROR"; then
  git clone --mirror "$DRUSE_CI_REPO_URL" "$DRUSE_CI_MIRROR"
fi

git --git-dir="$DRUSE_CI_MIRROR" fetch --prune "$DRUSE_CI_REPO_URL" \
  "+refs/heads/$DRUSE_CI_BRANCH:refs/heads/$DRUSE_CI_BRANCH"

DRUSE_CI_COMMIT="$(git --git-dir="$DRUSE_CI_MIRROR" \
  rev-parse "refs/heads/$DRUSE_CI_BRANCH")"
DRUSE_CI_LAST_COMMIT="$(sed -n 's/^commit=//p' "$DRUSE_CI_STATUS" 2>/dev/null || true)"
DRUSE_CI_LAST_RESULT="$(sed -n 's/^result=//p' "$DRUSE_CI_STATUS" 2>/dev/null || true)"

if test "$DRUSE_CI_COMMIT" = "$DRUSE_CI_LAST_COMMIT" && \
   test "$DRUSE_CI_LAST_RESULT" = "pass"; then
  echo "Already verified: $DRUSE_CI_COMMIT"
  exit 0
fi

DRUSE_CI_WORK="$(mktemp -d /tmp/druse-ci.XXXXXX)"
cleanup() {
  rm -rf -- "$DRUSE_CI_WORK"
}
trap cleanup EXIT

git --git-dir="$DRUSE_CI_MIRROR" archive "$DRUSE_CI_COMMIT" |
  tar -x -C "$DRUSE_CI_WORK"

DRUSE_CI_STARTED="$(date +%s)"
cd "$DRUSE_CI_WORK"
set +e
env DRUSE_ODIN_BIN="$DRUSE_ODIN_BIN" \
  bash "$DRUSE_CI_WORK/build/check.sh" 2>&1 | tee "$DRUSE_CI_LOG"
DRUSE_CI_EXIT="${PIPESTATUS[0]}"
set -e
DRUSE_CI_FINISHED="$(date +%s)"
DRUSE_CI_DURATION="$((DRUSE_CI_FINISHED - DRUSE_CI_STARTED))"

if test "$DRUSE_CI_EXIT" -eq 0; then
  DRUSE_CI_RESULT=pass
else
  DRUSE_CI_RESULT=fail
fi

DRUSE_CI_STATUS_TMP="$(mktemp "$DRUSE_CI_STATE_DIR/.status.XXXXXX")"
{
  printf 'commit=%s\n' "$DRUSE_CI_COMMIT"
  printf 'branch=%s\n' "$DRUSE_CI_BRANCH"
  printf 'result=%s\n' "$DRUSE_CI_RESULT"
  printf 'checked_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'duration_seconds=%s\n' "$DRUSE_CI_DURATION"
} >"$DRUSE_CI_STATUS_TMP"
mv "$DRUSE_CI_STATUS_TMP" "$DRUSE_CI_STATUS"

echo "Verification $DRUSE_CI_RESULT: $DRUSE_CI_COMMIT"
exit "$DRUSE_CI_EXIT"
