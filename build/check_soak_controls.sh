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

# --- 0. The soak SERVER compiles ---------------------------------------------
# This gate built the Go load generator and never the Odin server it points at,
# so `ops/soak/soak-server` was outside every gate in the repository: a public
# signature change broke it in SILENCE, and the silence lasted until somebody
# started a campaign. WP123 is where that happened — `web.stats()` gained an
# argument and this file was the one call site no check would have caught.
#
# A compile, not a run: the run is the campaign, and the campaign is not a gate.
if test -n "${DRUSE_COMPILER:-}"; then
  DRUSE_SOAK_ODIN="$DRUSE_COMPILER"
elif command -v odin >/dev/null 2>&1; then
  DRUSE_SOAK_ODIN="$(command -v odin)"
else
  DRUSE_SOAK_ODIN=""
fi
test -n "$DRUSE_SOAK_ODIN" || fail "odin compiler not found; the soak server would go unchecked"
env ODIN_ROOT="$(cd "$(dirname "$(readlink -f "$DRUSE_SOAK_ODIN")")" && pwd)" \
  "$DRUSE_SOAK_ODIN" check "$SOAK/soak-server" "-collection:druse=$DRUSE_ROOT" ||
  fail "ops/soak/soak-server does not compile. It is the instrument that produces release evidence and it is in no other gate, so a break here is invisible until a campaign starts."
echo "PASS (soak): the soak server compiles against the current public surface"

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

# ---------------------------------------------------------------------------
# The analyser CARRIES a cause it was given. This is the positive half of the
# check above, and it is here because its absence let a real defect through:
# the analyser aggregated each workload into a dict with no `failures` key, so
# the accounting rule read an empty list and reported every failure as
# unexplained. The run above still went red — for the wrong reason — and the
# control could not tell the difference. A rule that only ever says "no cause"
# is indistinguishable from a broken one.
# ---------------------------------------------------------------------------
cat >"$TMP/run/cycles/c0001-tiny.json" <<'JSON'
{"planned": 10, "completed": 10, "transport_errors": 2, "status": {"200": 8, "0": 2},
 "latency_p99_us": 1000,
 "failures": [{"class": "peer_reset", "count": 2,
               "example_error": "read tcp 127.0.0.1:1->127.0.0.1:2: connection reset by peer"}]}
JSON

python3 "$SOAK/analyze-soak.py" "$TMP/run" >"$TMP/verdict2.json" 2>"$TMP/verdict2.err" ||
  fail "the analyser could not read a run whose failures are classified: $(cat "$TMP/verdict2.err")"

python3 - "$TMP/verdict2.json" <<'PY' || fail "the analyser dropped a cause the artefact carried"
import json, sys
verdict = json.load(open(sys.argv[1]))
if verdict["failures_counted"] != 2:
    print(f"expected 2 counted, got {verdict['failures_counted']}", file=sys.stderr)
    raise SystemExit(1)
if verdict["failures_classified"] != 2:
    print(
        f"the artefact classified 2 failures and the analyser reported "
        f"{verdict['failures_classified']}: the aggregation discarded them",
        file=sys.stderr,
    )
    raise SystemExit(1)
if verdict["failures_unclassified"] != 0:
    print(f"classified failures reported as unclassified", file=sys.stderr)
    raise SystemExit(1)
if verdict["failure_classes"].get("peer_reset") != 2:
    print(f"class lost in aggregation: {verdict['failure_classes']}", file=sys.stderr)
    raise SystemExit(1)
if "connection reset by peer" not in verdict["failure_examples"].get("peer_reset", ""):
    print("the example error text was dropped", file=sys.stderr)
    raise SystemExit(1)
if any("not classified" in reason for reason in verdict["reasons"]):
    print(f"analyser called an explained failure unexplained: {verdict['reasons']}", file=sys.stderr)
    raise SystemExit(1)
PY
echo "PASS (soak): the analyser carries a cause the artefact gave it, class and text intact"

# ---------------------------------------------------------------------------
# A profile absent WITH a recorded reason is fine; absent WITHOUT one is red.
#
# The saturation experiment removes the blocking handler by setting its rate to
# zero, and the orchestrator records that in control/skipped.txt. Before this
# distinction existed, a profile with no runs divided by a planned count of zero,
# was charged a transport error ratio of 1.0, and failed the run for never having
# happened — an arm deliberately configured would have been read as an arm that
# broke. The opposite mistake is worse: a profile that silently vanishes and
# nobody notices.
# ---------------------------------------------------------------------------
rm -f "$TMP/run/cycles/c0001-wait-40ms.json"

# 1. absent and unexplained -> red, naming the disappearance
python3 "$SOAK/analyze-soak.py" "$TMP/run" >"$TMP/verdict3.json" 2>&1 || true
python3 - "$TMP/verdict3.json" <<'PY' || fail "a profile vanished from the run and the analyser did not say so"
import json, sys
verdict = json.load(open(sys.argv[1]))
if verdict["result"] != "FAIL":
    print("a profile disappeared and the run passed", file=sys.stderr)
    raise SystemExit(1)
if not any("no runs and control/skipped.txt gives no reason" in r for r in verdict["reasons"]):
    print(f"failed for the wrong reason: {verdict['reasons']}", file=sys.stderr)
    raise SystemExit(1)
PY

# 2. absent WITH a reason -> accepted, and the reason is carried through
mkdir -p "$TMP/run/control"
echo "skipped=wait-40ms reason=rate_zero" >"$TMP/run/control/skipped.txt"
python3 "$SOAK/analyze-soak.py" "$TMP/run" >"$TMP/verdict4.json" 2>&1 || true
python3 - "$TMP/verdict4.json" <<'PY' || fail "a deliberately excluded profile was reported as a failure"
import json, sys
verdict = json.load(open(sys.argv[1]))
if any("wait-40ms" in r for r in verdict["reasons"]):
    print(f"the skipped profile still failed the run: {verdict['reasons']}", file=sys.stderr)
    raise SystemExit(1)
if verdict.get("skipped_workloads", {}).get("wait-40ms") != "rate_zero":
    print(f"the reason was not carried: {verdict.get('skipped_workloads')}", file=sys.stderr)
    raise SystemExit(1)
if verdict["workloads"]["wait-40ms"].get("skipped_reason") != "rate_zero":
    print("the workload row does not say why it is empty", file=sys.stderr)
    raise SystemExit(1)
PY
echo "PASS (soak): an absent profile is red unless the run recorded why it is absent"
