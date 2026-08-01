#!/usr/bin/env bash
# C-02 — the resource x property matrix, as a LIVING GATE.
#
# The matrix is the single canonical list of what this core does and does not
# bound. Its value is entirely in not going stale, so it is a gate, not a
# document. Five executable claims:
#
#   1. STRUCTURE — the eight columns are present, the declared number of rows is
#      the real number of rows, and NO CELL IS EMPTY. An unanswered cell is the
#      one thing this WP exists to make impossible; "none" is an answer, blank
#      is not;
#   2. CAPACITY COVERAGE — every field of `web.Limits` appears in the matrix. A
#      new limit with no row fails the build, which is the structural half of
#      "no framework-owned operation without a declared capacity";
#   3. METRIC COVERAGE — every public observability procedure appears, so a
#      counter cannot be added or dropped without the metric column noticing;
#   4. THE POINTERS HOLD — the documents that used to keep their own enumeration
#      point here instead;
#   5. THE DRIFTED CLAIMS CANNOT COME BACK. This one is unusual and deliberate:
#      a pointer is only worth something if the list it replaced cannot quietly
#      regrow, and the three sentences below are the MEASURED evidence that it
#      does. Before C-02, docs/operations.md asserted that large-body upload had
#      no public API, that the framework would not spool to disk, and that
#      streaming was out of core — all three false, all three shipped, and the
#      third contradicted a bullet four lines above it in the same section.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_MATRIX="$DRUSE_ROOT/planning/closure-readiness-matrix.md"

fail() {
  echo "C02-MATRIX-FAIL: $*" >&2
  exit 1
}

test -f "$DRUSE_MATRIX" ||
  fail "planning/closure-readiness-matrix.md is missing; it is the canonical limitations list every doc now points at"

# --- 1. Structure ------------------------------------------------------------
for DRUSE_COL in Resource Limit Deadline Cancellation 'Saturation policy' Metric Shutdown Class; do
  grep -q "| $DRUSE_COL |" "$DRUSE_MATRIX" ||
    fail "the matrix lost its '$DRUSE_COL' column. Each column is a question about every resource; dropping one drops the class of gap it finds."
done

DRUSE_DECLARED="$(sed -n 's/^<!-- c02-rows: \([0-9]\+\) -->$/\1/p' "$DRUSE_MATRIX")"
test -n "$DRUSE_DECLARED" || fail "the matrix lost its 'c02-rows' marker"

# Data rows are the numbered ones: '| 7 | Spool ingest | ... |'.
DRUSE_ROWS="$(grep -cE '^\| [0-9]+ \| ' "$DRUSE_MATRIX" || true)"
test "$DRUSE_ROWS" -eq "$DRUSE_DECLARED" ||
  fail "the matrix has $DRUSE_ROWS resource rows but declares $DRUSE_DECLARED"

# No empty cell, anywhere. A row is nine fields wide (leading index + eight
# columns); awk splits on '|' so a 9-column row yields 11 fields including the
# empty ones either side of the leading and trailing pipes.
DRUSE_BAD="$(awk -F'|' '
  /^\| [0-9]+ \| / {
    if (NF != 11) { printf "row %s has %d fields, expected 11\n", $2, NF-2; next }
    for (i = 2; i <= 10; i++) {
      cell = $i
      gsub(/^[ \t]+|[ \t]+$/, "", cell)
      if (cell == "" || cell == "?" || cell == "-" || cell == "TBD") {
        printf "row %s column %d is unanswered (%s)\n", $2, i-1, (cell == "" ? "empty" : cell)
      }
    }
  }' "$DRUSE_MATRIX")"
test -z "$DRUSE_BAD" || fail "$(printf 'the matrix has unanswered cells:\n%s\nAn empty cell is a gap nobody has classified — write "none" and say who owns the consequence.' "$DRUSE_BAD")"

# --- 2. Capacity coverage: every `web.Limits` field has a home ---------------
DRUSE_LIMIT_FIELDS="$(sed -n '/^Limits :: struct {/,/^}/p' "$DRUSE_ROOT/web/limits.odin" |
  sed -n 's/^\t\([a-z_]\+\):.*$/\1/p' | sort -u)"
test -n "$DRUSE_LIMIT_FIELDS" ||
  fail "could not read the field list of web.Limits; the capacity-coverage check would silently pass"
for DRUSE_F in $DRUSE_LIMIT_FIELDS; do
  grep -q "$DRUSE_F" "$DRUSE_MATRIX" ||
    fail "web.Limits.$DRUSE_F appears nowhere in the readiness matrix. A capacity the framework offers but the matrix does not place is a capacity whose saturation, metric and shutdown behaviour nobody has stated."
done

# --- 3. Metric coverage ------------------------------------------------------
# WP123 — the two public counters now take the App whose server they describe,
# so the extraction matches `proc(` rather than `proc()`. Pinning the empty
# parameter list made this check silently unreadable the moment the arity
# changed, and an extraction that comes back empty is a gate that has stopped
# looking rather than a surface that has stopped existing — which is exactly
# what the guard below is here to catch.
DRUSE_OBS="$(sed -n 's/^\([a-z_]\+\) :: proc(.*$/\1/p' "$DRUSE_ROOT/web/observability.odin")"
test -n "$DRUSE_OBS" ||
  fail "could not read the public observability surface from web/observability.odin"
for DRUSE_O in $DRUSE_OBS; do
  grep -q "$DRUSE_O" "$DRUSE_MATRIX" ||
    fail "the public counter web.$DRUSE_O appears nowhere in the matrix's Metric column"
done

# --- 4. The pointers hold ----------------------------------------------------
for DRUSE_DOC in docs/operations.md docs/quick-start.md; do
  grep -q 'closure-readiness-matrix.md' "$DRUSE_ROOT/$DRUSE_DOC" ||
    fail "$DRUSE_DOC no longer points at planning/closure-readiness-matrix.md. The enumeration lives in one place; a document that stops pointing at it is a document about to start keeping its own copy again."
done

# --- 5. The drifted claims cannot come back ----------------------------------
# Each phrase may appear ONLY where it is being refuted — the two-line window
# must contain the word "false". That keeps the historical explanation in
# operations.md legal while an assertion anywhere is fatal.
check_no_assertion() {
  local phrase="$1" why="$2" hit
  while IFS= read -r hit; do
    test -n "$hit" || continue
    local file rest line window
    file="${hit%%:*}"
    rest="${hit#*:}"
    line="${rest%%:*}"
    window="$(sed -n "$((line > 1 ? line - 1 : 1)),$((line + 2))p" "$DRUSE_ROOT/$file")"
    grep -qi 'false\|used to\|no longer\|drifted' <<<"$window" ||
      fail "$file:$line asserts \"$phrase\" — $why"
  done < <(cd "$DRUSE_ROOT" && grep -rn "$phrase" docs/ README.md 2>/dev/null || true)
}
check_no_assertion 'no public API yet' \
  "large-body upload shipped its public API in Phase 7.5-C2 (web.enable_upload / web.upload / web.upload_persist)"
check_no_assertion 'will not spool to disk' \
  "the core spools to disk on the opt-in upload path since Phase 7.5-C2"
check_no_assertion 'No WebSocket or streaming' \
  "response streaming shipped in Phase 7 (web.stream); only WebSocket remains out of core"

echo "c02: $DRUSE_ROWS resources x 8 properties, no unanswered cell"
echo "c02: every web.Limits field and every public counter is placed in the matrix"
echo "c02: docs/operations.md and docs/quick-start.md point at the matrix instead of restating it"
echo "c02: the three drifted claims cannot be asserted again"
echo "PASS: C-02 readiness matrix (living gate)"
