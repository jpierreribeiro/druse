#!/usr/bin/env bash
# WP22 — the seven required `logger` mutation controls, as one executable run.
#
# The WP17-WP21 protocol, unchanged: each control re-creates a specific defect
# in a THROWAWAY copy of the shipped sources and requires the WP22 test suite
# to catch it. Every probe (a) runs its selected tests UNMUTATED first and
# requires them green with at least one test executed, (b) asserts its own edit
# applied by md5 — BROKEN PROBE otherwise, never a false verdict — and (c)
# requires the selected tests red afterwards.
#
#   1  the raw PATH used as route identity  -> the pattern-only tests MUST go red
#   2  the line written BEFORE `next`       -> committed-status test MUST go red
#   3  the commit guard ignored             -> uncommitted-status test MUST go red
#   4  the truncation mark dropped          -> truncation-announced test MUST go red
#   5  the escaper bypassed                 -> CR/LF injection test MUST go red
#   6  EVERY line marked truncated          -> the POSITIVE test MUST go red
#   7  binary cost, measured with `nm`      -> zero logger symbols when unused
#
# CONTROL 6 IS THE POSITIVE HALF and it is not decoration. Controls 4 and 5
# are satisfied by an implementation that mangles every line — one that always
# truncates passes "a long pattern is marked" while telling the truth about
# nothing. Control 6 fails that implementation, which is what makes the other
# two mean something.
#
# CONTROL 7 CARRIES ITS OWN POSITIVE CONTROL, on the G-11 gate's pattern: an
# application that DOES use `web.logger` must link the symbols an application
# that ignores it must not. Without that, a typo in the symbol pattern would
# make the zero-assertion pass against every possible binary.
#
# Controls 1-6 need the pinned compiler; control 7 needs the compiler and `nm`.
# Without a toolchain this script reports BLOCKED and exits 2 — it never
# reports a control it did not run.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP22-CONTROL-FAIL: $*" >&2
  exit 1
}

DRUSE_W22_ODIN="${DRUSE_ODIN_BIN:-}"
if test -z "$DRUSE_W22_ODIN" && command -v odin >/dev/null 2>&1; then
  DRUSE_W22_ODIN="$(command -v odin)"
fi
if test -z "$DRUSE_W22_ODIN" && test -x /tmp/druse-toolchain/odin; then
  DRUSE_W22_ODIN=/tmp/druse-toolchain/odin
fi
if test -z "$DRUSE_W22_ODIN"; then
  echo "WP22 CONTROLS -> BLOCKED: no Odin toolchain found (set DRUSE_ODIN_BIN). NOTHING RAN." >&2
  exit 2
fi
DRUSE_W22_ODIN_DIR="$(cd "$(dirname "$DRUSE_W22_ODIN")" && pwd)"

DRUSE_W22_TMP="$(mktemp -d -t druse-wp22-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_W22_TMP"' EXIT

internal_tree() { # name
  local t="$DRUSE_W22_TMP/$1"
  mkdir -p "$t"
  cp "$DRUSE_ROOT"/web/*.odin "$t/"
  cp "$DRUSE_ROOT"/tests/wp22-internal/*.odin "$t/"
  printf '%s' "$t"
}

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

# The public suite runs against the real collection; the internal suite runs
# inside the throwaway package. `which` selects the target so a control can
# mutate `web/` and still exercise the EXTERNAL contract.
run_selected() { # tree test-names
  env -u ODIN_ROOT "$DRUSE_W22_ODIN" test "$1" \
    "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_W22_TMP/runner" \
    "-define:ODIN_TEST_NAMES=$2" 2>&1
}

assert_green_baseline() { # tree test-names label
  local out
  if ! out="$(run_selected "$1" "$2")"; then
    echo "$out" >&2
    fail "BROKEN PROBE ($3): the selected tests are not green BEFORE the mutation"
  fi
  grep -qE 'Finished [1-9][0-9]* tests?' <<<"$out" ||
    { echo "$out" >&2; fail "BROKEN PROBE ($3): the selection ran no test; a stale test name would fake a pass"; }
}

must_go_red() { # tree test-names label
  local out
  if out="$(run_selected "$1" "$2")"; then
    echo "$out" >&2
    fail "control '$3' stayed GREEN under the mutation; the suite does not catch this defect"
  fi
  echo "CONTROL $3 -> RED as required"
}

# --- 1. the raw PATH used as route identity ----------------------------------
# The single most dangerous regression this work package can have. The route
# field would become unbounded, attacker-chosen text in every log line — the
# cardinality explosion and the data leak in one edit.
NAMES="web.wp22_a_pattern_that_fits_is_not_marked,web.wp22_control_bytes_are_escaped_in_hex"
T="$(internal_tree rawpath)"
assert_green_baseline "$T" "$NAMES" "1: raw path as route"
H="$(md5sum "$T/logger.odin" | cut -d' ' -f1)"
sed -i 's|^\tn += logger_write_route(dst\[n:\], ctx.private.route)$|\tn += logger_write_route(dst[n:], ctx.request.path)|' \
  "$T/logger.odin"
assert_mutated "raw path as route" "$T/logger.odin" "$H"
must_go_red "$T" "$NAMES" "1: raw path as route -> pattern-only line tests"

# --- 2. the line written BEFORE `next` ---------------------------------------
# The status would then be a prediction rather than a reading: whatever the
# response happened to hold before the handler ran.
NAMES="web.wp22_a_pattern_that_fits_is_not_marked"
T="$(internal_tree earlyline)"
assert_green_baseline "$T" "$NAMES" "2: line written before next"
H="$(md5sum "$T/logger.odin" | cut -d' ' -f1)"
python3 - "$T/logger.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	next(ctx)

	handle := context.logger"""
new = """	handle := context.logger"""
assert old in s, "pattern not found"
s = s.replace(old, new, 1)
old2 = """	handle.procedure(handle.data, .Info, string(buf[:n]), handle.options, #location(logger))
}"""
new2 = """	handle.procedure(handle.data, .Info, string(buf[:n]), handle.options, #location(logger))
	next(ctx)
}"""
assert old2 in s, "tail pattern not found"
open(p, 'w').write(s.replace(old2, new2, 1))
PYEOF
assert_mutated "line before next" "$T/logger.odin" "$H"
must_go_red "$T" "$NAMES" "2: line written before next -> committed-status test"

# --- 3. the commit guard ignored ---------------------------------------------
# `logger_status` is the ONE place this middleware reads response state, and it
# asks the guard first. Ignoring the guard makes an uncommitted request report
# the zero Status as though it had been sent.
NAMES="web.wp22_status_field_consults_the_commit_guard"
T="$(internal_tree noguard)"
assert_green_baseline "$T" "$NAMES" "3: commit guard ignored"
H="$(md5sum "$T/logger.odin" | cut -d' ' -f1)"
sed -i 's|^\tif !ctx.private.response.committed {$|\tif false {|' "$T/logger.odin"
assert_mutated "commit guard ignored" "$T/logger.odin" "$H"
must_go_red "$T" "$NAMES" "3: commit guard ignored -> uncommitted-status test"

# --- 4. the truncation mark dropped ------------------------------------------
# The line would be cut SILENTLY: the logger would quietly lie by omission
# about a route it did see. This is the amendment of 2026-07-20 made executable.
NAMES="web.wp22_truncation_is_announced_in_the_line"
T="$(internal_tree silentcut)"
assert_green_baseline "$T" "$NAMES" "4: truncation mark dropped"
H="$(md5sum "$T/logger.odin" | cut -d' ' -f1)"
python3 - "$T/logger.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = """	if truncating {
		n += copy(dst[n:], LOGGER_TRUNCATED)
	}
	return n"""
new = """	if false {
		n += copy(dst[n:], LOGGER_TRUNCATED)
	}
	return n"""
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "truncation mark dropped" "$T/logger.odin" "$H"
must_go_red "$T" "$NAMES" "4: truncation mark dropped -> truncation-announced test"

# --- 5. the escaper bypassed -------------------------------------------------
# Raw CR/LF from a route pattern would reach the log and forge extra records.
NAMES="web.wp22_control_bytes_are_escaped_in_hex,web.wp22_truncation_never_splits_an_escape"
T="$(internal_tree rawbytes)"
assert_green_baseline "$T" "$NAMES" "5: escaper bypassed"
H="$(md5sum "$T/logger.odin" | cut -d' ' -f1)"
python3 - "$T/logger.odin" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\t\tn += logger_write_escaped(dst[n:], pattern[i])"
new = "\t\tdst[n] = pattern[i]\n\t\tn += 1"
assert old in s, "pattern not found"
open(p, 'w').write(s.replace(old, new, 1))
PYEOF
assert_mutated "escaper bypassed" "$T/logger.odin" "$H"
must_go_red "$T" "$NAMES" "5: escaper bypassed -> CR/LF injection tests"

# --- 6. EVERY line marked truncated (the POSITIVE control) -------------------
# An implementation that always truncates satisfies control 4 while destroying
# every ordinary line. Only the positive assertion catches it.
NAMES="web.wp22_a_pattern_that_fits_is_not_marked"
T="$(internal_tree alwayscut)"
assert_green_baseline "$T" "$NAMES" "6: everything marked truncated"
H="$(md5sum "$T/logger.odin" | cut -d' ' -f1)"
sed -i 's|^\ttruncating := total > budget$|\ttruncating := true|' "$T/logger.odin"
assert_mutated "everything marked truncated" "$T/logger.odin" "$H"
must_go_red "$T" "$NAMES" "6: everything marked truncated -> the POSITIVE unmarked-line test"

# --- 7. binary cost, measured (NEGATIVE + POSITIVE) --------------------------
#
# The claim is "an application that never references `web.logger` links ZERO
# logger symbols". It is measured with `nm` against two real consumers, on the
# G-11 gate's pattern, because a claim of this shape is worth exactly the
# measurement behind it.
#
# WHAT THIS CONTROL DELIBERATELY DOES NOT ASSERT: byte-identity of the binary.
# `planning/phase-2-plan.md` WP22 asked for "byte-identical to WP17's
# baseline"; that is not a testable property on the pinned toolchain. Five
# builds of an IDENTICAL source tree produced five different binaries
# (876,304 / 876,352 / 876,352 / 876,368 / 876,360 bytes, five distinct md5s):
# the vendored `nbio` emits polymorphic instantiations whose mangled parameter
# names vary between runs. Byte-identity therefore fails for a tree compared
# against ITSELF, so asserting it would be a gate that flakes rather than a
# guarantee that holds. The symbol COUNT is stable — 0 across all five rebuilds
# — and is what this control asserts. See plan amendment (2026-07-20).
if ! command -v nm >/dev/null 2>&1; then
  echo "WP22 CONTROL 7 -> BLOCKED: nm not found; the binary-cost claim cannot be measured." >&2
  exit 2
fi

# Scoped to `package web`, so it can only match this framework's own code: the
# unqualified word "logger" appears in `core:log`'s symbols (`file_console_
# logger.odin`) in EVERY binary and would make the negative assertion
# meaningless. Both halves are required — the public entry point is emitted as
# `web::logger` and the helpers as `web::[logger.odin]::*`, so a pattern
# carrying only the file-qualified form would miss a regression that linked the
# public procedure while dead-stripping its helpers.
DRUSE_W22_SYMS='web::(logger$|\[logger\.odin\])'

wp22_build_consumer() { # label use-line
  local label="$1"
  local use_line="$2"
  local tree="$DRUSE_W22_TMP/$label"
  mkdir -p "$tree/app" "$tree/vendor"
  cp -r "$DRUSE_ROOT/web" "$tree/web"
  cp -r "$DRUSE_ROOT/vendor/odin-http" "$tree/vendor/odin-http"
  cat >"$tree/app/main.odin" <<ODIN
package main

import web "druse:web"

ping :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

main :: proc() {
	app := web.app()
	defer web.destroy(&app)
$use_line
	web.get(&app, "/ping", ping)
	web.serve(&app, 8080)
}
ODIN
  ( cd "$tree" && env ODIN_ROOT="$DRUSE_W22_ODIN_DIR" \
      PATH="$DRUSE_W22_ODIN_DIR:/usr/bin:/bin" \
      "$DRUSE_W22_ODIN" build app "-collection:druse=$tree" -out:app.bin >/dev/null ) ||
    fail "the $label consumer did not build; control 7 proved nothing"
  printf '%s' "$tree/app.bin"
}

DRUSE_W22_NEG_BIN="$(wp22_build_consumer never-logs "")"
DRUSE_W22_NEG="$(nm "$DRUSE_W22_NEG_BIN" 2>/dev/null | grep -cE "$DRUSE_W22_SYMS" || true)"

DRUSE_W22_POS_BIN="$(wp22_build_consumer does-log "	web.use(&app, web.logger)")"
DRUSE_W22_POS="$(nm "$DRUSE_W22_POS_BIN" 2>/dev/null | grep -cE "$DRUSE_W22_SYMS" || true)"

if test "$DRUSE_W22_POS" -eq 0; then
  fail "the POSITIVE control links no logger symbol either; the pattern /$DRUSE_W22_SYMS/ matches nothing, so the zero-assertion below would prove nothing"
fi

if test "$DRUSE_W22_NEG" -ne 0; then
  echo "--- logger symbols linked into an application that never names web.logger ---" >&2
  nm "$DRUSE_W22_NEG_BIN" | grep -E "$DRUSE_W22_SYMS" | sed 's/^[0-9a-f]* //' >&2
  fail "an application that never references web.logger links $DRUSE_W22_NEG logger symbol(s); the middleware must cost nothing when unused"
fi

echo "CONTROL 7: application that never names web.logger -> $DRUSE_W22_NEG logger symbols ($(stat -c%s "$DRUSE_W22_NEG_BIN") bytes)"
echo "CONTROL 7: application that DOES use web.logger    -> $DRUSE_W22_POS logger symbols ($(stat -c%s "$DRUSE_W22_POS_BIN") bytes) [positive control]"

echo "PASS: all seven WP22 mutation controls behaved as required"
