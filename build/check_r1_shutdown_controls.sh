#!/usr/bin/env bash
# R1-WP01 — controls for the real-process shutdown contract.
set -euo pipefail

DRUSE_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DRUSE_ODIN="${DRUSE_ODIN_BIN:-$(command -v odin || true)}"

fail() {
  echo "R1-SHUTDOWN-CONTROL-FAIL: $*" >&2
  exit 1
}

test -n "$DRUSE_ODIN" || fail "Odin compiler not found"
bash -n "$DRUSE_ROOT/ops/verification/run-shutdown-drill.sh"
PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/druse-r1-python-cache" \
  python3 -m py_compile "$DRUSE_ROOT/tests/r1-process-shutdown/client.py"

HANDLER_BODY="$(sed -n '/^on_signal :: proc/,/^}/p' "$DRUSE_ROOT/tests/r1-process-shutdown/server/main.odin")"
test -n "$HANDLER_BODY" || fail "signal handler not found"
grep -q 'runtime.default_context' <<<"$HANDLER_BODY" || fail "signal handler does not establish the default context"
grep -q 'web.stop(&app_a)' <<<"$HANDLER_BODY" || fail "signal handler does not stop its App"
if grep -Eq 'fmt\.|os\.|log|print|alloc|mutex|lock|sleep' <<<"$HANDLER_BODY"; then
  fail "signal handler contains allocation, logging, waiting or locking vocabulary"
fi
echo "r1-shutdown: signal handler is structurally minimal"

python3 - "$DRUSE_ROOT/web/lifecycle.odin" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
body = src[src.index("stop :: proc"):src.index("// is_draining reports")]
published = body.index("sync.atomic_store(&a.private.draining, 1)")
requested = body.index("transport.request_stop")
if published >= requested:
    raise SystemExit("R1-SHUTDOWN-CONTROL-FAIL: draining must publish before transport refusal starts")
PY
echo "r1-shutdown: draining publication precedes transport stop"

UNIT="$DRUSE_ROOT/ops/deploy/druse.service"
grep -q 'max_drain_time.*DRAIN_TIME_LIMIT' "$DRUSE_ROOT/web/limits.odin" || fail "DEFAULT_LIMITS no longer derives max_drain_time from DRAIN_TIME_LIMIT"
grep -q 'DRAIN_TIME_LIMIT :: i64(10 \* 1_000_000_000)' "$DRUSE_ROOT/web/limits.odin" || fail "default max_drain_time is no longer visibly 10s; re-derive the supervisor inequality"

check_supervisor_deadline() {
  local unit=$1 timeout_value
  timeout_value="$(sed -n 's/^TimeoutStopSec=//p' "$unit" | tail -1)"
  [[ "$timeout_value" =~ ^[0-9]+$ ]] || return 1
  test "$timeout_value" -gt 10
}

check_supervisor_deadline "$UNIT" || fail "canonical supervisor requires an integer TimeoutStopSec greater than the 10s default drain"
UNIT_TIMEOUT="$(sed -n 's/^TimeoutStopSec=//p' "$UNIT" | tail -1)"
echo "r1-shutdown: TimeoutStopSec=${UNIT_TIMEOUT}s is greater than default max_drain_time=10s"

TIMEOUT_PROBE="$(mktemp -d -t druse-r1-timeout-control-XXXXXXXX)"
cp "$UNIT" "$TIMEOUT_PROBE/druse.service"
sed -i '/^TimeoutStopSec=/d' "$TIMEOUT_PROBE/druse.service"
if check_supervisor_deadline "$TIMEOUT_PROBE/druse.service"; then
  fail "the supervisor deadline control accepted a unit without TimeoutStopSec"
fi
rm -rf "$TIMEOUT_PROBE"
echo "r1-shutdown: supervisor deadline control rejects a missing TimeoutStopSec"

env DRUSE_ODIN_BIN="$DRUSE_ODIN" bash "$DRUSE_ROOT/ops/verification/run-shutdown-drill.sh" "$DRUSE_ROOT"

MUTANT="$(mktemp -d -t druse-r1-shutdown-mutant-XXXXXXXX)"
trap 'rm -rf "$MUTANT"' EXIT
mkdir -p "$MUTANT/web" "$MUTANT/vendor"
cp -a "$DRUSE_ROOT/web/." "$MUTANT/web/"
cp -a "$DRUSE_ROOT/vendor/odin-http" "$MUTANT/vendor/odin-http"
python3 - "$MUTANT/web/lifecycle.odin" <<'PY'
import sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
old = "\tsync.atomic_store(&a.private.draining, 1)"
if src.count(old) != 1:
    raise SystemExit("R1-SHUTDOWN-CONTROL-FAIL: draining mutation pattern is stale")
open(p, "w", encoding="utf-8").write(src.replace(old, "\t// MUTANT: readiness never publishes", 1))
PY

if env DRUSE_ODIN_BIN="$DRUSE_ODIN" DRUSE_COLLECTION_ROOT="$MUTANT" DRUSE_R1_ARM=s0 \
  bash "$DRUSE_ROOT/ops/verification/run-shutdown-drill.sh" "$DRUSE_ROOT" >/dev/null 2>&1; then
  fail "S0 stayed green when the draining publication was removed"
fi
echo "r1-shutdown: S0 goes red when draining publication is removed"
echo "PASS: R1 shutdown controls"
