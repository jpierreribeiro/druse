#!/usr/bin/env bash
#
# R2-WP03 — the overhead of exporting out of band, against the budget frozen in
# planning/readiness/R2-WP03-preregistration.md BEFORE this script ran (G3).
#
#   B5  exporter CPU, idle process, 60 s at 1 Hz      <= 60 ms  (0.10% of a core)
#   B6  VmHWM with export minus without               <= 2048 KiB
#   B7  lane cost                                     exactly 0  (asserted in
#                                                     tests/r2-observability-saturation)
#
# and, as a DIAGNOSTIC rather than a criterion, a paired throughput comparison
# with the INCONCLUSIVE rule the pre-registration fixed in advance: if the
# no-exporter arm's own spread exceeds the effect the budget is meant to detect,
# this host cannot resolve it and the answer is "inconclusive", not a pass.
#
# Usage: ops/monitoring/measure-export-overhead.sh OUTPUT_DIR
set -euo pipefail

OUT="${1:?usage: $0 OUTPUT_DIR}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$OUT"

ODIN="${DRUSE_ODIN_BIN:-$(command -v odin || true)}"
test -n "$ODIN" || { echo "odin not found; set DRUSE_ODIN_BIN" >&2; exit 2; }
ODIN="$(readlink -f "$ODIN")"
export ODIN_ROOT="$(dirname "$ODIN")"

WORK="$(mktemp -d -t druse-overhead-XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PORT=${PORT:-57611}
IDLE_SECONDS=${IDLE_SECONDS:-60}
IDLE_REPS=${IDLE_REPS:-5}
LOAD_SECONDS=${LOAD_SECONDS:-15}
REPS=${REPS:-7}
RATE=${RATE:-2000}
CONNECTIONS=${CONNECTIONS:-64}
# Pre-registered. Repeated here so the script and the frozen document can be
# diffed against each other rather than trusted to agree.
B5_BUDGET_MS=60
B6_BUDGET_KB=2048
THROUGHPUT_BUDGET_PCT=1.0
NOISE_ABORT_PCT=1.0

"$ODIN" build "$ROOT/ops/soak/soak-server" "-collection:druse=$ROOT" -out:"$WORK/soak-server"
echo "soak-server sha256: $(sha256sum "$WORK/soak-server" | cut -d' ' -f1)" | tee "$OUT/binaries.txt"
# `go build .` cannot be used here: there is no go.mod in the tree, so the
# module resolver walks up, finds the repository, and refuses. `run-soak.sh`
# names the file explicitly for the same reason, and this matches it flag for
# flag so the two harnesses build the same binary.
if command -v go >/dev/null 2>&1; then
  (cd "$ROOT/ops/soak/openload" && go build -buildvcs=false -trimpath -o "$WORK/openload" main.go) &&
    echo "openload sha256: $(sha256sum "$WORK/openload" | cut -d' ' -f1)" >>"$OUT/binaries.txt"
fi

CLK="$(getconf CLK_TCK)"

# start_server WITH_EXPORT -> echoes the pid
start_server() {
  local with_export="$1" snapshot=""
  if test "$with_export" = yes; then
    snapshot="$WORK/snapshot"
  fi
  "$WORK/soak-server" 4 "$PORT" "$snapshot" >"$WORK/server.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 200); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
      exec 3<&- 3>&-
      echo "$pid"
      return 0
    fi
    sleep 0.05
  done
  kill "$pid" 2>/dev/null || true
  return 1
}

cpu_ticks() { awk '{print $14 + $15}' "/proc/$1/stat" 2>/dev/null || echo 0; }
vmhwm_kb()  { awk '/^VmHWM:/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }

# stop_server TERMs the server and WAITS FOR IT TO BE GONE, by polling /proc.
#
# `wait` is not enough and the first version of this script proved it: the
# server is started inside a command substitution, so it is a child of that
# SUBSHELL and not of this shell. `wait $pid` therefore returns immediately, the
# loop moves on, and the dying server writes its final drain snapshot INSIDE the
# next arm's measurement window. The symptom was a `no-export` arm reporting one
# export tick — a number that could only come from a process that was supposed
# to be gone.
#
# It is the same class of defect the work package is about: a measurement whose
# window is not the window it claims.
stop_server() {
  kill -TERM "$1" 2>/dev/null || true
  for _ in $(seq 1 200); do
    test -d "/proc/$1" || return 0
    sleep 0.05
  done
  kill -KILL "$1" 2>/dev/null || true
  for _ in $(seq 1 100); do
    test -d "/proc/$1" || return 0
    sleep 0.05
  done
  echo "WARNING: pid $1 outlived SIGKILL; the next arm's window is contaminated" >&2
  return 1
}

# --- B5 / B6: an IDLE process, so the only difference is the exporter --------
#
# REPEATED AND ALTERNATING, because a single pair cannot resolve this. The
# kernel accounts CPU in clock ticks — 10 ms here — and one 60 s idle run of a
# server that is doing nothing burns a handful of them, so run-to-run variance is
# the same size as the effect. The first version of this script ran one pair,
# measured the exporter as costing MINUS 40 ms, and would have printed PASS.
#
# A negative delta is not a fast exporter. It is the measurement saying it cannot
# see the thing it was pointed at, and the analysis below is required to say so
# rather than take the sign at face value.
{
  echo "# B5/B6 — idle process, ${IDLE_SECONDS}s, export at 1 Hz, ${IDLE_REPS} paired reps"
  echo "# clk_tck=$CLK (CPU accounting resolution: $((1000 / CLK)) ms)"
  for rep in $(seq 1 "$IDLE_REPS"); do
    for arm in no-export with-export; do
      with=no
      test "$arm" = with-export && with=yes
      rm -f "$WORK/snapshot"
      pid="$(start_server "$with")" || { echo "rep=$rep arm=$arm FAILED_TO_START"; continue; }
      t0="$(cpu_ticks "$pid")"
      # Count DISTINCT snapshot mtimes: that is the number of times the exporter
      # actually ran. Counting lines in the file counts one record's fields,
      # which is a number that looks like a tick count and is not one.
      ticks_seen=0
      last_mtime=""
      for _ in $(seq 1 "$IDLE_SECONDS"); do
        sleep 1
        if test -f "$WORK/snapshot"; then
          m="$(stat -c %Y%N "$WORK/snapshot" 2>/dev/null || echo "")"
          if test -n "$m" && test "$m" != "$last_mtime"; then
            ticks_seen=$((ticks_seen + 1))
            last_mtime="$m"
          fi
        fi
      done
      t1="$(cpu_ticks "$pid")"
      hwm="$(vmhwm_kb "$pid")"
      stop_server "$pid"
      echo "rep=$rep arm=$arm cpu_ticks=$((t1 - t0)) vmhwm_kb=$hwm export_ticks=$ticks_seen"
    done
  done
} | tee "$OUT/idle.txt"

# --- Throughput diagnostic, paired and alternating ---------------------------
if test -x "$WORK/openload"; then
  {
    echo "# throughput diagnostic — ${REPS} paired reps, ${LOAD_SECONDS}s each, rate=$RATE conns=$CONNECTIONS"
    echo "# NOT an acceptance criterion. G4: a local gate does not answer capacity."
    for rep in $(seq 1 "$REPS"); do
      for arm in no-export with-export; do
        with=no
        test "$arm" = with-export && with=yes
        pid="$(start_server "$with")" || { echo "rep=$rep $arm FAILED_TO_START"; continue; }
        report="$("$WORK/openload" -url "http://127.0.0.1:$PORT/tiny" \
          -rate "$RATE" -duration "${LOAD_SECONDS}s" -connections "$CONNECTIONS" \
          -timeout 5s 2>/dev/null || echo '{}')"
        stop_server "$pid"
        rm -f "$WORK/snapshot"
        goodput="$(printf '%s' "$report" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("goodput_per_second", -1))' 2>/dev/null || echo -1)"
        errors="$(printf '%s' "$report" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("transport_errors", -1))' 2>/dev/null || echo -1)"
        echo "rep=$rep arm=$arm goodput_per_second=$goodput transport_errors=$errors"
      done
    done
  } | tee "$OUT/throughput.txt"
else
  echo "# throughput diagnostic SKIPPED: openload could not be built (no Go toolchain)" | tee "$OUT/throughput.txt"
fi

# --- Verdict against the frozen budgets --------------------------------------
python3 - "$OUT" "$B5_BUDGET_MS" "$B6_BUDGET_KB" "$THROUGHPUT_BUDGET_PCT" "$NOISE_ABORT_PCT" "$RATE" <<'PY' | tee "$OUT/verdict.txt"
import re, sys, statistics
out, b5, b6, budget_pct, noise_pct = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
offered = float(sys.argv[6])

clk = 100
cpu = {"no-export": [], "with-export": []}
hwm = {"no-export": [], "with-export": []}
ticks = {"no-export": [], "with-export": []}
for line in open(f"{out}/idle.txt"):
    m = re.match(r"# clk_tck=(\d+)", line)
    if m:
        clk = int(m.group(1))
    m = re.match(r"rep=(\d+) arm=(\S+) cpu_ticks=(-?\d+) vmhwm_kb=(\d+) export_ticks=(\d+)", line)
    if m:
        cpu[m.group(2)].append(int(m.group(3)))
        hwm[m.group(2)].append(int(m.group(4)))
        ticks[m.group(2)].append(int(m.group(5)))

lines = []
tick_ms = 1000 // clk
if len(cpu["no-export"]) >= 3 and len(cpu["with-export"]) >= 3:
    # The exporter must have actually RUN, or B5 and B6 measured two identical
    # processes and would pass by construction.
    ran = min(ticks["with-export"])
    leaked = max(ticks["no-export"])
    lines.append(f"precondition export_ticks_with_export_min={ran} export_ticks_no_export_max={leaked}")
    if ran < 3:
        lines.append("B5 INVALID: the exporter did not run; nothing was measured")
        lines.append("B6 INVALID: the exporter did not run; nothing was measured")
    elif leaked > 0:
        # A control arm that produced a snapshot is not a control arm. It means a
        # previous server was still alive inside this window, so the window is
        # not the window it claims to be.
        lines.append(f"B5 INVALID: the no-export arm saw {leaked} export tick(s); its window was contaminated by a server that should have been gone")
        lines.append(f"B6 INVALID: the no-export arm saw {leaked} export tick(s); its window was contaminated")
    else:
        base = statistics.median(cpu["no-export"])
        with_med = statistics.median(cpu["with-export"])
        d_ticks = with_med - base
        d_ms = d_ticks * (1000 / clk)
        # The noise floor of the CONTROL arm, expressed in the same unit as the
        # budget. If the arm that changes nothing varies by more than the budget,
        # a delta inside that range is not a measurement of the exporter.
        noise_ticks = max(cpu["no-export"]) - min(cpu["no-export"])
        noise_ms = noise_ticks * (1000 / clk)
        lines.append(
            f"B5 raw no_export_median_ticks={base} with_export_median_ticks={with_med} "
            f"delta_ms={d_ms:.0f} control_arm_spread_ms={noise_ms:.0f} "
            f"accounting_resolution_ms={tick_ms} budget_ms={b5}"
        )
        if noise_ms > b5:
            lines.append(
                f"B5 INCONCLUSIVE: the no-export arm's own spread is {noise_ms:.0f} ms, wider than "
                f"the {b5} ms budget. A delta inside that range is noise, not the exporter. "
                f"NOT a pass."
            )
        elif d_ms < 0:
            lines.append(
                f"B5 INCONCLUSIVE: the measured delta is negative ({d_ms:.0f} ms), which no exporter "
                f"can produce. The effect is below what this host resolves. NOT a pass — a negative "
                f"cost reported as a pass is a plausible number that measured nothing."
            )
        else:
            lines.append(f"B5 {'PASS' if d_ms <= b5 else 'FAIL'} exporter_cpu_delta_ms={d_ms:.0f} budget={b5}")

        d_hwm = statistics.median(hwm["with-export"]) - statistics.median(hwm["no-export"])
        hwm_noise = max(hwm["no-export"]) - min(hwm["no-export"])
        lines.append(f"B6 raw delta_kb={d_hwm:.0f} control_arm_spread_kb={hwm_noise} budget_kb={b6}")
        if hwm_noise > b6:
            lines.append(f"B6 INCONCLUSIVE: the no-export arm's own VmHWM spread is {hwm_noise} KiB, wider than the {b6} KiB budget. NOT a pass.")
        elif d_hwm < 0:
            lines.append(f"B6 INCONCLUSIVE: negative delta ({d_hwm:.0f} KiB); the effect is below what this host resolves. NOT a pass.")
        else:
            lines.append(f"B6 {'PASS' if d_hwm <= b6 else 'FAIL'} vmhwm_delta_kb={d_hwm:.0f} budget={b6}")
else:
    lines.append("B5 INVALID: fewer than three valid reps per arm")
    lines.append("B6 INVALID: fewer than three valid reps per arm")

vals = {"no-export": [], "with-export": []}
for line in open(f"{out}/throughput.txt"):
    m = re.search(r"arm=(\S+) goodput_per_second=([\d.]+)", line)
    if m and float(m.group(2)) > 0:
        vals[m.group(1)].append(float(m.group(2)))

if len(vals["no-export"]) >= 3 and len(vals["with-export"]) >= 3:
    base = statistics.median(vals["no-export"])
    spread = (max(vals["no-export"]) - min(vals["no-export"])) / base * 100
    with_med = statistics.median(vals["with-export"])
    delta = (base - with_med) / base * 100
    lines.append(f"throughput no_export_median={base:.1f} with_export_median={with_med:.1f} delta_pct={delta:.2f} host_spread_pct={spread:.2f} offered_rate={offered:.0f}")
    # `openload` is a FIXED-RATE generator. If both arms delivered essentially
    # the rate they were offered, the server was never the bottleneck and this
    # is not a throughput measurement at all — it is the generator's clock,
    # reported to four decimal places, which is exactly the shape of a number
    # that looks like a result and is not one.
    if base >= offered * 0.99 and with_med >= offered * 0.99:
        lines.append(
            f"throughput INCONCLUSIVE: both arms delivered the full offered rate ({offered:.0f}/s), "
            f"so the server was never the bottleneck. A fixed-rate generator below capacity measures "
            f"ITS OWN clock, not throughput. NOT a pass."
        )
        errs = 0
        for line in open(f"{out}/throughput.txt"):
            m2 = re.search(r"transport_errors=(-?\d+)", line)
            if m2 and int(m2.group(1)) > 0:
                errs += int(m2.group(1))
        lines.append(
            f"no-regression (a different and weaker claim): at {offered:.0f}/s offered, both arms "
            f"delivered full goodput with {errs} transport error(s). This says the exporter did not "
            f"break the server at a rate it handles comfortably. It says nothing about capacity."
        )
    elif spread > noise_pct:
        lines.append(f"throughput INCONCLUSIVE: the no-export arm's own spread is {spread:.2f}%, above the {noise_pct}% abort rule frozen before the run. This host cannot resolve a {budget_pct}% effect. Not a pass.")
    else:
        lines.append(f"throughput {'PASS' if delta <= budget_pct else 'FAIL'} against a {budget_pct}% budget")
else:
    lines.append("throughput INCONCLUSIVE: not enough valid reps")

print("\n".join(lines))
PY
