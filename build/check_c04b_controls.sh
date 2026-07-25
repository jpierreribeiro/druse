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

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_LIMITS="$URUQUIM_ROOT/web/limits.odin"
URUQUIM_ERRORS="$URUQUIM_ROOT/web/errors.odin"
URUQUIM_SERVE="$URUQUIM_ROOT/web/serve.odin"
URUQUIM_SUITE="$URUQUIM_ROOT/tests/c04b-response-limit/contract_test.odin"

fail() { echo "C04B-CONTROL-FAIL: $*" >&2; exit 1; }

URUQUIM_ODIN="${URUQUIM_ODIN_BIN:-odin}"
URUQUIM_ODIN_DIR="$(cd "$(dirname "$(readlink -f "$URUQUIM_ODIN")")" && pwd)"

# --- the surface exists as ratified ------------------------------------------
grep -qE 'max_response_bytes: int' "$URUQUIM_LIMITS" ||
  fail "Limits.max_response_bytes is missing its ratified field"
grep -qE 'Response_Too_Large' "$URUQUIM_ERRORS" ||
  fail "Framework_Error.Response_Too_Large is missing"

# --- the enforcement is on the SHARED path, before copy-out (R-10) -----------
# It must sit in driver_run, which both transports run, not in a socket-only
# path — otherwise test_request and a real socket would disagree about the 500.
grep -qE 'error_enforce_response_size\(ctx\)' "$URUQUIM_SERVE" ||
  fail "error_enforce_response_size is not called on the shared driver path; test_request and the socket could disagree (R-10)"

# --- the guard is `>` (exactly-the-limit is served, mirroring max_body) -------
grep -qE 'len\(res\.body\) <= limit' "$URUQUIM_ERRORS" ||
  fail "the response-size guard is not '<= limit' (exactly the limit must be accepted, one byte more refused)"

# --- the behaviour is wired: the suite is green ------------------------------
test -f "$URUQUIM_SUITE" || fail "tests/c04b-response-limit/contract_test.odin is missing"
env ODIN_ROOT="$URUQUIM_ODIN_DIR" "$URUQUIM_ODIN" test "$URUQUIM_ROOT/tests/c04b-response-limit" \
  -collection:uruquim="$URUQUIM_ROOT" >/dev/null 2>&1 ||
  fail "the C-04b response-limit suite did not pass"

echo "C-04b control: max_response_bytes replaces an over-limit response with a 500 before copy-out, exactly-the-limit served, default off, breach observed as Response_Too_Large; suite green"
