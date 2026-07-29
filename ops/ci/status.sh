#!/usr/bin/env bash
set -euo pipefail

DRUSE_CI_STATE_DIR="${DRUSE_CI_STATE_DIR:-/var/lib/druse-ci}"
DRUSE_CI_STATUS="$DRUSE_CI_STATE_DIR/status"

if test ! -f "$DRUSE_CI_STATUS"; then
  echo "No VPS verification result has been recorded yet."
  exit 1
fi

printf '%s\n' "Druse VPS verification status"
sed 's/^/  /' "$DRUSE_CI_STATUS"
printf '\nRecent output:\n'
tail -n 20 "$DRUSE_CI_STATE_DIR/latest.log"
