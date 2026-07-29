#!/usr/bin/env bash
# C-06 — the reverse-proxy contract, under control.
#
# Four executable claims:
#
#   1. THE BUFFERING ARM'S INEQUALITY HOLDS. The clause rests on a stream that
#      does NOT complete inside the observation window. STREAM_CHUNKS x
#      STREAM_TICK must exceed BUFFERED_PATIENCE — the first version of this
#      suite had 600 ms of stream against 1500 ms of patience, so the stream
#      completed, the buffering proxy forwarded it at 601 ms, and the arm proved
#      nothing while still passing;
#   2. THE CONTROL ARMS SURVIVE. A direct arm and an unbuffered arm are what
#      make the buffered arm a finding rather than a broken server;
#   3. THE UNTRUSTED ARM SURVIVES. It is the security half of the client-address
#      clause: an untrusted peer's X-Forwarded-For must be ignored, or any client
#      can name its own address in an audit log;
#   4. what is OWED is still recorded — a fixture proves the contract is
#      satisfiable, not that nginx satisfies it.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_SUITE="$DRUSE_ROOT/tests/c06-proxy-contract/proxy_contract_test.odin"
DRUSE_DOC="$DRUSE_ROOT/planning/closure-proxy-contract.md"

fail() {
  echo "C06-CONTROL-FAIL: $*" >&2
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
DRUSE_TMP="$(mktemp -d -t druse-c06-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

test -f "$DRUSE_SUITE" || fail "tests/c06-proxy-contract/proxy_contract_test.odin is missing"
test -f "$DRUSE_DOC" || fail "planning/closure-proxy-contract.md is missing"

# --- 1. The inequality that makes the buffering arm mean something -----------
DRUSE_TICK_MS="$(sed -n 's/^STREAM_TICK :: \([0-9]\+\) \* time.Millisecond$/\1/p' "$DRUSE_SUITE")"
DRUSE_CHUNKS="$(sed -n 's/^STREAM_CHUNKS :: \([0-9]\+\).*$/\1/p' "$DRUSE_SUITE")"
DRUSE_PATIENCE_MS="$(sed -n 's/^BUFFERED_PATIENCE :: \([0-9]\+\) \* time.Millisecond$/\1/p' "$DRUSE_SUITE")"
test -n "$DRUSE_TICK_MS" -a -n "$DRUSE_CHUNKS" -a -n "$DRUSE_PATIENCE_MS" ||
  fail "could not read STREAM_TICK / STREAM_CHUNKS / BUFFERED_PATIENCE; the inequality below cannot be checked and the buffering arm could silently stop testing anything"
DRUSE_STREAM_MS=$((DRUSE_TICK_MS * DRUSE_CHUNKS))
test "$DRUSE_STREAM_MS" -gt "$((DRUSE_PATIENCE_MS + 500))" || fail "$(cat <<EOF
the stream (${DRUSE_STREAM_MS} ms) no longer comfortably outlasts the observation window (${DRUSE_PATIENCE_MS} ms).
The buffering clause rests on a stream that does NOT complete inside the window:
that is what makes a buffering proxy withhold it FOREVER rather than merely
late. With a completing stream the buffered arm passes while proving nothing —
which is exactly what the first version of this suite did (600 ms of stream
against 1500 ms of patience; the proxy forwarded everything at 601 ms).
EOF
)"

# --- 2 & 3. The arms that make the findings findings -------------------------
for DRUSE_ARM in \
  'direct        first chunk' \
  'buffering off first chunk' \
  'buffering ON  first chunk' \
  'untrusted: via proxy'; do
  grep -qF "$DRUSE_ARM" "$DRUSE_SUITE" ||
    fail "the '$DRUSE_ARM' arm is gone. Every arm here is a control: without the direct and unbuffered arms the buffered result is indistinguishable from a broken server, and without the untrusted arm the client-address clause loses its security half."
done
grep -q 'c06_a_buffering_proxy_withholds_a_stream_and_an_unbuffered_one_does_not ::' "$DRUSE_SUITE" ||
  fail "the buffering clause test is gone"
grep -q 'c06_the_forwarded_client_address_is_believed_only_from_a_trusted_hop ::' "$DRUSE_SUITE" ||
  fail "the client-address clause test is gone"

# --- 4. The owed work is still named -----------------------------------------
DRUSE_FLAT="$(tr '\n' ' ' <"$DRUSE_DOC" | tr -s ' ')"
grep -qi 'real-proxy round' <<<"$DRUSE_FLAT" ||
  fail "the owed real-proxy round is no longer recorded. The fixture proves the contract is SATISFIABLE, not that nginx satisfies it, and the difference must stay written down."
grep -qi 'mandatory, documented' <<<"$DRUSE_FLAT" ||
  fail "the record lost the classification rule it rests on — a delegation is acceptable only if the topology is mandatory, documented AND tested"

# --- Green -------------------------------------------------------------------
env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
  "$DRUSE_ROOT/tests/c06-proxy-contract" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$DRUSE_TMP/c06"

echo "c06: the stream (${DRUSE_STREAM_MS} ms) outlasts the observation window (${DRUSE_PATIENCE_MS} ms)"
echo "c06: direct, unbuffered and buffered arms all present; the untrusted-hop arm survives"
echo "c06: the owed real-proxy round is on record"
echo "PASS: C-06 reverse-proxy contract controls"
