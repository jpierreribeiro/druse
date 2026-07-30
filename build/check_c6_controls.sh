#!/usr/bin/env bash
# C6 — corrective WP for friction F8-7: Expect: 100-continue is honored (body
# read) instead of a hard 417. No ledger change (transport behaviour). This
# control pins the adapter logic and the re-aimed wire corpus; the behaviour
# itself is exercised by tests/wp9-wire (real socket) in the gate's test step.
set -euo pipefail
DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "C6-CONTROL-FAIL: $*" >&2; exit 1; }
DRUSE_ADAPTER="$(grep -rl 'import http "druse:vendor/odin-http"' "$DRUSE_ROOT/web/internal/transport/" | head -1)"
test -n "$DRUSE_ADAPTER" || fail "no vendored-backend adapter found"
DRUSE_CORPUS="$DRUSE_ROOT/tests/support/transport_conformance/corpus.odin"

# 1. The adapter honors 100-continue (does not 417 it) and keeps 417 for others.
grep -qE 'expect_is_100_continue' "$DRUSE_ADAPTER" ||
  fail "the adapter no longer distinguishes 100-continue (expect_is_100_continue missing) — it would 417 all Expect"
grep -qE 'auto_expect_continue = false' "$DRUSE_ADAPTER" ||
  fail "auto_expect_continue must stay false (the vendored auto-continue blocks)"

# 2. The wire corpus carries BOTH the honored-100-continue case and the
#    unknown-expectation-still-417 case.
grep -qE '100-continue is honored' "$DRUSE_CORPUS" ||
  fail "the wire corpus does not assert 100-continue is honored (body read, handler runs)"
grep -qE 'unknown Expect is still refused with 417' "$DRUSE_CORPUS" ||
  fail "the wire corpus does not preserve the 417 branch for an unknown expectation"

echo "C6 control: adapter honors 100-continue (reads body) and 417s unknown expectations; wire corpus covers both (socket-proven in wp9-wire)"
