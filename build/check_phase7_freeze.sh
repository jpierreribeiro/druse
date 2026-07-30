#!/usr/bin/env bash
# WP101 — Phase-7 freeze gate.
#
# Same shape and lesson as its predecessors: a frozen total is HISTORY. This
# pins Phase 7's ledger diff as written, checks the document's arithmetic,
# requires the live ledger not to have shrunk, and holds the things this freeze
# would lose first if someone tidied it:
#
#   * the record of what was NOT delivered — the public large-body upload API
#     and the 3,000 real-socket round — because a freeze that drops those rows
#     reads as a phase that delivered everything;
#   * the five public symbols by name, so a ledger row cannot become a number
#     nobody can check;
#   * the graceful-close and safe-without-tuning decisions, which are the ones a
#     later refactor would quietly reverse;
#   * G7-8 (pay only when used) and the lazy-allocation fix behind it.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_P7="$DRUSE_ROOT/planning/phase-7-freeze.md"

fail() {
  echo "PHASE7-FREEZE-FAIL: $*" >&2
  exit 1
}

test -f "$DRUSE_P7" || fail "planning/phase-7-freeze.md is missing"

DRUSE_FLAT="$(tr '\n' ' ' < "$DRUSE_P7" | tr -s ' ')"

# --- 1. The ledger: history, arithmetic, and a floor ------------------------
grep -qE '\| application \| 63 \| \+5 \| \*\*68\*\* \|' "$DRUSE_P7" ||
  fail "the application ledger diff row (63 -> 68) is missing or edited"
grep -qE '\| union \| 65 \| \+5 \| \*\*70\*\* \|' "$DRUSE_P7" ||
  fail "the union row (65 -> 70) is missing or edited"

# The live ledger must NOT HAVE SHRUNK below what this phase froze — it may grow
# (WP7.5-C2 added the 5-symbol upload API, 68 -> 73). Pinning this to the literal
# live count was the anti-pattern that broke check_phase2_freeze the moment a
# later phase grew the ledger; the frozen total (68) is history, held by the doc
# arithmetic above, and here we only require live >= 68. The canonical count
# lives in check_public_api.sh ("application ledger is exactly N symbols").
DRUSE_P7_LIVE_LEDGER="$(grep -oE 'application ledger is exactly [0-9]+ symbols' "$DRUSE_ROOT/build/check_public_api.sh" | grep -oE '[0-9]+' | head -1)"
test -n "$DRUSE_P7_LIVE_LEDGER" ||
  fail "could not read the live application ledger count from check_public_api.sh"
test "$DRUSE_P7_LIVE_LEDGER" -ge 68 ||
  fail "the live application ledger ($DRUSE_P7_LIVE_LEDGER) is below the 68 Phase 7 froze; a symbol was removed"

# Every one of the five new public symbols must be named in the freeze.
for DRUSE_SYM in Stream Stream_Send stream stream_send stream_close; do
  grep -q "$DRUSE_SYM" "$DRUSE_P7" ||
    fail "the freeze does not name '$DRUSE_SYM'; a ledger row without its symbol is a number nobody can check"
done

# --- 2. The gates verdict table names all ten, with G7-6/G7-9 honest --------
for DRUSE_G in G7-1 G7-2 G7-3 G7-4 G7-5 G7-6 G7-7 G7-8 G7-9 G7-10; do
  grep -q "\*\*$DRUSE_G\*\*" "$DRUSE_P7" ||
    fail "the exit-gate table is missing $DRUSE_G"
done
case "$DRUSE_FLAT" in
  *"PASS (in memory) / DEFERRED (real sockets)"*) ;;
  *) fail "G7-6 no longer records the real-socket deferral honestly" ;;
esac
case "$DRUSE_FLAT" in
  *"PASS (substrate)"*) ;;
  *) fail "G7-9 no longer records that the large-body path is substrate-only" ;;
esac

# --- 3. The non-deliveries must remain named --------------------------------
grep -q 'public large-body upload API is deferred' "$DRUSE_P7" ||
  fail "the deferred public upload API is no longer recorded — a freeze that hides it lies by tidiness"
grep -q '3,000 real-socket round is deferred' "$DRUSE_P7" ||
  fail "the deferred 3,000 real-socket scale round is no longer recorded"
case "$DRUSE_FLAT" in
  *"WebSocket and arbitrary full-duplex"*) ;;
  *) fail "the WebSocket refusal is no longer recorded" ;;
esac

# --- 4. The decisions a refactor would reverse ------------------------------
grep -q 'Graceful close' "$DRUSE_P7" ||
  fail "the graceful-close decision is not recorded"
case "$DRUSE_FLAT" in
  *"safe without tuning for a stream"*) ;;
  *) fail "the safe-without-tuning stream write deadline is not recorded" ;;
esac
grep -q 'lazily on first open' "$DRUSE_P7" ||
  fail "the lazy-allocation fix behind G7-8 is not recorded"

# --- 5. The vendored patch count and the BRIDGE exit ------------------------
# The freeze DOCUMENT pins the historical total: Phase 7 froze at twenty-two
# vendored patches. That number is history and must stay recorded here.
grep -q 'Twenty-two local patches' "$DRUSE_P7" ||
  fail "the vendored patch count (22) is not recorded"
# The LIVE ledger, by contrast, must only be checked for not having SHRUNK below
# the frozen total — a later phase may add BRIDGE patches (WP7.5-C1 added patch
# 23, the streaming inbound body). Pinning the freeze gate to the live count was
# the exact anti-pattern that broke check_phase2_freeze the moment a later phase
# grew the ledger: "a frozen total is history; pin it in the doc, and separately
# require the live count not to have shrunk." So this asserts >= 22, not == 22.
test "$(grep -cE '^\| [0-9]+ \|' "$DRUSE_ROOT/vendor/odin-http/VENDOR.md")" -ge 22 ||
  fail "VENDOR.md lists fewer than the 22 frozen patch rows; a Phase-7 patch has been dropped"
case "$DRUSE_FLAT" in
  *"BRIDGE"*"core:net/http"*) ;;
  *) fail "the BRIDGE exit to core:net/http is not recorded" ;;
esac

# --- 6. The Crystals half's SSE freeze is named -----------------------------
grep -q 'crystals:web/sse' "$DRUSE_P7" ||
  fail "the SSE Crystal (G7-7 ecosystem proof) is not recorded"

echo "phase-7 freeze: ledger 63 -> 68 (union 70), five symbols named"
echo "phase-7 freeze: G7-1..G7-10 recorded; G7-6/G7-9 deferrals honest"
echo "phase-7 freeze: graceful close, safe-without-tuning, lazy alloc kept"
echo "phase-7 freeze: 22 vendored patches frozen (live >= 22; 7.5-C1 added 23), BRIDGE exit to core:net/http"
echo "PASS: WP101 Phase-7 freeze gate"
