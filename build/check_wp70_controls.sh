#!/usr/bin/env bash
# WP70 — immutable serving publication and race-free framework-owned state.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP70-CONTROL-FAIL: $*" >&2
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
DRUSE_TMP="$(mktemp -d -t druse-wp70-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

run_internal() { # package, binary
  env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test "$1" \
    "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
    "-out:$DRUSE_TMP/$2"
}

DRUSE_INTERNAL="$DRUSE_TMP/internal"
mkdir "$DRUSE_INTERNAL"
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_INTERNAL/"
cp "$DRUSE_ROOT/tests/wp70-thread-safety/wp70_internal_test.odin" "$DRUSE_INTERNAL/"
run_internal "$DRUSE_INTERNAL" internal-green

timeout 20 env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
  "$DRUSE_ROOT/tests/wp70-thread-safety/stop" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$DRUSE_TMP/stop"

# Three independent mutations prove the contention corpus owns the mechanism:
# IDs must allocate atomically, lazy miss state must be completed before
# publication, and configuration after publication must not alter the snapshot.
mutant_must_fail() { # name, sed expression, file
  local name="$1" expression="$2" file="$3"
  local mutant="$DRUSE_TMP/mutant-$name"
  mkdir "$mutant"
  cp "$DRUSE_ROOT"/web/*.odin "$mutant/"
  cp "$DRUSE_ROOT/tests/wp70-thread-safety/wp70_internal_test.odin" "$mutant/"
  sed -i "$expression" "$mutant/$file"
  if env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test "$mutant" \
      "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
      "-out:$DRUSE_TMP/mutant-$name-bin" >/dev/null 2>&1; then
    fail "$name mutation unexpectedly passed"
  fi
}

mutant_must_fail request-id \
  's/counter := sync.atomic_add(&request_id_counter, 1) + 1/counter := u64(1)/' \
  request_id.odin
mutant_must_fail miss-publication \
  's/^\tmiss_chain_ensure(a)$/\t\/\/ mutation: publish incomplete state/' \
  concurrency.odin
mutant_must_fail late-route \
  '0,/^\tif app_is_serving(a) {$/s//\tif false {/' \
  dispatch_table.odin

# THE ADAPTER'S SERVER LIFETIME IS STILL PROTECTED — by a different mechanism
# since WP123, and this check follows the invariant rather than the code that
# used to carry it.
#
# WP70's answer was a mutex in `odin_http_adapter.odin`, held across every read
# of the running server, so a concurrent shutdown could not free what a reader
# was holding. This check used to `grep -F 'mutex:  sync.Mutex'` for it — two
# spaces and all — which is exactly the implementation-text pinning R-22 names:
# an honest refactor fails with a message accusing the maintainer of breaking a
# guarantee they kept.
#
# WP123 could not keep that mutex. `web.stop` is documented as callable from a
# SIGTERM handler and a mutex on that path deadlocks the process on the stop
# itself. What replaces it protects the same lifetime WITHOUT a lock: a retire
# invalidates the generation first, so no new reader is admitted, then WAITS OUT
# the readers already inside, and only then clears the pointers. `serve` destroys
# the runtime after that returns.
#
# The ORDER is the guarantee, so the order is what is checked. Clearing the
# pointers before the drain, or draining before invalidating, would each restore
# the use-after-free while leaving all three lines present.
DRUSE_REGISTRY="$DRUSE_ROOT/web/internal/transport/server_registry.odin"
test -f "$DRUSE_REGISTRY" ||
  fail "web/internal/transport/server_registry.odin is missing; the adapter's server lifetime is protected by nothing"

DRUSE_RETIRE="$(sed -n '/^server_retire :: proc(h: Server_Handle) {/,/^}/p' "$DRUSE_REGISTRY")"
test -n "$DRUSE_RETIRE" ||
  fail "server_retire is gone from the registry; nothing ends a server's registration, so a handle outlives the runtime it names"

druse_retire_line() { # pattern -> line number within server_retire
  grep -nE "$1" <<<"$DRUSE_RETIRE" | head -1 | cut -d: -f1
}
DRUSE_L_GEN="$(druse_retire_line 'atomic_add\(&e\.generation, 1\)')"
DRUSE_L_DRAIN="$(druse_retire_line 'atomic_load\(&e\.readers\) != 0')"
DRUSE_L_CLEAR="$(druse_retire_line '^\s*e\.server = nil')"

test -n "$DRUSE_L_GEN" ||
  fail "server_retire no longer invalidates the generation. Without it a stale handle still names a live entry, and a reader holding one dereferences a runtime that serve has already destroyed."
test -n "$DRUSE_L_DRAIN" ||
  fail "server_retire no longer waits for its readers to leave. serve destroys the stream registry and the upload admission the moment it returns, so a stream_send in flight on another thread reads freed memory — the exact use-after-free WP70's mutex existed to prevent."
test -n "$DRUSE_L_CLEAR" ||
  fail "server_retire no longer clears the entry's pointers; a retired slot keeps naming a dead runtime"

test "$DRUSE_L_GEN" -lt "$DRUSE_L_DRAIN" ||
  fail "server_retire waits for readers BEFORE invalidating the generation. New readers are still being admitted while it waits, so the wait races an open population instead of draining a closed one."
test "$DRUSE_L_DRAIN" -lt "$DRUSE_L_CLEAR" ||
  fail "server_retire clears the entry's pointers BEFORE its readers have left. A reader inside the entry then reads a nil registry — or worse, reads it a moment before the clear and uses it a moment after serve freed it."

# And the readers actually go through the acquisition that makes the drain
# meaningful. A reader that touched the row without incrementing `readers` would
# be invisible to the wait above, which would then be a wait on nothing.
grep -q 'server_acquire' "$DRUSE_ROOT/web/internal/transport/odin_http_adapter.odin" ||
  fail "the adapter reads the server registry without server_acquire, so server_retire's drain counts none of its readers"

# A SLOT IS NOT FREE UNTIL THE RETIRE HAS LEFT IT, and this is the half of the
# lifetime that has no behavioural test.
#
# `live` and `claimed` look like the same bit and are not. `live` shuts the door
# on READERS at the top of a retire; `claimed` shuts it on PUBLISHERS until the
# retire has finished. Written with one bit doing both jobs — which is how this
# file's first draft had it — a `serve` starting while another retires claims the
# slot the instant `live` goes false, and the retire then clears `server`,
# `streams` and `admission` OUT FROM UNDER the server that just published them.
# The new server is live, its handle valid, its generation current, and every
# read through it answers as though no server were running.
#
# It is checked HERE, structurally, because it cannot practically be checked
# behaviourally: the window is the microseconds between one `serve` returning and
# another claiming its slot, and `tests/wp123-two-servers` is green with the
# defect present. A guarantee whose only evidence is that nobody has hit it yet
# is not a guarantee.
DRUSE_PUBLISH="$(sed -n '/^server_publish :: proc(/,/^}/p' "$DRUSE_REGISTRY")"
test -n "$DRUSE_PUBLISH" || fail "server_publish is gone from the registry"
grep -q 'atomic_load(&e.claimed)' <<<"$DRUSE_PUBLISH" ||
  fail "server_publish selects a slot by something other than 'claimed'. Selecting on 'live' takes slots a retire is still inside: that retire then clears the pointers of the server that just claimed it, and the newcomer reads as though no server were running."
grep -q 'atomic_store(&e.claimed, true)' <<<"$DRUSE_PUBLISH" ||
  fail "server_publish does not mark the slot claimed, so two concurrent serves can take the same one"

DRUSE_L_UNCLAIM="$(druse_retire_line 'atomic_store\(&e\.claimed, false\)')"
test -n "$DRUSE_L_UNCLAIM" ||
  fail "server_retire never releases the slot to publishers; the table leaks a row per served server and the seventeenth serve in a process's life fails to bind"
test "$DRUSE_L_CLEAR" -lt "$DRUSE_L_UNCLAIM" ||
  fail "server_retire releases the slot to publishers BEFORE it has cleared the entry. A serve starting in that window claims the row and publishes its pointers, and this retire then nils them — leaving a live server that every reader sees as absent."
echo "wp70: the adapter's server lifetime is protected — generation invalidated, readers drained, pointers cleared, slot released, in that order"
grep -qF 'sync.atomic_add(&server.refused_total, 1)' \
  "$DRUSE_ROOT/vendor/odin-http/server.odin" ||
  fail "multi-lane refusal total is not atomic"
grep -qF 'date:       Server_Date' "$DRUSE_ROOT/vendor/odin-http/server.odin" ||
  fail "the Date cache is not lane-owned"

echo "wp70: immutable App publication and 8-lane request-ID/dispatch contention are green"
echo "wp70: 16 concurrent stop callers elect exactly one backend shutdown owner"
echo "wp70: request-ID, miss-publication and late-route mutations are rejected"
echo "PASS: WP70 thread-safe core controls"
