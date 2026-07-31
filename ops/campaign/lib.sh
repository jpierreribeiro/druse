# Shared campaign helpers. Sourced, not executed.
URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
URUQUIM_ARTIFACTS="${URUQUIM_ARTIFACTS:-$URUQUIM_ROOT/artifacts}"
URUQUIM_ODIN="${URUQUIM_ODIN:-/opt/uruquim-odin/odin}"
URUQUIM_BIN="${URUQUIM_BIN:-$URUQUIM_ARTIFACTS/bin}"
mkdir -p "$URUQUIM_ARTIFACTS" "$URUQUIM_BIN"

stamp() { date -u +%Y%m%dT%H%M%SZ; }

need_odin() {
  test -x "$URUQUIM_ODIN" || {
    echo "no compiler at $URUQUIM_ODIN — run ops/ci/install-odin.sh" >&2
    exit 2
  }
}

# revert_transport_fix / restore_transport_fix bracket a control run. They work
# on a COPY kept beside the source so an interrupted run cannot leave the tree
# reverted — which would silently turn every later campaign into a control.
FIX_BACKUP="$URUQUIM_ARTIFACTS/.server.odin.orig"

revert_b1_fix() {
  local f="$URUQUIM_ROOT/vendor/odin-http/server.odin"
  cp "$f" "$FIX_BACKUP"
  python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
a = s.index("\t\tsync.atomic_store_explicit(&s.pending_waiting, true, .Seq_Cst)")
b = s.index("\t}\n\titem := new(Accepted_Connection, s.conn_allocator)")
s = s[:a] + "\t\tsync.atomic_store_explicit(&s.pending_waiting, true, .Release)\n\t\treturn false\n" + s[b:]
s = s.replace("sync.atomic_load_explicit(&lane.handler_active, .Seq_Cst)",
              "sync.atomic_load_explicit(&lane.handler_active, .Acquire)")
s = s.replace("sync.atomic_load_explicit(&lane.queued_handoffs, .Seq_Cst)",
              "sync.atomic_load(&lane.queued_handoffs)")
s = s.replace("sync.atomic_load_explicit(&server.pending_waiting, .Seq_Cst)",
              "sync.atomic_load_explicit(&server.pending_waiting, .Acquire)")
s = s.replace("sync.atomic_store_explicit(&td.handler_active, false, .Seq_Cst)",
              "sync.atomic_store_explicit(&td.handler_active, false, .Release)")
s = s.replace("sync.atomic_store_explicit(&td.handler_active, true, .Seq_Cst)",
              "sync.atomic_store_explicit(&td.handler_active, true, .Release)")
# The safety-net tick would mask the very stall this control is trying to see.
s = s.replace("err := nbio.tick(nbio.NO_TIMEOUT if assigned else ACCEPT_STALL_RECHECK)",
              "err := nbio.tick()")
open(p, "w").write(s)
print("B1 fix reverted", file=sys.stderr)
PY
}

revert_b2_fix() {
  local f="$URUQUIM_ROOT/vendor/odin-http/server.odin"
  cp "$f" "$FIX_BACKUP"
  python3 - "$f" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
# 1. drop the `closing` refusal at the top of on_accept_dedicated
a = s.index("\tif atomic_load(&s.closing) {\n\t\tif op.accept.err == nil {")
b = s.index("\tif op.accept.err != nil {", a)
s = s[:a] + s[b:]
# 2. drop the lane-side accept_drained gate
a = s.index("\twhen URUQUIM_DEDICATED_ACCEPT {\n\t\t// URUQUIM PATCH 33 (transport audit F2)")
b = s.index("\tnbio.release_thread_event_loop()", a)
s = s[:a] + s[b:]
open(p, "w").write(s)
print("B2 fix reverted", file=sys.stderr)
PY
}

restore_fix() {
  test -f "$FIX_BACKUP" || return 0
  cp "$FIX_BACKUP" "$URUQUIM_ROOT/vendor/odin-http/server.odin"
  rm -f "$FIX_BACKUP"
  echo "fix restored" >&2
}

# Any exit path restores the tree. A control run that dies must not leave the
# repository holding reverted code.
trap restore_fix EXIT INT TERM
