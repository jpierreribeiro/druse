#!/usr/bin/env bash
# C8 — corrective WP for friction F8-9: the public Status enum gains the redirect
# family (301/302/303/307/308), which it did not name at all.
#
# The ledger amendment (no growth — Status is one symbol) is pinned by the
# freeze/public-api/docs gates. This control pins what those cannot see: that the
# named members are actually WIRED to their HTTP codes on the wire, that a redirect
# carries its `Location` (a 303 without one sends the client nowhere with a status
# that says otherwise), and that C8 did NOT smuggle in a `redirect` responder —
# `set_header` + `text` already express it (G-01), and the name stays reserved.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_RESP="$URUQUIM_ROOT/web/respond.odin"
URUQUIM_SUITE="$URUQUIM_ROOT/tests/c8-redirect-statuses/redirect_statuses_test.odin"

fail() { echo "C8-CONTROL-FAIL: $*" >&2; exit 1; }

URUQUIM_ODIN="${URUQUIM_ODIN_BIN:-odin}"
URUQUIM_ODIN_DIR="$(cd "$(dirname "$(readlink -f "$URUQUIM_ODIN")")" && pwd)"

# Comments are STRIPPED before every grep below. The doc comment on `Status`
# explains this family and names the very codes these patterns match, so grepping
# the raw file would let the prose satisfy the check that guards the code — a trap
# this repository has fallen into twice.
URUQUIM_RESP_CODE="$(sed -E 's://.*$::' "$URUQUIM_RESP")"

# 1. The five named members exist with their exact codes.
for pair in "Moved_Permanently = 301" "Found = 302" "See_Other = 303" \
  "Temporary_Redirect = 307" "Permanent_Redirect = 308"; do
  grep -qE "^\s*${pair%% =*}\s*=\s*${pair##*= }," <<<"$URUQUIM_RESP_CODE" ||
    fail "public Status is missing the C8 member: $pair"
done

# 2. No redirect RESPONDER was added. C8 is five names, not a new public
#    operation; `web.set_header` + `web.text` are the canonical pair.
if grep -qE '^redirect(_[a-z_]+)? :: proc' <<<"$(sed -E 's://.*$::' "$URUQUIM_ROOT"/web/*.odin)"; then
  fail "a public redirect responder was added; C8 adds Status members only (G-01, and 'redirect' is a reserved later-phase name)"
fi

# 3. The RED test exists and passes on real (in-memory transport) traffic —
#    including the Location header and the `%v` rendering of the status.
test -f "$URUQUIM_SUITE" || fail "tests/c8-redirect-statuses/redirect_statuses_test.odin is missing"
grep -q 'Location: /notes' "$URUQUIM_SUITE" ||
  fail "the C8 suite no longer asserts the Location header of the 303 (half the pattern)"
grep -q 'BAD ENUM VALUE' "$URUQUIM_SUITE" ||
  fail "the C8 suite no longer asserts that a redirect status renders as its own name (F8-9's second facet)"
env ODIN_ROOT="$URUQUIM_ODIN_DIR" "$URUQUIM_ODIN" test "$URUQUIM_ROOT/tests/c8-redirect-statuses" \
  -collection:uruquim="$URUQUIM_ROOT" >/dev/null 2>&1 ||
  fail "the C8 redirect-statuses suite did not pass"

echo "C8 control: Status.{Moved_Permanently,Found,See_Other,Temporary_Redirect,Permanent_Redirect} wired to 301/302/303/307/308; POST/Redirect/GET carries its Location; no redirect responder added; suite green"
