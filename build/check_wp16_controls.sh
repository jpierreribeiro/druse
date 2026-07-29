#!/usr/bin/env bash
# WP16 — the six required gate-restructuring controls, as one executable run.
#
# Each control below is ALSO enforced permanently: controls 1, 2, 3, 4 and 6
# live in build/check_wp3_mutations.sh (cases 57, 1, 58/58b, 61 and 59), which
# runs on every gate invocation, and control 5's guard is the freeze gate's
# own proc_group self-test plus its section 3b. This script exists so the six
# WP16 acceptance controls can be produced as one report, on demand, with
# every probe asserting its own edit applied — a probe that fails to mutate
# reports BROKEN PROBE, never a false verdict.
#
#   1  stray web/oops.odin                 -> MUST FAIL   (static)
#   2  extra export                        -> MUST FAIL   (static)
#   3  private parameter rename            -> MUST PASS   (static)
#   4  deleted ledger entry                -> MUST FAIL   (static)
#   5  private-member procedure group      -> MUST FAIL   (needs the pinned toolchain)
#   6  vendor patch re-applied differently -> MUST PASS   (static)
#
# Control 5 is the only one that needs the compiler (`odin doc` generates the
# inventory the freeze gate reads). Without a toolchain this script reports it
# BLOCKED and exits 2 — it never reports a control it did not run.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "WP16-CONTROL-FAIL: $*" >&2
  exit 1
}

DRUSE_W16_TMP="$(mktemp -d -t druse-wp16-controls-XXXXXXXX)"
trap 'rm -rf "$DRUSE_W16_TMP"' EXIT

# A minimal static tree: exactly what check_public_api.sh reads.
static_tree() {
  local t="$DRUSE_W16_TMP/static-$1"
  # web/internal now holds three private packages: check_public_api.sh (amended
  # by WP87/WP94) requires the subdir set to be EXACTLY {transport, stream,
  # ingest}, so the static tree must mirror all three or the subdir guard fires
  # before the control's own probe can. (transport was the only one this helper
  # copied until WP7.5-C1 found the staleness.)
  mkdir -p "$t/build" "$t/web/testing" "$t/web/internal/transport" \
    "$t/web/internal/stream" "$t/web/internal/ingest" "$t/tests" "$t/vendor"
  cp "$DRUSE_ROOT"/build/check_public_api.sh "$t/build/"
  cp "$DRUSE_ROOT"/build/check.sh "$t/build/"
  cp "$DRUSE_ROOT"/web/*.odin "$t/web/"
  cp "$DRUSE_ROOT"/web/testing/*.odin "$t/web/testing/"
  cp "$DRUSE_ROOT"/web/internal/transport/*.odin "$t/web/internal/transport/"
  cp "$DRUSE_ROOT"/web/internal/stream/*.odin "$t/web/internal/stream/"
  cp "$DRUSE_ROOT"/web/internal/ingest/*.odin "$t/web/internal/ingest/"
  cp -r "$DRUSE_ROOT"/vendor/odin-http "$t/vendor/odin-http"
  cp -r "$DRUSE_ROOT"/tests/. "$t/tests/"
  printf '%s' "$t"
}

assert_mutated() { # label file before-hash
  local after
  after="$(md5sum "$2" | cut -d' ' -f1)"
  test "$3" != "$after" ||
    fail "BROKEN PROBE ($1): the edit left ${2##*/} unchanged; this control would prove nothing"
}

must_fail() { # tree label expected-substring
  local out
  if out="$(bash "$1/build/check_public_api.sh" 2>&1)"; then
    echo "$out" >&2
    fail "control '$2' PASSED the checker; it is required to FAIL"
  fi
  grep -qF "$3" <<<"$out" || { echo "$out" >&2; fail "control '$2' failed for the wrong reason; expected: $3"; }
  echo "CONTROL $2 -> FAILED as required"
}

must_pass() { # tree label
  local out
  if ! out="$(bash "$1/build/check_public_api.sh" 2>&1)"; then
    echo "$out" >&2
    fail "control '$2' was REJECTED; a behaviour-preserving refactor must pass with no gate edit"
  fi
  echo "CONTROL $2 -> PASSED as required"
}

# --- 1. stray web/oops.odin — MUST FAIL --------------------------------------
T="$(static_tree oops)"
printf 'package web\n\n@(private)\noops :: proc() {}\n' >"$T/web/oops.odin"
test -f "$T/web/oops.odin" || fail "BROKEN PROBE (stray file): oops.odin was not created"
must_fail "$T" "1: stray web/oops.odin" "declares no ledger"

# --- 2. extra export — MUST FAIL ---------------------------------------------
T="$(static_tree extra)"
printf '\nwp16_extra_export :: proc() {}\n' >>"$T/web/serve.odin"
must_fail "$T" "2: extra export" "exports symbols outside the ratified Phase-1 surface"

# --- 3. private parameter rename — MUST PASS ---------------------------------
T="$(static_tree rename)"
H="$(md5sum "$T/web/response.odin" | cut -d' ' -f1)"
sed -i -E 's/^response_commit :: proc\(res: \^Response, status: Status, headers: \[\]Header_Pair, body: \[\]u8\) -> bool \{$/response_commit :: proc(target: ^Response, code: Status, header_pairs: []Header_Pair, payload: []u8) -> bool {/' \
  "$T/web/response.odin"
assert_mutated "private parameter rename" "$T/web/response.odin" "$H"
must_pass "$T" "3: private parameter rename (response_commit)"

# --- 4. deleted ledger entry — MUST FAIL -------------------------------------
T="$(static_tree deleted)"
H="$(md5sum "$T/web/errors.odin" | cut -d' ' -f1)"
sed -i '/^unauthorized :: proc/d' "$T/web/errors.odin"
assert_mutated "deleted ledger entry" "$T/web/errors.odin" "$H"
must_fail "$T" "4: deleted ledger entry" "web/ is missing part of the ratified Phase-1 surface"

# --- 6. vendor patch re-applied differently — MUST PASS ----------------------
# (Run before 5 so a missing toolchain blocks nothing static.)
T="$(static_tree vendor)"
H="$(md5sum "$T/vendor/odin-http/body.odin" | cut -d' ' -f1)"
sed -i 's/if len(token) != 0 {/if len(token) > 0 {/' "$T/vendor/odin-http/body.odin"
assert_mutated "vendor patch respelled" "$T/vendor/odin-http/body.odin" "$H"
must_pass "$T" "6: vendor patch re-applied differently"

# --- 5. private-member procedure group — MUST FAIL (two layers) --------------
#
# Layer one: injecting an exported group over @(private) members must fail the
# freeze gate's snapshot diff. Layer two: "refreshing" the snapshot to launder
# the change must STILL fail, at section 3b — the named assertion that a group
# over private members is unfreezable (ADR-021 as amended). Both layers need
# `odin doc`, so this control requires the pinned toolchain.
DRUSE_W16_ODIN="${DRUSE_ODIN_BIN:-}"
if test -z "$DRUSE_W16_ODIN" && command -v odin >/dev/null 2>&1; then
  DRUSE_W16_ODIN="$(command -v odin)"
fi
if test -z "$DRUSE_W16_ODIN" && test -x /tmp/druse-toolchain/odin; then
  DRUSE_W16_ODIN=/tmp/druse-toolchain/odin
fi
if test -z "$DRUSE_W16_ODIN"; then
  echo "CONTROL 5: private-member proc group -> BLOCKED: no Odin toolchain found (set DRUSE_ODIN_BIN)." >&2
  echo "The five static controls above ran and passed; control 5 DID NOT RUN." >&2
  exit 2
fi

F="$DRUSE_W16_TMP/freeze"
mkdir -p "$F"
# The freeze gate resolves evidence citations against the whole tree, so the
# control tree is a full copy of the repository (sans VCS metadata).
( cd "$DRUSE_ROOT" && tar --exclude=.git -cf - . ) | ( cd "$F" && tar -xf - )

cat >>"$F/web/serve.odin" <<'ODIN'

@(private)
wp16_group_member_a :: proc(x: int) -> int {
	return x
}
@(private)
wp16_group_member_b :: proc(x: string) -> int {
	return len(x)
}
wp16_probe_group :: proc {
	wp16_group_member_a,
	wp16_group_member_b,
}
ODIN

if OUT="$( cd "$F" && env DRUSE_ODIN_BIN="$DRUSE_W16_ODIN" bash build/check_phase1_freeze.sh 2>&1 )"; then
  echo "$OUT" >&2
  fail "control '5: private-member proc group' layer 1 PASSED; the freeze gate no longer notices an injected exported group"
fi
grep -qF "no longer matches" <<<"$OUT" ||
  { echo "$OUT" >&2; fail "control 5 layer 1 failed for the wrong reason; expected the snapshot diff"; }
echo "CONTROL 5 (layer 1: injected group vs snapshot) -> FAILED as required"

# Layer two: launder the snapshot with the diff the gate itself printed, then
# require the 3b rejection to fire anyway.
grep -E '^\s*\+(application|test-support)\s' <<<"$OUT" | sed -E 's/^\s*\+//' \
  >>"$F/build/phase1-public-signatures.txt"
LC_ALL=C sort -o "$F/build/phase1-public-signatures.txt" "$F/build/phase1-public-signatures.txt"
if OUT2="$( cd "$F" && env DRUSE_ODIN_BIN="$DRUSE_W16_ODIN" bash build/check_phase1_freeze.sh 2>&1 )"; then
  echo "$OUT2" >&2
  fail "control '5' layer 2 PASSED: a refreshed snapshot laundered a private-member group past the freeze gate; the 3b guard is dead"
fi
grep -qF "not itself exported" <<<"$OUT2" ||
  { echo "$OUT2" >&2; fail "control 5 layer 2 failed for the wrong reason; expected the 3b private-member-group rejection"; }
echo "CONTROL 5 (layer 2: snapshot laundering vs 3b) -> FAILED as required"

echo "PASS: all six WP16 controls behaved as required"
