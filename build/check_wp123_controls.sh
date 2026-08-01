#!/usr/bin/env bash
# WP123 / ADR-018 — the per-server state, under control.
#
# The freeze, public-api and docs gates already pin the two changed arities and
# the prose. This gate pins the four things none of them can see:
#
#   1. THE SUITE IS SENSITIVE. `tests/wp123-two-servers` is green against the
#      real implementation — but so is a suite that asserts nothing about which
#      server it is talking to. The mutation below collapses the registry back
#      to ONE slot, which is precisely the WP43 `g_server` behaviour, and
#      requires the suite to go red. Without this, the day someone rewrites the
#      registry the suite would keep passing and nobody would learn anything.
#
#      MEASURED while the suite was written: with the mutation applied, all four
#      tests fail — the counters read 0 for both servers and report the same
#      number, the stream token comes back Closed against the other server's
#      registry, and the stop of server A never returns (the suite hangs in
#      teardown, which is why the run below is bounded by `timeout` and a hang
#      counts as red rather than as a stalled gate).
#
#   2. RETIRING IS NOT FREE. A row stops accepting readers at the beginning of
#      retire, but cannot accept another publisher until every old reader has
#      left and the old pointers have been cleared. `claimed` and `live` are
#      deliberately separate state. A focused internal fixture holds a reader
#      inside while another server publishes; a mutation that gates publishers
#      on `live` must make that fixture fail on the named slot-reuse assertion.
#
#   3. ONE ACTIVE SERVE OWNS ONE APP. Multiple servers in a process require
#      multiple Apps. A private CAS control proves concurrent callers elect one
#      owner; a socket suite proves the loser returns before bind, the winner
#      retains its stop handle, bind failure can retry, and drain cannot restart.
#
#   4. VENDOR PATCH 43 IS LOAD-BEARING. The backend shutdown hook is what makes
#      `web.stop` async-signal-safe: it moved `stream.drain_begin` off the
#      caller's thread — where it took two mutexes a SIGTERM handler could
#      deadlock on — and onto the first lane to observe `closing`. Nothing in
#      the ordinary suite notices if that hook stops firing, because the
#      backend's own `max_drain_time` force-closes the streams anyway and every
#      deadline assertion still holds. MEASURED: with the hook disabled,
#      `tests/wp95-drain` was FULLY GREEN. The assertion that distinguishes them
#      is that the drain finishes PROMPTLY rather than at the deadline (2.597 s
#      with the hook removed, under 1 s with it), and this gate proves that
#      assertion is the one doing the work.
#
# The mutations are applied to a COPY of the tree, never to the working tree: a
# gate that edits the sources it is judging can leave them edited when it dies.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_REGISTRY_REL="web/internal/transport/server_registry.odin"
DRUSE_ADAPTER_REL="web/internal/transport/odin_http_adapter.odin"
DRUSE_SUITE="$DRUSE_ROOT/tests/wp123-two-servers/two_servers_test.odin"
DRUSE_LIFETIME_SUITE="$DRUSE_ROOT/tests/wp123-registry-lifetime/registry_internal_test.odin"
DRUSE_APP_INTERNAL_SUITE="$DRUSE_ROOT/tests/r0-app-serve-lifecycle/app_internal_test.odin"
DRUSE_APP_SOCKET_SUITE="$DRUSE_ROOT/tests/r0-app-serve-lifecycle/socket"
DRUSE_DRAIN_SUITE="$DRUSE_ROOT/tests/wp95-drain/drain_test.odin"

fail() {
  echo "WP123-CONTROL-FAIL: $*" >&2
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
DRUSE_TMP="$(mktemp -d -t druse-wp123-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

test -f "$DRUSE_SUITE" || fail "tests/wp123-two-servers is missing; it is the suite this work package exists to turn green"
test -f "$DRUSE_LIFETIME_SUITE" || fail "tests/wp123-registry-lifetime is missing; it proves a retiring slot cannot be reused while an old reader remains"
test -f "$DRUSE_APP_INTERNAL_SUITE" || fail "the same-App serve ownership control is missing"
test -f "$DRUSE_APP_SOCKET_SUITE/socket_test.odin" || fail "the same-App socket lifecycle suite is missing"
test -f "$DRUSE_ROOT/$DRUSE_REGISTRY_REL" || fail "$DRUSE_REGISTRY_REL is missing"

# ---------------------------------------------------------------------------
# 0. Structural claims the mutations below assume.
# ---------------------------------------------------------------------------
# The suite must cover all THREE pointers the old single slot conflated. A suite
# that proved only the counters would leave two thirds of the defect uncovered
# while reading as complete.
for DRUSE_CLAIM in \
  wp123_each_server_counts_only_its_own_responses \
  wp123_stopping_one_server_leaves_the_other_serving \
  wp123_a_stream_token_sends_to_the_server_that_opened_it \
  wp123_stopping_a_server_does_not_drain_another_servers_uploads; do
  grep -q "^$DRUSE_CLAIM ::" "$DRUSE_SUITE" ||
    fail "tests/wp123-two-servers no longer has '$DRUSE_CLAIM'. The retired single slot held THREE pointers — the backend server, the stream registry and the upload admission — and each is a separate way for one server to answer for another."
done

# `thread.join` cannot time out, so a suite that waits on it can only hang when
# the thing it tests hangs (the WP58 harness rule). Here the failure under test
# IS a stop that never returns, so this is not a style preference.
grep -q 'Wait_Stopped' "$DRUSE_SUITE" ||
  fail "the suite no longer waits on a deadline-bounded semaphore for a drain; a thread.join here turns a wrong-server stop into a hung gate instead of a failed assertion"

# The suite must stay PARALLEL: running the tests concurrently is the capability
# WP123 bought, and serialising them would hide the regression they catch. The
# grep skips comment lines, because the suite header EXPLAINS why it is not
# serialised and a naive match would fail on its own reasoning.
if sed -E 's://.*$::' "$DRUSE_SUITE" | grep -q 'ODIN_TEST_THREADS'; then
  fail "tests/wp123-two-servers asks to be serialised; running its two-server tests in parallel is the observable difference this work package delivered"
fi

# ---------------------------------------------------------------------------
# 1. Mutation A — collapse the registry to one slot (the WP43 g_server).
# ---------------------------------------------------------------------------
cp -a "$DRUSE_ROOT" "$DRUSE_TMP/tree"
rm -rf "$DRUSE_TMP/tree/.git" "$DRUSE_TMP/tree/.claude"

python3 - "$DRUSE_TMP/tree/$DRUSE_REGISTRY_REL" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
old = """	for i in 0 ..< SERVER_TABLE_CAP {
		e := &g_servers.entries[i]
		if sync.atomic_load(&e.claimed) {
			continue
		}
		sync.atomic_store(&e.claimed, true)
		generation := sync.atomic_load(&e.generation) + 1"""
new = """	for i in 0 ..< 1 { // MUTANT: one slot, last writer wins (the WP43 g_server)
		e := &g_servers.entries[i]
		sync.atomic_store(&e.claimed, true)
		generation := sync.atomic_load(&e.generation) + 1"""
if old not in src:
    sys.exit("WP123-CONTROL-FAIL: the slot-claim loop in server_registry.odin no longer matches the mutation this gate applies; re-derive it")
open(path, "w").write(src.replace(old, new, 1))
PY

# A hang is red. The mutant's stop reaches the wrong server, so the other one
# never leaves `serve` and the suite blocks in teardown; `timeout` turns that
# into a non-zero exit rather than a gate that never finishes.
if env ODIN_ROOT="$DRUSE_ODIN_ROOT" timeout 120 "$DRUSE_ODIN" test \
  "$DRUSE_TMP/tree/tests/wp123-two-servers" \
  "-collection:druse=$DRUSE_TMP/tree" \
  "-out:$DRUSE_TMP/mutant-registry" >"$DRUSE_TMP/registry.log" 2>&1; then
  fail "the two-server suite PASSED against a registry collapsed to one slot — which is the exact behaviour WP123 replaced. The suite is not measuring which server it is talking to. See $DRUSE_TMP/registry.log"
fi
echo "wp123: the two-server suite goes red when the registry is collapsed to one slot"

# ---------------------------------------------------------------------------
# 2. Mutation B — conflate retiring with free.
# ---------------------------------------------------------------------------
# First run the focused lifetime regression against the shipped transport. The
# fixture lives outside the package because these helpers stay private; copying
# it beside the exact sources is the same boundary discipline as WP71.
DRUSE_LIFETIME_BASELINE="$DRUSE_TMP/lifetime-baseline"
mkdir "$DRUSE_LIFETIME_BASELINE"
cp "$DRUSE_ROOT"/web/internal/transport/*.odin "$DRUSE_LIFETIME_BASELINE/"
cp "$DRUSE_LIFETIME_SUITE" "$DRUSE_LIFETIME_BASELINE/"

env ODIN_ROOT="$DRUSE_ODIN_ROOT" timeout 30 "$DRUSE_ODIN" test \
  "$DRUSE_LIFETIME_BASELINE" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$DRUSE_TMP/lifetime-baseline-test" >/dev/null
echo "wp123: a retiring slot stays claimed until its old readers leave"

DRUSE_LIFETIME_MUTANT="$DRUSE_TMP/lifetime-mutant"
cp -a "$DRUSE_LIFETIME_BASELINE" "$DRUSE_LIFETIME_MUTANT"
python3 - "$DRUSE_LIFETIME_MUTANT/server_registry.odin" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
old = "\t\tif sync.atomic_load(&e.claimed) {"
new = "\t\tif sync.atomic_load(&e.live) { // MUTANT: retiring is mistaken for free"
if src.count(old) != 1:
    sys.exit("WP123-CONTROL-FAIL: the publisher claim check no longer matches the retiring-slot mutation; re-derive it")
open(path, "w").write(src.replace(old, new, 1))
PY

if env ODIN_ROOT="$DRUSE_ODIN_ROOT" timeout 30 "$DRUSE_ODIN" test \
  "$DRUSE_LIFETIME_MUTANT" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$DRUSE_TMP/lifetime-mutant-test" >"$DRUSE_TMP/lifetime-mutant.log" 2>&1; then
  fail "the lifetime fixture PASSED when publishers treated live=false as a free slot; the original slot-reuse race is no longer under control"
fi
grep -q 'RETIRING-SLOT-REUSED' "$DRUSE_TMP/lifetime-mutant.log" ||
  fail "the retiring-slot mutant went red for an unrelated reason. It must fail because a publisher reused the row while an old reader remained. See $DRUSE_TMP/lifetime-mutant.log"
echo "wp123: the lifetime fixture goes red on RETIRING-SLOT-REUSED when claimed and live are conflated"

# ---------------------------------------------------------------------------
# 3. Mutation C — let more than one active serve own the same App.
# ---------------------------------------------------------------------------
DRUSE_APP_BASELINE="$DRUSE_TMP/app-baseline"
mkdir "$DRUSE_APP_BASELINE"
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_APP_BASELINE/"
cp "$DRUSE_APP_INTERNAL_SUITE" "$DRUSE_APP_BASELINE/"

env ODIN_ROOT="$DRUSE_ODIN_ROOT" timeout 30 "$DRUSE_ODIN" test \
  "$DRUSE_APP_BASELINE" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$DRUSE_TMP/app-baseline-test" >/dev/null
env ODIN_ROOT="$DRUSE_ODIN_ROOT" timeout 30 "$DRUSE_ODIN" test \
  "$DRUSE_APP_SOCKET_SUITE" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$DRUSE_TMP/app-socket-test" >/dev/null
echo "wp123: one active serve owns an App; bind retry and terminal drain are socket-proven"

DRUSE_APP_MUTANT="$DRUSE_TMP/app-mutant"
cp -a "$DRUSE_APP_BASELINE" "$DRUSE_APP_MUTANT"
python3 - "$DRUSE_APP_MUTANT/concurrency.odin" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
old = """\tif _, claimed := sync.atomic_compare_exchange_strong(&a.private.serve_active, 0, 1); !claimed {
\t\treturn false
\t}"""
new = """\tsync.atomic_store(&a.private.serve_active, 1) // MUTANT: every concurrent caller wins"""
if src.count(old) != 1:
    sys.exit("WP123-CONTROL-FAIL: the App serve claim no longer matches its multi-winner mutation; re-derive it")
open(path, "w").write(src.replace(old, new, 1))
PY

if env ODIN_ROOT="$DRUSE_ODIN_ROOT" timeout 30 "$DRUSE_ODIN" test \
  "$DRUSE_APP_MUTANT" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$DRUSE_TMP/app-mutant-test" >"$DRUSE_TMP/app-mutant.log" 2>&1; then
  fail "the same-App ownership fixture PASSED when every concurrent serve won the claim"
fi
grep -q 'SERVE-CLAIM-MULTIPLE-WINNERS' "$DRUSE_TMP/app-mutant.log" ||
  fail "the same-App claim mutant went red for an unrelated reason. See $DRUSE_TMP/app-mutant.log"
grep -q 'Each concurrent `web.serve` requires a different App' "$DRUSE_ROOT/docs/canonical-patterns.md" ||
  fail "the same-App limitation is absent from the canonical patterns"
echo "wp123: the App ownership fixture goes red on SERVE-CLAIM-MULTIPLE-WINNERS when the CAS is removed"

# ---------------------------------------------------------------------------
# 4. Mutation D — disarm vendor patch 43 (the backend shutdown hook).
# ---------------------------------------------------------------------------
rm -rf "$DRUSE_TMP/tree2"
cp -a "$DRUSE_ROOT" "$DRUSE_TMP/tree2"
rm -rf "$DRUSE_TMP/tree2/.git" "$DRUSE_TMP/tree2/.claude"

grep -q '^	s.on_shutdown = runtime_drain$' "$DRUSE_TMP/tree2/$DRUSE_ADAPTER_REL" ||
  fail "the adapter no longer arms the backend shutdown hook (vendor patch 43); without it web.stop is not async-signal-safe, because the registry drain returns to the caller's thread and its two mutexes"
sed -i 's|^\ts.on_shutdown = runtime_drain$|\ts.on_shutdown = nil // MUTANT: patch 43 disarmed|' \
  "$DRUSE_TMP/tree2/$DRUSE_ADAPTER_REL"

if env ODIN_ROOT="$DRUSE_ODIN_ROOT" timeout 120 "$DRUSE_ODIN" test \
  "$DRUSE_TMP/tree2/tests/wp95-drain" \
  "-collection:druse=$DRUSE_TMP/tree2" -define:ODIN_TEST_THREADS=1 \
  "-out:$DRUSE_TMP/mutant-hook" >"$DRUSE_TMP/hook.log" 2>&1; then
  fail "tests/wp95-drain PASSED with the backend shutdown hook disarmed. That is the state this suite was in before WP123: the backend's own max_drain_time force-closes the streams, every deadline assertion still holds, and the graceful drain the suite claims to prove is never exercised. The distinguishing assertion (the drain finishes well INSIDE the deadline) is missing or too loose. See $DRUSE_TMP/hook.log"
fi
grep -q 'FORCE-CLOSED' "$DRUSE_TMP/hook.log" ||
  fail "tests/wp95-drain went red with the hook disarmed, but not on the assertion that names the mechanism. It has to fail BECAUSE the drain ran to the deadline, or the control is measuring something else. See $DRUSE_TMP/hook.log"
echo "wp123: tests/wp95-drain goes red — on the force-close assertion — when vendor patch 43 is disarmed"

# ---------------------------------------------------------------------------
# 5. The signal-safe claim is structural, not a comment.
# ---------------------------------------------------------------------------
# `request_stop` is what a SIGTERM handler runs. It must take no lock: the
# defect this work package fixed was a mutex here plus two more inside the
# drains, any of which deadlocks a process that catches the signal on a thread
# already holding one.
DRUSE_STOP_BODY="$(sed -n '/^request_stop :: proc(h: Server_Handle) {/,/^}/p' "$DRUSE_ROOT/$DRUSE_ADAPTER_REL")"
test -n "$DRUSE_STOP_BODY" || fail "request_stop no longer takes a Server_Handle"
if grep -qE 'sync\.(lock|mutex_lock|guard)' <<<"$DRUSE_STOP_BODY"; then
  fail "request_stop takes a lock. web.stop is documented three times over as callable from a signal handler — examples/09-graceful-shutdown wires it to SIGTERM — and a mutex on that path turns the operator's drain into the hang it exists to prevent. The window is widest when the server is busiest."
fi
if grep -qE 'stream\.drain_begin|ingest\.admission_drain' <<<"$DRUSE_STOP_BODY"; then
  fail "request_stop calls a drain that takes a mutex (stream.drain_begin / ingest.admission_drain). Those belong in runtime_drain, which the backend runs from its own shutdown on a lane — see vendor patch 43."
fi
echo "wp123: request_stop is lock-free (async-signal-safe) and drives no mutex-taking drain"

echo "PASS: WP123 per-server state controls"
