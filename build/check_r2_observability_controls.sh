#!/usr/bin/env bash
# R2-WP03 — observability under saturation, under control.
#
# AUD-P2-009 says application saturation and network loss are indistinguishable
# under pressure. ADR-050 decided the arm; `tests/r2-observability-saturation`
# proves the behaviour. This script proves THE SUITE CAN STILL FAIL, which is a
# different claim and the one the repository has been burned by:
#
#   "A control that only knows how to say 'failed' is indistinguishable from a
#    control that is broken."
#
# So every behavioural control below is run twice — once as it ships (green) and
# once against a MUTANT that must go red FOR THE EXPECTED REASON. A mutant that
# goes red because the tree stopped compiling has proved nothing, so each one
# greps the failure text.
#
# The static assertions are the ones no Odin test can make, because they are
# about the operator-facing artefacts: an alert file that interpolates across a
# gap, or a sampler that swallows an exit status, is a defect a passing test
# suite cannot see.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_SUITE_DIR="$DRUSE_ROOT/tests/r2-observability-saturation"
DRUSE_SUITE="$DRUSE_SUITE_DIR/observability_saturation_test.odin"
DRUSE_ADAPTER="$DRUSE_ROOT/web/internal/transport/odin_http_adapter.odin"
DRUSE_OBS="$DRUSE_ROOT/web/observability.odin"
DRUSE_SAMPLER="$DRUSE_ROOT/ops/monitoring/sample-metrics.sh"
DRUSE_ALERTS="$DRUSE_ROOT/ops/monitoring/alerts.yml"
DRUSE_FORMAT="$DRUSE_ROOT/ops/monitoring/snapshot-format.md"
DRUSE_DASH="$DRUSE_ROOT/ops/monitoring/dashboard.md"
DRUSE_SOAK_SERVER="$DRUSE_ROOT/ops/soak/soak-server/main.odin"
DRUSE_EXAMPLE="$DRUSE_ROOT/examples/10-config-and-health/main.odin"
DRUSE_PREREG="$DRUSE_ROOT/planning/readiness/R2-WP03-preregistration.md"

fail() {
  echo "R2-OBS-CONTROL-FAIL: $*" >&2
  exit 1
}

if test -n "${DRUSE_COMPILER:-}"; then
  DRUSE_ODIN="$DRUSE_COMPILER"
elif test -n "${DRUSE_ODIN_BIN:-}"; then
  DRUSE_ODIN="$DRUSE_ODIN_BIN"
elif command -v odin >/dev/null 2>&1; then
  DRUSE_ODIN="$(command -v odin)"
elif test -x /tmp/druse-toolchain/odin; then
  DRUSE_ODIN=/tmp/druse-toolchain/odin
else
  fail "odin compiler not found"
fi

DRUSE_ODIN="$(readlink -f "$DRUSE_ODIN")"
DRUSE_ODIN_ROOT="$(cd "$(dirname "$DRUSE_ODIN")" && pwd)"
DRUSE_TMP="$(mktemp -d -t druse-r2-obs-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP"' EXIT

for f in "$DRUSE_SUITE" "$DRUSE_SAMPLER" "$DRUSE_ALERTS" "$DRUSE_FORMAT" \
         "$DRUSE_DASH" "$DRUSE_PREREG"; do
  test -f "$f" || fail "missing $f"
done

# ---------------------------------------------------------------------------
# 1. G3 — the criteria were frozen before the measurement
# ---------------------------------------------------------------------------
# Not a formality. A budget written after a result is a description of the
# result. The gate cannot check WHEN the file was committed, but it can check
# that the numbers the ADR claims to have been held to are the numbers the
# pre-registration states, so the two cannot drift apart afterwards.
for DRUSE_CRIT in B1 B1n B2 B3 B4 B5 B6 B7; do
  grep -q "\*\*$DRUSE_CRIT\*\*" "$DRUSE_PREREG" ||
    fail "criterion $DRUSE_CRIT is gone from the pre-registration. Criteria are frozen before the run (G3); deleting one after the fact invalidates the run it was frozen for."
done
grep -q 'INCONCLUSIVE' "$DRUSE_PREREG" ||
  fail "the pre-registration lost its INCONCLUSIVE rule for the throughput diagnostic. A host that cannot resolve the effect must produce 'inconclusive', not a pass."
grep -q 'controle negativo' "$DRUSE_PREREG" ||
  fail "the pre-registration no longer names the baseline as the negative control (B1n)"

# ---------------------------------------------------------------------------
# 2. The four occupancy/capacity fields are WIRED, not decorative
# ---------------------------------------------------------------------------
for DRUSE_FIELD in active_connections handlers_active handler_capacity connection_capacity; do
  grep -q "^	$DRUSE_FIELD:" "$DRUSE_OBS" ||
    fail "web.Server_Stats no longer declares $DRUSE_FIELD"
done
grep -q 'count_active_handlers :: proc' "$DRUSE_ADAPTER" ||
  fail "count_active_handlers is gone; handlers_active would have no source"
grep -q 'lane.handler_active' "$DRUSE_ADAPTER" ||
  fail "count_active_handlers no longer reads the per-lane handler_active flag, so the occupancy gauge is decorative"
# The enforced ceiling is max_connections MINUS the shutdown reserve. Reporting
# max_connections would advertise headroom admission never hands out.
grep -q 'server.opts.max_connections - server.opts.reserved_connections' "$DRUSE_ADAPTER" ||
  fail "connection_capacity no longer subtracts reserved_connections; it would report a ceiling admission does not enforce"

# The vendor ledger must not have grown for this. Every one of the four is a
# READ of state the backend already keeps.
grep -q 'DRUSE PATCH 44' "$DRUSE_ROOT/vendor/odin-http/server.odin" &&
  fail "a patch 44 appeared in the backend. R2-WP03 added no vendor patch by design; if one is genuinely needed it belongs in the vendor ledger with a disposition, not here."

# ---------------------------------------------------------------------------
# 3. The exporter never writes in place
# ---------------------------------------------------------------------------
# temp-then-rename, in both reference exporters. Writing in place lets a reader
# observe a truncated record — and a truncated record of integers is PLAUSIBLE,
# which is what makes it dangerous rather than merely wrong.
for DRUSE_EXP in "$DRUSE_SOAK_SERVER" "$DRUSE_EXAMPLE"; do
  grep -q 'os.rename' "$DRUSE_EXP" ||
    fail "$DRUSE_EXP writes its snapshot without a rename; a reader can observe a partial record"
  grep -q '\.tmp' "$DRUSE_EXP" ||
    fail "$DRUSE_EXP no longer stages its snapshot through a temporary file"
  grep -q 'end' "$DRUSE_EXP" ||
    fail "$DRUSE_EXP no longer writes the record terminator; truncation stops being detectable"
done

# ---------------------------------------------------------------------------
# 4. The operator artefacts do not hide a gap
# ---------------------------------------------------------------------------
grep -q 'DruseMetricsAbsent' "$DRUSE_ALERTS" ||
  fail "the missing-scrape alert is gone. AUD-P2-009: an alert on an absent scrape works; interpolating silently hides pressure."
grep -q 'DruseLanesSaturated' "$DRUSE_ALERTS" ||
  fail "the lane-occupancy alert is gone. It is the only alert that fires under total saturation, because every counter freezes there."
# Comments are stripped first: the file EXPLAINS why gap-filling is forbidden,
# and a check that cannot tell an explanation from an instance would forbid
# writing the reason down.
if sed 's/#.*//' "$DRUSE_ALERTS" | grep -qE 'or vector\(0\)|or on\(\) vector\(0\)'; then
  fail "the alert rules fill an absent series with zero. A filled gap is a claim the process made about itself while it was silent — that is the defect, not the fix."
fi
grep -q 'Connect nulls: OFF' "$DRUSE_DASH" ||
  fail "the dashboard no longer forbids connecting nulls; an interpolated point renders an outage as a healthy line"
grep -qi 'handlers_active / handler_capacity' "$DRUSE_DASH" ||
  fail "the dashboard lost the occupancy panel, which is the only saturation signal that is not a frozen counter"

# The sampler must emit a line for EVERY tick, with a cause, and must not
# swallow a command's exit status. `cmd || true` overwriting `$?` is AUD-P1-003
# verbatim, and it shipped once already.
grep -q 'cause=\$cause' "$DRUSE_SAMPLER" ||
  fail "the sampler no longer stamps a cause on every line; an absence with no cause is an instrument failure, not a datum"
if grep -qE '^\s*[a-z_]+="\$\(curl[^)]*\)" *\|\| *true' "$DRUSE_SAMPLER"; then
  fail "the sampler captures a curl result with '|| true', which overwrites \$? — the exact defect AUD-P1-003 named in run-soak.sh"
fi
grep -q 'no_process' "$DRUSE_SAMPLER" ||
  fail "the sampler no longer distinguishes a dead process from a stale record. That distinction is the whole reason it runs outside the process."

bash -n "$DRUSE_SAMPLER" || fail "ops/monitoring/sample-metrics.sh does not parse"

# ---------------------------------------------------------------------------
# 5. Positive control — the suite is green as it ships
# ---------------------------------------------------------------------------
env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test "$DRUSE_SUITE_DIR" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  "-out:$DRUSE_TMP/r2obs" >"$DRUSE_TMP/positive.log" 2>&1 ||
  { cat "$DRUSE_TMP/positive.log" >&2; fail "the R2-WP03 suite is red before any mutation"; }
grep -q 'The test was successful' "$DRUSE_TMP/positive.log" ||
  fail "the R2-WP03 suite did not report success. See $DRUSE_TMP/positive.log"

# ---------------------------------------------------------------------------
# 6. Negative controls
# ---------------------------------------------------------------------------
# A pristine copy of exactly what a build of the suite needs. Each mutant starts
# by restoring the one file it touches, so the mutations cannot compound.
DRUSE_TREE="$DRUSE_TMP/tree"
mkdir -p "$DRUSE_TREE"
for DRUSE_DIR in web vendor tests; do
  cp -a "$DRUSE_ROOT/$DRUSE_DIR" "$DRUSE_TREE/"
done
cp -a "$DRUSE_ROOT/odin-version.txt" "$DRUSE_TREE/" 2>/dev/null || true

DRUSE_MUT_ADAPTER="$DRUSE_TREE/web/internal/transport/odin_http_adapter.odin"
DRUSE_MUT_SUITE="$DRUSE_TREE/tests/r2-observability-saturation/observability_saturation_test.odin"

restore() {
  cp -a "$DRUSE_ADAPTER" "$DRUSE_MUT_ADAPTER"
  cp -a "$DRUSE_SUITE" "$DRUSE_MUT_SUITE"
}

# run_mutant NAME EXPECTED_SUBSTRING
# Runs the suite in the mutated tree, requires red, and requires the red to be
# for the expected reason. A mutant that merely fails to compile has proved
# nothing about the control.
run_mutant() {
  local name="$1" expected="$2" log="$DRUSE_TMP/$1.log"
  if env ODIN_ROOT="$DRUSE_ODIN_ROOT" "$DRUSE_ODIN" test \
      "$DRUSE_TREE/tests/r2-observability-saturation" \
      "-collection:druse=$DRUSE_TREE" -define:ODIN_TEST_THREADS=1 \
      "-out:$DRUSE_TMP/mut-$name" >"$log" 2>&1; then
    fail "mutant '$name' stayed GREEN. The control it targets cannot detect its own absence. See $log"
  fi
  grep -q "$expected" "$log" ||
    fail "mutant '$name' went red for the wrong reason; expected text matching '$expected'. See $log"
  echo "r2-obs: mutant '$name' is red for the expected reason"
}

# --- M1: the occupancy gauge always reads zero ------------------------------
# The single most valuable mutant here. A gauge stuck at zero is exactly what
# the FIRST version of every metric looks like, and every cumulative counter
# around it is frozen at full occupancy, so nothing else in the snapshot would
# contradict it.
restore
python3 - "$DRUSE_MUT_ADAPTER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	active := 0
	for &lane in server.threads {
		if sync.atomic_load_explicit(&lane.handler_active, .Acquire) {
			active += 1
		}
	}
	return active"""
assert old in s, "M1 anchor not found in the adapter"
open(p, "w").write(s.replace(old, "	// MUTANT M1: the occupancy gauge never sees a busy lane\n	_ = server\n	return 0"))
PY
run_mutant m1-gauge-stuck-at-zero "handlers_active is 0 of 4"

# --- M2: capacity reported as the unenforced ceiling ------------------------
restore
python3 - "$DRUSE_MUT_ADAPTER" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "max(1, server.opts.max_connections - server.opts.reserved_connections)"
assert old in s, "M2 anchor not found in the adapter"
# MUTANT M2: advertise headroom that admission will never hand out.
open(p, "w").write(s.replace(old, "server.opts.max_connections"))
PY
run_mutant m2-capacity-ignores-reserve "connection_capacity"

# --- M3: the reader accepts a truncated record ------------------------------
restore
python3 - "$DRUSE_MUT_SUITE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	if !strings.has_suffix(strings.trim_right_space(text), "end") {
		return .Malformed, text
	}"""
assert old in s, "M3 anchor not found in the suite"
open(p, "w").write(s.replace(old, "	// MUTANT M3: truncation is assumed away"))
PY
run_mutant m3-reader-accepts-truncation "no \`end\` terminator"

# --- M4: absence is interpolated instead of alerted -------------------------
# The mutant that models the finding's own sentence: "an alert on a missing
# scrape works; interpolating silently hides pressure."
restore
python3 - "$DRUSE_MUT_SUITE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	if time.now()._nsec - stamp > i64(MAX_AGE) {
		return .Stale, text
	}"""
assert old in s, "M4 anchor not found in the suite"
open(p, "w").write(s.replace(old, "	// MUTANT M4: a record that stopped being updated still reads as a value\n	_ = stamp"))
PY
run_mutant m4-stale-reads-as-a-value "must not read as a value"

# --- M5: the exporter spends lane time (B7) ---------------------------------
# Give the exporter thread an HTTP scrape to do. It now costs exactly what an
# in-process metrics ROUTE costs, which is the thing ADR-050 rejected, and B7
# must notice.
restore
python3 - "$DRUSE_MUT_SUITE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """		if write_snapshot(web.is_draining(&g_server.app)) {
			sync.atomic_add(&g_export_ticks, 1)
		}"""
assert old in s, "M5 anchor not found in the suite"
new = """		// MUTANT M5: the exporter goes through a Handler lane after all.
		_ = scrape_stats(g_server.port, 500 * time.Millisecond)
		if write_snapshot(web.is_draining(&g_server.app)) {
			sync.atomic_add(&g_export_ticks, 1)
		}"""
open(p, "w").write(s.replace(old, new))
PY
run_mutant m5-exporter-costs-lane-time "B7 FAILED"

# --- M6: the finding itself is asserted, not assumed ------------------------
# If `/stats` under total occupancy could answer, AUD-P2-009 would not exist.
# This mutant makes the scrape claim success and requires the suite to catch it,
# which proves the `!route_answered` assertion is live rather than vacuous.
restore
python3 - "$DRUSE_MUT_SUITE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "	route_answered := scrape_stats(server.port, 500 * time.Millisecond)"
assert old in s, "M6 anchor not found in the suite"
new = "	// MUTANT M6: pretend the saturated route answered\n	route_answered := true"
open(p, "w").write(s.replace(old, new))
PY
run_mutant m6-saturated-route-answers "answered while every lane was inside a handler"

# --- M7: a dead server publishes a record of zeroes -------------------------
# `web.stats` returns the zero value once the App stops running a server, and
# the final drain write lands exactly there. An exporter that publishes it emits
# a counter RESET — which this system's own runbook tells operators to read as a
# restart. The mutant removes the guard and the suite must catch it.
restore
python3 - "$DRUSE_MUT_SUITE" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	if s.handler_capacity == 0 {
		return false
	}"""
assert old in s, "M7 anchor not found in the suite"
open(p, "w").write(s.replace(old, "	// MUTANT M7: a stopped server publishes all-zero counters", 1))
PY
run_mutant m7-zeroed-record-after-stop "publishes a counter reset"

restore

# The guard must exist in BOTH reference exporters, not only in the suite that
# proves it. A control that is green because the test copy is right, while the
# shipped copy is wrong, is worse than no control.
for DRUSE_EXP in "$DRUSE_SOAK_SERVER" "$DRUSE_EXAMPLE"; do
  grep -q 'handler_capacity == 0' "$DRUSE_EXP" ||
    fail "$DRUSE_EXP writes a snapshot without checking that a server is still running. After serve returns, web.stats is all zeroes, and publishing that record is publishing a counter reset."
done

echo "r2-obs: the pre-registered criteria B1-B7 and the INCONCLUSIVE rule are intact"
echo "r2-obs: the four occupancy/capacity fields are wired to real backend state, with no vendor patch"
echo "r2-obs: both reference exporters stage through a temporary file and rename"
echo "r2-obs: the alert rules and dashboard treat an absent sample as an alert, never as data"
echo "r2-obs: the sampler stamps a cause on every tick and does not swallow an exit status"
echo "r2-obs: the behavioural suite is green, and seven mutants are red for their own reasons"
echo "PASS: R2-WP03 observability controls"
