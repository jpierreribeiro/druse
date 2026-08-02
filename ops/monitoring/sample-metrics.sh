#!/usr/bin/env bash
#
# The out-of-band metric sampler: one line per tick, on stdout, forever.
#
# It reads FOUR sources and joins them on one timestamp, because the question an
# operator has under pressure — "is the application saturated or did the network
# eat my scrape?" — cannot be answered from any one of them:
#
#   1. the process snapshot   (ops/monitoring/snapshot-format.md)
#   2. the process itself     (/proc/PID: fds, RSS/HWM, threads)
#   3. the host's TCP counters(/proc/net/netstat, /proc/net/snmp)
#   4. the proxy upstream     (an optional stub_status URL)
#
# EVERY TICK EMITS A LINE. A tick that read nothing emits a line saying so, with
# a cause. That is the rule this whole work package exists for: a sampler that
# goes quiet is indistinguishable from a sampler whose subject went quiet, and
# INS-013 is what that costs — a twelve-hour artefact with no telemetry in it at
# all, graded PASS.
#
# It runs OUTSIDE the process it measures, so it survives that process dying —
# which is the one thing an in-process listener cannot do, and the reason a dead
# worker is reported as `no_process` here instead of as a failed scrape.
#
# Usage:
#   ops/monitoring/sample-metrics.sh SNAPSHOT_PATH [INTERVAL_SECONDS] [PROXY_STATUS_URL]
#
# Output is line-oriented `key=value`, one tick per line, and every line starts
# with `t=` and carries `cause=`.
set -uo pipefail

SNAPSHOT="${1:-}"
INTERVAL="${2:-1}"
PROXY_STATUS="${3:-}"

if test -z "$SNAPSHOT"; then
  echo "usage: $0 SNAPSHOT_PATH [INTERVAL_SECONDS] [PROXY_STATUS_URL]" >&2
  exit 2
fi

SCHEMA=1
# Four export periods. One missed tick is jitter; four is a stopped exporter.
# Expressed in seconds against the sampler's own interval so a slower sampler
# does not manufacture staleness it cannot observe.
MAX_AGE_S=$((INTERVAL * 4))
test "$MAX_AGE_S" -lt 1 && MAX_AGE_S=1

# --- the host's TCP refusal counters -----------------------------------------
#
# ListenDrops and ListenOverflows are the KERNEL's side of the same story
# `saturation_refusals` tells from the application's side, and they are the only
# way to see a connection the server never got to refuse. Absent counters are
# reported as -1 rather than 0: a missing counter and a counter reading zero are
# different facts, and printing 0 for both is how a host without them starts
# looking healthy.
host_counter() {
  local file="$1" key="$2"
  awk -v k="$key" '
    /^[A-Za-z]+:/ {
      if (hdr == "" || $1 != hdr) { hdr = $1; for (i = 2; i <= NF; i++) name[i] = $i; next }
      for (i = 2; i <= NF; i++) if (name[i] == k) { print $i; found = 1; exit }
    }
    END { if (!found) print -1 }
  ' "$file" 2>/dev/null || echo -1
}

snapshot_field() {
  local text="$1" key="$2"
  local line
  line="$(printf '%s\n' "$text" | grep -m1 "^${key} " || true)"
  if test -z "$line"; then
    echo -1
    return
  fi
  printf '%s\n' "${line#"${key} "}"
}

emit() {
  printf '%s\n' "$*"
}

while true; do
  now_s="$(date -u +%s)"
  now_ns="$((now_s * 1000000000))"
  iso="$(date -u -d "@$now_s" +%Y-%m-%dT%H:%M:%SZ)"

  cause=ok
  text=""
  if ! test -e "$SNAPSHOT"; then
    cause=missing
  elif ! text="$(cat "$SNAPSHOT" 2>/dev/null)"; then
    cause=unreadable
  elif ! printf '%s\n' "$text" | head -n1 | grep -q "^druse_snapshot ${SCHEMA}$"; then
    # A different schema version is MALFORMED to this sampler, not something to
    # parse optimistically. A writer from another build is a deployment fault and
    # must read as one.
    cause=malformed
  elif ! printf '%s\n' "$text" | tail -n1 | grep -q '^end$'; then
    cause=malformed
  fi

  pid=-1
  age_ns=-1
  if test "$cause" = ok; then
    stamp="$(snapshot_field "$text" unix_ns)"
    pid="$(snapshot_field "$text" pid)"
    if test "$stamp" = -1; then
      cause=malformed
    else
      age_ns=$((now_ns - stamp))
      if test "$age_ns" -gt $((MAX_AGE_S * 1000000000)); then
        cause=stale
      fi
    fi
  fi

  # A stale record whose pid is gone is not "stale", it is a DEAD PROCESS, and
  # the distinction is the difference between paging someone and waiting a tick.
  # This is the check an in-process listener structurally cannot make: it would
  # have died with the process it was reporting on.
  if test "$cause" = stale && test "$pid" != -1 && ! test -d "/proc/$pid"; then
    cause=no_process
  fi

  fds=-1
  rss_kb=-1
  hwm_kb=-1
  threads=-1
  if test "$pid" != -1 && test -d "/proc/$pid"; then
    fds="$(ls -1 "/proc/$pid/fd" 2>/dev/null | wc -l)"
    rss_kb="$(awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo -1)"
    hwm_kb="$(awk '/^VmHWM:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo -1)"
    threads="$(awk '/^Threads:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo -1)"
  fi
  : "${rss_kb:=-1}" "${hwm_kb:=-1}" "${threads:=-1}"

  listen_drops="$(host_counter /proc/net/netstat ListenDrops)"
  listen_overflows="$(host_counter /proc/net/netstat ListenOverflows)"
  retrans="$(host_counter /proc/net/snmp RetransSegs)"

  # Restart count from the supervisor, when there is one. `NRestarts` is the only
  # number that puts a restart on the timeline: the process counters reset, and a
  # counter that went back to zero looks exactly like a quiet period.
  restarts=-1
  if test -n "${DRUSE_UNIT:-}" && command -v systemctl >/dev/null 2>&1; then
    restarts="$(systemctl show -p NRestarts --value "$DRUSE_UNIT" 2>/dev/null || echo -1)"
    : "${restarts:=-1}"
  fi

  proxy_active=-1
  proxy_connect_errors=-1
  proxy_retries=-1
  if test -n "$PROXY_STATUS" && command -v curl >/dev/null 2>&1; then
    # `|| true` would swallow the status the way AUD-P1-003 did; capture it.
    if proxy_body="$(curl -fsS --max-time 2 "$PROXY_STATUS" 2>/dev/null)"; then
      proxy_active="$(printf '%s\n' "$proxy_body" | awk '/^Active connections:/{print $3}')"
      proxy_connect_errors="$(printf '%s\n' "$proxy_body" | awk '/^druse_upstream_connect_errors/{print $2}')"
      proxy_retries="$(printf '%s\n' "$proxy_body" | awk '/^druse_upstream_retries/{print $2}')"
    fi
    : "${proxy_active:=-1}" "${proxy_connect_errors:=-1}" "${proxy_retries:=-1}"
  fi

  line="t=$iso cause=$cause pid=$pid age_ns=$age_ns"
  if test "$cause" = ok; then
    for key in draining refused_connections saturation_refusals responses_sent \
               response_bytes send_errors write_deadline_aborts handler_dwell_ns \
               stream_refused_full stream_refused_budget stream_aborted_slow \
               active_connections handlers_active handler_capacity \
               connection_capacity; do
      line="$line $key=$(snapshot_field "$text" "$key")"
    done
  fi
  line="$line fds=$fds rss_kb=$rss_kb hwm_kb=$hwm_kb threads=$threads restarts=$restarts"
  line="$line listen_drops=$listen_drops listen_overflows=$listen_overflows retrans_segs=$retrans"
  line="$line proxy_active=$proxy_active proxy_connect_errors=$proxy_connect_errors proxy_retries=$proxy_retries"
  emit "$line"

  sleep "$INTERVAL"
done
