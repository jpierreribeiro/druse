#!/usr/bin/env bash
set -euo pipefail

BASE="${1:?usage: run-soak.sh BASE [HOURS]}"
HOURS="${2:-12}"
REPO="$BASE/repo"
HARNESS="${DRUSE_SOAK_HARNESS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
OUT="$BASE/soak"
ODIN_BIN="${DRUSE_ODIN_BIN:-/home/ubuntu/odin/odin}"
PORT="${DRUSE_SOAK_PORT:-8080}"
PHASE_SECONDS="${DRUSE_SOAK_PHASE_SECONDS:-120}"
MAX_RSS_KIB="${DRUSE_SOAK_MAX_RSS_KIB:-4194304}"
MAX_CYCLES="${DRUSE_SOAK_MAX_CYCLES:-0}"
HEALTH_RATE="${DRUSE_SOAK_HEALTH_RATE:-20}"
TINY_RATE="${DRUSE_SOAK_TINY_RATE:-10000}"
JSON_ENCODE_RATE="${DRUSE_SOAK_JSON_ENCODE_RATE:-1500}"
JSON_DECODE_RATE="${DRUSE_SOAK_JSON_DECODE_RATE:-4000}"
BYTES_64K_RATE="${DRUSE_SOAK_BYTES_64K_RATE:-150}"
WAIT_40MS_RATE="${DRUSE_SOAK_WAIT_40MS_RATE:-15}"
LAUNCH_STAGGER_SECONDS="${DRUSE_SOAK_LAUNCH_STAGGER_SECONDS:-1}"
FINAL_SETTLE_SECONDS="${DRUSE_SOAK_FINAL_SETTLE_SECONDS:-35}"
SAMPLE_SECONDS="${DRUSE_SOAK_SAMPLE_SECONDS:-1}"
LANES="${DRUSE_SOAK_LANES:-4}"
END_EPOCH=$(( $(date +%s) + HOURS * 3600 ))
mkdir -p "$OUT"/{bin,control,cycles,telemetry}

SERVER="$OUT/bin/server"
OPENLOAD="$OUT/bin/openload"
"$ODIN_BIN" build "$HARNESS/soak-server" \
  -collection:druse="$REPO" -o:speed -out:"$SERVER"
(cd "$HARNESS/openload" && go build -buildvcs=false -trimpath -o "$OPENLOAD" main.go)
sha256sum "$SERVER" "$OPENLOAD" >"$OUT/bin/SHA256SUMS"

ulimit -n 8192
server_pid=""
sampler_pid=""
cleanup() {
  if [[ -n "$sampler_pid" ]] && kill -0 "$sampler_pid" 2>/dev/null; then
    kill -TERM "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null || true
  fi
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
    for _ in $(seq 1 150); do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$server_pid" 2>/dev/null; then
      echo "forced_kill=1" >>"$OUT/control/final-state.txt"
      kill -KILL "$server_pid" 2>/dev/null || true
    fi
    wait "$server_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

taskset -c 0-3 "$SERVER" "$LANES" "$PORT" >"$OUT/server.log" 2>&1 &
server_pid=$!
echo "$server_pid" >"$OUT/control/server.pid"
for _ in $(seq 1 200); do
  curl -fsS --max-time 0.5 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 &&
    break
  kill -0 "$server_pid" 2>/dev/null || {
    echo "fatal: release-candidate server exited before readiness" >&2
    exit 2
  }
  sleep 0.1
done
curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null

{
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "git_head=$(git -C "$REPO" rev-parse HEAD)"
  echo "compiler=$("$ODIN_BIN" version 2>&1 | head -n 1)"
  echo "kernel=$(uname -srmo)"
  echo "hours=$HOURS"
  echo "phase_seconds=$PHASE_SECONDS"
  echo "sample_seconds=$SAMPLE_SECONDS"
  echo "lanes=$LANES"
  echo "max_cycles=$MAX_CYCLES"
  echo "health_rate=$HEALTH_RATE"
  echo "tiny_rate=$TINY_RATE"
  echo "json_encode_rate=$JSON_ENCODE_RATE"
  echo "json_decode_rate=$JSON_DECODE_RATE"
  echo "bytes_64k_rate=$BYTES_64K_RATE"
  echo "wait_40ms_rate=$WAIT_40MS_RATE"
  echo "launch_stagger_seconds=$LAUNCH_STAGGER_SECONDS"
  echo "final_settle_seconds=$FINAL_SETTLE_SECONDS"
  echo "server_cpus=0-3"
  echo "generator_cpus=4-7"
  echo "max_rss_kib=$MAX_RSS_KIB"
  echo "nofile=$(ulimit -Sn)"
  echo "server_sha256=$(sha256sum "$SERVER" | awk '{print $1}')"
  echo "openload_sha256=$(sha256sum "$OPENLOAD" | awk '{print $1}')"
} >"$OUT/manifest.txt"

(
  # unix_nanos joins this row to the generator's per-request CSV. Everything the
  # old telemetry recorded was relative to a start time it never printed, so no
  # server-side sample could be matched to a client-side failure.
  echo "sample,utc,unix_nanos,elapsed_s,rss_kib,hwm_kib,threads,fds,proc_ticks,host_ticks,stats_http,stats_curl_exit,listen_overflows,listen_drops,tcp_abort_on_close,tcp_retrans"
  sample=0
  started=$SECONDS
  while kill -0 "$server_pid" 2>/dev/null; do
    status="/proc/$server_pid/status"
    rss="$(awk '/^VmRSS:/ {print $2}' "$status" 2>/dev/null || echo 0)"
    hwm="$(awk '/^VmHWM:/ {print $2}' "$status" 2>/dev/null || echo 0)"
    threads="$(awk '/^Threads:/ {print $2}' "$status" 2>/dev/null || echo 0)"
    fds="$(find "/proc/$server_pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
    proc_ticks="$(awk '{print $14+$15}' "/proc/$server_pid/stat" 2>/dev/null || echo 0)"
    host_ticks="$(awk 'NR==1 {for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat)"
    stats_file="$OUT/telemetry/stats-$(printf '%06d' "$sample").json"
    # curl's exit code, not only its HTTP code. A /stats sample that fails
    # records `000` and nothing else, which is how a pre-registered criterion —
    # "/stats observed during load" — was measured for twelve hours with 111
    # failures whose cause was never captured. 7 is refused, 28 is timeout,
    # 52 is an empty reply, 56 is a receive failure: a taxonomy for free.
    stats_http="$(curl -sS --max-time 1 -o "$stats_file" -w '%{http_code}' \
      "http://127.0.0.1:$PORT/stats" 2>/dev/null)" || true
    stats_curl_exit=$?
    # Kernel counters. A request the kernel dropped before the server ever saw
    # it looks identical, from userspace, to a request the server refused —
    # these four numbers are what tells the two apart, and no previous run
    # recorded them.
    nstat_line="$(nstat -az 2>/dev/null | awk '
      /^TcpExtListenOverflows/ {o=$2}
      /^TcpExtListenDrops/     {d=$2}
      /^TcpExtTCPAbortOnClose/ {a=$2}
      /^TcpRetransSegs/        {r=$2}
      END {printf "%s,%s,%s,%s", (o?o:0), (d?d:0), (a?a:0), (r?r:0)}')"
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$sample" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%s%N)" \
      "$((SECONDS-started))" \
      "$rss" "$hwm" "$threads" "$fds" "$proc_ticks" "$host_ticks" \
      "${stats_http:-000}" "${stats_curl_exit:-0}" "${nstat_line:-0,0,0,0}"
    if [[ "${rss:-0}" -ge "$MAX_RSS_KIB" ]]; then
      echo "rss_safety_stop=$rss" >"$OUT/control/safety-stop.txt"
      kill -TERM "$server_pid" 2>/dev/null || true
      break
    fi
    sample=$((sample + 1))
    # One second, not five. A saturation refusal burst has a median of one
    # refusal, so a five-second window buries it in a bucket four seconds wider
    # than the event.
    sleep "$SAMPLE_SECONDS"
  done
) >"$OUT/telemetry/process.csv" &
sampler_pid=$!

run_load() {
  local cycle="$1" name="$2" path="$3" rate="$4" connections="$5"
  local method="${6:-GET}" payload="${7:-}"
  # Rate 0 means "this profile is not part of this run" — the saturation
  # experiment removes the blocking handler that way. The generator exits with
  # usage on a zero rate, which the orchestrator would otherwise record as a
  # failed load generator: an arm deliberately configured would be reported as
  # an arm that broke.
  if [[ "$rate" -le 0 ]]; then
    echo "skipped=$name reason=rate_zero" >>"$OUT/control/skipped.txt"
    LAST_PID=""
    return 0
  fi
  local args=(
    -url "http://127.0.0.1:$PORT$path"
    -method "$method"
    -rate "$rate"
    -duration "${PHASE_SECONDS}s"
    -connections "$connections"
    -timeout 5s
  )
  if [[ -n "$payload" ]]; then
    args+=(-payload "$payload")
  fi
  # -raw is not optional. The generator has always been able to write one line
  # per request and the orchestrator never asked for it, which is why a 12-hour
  # run could count 674 failures and locate none of them in time. The CSV is the
  # only artefact that can be joined against the /stats samples below.
  args+=(-raw "$OUT/cycles/c$(printf '%04d' "$cycle")-$name.csv")
  taskset -c 4-7 "$OPENLOAD" "${args[@]}" \
    >"$OUT/cycles/c$(printf '%04d' "$cycle")-$name.json" \
    2>"$OUT/cycles/c$(printf '%04d' "$cycle")-$name.err" &
  LAST_PID=$!
}

run_rst() {
  local cycle="$1"
  taskset -c 4-7 "$OPENLOAD" \
    -url "http://127.0.0.1:$PORT/bytes/64k" \
    -rst-count 128 -rst-delay 20ms -connections 16 \
    >"$OUT/cycles/c$(printf '%04d' "$cycle")-rst.json" \
    2>"$OUT/cycles/c$(printf '%04d' "$cycle")-rst.err" &
  LAST_PID=$!
}

run_slow_readers() {
  local cycle="$1"
  python3 - "$PORT" \
    >"$OUT/cycles/c$(printf '%04d' "$cycle")-slow-readers.txt" 2>&1 <<'PY' &
import socket
import sys
import time

port = int(sys.argv[1])
sockets = []
for _ in range(24):
    sock = socket.create_connection(("127.0.0.1", port), timeout=2)
    sock.sendall(
        b"GET /bytes/1m HTTP/1.1\r\n"
        b"Host: soak\r\nConnection: close\r\n\r\n"
    )
    sockets.append(sock)
time.sleep(8)
for sock in sockets:
    sock.close()
print(f"opened_and_closed={len(sockets)}")
PY
  LAST_PID=$!
}

cycle=0
echo "cycle,started_utc,ended_utc,health_status,health_transport_errors,health_p99_us,stats_http" \
  >"$OUT/cycles.csv"
while [[ "$(date +%s)" -lt "$END_EPOCH" ]]; do
  kill -0 "$server_pid" 2>/dev/null || {
    echo "server_died_cycle=$cycle" >"$OUT/control/server-died.txt"
    break
  }
  cycle=$((cycle + 1))
  started_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  pids=()
  run_load "$cycle" health /health "$HEALTH_RATE" 16
  pids+=("$LAST_PID")
  sleep "$LAUNCH_STAGGER_SECONDS"
  run_load "$cycle" tiny /tiny "$TINY_RATE" 128
  pids+=("$LAST_PID")
  sleep "$LAUNCH_STAGGER_SECONDS"
  run_load "$cycle" json-encode /json/medium "$JSON_ENCODE_RATE" 128
  pids+=("$LAST_PID")
  sleep "$LAUNCH_STAGGER_SECONDS"
  run_load "$cycle" json-decode /json/medium/decode "$JSON_DECODE_RATE" 256 POST medium-json
  pids+=("$LAST_PID")
  sleep "$LAUNCH_STAGGER_SECONDS"
  run_load "$cycle" bytes-64k /bytes/64k "$BYTES_64K_RATE" 64
  pids+=("$LAST_PID")
  sleep "$LAUNCH_STAGGER_SECONDS"
  run_load "$cycle" wait-40ms /wait/40ms "$WAIT_40MS_RATE" 32
  pids+=("$LAST_PID")
  if (( cycle % 5 == 0 )); then
    run_rst "$cycle"
    pids+=("$LAST_PID")
    run_slow_readers "$cycle"
    pids+=("$LAST_PID")
  fi
  for pid in "${pids[@]}"; do
    # A skipped profile contributes an empty entry, and `wait ""` fails — which
    # would record a load-generator error for a generator that was deliberately
    # never started.
    [[ -z "$pid" ]] && continue
    wait "$pid" || echo "cycle=$cycle child=$pid exit=$?" >>"$OUT/control/load-errors.txt"
  done

  health_file="$OUT/cycles/c$(printf '%04d' "$cycle")-health.json"
  health_status="$(jq -r '.status["200"] // 0' "$health_file")"
  health_errors="$(jq -r '.transport_errors' "$health_file")"
  health_p99="$(jq -r '.latency_p99_us' "$health_file")"
  stats_http="$(curl -sS --max-time 2 -o "$OUT/cycles/c$(printf '%04d' "$cycle")-stats.json" \
    -w '%{http_code}' "http://127.0.0.1:$PORT/stats" || true)"
  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$cycle" "$started_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$health_status" "$health_errors" "$health_p99" "${stats_http:-000}" \
    >>"$OUT/cycles.csv"
  if [[ "$health_errors" -ne 0 || "$health_p99" -gt 250000 ]]; then
    echo "cycle=$cycle health_errors=$health_errors health_p99_us=$health_p99" \
      >>"$OUT/control/health-violations.txt"
  fi
  if [[ "$MAX_CYCLES" -gt 0 && "$cycle" -ge "$MAX_CYCLES" ]]; then
    break
  fi
  sleep 5
done

sleep "$FINAL_SETTLE_SECONDS"
curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" \
  >"$OUT/control/final-health.body"
curl -fsS --max-time 2 "http://127.0.0.1:$PORT/stats" \
  >"$OUT/control/final-stats.json"
echo "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$OUT/manifest.txt"
echo "cycles=$cycle" >>"$OUT/manifest.txt"
kill -TERM "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
sampler_pid=""
kill -TERM "$server_pid" 2>/dev/null || true
for _ in $(seq 1 150); do
  kill -0 "$server_pid" 2>/dev/null || break
  sleep 0.1
done
forced_kill=0
if kill -0 "$server_pid" 2>/dev/null; then
  forced_kill=1
  kill -KILL "$server_pid" 2>/dev/null || true
fi
set +e
wait "$server_pid"
server_exit=$?
set -e
server_pid=""
{
  echo "forced_kill=$forced_kill"
  echo "server_exit=$server_exit"
} >>"$OUT/control/final-state.txt"

find "$OUT" -type f ! -name MANIFEST.sha256 -print0 | sort -z |
  xargs -0 sha256sum >"$OUT/MANIFEST.sha256"
touch "$OUT/COMPLETE"
