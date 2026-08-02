#!/usr/bin/env bash
# Copy a committed fixture into a scratch directory, with the live hash pins
# substituted.
#
#   usage: materialise.sh FIXTURE_NAME DESTINATION [criteria_sha] [schema_sha]
#
# A run pins criteria_sha256 and schema_sha256 so a criterion cannot be edited
# between a run and its grade. A committed fixture therefore cannot carry the
# literal hashes: it would go red on every unrelated edit to CRITERIA.md, and a
# control that fails for reasons of its own is one people learn to skip.
#
# The optional third and fourth arguments exist for the negative control that
# needs a DELIBERATELY WRONG pin — proving the analyser notices a criteria file
# that moved after the run.
set -euo pipefail

FIXTURE="${1:?usage: materialise.sh FIXTURE DESTINATION [criteria_sha] [schema_sha]}"
DEST="${2:?usage: materialise.sh FIXTURE DESTINATION [criteria_sha] [schema_sha]}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOAK="$(cd "$HERE/.." && pwd)"

test -d "$HERE/$FIXTURE" || {
  echo "no such fixture: $FIXTURE" >&2
  exit 1
}

CRITERIA_SHA="${3:-$(sha256sum "$SOAK/CRITERIA.md" | awk '{print $1}')}"
SCHEMA_SHA="${4:-$(sha256sum "$SOAK/schema.md" | awk '{print $1}')}"

rm -rf "$DEST"
mkdir -p "$DEST"
cp -R "$HERE/$FIXTURE/." "$DEST/"
rm -f "$DEST/EXPECT.json"

sed -i \
  -e "s|@CRITERIA_SHA256@|$CRITERIA_SHA|" \
  -e "s|@SCHEMA_SHA256@|$SCHEMA_SHA|" \
  "$DEST/manifest.txt"

if grep -q '@[A-Z_]*@' "$DEST/manifest.txt"; then
  echo "fixture $FIXTURE has an unsubstituted placeholder:" >&2
  grep -n '@[A-Z_]*@' "$DEST/manifest.txt" >&2
  exit 1
fi
