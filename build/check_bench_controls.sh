#!/usr/bin/env bash
# Diagnosability controls for the benchmark summary (planning/diagnosability.md).
#
# On 2026-07-30 a comparison of four servers was published in which one of them
# answered with 21.6% more bytes than the other three. The generator had
# recorded `response_bytes` in every artefact. The summary never read it, so the
# one field that says "these servers did not do the same work" reached disk and
# stopped there, and the divergence was found by hand after publication.
#
# Rule 1 of the standard is no discard, and a field computed and never read is
# discarded as surely as one never computed. These controls prove the summary
# now reads it:
#
#   POSITIVE  — servers that agree on response size produce no warning, so the
#               warning means something when it appears.
#   NEGATIVE  — servers that disagree are flagged, the row is named as not
#               like-for-like, and every server's size is printed.
#
# The positive case is not decoration. A summary that warned unconditionally
# would pass the negative check while telling the reader nothing.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUMMARISE="$DRUSE_ROOT/bench/application_matrix/summarise-openload-matrix.py"
TMP="$(mktemp -d -t druse-bench-controls-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "BENCH-CONTROL-FAIL: $*" >&2
  exit 1
}

test -f "$SUMMARISE" || fail "the matrix summary is missing: $SUMMARISE"

# write_run OUT_DIR SERVER BYTES_PER_RESPONSE
write_run() {
  local dir="$1" server="$2" bytes="$3"
  local answered=1000
  mkdir -p "$dir/runs"
  cat >"$dir/runs/$server-json-medium-r1.json" <<JSON
{
  "url": "http://127.0.0.1:8080/json/medium",
  "planned": $answered, "completed": $answered, "succeeded": $answered,
  "transport_errors": 0, "status": {"200": $answered},
  "failures": [], "unclassified": 0,
  "response_bytes": $(( answered * bytes )),
  "goodput_per_second": 20000,
  "latency_p50_us": 150, "latency_p99_us": 900
}
JSON
}

# --- POSITIVE: equal sizes must NOT warn ------------------------------------
mkdir -p "$TMP/equal"
printf 'rate_per_second=20000\nrepeats=1\nseconds_per_run=10\ngit_head=deadbeef\n' \
  >"$TMP/equal/manifest.txt"
write_run "$TMP/equal" druse 4438
write_run "$TMP/equal" nethttp 4438
write_run "$TMP/equal" fiber 4438

python3 "$SUMMARISE" "$TMP/equal" >"$TMP/equal.txt" 2>&1 ||
  fail "the summary could not read a well-formed run directory"

grep -q "RESPONSE SIZES DIFFER" "$TMP/equal.txt" &&
  fail "servers that agree on response size were flagged as differing; the warning is unconditional and therefore meaningless"

grep -q "4,438" "$TMP/equal.txt" ||
  fail "the summary does not print bytes per response at all, so a divergence could not be seen even when flagged"

echo "PASS (bench): equal response sizes are printed and not flagged"

# --- NEGATIVE: unequal sizes MUST be flagged --------------------------------
mkdir -p "$TMP/unequal"
printf 'rate_per_second=20000\nrepeats=1\nseconds_per_run=10\ngit_head=deadbeef\n' \
  >"$TMP/unequal/manifest.txt"
# The real numbers from the run that went out wrong.
write_run "$TMP/unequal" druse 5398
write_run "$TMP/unequal" nethttp 4438
write_run "$TMP/unequal" fiber 4438

python3 "$SUMMARISE" "$TMP/unequal" >"$TMP/unequal.txt" 2>&1 ||
  fail "the summary could not read a run directory whose servers disagree"

grep -q "RESPONSE SIZES DIFFER" "$TMP/unequal.txt" ||
  fail "servers answering 4,438 and 5,398 bytes were presented as a comparison; this is the exact artefact that was published on 2026-07-30"

grep -q "NOT a like-for-like comparison" "$TMP/unequal.txt" ||
  fail "the divergence is reported without saying the row cannot be compared"

grep -q "+21.6%" "$TMP/unequal.txt" ||
  fail "the divergence is flagged without quantifying it; a reader cannot tell 0.1% from 21.6%"

echo "PASS (bench): a row whose servers answer different sizes is flagged and quantified"

# --- The commit provenance field must never be silently empty ---------------
# A tree copied without .git makes `git rev-parse` print to stderr and nothing
# to stdout, and the manifest loses the field that says WHAT was measured.
mkdir -p "$TMP/nocommit"
printf 'rate_per_second=20000\nrepeats=1\nseconds_per_run=10\ngit_head=unknown\n' \
  >"$TMP/nocommit/manifest.txt"
write_run "$TMP/nocommit" druse 4438
write_run "$TMP/nocommit" nethttp 4438

python3 "$SUMMARISE" "$TMP/nocommit" >"$TMP/nocommit.txt" 2>&1 ||
  fail "the summary could not read a run whose commit is unknown"
grep -q "unknown" "$TMP/nocommit.txt" ||
  fail "a run with no recorded commit does not say so in its summary"

echo "PASS (bench): a run that does not know its own commit says 'unknown' out loud"
