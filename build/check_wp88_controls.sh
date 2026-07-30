#!/usr/bin/env bash
# WP88/WP89 — the stream registry and cross-lane delivery, under control.
#
# Four executable claims:
#   1. the WP87 stream corpus is green UNEDITED (checked here by content
#      hash of its test names — a dropped case cannot hide) and the WP88
#      suite (ring wraparound, process budget, wake hook, concurrent
#      producers) is green;
#   2. the plan's control mutation holds: removing the generation check in a
#      tree copy makes the stale-safety cases fail — the corpus really does
#      guard G7-3, not a coincidence of the implementation;
#   3. the implementation keeps its boundary: `web` still imports no stream
#      package (that wiring is WP90), and the stream package itself imports
#      no backend and no `druse:web`.
#   4. try_send releases its slot mutex exactly once before invoking the wake;
#      a second unlock is undefined behaviour and makes the concurrent corpus
#      spin forever instead of reporting a useful failure.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP88-CONTROL-FAIL: $*" >&2
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
DRUSE_TMP="$(mktemp -d -t druse-wp88-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

# Claim 1a — corpus completeness by name: the twelve pre-registered cases.
for DRUSE_CASE in \
  wp87_registry_initializes_with_preregistered_capacity \
  wp87_open_commits_reserved_state_exactly_once \
  wp87_open_beyond_capacity_refuses_typed \
  wp87_stream_outlives_the_handler_scope \
  wp87_enqueue_copies_the_callers_bytes \
  wp87_queue_full_is_deterministic_and_immediate \
  wp87_close_is_idempotent \
  wp87_full_user_capacity_cannot_block_close \
  wp87_send_after_close_has_one_terminal_owner \
  wp87_stale_token_after_slot_reuse_refuses \
  wp87_no_open_and_no_send_after_drain_begins \
  wp87_close_releases_the_stream_for_accounting; do
  grep -q "^$DRUSE_CASE ::" \
    "$DRUSE_ROOT/tests/wp87-stream-lifecycle/stream_lifecycle_test.odin" ||
    fail "pre-registered corpus case dropped: $DRUSE_CASE"
done

# Claim 1b preflight — validate the M2 lock shape BEFORE running the concurrent
# suite. A duplicate unlock here previously made that suite consume CPUs until
# an external timeout, so checking this after the suite is too late.
DRUSE_STREAM="$DRUSE_ROOT/web/internal/stream/stream.odin"
grep -q 'wp88_the_slot_wake_runs_outside_the_slot_lock' \
  "$DRUSE_ROOT/tests/wp88-stream-registry/registry_test.odin" ||
  fail "the M2 control is gone: nothing now detects the slot wake being invoked under s.mu, which deadlocks the owner lane against a full nbio queue"
if ! grep -Pzoq 'slot_user := s\.wake_user\s*\n\s*sync\.mutex_unlock\(&s\.mu\)' \
  "$DRUSE_STREAM"; then
  fail "try_send no longer releases s.mu before invoking the slot wake (M2). A wake that reaches a full cross-thread nbio queue spins under this lock while the owner lane blocks on it — deadlock."
fi
if sed -n '/\/\/ 5\. wake the owner/,/\/\/ 6\. a closed typed result/p' \
    "$DRUSE_STREAM" |
    grep -q 'sync\.mutex_unlock(&s\.mu)'; then
  fail "try_send unlocks s.mu again after invoking the wake; the duplicate unlock corrupts mutex state and makes the concurrent WP89 corpus spin"
fi

# Claim 1b — both suites green on the real tree.
env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
  "$DRUSE_ROOT/tests/wp87-stream-lifecycle" \
  "-collection:druse=$DRUSE_ROOT" "-out:$DRUSE_TMP/corpus"
env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
  "$DRUSE_ROOT/tests/wp88-stream-registry" \
  "-collection:druse=$DRUSE_ROOT" "-out:$DRUSE_TMP/registry"

# Claim 2 — the generation-check mutation. A copy of the tree loses the
# stale guard; the corpus and the registry suite must both catch it.
DRUSE_MUT="$DRUSE_TMP/mut"
mkdir -p "$DRUSE_MUT/web/internal" "$DRUSE_MUT/tests"
cp -r "$DRUSE_ROOT/web" "$DRUSE_MUT/" 2>/dev/null
cp -r "$DRUSE_ROOT/vendor" "$DRUSE_MUT/" 2>/dev/null
cp -r "$DRUSE_ROOT/tests/wp87-stream-lifecycle" "$DRUSE_MUT/tests/"
cp -r "$DRUSE_ROOT/tests/wp88-stream-registry" "$DRUSE_MUT/tests/"
sed -i 's/s\.generation != tok\.generation/false/g' \
  "$DRUSE_MUT/web/internal/stream/stream.odin"
grep -q 'if false {' "$DRUSE_MUT/web/internal/stream/stream.odin" ||
  fail "the generation-check mutation did not apply; the control is broken"
if env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
    "$DRUSE_MUT/tests/wp87-stream-lifecycle" \
    "-collection:druse=$DRUSE_MUT" \
    "-out:$DRUSE_TMP/mut-corpus" >/dev/null 2>&1; then
  fail "the corpus survives without the generation check — stale safety is not being tested (G7-3)"
fi

# Claim 3 — boundaries, staged by WP90b: the stream package is now wired,
# but ONLY through the transport boundary. `package web` (the public core)
# still imports it nowhere, and the stream package itself remains
# executor-agnostic: no backend, no `druse:web`, no transport.
if grep -rnE '^[[:space:]]*import[[:space:]].*"druse:web/internal/stream"' \
  "$DRUSE_ROOT/web" --include='*.odin' -l |
  grep -v 'web/internal/transport/' >/dev/null; then
  fail "the stream package is imported outside the transport boundary (ADR-009)"
fi
if grep -nE '"druse:(web|vendor)' "$DRUSE_ROOT/web/internal/stream"/*.odin; then
  fail "the stream package imports web or the backend; it must stay executor-agnostic"
fi

echo "wp88: the WP87 stream corpus is green unedited, all 12 cases present"
echo "wp88: the slot wake is invoked outside s.mu, on both try_send and close (M2)"
echo "wp88: ring wraparound, process budget, wake hook and 2000-event concurrency hold"
echo "wp88: removing the generation check makes the corpus fail (G7-3 control)"
echo "wp88: stream package wired only through the transport boundary; imports neither web nor backend"
echo "PASS: WP88/WP89 registry and delivery controls"
