#!/usr/bin/env bash
# WP41 — the fault-laboratory controls.
#
# A lab that reports a finding must first prove the finding is about the SERVER
# and not about the lab. These controls exist because "the connection was held
# open" has three uninteresting explanations before it has an interesting one:
# the client never sent anything, the client never read, or the client's own
# timeout fired for an unrelated reason.
#
#   1  the server's answer is real — the lab reads a 200 from a complete request
#      [POSITIVE control, and it runs FIRST because every other result is
#      meaningless without it]
#   2  the lab's determinism is real — the same seed replays, a different seed
#      diverges
#   3  the finding is about the SERVER — pointing the same truncated request at
#      a socket with NO server behind it produces a DIFFERENT outcome
#   4  the lab cannot be satisfied by a silent server — a mutation that makes
#      `read_status` treat every timeout as a response turns the findings green,
#      which must be caught
#
# Control 3 is the one that makes the slowloris finding admissible. Without it,
# "held open until the lab gave up" is a sentence about the lab.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP41-CONTROL-FAIL: $*" >&2
  exit 1
}

DRUSE_W41_ODIN="${DRUSE_ODIN_BIN:-}"
if test -z "$DRUSE_W41_ODIN" && command -v odin >/dev/null 2>&1; then
  DRUSE_W41_ODIN="$(command -v odin)"
fi
if test -z "$DRUSE_W41_ODIN" && test -x /tmp/druse-toolchain/odin; then
  DRUSE_W41_ODIN=/tmp/druse-toolchain/odin
fi
if test -z "$DRUSE_W41_ODIN"; then
  echo "WP41 CONTROLS -> BLOCKED: no Odin toolchain found (set DRUSE_ODIN_BIN). NOTHING RAN." >&2
  exit 2
fi

DRUSE_W41_TMP="$(mktemp -d -t druse-wp41-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_W41_TMP"' EXIT

tree_copy() { # name
  local t="$DRUSE_W41_TMP/$1"
  mkdir -p "$t/druse"
  cp -r "$DRUSE_ROOT/web" "$DRUSE_ROOT/vendor" "$DRUSE_ROOT/tests" "$t/druse/"
  printf '%s' "$t"
}

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

run_suite() { # tree
  env -u ODIN_ROOT "$DRUSE_W41_ODIN" test "$1/druse/tests/wp41-fault" \
    "-collection:druse=$1/druse" -out:"$DRUSE_W41_TMP/runner" 2>&1
}

# --- 1 & 2. POSITIVE: the real suite passes ----------------------------------
# It carries the positive controls INSIDE it — a complete request must be
# answered 200, and a fragmented one reassembled — so a green run here is
# already the statement that the lab can see a working server. Controls 3 and 4
# then ask whether it can see a broken one.
T="$(tree_copy positive)"
OUT="$(run_suite "$T")" || { echo "$OUT" >&2; fail "POSITIVE control failed: the real fault suite does not pass"; }
grep -qE 'Finished [1-9][0-9]* tests?.*successful' <<<"$OUT" ||
  { echo "$OUT" >&2; fail "POSITIVE control: the suite reported no successful tests"; }
echo "CONTROL 1+2: the real fault suite passes, including its own in-suite positive controls -> GREEN as required"

# --- 3. THE FINDING IS ABOUT THE SERVER --------------------------------------
# The suite's `phase_truncated_hold` asserts `Held_Open_Until_Lab_Gave_Up`. If
# that outcome were an artefact of the client, it would appear against ANY
# endpoint. It does not: with no server listening, the same code path cannot
# even connect, which is a different Outcome member.
#
# This is asserted by MUTATION rather than by a second suite: point the phase at
# a port nothing is listening on, and the expectation must go RED. A green run
# would mean the lab produces its headline finding without a server at all.
T="$(tree_copy no_server)"
H="$(md5sum "$T/druse/tests/wp41-fault/fault_test.odin" | cut -d' ' -f1)"
python3 - "$T/druse/tests/wp41-fault/fault_test.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	sock, ok := lab.dial(server.port, l.patience)
	testing.expect(t, ok, "the lab must be able to connect")
	if !ok {
		return
	}
	defer net.close(sock)

	// A valid, incomplete request: the request line and one header, no
	// terminator. Nothing about it is malformed — it is simply unfinished."""
new = """	sock, ok := lab.dial(59999, l.patience)
	testing.expect(t, ok, "the lab must be able to connect")
	if !ok {
		return
	}
	defer net.close(sock)

	// MUTATED BY CONTROL 3: no server listens on 59999."""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "no server behind the socket" "$T/druse/tests/wp41-fault/fault_test.odin" "$H"
if run_suite "$T" >/dev/null 2>&1; then
  fail "control '3: the finding is about the server' stayed GREEN with NO SERVER listening. The 'held open' outcome would then be a property of the lab, and the slowloris finding would be inadmissible."
fi
echo "CONTROL 3: the truncated-hold finding requires a real server -> RED without one, as required"

# --- 4. THE LAB CANNOT BE SATISFIED BY SILENCE -------------------------------
# `read_status` distinguishes a timeout (still open, said nothing) from a close.
# Collapse that distinction — treat every timeout as a response — and the two
# findings turn green while the server behaves identically. That is the shape of
# an instrument that agrees with whatever it is pointed at.
T="$(tree_copy silence_is_success)"
H="$(md5sum "$T/druse/tests/support/fault_lab/lab.odin" | cut -d' ' -f1)"
python3 - "$T/druse/tests/support/fault_lab/lab.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
# THE MUTATION REMOVES THE CAPABILITY, NOT ONE ROUTE TO IT — and two earlier
# versions of this probe removed a route, which is why the comment is this long.
#
# `read_status` reports "held open" from TWO places: the timeout branch inside
# the loop, and the tail after the loop exits. Deleting either one alone leaves
# the other producing the same observation, so the suite stayed green and the
# control accused the gate of a hole that was really a probe pointed at one of
# two doors.
#
# The rule this earned, and it generalises past this file: a probe must remove
# the ability to make an observation, not one path that happens to reach it.
# Same class as WP39's control 6 and WP18's control 6 — three in one session.
# THE COUNT IS ASSERTED, NOT ASSUMED, and WP56's re-run is why this comment
# exists. It was 2; WP45 added `read_status_again` for the keep-alive phases and
# made it 3. The probe caught that IMMEDIATELY rather than silently mutating two
# of three and reporting a hole — which is exactly what the earlier versions of
# this control did, and the reason the assert was added.
#
# It is deliberately an exact count rather than a minimum: a NEW report site is
# a new way to make this observation, and a probe that removes the ability must
# know about all of them. Raising this number is a decision, not an edit.
count = s.count(".Held_Open_Until_Lab_Gave_Up, 0")
assert count == 3, "expected 3 report sites, found %d" % count
s = s.replace(".Held_Open_Until_Lab_Gave_Up, 0", ".Responded, 0")
open(p, 'w').write(s)
PYEOF
assert_mutated "silence reported as a response" "$T/druse/tests/support/fault_lab/lab.odin" "$H"
if run_suite "$T" >/dev/null 2>&1; then
  fail "control '4: silence is not a response' stayed GREEN when the lab was mutated to report every timeout as a response. An instrument that agrees with whatever it is pointed at is not an instrument."
fi
echo "CONTROL 4: reporting silence as a response -> RED as required"

echo "PASS: all four WP41 fault-laboratory controls behaved as required"
