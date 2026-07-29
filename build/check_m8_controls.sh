#!/usr/bin/env bash
# M8 — prove that the boot-sweep test guards both sides of the ownership line.
#
# A green sweep test is evidence only if it detects:
#   1. a framework that leaves its own crash residue behind; and
#   2. a framework that deletes files outside its own spool namespace.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_SOURCE="$URUQUIM_ROOT/web/internal/ingest/ingest.odin"

fail() {
  echo "M8-CONTROL-FAIL: $*" >&2
  exit 1
}

if test -n "${URUQUIM_COMPILER:-}"; then
  URUQUIM_ODIN="$URUQUIM_COMPILER"
elif test -n "${URUQUIM_ODIN_BIN:-}"; then
  URUQUIM_ODIN="$URUQUIM_ODIN_BIN"
elif command -v odin >/dev/null 2>&1; then
  URUQUIM_ODIN="$(command -v odin)"
elif test -x /tmp/uruquim-odin-toolchain/odin; then
  URUQUIM_ODIN=/tmp/uruquim-odin-toolchain/odin
else
  fail "odin compiler not found"
fi

URUQUIM_ODIN="$(readlink -f "$URUQUIM_ODIN")"
URUQUIM_ODIN_ROOT="$(cd "$(dirname "$URUQUIM_ODIN")" && pwd)"
URUQUIM_TMP="$(mktemp -d -t uruquim-m8-controls-XXXXXXXX)"

restore() {
  git -C "$URUQUIM_ROOT" checkout -- web/internal/ingest/ingest.odin 2>/dev/null || true
  rm -rf "$URUQUIM_TMP"
}
trap restore EXIT

git -C "$URUQUIM_ROOT" diff --quiet -- web/internal/ingest/ingest.odin ||
  fail "ingest.odin has uncommitted changes; the control restores that file"

run_red() {
  local label="$1" replacement="$2" expected="$3" out rc

  sed -i \
    "s/if !strings.has_prefix(entry.name, SPOOL_PREFIX) {/if $replacement {/" \
    "$URUQUIM_SOURCE"
  grep -qF "if $replacement {" "$URUQUIM_SOURCE" ||
    fail "mutation '$label' no longer applies to the prefix guard"

  set +e
  out="$(
    env ODIN_ROOT="$URUQUIM_ODIN_ROOT" PATH="$URUQUIM_ODIN_ROOT:/usr/bin:/bin" \
      timeout 120 "$URUQUIM_ODIN" test "$URUQUIM_ROOT/tests/m8-spool-sweep" \
      "-collection:uruquim=$URUQUIM_ROOT" -define:ODIN_TEST_THREADS=1 \
      -out:"$URUQUIM_TMP/$replacement" 2>&1
  )"
  rc=$?
  set -e

  git -C "$URUQUIM_ROOT" checkout -- web/internal/ingest/ingest.odin

  test "$rc" -ne 0 ||
    fail "mutation '$label' SURVIVED: the M8 suite stayed green"
  test "$rc" -ne 124 ||
    fail "mutation '$label' timed out instead of producing the expected assertion"
  grep -qF "$expected" <<<"$out" || {
    echo "$out" >&2
    fail "mutation '$label' failed for the wrong reason"
  }
  echo "M8 control: $label -> RED as required"
}

# Skip every candidate: the framework leaves both orphaned spools behind.
run_red \
  "orphan sweep disabled" \
  "true" \
  "an orphaned spool must be swept at boot"

# Skip no candidate: the framework crosses the namespace boundary and removes
# the application's files as well as its own.
run_red \
  "prefix ownership guard disabled" \
  "false" \
  "THE LINE THIS MUST NOT CROSS"

echo "PASS: M8 boot-sweep mutation controls"
