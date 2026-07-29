#!/usr/bin/env bash
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! git -C "$DRUSE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: install-hooks must run inside the cloned Druse repository" >&2
  exit 1
fi

git -C "$DRUSE_ROOT" config core.hooksPath .githooks
echo "Installed Druse hooks: core.hooksPath=.githooks"
