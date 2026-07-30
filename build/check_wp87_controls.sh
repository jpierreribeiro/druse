#!/usr/bin/env bash
# WP87 — the stream/body lifecycle corpus is committed RED, under control.
#
# Three claims, each executable:
#   1. the buffered oracle is GREEN — so the RED below cannot be blamed on the
#      tree, and G7-10's byte pins exist before any streaming code does;
#   2. both lifecycle corpora fail COMPLETELY, and for the sentinel's reason
#      (`Unimplemented`), not for a compile error, a partial pass or an
#      unrelated fault — the WP67 vacuity lesson;
#   3. the pre-registered contract cases are all present by name, so a later
#      edit cannot quietly drop one and call the survivor set "the corpus".
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP87-CONTROL-FAIL: $*" >&2
  exit 1
}

if test -n "${DRUSE_COMPILER:-}"; then
  DRUSE_ODIN="$DRUSE_COMPILER"
elif test -n "${DRUSE_ODIN_BIN:-}"; then
  DRUSE_ODIN="$DRUSE_ODIN_BIN"
elif command -v odin >/dev/null 2>&1; then
  DRUSE_ODIN="$(command -v odin)"
elif test -x /tmp/druse-toolchain/odin; then
  DRUSE_ODIN=/tmp/druse-toolchain/odin
else
  fail "odin compiler not found"
fi

DRUSE_ODIN="$(readlink -f "$DRUSE_ODIN")"
DRUSE_ODIN_ROOT="$(cd "$(dirname "$DRUSE_ODIN")" && pwd)"
DRUSE_TMP="$(mktemp -d -t druse-wp87-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

run_green() { # package, output binary
  env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
    "$1" "-collection:druse=$DRUSE_ROOT" "-out:$DRUSE_TMP/$2"
}

run_expected_red() { # package, output binary, then diagnostic tokens...
  local package="$1" binary="$2"
  shift 2
  local output
  if output="$(env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
      "$package" "-collection:druse=$DRUSE_ROOT" \
      "-out:$DRUSE_TMP/$binary" 2>&1)"; then
    fail "$package unexpectedly passed before WP88/WP89/WP94 exist"
  fi
  for token in "$@"; do
    grep -qF "$token" <<<"$output" || {
      echo "$output" >&2
      fail "$package failed for the wrong reason; missing diagnostic token: $token"
    }
  done
}

# Claim 1 — the oracle: buffered behaviour is pinned and green today.
run_green "$DRUSE_ROOT/tests/wp87-buffered-oracle" oracle-green

# Claim 2/3, response side — STAGE ADVANCED BY WP88/WP89 (2026-07-23): the
# registry and cross-lane delivery are implemented, so the stream corpus is
# now required GREEN, unedited — the RED-under-control promise kept. The
# corpus completeness (every pre-registered case present by name) moves to
# check_wp88_controls.sh, next to the generation-check mutation control.
run_green "$DRUSE_ROOT/tests/wp87-stream-lifecycle" stream-green

# The inbound-body corpus — STAGE ADVANCED BY WP94 (2026-07-23): the spool
# substrate is implemented, so the body corpus is now required GREEN,
# unedited — the RED-under-control promise kept.
#
# AUDIT T6/M7: the sentence that used to end this paragraph pointed at
# check_wp94_controls.sh "alongside the multipart fragmentation proof". Both
# are gone. The streaming multipart parser they guarded had zero product
# consumers — the shipped upload path spools raw bytes — and its own finding
# recorded that wiring it would have been pathological, so it was deleted
# rather than left as a trap for whoever wired it next.
run_green "$DRUSE_ROOT/tests/wp87-body-lifecycle" body-green

# `package web` itself (the public core) still imports NEITHER private
# lifecycle package — only the transport boundary may (ADR-009). The stream
# package is wired there (WP90b); ingest is wired there by WP94's adapter step.
# Match IMPORT lines, not prose: a doc comment may name the package it wraps.
if grep -nE '^[[:space:]]*import[[:space:]].*"druse:web/internal/(stream|ingest)"' \
  "$DRUSE_ROOT/web"/*.odin >/dev/null 2>&1; then
  fail "package web imports a private lifecycle package directly; only the transport boundary may (ADR-009)"
fi

echo "wp87: buffered oracle green — G7-10 byte pins exist before streaming code"
echo "wp87: stream corpus GREEN unedited (WP88/WP89 implemented the sentinel)"
echo "wp87: body corpus GREEN unedited (WP94 implemented the spool substrate)"
echo "wp87: package web imports no private lifecycle package directly"
echo "PASS: WP87 lifecycle corpus controls"
