#!/usr/bin/env bash
# R1-WP02 runtime preflight.  It runs as ExecStartPre, after systemd has applied
# the service's rlimits/cgroup and created StateDirectory, but before any socket
# can bind.  It prints only configuration/accounting facts, never request data.

set -euo pipefail

fail() {
  echo "ERROR: druse runtime preflight: $*" >&2
  exit 1
}

usage() {
  echo "usage: $0 [--profile PATH] [--explain]" >&2
  exit 2
}

PROFILE=""
EXPLAIN=0
while test "$#" -gt 0; do
  case "$1" in
    --profile)
      test "$#" -ge 2 || usage
      PROFILE="$2"
      shift 2
      ;;
    --explain)
      EXPLAIN=1
      shift
      ;;
    *) usage ;;
  esac
done

# `source` is intentional: runtime-limits.example is constrained to the common
# KEY=value subset accepted by systemd EnvironmentFile and by the shell.  The
# deployed ExecStartPre normally receives these values from systemd and does
# not parse a second format; --profile is the local/operator diagnostic path.
if test -n "$PROFILE"; then
  test -r "$PROFILE" || fail "profile is not readable: $PROFILE"
  set -a
  # shellcheck disable=SC1090
  . "$PROFILE"
  set +a
fi

REQUIRED_VARS=(
  DRUSE_PROFILE DRUSE_LIMITS_SOURCE DRUSE_SERVER_COUNT
  DRUSE_MAX_CONNECTIONS DRUSE_RESERVED_CONNECTIONS DRUSE_MAX_HANDLERS
  DRUSE_MAX_RESPONSE_BYTES DRUSE_MAX_DRAIN_TIME_SEC
  DRUSE_SPOOL_DIR DRUSE_MAX_CONCURRENT_SPOOLS DRUSE_READ_WRITE_PATHS
  DRUSE_AUXILIARY_FDS DRUSE_FD_MARGIN DRUSE_EXPECTED_NOFILE
  DRUSE_IO_URING_MAPPED_BYTES_PER_LOOP DRUSE_MEMLOCK_FLOOR_BYTES
  DRUSE_MEASURED_PEAK_SERVER_COUNT DRUSE_MEASURED_PEAK_HANDLERS
  DRUSE_MEASURED_PEAK_RESPONSE_BYTES DRUSE_MEASURED_PEAK_RSS_BYTES
  DRUSE_MEMORY_HEADROOM_PERCENT DRUSE_MEMORY_MAX_BYTES
  DRUSE_TIMEOUT_STOP_SEC
)
for name in "${REQUIRED_VARS[@]}"; do
  test -n "${!name:-}" || fail "$name is unset; refusing inherited/default production limits"
done

test "$DRUSE_PROFILE" = controlled-pilot ||
  fail "unsupported DRUSE_PROFILE=$DRUSE_PROFILE (expected controlled-pilot)"
test "$DRUSE_LIMITS_SOURCE" = systemd ||
  fail "DRUSE_LIMITS_SOURCE must be systemd; critical limits may not remain inherited"

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
for name in "${REQUIRED_VARS[@]}"; do
  case "$name" in
    DRUSE_PROFILE|DRUSE_LIMITS_SOURCE|DRUSE_SPOOL_DIR|DRUSE_READ_WRITE_PATHS) continue ;;
  esac
  is_uint "${!name}" || fail "$name must be an unsigned base-10 integer, got '${!name}'"
done

test "$DRUSE_SERVER_COUNT" -ge 1 || fail "DRUSE_SERVER_COUNT must be at least 1"
test "$DRUSE_MAX_HANDLERS" -ge 1 && test "$DRUSE_MAX_HANDLERS" -le 256 ||
  fail "DRUSE_MAX_HANDLERS must be explicit and in 1..256 (automatic 0 cannot be budgeted)"
test "$DRUSE_MAX_CONNECTIONS" -gt "$DRUSE_RESERVED_CONNECTIONS" ||
  fail "DRUSE_MAX_CONNECTIONS must exceed DRUSE_RESERVED_CONNECTIONS"
test "$DRUSE_MAX_RESPONSE_BYTES" -gt 0 ||
  fail "DRUSE_MAX_RESPONSE_BYTES must be explicit for the controlled pilot"
test "$DRUSE_MAX_DRAIN_TIME_SEC" -gt 0 ||
  fail "DRUSE_MAX_DRAIN_TIME_SEC must be greater than zero"
test "$DRUSE_TIMEOUT_STOP_SEC" -gt "$DRUSE_MAX_DRAIN_TIME_SEC" ||
  fail "DRUSE_TIMEOUT_STOP_SEC=$DRUSE_TIMEOUT_STOP_SEC must be greater than DRUSE_MAX_DRAIN_TIME_SEC=$DRUSE_MAX_DRAIN_TIME_SEC"

# Refuse extrapolation from the preserved memory experiment.  Smaller values
# are conservative; a larger server count, handler count or response cap needs
# a new measurement and a new frozen peak.
test "$DRUSE_SERVER_COUNT" -le "$DRUSE_MEASURED_PEAK_SERVER_COUNT" ||
  fail "server count exceeds the measured memory profile; remeasure before deployment"
test "$DRUSE_MAX_HANDLERS" -le "$DRUSE_MEASURED_PEAK_HANDLERS" ||
  fail "handler count exceeds the measured memory profile; remeasure before deployment"
test "$DRUSE_MAX_RESPONSE_BYTES" -le "$DRUSE_MEASURED_PEAK_RESPONSE_BYTES" ||
  fail "response cap exceeds the measured memory profile; remeasure before deployment"

# 3 stdio descriptors, then one listener plus one io_uring FD and one eventfd
# for every handler lane and the dedicated acceptor.  Connections and live
# spool files are counted per server.  Auxiliary FDs name logs/telemetry/app
# needs; the final margin is deliberately separate and visible.
RUNTIME_FDS=$((3 + DRUSE_SERVER_COUNT * (1 + 2 * (DRUSE_MAX_HANDLERS + 1))))
REQUIRED_NOFILE=$((
  DRUSE_SERVER_COUNT * DRUSE_MAX_CONNECTIONS +
  RUNTIME_FDS +
  DRUSE_SERVER_COUNT * DRUSE_MAX_CONCURRENT_SPOOLS +
  DRUSE_AUXILIARY_FDS +
  DRUSE_FD_MARGIN
))
test "$DRUSE_EXPECTED_NOFILE" -ge "$REQUIRED_NOFILE" ||
  fail "profile LimitNOFILE=$DRUSE_EXPECTED_NOFILE is below derived requirement $REQUIRED_NOFILE"

ACTUAL_NOFILE="${DRUSE_PREFLIGHT_NOFILE:-$(ulimit -Sn)}"
if test "$ACTUAL_NOFILE" != unlimited; then
  is_uint "$ACTUAL_NOFILE" || fail "could not parse effective soft nofile '$ACTUAL_NOFILE'"
  test "$ACTUAL_NOFILE" -ge "$DRUSE_EXPECTED_NOFILE" ||
    fail "effective soft nofile=$ACTUAL_NOFILE is below profile $DRUSE_EXPECTED_NOFILE (derived minimum $REQUIRED_NOFILE)"
fi

LOOPS=$((DRUSE_SERVER_COUNT * (DRUSE_MAX_HANDLERS + 1)))
MAPPED_RING_BYTES=$((LOOPS * DRUSE_IO_URING_MAPPED_BYTES_PER_LOOP))
REQUIRED_MEMLOCK=$DRUSE_MEMLOCK_FLOOR_BYTES
test "$MAPPED_RING_BYTES" -le "$REQUIRED_MEMLOCK" || REQUIRED_MEMLOCK=$MAPPED_RING_BYTES

if test -n "${DRUSE_PREFLIGHT_MEMLOCK_BYTES:-}"; then
  ACTUAL_MEMLOCK_BYTES="$DRUSE_PREFLIGHT_MEMLOCK_BYTES"
else
  MEMLOCK_TOKEN="$(awk '$1 == "Max" && $2 == "locked" && $3 == "memory" { print $4; exit }' /proc/self/limits)"
  test -n "$MEMLOCK_TOKEN" || fail "could not read effective memlock from /proc/self/limits"
  if test "$MEMLOCK_TOKEN" = unlimited; then
    ACTUAL_MEMLOCK_BYTES=unlimited
  else
    is_uint "$MEMLOCK_TOKEN" || fail "could not parse effective memlock '$MEMLOCK_TOKEN'"
    ACTUAL_MEMLOCK_BYTES="$MEMLOCK_TOKEN"
  fi
fi
if test "$ACTUAL_MEMLOCK_BYTES" != unlimited; then
  test "$ACTUAL_MEMLOCK_BYTES" -ge "$REQUIRED_MEMLOCK" ||
    fail "effective memlock=$ACTUAL_MEMLOCK_BYTES bytes is below derived/floor requirement $REQUIRED_MEMLOCK for $LOOPS event loops"
fi

test -d "$DRUSE_SPOOL_DIR" || fail "spool directory does not exist: $DRUSE_SPOOL_DIR"
test -w "$DRUSE_SPOOL_DIR" || fail "spool directory is not writable by the service user: $DRUSE_SPOOL_DIR"
SPOOL_REAL="$(realpath -e "$DRUSE_SPOOL_DIR")" || fail "cannot resolve spool directory: $DRUSE_SPOOL_DIR"
SPOOL_ALLOWED=0
IFS=: read -r -a WRITE_PATHS <<< "$DRUSE_READ_WRITE_PATHS"
for path in "${WRITE_PATHS[@]}"; do
  test -n "$path" || continue
  ALLOWED_REAL="$(realpath -e "$path")" || fail "ReadWritePaths entry does not exist: $path"
  if test "$SPOOL_REAL" = "$ALLOWED_REAL" || [[ "$SPOOL_REAL" == "$ALLOWED_REAL/"* ]]; then
    SPOOL_ALLOWED=1
    break
  fi
done
test "$SPOOL_ALLOWED" -eq 1 ||
  fail "spool directory $SPOOL_REAL is outside DRUSE_READ_WRITE_PATHS=$DRUSE_READ_WRITE_PATHS"

REQUIRED_MEMORY=$((
  DRUSE_MEASURED_PEAK_RSS_BYTES * (100 + DRUSE_MEMORY_HEADROOM_PERCENT) / 100
))
test "$DRUSE_MEMORY_MAX_BYTES" -ge "$REQUIRED_MEMORY" ||
  fail "MemoryMax profile $DRUSE_MEMORY_MAX_BYTES is below measured peak plus headroom $REQUIRED_MEMORY"

if test -n "${DRUSE_PREFLIGHT_MEMORY_MAX_FILE:-}"; then
  MEMORY_MAX_FILE="$DRUSE_PREFLIGHT_MEMORY_MAX_FILE"
else
  CGROUP_PATH="$(awk -F: '$1 == "0" { print $3; exit }' /proc/self/cgroup)"
  MEMORY_MAX_FILE="/sys/fs/cgroup${CGROUP_PATH}/memory.max"
fi
test -r "$MEMORY_MAX_FILE" ||
  fail "effective cgroup memory.max is unavailable ($MEMORY_MAX_FILE); MemoryMax must not be inherited or absent"
ACTUAL_MEMORY_MAX="$(tr -d '[:space:]' < "$MEMORY_MAX_FILE")"
test "$ACTUAL_MEMORY_MAX" != max ||
  fail "effective cgroup memory.max is unlimited; MemoryMax is absent"
is_uint "$ACTUAL_MEMORY_MAX" || fail "could not parse cgroup memory.max '$ACTUAL_MEMORY_MAX'"
test "$ACTUAL_MEMORY_MAX" -eq "$DRUSE_MEMORY_MAX_BYTES" ||
  fail "effective cgroup memory.max=$ACTUAL_MEMORY_MAX does not equal profile DRUSE_MEMORY_MAX_BYTES=$DRUSE_MEMORY_MAX_BYTES"

echo "PASS: druse runtime preflight profile=$DRUSE_PROFILE servers=$DRUSE_SERVER_COUNT handlers=$DRUSE_MAX_HANDLERS nofile=$ACTUAL_NOFILE/$REQUIRED_NOFILE memlock=$ACTUAL_MEMLOCK_BYTES/$REQUIRED_MEMLOCK memory.max=$ACTUAL_MEMORY_MAX/$REQUIRED_MEMORY spool=$SPOOL_REAL"
if test "$EXPLAIN" -eq 1; then
  echo "FD formula: connections=$((DRUSE_SERVER_COUNT * DRUSE_MAX_CONNECTIONS)) runtime=$RUNTIME_FDS spools=$((DRUSE_SERVER_COUNT * DRUSE_MAX_CONCURRENT_SPOOLS)) auxiliary=$DRUSE_AUXILIARY_FDS margin=$DRUSE_FD_MARGIN total=$REQUIRED_NOFILE"
  echo "Memory evidence: peak=$DRUSE_MEASURED_PEAK_RSS_BYTES headroom=${DRUSE_MEMORY_HEADROOM_PERCENT}% required=$REQUIRED_MEMORY cap=$DRUSE_MEMORY_MAX_BYTES"
  echo "io_uring evidence: loops=$LOOPS mapped=$MAPPED_RING_BYTES floor=$DRUSE_MEMLOCK_FLOOR_BYTES required=$REQUIRED_MEMLOCK"
fi
