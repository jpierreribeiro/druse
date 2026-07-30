#!/usr/bin/env bash
# C1 — corrective WP for friction F8-1: the public Status enum gains 409/413/429/503.
#
# The ledger amendment (no growth — Status is one symbol) is pinned by the
# freeze/public-api/docs gates. This control pins what those cannot see: that the
# named members are actually WIRED to their HTTP codes on the wire, and that the
# body-too-large path returns the NAMED .Payload_Too_Large rather than a private
# Status(413) cast (the inverted WP7 D3 control).
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_RESP="$DRUSE_ROOT/web/respond.odin"
DRUSE_ERRORS="$DRUSE_ROOT/web/errors.odin"
DRUSE_SUITE="$DRUSE_ROOT/tests/c1-status-codes/status_codes_test.odin"

fail() { echo "C1-CONTROL-FAIL: $*" >&2; exit 1; }

DRUSE_ODIN="${DRUSE_ODIN_BIN:-odin}"
DRUSE_ODIN_DIR="$(cd "$(dirname "$(readlink -f "$DRUSE_ODIN")")" && pwd)"

# 1. The four named members exist with their exact codes.
for pair in "Conflict = 409" "Payload_Too_Large = 413" "Too_Many_Requests = 429" "Service_Unavailable = 503"; do
  grep -qE "^\s*${pair%% =*}\s*=\s*${pair##*= }," "$DRUSE_RESP" ||
    fail "public Status is missing the C1 member: $pair"
done

# 2. The body-too-large path uses the NAMED member, not a private cast.
grep -q 'STATUS_BODY_TOO_LARGE' "$DRUSE_ERRORS" &&
  fail "web/errors.odin still defines/uses the private STATUS_BODY_TOO_LARGE cast (C1 removes it)"
grep -qE '\.Payload_Too_Large,' "$DRUSE_ERRORS" ||
  fail "the body-too-large path does not return the named .Payload_Too_Large (C1)"

# 3. The RED test exists and passes on real (in-memory transport) traffic.
test -f "$DRUSE_SUITE" || fail "tests/c1-status-codes/status_codes_test.odin is missing"
env ODIN_ROOT="$DRUSE_ODIN_DIR" "$DRUSE_ODIN" test "$DRUSE_ROOT/tests/c1-status-codes" \
  -collection:druse="$DRUSE_ROOT" >/dev/null 2>&1 ||
  fail "the C1 status-codes suite did not pass"

echo "C1 control: Status.{Conflict,Payload_Too_Large,Too_Many_Requests,Service_Unavailable} wired to 409/413/429/503; body-too-large uses the named member; suite green"
