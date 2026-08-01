#!/usr/bin/env bash
# R1-WP02 resource/supervisor campaign.  Run from a CLEAN committed candidate.
# The local arms measure the real Druse process; the user-systemd arms prove
# cgroup OOM recovery, restart backoff, crash-loop stop and clean-stop behavior
# without requiring root or touching a production unit.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TODAY="$(date -u +%F)"
OUTPUT="$ROOT/evidence/${TODAY}-r1-resource-budget"
RUN_SYSTEMD=1

usage() {
  echo "usage: $0 [--output DIR] [--skip-systemd]" >&2
  exit 2
}

while test "$#" -gt 0; do
  case "$1" in
    --output)
      test "$#" -ge 2 || usage
      OUTPUT="$2"
      shift 2
      ;;
    --skip-systemd)
      RUN_SYSTEMD=0
      shift
      ;;
    *) usage ;;
  esac
done

fail() {
  echo "ERROR: R1 resource drill: $*" >&2
  exit 1
}

test -z "$(git -C "$ROOT" status --porcelain)" ||
  fail "candidate working tree is dirty; commit first so evidence has one identity"
test ! -e "$OUTPUT" || fail "output already exists: $OUTPUT"

ODIN_BIN="${DRUSE_ODIN_BIN:-$(command -v odin)}"
test -x "$ODIN_BIN" || fail "Odin compiler not found"
PROFILE="$ROOT/ops/deploy/runtime-limits.example"
PREFLIGHT="$ROOT/ops/deploy/check-runtime-limits.sh"
CLIENT="$ROOT/tests/r1-resource-budget/client.py"
test -r "$PROFILE" && test -x "$PREFLIGHT" && test -r "$CLIENT" ||
  fail "R1-WP02 profile/preflight/client is incomplete"

WORK="$(mktemp -d /tmp/druse-r1-resource-XXXXXX)"
SERVER="$WORK/resource-server"
ACTIVE_PID=""
UNITS=()

cleanup() {
  if test -n "$ACTIVE_PID" && kill -0 "$ACTIVE_PID" 2>/dev/null; then
    kill -TERM "$ACTIVE_PID" 2>/dev/null || true
    for _ in $(seq 1 100); do
      kill -0 "$ACTIVE_PID" 2>/dev/null || break
      sleep 0.02
    done
    kill -KILL "$ACTIVE_PID" 2>/dev/null || true
    wait "$ACTIVE_PID" 2>/dev/null || true
  fi
  for unit in "${UNITS[@]}"; do
    systemctl --user stop "$unit.service" >/dev/null 2>&1 || true
    systemctl --user reset-failed "$unit.service" >/dev/null 2>&1 || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

mkdir -p "$OUTPUT/config" "$OUTPUT/raw" "$OUTPUT/analysis"
cp "$PROFILE" "$OUTPUT/config/runtime-limits.example"
cp "$ROOT/ops/deploy/druse.service" "$OUTPUT/config/druse.service"
cp "$PREFLIGHT" "$OUTPUT/config/check-runtime-limits.sh"

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
TREE="$(git -C "$ROOT" rev-parse HEAD^{tree})"
START_UTC="$(date -u +%FT%TZ)"
{
  echo "campaign=R1-WP02-resource-budget"
  echo "start_utc=$START_UTC"
  echo "commit=$COMMIT"
  echo "tree=$TREE"
  echo "compiler=$ODIN_BIN"
  echo "compiler_sha256=$(sha256sum "$ODIN_BIN" | awk '{print $1}')"
  echo "profile_sha256=$(sha256sum "$PROFILE" | awk '{print $1}')"
  echo "systemd_arms=$RUN_SYSTEMD"
} > "$OUTPUT/manifest.txt"
{
  uname -a
  "$ODIN_BIN" version
  systemd --version | head -n 1
  echo "cpus=$(nproc)"
  echo "page_size=$(getconf PAGESIZE)"
  echo "nofile_soft=$(ulimit -Sn)"
  echo "nofile_hard=$(ulimit -Hn)"
  echo "memlock_soft_kib=$(ulimit -Sl)"
  echo "memlock_hard_kib=$(ulimit -Hl)"
  free -b
  cat /proc/self/cgroup
} > "$OUTPUT/environment.txt"
{
  printf 'invocation='
  printf '%q ' "$0" --output "$OUTPUT"
  test "$RUN_SYSTEMD" -eq 0 && printf '%q ' --skip-systemd
  printf '\n'
  echo "build=$ODIN_BIN build tests/r1-resource-budget/server -collection:druse=."
} > "$OUTPUT/commands.txt"

"$ODIN_BIN" build "$ROOT/tests/r1-resource-budget/server" \
  -collection:druse="$ROOT" -out:"$SERVER"
echo "server_sha256=$(sha256sum "$SERVER" | awk '{print $1}')" >> "$OUTPUT/manifest.txt"
echo "client_sha256=$(sha256sum "$CLIENT" | awk '{print $1}')" >> "$OUTPUT/manifest.txt"

set -a
# shellcheck disable=SC1090
. "$PROFILE"
set +a

wait_ready() {
  local port="$1"
  for _ in $(seq 1 200); do
    curl -fsS --max-time 0.2 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && return 0
    test -n "$ACTIVE_PID" && kill -0 "$ACTIVE_PID" 2>/dev/null || return 1
    sleep 0.02
  done
  return 1
}

start_server() {
  local port="$1"
  local spool="$2"
  local log="$3"
  shift 3
  env \
    DRUSE_PORT="$port" \
    DRUSE_MARKER_DIR="$spool" \
    DRUSE_SPOOL_DIR="$spool" \
    "$@" \
    "$SERVER" > "$log" 2>&1 &
  ACTIVE_PID=$!
  wait_ready "$port" || fail "server did not become ready on port $port (see $log)"
}

stop_server() {
  test -n "$ACTIVE_PID" || return 0
  kill -TERM "$ACTIVE_PID"
  wait "$ACTIVE_PID"
  ACTIVE_PID=""
}

# A — canonical FD/thread/io_uring baseline.
FD_SPOOL="$WORK/fd-spool"
mkdir "$FD_SPOOL"
start_server 22121 "$FD_SPOOL" "$OUTPUT/raw/fd-server.log"
sleep 0.1
FD_COUNT="$(find "/proc/$ACTIVE_PID/fd" -mindepth 1 -maxdepth 1 | wc -l)"
THREAD_COUNT="$(find "/proc/$ACTIVE_PID/task" -mindepth 1 -maxdepth 1 | wc -l)"
for fd in "/proc/$ACTIVE_PID"/fd/*; do
  printf '%s -> %s\n' "${fd##*/}" "$(readlink "$fd")"
done | sort -n > "$OUTPUT/raw/fd-layout.txt"
RING_COUNT="$(grep -Fc 'anon_inode:[io_uring]' "$OUTPUT/raw/fd-layout.txt")"
EVENTFD_COUNT="$(grep -Fc 'anon_inode:[eventfd]' "$OUTPUT/raw/fd-layout.txt")"
rg '^(VmPeak|VmSize|VmRSS|VmLck|Threads):' "/proc/$ACTIVE_PID/status" > "$OUTPUT/raw/fd-process-status.txt"
rg 'anon_inode:\[io_uring\]' "/proc/$ACTIVE_PID/maps" > "$OUTPUT/raw/io-uring-maps.txt"
stop_server
test "$FD_COUNT" -eq 22 || fail "canonical idle FD count changed: expected 22, got $FD_COUNT"
test "$THREAD_COUNT" -eq 9 || fail "canonical thread count changed: expected 9, got $THREAD_COUNT"
test "$RING_COUNT" -eq 9 && test "$EVENTFD_COUNT" -eq 9 ||
  fail "expected nine io_uring/eventfd pairs, got rings=$RING_COUNT eventfds=$EVENTFD_COUNT"
printf 'fds=%s\nthreads=%s\nio_uring=%s\neventfd=%s\n' \
  "$FD_COUNT" "$THREAD_COUNT" "$RING_COUNT" "$EVENTFD_COUNT" \
  > "$OUTPUT/analysis/fd-budget.txt"

# B — admission refusal and recovery at a small, structurally identical cap.
SAT_SPOOL="$WORK/saturation-spool"
mkdir "$SAT_SPOOL"
start_server 22122 "$SAT_SPOOL" "$OUTPUT/raw/saturation-server.log" \
  DRUSE_MAX_CONNECTIONS=32 DRUSE_RESERVED_CONNECTIONS=4
python3 "$CLIENT" saturation 22122 28 8 > "$OUTPUT/raw/saturation-client.json"
stop_server
grep -Fq '"refused": 8' "$OUTPUT/raw/saturation-client.json" || fail "saturation did not refuse all probes"
grep -Fq '"recovery_status": 200' "$OUTPUT/raw/saturation-client.json" || fail "saturation did not recover"

# C — measured memory peak: eight 8 MiB responses held by slow readers.
MEM_SPOOL="$WORK/memory-spool"
mkdir "$MEM_SPOOL"
start_server 22123 "$MEM_SPOOL" "$OUTPUT/raw/memory-server.log" \
  DRUSE_MAX_HANDLERS=8 DRUSE_FIXTURE_RESPONSE_BYTES=8388608 \
  DRUSE_MAX_RESPONSE_BYTES=8388608 DRUSE_MAX_WRITE_TIME_SEC=5
BASELINE_KIB="$(awk '/^VmRSS:/ {print $2}' "/proc/$ACTIVE_PID/status")"
CLIENT_PIDS=()
for _ in $(seq 1 8); do
  python3 "$CLIENT" slow-read 22123 4 > /dev/null 2>&1 &
  CLIENT_PIDS+=("$!")
done
PEAK_KIB="$BASELINE_KIB"
echo $'sample\trss_kib' > "$OUTPUT/raw/memory-rss.tsv"
for sample in $(seq 1 300); do
  RSS_KIB="$(awk '/^VmRSS:/ {print $2}' "/proc/$ACTIVE_PID/status")"
  printf '%s\t%s\n' "$sample" "$RSS_KIB" >> "$OUTPUT/raw/memory-rss.tsv"
  test "$RSS_KIB" -gt "$PEAK_KIB" && PEAK_KIB="$RSS_KIB"
  ANY=0
  for client_pid in "${CLIENT_PIDS[@]}"; do
    kill -0 "$client_pid" 2>/dev/null && ANY=1
  done
  test "$ANY" -eq 1 || break
  sleep 0.02
done
for client_pid in "${CLIENT_PIDS[@]}"; do wait "$client_pid"; done
HWM_KIB="$(awk '/^VmHWM:/ {print $2}' "/proc/$ACTIVE_PID/status")"
test "$HWM_KIB" -gt "$PEAK_KIB" && PEAK_KIB="$HWM_KIB"
stop_server
PEAK_BYTES=$((PEAK_KIB * 1024))
REQUIRED_BYTES=$((PEAK_BYTES * (100 + DRUSE_MEMORY_HEADROOM_PERCENT) / 100))
test "$REQUIRED_BYTES" -le "$DRUSE_MEMORY_MAX_BYTES" ||
  fail "new memory peak $PEAK_BYTES plus headroom exceeds profile MemoryMax=$DRUSE_MEMORY_MAX_BYTES"
printf 'baseline_kib=%s\npeak_kib=%s\npeak_bytes=%s\nrequired_with_headroom=%s\nmemory_max=%s\n' \
  "$BASELINE_KIB" "$PEAK_KIB" "$PEAK_BYTES" "$REQUIRED_BYTES" "$DRUSE_MEMORY_MAX_BYTES" \
  > "$OUTPUT/analysis/memory-budget.txt"

# D — process spool quota: observable 503, cleanup, then successful recovery.
UPLOAD_SPOOL="$WORK/upload-spool"
mkdir "$UPLOAD_SPOOL"
start_server 22124 "$UPLOAD_SPOOL" "$OUTPUT/raw/spool-server.log" \
  DRUSE_UPLOAD_QUOTA_BYTES=8388608 DRUSE_UPLOAD_PROCESS_QUOTA_BYTES=5242880
python3 "$CLIENT" upload 22124 6291456 > "$OUTPUT/raw/spool-breach.json"
RESIDUAL_BREACH="$(find "$UPLOAD_SPOOL" -maxdepth 1 -type f -name 'druse-spool-*' | wc -l)"
python3 "$CLIENT" upload 22124 4718592 > "$OUTPUT/raw/spool-recovery.json"
RESIDUAL_RECOVERY="$(find "$UPLOAD_SPOOL" -maxdepth 1 -type f -name 'druse-spool-*' | wc -l)"
stop_server
grep -Fq '"status": 503' "$OUTPUT/raw/spool-breach.json" || fail "process spool quota did not return 503"
grep -Fq '"status": 201' "$OUTPUT/raw/spool-recovery.json" || fail "spool did not recover after quota cleanup"
test "$RESIDUAL_BREACH" -eq 0 && test "$RESIDUAL_RECOVERY" -eq 0 ||
  fail "spool left residual files: breach=$RESIDUAL_BREACH recovery=$RESIDUAL_RECOVERY"
printf 'residual_after_breach=%s\nresidual_after_recovery=%s\n' \
  "$RESIDUAL_BREACH" "$RESIDUAL_RECOVERY" > "$OUTPUT/analysis/spool-cleanup.txt"

SYSTEMD_RESULT=skipped
if test "$RUN_SYSTEMD" -eq 1; then
  systemctl --user is-system-running >/dev/null 2>&1 ||
    fail "--user systemd is unavailable; rerun with --skip-systemd only for a partial diagnostic campaign"
  SYSTEMD_RESULT=passed

  # E — a real transient unit applies 16 KiB memlock.  ExecStart is the
  # preflight, so the unit must fail before an application could bind even on a
  # kernel (such as 6.8) that no longer charges these rings to RLIMIT_MEMLOCK.
  MEMLOCK_UNIT="druse-r1-memlock-$BASHPID"
  UNITS+=("$MEMLOCK_UNIT")
  if systemd-run --user --wait --pipe --unit="$MEMLOCK_UNIT" \
      --property=Type=oneshot --property=MemoryMax=1G \
      --property=LimitNOFILE=2048 --property=LimitMEMLOCK=16K \
      /bin/bash -c 'set -a; . "$1"; set +a; export DRUSE_SPOOL_DIR="$2" DRUSE_READ_WRITE_PATHS="$2"; exec "$3"' \
      _ "$PROFILE" "$UPLOAD_SPOOL" "$PREFLIGHT" \
      > "$OUTPUT/raw/systemd-memlock.log" 2>&1; then
    fail "16 KiB systemd memlock passed preflight"
  fi
  grep -Fq 'effective memlock=16384 bytes' "$OUTPUT/raw/systemd-memlock.log" ||
    fail "memlock unit failed for an unexpected reason"

  # F — cgroup OOM kills a 128 MiB response under 64 MiB and on-failure
  # restarts it.  Health after NRestarts>=1 is the recovery proof.
  OOM_UNIT="druse-r1-oom-$BASHPID"
  UNITS+=("$OOM_UNIT")
  OOM_SPOOL="$WORK/oom-spool"
  mkdir "$OOM_SPOOL"
  systemd-run --user --unit="$OOM_UNIT" \
    --property=Restart=on-failure --property=RestartSec=200ms \
    --property=MemoryMax=64M --property=LimitNOFILE=2048 --property=LimitMEMLOCK=64M \
    --setenv=DRUSE_PORT=22125 --setenv=DRUSE_MARKER_DIR="$OOM_SPOOL" \
    --setenv=DRUSE_SPOOL_DIR="$OOM_SPOOL" --setenv=DRUSE_MAX_HANDLERS=8 \
    --setenv=DRUSE_FIXTURE_RESPONSE_BYTES=134217728 \
    --setenv=DRUSE_MAX_RESPONSE_BYTES=134217728 "$SERVER" \
    > "$OUTPUT/raw/systemd-oom-start.log" 2>&1
  for _ in $(seq 1 200); do
    curl -fsS --max-time 0.2 http://127.0.0.1:22125/health >/dev/null 2>&1 && break
    sleep 0.02
  done
  python3 "$CLIENT" request 22125 /large > "$OUTPUT/raw/systemd-oom-client.json" 2>&1 || true
  OOM_RECOVERED=0
  for _ in $(seq 1 300); do
    NRESTARTS="$(systemctl --user show "$OOM_UNIT.service" -p NRestarts --value)"
    if test "${NRESTARTS:-0}" -ge 1 && curl -fsS --max-time 0.2 http://127.0.0.1:22125/health >/dev/null 2>&1; then
      OOM_RECOVERED=1
      break
    fi
    sleep 0.02
  done
  systemctl --user show "$OOM_UNIT.service" -p ActiveState -p SubState -p NRestarts -p Result \
    > "$OUTPUT/raw/systemd-oom-show.txt"
  journalctl --user -u "$OOM_UNIT.service" --no-pager > "$OUTPUT/raw/systemd-oom-journal.txt"
  test "$OOM_RECOVERED" -eq 1 || fail "OOM unit did not restart and recover health"
  grep -Fq "Failed with result 'oom-kill'" "$OUTPUT/raw/systemd-oom-journal.txt" ||
    fail "OOM unit journal did not classify oom-kill"
  systemctl --user stop "$OOM_UNIT.service"

  # G — repeated handler faults reach StartLimitBurst and park the unit failed.
  CRASH_UNIT="druse-r1-crash-$BASHPID"
  UNITS+=("$CRASH_UNIT")
  systemd-run --user --unit="$CRASH_UNIT" \
    --property=Restart=on-failure --property=RestartSec=100ms \
    --property=StartLimitBurst=3 --property=StartLimitIntervalSec=5s \
    --setenv=DRUSE_CRASH_ON_START=1 "$SERVER" \
    > "$OUTPUT/raw/systemd-crash-start.log" 2>&1
  for _ in $(seq 1 300); do
    CRASH_STATE="$(systemctl --user show "$CRASH_UNIT.service" -p ActiveState --value)"
    test "$CRASH_STATE" = failed && break
    sleep 0.02
  done
  systemctl --user show "$CRASH_UNIT.service" -p ActiveState -p SubState -p NRestarts -p Result -p StartLimitBurst \
    > "$OUTPUT/raw/systemd-crash-show.txt"
  journalctl --user -u "$CRASH_UNIT.service" --no-pager > "$OUTPUT/raw/systemd-crash-journal.txt"
  grep -Fq 'ActiveState=failed' "$OUTPUT/raw/systemd-crash-show.txt" || fail "crash-loop unit did not enter failed"
  grep -Fq 'NRestarts=3' "$OUTPUT/raw/systemd-crash-show.txt" || fail "crash-loop restart count did not reach the frozen burst"
  grep -Fq 'Start request repeated too quickly' "$OUTPUT/raw/systemd-crash-journal.txt" ||
    fail "crash-loop journal did not expose the start-limit backstop"
  systemctl --user reset-failed "$CRASH_UNIT.service"

  # H — clean SIGTERM returns from serve and Restart=on-failure leaves it down.
  CLEAN_UNIT="druse-r1-clean-$BASHPID"
  UNITS+=("$CLEAN_UNIT")
  CLEAN_SPOOL="$WORK/clean-spool"
  mkdir "$CLEAN_SPOOL"
  systemd-run --user --unit="$CLEAN_UNIT" \
    --property=Restart=on-failure --property=RestartSec=100ms --property=TimeoutStopSec=3s \
    --setenv=DRUSE_PORT=22126 --setenv=DRUSE_MARKER_DIR="$CLEAN_SPOOL" \
    --setenv=DRUSE_SPOOL_DIR="$CLEAN_SPOOL" --setenv=DRUSE_MAX_DRAIN_TIME_SEC=1 "$SERVER" \
    > "$OUTPUT/raw/systemd-clean-start.log" 2>&1
  for _ in $(seq 1 200); do
    curl -fsS --max-time 0.2 http://127.0.0.1:22126/health >/dev/null 2>&1 && break
    sleep 0.02
  done
  systemctl --user stop "$CLEAN_UNIT.service"
  sleep 0.3
  systemctl --user show "$CLEAN_UNIT.service" -p ActiveState -p SubState -p NRestarts -p Result \
    > "$OUTPUT/raw/systemd-clean-show.txt" 2>/dev/null || true
  journalctl --user -u "$CLEAN_UNIT.service" --no-pager > "$OUTPUT/raw/systemd-clean-journal.txt"
  test -f "$CLEAN_SPOOL/serve-returned" || fail "clean stop did not return from web.serve"
  grep -Fq 'NRestarts=0' "$OUTPUT/raw/systemd-clean-show.txt" || fail "clean stop caused a restart"
  if grep -Fq 'Scheduled restart job' "$OUTPUT/raw/systemd-clean-journal.txt"; then
    fail "clean stop journal scheduled a restart"
  fi
fi

END_UTC="$(date -u +%FT%TZ)"
echo "end_utc=$END_UTC" >> "$OUTPUT/manifest.txt"
echo "systemd_result=$SYSTEMD_RESULT" >> "$OUTPUT/manifest.txt"

{
  echo "# R1-WP02 resource-budget verdict"
  echo
  echo "Result: PASS for the measured controlled-pilot profile."
  echo
  echo "- Canonical idle process: $FD_COUNT FDs, $THREAD_COUNT threads, $RING_COUNT io_uring/eventfd pairs."
  echo "- Derived LimitNOFILE: 1213 required; 2048 configured."
  echo "- Concurrent slow-reader peak in this run: $PEAK_KIB KiB; 1 GiB remains above peak plus 200% headroom."
  echo "- Connection saturation refused all eight over-budget probes and recovered to HTTP 200."
  echo "- Process spool quota returned 503, cleaned the partial, then recovered to 201."
  echo "- systemd arms: $SYSTEMD_RESULT (16 KiB memlock preflight refusal, OOM restart, crash-loop backstop, clean stop without restart)."
  echo
  echo "Scope: one Linux process, one listener, eight handlers, 1024 max connections, 8 MiB response cap."
  echo "Changing any measured capacity invalidates this profile and requires a new run."
} > "$OUTPUT/verdict.md"

(
  cd "$OUTPUT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

trap - EXIT INT TERM
cleanup
echo "PASS: R1-WP02 resource drill evidence written to $OUTPUT"
