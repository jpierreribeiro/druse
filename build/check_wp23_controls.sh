#!/usr/bin/env bash
# WP23 — the seven required `request_id` mutation controls, as one executable run.
#
# The WP17-WP22 protocol, unchanged: each control re-creates a specific defect
# in a THROWAWAY copy of the shipped sources and requires the WP23 suites to
# catch it. Every probe (a) runs its selected tests UNMUTATED first and requires
# them green with at least one test executed, (b) asserts its own edit applied
# by md5 — BROKEN PROBE otherwise, never a false verdict — and (c) requires the
# selected tests red afterwards.
#
# THIS WORK PACKAGE IS A SECURITY BOUNDARY, so four of the seven controls are
# attacks rather than regressions: each one re-opens a specific hole ADR-027
# closed, and requires a test to notice.
#
#   1  the inbound value echoed unvalidated -> CR/LF injection tests MUST go red
#   2  the charset widened to "printable"   -> the CR/LF tests MUST go red
#   3  the length bound dropped             -> the oversized test MUST go red
#   4  the overlay published AFTER next     -> handler-readability MUST go red
#   5  the header seeded FIRST, not appended-> the WP17 Allow-order test MUST go red
#   6  one ID reused for every request      -> the uniqueness test MUST go red
#   7  POSITIVE: a valid inbound ID honoured, and the opt-in default preserved
#
# CONTROL 7 IS THE POSITIVE HALF and it is not decoration. Controls 1-3 are all
# satisfied by an implementation that rejects EVERYTHING and always generates —
# which would silently destroy cross-service correlation, the entire reason to
# honour an inbound ID. Control 7 fails that implementation. It also fails an
# implementation that stamps the header when the middleware was never
# registered, which is the opt-in half of G-08.
#
# Controls 1-6 mutate; control 7 asserts on the UNMUTATED tree. Without a
# toolchain this script reports BLOCKED and exits 2 — it never reports a control
# it did not run.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP23-CONTROL-FAIL: $*" >&2
  exit 1
}

DRUSE_W23_ODIN="${DRUSE_ODIN_BIN:-}"
if test -z "$DRUSE_W23_ODIN" && command -v odin >/dev/null 2>&1; then
  DRUSE_W23_ODIN="$(command -v odin)"
fi
if test -z "$DRUSE_W23_ODIN" && test -x /tmp/druse-toolchain/odin; then
  DRUSE_W23_ODIN=/tmp/druse-toolchain/odin
fi
if test -z "$DRUSE_W23_ODIN"; then
  echo "WP23 CONTROLS -> BLOCKED: no Odin toolchain found (set DRUSE_ODIN_BIN). NOTHING RAN." >&2
  exit 2
fi

DRUSE_W23_TMP="$(mktemp -d -t druse-wp23-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_W23_TMP"' EXIT

internal_tree() { # name
  local t="$DRUSE_W23_TMP/$1"
  mkdir -p "$t"
  cp "$DRUSE_ROOT"/web/*.odin "$t/"
  cp "$DRUSE_ROOT"/tests/wp23-internal/*.odin "$t/"
  printf '%s' "$t"
}

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

run_selected() { # tree test-names
  env -u ODIN_ROOT "$DRUSE_W23_ODIN" test "$1" \
    "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_W23_TMP/runner" \
    "-define:ODIN_TEST_NAMES=$2" 2>&1
}

assert_green_baseline() { # tree test-names label
  local out
  if ! out="$(run_selected "$1" "$2")"; then
    echo "$out" >&2
    fail "BROKEN PROBE ($3): the selected tests are not green BEFORE the mutation"
  fi
  grep -qE 'Finished [1-9][0-9]* tests?' <<<"$out" ||
    { echo "$out" >&2; fail "BROKEN PROBE ($3): the selection ran no test; a stale test name would fake a pass"; }
}

must_go_red() { # tree test-names label
  local out
  if out="$(run_selected "$1" "$2")"; then
    echo "$out" >&2
    fail "control '$3' stayed GREEN under the mutation; the suite does not catch this defect"
  fi
  echo "CONTROL $3 -> RED as required"
}

# --- 1. the inbound value echoed unvalidated ---------------------------------
# ADR-027 option (D), rejected on sight: echo whatever arrives. This is the
# CR/LF response-header injection this work package exists to prevent.
NAMES="web.wp23_a_rejected_value_never_reaches_the_response"
T="$(internal_tree echoraw)"
assert_green_baseline "$T" "$NAMES" "1: inbound echoed unvalidated"
H="$(md5sum "$T/request_id.odin" | cut -d' ' -f1)"
sed -i 's|^\tif found \&\& request_id_acceptable(inbound) {$|\tif found {|' "$T/request_id.odin"
assert_mutated "inbound echoed unvalidated" "$T/request_id.odin" "$H"
must_go_red "$T" "$NAMES" "1: inbound echoed unvalidated -> CR/LF reaches a response header"

# --- 2. the charset widened to "any printable byte" --------------------------
# The plausible-looking weakening: someone decides the charset is too strict and
# accepts anything that is not a control byte. SP, `;`, `"` and `,` come back —
# and so does every byte a future header parser might treat as a separator.
NAMES="web.wp23_the_validator_accepts_exactly_the_ratified_charset"
T="$(internal_tree widecharset)"
assert_green_baseline "$T" "$NAMES" "2: charset widened"
H="$(md5sum "$T/request_id.odin" | cut -d' ' -f1)"
python3 - "$T/request_id.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """		case c >= 'A' && c <= 'Z':
		case c >= 'a' && c <= 'z':
		case c >= '0' && c <= '9':
		case c == '.' || c == '_' || c == '-':
		case:
			return false
		}"""
new = """		case c > 0x20 && c < 0x7F:
		case:
			return false
		}"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "charset widened" "$T/request_id.odin" "$H"
must_go_red "$T" "$NAMES" "2: charset widened -> the ratified-charset test"

# --- 3. the length bound dropped ---------------------------------------------
# An unbounded ID overruns nothing (the copy is bounded by the buffer) but it
# silently TRUNCATES an attacker value into the response instead of rejecting
# it — a partial attacker value is still an attacker value.
NAMES="web.wp23_the_validator_accepts_exactly_the_ratified_charset"
T="$(internal_tree nolimit)"
assert_green_baseline "$T" "$NAMES" "3: length bound dropped"
H="$(md5sum "$T/request_id.odin" | cut -d' ' -f1)"
# python, not sed: the line being replaced contains `||`, which collides with
# every convenient sed delimiter.
python3 - "$T/request_id.odin" <<'PYEOF2'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\tif len(value) == 0 || len(value) > REQUEST_ID_MAX {"
new = "\tif len(value) == 0 {"
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF2
assert_mutated "length bound dropped" "$T/request_id.odin" "$H"
must_go_red "$T" "$NAMES" "3: length bound dropped -> the 1..64 bound test"

# --- 4. the overlay published AFTER `next` -----------------------------------
# The handler would then read the ARRIVED header — the very value the framework
# rejected — while the response carried the effective one. Two different IDs for
# one request, the subtler half-broken state.
NAMES="web.wp23_the_handler_reads_the_effective_id_not_the_arrived_one"
T="$(internal_tree lateoverlay)"
assert_green_baseline "$T" "$NAMES" "4: overlay published after next"
H="$(md5sum "$T/request_id.odin" | cut -d' ' -f1)"
python3 - "$T/request_id.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	ctx.private.overlay_set = true

	next(ctx)"""
new = """	next(ctx)

	ctx.private.overlay_set = true"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "overlay published after next" "$T/request_id.odin" "$H"
must_go_red "$T" "$NAMES" "4: overlay published after next -> handler/response agreement"

# --- 5. the header seeded FIRST instead of appended --------------------------
# The cross-work-package regression: WP4 ratified `Allow` first and
# `Content-Type` second, and a merged WP17 test pins both BY INDEX. Seeding the
# request ID at slot 0 renumbers them.
NAMES="web.wp23_the_id_appears_on_a_405_without_displacing_allow"
T="$(internal_tree seedfirst)"
assert_green_baseline "$T" "$NAMES" "5: header seeded first"
H="$(md5sum "$T/response.odin" | cut -d' ' -f1)"
python3 - "$T/response.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
# RE-ANCHORED BY WP56's re-run. WP49 inserted the security-header block between
# `count := n` and the request-ID block, so the old anchor — which spanned both
# — no longer matched and this control reported a BROKEN PROBE. The mutation is
# unchanged; only the text it attaches to moved. Anchored on the request-ID
# block ALONE now, so a future insertion elsewhere cannot break it again (the
# lesson the WP18 and WP20 probes already taught, applied here).
old = """	if ctx.private.request_id_set {
		ctx.private.response_headers[count] = Header_Pair {
			name  = REQUEST_ID_HEADER,
			value = ctx.private.request_id_value,
		}
		count += 1
	}"""
new = """	if ctx.private.request_id_set {
		for i := count; i > 0; i -= 1 {
			ctx.private.response_headers[i] = ctx.private.response_headers[i - 1]
		}
		ctx.private.response_headers[0] = Header_Pair {
			name  = REQUEST_ID_HEADER,
			value = ctx.private.request_id_value,
		}
		count += 1
	}"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "header seeded first" "$T/response.odin" "$H"
must_go_red "$T" "$NAMES" "5: header seeded first -> the Allow-stays-at-index-0 test"

# --- 6. one ID reused for every request --------------------------------------
NAMES="web.wp23_generated_ids_are_acceptable_to_the_validator"
T="$(internal_tree reuseid)"
assert_green_baseline "$T" "$NAMES" "6: one ID reused"
H="$(md5sum "$T/request_id.odin" | cut -d' ' -f1)"
python3 - "$T/request_id.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
# REPOINTED (audit): the counter became an atomic add for concurrent lanes,
# and this pattern has not matched since — the uniqueness guard was unguarded.
old = """	counter := sync.atomic_add(&request_id_counter, 1) + 1"""
new = """	counter := u64(1)"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "one ID reused" "$T/request_id.odin" "$H"
must_go_red "$T" "$NAMES" "6: one ID reused -> the uniqueness test"

# --- 7. POSITIVE control: honouring and opt-in still work --------------------
#
# Controls 1-3 are ALL satisfied by an implementation that rejects everything
# and generates every time. That implementation destroys cross-service
# correlation — the entire reason ADR-027 chose (A) over (C) — while passing
# every negative probe above. And an implementation that stamps the header
# without being registered breaks the opt-in rule (G-08) while breaking no
# security property at all.
#
# So the last control runs the UNMUTATED tree and requires both to hold.
T="$(internal_tree positive)"
NAMES="web.wp23_the_header_is_emitted_exactly_once,web.wp23_without_the_middleware_no_header_is_added,web.wp23_bare_adds_no_header_either"
assert_green_baseline "$T" "$NAMES" "7: positive control"

if ! OUT="$(env -u ODIN_ROOT "$DRUSE_W23_ODIN" test "$DRUSE_ROOT/tests/wp23-public-surface" \
    "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_W23_TMP/pos" \
    "-define:ODIN_TEST_NAMES=test_wp23_public.wp23_public_a_valid_inbound_id_is_honoured,test_wp23_public.wp23_public_is_opt_in" 2>&1)"; then
  echo "$OUT" >&2
  fail "POSITIVE control failed: a well-formed inbound ID is no longer honoured, or the middleware is no longer opt-in. An implementation that rejects everything passes controls 1-3 while destroying correlation"
fi
grep -qE 'Finished [1-9][0-9]* tests?' <<<"$OUT" ||
  { echo "$OUT" >&2; fail "BROKEN PROBE (7: positive control): the selection ran no test"; }
echo "CONTROL 7: a valid inbound ID is honoured and the middleware stays opt-in -> GREEN as required [positive control]"

echo "PASS: all seven WP23 mutation controls behaved as required"
