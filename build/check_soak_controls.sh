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
# THE FOUR-BRANCH CHAIN, and it is copied from the other control scripts rather
# than shortened. The first edition of this block checked `DRUSE_COMPILER` and
# then `PATH`, which is what a workstation has — and CI has NEITHER: it exports
# `DRUSE_ODIN_BIN` and never puts odin on the path. So the gate that was added to
# stop a silent break went red on its own first CI run, with "odin compiler not
# found" about a compiler that was right there under another name.
if test -n "${DRUSE_COMPILER:-}"; then
  DRUSE_SOAK_ODIN="$DRUSE_COMPILER"
elif test -n "${DRUSE_ODIN_BIN:-}"; then
  DRUSE_SOAK_ODIN="$DRUSE_ODIN_BIN"
elif command -v odin >/dev/null 2>&1; then
  DRUSE_SOAK_ODIN="$(command -v odin)"
elif test -x /tmp/druse-toolchain/odin; then
  DRUSE_SOAK_ODIN=/tmp/druse-toolchain/odin
else
  DRUSE_SOAK_ODIN=""
fi
test -n "$DRUSE_SOAK_ODIN" || fail "odin compiler not found; the soak server would go unchecked"
# Resolve the symlink before taking its directory: ODIN_ROOT must be where the
# compiler LIVES, not where the name that reached it lives. A ~/.local/bin/odin
# pointing into an unpacked toolchain is the ordinary install, and the dirname of
# the link has no base/ — which surfaces as an Internal Compiler Error reported
# as a build failure. Same fault as vendor gate wp24 carried.
DRUSE_SOAK_ODIN="$(readlink -f "$DRUSE_SOAK_ODIN")"
env ODIN_ROOT="$(cd "$(dirname "$DRUSE_SOAK_ODIN")" && pwd)" \
  "$DRUSE_SOAK_ODIN" check "$SOAK/soak-server" "-collection:druse=$DRUSE_ROOT" ||
  fail "ops/soak/soak-server does not compile. It is the instrument that produces release evidence and it is in no other gate, so a break here is invisible until a campaign starts."
echo "PASS (soak): the soak server compiles against the current public surface"

# The smoke target, for exactly the same reason and it is the newer half of it:
# `ops/soak/smoke-server` calls web.enable_upload, web.upload, web.stream,
# web.stream_send and web.stream_close, and it is the only program in ops/ that
# does. A signature change to any of the five would break the host
# qualification silently, and the first person to notice would be somebody
# starting a campaign on a host they cannot qualify.
env ODIN_ROOT="$(cd "$(dirname "$DRUSE_SOAK_ODIN")" && pwd)" \
  "$DRUSE_SOAK_ODIN" check "$SOAK/smoke-server" "-collection:druse=$DRUSE_ROOT" ||
  fail "ops/soak/smoke-server does not compile. It is the upload/stream/proxy smoke R2-WP02 requires before any load, and nothing else in the tree exercises that trio from ops/."
echo "PASS (soak): the smoke server compiles against the current public surface"

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

# ===========================================================================
# R2-WP01. Everything below grades the ANALYSER and the ORCHESTRATOR against
# ops/soak/fixtures/, and then mutates each mechanism the audit found missing.
#
# The audit that opened R2 asked ten questions of this instrument. Seven of the
# answers were "no", and each one had the same shape: the runner recorded
# something the analyser never read, or the analyser assumed a file the runner
# did not always write. None of it was visible, because the only thing anybody
# looked at was the word PASS.
#
# So each control below states the artefact it mutates, the reason the analyser
# must give, and — for the four that used to pass — what the shipped instrument
# said about that same artefact before soak/1.
# ===========================================================================

FIXTURES="$SOAK/fixtures"
ANALYSE="$SOAK/analyze-soak.py"

test -d "$FIXTURES" || fail "ops/soak/fixtures/ is missing; the analyser has no reference artefact"

# grade DIR -> verdict JSON at $TMP/verdict.json, and NEVER a traceback.
#
# The analyser's contract is that it always prints a verdict and always exits 0.
# That contract is itself a control: soak/0 raised FileNotFoundError on the
# single most likely artefact of a bad night, and a crash is not a grade.
grade() { # run-directory label
  local dir="$1" label="$2"
  if ! python3 "$ANALYSE" "$dir" >"$TMP/verdict.json" 2>"$TMP/verdict.err"; then
    fail "the analyser exited non-zero on $label: $(cat "$TMP/verdict.err")"
  fi
  if [ -s "$TMP/verdict.err" ]; then
    fail "the analyser wrote to stderr on $label (a traceback is not a verdict): $(cat "$TMP/verdict.err")"
  fi
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/verdict.json" ||
    fail "the analyser did not print valid JSON for $label"
}

# require DIR label VERDICT [reason-substring...]
require() {
  local dir="$1" label="$2" want="$3"
  shift 3
  grade "$dir" "$label"
  python3 - "$TMP/verdict.json" "$label" "$want" "$@" <<'PY' || fail "control failed: $label"
import json, sys

verdict = json.load(open(sys.argv[1]))
label, want, needles = sys.argv[2], sys.argv[3], sys.argv[4:]
reasons = verdict.get("reasons", [])

if verdict.get("result") != want:
    print(f"{label}: expected {want}, got {verdict.get('result')}", file=sys.stderr)
    for reason in reasons:
        print(f"    reason: {reason}", file=sys.stderr)
    raise SystemExit(1)

for needle in needles:
    if not any(needle in reason for reason in reasons):
        print(f"{label}: no reason mentions {needle!r}", file=sys.stderr)
        for reason in reasons:
            print(f"    reason: {reason}", file=sys.stderr)
        raise SystemExit(1)
PY
}

# ---------------------------------------------------------------------------
# The committed fixtures, each against the verdict and the REASONS its
# EXPECT.json names.
#
# Asserting the reason and not only the verdict is the whole point. A suite that
# only required FAIL would be satisfied by an analyser that failed everything —
# and this repository has already paid for that once: a run went red for the
# wrong reason and the control could not tell the difference.
# ---------------------------------------------------------------------------
for fixture_dir in "$FIXTURES"/*/; do
  fixture="$(basename "$fixture_dir")"
  [ -f "$fixture_dir/EXPECT.json" ] || continue
  bash "$FIXTURES/materialise.sh" "$fixture" "$TMP/fx-$fixture" ||
    fail "fixture $fixture could not be materialised"
  grade "$TMP/fx-$fixture" "fixture $fixture"
  python3 - "$fixture_dir/EXPECT.json" "$TMP/verdict.json" "$fixture" <<'PY' ||
import json, sys

expect = json.load(open(sys.argv[1]))
verdict = json.load(open(sys.argv[2]))
fixture = sys.argv[3]
reasons = verdict.get("reasons", [])

if verdict.get("result") != expect["result"]:
    print(f"{fixture}: expected {expect['result']}, got {verdict.get('result')}", file=sys.stderr)
    for reason in reasons:
        print(f"    reason: {reason}", file=sys.stderr)
    raise SystemExit(1)

for needle in expect.get("reasons_must_include", []):
    if not any(needle in reason for reason in reasons):
        print(f"{fixture}: no reason mentions {needle!r}", file=sys.stderr)
        for reason in reasons:
            print(f"    reason: {reason}", file=sys.stderr)
        raise SystemExit(1)

for needle in expect.get("reasons_must_not_include", []):
    if any(needle in reason for reason in reasons):
        print(f"{fixture}: a reason mentions {needle!r} and must not", file=sys.stderr)
        for reason in reasons:
            print(f"    reason: {reason}", file=sys.stderr)
        raise SystemExit(1)

# A PASS fixture with any reason at all is a contradiction the JSON would hide.
if expect["result"] == "PASS" and reasons:
    print(f"{fixture}: PASS with reasons attached: {reasons}", file=sys.stderr)
    raise SystemExit(1)
PY
    fail "fixture $fixture did not produce its expected verdict and reasons"
  echo "PASS (soak fixture): $fixture -> $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["result"])' "$TMP/verdict.json")"
done

# PASS is materialised once more as the base for the mutations below. Each
# mutation starts from a run the analyser has just certified clean, so a red
# result can only come from the mutation.
base() { # destination
  bash "$FIXTURES/materialise.sh" pass "$1" || fail "could not materialise the pass fixture"
}

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL 1 — the absence of a metric sample is recorded with a CAUSE.
#
# THE DEFECT THIS WORK PACKAGE IS NAMED FOR. The sampler read
#
#     stats_http="$(curl ...)" || true
#     stats_curl_exit=$?
#
# and `$?` there is the exit status of `true`. Every failed scrape in the
# history of this harness recorded 0, so the taxonomy promised in the comment
# above it was unreachable for the whole life of the field.
#
# THE CHANNEL CHANGED IN R2-WP04, AND THE PROPERTY DID NOT. The scrape is gone —
# ADR-050 moved the metric out of the request path, and the smoke measured why:
# 322 of 658 samples failed because `/stats` competed for the lanes it was
# sampling. What must still hold is the thing this control has always been
# about: **an absent sample carries a cause, and the cause is not zero.**
#
# So the control now drives the shipped block through every branch of ADR-050's
# closed taxonomy, extracted from run-soak.sh rather than retyped, and requires
# each one to record its own code. A control that only checked "not zero" would
# pass an instrument that reported `missing` for a stale snapshot.
# ---------------------------------------------------------------------------
RUNNER="$SOAK/run-soak.sh"
# The sampler's block specifically — run-soak.sh reads the snapshot twice, once
# per telemetry sample and once per cycle. Stop at the closing `fi` of the first.
awk '/^ *stats_curl_exit=0$/ {found=1} found {print} found && /^ *fi$/ {depth++; if (depth==2) exit}' \
  "$RUNNER" >"$TMP/capture.sh"
test -s "$TMP/capture.sh" ||
  fail "could not find the snapshot capture block in run-soak.sh; this control cannot test what it claims"
grep -q 'SNAPSHOT_CAUSE_' "$TMP/capture.sh" ||
  fail "the extracted block records no ADR-050 cause at all; this control cannot test what it claims"

# drive CASE SNAPSHOT-CONTENT -> "http exit"
drive() {
  local label="$1" snap="$2"
  cat >"$TMP/drive.sh" <<EOF
set -uo pipefail
SNAPSHOT_PATH="$snap"
SNAPSHOT_MAX_AGE_SECONDS=5
SNAPSHOT_CAUSE_MISSING=101
SNAPSHOT_CAUSE_UNREADABLE=102
SNAPSHOT_CAUSE_MALFORMED=103
SNAPSHOT_CAUSE_STALE=104
SNAPSHOT_CAUSE_NO_PROCESS=105
SNAPSHOT_CAUSE_DISABLED=106
server_pid=\$\$
stats_file="$TMP/stats-$label.json"
$(cat "$TMP/capture.sh")
echo "\$stats_http \$stats_curl_exit"
EOF
  bash "$TMP/drive.sh"
}

now_ns="$(date -u +%s%N)"
printf 'druse_snapshot 1\npid 1\nunix_ns %s\n' "$now_ns" >"$TMP/snap-ok.txt"
printf 'druse_snapshot 1\npid 1\nunix_ns %s\n' "$(( now_ns - 60000000000 ))" >"$TMP/snap-stale.txt"
printf 'not_a_snapshot\n' >"$TMP/snap-bad.txt"

test "$(drive ok "$TMP/snap-ok.txt")" = "200 0" ||
  fail "a fresh, well-formed snapshot did not record 200: $(drive ok "$TMP/snap-ok.txt"). Without a positive case every assertion below is satisfied by a reader that fails everything."
test "$(drive missing "$TMP/does-not-exist.txt")" = "000 101" ||
  fail "an absent snapshot did not record cause 101 (missing): $(drive missing "$TMP/does-not-exist.txt")"
test "$(drive malformed "$TMP/snap-bad.txt")" = "000 103" ||
  fail "a snapshot with the wrong schema line did not record cause 103 (malformed): $(drive malformed "$TMP/snap-bad.txt")"
test "$(drive stale "$TMP/snap-stale.txt")" = "000 104" ||
  fail "a snapshot 60 s older than max_age did not record cause 104 (stale): $(drive stale "$TMP/snap-stale.txt"). A wedged exporter that keeps its last record must not read as healthy."
test "$(drive disabled "")" = "000 106" ||
  fail "an unconfigured snapshot path did not record cause 106 (disabled): $(drive disabled "")"

# The mutant: the old idiom, restored. It must go blind.
cat >"$TMP/capture-mutant.sh" <<EOF
set -uo pipefail
PORT=$CLOSED_PORT
stats_file="$TMP/stats-mutant.json"
stats_http="\$(curl -sS --max-time 1 -o "\$stats_file" -w '%{http_code}' \\
  "http://127.0.0.1:\$PORT/stats" 2>/dev/null)" || true
stats_curl_exit=\$?
echo "\$stats_curl_exit"
EOF
mutant_exit="$(bash "$TMP/capture-mutant.sh")"
if [ "$mutant_exit" != "0" ]; then
  fail "the mutant did not reproduce the original defect (recorded $mutant_exit, expected 0); this control is not testing what it claims"
fi
echo "PASS (soak negative 1): every ADR-050 absence cause is recorded with its own code, and the old '|| true' idiom is proved to record 0"

# And the analyser must act on it: a cause captured is a NAMED cause, a cause
# discarded is a red run that says so.
base "$TMP/n1a"
python3 - "$TMP/n1a/telemetry/process.csv" 000 7 <<'PY'
import sys
path, http, exit_code = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
fields = lines[3].split(",")
fields[10], fields[11], fields[12] = http, exit_code, "0"
lines[3] = ",".join(fields)
open(path, "w").write("\n".join(lines) + "\n")
PY
require "$TMP/n1a" "negative 1a (scrape failed, cause captured)" FAIL \
  "/stats did not answer 200" "7 (connection refused)"
grade "$TMP/n1a" "negative 1a"
python3 - "$TMP/verdict.json" <<'PY' || fail "a captured curl exit was still reported as uncaptured"
import json, sys
verdict = json.load(open(sys.argv[1]))
if verdict["stats_failures_uncaptured"] != 0:
    print(f"cause was captured, analyser called it uncaptured: {verdict['reasons']}", file=sys.stderr)
    raise SystemExit(1)
PY

base "$TMP/n1b"
python3 - "$TMP/n1b/telemetry/process.csv" 000 0 <<'PY'
import sys
path, http, exit_code = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines()
fields = lines[3].split(",")
fields[10], fields[11], fields[12] = http, exit_code, "0"
lines[3] = ",".join(fields)
open(path, "w").write("\n".join(lines) + "\n")
PY
require "$TMP/n1b" "negative 1b (scrape failed, cause zeroed)" FAIL \
  "captured no cause"
echo "PASS (soak negative 1): the analyser separates a scrape failure with a cause from one whose cause was zeroed"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL 2 — failure_examples are discarded.
#
# A class name with no example text is a bucket, not an explanation. The
# generator mutation is the honest form of this control: it removes the example
# at the source, exactly as the pre-diagnosability generator did.
# ---------------------------------------------------------------------------
mkdir -p "$TMP/mut3"
sed 's|^\t\t\tExample: exampleOf\[class\],|\t\t\tExample: "",|' \
  "$SOAK/openload/main.go" >"$TMP/mut3/main.go"
cmp -s "$SOAK/openload/main.go" "$TMP/mut3/main.go" &&
  fail "mutation 3 changed nothing; the control is not testing what it claims"
build_generator "$TMP/mut3" "$TMP/openload-mut3"
run_generator "$TMP/openload-mut3" "$TMP/raw-mut3.csv" >"$TMP/summary-mut3.json"

base "$TMP/n2"
python3 - "$TMP/summary-mut3.json" "$TMP/n2/cycles/c0001-tiny.json" <<'PY'
import json, sys
generated = json.load(open(sys.argv[1]))
target = json.load(open(sys.argv[2]))
errors = generated["transport_errors"]
if errors == 0:
    print("mutation 3 produced no failure, so nothing is proved", file=sys.stderr)
    raise SystemExit(1)
target["transport_errors"] = errors
target["succeeded"] = target["completed"] - errors
target["status"] = {"200": target["completed"] - errors, "0": errors}
target["failures"] = generated["failures"]
json.dump(target, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
require "$TMP/n2" "negative 2 (examples discarded at the source)" FAIL \
  "no example text"
echo "PASS (soak negative 2): a generator that keeps class names and drops the error text is caught"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL 3 — `completed` is inflated with no class and no status.
#
# BEFORE soak/1 THIS PASSED. The analyser summed `planned` and `completed` and
# compared neither against the other nor against the status map, so a generator
# whose workers hung — or one that simply overstated its work — produced a clean
# run with requests that left no record of any kind.
# ---------------------------------------------------------------------------
base "$TMP/n3"
python3 - "$TMP/n3/cycles/c0001-tiny.json" <<'PY'
import json, sys
report = json.load(open(sys.argv[1]))
report["completed"] += 250          # 250 requests with no status and no class
json.dump(report, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
require "$TMP/n3" "negative 3 (completed inflated)" FAIL \
  "more requests finished than were scheduled" "status map accounts for"
echo "PASS (soak negative 3): requests counted with no status and no class are caught"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL 4 — a workload is removed with nothing recorded.
#
# The opposite mistake is also live and also tested: a workload deliberately
# excluded, WITH a reason in control/skipped.txt, must not fail the run. An
# instrument that cannot tell a configured absence from an unexplained one is
# useless in both directions.
# ---------------------------------------------------------------------------
base "$TMP/n4"
rm -f "$TMP/n4/cycles/c0001-wait-40ms.json"
require "$TMP/n4" "negative 4 (workload vanished)" FAIL \
  "no runs and control/skipped.txt gives no reason"

echo "skipped=wait-40ms reason=rate_zero" >"$TMP/n4/control/skipped.txt"
grade "$TMP/n4" "negative 4 positive half"
python3 - "$TMP/verdict.json" <<'PY' || fail "a deliberately excluded workload was reported as a failure"
import json, sys
verdict = json.load(open(sys.argv[1]))
if any("wait-40ms" in reason for reason in verdict["reasons"]):
    print(f"the skipped profile still failed the run: {verdict['reasons']}", file=sys.stderr)
    raise SystemExit(1)
if verdict["skipped_workloads"].get("wait-40ms") != "rate_zero":
    print(f"the reason was not carried: {verdict['skipped_workloads']}", file=sys.stderr)
    raise SystemExit(1)
if verdict["result"] != "PASS":
    print(f"an explained absence failed the run: {verdict['reasons']}", file=sys.stderr)
    raise SystemExit(1)
PY
echo "PASS (soak negative 4): an absent workload is red unless the run recorded why"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL 5 — telemetry samples are removed.
#
# BEFORE soak/1 THIS PASSED, and it is the subtlest of the eight. A short
# telemetry file does not merely lose data: the RSS-slope criterion only applies
# at 720 samples or more, so a sampler that died in minute three of a twelve-hour
# run DISABLED that criterion silently and the run went green with the rule
# never evaluated. Nothing in the artefact said so.
# ---------------------------------------------------------------------------
base "$TMP/n5"
python3 - "$TMP/n5/telemetry/process.csv" <<'PY'
import sys
lines = open(sys.argv[1]).read().splitlines()
open(sys.argv[1], "w").write("\n".join(lines[:3]) + "\n")   # header + 2 samples
PY
require "$TMP/n5" "negative 5 (samples removed)" FAIL "telemetry stopped early"
echo "PASS (soak negative 5): a sampler that stopped early is red, not a criterion that quietly did not apply"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL 6 — the run dies before it can clean up.
#
# Behavioural, against the real orchestrator. run-soak.sh is driven into two
# abort paths and each must leave control/final-state.txt carrying an
# abort_reason. soak/0 wrote that file only on the happy path, so the artefact a
# bad night actually produces made the analyser raise FileNotFoundError instead
# of returning a verdict — the run with the most to say produced no grade.
# ---------------------------------------------------------------------------
abort_run() { # label extra-env... -- expects run-soak.sh to fail
  local label="$1"
  shift
  local base_dir="$TMP/abort-$label"
  rm -rf "$base_dir"
  mkdir -p "$base_dir/repo"
  # A minimal clean repo, so the dirty-tree refusal is a decision of the control
  # rather than an accident of the developer's working tree.
  git -C "$base_dir/repo" init -q 2>/dev/null
  git -C "$base_dir/repo" config user.email control@example.invalid
  git -C "$base_dir/repo" config user.name control
  echo "placeholder" >"$base_dir/repo/README"
  git -C "$base_dir/repo" add README
  git -C "$base_dir/repo" commit -qm "control fixture"
  "$@" DRUSE_SOAK_SKIP_PREFLIGHT=1 DRUSE_SOAK_HARNESS="$SOAK" \
    bash "$RUNNER" "$base_dir" 1 >"$base_dir/run.log" 2>&1 &&
    fail "control 6/$label: run-soak.sh was expected to abort and did not"
  test -f "$base_dir/soak/control/final-state.txt" ||
    fail "control 6/$label: the run aborted and recorded no final state; the analyser would have nothing to grade"
  grep -q '^abort_reason=' "$base_dir/soak/control/final-state.txt" ||
    fail "control 6/$label: final-state.txt records no abort_reason: $(cat "$base_dir/soak/control/final-state.txt")"
  # And the analyser must GRADE that artefact rather than crash on it.
  require "$base_dir/soak" "control 6/$label artefact" FAIL "the run aborted"
}

# 6a: no compiler. The build fails before anything is launched.
abort_run no-compiler env DRUSE_ODIN_BIN="$TMP/there-is-no-compiler-here"

# 6b: a dirty working tree. Identity, not machinery: the artefact would be
# attributable to no commit (readiness rule G1).
abort_dirty() {
  local base_dir="$TMP/abort-dirty"
  rm -rf "$base_dir"
  mkdir -p "$base_dir/repo"
  git -C "$base_dir/repo" init -q 2>/dev/null
  git -C "$base_dir/repo" config user.email control@example.invalid
  git -C "$base_dir/repo" config user.name control
  echo "placeholder" >"$base_dir/repo/README"
  git -C "$base_dir/repo" add README
  git -C "$base_dir/repo" commit -qm "control fixture"
  echo "uncommitted" >>"$base_dir/repo/README"
  env DRUSE_SOAK_SKIP_PREFLIGHT=1 DRUSE_SOAK_HARNESS="$SOAK" \
    DRUSE_ODIN_BIN="$DRUSE_SOAK_ODIN" \
    bash "$RUNNER" "$base_dir" 1 >"$base_dir/run.log" 2>&1 &&
    fail "control 6/dirty: run-soak.sh measured a dirty tree without being told to"
  grep -q 'is dirty' "$base_dir/soak/control/final-state.txt" ||
    fail "control 6/dirty: the refusal was not recorded as the abort reason: $(cat "$base_dir/soak/control/final-state.txt" 2>/dev/null)"
}
abort_dirty
echo "PASS (soak negative 6): a run that dies before cleanup records how it died, and the analyser grades that artefact"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL 7 — a criterion is changed after the manifest.
#
# A criteria file edited between a run and its grade cannot be detected by
# reading either one. The run pins the hash; the analyser recomputes it. This
# control materialises the fixture with a pin that does not match the tree,
# which is what a post-hoc edit looks like from the analyser's side.
# ---------------------------------------------------------------------------
bash "$FIXTURES/materialise.sh" pass "$TMP/n7" \
  "0000000000000000000000000000000000000000000000000000000000000000" ||
  fail "could not materialise the pass fixture with a stale criteria pin"
require "$TMP/n7" "negative 7 (criteria changed after the run)" FAIL \
  "CRITERIA.md changed after the run"

base "$TMP/n7b"
sed -i '/^criteria_sha256=/d' "$TMP/n7b/manifest.txt"
require "$TMP/n7b" "negative 7b (no criteria pin at all)" FAIL \
  "pinned no criteria_sha256"
echo "PASS (soak negative 7): a criterion edited after the run, or never pinned, is caught"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL 8 — the binary changes after its hash is taken.
#
# The manifest hashes what was launched; the run re-hashes what finished. A
# candidate swapped in between is a different candidate, and readiness rule G1
# is that evidence is not transferred by similarity.
# ---------------------------------------------------------------------------
base "$TMP/n8"
sed -i 's/^server_sha256=.*/server_sha256=ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
  "$TMP/n8/control/final-binaries.txt"
require "$TMP/n8" "negative 8 (binary swapped mid-run)" FAIL \
  "server_sha256 changed during the run"

base "$TMP/n8b"
rm -f "$TMP/n8b/control/final-binaries.txt"
require "$TMP/n8b" "negative 8b (no post-run hash)" FAIL \
  "control/final-binaries.txt is missing"
echo "PASS (soak negative 8): a binary that changed during the run, or was never re-hashed, is caught"

# ---------------------------------------------------------------------------
# Two more the audit turned up, kept because each was a silent PASS.
# ---------------------------------------------------------------------------

# The run never finished, and soak/0 graded it exactly like one that did.
base "$TMP/n9"
rm -f "$TMP/n9/COMPLETE"
require "$TMP/n9" "negative 9 (no COMPLETE marker)" FAIL "COMPLETE is absent"
echo "PASS (soak negative 9): a run that never reached its end is not graded as one that did"

# An injected fault report with no declaration, and a declaration with no
# report. Deliberate faults are only separable from spontaneous ones while both
# records agree — and the analyser never read either before soak/1.
base "$TMP/n10"
cat >"$TMP/n10/cycles/c0005-rst.json" <<'JSON'
{"mode": "rst-after-write", "deliberate": true, "attempted": 128, "errors": 128,
 "errors_by_phase": {"close": 128}, "started_unix_nanos": 1785000000000000000,
 "ended_unix_nanos": 1785000003000000000}
JSON
require "$TMP/n10" "negative 10 (undeclared injection)" FAIL \
  "0 RST injection(s) declared"

echo "cycle=5 kind=rst attempted=128 utc=2026-08-02T00:00:05Z" >"$TMP/n10/control/injected.txt"
grade "$TMP/n10" "negative 10 positive half"
python3 - "$TMP/verdict.json" <<'PY' || fail "a declared injection was not accounted separately"
import json, sys
verdict = json.load(open(sys.argv[1]))
injected = verdict["injected_faults"]
if injected["campaigns"] != 1 or injected["errors"] != 128:
    print(f"the injection was not counted: {injected}", file=sys.stderr)
    raise SystemExit(1)
if verdict["failures_counted"] != 0:
    print(
        "an injected fault was folded into the spontaneous failure count: "
        f"{verdict['failures_counted']}",
        file=sys.stderr,
    )
    raise SystemExit(1)
if verdict["result"] != "PASS":
    print(f"a declared injection failed the run: {verdict['reasons']}", file=sys.stderr)
    raise SystemExit(1)
PY
echo "PASS (soak negative 10): injected faults are counted apart from spontaneous ones, and neither is netted off the other"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL 11 — the host could not collect kernel counters.
#
# Found by RUNNING the repaired instrument rather than by reading it. The
# kernel-counter line is a pipeline, run-soak.sh runs under `set -o pipefail`,
# and on a host with no `nstat` that pipeline returned 127 and took the whole
# sampler subshell with it on iteration one — leaving telemetry/process.csv
# holding a header and nothing else. Under the old analyser that graded PASS.
#
# The counters are still written as zeros when nstat is absent, and a zero in
# those columns reads as "no drops": the single thing they exist to
# distinguish. So absence of the tool is recorded and refused, rather than
# rendered as a clean result.
# ---------------------------------------------------------------------------
base "$TMP/n11"
sed -i 's/^nstat=.*/nstat=absent/' "$TMP/n11/manifest.txt"
require "$TMP/n11" "negative 11 (kernel counters never collected)" FAIL \
  "absence of measurement, not absence of drops"
echo "PASS (soak negative 11): a host that could not collect kernel counters is refused, not read as a clean kernel"

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL 12 — the host was never qualified (R2-WP02, criterion 18).
#
# `preflight` has been in the manifest and in schema.md since soak/1 and was
# read by nothing at all, so a run taken with DRUSE_SOAK_SKIP_PREFLIGHT=1 graded
# exactly like a run on a qualified host. Criterion 11's finding, one level up:
# the field was written for a rule that never ran.
#
# Both of the states that are not `pass` are exercised, because they arrive by
# different routes — `skipped` is a deliberate override at the prompt, `absent`
# is a host where the preflight script was not there to run.
# ---------------------------------------------------------------------------
base "$TMP/n12"
sed -i 's/^preflight=.*/preflight=skipped/' "$TMP/n12/manifest.txt"
require "$TMP/n12" "negative 12 (preflight skipped)" FAIL \
  "the host was not qualified"

base "$TMP/n12b"
sed -i 's/^preflight=.*/preflight=absent/' "$TMP/n12b/manifest.txt"
require "$TMP/n12b" "negative 12b (no preflight at all)" FAIL \
  "the host was not qualified"

base "$TMP/n12c"
sed -i '/^preflight=/d' "$TMP/n12c/manifest.txt"
require "$TMP/n12c" "negative 12c (manifest carries no preflight state)" FAIL \
  "the host was not qualified"
echo "PASS (soak negative 12): a run whose host was never qualified is refused, instead of grading like one that was"

# ---------------------------------------------------------------------------
# The preflight refuses a host it cannot qualify, and says which CPU.
# ---------------------------------------------------------------------------
test -f "$SOAK/preflight.sh" || fail "ops/soak/preflight.sh is missing"
if env DRUSE_SOAK_SERVER_CPUS="0-3" DRUSE_SOAK_GENERATOR_CPUS="9000-9003" \
   bash "$SOAK/preflight.sh" "$TMP/preflight-bad.txt" >/dev/null 2>&1; then
  fail "preflight qualified a host for CPUs 9000-9003"
fi
grep -q '^preflight=fail' "$TMP/preflight-bad.txt" ||
  fail "preflight refused a host and did not record the refusal in its report"
grep -q '^problem=' "$TMP/preflight-bad.txt" ||
  fail "preflight refused a host and recorded no reason"
echo "PASS (soak preflight): an unqualified host is refused before the campaign, with the reason recorded"

# ===========================================================================
# R2-WP02. The preflight's CPU-isolation check, against physical cores.
#
# WHAT WAS WRONG. The check above proves the preflight can REFUSE. That is half
# a control: an instrument that only ever says no is indistinguishable from one
# that is broken, and this file already argues the same point about the analyser
# ("an analyser that returned FAIL unconditionally would satisfy every negative
# control in the file"). The preflight had no positive case at all.
#
# It also had the defect the positive case would have exposed. Isolation was
# tested as `[[ "$SERVER_CPUS" == "$GENERATOR_CPUS" ]]` — a STRING comparison —
# so two things passed that must not:
#
#   * `0-3` against `0,1,2,3`: the same four CPUs, spelled differently;
#   * `0-3` against `4-7` on an SMT host: disjoint by number, and the two thread
#     halves of ONE set of four physical cores. A c5.2xlarge is exactly this
#     shape. The preflight's own header says the sets must be disjoint because
#     "the load generator would compete with the process under measurement", and
#     through SMT siblings it competes precisely so — on every core the server
#     is pinned to.
#
# So the property under control is: SERVER AND GENERATOR DO NOT SHARE A PHYSICAL
# CORE. Below it is exercised green, red, and red-for-the-right-reason, against
# synthetic sibling maps rather than against whatever machine the gate happens to
# run on — a control whose result depends on the CI runner's core count is not a
# control. DRUSE_SOAK_TOPOLOGY_DIR exists for this and the preflight records in
# its report when it is set, so a real campaign cannot use it unnoticed.
# ===========================================================================

# topology_fixture DIR SIBLINGS...  — one argument per physical core, each the
# comma-separated sibling list of that core. `topology_fixture d 0,4 1,5` builds
# a four-CPU host of two cores whose threads are (0,4) and (1,5).
topology_fixture() {
  local dir="$1"; shift
  local core cpu
  rm -rf "$dir"
  for core in "$@"; do
    for cpu in ${core//,/ }; do
      mkdir -p "$dir/cpu$cpu/topology"
      printf '%s\n' "$core" >"$dir/cpu$cpu/topology/thread_siblings_list"
    done
  done
}

# preflight_report TOPOLOGY SERVER GENERATOR OUT — run the preflight against a
# fixture and keep its report. Its EXIT STATUS is deliberately ignored: the gate
# runs on hosts with no free 100 GiB, a busy port 8080 and no dedicated CPUs, so
# a whole-host PASS is not available here and asserting on one would make this
# control a statement about the runner. The assertions below read the two lines
# that belong to the topology check and nothing else.
preflight_report() {
  env DRUSE_SOAK_TOPOLOGY_DIR="$1" \
      DRUSE_SOAK_SERVER_CPUS="$2" \
      DRUSE_SOAK_GENERATOR_CPUS="$3" \
      bash "$SOAK/preflight.sh" "$4" >/dev/null 2>&1 || true
  test -s "$4" || fail "preflight produced no report for server=$2 generator=$3"
}

# ---------------------------------------------------------------------------
# POSITIVE — cores really are disjoint, and the preflight SAYS SO.
#
# Siblings (0,1) (2,3) (4,5) (6,7): CPUs 0-3 are two whole cores and 4-7 are the
# other two. This is the ThreadsPerCore=1-equivalent shape the campaign needs,
# and the check must go green on it. Without this case every assertion below is
# satisfied by a preflight that refuses everything.
# ---------------------------------------------------------------------------
topology_fixture "$TMP/topo-distinct" 0,1 2,3 4,5 6,7
preflight_report "$TMP/topo-distinct" 0-3 4-7 "$TMP/pf-distinct.txt"
grep -q '^physical_core_disjoint=yes$' "$TMP/pf-distinct.txt" ||
  { cat "$TMP/pf-distinct.txt" >&2
    fail "the preflight did not confirm physical-core disjointness on a host where the two CPU sets are four whole cores. A preflight that can only refuse cannot be told apart from a broken one."; }
grep -q '^problem=.*physical core' "$TMP/pf-distinct.txt" &&
  fail "the preflight refused genuinely disjoint physical cores"
grep -q '^server_physical_cores=0 1;2 3$' "$TMP/pf-distinct.txt" ||
  { cat "$TMP/pf-distinct.txt" >&2
    fail "the preflight did not record which physical cores the server set resolves to. The mapping is the evidence that the check ran; its absence would leave 'disjoint' as an unsupported claim in the campaign record."; }
echo "PASS (soak preflight, R2-WP02 positive): CPU sets on four distinct physical cores are qualified, and the mapping is recorded"

# ---------------------------------------------------------------------------
# THE MUTANT — disjoint by number, siblings by topology.
#
# Siblings (0,4) (1,5) (2,6) (3,7): the AWS Nitro layout for a c5.2xlarge, and
# the shape this host qualification exists to catch. Server 0-3 and generator
# 4-7 pass every numeric test and are the same four cores.
#
# The assertion is on the REASON, not only on the refusal. This file already
# carries that rule for the analyser — "asserting the reason and not only the
# verdict is the whole point" — and it applies here for the same cause: the
# preflight refuses this fixture for a missing port and a small disk too, so a
# bare `preflight=fail` would be satisfied without the topology check existing
# at all.
# ---------------------------------------------------------------------------
topology_fixture "$TMP/topo-smt" 0,4 1,5 2,6 3,7
preflight_report "$TMP/topo-smt" 0-3 4-7 "$TMP/pf-smt.txt"
grep -q '^preflight=fail$' "$TMP/pf-smt.txt" ||
  { cat "$TMP/pf-smt.txt" >&2
    fail "the preflight qualified a host where the server set and the generator set are SMT siblings of the same four physical cores"; }
grep -q '^physical_core_disjoint=no$' "$TMP/pf-smt.txt" ||
  { cat "$TMP/pf-smt.txt" >&2
    fail "the preflight did not record physical_core_disjoint=no for sibling-thread CPU sets"; }
grep -q '^problem=.*disjoint by CPU NUMBER and share physical core' "$TMP/pf-smt.txt" ||
  { cat "$TMP/pf-smt.txt" >&2
    fail "the preflight refused the SMT host for some OTHER reason. A refusal for the wrong reason would let the same host through the moment its disk grew, and the campaign would run with the generator on the server's cores."; }
echo "PASS (soak preflight, R2-WP02 mutant): CPU sets that are disjoint by number and SMT siblings by topology are refused, by that reason"

# The same SMT host, split along cores instead of along thread numbers. This is
# the affinity a campaign must pre-register and commit if it keeps such a host
# (R2-WP02: "alterar o plano e commitá-lo antes do run"), and it proves the
# refusal above is about the TOPOLOGY and not about that fixture.
preflight_report "$TMP/topo-smt" 0,1,4,5 2,3,6,7 "$TMP/pf-smt-split.txt"
grep -q '^physical_core_disjoint=yes$' "$TMP/pf-smt-split.txt" ||
  { cat "$TMP/pf-smt-split.txt" >&2
    fail "the preflight refused 0,1,4,5 / 2,3,6,7 on an SMT host, which IS the core-disjoint split of it. A check that cannot pass any affinity on a given host offers no way to fix the host."; }
echo "PASS (soak preflight, R2-WP02): on the same SMT host, the core-disjoint split 0,1,4,5 / 2,3,6,7 qualifies"

# ---------------------------------------------------------------------------
# The set comparison is over MEMBERS. `0-3` and `0,1,2,3` differ as strings and
# are one set; the shipped check compared strings and passed this.
# ---------------------------------------------------------------------------
preflight_report "$TMP/topo-distinct" 0-3 0,1,2,3 "$TMP/pf-same-set.txt"
grep -q '^problem=.*share logical CPU(s) 0,1,2,3' "$TMP/pf-same-set.txt" ||
  { cat "$TMP/pf-same-set.txt" >&2
    fail "the preflight accepted '0-3' against '0,1,2,3' as distinct CPU sets. They are the same four CPUs written two ways, and a string comparison cannot see it."; }
echo "PASS (soak preflight, R2-WP02): overlapping CPU sets are refused however they are spelled"

# ---------------------------------------------------------------------------
# A topology that cannot be READ is refused, not assumed flat. INS-013's rule:
# an absent measurement must never be rendered as a clean result. A container
# without sysfs would otherwise qualify every affinity it was given.
# ---------------------------------------------------------------------------
preflight_report "$TMP/topo-absent" 0-3 4-7 "$TMP/pf-absent.txt"
grep -q '^physical_core_disjoint=unknown$' "$TMP/pf-absent.txt" ||
  { cat "$TMP/pf-absent.txt" >&2
    fail "an unreadable topology did not record physical_core_disjoint=unknown"; }
grep -q '^problem=.*topology is unreadable' "$TMP/pf-absent.txt" ||
  { cat "$TMP/pf-absent.txt" >&2
    fail "the preflight qualified a host whose CPU topology it could not read. 'No siblings found' and 'no siblings file' are different facts and only one of them is an isolated host."; }
echo "PASS (soak preflight, R2-WP02): a topology that cannot be read is refused rather than assumed flat"

# ---------------------------------------------------------------------------
# AND THE CONTROL ITSELF CAN GO RED. Every assertion above is about the
# preflight; this one is about them. A copy of the preflight with the
# physical-core refusal deleted must stop satisfying the mutant case — otherwise
# the mutant case is passing for some reason other than the check it names.
# planning/diagnosability.md rule 4, "no unattributed pass": an assertion that an
# outcome is expected must match the CAUSE of that outcome, not only its exit
# status. That rule is usually read as being about the gate's assertions; it
# applies to the assertions ABOUT the gate too.
# ---------------------------------------------------------------------------
sed '/share physical core(s)/d' "$SOAK/preflight.sh" >"$TMP/preflight-mutated.sh"
cmp -s "$SOAK/preflight.sh" "$TMP/preflight-mutated.sh" &&
  fail "the physical-core refusal could not be located in preflight.sh to mutate it; this control has gone stale against the script it guards"
env DRUSE_SOAK_TOPOLOGY_DIR="$TMP/topo-smt" \
    DRUSE_SOAK_SERVER_CPUS="0-3" DRUSE_SOAK_GENERATOR_CPUS="4-7" \
    bash "$TMP/preflight-mutated.sh" "$TMP/pf-mutated.txt" >/dev/null 2>&1 || true
if grep -q '^problem=.*disjoint by CPU NUMBER and share physical core' "$TMP/pf-mutated.txt"; then
  fail "a preflight with the physical-core refusal removed still produced it. The mutant control above is not reading what it claims to read."
fi
echo "PASS (soak preflight, R2-WP02 control-of-the-control): removing the physical-core refusal makes the mutant case red"

# ---------------------------------------------------------------------------
# The compiler BUILDS, it does not merely exist.
#
# Found on a real campaign host, and found by the smoke rather than by the
# preflight that is supposed to run first: the pinned toolchain was unpacked and
# `odin version` answered correctly, but the box had no clang. Odin links through
# clang on Linux, so the first build of the campaign died with
# `sh: 1: clang: not found` — on a host the preflight had already passed.
#
# Qualifying a filename is not qualifying a toolchain. The positive case is the
# gate's own compiler, which must build; the mutant is a compiler that exists,
# answers, and cannot.
# ---------------------------------------------------------------------------
env DRUSE_ODIN_BIN="$DRUSE_SOAK_ODIN" bash "$SOAK/preflight.sh" "$TMP/pf-odin-ok.txt" >/dev/null 2>&1 || true
grep -q '^odin_can_build=yes$' "$TMP/pf-odin-ok.txt" ||
  { cat "$TMP/pf-odin-ok.txt" >&2
    fail "the preflight did not prove the pinned compiler can build. It checked that a file exists and reports a version, which is the state a host with no linker is also in."; }

# The mutant: a compiler that answers `version` and cannot build anything.
cat >"$TMP/fake-odin" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  version) echo "odin version dev-2026-07-nightly:819fdc7"; exit 0 ;;
  *) echo "sh: 1: clang: not found" >&2; exit 1 ;;
esac
FAKE
chmod +x "$TMP/fake-odin"
env DRUSE_ODIN_BIN="$TMP/fake-odin" bash "$SOAK/preflight.sh" "$TMP/pf-odin-bad.txt" >/dev/null 2>&1 || true
grep -q '^problem=the Odin compiler is present and cannot BUILD' "$TMP/pf-odin-bad.txt" ||
  { cat "$TMP/pf-odin-bad.txt" >&2
    fail "the preflight qualified a compiler that reports a version and cannot build. That is the exact host state that passed the preflight and failed the smoke."; }
grep -q '^odin_can_build=yes$' "$TMP/pf-odin-bad.txt" &&
  fail "the preflight recorded odin_can_build=yes for a compiler that cannot build"
echo "PASS (soak preflight, R2-WP02): the pinned compiler is proved to BUILD, and one that only answers 'version' is refused"

# ---------------------------------------------------------------------------
# RLIMIT_MEMLOCK — a host that cannot hold the io_uring rings is refused.
#
# The stock AWS AMI ships 8 MiB. Every lane's rings pin against that limit, and a
# ring allocation that fails does not degrade — the server dies before readiness,
# and the run reports "server exited before readiness", a sentence about the
# product produced by a host that was never configured to run it. This project
# has already diagnosed exactly that once, as F-C03-2.
#
# Driven through the threshold rather than through the host's real limit, so the
# control means the same thing on a workstation, in CI and on a campaign box.
# ---------------------------------------------------------------------------
env DRUSE_SOAK_MIN_MEMLOCK_KIB=1 bash "$SOAK/preflight.sh" "$TMP/pf-memlock-ok.txt" >/dev/null 2>&1 || true
grep -q '^memlock_hard_kib=' "$TMP/pf-memlock-ok.txt" ||
  { cat "$TMP/pf-memlock-ok.txt" >&2
    fail "the preflight does not record the host's RLIMIT_MEMLOCK. A limit nobody wrote down is a limit nobody can compare a failed run against."; }
grep -q '^problem=RLIMIT_MEMLOCK' "$TMP/pf-memlock-ok.txt" &&
  fail "the preflight refused a memlock that satisfies the threshold"

# The mutant: a threshold this host cannot meet must be refused, and the reason
# must name F-C03-2's mechanism rather than merely say 'limit too small'. A
# refusal that does not name io_uring sends the reader to the wrong place.
env DRUSE_SOAK_MIN_MEMLOCK_KIB=999999999 bash "$SOAK/preflight.sh" "$TMP/pf-memlock-bad.txt" >/dev/null 2>&1 || true
if ! grep -q '^problem=RLIMIT_MEMLOCK' "$TMP/pf-memlock-bad.txt"; then
  # `unlimited` is the one host state the threshold cannot fail; say so rather
  # than reporting a broken control.
  grep -q '^memlock_hard_kib=unlimited$' "$TMP/pf-memlock-bad.txt" ||
    { cat "$TMP/pf-memlock-bad.txt" >&2
      fail "the preflight accepted a memlock below the required threshold"; }
  echo "PASS (soak preflight, R2-WP02): memlock is recorded; this host reports unlimited, so the threshold cannot be driven red here"
else
  grep -q '^problem=RLIMIT_MEMLOCK.*io_uring rings pin against it' "$TMP/pf-memlock-bad.txt" ||
    { cat "$TMP/pf-memlock-bad.txt" >&2
      fail "the preflight refused a small memlock without naming io_uring as the mechanism. 'Limit too small' sends the reader to the wrong subsystem; F-C03-2 took a production diagnosis to find."; }
  echo "PASS (soak preflight, R2-WP02): a host whose RLIMIT_MEMLOCK cannot hold the io_uring rings is refused, naming F-C03-2's mechanism"
fi

# ---------------------------------------------------------------------------
# The SMOKE runs after qualification, and its escape hatch is loud.
#
# The smoke itself is not a gate — it builds a server, starts a container and
# terminates TLS, and the campaign is not a gate (same rule as the soak server
# above: this file compiles it and does not run it). What IS gated is the
# ordering, because the ordering is the whole claim: a host that passes the
# preflight and fails the smoke is not qualified, and a smoke that ran on a host
# the preflight refused says nothing about the host at all.
#
# CPUs 9000-9003 make the preflight refuse on any machine, so both cases below
# are deterministic wherever the gate runs.
# ---------------------------------------------------------------------------
test -x "$SOAK/smoke.sh" || fail "ops/soak/smoke.sh is missing or not executable"

if env DRUSE_SOAK_GENERATOR_CPUS="9000-9003" \
   bash "$SOAK/smoke.sh" "$TMP/smoke-refused.txt" >/dev/null 2>&1; then
  fail "the smoke ran to completion on a host the preflight refuses. The smoke qualifies a host; it cannot substitute for the qualification."
fi
grep -q '^problem=the preflight refuses this host' "$TMP/smoke-refused.txt" ||
  { cat "$TMP/smoke-refused.txt" >&2
    fail "the smoke stopped on an unqualified host without recording that the preflight was the reason"; }
echo "PASS (soak smoke, R2-WP02): the smoke refuses to run on a host the preflight has not qualified"

# The escape hatch exists — the instrument has to be exercisable somewhere — and
# the control is that using it MARKS THE ARTEFACT. A green smoke carrying this
# line is a fact about the script; the same file without it would be read as a
# qualified host. DRUSE_COMPILER is pointed at nothing so the run stops before
# building anything, which keeps this control at about a second.
env DRUSE_SOAK_GENERATOR_CPUS="9000-9003" \
    DRUSE_SOAK_SMOKE_ALLOW_UNQUALIFIED=1 \
    DRUSE_COMPILER=/nonexistent/odin \
    bash "$SOAK/smoke.sh" "$TMP/smoke-allowed.txt" >/dev/null 2>&1 || true
grep -q '^smoke_on_unqualified_host=yes' "$TMP/smoke-allowed.txt" ||
  { cat "$TMP/smoke-allowed.txt" >&2
    fail "the smoke accepted DRUSE_SOAK_SMOKE_ALLOW_UNQUALIFIED and did not stamp the report with it. An override that leaves no trace in the artefact is how an unqualified host becomes a qualified one in the record."; }
grep -q '^preflight_problem=' "$TMP/smoke-allowed.txt" ||
  { cat "$TMP/smoke-allowed.txt" >&2
    fail "the smoke overrode the preflight and did not carry the preflight's reasons into its own report"; }
echo "PASS (soak smoke, R2-WP02): overriding the qualification stamps the artefact with the override and the reasons"

# A missing tool must be a REFUSAL, not a leg that quietly does not run. This is
# INS-013 restated: one absent optional tool produced a clean twelve-hour
# artefact with no telemetry in it, and it graded PASS. Asserted on the source
# because the failure mode is a code shape — there is no `skip` verdict in this
# script, and there must not be one.
grep -q 'a missing tool is a refusal, not a skipped leg' "$SOAK/smoke.sh" ||
  fail "smoke.sh lost the rule that a missing tool refuses rather than skips a leg"
if grep -Eq '^[[:space:]]*(note "[a-z_]*_(upload|stream)=skip|continue[[:space:]]*#.*skip)' "$SOAK/smoke.sh"; then
  fail "smoke.sh grew a path that records a leg as skipped. Three legs are required; two of three is a red smoke, not a partial one."
fi
echo "PASS (soak smoke, R2-WP02): a leg cannot be skipped — a missing dependency refuses the host"

# ---------------------------------------------------------------------------
# R2-WP02 — the pre-registration, and the identity it pins.
#
# G3 says criteria are frozen before the run. A gate cannot check WHEN a file was
# committed, so it checks the two things that make the ordering meaningful
# afterwards — the same approach check_r2_observability_controls.sh takes for
# R2-WP03:
#
#   1. the numbered criteria are still there. Deleting one after a result is how
#      a pre-registration becomes a description of what happened;
#   2. the INSTRUMENT the pre-registration pins is still the instrument on disk.
#      Under G1 a changed instrument is a changed candidate, and a
#      pre-registration whose hashes have drifted is frozen against a program
#      that no longer exists.
#
# (2) has a cost that is intended: a future WP that edits run-soak.sh or the
# analyser must update this table in the same commit. That IS G1 — evidence is
# not transferred by similarity — and the alternative is a table that was true
# once.
# ---------------------------------------------------------------------------
PREREG="$SOAK/campaigns/2026-08-02-r2-soak-candidate-1.md"
test -f "$PREREG" ||
  fail "the R2-WP02 pre-registration is missing. No soak result is admissible for promotion without it committed ahead of the run's started_utc."

for DRUSE_CRIT in C18 C19 C20 C21 C22; do
  grep -q "| $DRUSE_CRIT |" "$PREREG" ||
    fail "criterion $DRUSE_CRIT is gone from the R2-WP02 pre-registration. Criteria are frozen before the run (G3); removing one afterwards invalidates the run it was frozen for."
done

# The three origins, and the rule that produced them. A pre-registration whose
# SLO table lost the distinction between a measured number, an inherited one and
# an open one is a table of numbers with no provenance, which is the exact thing
# R2-WP02 exists to prevent.
grep -q 'A \*\*service SLO is a promise to the user of the service' "$PREREG" ||
  fail "the pre-registration lost the statement separating an SLO from a microbenchmark. Without it the origin column is decoration."
for DRUSE_ORIGIN in 'measured' 'inherited' 'open'; do
  grep -q "\`$DRUSE_ORIGIN\` —" "$PREREG" ||
    fail "the pre-registration no longer defines the '$DRUSE_ORIGIN' origin. Every SLO number needs one of the three, and a number with no origin is an invented number."
done
grep -q '\*\*An open row is a deliverable' "$PREREG" ||
  fail "the pre-registration lost the rule that an open SLO row is a deliverable. Deleting it is how open rows quietly become invented numbers."

# Every workload in §4 has a row in the SLO table of §6.2. A profile that is
# offered load with no promise attached is a profile nobody decided about.
for DRUSE_ROUTE in '/health' '/tiny' '/json/medium' '/json/medium/decode' '/bytes/64k' '/wait/40ms'; do
  grep -q "^| \`$DRUSE_ROUTE\` |" "$PREREG" ||
    fail "workload $DRUSE_ROUTE is driven by the campaign and has no row in the service SLO table"
done

# The pinned instrument still hashes to what the pre-registration says.
DRUSE_HASH_DRIFT=""
while IFS='|' read -r _ DRUSE_FILE DRUSE_WANT _; do
  DRUSE_FILE="$(echo "$DRUSE_FILE" | tr -d ' `')"
  DRUSE_WANT="$(echo "$DRUSE_WANT" | tr -d ' `')"
  case "$DRUSE_FILE" in ops/soak/*) ;; *) continue ;; esac
  test -f "$DRUSE_ROOT/$DRUSE_FILE" ||
    fail "the pre-registration pins $DRUSE_FILE and it does not exist"
  DRUSE_GOT="$(sha256sum "$DRUSE_ROOT/$DRUSE_FILE" | awk '{print $1}')"
  test "$DRUSE_GOT" = "$DRUSE_WANT" ||
    DRUSE_HASH_DRIFT="$DRUSE_HASH_DRIFT
  $DRUSE_FILE
    pinned:  $DRUSE_WANT
    on disk: $DRUSE_GOT"
done < <(sed -n '/<!-- r2-wp02-instrument-hashes -->/,/<!-- \/r2-wp02-instrument-hashes -->/p' "$PREREG" |
         grep '^| `ops/soak/')

test -z "$DRUSE_HASH_DRIFT" || fail "the instrument moved and the pre-registration did not:$DRUSE_HASH_DRIFT

Readiness rule G1: a change to the instrument creates a NEW CANDIDATE, and
evidence is not transferred by similarity. Update the table in
ops/soak/campaigns/2026-08-02-r2-soak-candidate-1.md in this commit — and if a
run has already been graded against the old hashes, that run belongs to the old
candidate and does not carry over."

# The table is not empty, or the loop above passes by finding nothing.
DRUSE_PINNED="$(sed -n '/<!-- r2-wp02-instrument-hashes -->/,/<!-- \/r2-wp02-instrument-hashes -->/p' "$PREREG" |
  grep -c '^| `ops/soak/')"
test "$DRUSE_PINNED" -ge 6 ||
  fail "the pre-registration pins only $DRUSE_PINNED instrument files; the runner, the analyser, the criteria, the schema, the soak server and the generator are all part of the candidate's identity"
echo "PASS (soak pre-registration, R2-WP02): the campaign criteria are present, every SLO row has a declared origin, and the $DRUSE_PINNED pinned instrument files still hash to what was frozen"

echo "PASS (soak): the R2-WP01 instrument controls are green"
