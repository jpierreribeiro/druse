#!/usr/bin/env bash
# R2-WP05 experiment 2 — what does raising `max_handlers` COST?
#
#   usage: lanes-sweep.sh BASE ARM LANES BURST_PERIOD_S DURATION_S
#
# Experiment 1 measured that doubling lanes ELIMINATES saturation refusals. It
# recorded, in its own §5, what it did not measure: that four lanes on two
# physical cores is oversubscription, and the 2026-07-25 report measured that
# more lanes costs throughput and tail. This harness measures that other half.
#
# THE ONE DIFFERENCE FROM `burst-sweep.sh`: it passes `-raw` to every generator
# and KEEPS the per-request CSV, because throughput and percentiles come from
# there. Experiment 1 sent it all to /dev/null — it only counted refusals on the
# server, and keeping 4.6 M rows it would never read would have been storage
# spent to look thorough.
#
# WHY THIS EXISTS. R2-WP04 stopped because load refusals did not reach zero at
# any tested rate, and it recorded a hypothesis it could not test: the driver is
# the ~624-connection burst at each cycle edge, not the offered request rate.
# `run-soak.sh` cannot separate those two — it restarts every generator every
# cycle, always — and it is pinned by sha256 in §2.1 of the soak
# pre-registration, so changing it would create a new candidate under G1 and
# discard the five ladder steps already run.
#
# So this is a SEPARATE harness that reuses the same server, the same generator
# and the same out-of-band snapshot channel, and makes the restart period a
# PARAMETER. The pre-registration is
# planning/readiness/R2-WP05-lanes-preregistration.md; the criteria there are
# frozen and this script does not grade — it measures and records.
#
# WHAT IT DELIBERATELY DOES NOT DO. No fault injection. Every refusal this
# harness observes is therefore attributable to offered load BY CONSTRUCTION,
# and it writes an empty `injected.txt` so the artefact proves that rather than
# asserting it (criterion W5).
set -euo pipefail

BASE="${1:?usage: burst-sweep.sh BASE ARM LANES BURST_PERIOD_S DURATION_S}"
ARM="${2:?arm label}"
LANES="${3:?lanes}"
BURST_PERIOD="${4:?burst period seconds, 0 = continuous}"
DURATION="${5:?duration seconds}"

REPO="$BASE/repo"
OUT="$BASE/wp05/$ARM"
PORT="${DRUSE_WP05_PORT:-8080}"
ODIN_BIN="${DRUSE_ODIN_BIN:-$HOME/odin-pinned/odin}"
SERVER_CPUS="${DRUSE_SOAK_SERVER_CPUS:-0,1,4,5}"
GENERATOR_CPUS="${DRUSE_SOAK_GENERATOR_CPUS:-2,3,6,7}"

# The offered rates. Defaults are §4.7 (aggregate 960/s), which is what
# experiment 2 held constant while lanes moved.
#
# THEY ARE OVERRIDABLE, AND THE FIRST EDITION WAS NOT — that cost a run. This
# harness was derived from `burst-sweep.sh`, where hard-coding was CORRECT:
# there the rate had to stay fixed while the burst structure moved, and a
# variable rate would have been a bug. Experiment 3 inverts the design — the
# rate IS the variable — and the constant came along for the ride.
#
# The symptom was quiet in exactly the way that matters: the ladder's second
# point offered 449,100 requests and delivered 288,000, which is 960 x 300 to
# the request. The number looked like a 64% goodput collapse and was really the
# generator never leaving the first rate. A harness that reports someone else's
# configuration as a measurement is the same class of defect as one that reads
# someone else's server.
HEALTH_RATE="${DRUSE_SOAK_HEALTH_RATE:-20}"
TINY_RATE="${DRUSE_SOAK_TINY_RATE:-600}"
JSON_ENCODE_RATE="${DRUSE_SOAK_JSON_ENCODE_RATE:-90}"
JSON_DECODE_RATE="${DRUSE_SOAK_JSON_DECODE_RATE:-240}"
BYTES_64K_RATE="${DRUSE_SOAK_BYTES_64K_RATE:-9}"
WAIT_40MS_RATE="${DRUSE_SOAK_WAIT_40MS_RATE:-1}"

# THE PORT MUST BE FREE BEFORE WE START, and this is not defensive politeness.
# The first edition skipped it and paid: arm 1 died on an unrelated bug leaving
# its server alive, the next seven could not bind — and their readiness check
# still got a 200 from the ORPHAN. A harness that reads one process's counters
# while believing they belong to another does not produce a wrong number, it
# produces a confident one. `preflight.sh` refuses an occupied port for the same
# reason; so does this.
if command -v ss >/dev/null 2>&1 && ss -lntH "sport = :$PORT" 2>/dev/null | grep -q .; then
  echo "FATAL: port $PORT already has a listener. This run would measure someone else's server — refusing to start. Find it with 'ss -lntp \"sport = :$PORT\"' and kill it BY PID (never pkill -f)." >&2
  exit 6
fi

rm -rf "$OUT"
mkdir -p "$OUT"/{bin,control,raw}
SERVER="$OUT/bin/server"
OPENLOAD="$OUT/bin/openload"
SNAPSHOT="$OUT/control/snapshot.txt"

# W5's proof: an empty injected.txt, written unconditionally. An absent file
# would be indistinguishable from a harness that forgot to declare injections.
: >"$OUT/control/injected.txt"

echo "building" >&2
"$ODIN_BIN" build "$REPO/ops/soak/soak-server" \
  -collection:druse="$REPO" -o:speed -out:"$SERVER"
(cd "$REPO/ops/soak/openload" && go build -buildvcs=false -trimpath -o "$OPENLOAD" main.go)

taskset -c "$SERVER_CPUS" "$SERVER" "$LANES" "$PORT" "$SNAPSHOT" \
  >"$OUT/server.log" 2>&1 &
SERVER_PID=$!
echo "$SERVER_PID" >"$OUT/control/server.pid"

# KILL THE SERVER ON EVERY EXIT PATH, not only the ones we thought of. The first
# edition killed it inside each FATAL branch and leaked it everywhere else — one
# unhandled error left a server holding the port for the rest of the sweep. The
# trap is the only construct that covers the paths nobody enumerated.
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

# THE NEGATIVE CONTROL IS STRUCTURAL, not a separate case: if the server never
# becomes ready the harness EXITS NON-ZERO instead of recording zero refusals.
# INS-013 in this repository — one absent measurement rendered as a clean result
# produced a green twelve-hour artefact with no telemetry in it.
#
# AND READINESS IS CHECKED ON OUR OWN PROCESS FIRST. A 200 from `/health` proves
# that SOMETHING answers on this port, which is a weaker claim than it looks.
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "FATAL: the server exited immediately; see $OUT/server.log" >&2
  exit 7
fi
ready=no
for _ in $(seq 1 200); do
  if curl -fsS --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    ready=yes; break
  fi
  sleep 0.1
done
if [[ "$ready" != yes ]]; then
  echo "FATAL: server never became ready; refusing to report a measurement" >&2
  kill "$SERVER_PID" 2>/dev/null || true
  exit 3
fi

# The ADR-050 snapshot, not an HTTP scrape on the lanes under test. Guarded on
# the file EXISTING because the first edition was not: `awk` on a missing file
# exits 2, `pipefail` propagated it and `set -e` killed the harness before it
# measured anything. Eight arms died in eleven seconds each.
#
# The guard returns empty, never zero. Zero is a measurement; empty is the
# absence of one, and the callers below treat them differently.
read_refusals() {
  [[ -f "$SNAPSHOT" ]] || return 0
  awk '/^saturation_refusals /{print $2}' "$SNAPSHOT" 2>/dev/null | tail -1
}

# THE SNAPSHOT IS A PRECONDITION, NOT A CONVENIENCE. `/health` answers before
# the exporter thread has written its first file, so waiting only on readiness
# reads an absent channel as a working one. The soak analyser refuses a run whose
# snapshot is missing or stale; this harness refuses to START one.
snapshot_ready=no
for _ in $(seq 1 100); do
  if [[ -n "$(read_refusals)" ]]; then snapshot_ready=yes; break; fi
  sleep 0.2
done
if [[ "$snapshot_ready" != yes ]]; then
  echo "FATAL: the ADR-050 snapshot never appeared at $SNAPSHOT; the metric channel this run depends on is not working, and a run without it is not a measurement" >&2
  kill "$SERVER_PID" 2>/dev/null || true
  exit 5
fi

REFUSALS_BEFORE="$(read_refusals)"

# One "burst" = every generator being (re)started at the same instant. That is
# what run-soak.sh does at each cycle edge, and what this script makes optional.
launch_generators() {  # $1 = seconds this wave should run for
  local secs="$1" cpus="$GENERATOR_CPUS"
  # A wave index keeps each burst's CSV separate. Overwriting would silently
  # keep only the last wave and make a 10-burst arm look like a 1-burst arm.
  WAVE=$(( WAVE + 1 ))
  local w
  w="$(printf '%03d' "$WAVE")"
  taskset -c "$cpus" "$OPENLOAD" -url "http://127.0.0.1:$PORT/health" \
    -rate "$HEALTH_RATE" -duration "${secs}s" -connections 16 \
    -raw "$OUT/raw/w$w-health.csv" >/dev/null 2>&1 &
  taskset -c "$cpus" "$OPENLOAD" -url "http://127.0.0.1:$PORT/tiny" \
    -rate "$TINY_RATE" -duration "${secs}s" -connections 128 \
    -raw "$OUT/raw/w$w-tiny.csv" >/dev/null 2>&1 &
  taskset -c "$cpus" "$OPENLOAD" -url "http://127.0.0.1:$PORT/json/medium" \
    -rate "$JSON_ENCODE_RATE" -duration "${secs}s" -connections 128 \
    -raw "$OUT/raw/w$w-json-encode.csv" >/dev/null 2>&1 &
  taskset -c "$cpus" "$OPENLOAD" -url "http://127.0.0.1:$PORT/json/medium/decode" \
    -method POST -payload medium-json \
    -rate "$JSON_DECODE_RATE" -duration "${secs}s" -connections 256 \
    -raw "$OUT/raw/w$w-json-decode.csv" >/dev/null 2>&1 &
  taskset -c "$cpus" "$OPENLOAD" -url "http://127.0.0.1:$PORT/bytes/64k" \
    -rate "$BYTES_64K_RATE" -duration "${secs}s" -connections 64 \
    -raw "$OUT/raw/w$w-bytes-64k.csv" >/dev/null 2>&1 &
  taskset -c "$cpus" "$OPENLOAD" -url "http://127.0.0.1:$PORT/wait/40ms" \
    -rate "$WAIT_40MS_RATE" -duration "${secs}s" -connections 32 \
    -raw "$OUT/raw/w$w-wait-40ms.csv" >/dev/null 2>&1 &
}

STARTED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BURSTS=0
WAVE=0
if [[ "$BURST_PERIOD" == 0 ]]; then
  # Arm A: a single connect event for the whole window.
  launch_generators "$DURATION"
  BURSTS=1
  wait $(jobs -p | grep -v "$SERVER_PID" || true) 2>/dev/null || true
  sleep 2
else
  remaining="$DURATION"
  while (( remaining > 0 )); do
    wave=$(( remaining < BURST_PERIOD ? remaining : BURST_PERIOD ))
    launch_generators "$wave"
    BURSTS=$(( BURSTS + 1 ))
    sleep $(( wave + 1 ))
    remaining=$(( remaining - wave ))
  done
  sleep 2
fi
ENDED_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

REFUSALS_AFTER="$(read_refusals)"
: "${REFUSALS_AFTER:=}"
cp "$SNAPSHOT" "$OUT/raw/snapshot-final.txt" 2>/dev/null || true

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true

# A snapshot that could not be read is a FAILED run, never a clean one (W4).
if [[ -z "$REFUSALS_AFTER" ]]; then
  echo "FATAL: the final snapshot carried no saturation_refusals; this run is invalid" >&2
  exit 4
fi

{
  echo "schema=wp05-burst/1"
  echo "arm=$ARM"
  echo "lanes=$LANES"
  echo "burst_period_s=$BURST_PERIOD"
  echo "bursts=$BURSTS"
  echo "duration_s=$DURATION"
  echo "started_utc=$STARTED_UTC"
  echo "ended_utc=$ENDED_UTC"
  echo "server_cpus=$SERVER_CPUS"
  echo "generator_cpus=$GENERATOR_CPUS"
  echo "health_rate=$HEALTH_RATE"
  echo "tiny_rate=$TINY_RATE"
  echo "json_encode_rate=$JSON_ENCODE_RATE"
  echo "json_decode_rate=$JSON_DECODE_RATE"
  echo "bytes_64k_rate=$BYTES_64K_RATE"
  echo "wait_40ms_rate=$WAIT_40MS_RATE"
  echo "aggregate_rate=$(( HEALTH_RATE + TINY_RATE + JSON_ENCODE_RATE + JSON_DECODE_RATE + BYTES_64K_RATE + WAIT_40MS_RATE ))"
  echo "commit=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "server_sha256=$(sha256sum "$SERVER" | awk '{print $1}')"
  echo "openload_sha256=$(sha256sum "$OPENLOAD" | awk '{print $1}')"
  echo "saturation_refusals_before=$REFUSALS_BEFORE"
  echo "saturation_refusals_after=$REFUSALS_AFTER"
  echo "saturation_refusals=$(( REFUSALS_AFTER - REFUSALS_BEFORE ))"
  echo "injections_declared=0"
} >"$OUT/manifest.txt"

# O resumo por braço sai do CSV por requisição, e é o que X1 e X2 leem. Contar
# aqui, uma vez, evita que a análise dependa de reprocessar 4,6 M linhas oito
# vezes — e deixa o número no artefato, onde pode ser contestado.
python3 - "$OUT" >>"$OUT/manifest.txt" <<'PY'
import csv, glob, os, sys
out = sys.argv[1]
lat, ok, non2xx, failed = [], 0, 0, 0
for path in glob.glob(os.path.join(out, "raw", "*.csv")):
    with open(path) as fh:
        for row in csv.DictReader(fh):
            cls = row.get("failure_class", "")
            if cls:
                failed += 1
                continue
            status = int(row["status"])
            if 200 <= status < 300:
                ok += 1
                lat.append(int(row["latency_ns"]))
            else:
                non2xx += 1
lat.sort()
def pct(p):
    return lat[min(len(lat) - 1, int(len(lat) * p))] // 1000 if lat else -1
print(f"completed_2xx={ok}")
print(f"non_2xx={non2xx}")
print(f"transport_failures={failed}")
print(f"latency_p50_us={pct(0.50)}")
print(f"latency_p99_us={pct(0.99)}")
print(f"latency_p999_us={pct(0.999)}")
PY

cat "$OUT/manifest.txt"
