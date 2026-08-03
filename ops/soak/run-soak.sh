#!/usr/bin/env bash
set -euo pipefail

# Produces a soak artefact conforming to ops/soak/schema.md, version soak/1.
# The schema is a document because R2-WP01 found this script and
# analyze-soak.py disagreeing in silence for the whole life of the harness:
# this script recorded kernel counters and a /stats curl exit the analyser never
# read, and the analyser read a control/final-state.txt this script did not
# always write.

SCHEMA_VERSION="soak/1"

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
SERVER_CPUS="${DRUSE_SOAK_SERVER_CPUS:-0-3}"
GENERATOR_CPUS="${DRUSE_SOAK_GENERATOR_CPUS:-4-7}"
END_EPOCH=$(( $(date +%s) + HOURS * 3600 ))

# ADR-050's out-of-band metric channel. The server writes a snapshot from a
# thread that owns no Handler lane; the sampler reads the file. Empty disables
# it, which is refused by the analyser rather than tolerated.
SNAPSHOT_PATH="${DRUSE_SOAK_SNAPSHOT_PATH:-$OUT/control/snapshot.txt}"
SNAPSHOT_MAX_AGE_SECONDS="${DRUSE_SOAK_SNAPSHOT_MAX_AGE_SECONDS:-5}"
# The closed absence taxonomy of ADR-050, carried in the second telemetry field.
# Numbers, not names, because the column is `soak/1`'s integer `stats_curl_exit`
# and the artefact schema is not being broken to add a word. They are far from
# curl's 0-99 so an artefact from either era reads unambiguously.
SNAPSHOT_CAUSE_MISSING=101     # the path does not exist
SNAPSHOT_CAUSE_UNREADABLE=102  # it exists and could not be read
SNAPSHOT_CAUSE_MALFORMED=103   # wrong schema line, or no timestamp
SNAPSHOT_CAUSE_STALE=104       # readable, and older than max_age
SNAPSHOT_CAUSE_NO_PROCESS=105  # the server named by the run is gone
SNAPSHOT_CAUSE_DISABLED=106    # no snapshot path configured at all
mkdir -p "$OUT"/{bin,control,cycles,telemetry}

SERVER="$OUT/bin/server"
OPENLOAD="$OUT/bin/openload"

# ---------------------------------------------------------------------------
# FINAL STATE IS WRITTEN ON EVERY EXIT PATH.
#
# The analyser reads control/final-state.txt to learn how the run ended. The
# previous edition of this script wrote it only on the happy path, so the
# artefact a bad night actually produces — orchestrator dead, server gone,
# nothing recorded — made the analyser raise FileNotFoundError instead of
# returning a verdict. The run with the most to say produced no grade at all.
# ---------------------------------------------------------------------------
FINAL_STATE_WRITTEN=0
ABORT_REASON=""
record_final_state() { # forced_kill server_exit sampler_exit
  [[ "$FINAL_STATE_WRITTEN" == 1 ]] && return 0
  FINAL_STATE_WRITTEN=1
  {
    echo "forced_kill=${1:-1}"
    echo "server_exit=${2:--1}"
    echo "sampler_exit=${3:--1}"
    if [[ -n "$ABORT_REASON" ]]; then
      echo "abort_reason=$ABORT_REASON"
    fi
  } >"$OUT/control/final-state.txt"
}

on_err() {
  if [[ -z "$ABORT_REASON" ]]; then
    ABORT_REASON="orchestrator failed at ${BASH_SOURCE[0]}:$1 with exit $2"
  fi
}
trap 'on_err "$LINENO" "$?"' ERR

server_pid=""
sampler_pid=""
cleanup() {
  local sampler_exit=-1 server_exit=-1 forced=0
  if [[ -n "$sampler_pid" ]] && kill -0 "$sampler_pid" 2>/dev/null; then
    kill -TERM "$sampler_pid" 2>/dev/null || true
    wait "$sampler_pid" 2>/dev/null && sampler_exit=0 || sampler_exit=$?
  fi
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
    for _ in $(seq 1 150); do
      kill -0 "$server_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$server_pid" 2>/dev/null; then
      forced=1
      kill -KILL "$server_pid" 2>/dev/null || true
    fi
    wait "$server_pid" 2>/dev/null && server_exit=0 || server_exit=$?
  fi
  if [[ -z "$ABORT_REASON" && "$FINAL_STATE_WRITTEN" == 0 ]]; then
    ABORT_REASON="the orchestrator exited without recording a final state"
  fi
  record_final_state "$forced" "$server_exit" "$sampler_exit"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# HOST QUALIFICATION BEFORE ANYTHING IS BUILT.
#
# This script pins the server to $SERVER_CPUS and the generators to
# $GENERATOR_CPUS. On a host without those CPUs, `taskset` fails and the failure
# arrives as "release-candidate server exited before readiness" — a sentence
# about the product, produced by a host that could never have run the
# measurement. R2 rule G2: an instrument failure fails the CAMPAIGN, visibly.
# ---------------------------------------------------------------------------
preflight_state="absent"
if [[ "${DRUSE_SOAK_SKIP_PREFLIGHT:-0}" == "1" ]]; then
  preflight_state="skipped"
  echo "warning: preflight skipped by DRUSE_SOAK_SKIP_PREFLIGHT=1" >&2
elif [[ -x "$HARNESS/preflight.sh" || -f "$HARNESS/preflight.sh" ]]; then
  if env DRUSE_SOAK_SERVER_CPUS="$SERVER_CPUS" \
         DRUSE_SOAK_GENERATOR_CPUS="$GENERATOR_CPUS" \
         DRUSE_SOAK_PORT="$PORT" DRUSE_SOAK_BASE="$BASE" \
         DRUSE_SOAK_PREFLIGHT_HOURS="$HOURS" \
         DRUSE_SOAK_SAMPLE_SECONDS="$SAMPLE_SECONDS" \
         DRUSE_SOAK_MAX_RSS_KIB="$MAX_RSS_KIB" \
         bash "$HARNESS/preflight.sh" "$OUT/control/preflight.txt"; then
    preflight_state="pass"
  else
    ABORT_REASON="preflight refused this host; see control/preflight.txt"
    echo "fatal: $ABORT_REASON" >&2
    exit 3
  fi
fi

# ---------------------------------------------------------------------------
# CANDIDATE IDENTITY (readiness rule G1). A dirty tree measures something no
# commit names. It is allowed only under an explicit variable, and the variable
# is RECORDED, so a diagnostic run can never be presented later as evidence.
# ---------------------------------------------------------------------------
git_head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
git_tree="$(git -C "$REPO" rev-parse 'HEAD^{tree}' 2>/dev/null || echo unknown)"
if git -C "$REPO" diff --quiet HEAD 2>/dev/null &&
   test -z "$(git -C "$REPO" status --porcelain 2>/dev/null)"; then
  git_dirty=0
else
  git_dirty=1
fi
allow_dirty="${DRUSE_SOAK_ALLOW_DIRTY:-0}"
if [[ "$git_dirty" == 1 && "$allow_dirty" != "1" ]]; then
  ABORT_REASON="the working tree at $REPO is dirty; set DRUSE_SOAK_ALLOW_DIRTY=1 to take a diagnostic run"
  echo "fatal: $ABORT_REASON" >&2
  exit 4
fi
harness_head="$(git -C "$HARNESS" rev-parse HEAD 2>/dev/null || echo unknown)"

"$ODIN_BIN" build "$HARNESS/soak-server" \
  -collection:druse="$REPO" -o:speed -out:"$SERVER"
(cd "$HARNESS/openload" && go build -buildvcs=false -trimpath -o "$OPENLOAD" main.go)
sha256sum "$SERVER" "$OPENLOAD" >"$OUT/bin/SHA256SUMS"
server_sha256="$(sha256sum "$SERVER" | awk '{print $1}')"
openload_sha256="$(sha256sum "$OPENLOAD" | awk '{print $1}')"

# The hard limit may be below this; preflight refuses such a host, and a run
# taken with the preflight skipped must not die here for an unrelated reason.
ulimit -n 8192 2>/dev/null || echo "nofile_raise_failed=1" >>"$OUT/control/notes.txt"

# argv[3] is the snapshot path, and passing it is what turns ADR-050's exporter
# on. It was optional in the soak server and this runner never supplied it, so
# the out-of-band channel R2-WP03 shipped had never once run during a campaign.
taskset -c "$SERVER_CPUS" "$SERVER" "$LANES" "$PORT" "$SNAPSHOT_PATH" \
  >"$OUT/server.log" 2>&1 &
server_pid=$!
echo "$server_pid" >"$OUT/control/server.pid"
for _ in $(seq 1 200); do
  # READY MEANS BOTH CHANNELS, not just the request path. The exporter writes
  # its first snapshot on its own schedule, so a sampler started the instant
  # /health answers takes its first sample against a file that does not exist
  # yet and records `missing` for a server that is perfectly healthy. R2-WP04's
  # second smoke did exactly that: 1 of 656 samples, cause 101, entirely an
  # artefact of the start-up race.
  curl -fsS --max-time 0.5 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 &&
    { [[ -z "$SNAPSHOT_PATH" ]] || [[ -s "$SNAPSHOT_PATH" ]]; } &&
    break
  kill -0 "$server_pid" 2>/dev/null || {
    ABORT_REASON="release-candidate server exited before readiness"
    echo "fatal: $ABORT_REASON" >&2
    exit 2
  }
  sleep 0.1
done
curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null

# nstat's ABSENCE IS RECORDED, and it is recorded because its absence used to
# kill the sampler outright. The kernel-counter line is a pipeline, this script
# runs under `set -o pipefail`, and a missing `nstat` therefore returned 127
# from that pipeline and took the sampler's whole subshell with it on the first
# iteration. The telemetry file was left holding a header and nothing else — and
# under the old analyser that graded PASS, because every rule computed from the
# tail applied only to files long enough to have one. The first end-to-end run
# of the repaired instrument reproduced this on a host with no nstat.
#
# A tool the campaign needs and the host does not have is a fact about the
# campaign. It is not a reason to stop sampling, and it is not something to
# paper over with zeros either: a zero in these columns reads as "no drops",
# which is the single thing they exist to distinguish. So it is recorded, the
# sampler carries on, and the analyser refuses to grade criterion 13 in silence.
if command -v nstat >/dev/null 2>&1; then
  have_nstat=present
else
  have_nstat=absent
  echo "nstat_absent=1" >>"$OUT/control/notes.txt"
  echo "warning: nstat is not installed; kernel drop counters will not be collected" >&2
fi

{
  echo "schema_version=$SCHEMA_VERSION"
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "git_head=$git_head"
  echo "git_tree=$git_tree"
  echo "git_dirty=$git_dirty"
  echo "allow_dirty=$allow_dirty"
  echo "harness_head=$harness_head"
  # The criteria and the schema are PINNED BY HASH, which is what stops a
  # criterion being edited between the run and its grade. The analyser
  # recomputes both from the tree and fails on a mismatch.
  echo "criteria_sha256=$(sha256sum "$HARNESS/CRITERIA.md" | awk '{print $1}')"
  echo "schema_sha256=$(sha256sum "$HARNESS/schema.md" | awk '{print $1}')"
  echo "runner_sha256=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')"
  echo "analyzer_sha256=$(sha256sum "$HARNESS/analyze-soak.py" | awk '{print $1}')"
  echo "preflight=$preflight_state"
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
  echo "server_cpus=$SERVER_CPUS"
  echo "generator_cpus=$GENERATOR_CPUS"
  echo "max_rss_kib=$MAX_RSS_KIB"
  echo "nofile=$(ulimit -Sn)"
  echo "server_sha256=$server_sha256"
  echo "openload_sha256=$openload_sha256"
  echo "nstat=$have_nstat"
} >"$OUT/manifest.txt"

SAMPLER_START_EPOCH="$(date +%s)"
(
  # unix_nanos joins this row to the generator's per-request CSV. Everything the
  # old telemetry recorded was relative to a start time it never printed, so no
  # server-side sample could be matched to a client-side failure.
  #
  # Sample 0 is taken BEFORE the first load cycle, which makes it the run's
  # kernel-counter baseline: nstat reports totals since boot, so only
  # last-minus-first is attributable to this run (schema.md rule 4).
  echo "sample,utc,unix_nanos,elapsed_s,rss_kib,hwm_kib,threads,fds,proc_ticks,host_ticks,stats_http,stats_curl_exit,stats_bytes,listen_overflows,listen_drops,tcp_abort_on_close,tcp_retrans"
  sample=0
  started=$SECONDS
  while kill -0 "$server_pid" 2>/dev/null; do
    sample_start_ns="$(date -u +%s%N)"
    status="/proc/$server_pid/status"
    rss="$(awk '/^VmRSS:/ {print $2}' "$status" 2>/dev/null || echo 0)"
    hwm="$(awk '/^VmHWM:/ {print $2}' "$status" 2>/dev/null || echo 0)"
    threads="$(awk '/^Threads:/ {print $2}' "$status" 2>/dev/null || echo 0)"
    fds="$(find "/proc/$server_pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)"
    proc_ticks="$(awk '{print $14+$15}' "/proc/$server_pid/stat" 2>/dev/null || echo 0)"
    host_ticks="$(awk 'NR==1 {for(i=2;i<=NF;i++) s+=$i; print s}' /proc/stat)"
    stats_file="$OUT/telemetry/stats-$(printf '%06d' "$sample").json"
    # THE METRIC DOES NOT TRAVEL THE PATH IT MEASURES (ADR-050).
    #
    # This block used to `curl http://127.0.0.1:$PORT/stats`, and R2-WP04's smoke
    # is what proved that wrong at last: with the pre-registered two-lane
    # affinity, 322 of 658 samples failed — 295 empty replies and 27 receive
    # failures — because `/stats` is an ordinary route competing for the very
    # Handler lanes the sample is trying to describe. Under load the observer
    # took a lane away from the observed, and then could not report it.
    #
    # That is exactly AUD-P2-009, and R2-WP03 had already decided it: ADR-050
    # moved the metric to a snapshot file written by a thread that owns no lane,
    # read by a sampler outside the process. The decision shipped, the soak
    # server grew the exporter — and this harness kept scraping HTTP. WP01 closed
    # the instrument and WP03 closed the observability; nobody closed the gap
    # between them.
    #
    # So the sample now READS THE SNAPSHOT. There is no network between the
    # metric and this reader, and no lane is consumed to take a measurement.
    #
    # The two fields keep their names and their meaning is widened, deliberately,
    # rather than renamed: `soak/1` artefacts and the eight committed fixtures
    # stay readable, and the analyser's accounting rule is unchanged. `200` still
    # means "this sample carries a value"; a non-200 still carries a cause in the
    # second field. What changed is which causes are possible — from curl's
    # 7/28/52/56, which cannot distinguish a stopped application from a lost
    # exchange, to ADR-050's closed taxonomy, which can.
    stats_curl_exit=0
    if [[ -z "$SNAPSHOT_PATH" ]]; then
      stats_http=000; stats_curl_exit=$SNAPSHOT_CAUSE_DISABLED
    elif [[ ! -e "$SNAPSHOT_PATH" ]]; then
      stats_http=000; stats_curl_exit=$SNAPSHOT_CAUSE_MISSING
    elif ! cp "$SNAPSHOT_PATH" "$stats_file" 2>/dev/null; then
      stats_http=000; stats_curl_exit=$SNAPSHOT_CAUSE_UNREADABLE
    elif ! head -n 1 "$stats_file" | grep -q '^druse_snapshot 1$'; then
      stats_http=000; stats_curl_exit=$SNAPSHOT_CAUSE_MALFORMED
    elif ! kill -0 "$server_pid" 2>/dev/null; then
      stats_http=000; stats_curl_exit=$SNAPSHOT_CAUSE_NO_PROCESS
    else
      # `stale` is the one cause that needs the record's own clock: a snapshot
      # can be present, well-formed and written by a process that has since
      # wedged. Age is measured against the record, not the file's mtime, so a
      # rename that touched the inode cannot pass for a fresh write.
      snap_ns="$(awk '/^unix_ns / {print $2; exit}' "$stats_file" 2>/dev/null || echo 0)"
      now_ns="$(date -u +%s%N)"
      if [[ -z "$snap_ns" || "$snap_ns" == 0 ]]; then
        stats_http=000; stats_curl_exit=$SNAPSHOT_CAUSE_MALFORMED
      elif (( (now_ns - snap_ns) / 1000000000 > SNAPSHOT_MAX_AGE_SECONDS )); then
        stats_http=000; stats_curl_exit=$SNAPSHOT_CAUSE_STALE
      else
        stats_http=200
      fi
    fi
    # A snapshot that "answered" must carry a body, for the same reason the curl
    # form did: an empty file and a successful read of nothing look identical on
    # disk. The size says which.
    stats_bytes="$(stat -c %s "$stats_file" 2>/dev/null || echo 0)"
    # Kernel counters. A request the kernel dropped before the server ever saw
    # it looks identical, from userspace, to a request the server refused —
    # these four numbers are what tells the two apart.
    # `|| nstat_line=""` is load-bearing: this is a pipeline under pipefail, and
    # without the guard a host with no nstat kills the sampler on iteration one.
    nstat_line="$(nstat -az 2>/dev/null | awk '
      /^TcpExtListenOverflows/ {o=$2}
      /^TcpExtListenDrops/     {d=$2}
      /^TcpExtTCPAbortOnClose/ {a=$2}
      /^TcpRetransSegs/        {r=$2}
      END {printf "%s,%s,%s,%s", (o?o:0), (d?d:0), (a?a:0), (r?r:0)}')" ||
      nstat_line=""
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$sample" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%s%N)" \
      "$((SECONDS-started))" \
      "$rss" "$hwm" "$threads" "$fds" "$proc_ticks" "$host_ticks" \
      "${stats_http:-000}" "${stats_curl_exit:-0}" "${stats_bytes:-0}" \
      "${nstat_line:-0,0,0,0}"
    if [[ "${rss:-0}" -ge "$MAX_RSS_KIB" ]]; then
      echo "rss_safety_stop=$rss" >"$OUT/control/safety-stop.txt"
      kill -TERM "$server_pid" 2>/dev/null || true
      break
    fi
    sample=$((sample + 1))
    # One second, not five. A saturation refusal burst has a median of one
    # refusal, so a five-second window buries it in a bucket four seconds wider
    # than the event.
    #
    # SLEEP THE REMAINDER, NOT THE WHOLE INTERVAL. `sleep $SAMPLE_SECONDS` after
    # a body that costs real time makes the true period `interval + work`, and
    # the drift is silent: R2-WP04's smoke recorded 658 samples where the
    # manifest expected 681, and the analyser called it "telemetry stopped
    # early". The sampler had not stopped. Measured gaps were 1.03-1.06 s with
    # NOT ONE above 1.5 s — it was simply costing ~4% more than the 2% tolerance
    # allows, so criterion 11 would have failed every run of any length.
    #
    # `expected_samples` is elapsed/interval, so the fix belongs here rather
    # than in the tolerance: a sampler that keeps its own cadence makes the
    # arithmetic true instead of making the rule lenient.
    sample_end_ns="$(date -u +%s%N)"
    remaining_ns=$(( SAMPLE_SECONDS * 1000000000 - (sample_end_ns - sample_start_ns) ))
    if (( remaining_ns > 0 )); then
      sleep "$(awk -v ns="$remaining_ns" 'BEGIN {printf "%.3f", ns / 1000000000}')"
    fi
    # A body that overran the interval is not silently absorbed: the next sample
    # starts late and the deficit is visible in the timestamps, which is the
    # only honest way to report a sampler that cannot keep up.
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
  taskset -c "$GENERATOR_CPUS" "$OPENLOAD" "${args[@]}" \
    >"$OUT/cycles/c$(printf '%04d' "$cycle")-$name.json" \
    2>"$OUT/cycles/c$(printf '%04d' "$cycle")-$name.err" &
  LAST_PID=$!
}

# Deliberate faults are DECLARED as they are launched. The analyser matches the
# declarations against the reports on disk and reports the two totals side by
# side; it never nets an injected fault off a spontaneous one, because a real
# failure hidden behind an injection is exactly the arithmetic this instrument
# is supposed to make impossible.
declare_injection() { # cycle kind attempted
  echo "cycle=$1 kind=$2 attempted=$3 utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >>"$OUT/control/injected.txt"
}

run_rst() {
  local cycle="$1"
  declare_injection "$cycle" rst 128
  taskset -c "$GENERATOR_CPUS" "$OPENLOAD" \
    -url "http://127.0.0.1:$PORT/bytes/64k" \
    -rst-count 128 -rst-delay 20ms -connections 16 \
    >"$OUT/cycles/c$(printf '%04d' "$cycle")-rst.json" \
    2>"$OUT/cycles/c$(printf '%04d' "$cycle")-rst.err" &
  LAST_PID=$!
}

run_slow_readers() {
  local cycle="$1"
  declare_injection "$cycle" slow_readers 24
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
echo "cycle,started_utc,ended_utc,health_status,health_transport_errors,health_p99_us,stats_http,stats_curl_exit" \
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

  # A cycle artefact the run expected and did not get used to kill the
  # orchestrator here: `jq` on an absent file exits non-zero under `set -e`, and
  # the run died mid-cycle leaving the exact artefact the analyser then crashed
  # on. Record the absence and keep going — the analyser fails the run for it,
  # which is a verdict rather than a traceback.
  health_file="$OUT/cycles/c$(printf '%04d' "$cycle")-health.json"
  if [[ -s "$health_file" ]] && jq -e . "$health_file" >/dev/null 2>&1; then
    health_status="$(jq -r '.status["200"] // 0' "$health_file")"
    health_errors="$(jq -r '.transport_errors // 0' "$health_file")"
    health_p99="$(jq -r '.latency_p99_us // 0' "$health_file")"
  else
    echo "cycle=$cycle artefact=$(basename "$health_file") reason=missing_or_unparseable" \
      >>"$OUT/control/artefact-missing.txt"
    health_status=0
    health_errors=0
    health_p99=0
  fi
  # Same channel as the per-sample read, for the same reason (ADR-050). This one
  # fired once per cycle rather than once per second, so it was never going to
  # produce the 49% the sampler did — but a campaign that reads the metric two
  # ways, one of which competes with the load, cannot say which reading it
  # trusts.
  cycle_stats_file="$OUT/cycles/c$(printf '%04d' "$cycle")-stats.json"
  stats_curl_exit=0
  if [[ -n "$SNAPSHOT_PATH" ]] && cp "$SNAPSHOT_PATH" "$cycle_stats_file" 2>/dev/null &&
     head -n 1 "$cycle_stats_file" | grep -q '^druse_snapshot 1$'; then
    stats_http=200
  else
    stats_http=000
    stats_curl_exit=$SNAPSHOT_CAUSE_MISSING
  fi
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$cycle" "$started_utc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$health_status" "$health_errors" "$health_p99" \
    "${stats_http:-000}" "${stats_curl_exit:-0}" \
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
  >"$OUT/control/final-health.body" || true
curl -fsS --max-time 2 "http://127.0.0.1:$PORT/stats" \
  >"$OUT/control/final-stats.json" || true

# THE SAMPLER MUST STILL BE ALIVE. A sampler that died at minute three of a
# twelve-hour run leaves a short telemetry/process.csv, and a short CSV does not
# merely lose data: it silently disables every rule computed from the tail. The
# RSS-slope criterion only applies at 720 samples or more, so a two-row
# artefact of a twelve-hour run used to PASS with that criterion never
# evaluated and nothing anywhere saying so.
if ! kill -0 "$sampler_pid" 2>/dev/null; then
  echo "the telemetry sampler was not running when the load stopped" \
    >"$OUT/control/sampler-died.txt"
fi

echo "completed_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$OUT/manifest.txt"
echo "cycles=$cycle" >>"$OUT/manifest.txt"
# expected_samples is what makes a short sampler a NAMED failure rather than an
# unremarkable file. It is the sampler's own wall-clock window, not the
# requested hours: a run stopped early by MAX_CYCLES is short on purpose.
echo "expected_samples=$(( ( $(date +%s) - SAMPLER_START_EPOCH ) / SAMPLE_SECONDS ))" \
  >>"$OUT/manifest.txt"

kill -TERM "$sampler_pid" 2>/dev/null || true
sampler_exit=0
wait "$sampler_pid" 2>/dev/null || sampler_exit=$?
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
record_final_state "$forced_kill" "$server_exit" "$sampler_exit"

# The binaries that FINISHED the run, re-hashed. A binary swapped between the
# manifest and the end of the night is a different candidate, and the artefact
# has to be able to say so.
{
  echo "server_sha256=$(sha256sum "$SERVER" | awk '{print $1}')"
  echo "openload_sha256=$(sha256sum "$OPENLOAD" | awk '{print $1}')"
} >"$OUT/control/final-binaries.txt"

find "$OUT" -type f ! -name MANIFEST.sha256 -print0 | sort -z |
  xargs -0 sha256sum >"$OUT/MANIFEST.sha256"
touch "$OUT/COMPLETE"
