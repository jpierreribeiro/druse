#!/usr/bin/env bash
#
# Regenerate the ADR-020 leak-shape measurement from committed code.
#
# This exists because this project requires every reported number to be
# regenerable from a committed script (a rule whose own document is not in the
# repository -- OQ-34 -- so it is restated here), and ADR-020's
# "8,250 bytes per recovered fault" is not: it came from an uncommitted WP13
# prototype of a REJECTED recovery fence, in a /tmp directory that no longer
# exists. See README.md — this measures the quantity the decision turns on, and
# does not pretend to reproduce the historical constant.
#
# Resolves the compiler the way build/check.sh does, and sanitises an ambient
# ODIN_ROOT so a stray environment cannot silently swap the toolchain.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

fail() {
  echo "ADR-020 LEAK SHAPE: ERROR: $*" >&2
  exit 1
}

if test -n "${DRUSE_ODIN_BIN:-}"; then
  COMPILER="$DRUSE_ODIN_BIN"
elif command -v odin >/dev/null 2>&1; then
  COMPILER="$(command -v odin)"
else
  fail "odin not found; install the pinned distribution or set DRUSE_ODIN_BIN"
fi

COMPILER="$(readlink -f "$COMPILER")" || fail "cannot resolve compiler: $COMPILER"
COMPILER_DIR="$(cd "$(dirname "$COMPILER")" && pwd)"

# The pin is checked rather than trusted: a number produced by a different
# toolchain is a number about a different program.
EXPECTED_COMMIT="$(sed -n 's/^commit=//p' "$ROOT/odin-version.txt")"
VERSION="$(ODIN_ROOT="$COMPILER_DIR" "$COMPILER" version 2>&1)" ||
  fail "compiler version check failed: $VERSION"
case "$VERSION" in
  *"$EXPECTED_COMMIT"*) ;;
  *) fail "compiler mismatch: odin-version.txt pins $EXPECTED_COMMIT, got: $VERSION" ;;
esac

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

echo "toolchain: $VERSION"
echo "building..."
env ODIN_ROOT="$COMPILER_DIR" PATH="$COMPILER_DIR:/usr/bin:/bin" \
  "$COMPILER" build "$HERE" "-collection:druse=$ROOT" -out:"$OUT/leak-shape" ||
  fail "the experiment did not compile"

echo "running (two arms, this takes minutes)..."
echo
"$OUT/leak-shape"
