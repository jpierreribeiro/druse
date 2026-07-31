#!/usr/bin/env bash
# Campaign D load generator. Run on the SECOND instance, against the server's
# PRIVATE ip, so the NIC path is real rather than loopback.
#
#   soak-load.sh <server-ip> [hours]
#
# Mixes the four shapes that matter, because a uniform workload cannot see what
# this soak exists to measure:
#   - keep-alive steady traffic
#   - connection churn (Connection: close)
#   - MIXED RESPONSE SIZES  <- the one that exposes per-connection retention
#   - slow readers and RST bursts
set -euo pipefail
SERVER="${1:?usage: soak-load.sh <server-ip> [hours]}"
HOURS="${2:-12}"
PORT="${URUQUIM_SOAK_PORT:-8080}"
END=$(( $(date +%s) + HOURS * 3600 ))

command -v wrk >/dev/null || { echo "wrk is required on the load box" >&2; exit 2; }

while test "$(date +%s)" -lt "$END"; do
  # 1. keep-alive steady state, small responses
  timeout 300 wrk -t4 -c100 -d300s --latency "http://$SERVER:$PORT/health" || true
  # 2. large responses — grows each connection's retained buffer
  timeout 120 wrk -t4 -c50 -d120s --latency "http://$SERVER:$PORT/json/medium" || true
  # 3. connection churn: a fresh connection per request
  timeout 120 wrk -t4 -c100 -d120s -H "Connection: close" "http://$SERVER:$PORT/health" || true
  # 4. RST burst: connect and abort without reading
  for _ in $(seq 1 2000); do
    timeout 1 bash -c "exec 3<>/dev/tcp/$SERVER/$PORT; printf 'GET /health HTTP/1.1\r\nHost: x\r\n\r\n' >&3; exec 3<&-" 2>/dev/null || true
  done
  # 5. slow readers: open, request, read nothing, hold
  for _ in $(seq 1 50); do
    ( timeout 30 bash -c "exec 3<>/dev/tcp/$SERVER/$PORT; printf 'GET /json/medium HTTP/1.1\r\nHost: x\r\n\r\n' >&3; sleep 30" 2>/dev/null || true ) &
  done
  wait
done
echo "load phase complete"
