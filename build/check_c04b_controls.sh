#!/usr/bin/env bash
# C-04b — the per-response size limit, `Limits.max_response_bytes` (ADR-045).
#
# The C-04 audit specified this limit and handed it forward rather than smuggle
# it into an audit phase; the readiness-hardening program implements it. It grows
# NO ledger — `max_response_bytes` is a field of the existing public `Limits`
# struct and `Response_Too_Large` a member of the existing public
# `Framework_Error` enum — so the freeze snapshot moves but the symbol count does
# not, pinned by check_public_api.sh and check_phase1_freeze.sh.
#
# This control pins what those cannot see: that the behaviour is WIRED — an
# over-limit response is a 500 and not a truncation, exactly-the-limit is served,
# the default (0) is unbounded, and the breach reaches the typed observer as
# Response_Too_Large — proven on real (in-memory transport) traffic.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_LIMITS="$DRUSE_ROOT/web/limits.odin"
DRUSE_ERRORS="$DRUSE_ROOT/web/errors.odin"
DRUSE_SERVE="$DRUSE_ROOT/web/serve.odin"
DRUSE_SUITE="$DRUSE_ROOT/tests/c04b-response-limit/contract_test.odin"

fail() { echo "C04B-CONTROL-FAIL: $*" >&2; exit 1; }

DRUSE_ODIN="${DRUSE_ODIN_BIN:-odin}"
if [[ "$DRUSE_ODIN" != */* ]]; then
  DRUSE_ODIN="$(command -v "$DRUSE_ODIN")"
fi
DRUSE_ODIN="$(readlink -f "$DRUSE_ODIN")"
DRUSE_ODIN_DIR="$(cd "$(dirname "$DRUSE_ODIN")" && pwd)"
DRUSE_TMP="$(mktemp -d -t druse-c04b-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

# --- the surface exists as ratified ------------------------------------------
grep -qE 'max_response_bytes: int' "$DRUSE_LIMITS" ||
  fail "Limits.max_response_bytes is missing its ratified field"
grep -qE 'Response_Too_Large' "$DRUSE_ERRORS" ||
  fail "Framework_Error.Response_Too_Large is missing"

# --- the enforcement is on the SHARED path, before copy-out (R-10) -----------
# It must sit in driver_run, which both transports run, not in a socket-only
# path — otherwise test_request and a real socket would disagree about the 500.
grep -qE 'error_enforce_response_size\(ctx\)' "$DRUSE_SERVE" ||
  fail "error_enforce_response_size is not called on the shared driver path; test_request and the socket could disagree (R-10)"

# --- the guard is `>` (exactly-the-limit is served, mirroring max_body) -------
grep -qE 'len\(res\.body\) <= limit' "$DRUSE_ERRORS" ||
  fail "the response-size guard is not '<= limit' (exactly the limit must be accepted, one byte more refused)"

# --- the behaviour is wired: the suite is green ------------------------------
test -f "$DRUSE_SUITE" || fail "tests/c04b-response-limit/contract_test.odin is missing"
env ODIN_ROOT="$DRUSE_ODIN_DIR" "$DRUSE_ODIN" test "$DRUSE_ROOT/tests/c04b-response-limit" \
  -collection:druse="$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_TMP/c04b" >/dev/null 2>&1 ||
  fail "the C-04b response-limit suite did not pass"

echo "C-04b control: max_response_bytes replaces an over-limit response with a 500 before copy-out, exactly-the-limit served, default off, breach observed as Response_Too_Large; suite green"
