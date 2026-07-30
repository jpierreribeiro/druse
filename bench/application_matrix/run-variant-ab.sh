#!/usr/bin/env bash
# Paired A/B over prototype variants of the same commit.
#
#   usage: run-variant-ab.sh OUT_DIR ENDPOINT REPEATS BIN_DIR VARIANT...
#
#   run-variant-ab.sh /tmp/ab /json/medium/int 5 /tmp/bins control presize skipval
#
# BIN_DIR holds one binary per variant name. They must differ only by a
# `-define` on one commit — the manifest records each one's sha256 so that
# claim can be checked rather than trusted.
#
# Two rates per variant, and they answer different questions:
#
#   BELOW THE KNEE (10,000/s here) — p50 is a service time, so a change in it
#   is a change in what a request costs.
#
#   ABOVE THE KNEE (30,000/s) — goodput IS the ceiling, and comparing ceilings
#   is valid even though comparing latencies there is not. This is the one
#   place a past-the-knee number means something, and it means throughput.
#
# Variants alternate every repeat, per planning/benchmark-methodology.md: "the
# outer loop is the repetition; the inner loop is the configuration", because
# running one variant's repeats back to back gives it a warm cache for its whole
# block and the measured difference would be the order.
set -euo pipefail

OUT="${1:?usage: run-variant-ab.sh OUT_DIR ENDPOINT REPEATS BIN_DIR VARIANT...}"
ENDPOINT="${2:?an endpoint path}"
REPEATS="${3:-5}"
BIN_DIR="${4:?a directory of per-variant binaries}"
shift 4
VARIANTS=("$@")
[ ${#VARIANTS[@]} -lt 2 ] && { echo "AB-FAIL: need at least two variants" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOAD_CPUS="${DRUSE_BENCH_LOAD_CPUS:-4-7}"
SERVER_CPUS="${DRUSE_BENCH_SERVER_CPUS:-0-3}"
LANES="${DRUSE_BENCH_LANES:-4}"
PORT=8080
BELOW="${DRUSE_AB_BELOW:-10000}"
ABOVE="${DRUSE_AB_ABOVE:-30000}"
SECONDS_PER_RUN="${DRUSE_AB_SECONDS:-10}"

mkdir -p "$OUT/runs"
fail() { echo "AB-FAIL: $*" >&2; exit 1; }

(cd "$ROOT/ops/soak/openload" && go build -buildvcs=false -trimpath \
  -o "$OUT/openload" main.go) || fail "openload does not build"

{
  echo "started_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "git_head=${DRUSE_BENCH_COMMIT:-$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)}"
  echo "endpoint=$ENDPOINT"
  echo "variants=${VARIANTS[*]}"
  echo "repeats=$REPEATS"
  echo "rate_below_knee=$BELOW"
  echo "rate_above_knee=$ABOVE"
  echo "seconds_per_run=$SECONDS_PER_RUN"
  echo "lanes=$LANES"
  echo "kernel=$(uname -srmo)"
  for v in "${VARIANTS[@]}"; do
    [ -x "$BIN_DIR/$v" ] || fail "no binary for variant '$v' in $BIN_DIR"
    echo "sha256_$v=$(sha256sum "$BIN_DIR/$v" | awk '{print $1}')"
  done
} >"$OUT/manifest.txt"

# Every variant must answer the SAME BYTES. A prototype that changes the
# response is not a faster encoder, it is a different endpoint — the mistake
# that put a withdrawn row into a published report.
reference=""
for v in "${VARIANTS[@]}"; do
  ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]" && fail "port $PORT is in use"
  taskset -c "$SERVER_CPUS" "$BIN_DIR/$v" "$LANES" >"$OUT/runs/$v-probe.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    curl -fsS --max-time 0.5 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
    sleep 0.1
  done
  curl -sS "http://127.0.0.1:$PORT$ENDPOINT" -o "$OUT/runs/$v-response.json"
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  for _ in $(seq 1 100); do
    ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]" || break
    sleep 0.1
  done
  if [ -z "$reference" ]; then
    reference="$v"
  elif ! cmp -s "$OUT/runs/$reference-response.json" "$OUT/runs/$v-response.json"; then
    fail "variant '$v' answers different bytes than '$reference'; it is a different endpoint, not a faster one"
  fi
done
echo "every variant answers byte-identical responses ($(wc -c <"$OUT/runs/$reference-response.json") bytes)"

# One server visit per variant per repeat, BOTH rates inside it.
#
# The first version of this restarted the server for every measurement — forty
# starts, each after a hundred thousand connections. From the second repeat on,
# bind() failed against the lingering TIME_WAIT connections, the server exited
# SILENTLY WITH STATUS ZERO (druse#152), and the readiness loop below had no
# failure branch, so the script cheerfully measured a closed port and recorded
# 100,000 dial_refused per run as if it were data. Both halves of that are fixed
# here: fewer restarts, and a readiness check that stops the run.
measure_visit() { # variant repeat
  local v="$1" repeat="$2"

  # ss -ltn lists LISTENING sockets only, so it cannot see the TIME_WAIT
  # connections that make bind() fail. The readiness check below is what
  # actually proves the server is up; this is only a fast pre-check.
  ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]" && fail "port $PORT is in use"

  # A Druse server that cannot bind returns from serve() with status 0 and
  # writes nothing (druse#152), so "the process is gone" is the ONLY signal that
  # a start failed. That is detectable, and a start that fails right after a
  # heavy run is transient — the kernel has not finished with the previous
  # run's sockets. Retrying with a longer wait is honest as long as the retry is
  # recorded, which it is: every attempt beyond the first goes into the manifest.
  local ready=0 attempt=0 pid=
  while [ "$attempt" -lt 3 ] && [ "$ready" = 0 ]; do
    attempt=$((attempt + 1))
    taskset -c "$SERVER_CPUS" "$BIN_DIR/$v" "$LANES" >"$OUT/runs/$v-r$repeat-server.log" 2>&1 &
    pid=$!
    for _ in $(seq 1 150); do
      if curl -fsS --max-time 0.5 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
        ready=1
        break
      fi
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    if [ "$ready" = 0 ]; then
      echo "retry_start variant=$v repeat=$repeat attempt=$attempt" >>"$OUT/manifest.txt"
      echo "  (start $attempt of '$v' did not come up; waiting and retrying)"
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      sleep 20
    fi
  done
  [ "$ready" = 1 ] ||
    fail "variant '$v' never answered /health on repeat $repeat after 3 attempts. A Druse server that cannot bind returns from serve() with status 0 and logs nothing (druse#152), so this is what that looks like from outside. Measuring anyway would record a closed port as data, which the first version of this script did."

  # Warm up, discarded: the first responses of a type pay costs a steady state
  # does not, and one of the variants under test caches on first use.
  taskset -c "$LOAD_CPUS" "$OUT/openload" -url "http://127.0.0.1:$PORT$ENDPOINT" \
    -rate "$BELOW" -duration 3s -connections 128 -timeout 5s >/dev/null 2>&1 || true

  for rate in "$BELOW" "$ABOVE"; do
    echo "repeat $repeat: $v at $rate/s"
    taskset -c "$LOAD_CPUS" "$OUT/openload" -url "http://127.0.0.1:$PORT$ENDPOINT" \
      -rate "$rate" -duration "${SECONDS_PER_RUN}s" -connections 128 -timeout 5s \
      >"$OUT/runs/$v-$rate-r$repeat.json" 2>/dev/null || true
    sleep 1
  done

  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  for _ in $(seq 1 100); do
    ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]" || break
    sleep 0.1
  done
  # Let the accepted connections drain out of TIME_WAIT before the next bind.
  sleep "${DRUSE_AB_SETTLE:-5}"
}

for repeat in $(seq 1 "$REPEATS"); do
  order=("${VARIANTS[@]}")
  if [ $((repeat % 2)) -eq 0 ]; then
    reversed=(); for (( i=${#order[@]}-1; i>=0; i-- )); do reversed+=("${order[i]}"); done
    order=("${reversed[@]}")
  fi
  for v in "${order[@]}"; do
    measure_visit "$v" "$repeat"
  done
done

python3 - "$OUT" "$BELOW" "$ABOVE" <<'PY' | tee "$OUT/summary.txt"
import glob, json, pathlib, re, statistics, sys

root, below, above = pathlib.Path(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
manifest = dict(
    line.split("=", 1) for line in (root / "manifest.txt").read_text().splitlines() if "=" in line
)
runs = {}
for path in sorted((root / "runs").glob("*-*-r*.json")):
    m = re.match(r"(.+)-(\d+)-r(\d+)\.json$", path.name)
    if not m:
        continue
    try:
        runs.setdefault((m.group(1), int(m.group(2))), []).append(json.loads(path.read_text()))
    except Exception:
        pass

variants = manifest.get("variants", "").split()
print(f"variant A/B — {manifest.get('endpoint')}, {manifest.get('repeats')} repeats, "
      f"{manifest.get('lanes')} lanes, commit {manifest.get('git_head','?')[:12]}")
print()

def med(reports, key):
    return statistics.median(r.get(key, 0) for r in reports)

base_p50 = base_ceiling = None
print(f"  {'variant':10} {'p50 below knee':>16} {'delta':>9} {'ceiling at ' + str(above):>18} {'delta':>9} {'failures':>9}")
for v in variants:
    lo, hi = runs.get((v, below)), runs.get((v, above))
    if not lo or not hi:
        continue
    p50 = med(lo, "latency_p50_us")
    ceiling = med(hi, "goodput_per_second")
    fails = sum(r.get("transport_errors", 0) for r in lo)
    if base_p50 is None:
        base_p50, base_ceiling = p50, ceiling
        dp = dc = "—"
    else:
        dp = f"{(p50/base_p50-1)*100:+.1f}%"
        dc = f"{(ceiling/base_ceiling-1)*100:+.1f}%"
    print(f"  {v:10} {p50:13,.0f} us {dp:>9} {ceiling:15,.0f}/s {dc:>9} {fails:9,}")
print()
print(f"  p50 is a service time only below the knee; the ceiling column is the")
print(f"  one number a past-the-knee run reports honestly. Deltas are against")
print(f"  '{variants[0] if variants else '?'}'.")
PY
