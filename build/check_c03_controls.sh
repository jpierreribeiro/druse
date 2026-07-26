#!/usr/bin/env bash
# C-03 — the closed fault-injection campaign, under control.
#
# The campaign's value is that the SPACE is enumerated, so a future defect is a
# new cell rather than a new category. Five executable claims:
#
#   1. the GRID IS WHOLE — every cell in planning/closure-fault-campaign.md
#      carries a disposition (covered / filled here / declared / external). A
#      cell with no owner is the state nobody drove, which is precisely how
#      .Will_Close survived seven phases;
#   2. the six cells C-03 filled exist by name — a dropped test cannot hide
#      behind a green run;
#   3. the two fixes this WP made cannot be silently reverted: `.Will_Close` is
#      still handled by the drain loop (F-C03-1) and the peer-gone fast close is
#      still guarded by "no send in flight" (patch 25);
#   4. the RST verdict block is still in the campaign record — the measurement
#      is the deliverable, and a fix whose evidence is deleted is a fix nobody
#      can re-derive;
#   5. the suite is green.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URUQUIM_GRID="$URUQUIM_ROOT/planning/closure-fault-campaign.md"
URUQUIM_SERVER="$URUQUIM_ROOT/vendor/odin-http/server.odin"

fail() {
  echo "C03-CONTROL-FAIL: $*" >&2
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
URUQUIM_TMP="$(mktemp -d -t uruquim-c03-controls-XXXXXXXX)"
trap 'rm -rf "$URUQUIM_TMP"' EXIT

test -f "$URUQUIM_GRID" || fail "planning/closure-fault-campaign.md is missing; it is the campaign's grid"

# --- 1. Every grid cell carries a disposition --------------------------------
# Cell rows look like: | A10 | Sustained RST flood | 🆕 ... |
URUQUIM_ORPHANS="$(awk -F'|' '
  /^\| [A-D][0-9]+ \| / {
    d = $4
    gsub(/^[ \t]+|[ \t]+$/, "", d)
    if (d !~ /(✅|🆕|📕|🌐)/) { printf "%s", $2 }
  }' "$URUQUIM_GRID")"
test -z "$URUQUIM_ORPHANS" || fail "$(printf 'grid cells with no disposition:%s\nEvery cell must be covered (✅), filled by C-03 (🆕), declared (📕) or external (🌐). A cell nobody owns is the state nobody drove.' "$URUQUIM_ORPHANS")"

URUQUIM_CELLS="$(grep -cE '^\| [A-D][0-9]+ \| ' "$URUQUIM_GRID" || true)"
test "$URUQUIM_CELLS" -ge 30 ||
  fail "the grid has shrunk to $URUQUIM_CELLS cells; the campaign is closed only while the axes stay enumerated"

# --- 2. The six cells C-03 filled, present by name ---------------------------
for URUQUIM_CASE in \
  c03_a_healthy_client_survives_an_rst_flood \
  c03_a_contended_lane_refuses_with_503_and_stays_alive \
  c03_a_disconnect_during_the_handler_does_not_outlive_the_request \
  c03_a_send_error_retires_the_connection_without_a_second_write \
  c03_a_deadline_expiring_with_the_drain_does_not_double_close \
  c03_a_stop_after_a_failed_bind_returns; do
  grep -qr "^$URUQUIM_CASE ::" "$URUQUIM_ROOT/tests/c03-fault-campaign" ||
    fail "campaign cell dropped: $URUQUIM_CASE"
done

# --- 3. The two fixes cannot be silently reverted ----------------------------
grep -q 'case .Active, .Will_Close:' "$URUQUIM_SERVER" || fail "$(cat <<'EOF'
the drain loop no longer handles .Will_Close (vendored patch 26 / F-C03-1).
That state is entered for every request carrying `Connection: close`, every
HTTP/1.0 request and every failed body read. An omitted case in a #partial
switch is silence: the connection stays in td.conns, len(td.conns) never
reaches zero, and the drain loop never breaks — past EVERY deadline, which makes
max_drain_time bound nothing. Measured: one client sending `Connection: close`
and not reading an 8 MiB response hangs web.stop indefinitely.
EOF
)"

grep -q 'if c.peer_gone && !had_send_in_flight {' "$URUQUIM_SERVER" || fail "$(cat <<'EOF'
the peer-gone fast close is gone or has lost its guard (vendored patch 25).
Both conditions are load-bearing. Without `peer_gone`, a connection whose client
is still draining a response would lose its RFC 7230 6.6 linger. Without
`!had_send_in_flight`, a close that began with a response outstanding would stop
taking the courteous path. And without the fast close at all, every RST'd
connection holds an admission slot for the whole 500 ms Conn_Close_Delay: a
healthy client was served 1 probe in 59 under an RST flood before this patch,
and 56 in 56 after it.
EOF
)"

grep -q 'peer_gone = true' "$URUQUIM_ROOT/vendor/odin-http/scanner.odin" ||
  fail "the scanner no longer records peer_gone; the patch-25 fast close can then never trigger and the RST-flood wedge returns silently"

# The dedicated acceptor originally shipped with eight callbacks queued per
# lane. On the reference host that admitted ~50k RST connections/s and starved
# the healthy probe (18-24/58). Three and four reproduced the failure; two
# passed three consecutive campaigns while keeping steady-state /ping within
# 1.6% of the eight-item control. Keep the measured bound executable.
grep -q 'URUQUIM_ACCEPT_HANDOFF_LIMIT :: 2' "$URUQUIM_SERVER" ||
  fail "the dedicated-accept handoff bound is no longer the C-03-validated value 2; re-run the RST campaign and steady-state A/B before changing it"

# --- 4. The measurement survives ---------------------------------------------
grep -q 'c03-rst-verdict:start' "$URUQUIM_GRID" ||
  fail "the RST-flood verdict block is gone from the campaign record; a fix whose evidence is deleted is a fix nobody can re-derive"
grep -q '1 / 59' "$URUQUIM_GRID" ||
  fail "the campaign record lost the before/after measurement (1/59 unpatched vs 56/56 patched)"

# --- 5. The suite is green ---------------------------------------------------
# THREADS=1: web.serve is one-server-per-process (the WP43 g_server), so tests
# that each start a server must run in sequence.
env ODIN_ROOT="$URUQUIM_ODIN_ROOT" "$URUQUIM_ODIN" test \
  "$URUQUIM_ROOT/tests/c03-fault-campaign" \
  "-collection:uruquim=$URUQUIM_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$URUQUIM_TMP/c03"

echo "c03: $URUQUIM_CELLS grid cells, every one with a disposition"
echo "c03: the RST-flood wedge is fixed (patch 25) and its measurement is on record"
echo "c03: the drain loop still handles .Will_Close (patch 26 / F-C03-1)"
echo "c03: contention, mid-handler disconnect, send error, coincident deadlines and failed bind all green"
echo "PASS: C-03 closed fault-injection campaign controls"
