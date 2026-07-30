#!/usr/bin/env bash
# Runs the three arms pre-registered in 2026-07-30-saturation-attribution.md.
#
# Order is alternated (A B C C B A) because this project's benchmark methodology
# requires it: a one-directional sweep confounds the arm with anything that
# drifts over the session — page cache, thermal state, a neighbour on the host.
#
#   usage: run-saturation-attribution.sh BASE [MINUTES_PER_ARM]
#
# BASE is the same layout run-soak.sh expects: BASE/repo is a checkout of the
# core. Each arm writes into BASE/experiments/<arm>-<n>/ and is analysed on its
# own; nothing is aggregated across arms by this script, because the comparison
# is the analyst's job and averaging arms would hide exactly the difference the
# experiment exists to measure.
set -euo pipefail

BASE="${1:?usage: run-saturation-attribution.sh BASE [MINUTES_PER_ARM]}"
MINUTES="${2:-15}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOAK="$(cd "$HERE/.." && pwd)"
OUT="$BASE/experiments"
mkdir -p "$OUT"

# One cycle per arm keeps each arm a single uninterrupted measurement window.
PHASE_SECONDS=$(( MINUTES * 60 ))

run_arm() { # arm-name run-index extra-env...
  local arm="$1" index="$2"
  shift 2
  local dir="$OUT/$arm-$index"
  rm -rf "$dir"
  mkdir -p "$dir"

  echo "=== arm $arm (run $index), ${MINUTES} min ==="
  # run-soak.sh writes into BASE/soak, so each arm gets its own BASE.
  local arm_base="$dir/base"
  mkdir -p "$arm_base"
  ln -sfn "$BASE/repo" "$arm_base/repo"

  env "$@" \
    DRUSE_SOAK_PHASE_SECONDS="$PHASE_SECONDS" \
    DRUSE_SOAK_MAX_CYCLES=1 \
    DRUSE_SOAK_HARNESS="$SOAK" \
    bash "$SOAK/run-soak.sh" "$arm_base" 1 >"$dir/run.log" 2>&1 ||
    echo "arm $arm run $index: runner exited non-zero (see $dir/run.log)"

  python3 "$SOAK/analyze-soak.py" "$arm_base/soak" >"$dir/verdict.json" 2>"$dir/verdict.err" ||
    echo "arm $arm run $index: analyser exited non-zero (see $dir/verdict.err)"

  python3 - "$arm_base/soak" "$dir/verdict.json" "$arm" "$index" <<'PY'
import json, glob, re, sys, pathlib

soak, verdict_path, arm, index = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
root = pathlib.Path(soak)

failures, by_class, examples = 0, {}, {}
planned = 0
for path in sorted(root.glob("cycles/c*-*.json")):
    name = path.name.split("-", 1)[1].rsplit(".", 1)[0]
    if name in ("stats", "rst"):
        continue
    try:
        report = json.loads(path.read_text())
    except Exception:
        continue
    if "transport_errors" not in report:
        continue
    failures += report["transport_errors"]
    planned += report.get("planned", 0)
    for entry in report.get("failures", []):
        by_class[entry["class"]] = by_class.get(entry["class"], 0) + entry["count"]
        examples.setdefault(entry["class"], entry.get("example_error", ""))

# Saturation refusals over the arm, from the first and last /stats sample.
stats = sorted(root.glob("telemetry/stats-*.json"))
refusals = None
if len(stats) >= 2:
    try:
        first = json.loads(stats[0].read_text())
        last = json.loads(stats[-1].read_text())
        refusals = last["saturation_refusals"] - first["saturation_refusals"]
    except Exception:
        refusals = None

# Kernel counters: a falsification condition, not a nicety.
kernel = {}
telemetry = root / "telemetry/process.csv"
if telemetry.exists():
    import csv
    rows = list(csv.DictReader(telemetry.open()))
    for column in ("listen_overflows", "listen_drops", "tcp_abort_on_close", "tcp_retrans"):
        if rows and column in rows[0]:
            try:
                kernel[column] = int(rows[-1][column]) - int(rows[0][column])
            except Exception:
                pass

per_million = (failures / planned * 1_000_000) if planned else 0.0
summary = {
    "arm": arm, "run": int(index), "planned": planned, "failures": failures,
    "failures_per_million": round(per_million, 3),
    "saturation_refusals": refusals, "failure_classes": by_class,
    "failure_examples": examples, "kernel_deltas": kernel,
}
print(json.dumps(summary, indent=2, sort_keys=True))
PY
}

# Alternating order. Each arm runs twice, in opposite halves of the session.
for spec in "A 1" "B 1" "C 1" "C 2" "B 2" "A 2"; do
  set -- $spec
  arm="$1" index="$2"
  case "$arm" in
    A) run_arm A "$index" ;;
    B) run_arm B "$index" DRUSE_SOAK_LANES=16 ;;
    C) run_arm C "$index" DRUSE_SOAK_WAIT_40MS_RATE=0 ;;
  esac
done | tee "$OUT/arms.jsonl"

echo
echo "=== pre-registered decision rule ==="
cat <<'RULE'
H1 (the failures ARE saturation refusals) survives only if failures and
refusals fall together in BOTH arm B (16 lanes) and arm C (no blocking
handler). Failures persisting while refusals fall refutes it, and the
per-request CSV then carries the real cause.

The experiment does not settle the question if arm A produced no failures, if
any failure arrived unclassified, or if the kernel counters moved.
RULE
