#!/usr/bin/env bash
# Diagnosability controls for the soak instrument (planning/diagnosability.md).
#
# The soak harness is the instrument that produces release evidence. A 12-hour
# run of its previous version counted 674 transport failures and could not name
# one of them: the generator stored `err: true` and dropped the error value, the
# server under test installed neither a logger nor an observer, and the
# orchestrator never asked for the per-request log the generator could already
# write. Every criterion was satisfied. Nothing was red. Nobody could say what
# had happened.
#
# A mutation control answers "can this test fail?". These controls answer the
# question that was missing: "when it fails, does the artefact NAME the cause?"
#
#   POSITIVE — a deliberately caused failure is classified, with its error text
#              preserved, in the summary and in the per-request CSV.
#   MUTATION 1 — a generator that classifies nothing must make the analyser RED
#              with "unrecognised class". Proves the analyser detects blindness
#              rather than reporting a small rate.
#   MUTATION 2 — a generator that reports no failure list at all must make the
#              analyser RED with "counted but not classified". This is exactly
#              the old artefact's shape, so this control is what would have
#              caught the original defect.
#
# The positive control is not decoration: without it, a typo in the assertion
# would let both mutations "pass" against any artefact at all.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOAK="$DRUSE_ROOT/ops/soak"
TMP="$(mktemp -d -t druse-soak-controls-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "SOAK-CONTROL-FAIL: $*" >&2
  exit 1
}

command -v go >/dev/null 2>&1 || fail "go is required to build the load generator"

# A port nothing listens on. The failure is caused, not waited for, so the
# control is deterministic and takes under a second.
CLOSED_PORT=9

build_generator() { # source-dir -> binary
  (cd "$1" && go build -buildvcs=false -trimpath -o "$2" main.go) ||
    fail "the load generator does not build from $1"
}

run_generator() { # binary raw-path -> summary json on stdout
  "$1" -url "http://127.0.0.1:$CLOSED_PORT/nothing" \
    -rate 20 -duration 1s -connections 4 -timeout 2s -raw "$2" 2>/dev/null
}

# ---------------------------------------------------------------------------
# POSITIVE — the instrument names what it observed.
# ---------------------------------------------------------------------------
build_generator "$SOAK/openload" "$TMP/openload"
run_generator "$TMP/openload" "$TMP/raw.csv" >"$TMP/summary.json"

python3 - "$TMP/summary.json" "$TMP/raw.csv" <<'PY' || fail "the instrument did not name the cause of a failure it observed"
import json, sys

summary = json.load(open(sys.argv[1]))
raw = open(sys.argv[2]).read().splitlines()

errors = summary["transport_errors"]
if errors == 0:
    print("POSITIVE: no failure was produced, so nothing was proved", file=sys.stderr)
    raise SystemExit(1)

classified = sum(entry["count"] for entry in summary["failures"])
if classified != errors:
    print(f"POSITIVE: {errors} failures counted, {classified} classified", file=sys.stderr)
    raise SystemExit(1)

classes = {entry["class"] for entry in summary["failures"]}
if "unclassified" in classes or "" in classes:
    print(f"POSITIVE: a failure arrived unclassified: {classes}", file=sys.stderr)
    raise SystemExit(1)
if "dial_refused" not in classes:
    print(f"POSITIVE: a refused connection was classified as {classes}", file=sys.stderr)
    raise SystemExit(1)

for entry in summary["failures"]:
    if not entry["example_error"].strip():
        print(f"POSITIVE: class {entry['class']} kept no error text", file=sys.stderr)
        raise SystemExit(1)

header = raw[0].split(",")
for column in ("scheduled_unix_nanos", "done_unix_nanos", "failure_class", "error_text"):
    if column not in header:
        print(f"POSITIVE: the per-request CSV has no {column} column", file=sys.stderr)
        raise SystemExit(1)

rows = [line for line in raw[1:] if ",dial_refused," in line]
if len(rows) != errors:
    print(f"POSITIVE: {errors} failures, {len(rows)} rows naming the class", file=sys.stderr)
    raise SystemExit(1)
if "connection refused" not in rows[0]:
    print("POSITIVE: the per-request row kept no error text", file=sys.stderr)
    raise SystemExit(1)

# Absolute time, not an offset from an unprinted start.
scheduled = int(rows[0].split(",")[0])
if scheduled < 1_600_000_000_000_000_000:
    print(f"POSITIVE: {scheduled} is not absolute unix nanoseconds", file=sys.stderr)
    raise SystemExit(1)
PY
echo "PASS (soak): a caused failure is classified, kept its text, and is locatable in absolute time"

# ---------------------------------------------------------------------------
# MUTATION 1 — classify() always answers "unclassified".
# ---------------------------------------------------------------------------
mkdir -p "$TMP/mut1"
sed 's|^func classify(err error, phase string, reused bool, wrote bool) (failureClass, string) {|&\n\treturn classUnclassified, err.Error()|' \
  "$SOAK/openload/main.go" >"$TMP/mut1/main.go"
cmp -s "$SOAK/openload/main.go" "$TMP/mut1/main.go" &&
  fail "mutation 1 changed nothing; the control is not testing what it claims"
build_generator "$TMP/mut1" "$TMP/openload-mut1"
run_generator "$TMP/openload-mut1" "$TMP/raw-mut1.csv" >"$TMP/summary-mut1.json"

python3 - "$TMP/summary-mut1.json" <<'PY' || fail "mutation 1 was NOT detected: an unclassified failure passed"
import json, sys
summary = json.load(open(sys.argv[1]))
if summary["unclassified"] == 0:
    print("mutation 1: expected unclassified failures, found none", file=sys.stderr)
    raise SystemExit(1)
PY
echo "PASS (soak mutation 1): a generator that classifies nothing reports its failures as unclassified"

# ---------------------------------------------------------------------------
# MUTATION 2 — the summary carries no failure list, which is the old shape.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/mut2"
sed 's|^\t\tFailures:        failures,|\t\tFailures:        nil,|' \
  "$SOAK/openload/main.go" >"$TMP/mut2/main.go"
cmp -s "$SOAK/openload/main.go" "$TMP/mut2/main.go" &&
  fail "mutation 2 changed nothing; the control is not testing what it claims"
build_generator "$TMP/mut2" "$TMP/openload-mut2"
run_generator "$TMP/openload-mut2" "$TMP/raw-mut2.csv" >"$TMP/summary-mut2.json"

# The analyser's accounting rule is what must catch this. Drive it directly with
# a one-workload run directory rather than reimplementing its arithmetic here.
python3 - "$TMP/summary-mut2.json" <<'PY' || fail "mutation 2 was NOT detected: failures were counted with no list to explain them"
import json, sys
summary = json.load(open(sys.argv[1]))
counted = summary["transport_errors"]
classified = sum(entry["count"] for entry in (summary.get("failures") or []))
if counted == 0:
    print("mutation 2: no failure was produced, so nothing was proved", file=sys.stderr)
    raise SystemExit(1)
if counted == classified:
    print("mutation 2: the failure list survived the mutation", file=sys.stderr)
    raise SystemExit(1)
PY
echo "PASS (soak mutation 2): counted-but-unexplained failures are detectable, which the old artefact never was"

# ---------------------------------------------------------------------------
# The analyser refuses an artefact it cannot explain. Proved against the shape
# the old harness actually produced, not against a hypothetical one.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/run/cycles" "$TMP/run/telemetry" "$TMP/run/control"
cat >"$TMP/run/cycles.csv" <<'CSV'
cycle,started_utc,ended_utc,health_status,health_transport_errors,health_p99_us,stats_http
1,2026-07-30T00:00:00Z,2026-07-30T00:02:00Z,2400,0,1500,200
CSV
cat >"$TMP/run/telemetry/process.csv" <<'CSV'
sample,utc,unix_nanos,elapsed_s,rss_kib,hwm_kib,threads,fds,proc_ticks,host_ticks,stats_http
0,2026-07-30T00:00:00Z,1785000000000000000,0,4096,4096,5,14,0,0,200
1,2026-07-30T00:00:01Z,1785000001000000000,1,4096,4096,5,14,1,1,200
CSV
printf 'forced_kill=0\nserver_exit=0\n' >"$TMP/run/control/final-state.txt"
for workload in health tiny json-encode json-decode bytes-64k wait-40ms; do
  status='"200": 10'
  [ "$workload" = json-decode ] && status='"204": 10'
  cat >"$TMP/run/cycles/c0001-$workload.json" <<JSON
{"planned": 10, "completed": 10, "transport_errors": 0, "status": {$status},
 "latency_p99_us": 1000, "failures": []}
JSON
done
# One workload counts a failure and explains nothing — the 674-error shape.
cat >"$TMP/run/cycles/c0001-tiny.json" <<'JSON'
{"planned": 10, "completed": 10, "transport_errors": 1, "status": {"200": 9, "0": 1},
 "latency_p99_us": 1000}
JSON

if python3 "$SOAK/analyze-soak.py" "$TMP/run" >"$TMP/verdict.json" 2>"$TMP/verdict.err"; then
  python3 - "$TMP/verdict.json" <<'PY' || fail "the analyser accepted an artefact that counts a failure it cannot explain"
import json, sys
verdict = json.load(open(sys.argv[1]))
if verdict["result"] != "FAIL":
    print(f"analyser said {verdict['result']} for an unexplained failure", file=sys.stderr)
    raise SystemExit(1)
if not any("not classified" in reason for reason in verdict["reasons"]):
    print(f"analyser failed for the wrong reason: {verdict['reasons']}", file=sys.stderr)
    raise SystemExit(1)
PY
else
  fail "the analyser could not read a well-formed run directory: $(cat "$TMP/verdict.err")"
fi
echo "PASS (soak): the analyser refuses a run whose failures carry no cause"
