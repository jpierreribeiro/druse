#!/usr/bin/env bash
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_PIN_FILE="$DRUSE_ROOT/odin-version.txt"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

test -f "$DRUSE_PIN_FILE" || fail "missing odin-version.txt"
DRUSE_EXPECTED_COMMIT="$(sed -n 's/^commit=//p' "$DRUSE_PIN_FILE")"
test -n "$DRUSE_EXPECTED_COMMIT" || fail "missing commit pin"

if test -n "${DRUSE_ODIN_BIN:-}"; then
  DRUSE_COMPILER="$DRUSE_ODIN_BIN"
elif command -v odin >/dev/null 2>&1; then
  DRUSE_COMPILER="$(command -v odin)"
elif test -x /tmp/druse-toolchain/odin; then
  DRUSE_COMPILER=/tmp/druse-toolchain/odin
else
  fail "odin not found; install the pinned distribution or set DRUSE_ODIN_BIN"
fi

DRUSE_COMPILER="$(readlink -f "$DRUSE_COMPILER")" ||
  fail "cannot resolve compiler path: $DRUSE_COMPILER"
test -x "$DRUSE_COMPILER" || fail "compiler is not executable: $DRUSE_COMPILER"
DRUSE_COMPILER_DIR="$(cd "$(dirname "$DRUSE_COMPILER")" && pwd)"
if ! DRUSE_VERSION="$(ODIN_ROOT="$DRUSE_COMPILER_DIR" \
  "$DRUSE_COMPILER" version 2>&1)"; then
  fail "compiler version check failed: $DRUSE_VERSION"
fi
case "$DRUSE_VERSION" in
  *"$DRUSE_EXPECTED_COMMIT"*) ;;
  *) fail "compiler mismatch: expected commit $DRUSE_EXPECTED_COMMIT, got: $DRUSE_VERSION" ;;
esac

test -d "$DRUSE_COMPILER_DIR/core/net" || fail "pinned core:net package missing"
test -d "$DRUSE_COMPILER_DIR/core/nbio" || fail "pinned core:nbio package missing"
test -d "$DRUSE_COMPILER_DIR/core/encoding/json" ||
  fail "pinned core:encoding/json package missing"
command -v clang >/dev/null 2>&1 ||
  fail "clang not found; Odin needs it to link runnable checks"
command -v rg >/dev/null 2>&1 ||
  fail "rg not found; documentation and evidence controls require ripgrep"

bash -n "$DRUSE_ROOT/build/check.sh"
bash -n "$DRUSE_ROOT/build/check_test.sh"
bash -n "$DRUSE_ROOT/build/check_public_api.sh"
bash -n "$DRUSE_ROOT/build/check_wp3_mutations.sh"
bash -n "$DRUSE_ROOT/build/check_wp9_mutations.sh"
bash -n "$DRUSE_ROOT/build/check_merged_fix_mutations.sh"
bash -n "$DRUSE_ROOT/build/check_typegate_controls.sh"
bash -n "$DRUSE_ROOT/build/check_m8_controls.sh"
bash -n "$DRUSE_ROOT/build/check_m9_controls.sh"
bash -n "$DRUSE_ROOT/build/check_g11_teardown.sh"
bash -n "$DRUSE_ROOT/build/check_examples.sh"
bash -n "$DRUSE_ROOT/build/check_docs.sh"
bash -n "$DRUSE_ROOT/build/check_phase1_freeze.sh"
bash -n "$DRUSE_ROOT/build/check_wp16_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp17_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp18_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp19_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp20_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp21_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp22_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp23_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp24_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp25_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp26_bench.sh"
bash -n "$DRUSE_ROOT/build/check_wp30_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp36_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp37_controls.sh"
bash -n "$DRUSE_ROOT/build/check_phase2_freeze.sh"
bash -n "$DRUSE_ROOT/build/check_phase3_freeze.sh"
bash -n "$DRUSE_ROOT/build/check_phase4_spec.sh"
bash -n "$DRUSE_ROOT/build/check_phase4_freeze.sh"
bash -n "$DRUSE_ROOT/build/check_wp39_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp41_controls.sh"
bash -n "$DRUSE_ROOT/build/check_phase5_freeze.sh"
bash -n "$DRUSE_ROOT/build/check_phase6_spec.sh"
bash -n "$DRUSE_ROOT/build/check_phase7_spec.sh"
bash -n "$DRUSE_ROOT/build/check_phase7_freeze.sh"
bash -n "$DRUSE_ROOT/build/check_wp87_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp88_controls.sh"
bash -n "$DRUSE_ROOT/build/check_c01_controls.sh"
bash -n "$DRUSE_ROOT/build/check_readiness_matrix.sh"
bash -n "$DRUSE_ROOT/build/check_c03_controls.sh"
bash -n "$DRUSE_ROOT/build/check_c04_controls.sh"
bash -n "$DRUSE_ROOT/build/check_c04b_controls.sh"
bash -n "$DRUSE_ROOT/build/check_security_backlog.sh"
bash -n "$DRUSE_ROOT/build/check_h3_controls.sh"
bash -n "$DRUSE_ROOT/build/check_c1_controls.sh"
bash -n "$DRUSE_ROOT/build/check_c2_controls.sh"
bash -n "$DRUSE_ROOT/build/check_c3_controls.sh"
bash -n "$DRUSE_ROOT/build/check_c4_controls.sh"
bash -n "$DRUSE_ROOT/build/check_c6_controls.sh"
bash -n "$DRUSE_ROOT/build/check_c7_controls.sh"
bash -n "$DRUSE_ROOT/build/check_c05_controls.sh"
bash -n "$DRUSE_ROOT/build/check_c06_controls.sh"
bash -n "$DRUSE_ROOT/build/check_c07_controls.sh"
bash -n "$DRUSE_ROOT/build/check_c08_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp68_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp70_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp71_controls.sh"
bash -n "$DRUSE_ROOT/build/check_wp72_controls.sh"
bash -n "$DRUSE_ROOT/build/check_r1_shutdown_controls.sh"
bash -n "$DRUSE_ROOT/build/check_supported_profile.sh"
bash -n "$DRUSE_ROOT/build/check_pilot_runbooks.sh"
bash -n "$DRUSE_ROOT/build/check_pilot_exercise.sh"
bash -n "$DRUSE_ROOT/build/check_r1_freeze.sh"
bash -n "$DRUSE_ROOT/build/check_vendor_policy.sh"
bash -n "$DRUSE_ROOT/build/check_release_identity.sh"
bash -n "$DRUSE_ROOT/ops/release/approve-artefact.sh"
bash -n "$DRUSE_ROOT/ops/release/verify-deployed.sh"
bash -n "$DRUSE_ROOT/build/check_wp38_controls.sh"
bash -n "$DRUSE_ROOT/build/install-hooks.sh"
bash -n "$DRUSE_ROOT/experiments/run_checks.sh"
bash -n "$DRUSE_ROOT/.githooks/pre-push"
bash -n "$DRUSE_ROOT/ops/ci/run.sh"
bash -n "$DRUSE_ROOT/ops/ci/status.sh"
bash -n "$DRUSE_ROOT/ops/ci/install-odin.sh"
bash -n "$DRUSE_ROOT/ops/verification/run-r1-freeze.sh"
bash -n "$DRUSE_ROOT/ops/soak/preflight.sh"
bash -n "$DRUSE_ROOT/ops/soak/smoke.sh"

# `odin test` writes its runner executable into the CURRENT WORKING DIRECTORY.
# It removes it again on success — but NOT when the test run fails, which drops
# a ~650 KiB ELF binary into the repository root on exactly the runs a developer
# is already iterating on. Every test binary is therefore given an explicit
# `-out:` under one temporary directory, so a red gate can never leave an
# artifact in the working tree. The directory lives in $TMPDIR, never in the repo.
DRUSE_BIN_TMP="$(mktemp -d -t druse-test-bin-XXXXXXXX)"

echo "toolchain version: $DRUSE_VERSION"
echo "toolchain commit: $DRUSE_EXPECTED_COMMIT"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  bash "$DRUSE_ROOT/experiments/run_checks.sh"

# WP1 — the public package must compile and its compile contract must hold.
# `web` is a library package, so -no-entry-point is required: without it the
# pinned compiler reports "Undefined entry point procedure 'main'".
echo "--- WP1 public API package (odin check) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" check "$DRUSE_ROOT/web" \
  "-collection:druse=$DRUSE_ROOT" -no-entry-point

echo "--- WP1 public API compile contract (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp1-public-api" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp1-public-api"

# WP2 — the request/response model.
#
# `Response`, `response_commit`, `method_from_token` and `Header_Pair` are
# package-private, and on the pinned toolchain an `@(test)` procedure must be
# compiled as part of the package it tests. Compiling those tests inside `web/`
# would link `core:testing` into every application binary (+41,592 bytes,
# measured on 819fdc7), so the shipped package contains no test file at all.
#
# Instead the gate assembles a THROWAWAY package: the real sources from `web/`
# plus `tests/wp2-internal/`, copied into a fresh `mktemp -d` directory. The
# tests therefore run against the genuine sources, not a stand-in. The
# directory is removed afterwards, including when the test run fails — the trap
# fires on the `set -e` exit. `build/check_public_api.sh` permanently forbids
# `*_test.odin` and `core:testing` under `web/`, so this cannot regress.
echo "--- WP2 request/response model, internal behavior (throwaway package) ---"
DRUSE_TMP_PKG="$(mktemp -d -t druse-wp2-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_TMP_PKG"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_TMP_PKG/"
cp "$DRUSE_ROOT"/tests/wp2-internal/*.odin "$DRUSE_TMP_PKG/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_TMP_PKG" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp2-internal"
rm -rf "$DRUSE_TMP_PKG"
trap - EXIT
test ! -d "$DRUSE_TMP_PKG" ||
  fail "the throwaway internal-test package was not removed"
echo "PASS: internal tests ran against the real sources; throwaway package removed"

echo "--- WP2 public surface contract (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp2-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp2-public-surface"

# WP2 compile probes. A negative probe must fail to compile AND fail for the
# stated reason: an unrelated compile error must never be read as proof that a
# symbol is unreachable.
DRUSE_PROBES="$DRUSE_ROOT/tests/wp2-public-surface/probes"

druse_negative_probe() { # file expected-diagnostic label
  local file="$1" expected="$2" label="$3"
  local output
  echo "--- WP2 probe: $label (expected compile failure) ---"
  # The compile is EXPECTED to fail, so it is run as the condition of an `if`:
  # under `set -e` a bare assignment from a failing command would abort here.
  if output="$(env ODIN_ROOT="$DRUSE_COMPILER_DIR" \
    PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
    "$DRUSE_COMPILER" check "$DRUSE_PROBES/$file" -file \
    "-collection:druse=$DRUSE_ROOT" -no-entry-point 2>&1)"; then
    echo "$output" >&2
    fail "probe '$label' compiled; the symbol it must not reach is reachable"
  fi
  if ! grep -qF "$expected" <<<"$output"; then
    echo "$output" >&2
    fail "probe '$label' failed for the wrong reason; expected: $expected"
  fi
  echo "PASS: $label"
}

druse_negative_probe header_pair_not_exported.odin \
  "'Header_Pair' is not exported by 'web'" \
  "Header_Pair is not nameable from outside the package"

druse_negative_probe header_view_internal_not_exported.odin \
  "'Header_View_Internal' is not exported by 'web'" \
  "Header_View_Internal is not nameable from outside the package"

druse_negative_probe context_has_no_response.odin \
  "has no field 'response'" \
  "Context exposes no public response field"

# The matching POSITIVE probe records an accepted fact rather than a feature:
# `Header_View` is encapsulated BY CONTRACT, not opaque. If this ever stopped
# compiling, the documentation would be claiming a barrier Odin does not give.
echo "--- WP2 probe: internal slot stays reachable (expected compile success) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" check "$DRUSE_PROBES/internal_slot_is_reachable.odin" -file \
  "-collection:druse=$DRUSE_ROOT" -no-entry-point ||
  fail "the encapsulation-by-contract probe stopped compiling; ADR-008's scope statement would be wrong"
echo "PASS: encapsulation is by contract, not a barrier (ADR-008 scope confirmed)"

# WP3 — in-memory test transport (facade in package `web`, machinery in
# `web/testing`). The dependency is one-way: `web` imports `web/testing`, and
# `web/testing` imports neither `druse:web` (cycle) nor `core:testing`.
#
# Probe C1 — the machinery compiles ALONE as neutral, core-only code.
echo "--- WP3 probe C1: web/testing machinery compiles alone (neutral, core-only) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" check "$DRUSE_ROOT/web/testing" \
  "-collection:druse=$DRUSE_ROOT" -no-entry-point
echo "PASS: web/testing compiles as standalone machinery (C1)"

# Probe C2 — the facade compiles importing the machinery. `odin check web` above
# (the WP1 step) already exercised this once web/test_support.odin exists; this
# line names it as the ratified C2 evidence.
echo "--- WP3 probe C2: web facade compiles importing web/testing ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" check "$DRUSE_ROOT/web" \
  "-collection:druse=$DRUSE_ROOT" -no-entry-point
echo "PASS: web imports web/testing one-way (C2)"

# WP3 machinery internal behavior — copy/lifetime/ownership tests, in a
# THROWAWAY package exactly like WP2: the machinery sources plus the out-of-tree
# test file, so the shipped machinery ships no test code.
echo "--- WP3 machinery internal behavior (throwaway package) ---"
DRUSE_WP3_TMP="$(mktemp -d -t druse-wp3-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP3_TMP"' EXIT
cp "$DRUSE_ROOT"/web/testing/*.odin "$DRUSE_WP3_TMP/"
cp "$DRUSE_ROOT"/tests/wp3-internal/*.odin "$DRUSE_WP3_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP3_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp3-internal"
rm -rf "$DRUSE_WP3_TMP"
trap - EXIT
test ! -d "$DRUSE_WP3_TMP" || fail "the throwaway WP3 machinery-test package was not removed"
echo "PASS: machinery internal tests ran against the real sources; throwaway package removed"

# WP3 public surface — external consumer of `druse:web` that RUNS
# `web.test_request` (probe C4): it completes with no socket, and its result is
# readable as status/body. Memory tracking (default in `odin test`) enforces the
# lazy-state and cleanup claims.
echo "--- WP3 public surface contract, incl. C4 in-memory round trip (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp3-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp3-public-surface"

# WP3 negative probe — RE-AIMED BY WP49. `Recorded_Response.headers` now
# exists (D-14.3 decided), so the probe pins its SHAPE instead of its absence:
# entries are wire-form strings, never a pair type or a map. A negative probe
# that is deleted is a guarantee that quietly disappeared.
DRUSE_WP3_PROBE="$DRUSE_ROOT/tests/wp3-public-surface/probes/recorded_response_has_no_headers.odin"
echo "--- WP3 probe: Recorded_Response.headers carries strings, not pairs (expected compile failure) ---"
if DRUSE_WP3_OUT="$(env ODIN_ROOT="$DRUSE_COMPILER_DIR" \
  PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" check "$DRUSE_WP3_PROBE" -file \
  "-collection:druse=$DRUSE_ROOT" -no-entry-point 2>&1)"; then
  echo "$DRUSE_WP3_OUT" >&2
  fail "probe compiled; Recorded_Response.headers entries are addressable as pairs. They must be wire-form strings: a pair type would export Header_Pair onto the public surface, and a map would export a lookup contract and an allocation (WP49)."
fi
# The expected diagnostic moved with the probe (WP49). Matching on the message
# is what stops a probe passing because of an unrelated compile error — a
# BROKEN PROBE that reports a guarantee it never tested.
if ! grep -qF "of type 'string' has no field 'name'" <<<"$DRUSE_WP3_OUT"; then
  echo "$DRUSE_WP3_OUT" >&2
  fail "the recorded-headers probe failed for the wrong reason; expected the entry to be a string with no 'name' field"
fi
echo "PASS: Recorded_Response.headers carries strings, not pairs"

# Probe C5 — the back-edge `web/testing -> web` is a COMPILE CYCLE. Copy the two
# packages into a throwaway tree, inject the committed back-edge fixture into the
# copied machinery, and check the copied facade: it must fail with the exact
# cyclic-import diagnostic. This is the versioned WP3 C5 contract.
echo "--- WP3 probe C5: web/testing -> web back-edge is a compile cycle (expected failure) ---"
DRUSE_WP3_CYCLE="$(mktemp -d -t druse-wp3-cycle-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP3_CYCLE"' EXIT
mkdir -p "$DRUSE_WP3_CYCLE/web/testing" "$DRUSE_WP3_CYCLE/web/internal/transport" \
  "$DRUSE_WP3_CYCLE/vendor/odin-http"
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP3_CYCLE/web/"
cp "$DRUSE_ROOT"/web/testing/*.odin "$DRUSE_WP3_CYCLE/web/testing/"
# WP8: `web` now imports the transport, which imports the vendored backend, so
# the throwaway tree must carry both or the probe fails to resolve an import
# instead of reporting the cycle it exists to prove.
cp "$DRUSE_ROOT"/web/internal/transport/*.odin "$DRUSE_WP3_CYCLE/web/internal/transport/"
# WP90b: the transport now also imports the stream and (via WP94) ingest
# lifecycle packages; the throwaway tree carries them for the same reason it
# carries the backend.
mkdir -p "$DRUSE_WP3_CYCLE/web/internal/stream" "$DRUSE_WP3_CYCLE/web/internal/ingest"
cp "$DRUSE_ROOT"/web/internal/stream/*.odin "$DRUSE_WP3_CYCLE/web/internal/stream/"
cp "$DRUSE_ROOT"/web/internal/ingest/*.odin "$DRUSE_WP3_CYCLE/web/internal/ingest/"
cp "$DRUSE_ROOT"/vendor/odin-http/*.odin "$DRUSE_WP3_CYCLE/vendor/odin-http/"
cp "$DRUSE_ROOT"/tests/wp3-probes/back_edge_import.odin "$DRUSE_WP3_CYCLE/web/testing/"
if DRUSE_WP3_CYCLE_OUT="$(env ODIN_ROOT="$DRUSE_COMPILER_DIR" \
  PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" check "$DRUSE_WP3_CYCLE/web" \
  "-collection:druse=$DRUSE_WP3_CYCLE" -no-entry-point 2>&1)"; then
  echo "$DRUSE_WP3_CYCLE_OUT" >&2
  fail "the back-edge compiled; web/testing -> web must be a compile cycle (C5)"
fi
# EITHER side of the cycle is acceptable evidence. The compiler names whichever
# package it reaches first, and that depends on import-resolution order — WP6
# added `core:` imports to `web/` and flipped the reported side from
# 'web_testing' to 'web' without changing the fact being proven. Matching one
# exact spelling made this probe fail for a reason that had nothing to do with
# the dependency direction it exists to enforce.
if ! grep -qE "Cyclic importation of '(web|web_testing)'" <<<"$DRUSE_WP3_CYCLE_OUT"; then
  echo "$DRUSE_WP3_CYCLE_OUT" >&2
  fail "the back-edge failed for the wrong reason; expected a cyclic-import diagnostic naming 'web' or 'web_testing'"
fi
rm -rf "$DRUSE_WP3_CYCLE"
trap - EXIT
echo "PASS: the one-way dependency is enforced by the compiler (C5)"

# WP4 — route registration, matching and dispatch.
#
# The route table, the matcher, `dispatch` and the private parameter storage in
# `Context_Internal` are all package-private, so these tests run in a THROWAWAY
# package exactly like WP2 and WP3: the real `web/` sources plus the
# out-of-tree test file, copied into a fresh `mktemp -d`.
#
# Two WP4 contracts are only observable from inside the package: the exact
# `Allow` header (Recorded_Response has no public headers field) and a routed
# 200 with a real body (the public responders are inert until WP6). Both are
# still driven through the REAL registration + dispatch path.
echo "--- WP4 route registration and dispatch, internal behavior (throwaway package) ---"
DRUSE_WP4_TMP="$(mktemp -d -t druse-wp4-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP4_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP4_TMP/"
cp "$DRUSE_ROOT"/tests/wp4-internal/*.odin "$DRUSE_WP4_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP4_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp4-internal"
rm -rf "$DRUSE_WP4_TMP"
trap - EXIT
test ! -d "$DRUSE_WP4_TMP" || fail "the throwaway WP4 internal-test package was not removed"
echo "PASS: WP4 internal tests ran against the real sources; throwaway package removed"

# WP4 public surface — an EXTERNAL consumer of `druse:web` that registers
# routes and drives them through `web.test_request`. It proves that routing is
# expressible with the ratified 34 symbols and adds none, and that `app()` and
# `bare()` are now observably different. Memory tracking (default in
# `odin test`) covers the App-owned route table's cleanup.
echo "--- WP4 public surface contract: routing, 404, 405, bare (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp4-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp4-public-surface"

# WP5 — the canonical path/query extractors and their private 400 envelope.
#
# The envelope machinery, the request-local storage it writes into, and the
# captured `Route_Param` that `web.path` reads are all package-private, so these
# tests run in a THROWAWAY package exactly like WP2, WP3 and WP4: the real
# `web/` sources plus the out-of-tree test file, copied into a fresh `mktemp -d`.
#
# Three WP5 contracts are only observable from inside the package: the exact
# bytes of the committed envelope, that the envelope body lives in request-local
# Context storage rather than an allocation, and that `web.path` consumes WP4's
# private capture (there is no public `ctx.params`). All are driven through the
# real extractors, and every envelope assertion is validated by the OFFICIAL
# `core:encoding/json` parser in strict `.JSON` mode.
echo "--- WP5 canonical extractors, internal behavior (throwaway package) ---"
DRUSE_WP5_TMP="$(mktemp -d -t druse-wp5-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP5_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP5_TMP/"
cp "$DRUSE_ROOT"/tests/wp5-internal/*.odin "$DRUSE_WP5_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP5_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp5-internal"
rm -rf "$DRUSE_WP5_TMP"
trap - EXIT
test ! -d "$DRUSE_WP5_TMP" || fail "the throwaway WP5 internal-test package was not removed"
echo "PASS: WP5 internal tests ran against the real sources; throwaway package removed"

# WP5 public surface — an EXTERNAL consumer of `druse:web` that reads path and
# query parameters through the ratified surface only, and observes a failing
# `path_int` as a complete 400 through `web.test_request`. It proves extraction
# is expressible with the ratified 34 symbols and adds none.
echo "--- WP5 public surface contract: path/query extraction and the 400 envelope ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp5-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp5-public-surface"

# WP5 negative probes — ADR-002 option B is enforced by the COMPILER.
#
# The value-producing extractors omit `#optional_ok`, so dropping `ok` must be a
# compile error. Each probe is required to fail with the exact `Assignment count
# mismatch` diagnostic: an unrelated compile error must never be read as proof
# that the directive is absent.
#
# `#optional_ok` is not part of a procedure's TYPE, so the signature assertions
# in the public contract test cannot see it. These probes are the only executable
# evidence that the directive was not re-added (R-07).
DRUSE_WP5_PROBES="$DRUSE_ROOT/tests/wp5-public-surface/probes"

druse_wp5_discard_probe() { # file label
  local file="$1" label="$2"
  local output
  echo "--- WP5 probe: $label (expected compile failure) ---"
  if output="$(env ODIN_ROOT="$DRUSE_COMPILER_DIR" \
    PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
    "$DRUSE_COMPILER" check "$DRUSE_WP5_PROBES/$file" -file \
    "-collection:druse=$DRUSE_ROOT" -no-entry-point 2>&1)"; then
    echo "$output" >&2
    fail "probe '$label' compiled; the extractor permits dropping ok, so #optional_ok is present (ADR-002)"
  fi
  if ! grep -qF "Assignment count mismatch" <<<"$output"; then
    echo "$output" >&2
    fail "probe '$label' failed for the wrong reason; expected: Assignment count mismatch"
  fi
  echo "PASS: $label"
}

druse_wp5_discard_probe discard_path_int_ok.odin \
  "dropping the ok of path_int is rejected"
druse_wp5_discard_probe discard_query_int_ok.odin \
  "dropping the ok of query_int is rejected"
druse_wp5_discard_probe discard_query_int_or_ok.odin \
  "dropping the ok of query_int_or is rejected"

# WP6 — response rendering, body ownership and the error envelope.
#
# The `Response`, both commit primitives, `response_destroy`, the envelope
# machinery and the typed framework-error report are all package-private, so
# these tests run in a THROWAWAY package exactly like WP2-WP5.
#
# Four WP6 contracts are only observable from inside the package: who OWNS a
# rendered body and whether the teardown released it exactly once; the exact
# `Content-Type` (Phase 1 ratifies no header accessor); that a rejected commit
# FREES the body it could not transfer; and that a marshal failure is LOGGED
# BEFORE the 500 is committed. Memory tracking (default in `odin test`) is what
# turns the ownership claims into assertions.
echo "--- WP6 response rendering and ownership, internal behavior (throwaway package) ---"
DRUSE_WP6_TMP="$(mktemp -d -t druse-wp6-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP6_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP6_TMP/"
cp "$DRUSE_ROOT"/tests/wp6-internal/*.odin "$DRUSE_WP6_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP6_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp6-internal"
rm -rf "$DRUSE_WP6_TMP"
trap - EXIT
test ! -d "$DRUSE_WP6_TMP" || fail "the throwaway WP6 internal-test package was not removed"
echo "PASS: WP6 internal tests ran against the real sources; throwaway package removed"

# WP6 public surface — an EXTERNAL consumer driving every responder end-to-end
# through `web.test_request`. It proves the response contract is expressible with
# the ratified 34 symbols and adds none, and that bodies handed back earlier stay
# valid after later requests render and tear down their own buffers.
echo "--- WP6 public surface contract: responders, envelopes, automatic 404/405 ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp6-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp6-public-surface"

# WP7 — JSON body binding, the 4 MiB cap, and the request-lifetime arena.
#
# The arena, the body-consumption state, `Context_Internal` and the typed report
# are all package-private, so these tests run in a THROWAWAY package exactly like
# WP2-WP6. Memory tracking (default in `odin test`) is what turns the arena
# ownership and no-leak claims into assertions, and the internal tests reach the
# private `Body_State` and `request_arena_*` machinery directly.
echo "--- WP7 body binding and the request arena, internal behavior (throwaway package) ---"
DRUSE_WP7_TMP="$(mktemp -d -t druse-wp7-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP7_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP7_TMP/"
cp "$DRUSE_ROOT"/tests/wp7-internal/*.odin "$DRUSE_WP7_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP7_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp7-internal"
rm -rf "$DRUSE_WP7_TMP"
trap - EXIT
test ! -d "$DRUSE_WP7_TMP" || fail "the throwaway WP7 internal-test package was not removed"
echo "PASS: WP7 internal tests ran against the real sources; throwaway package removed"

# WP7 public surface — an EXTERNAL consumer binding a body through the ratified
# surface. It proves body binding is expressible with the ratified 34 symbols and
# adds none, and that a body handler driven by `web.test_request` tears down
# cleanly.
echo "--- WP7 public surface contract: body binding, single-consumer, envelopes ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp7-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp7-public-surface"

# WP8 — the real transport adapter, the response-driver finalization, and one
# end-to-end socket round-trip.
#
# The driver finalization and the neutral-boundary conversions are
# package-private, so the internal tests run in a THROWAWAY package like
# WP2-WP7.
echo "--- WP8 driver finalization and boundary, internal behavior (throwaway package) ---"
DRUSE_WP8_TMP="$(mktemp -d -t druse-wp8-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP8_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP8_TMP/"
cp "$DRUSE_ROOT"/tests/wp8-internal/*.odin "$DRUSE_WP8_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP8_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp8-internal"
rm -rf "$DRUSE_WP8_TMP"
trap - EXIT
test ! -d "$DRUSE_WP8_TMP" || fail "the throwaway WP8 internal-test package was not removed"
echo "PASS: WP8 internal tests ran against the real sources; throwaway package removed"

# WP8 transport boundary compile probes — the one-way dependency (ADR-009).
#
# C1: the adapter package compiles standalone (it names no web type).
echo "--- WP8 probe: web/internal/transport compiles standalone ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" check "$DRUSE_ROOT/web/internal/transport" \
  "-collection:druse=$DRUSE_ROOT" -no-entry-point
echo "PASS: the transport adapter compiles as standalone neutral code"

# WP8 real-socket round-trip. It binds a loopback port, so it runs under an
# EXTERNAL timeout and is the only test that touches a real socket. It cleans up
# its server and thread even on failure, and never sends SIGINT to this runner.
echo "--- WP8 real-socket contract: GET /ping, POST JSON, 413, clean stop (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp8-socket" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp8-socket" ||
  fail "the WP8 real-socket contract did not pass within the timeout"

# WP9 — TRANSPORT CONFORMANCE.
#
# Three layers, deliberately separate (WP9 D1):
#
#   the CONTRACT suite is everything above (WP1-WP8), on the in-memory
#   transport, not duplicated per backend;
#
#   SEMANTIC conformance runs ONE shared matrix through TWO factories. The
#   in-memory factory is an internal test, because it must drive the same
#   private `driver_run`/`driver_cleanup` pipeline the real transport uses —
#   that shared pipeline is what makes parity structural rather than a claim
#   (R-10). The socket factory is an external consumer;
#
#   RAW-WIRE conformance runs ONLY against the real adapter, because the
#   in-memory transport has no TCP parser and cannot prove framing safety.
echo "--- WP9 semantic conformance: in-memory factory (throwaway package) ---"
DRUSE_WP9_TMP="$(mktemp -d -t druse-wp9-semantic-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP9_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP9_TMP/"
cp "$DRUSE_ROOT"/tests/wp9-semantic-internal/*.odin "$DRUSE_WP9_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP9_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp9-semantic-internal"
rm -rf "$DRUSE_WP9_TMP"
trap - EXIT
test ! -d "$DRUSE_WP9_TMP" || fail "the throwaway WP9 semantic package was not removed"
echo "PASS: the semantic matrix passes on the in-memory transport"

echo "--- WP9 semantic conformance: real HTTP factory (odin test) ---"
timeout 180 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp9-semantic" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp9-semantic" ||
  fail "the semantic matrix did not pass on the real HTTP transport within the timeout"

# The raw-wire corpus binds a real port and sends deliberately malformed bytes.
# It runs under an EXTERNAL timeout: a hang is a FAILURE, never a stall of the
# gate — an adapter that waits forever on a malformed request is exactly the
# defect this corpus exists to catch.
echo "--- WP9 raw-wire conformance: framing corpus against the real adapter ---"
timeout 240 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp9-wire" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp9-wire" ||
  fail "the raw-wire framing corpus did not pass within the timeout"

echo "--- WP9 public surface: the conformance harness adds no public symbol ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp9-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp9-public-surface"

# WP14 — request bodies are reachable in memory. This is the first Phase-2
# capability to land, and its parity assertions matter more than its convenience
# one: the 4 MiB cap and the JSON errors must behave identically here and on a
# socket, or the in-memory transport stops being trustworthy (R-10).
echo "--- WP14 request bodies through the memory transport (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp14-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp14-public-surface"

# WP14 part 2 — query strings. `web.query`, `query_int` and `query_int_or` are
# frozen Phase-1 symbols that could not be exercised in memory at all until now.
# The arena-release assertion here is the one that matters: without it, removing
# driver_cleanup left every behavioral test green, because a leak changes no
# status and no body. That mutation survived until the assertion existed.
echo "--- WP14 query strings through the memory transport (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp14-query" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp14-query"

# WP17 — middleware: `use`, `next`, the flattened chains, the miss chain and
# the ADR-019 fail-closed guard.
#
# The chain pool, the cursor, the miss machinery and the poison predicate are
# all package-private, so the internal tests run in a THROWAWAY package exactly
# like WP2-WP9. The zero-allocation dispatch claim and the poisoning-allocator
# pool-growth reproduction (WP12 P8/P9 made permanent) live here.
echo "--- WP17 middleware chains, internal behavior (throwaway package) ---"
DRUSE_WP17_TMP="$(mktemp -d -t druse-wp17-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP17_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP17_TMP/"
cp "$DRUSE_ROOT"/tests/wp17-internal/*.odin "$DRUSE_WP17_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP17_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp17-internal"
rm -rf "$DRUSE_WP17_TMP"
trap - EXIT
test ! -d "$DRUSE_WP17_TMP" || fail "the throwaway WP17 internal-test package was not removed"
echo "PASS: WP17 internal tests ran against the real sources; throwaway package removed"

# WP17 public surface — an EXTERNAL consumer registering middleware through the
# ratified surface. The security test lives here: the WP12 D-12.5 mis-ordered
# auth program, which measured `/admin/users -> 200 OK` to an unauthenticated
# caller, must fail closed.
echo "--- WP17 public surface contract: use, next, ordering, fail-closed (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp17-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp17-public-surface"

# WP17 socket contract — `serve` refuses to start on a poisoned application
# (ADR-019). If the guard regressed, `serve` would bind and block, so this runs
# under an EXTERNAL timeout like every socket suite: a hang is a failure, never
# a stalled gate.
echo "--- WP17 socket contract: serve refuses a poisoned app (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp17-socket" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp17-socket" ||
  fail "the WP17 socket refusal contract did not pass within the timeout"

# WP18 — route organisation: `Router`, `router`, `mount`.
#
# The mounted entries' composed chains, the closed flag and the poison
# propagation are package-private, so the internal tests run in a THROWAWAY
# package exactly like WP2-WP17.
echo "--- WP18 Router and mount, internal behavior (throwaway package) ---"
DRUSE_WP18_TMP="$(mktemp -d -t druse-wp18-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP18_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP18_TMP/"
cp "$DRUSE_ROOT"/tests/wp18-internal/*.odin "$DRUSE_WP18_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP18_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp18-internal"
rm -rf "$DRUSE_WP18_TMP"
trap - EXIT
test ! -d "$DRUSE_WP18_TMP" || fail "the throwaway WP18 internal-test package was not removed"
echo "PASS: WP18 internal tests ran against the real sources; throwaway package removed"

# WP18 public surface — an EXTERNAL consumer building and mounting routers
# through the ratified surface. The load-bearing pin lives here: every ^App
# procedure accepts a ^Router UNCHANGED (subtype polymorphism), so the WP17
# signature pins survive byte-identical.
echo "--- WP18 public surface contract: Router, router, mount (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp18-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp18-public-surface"

# WP19 — request header lookup: `header`, `bearer_token`, the ADR-027 overlay
# read path, and the `test_request` headers parameter.
#
# The overlay slot, Header_Pair and the facade's line splitter are
# package-private, so the internal tests run in a THROWAWAY package exactly
# like WP2-WP18.
echo "--- WP19 header lookup, internal behavior (throwaway package) ---"
DRUSE_WP19_TMP="$(mktemp -d -t druse-wp19-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP19_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP19_TMP/"
cp "$DRUSE_ROOT"/tests/wp19-internal/*.odin "$DRUSE_WP19_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP19_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp19-internal"
rm -rf "$DRUSE_WP19_TMP"
trap - EXIT
test ! -d "$DRUSE_WP19_TMP" || fail "the throwaway WP19 internal-test package was not removed"
echo "PASS: WP19 internal tests ran against the real sources; throwaway package removed"

# WP19 public surface — an EXTERNAL consumer reading headers through the
# ratified surface; the canonical bearer-auth middleware pattern end to end.
echo "--- WP19 public surface contract: header, bearer_token, headers param (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp19-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp19-public-surface"

# WP20 — the typed framework-error observer: `observe`, `Framework_Event`,
# and the now-public `Framework_Error`.
#
# The emit helpers, the Context-carried observer slot and the recorded route
# pattern are package-private, so the internal tests run in a THROWAWAY
# package exactly like WP2-WP19.
echo "--- WP20 framework-error observer, internal behavior (throwaway package) ---"
DRUSE_WP20_TMP="$(mktemp -d -t druse-wp20-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP20_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP20_TMP/"
cp "$DRUSE_ROOT"/tests/wp20-internal/*.odin "$DRUSE_WP20_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP20_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp20-internal"
rm -rf "$DRUSE_WP20_TMP"
trap - EXIT
test ! -d "$DRUSE_WP20_TMP" || fail "the throwaway WP20 internal-test package was not removed"
echo "PASS: WP20 internal tests ran against the real sources; throwaway package removed"

# WP20 public surface — an EXTERNAL consumer registering an observer. The
# redaction guarantee is visible here as a SIGNATURE: an observer receives the
# event by value and nothing else, so it cannot respond or read a request byte
# the event does not carry.
echo "--- WP20 public surface contract: observe, Framework_Event (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp20-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp20-public-surface"

# WP20 socket contract — `Serve_Listen_Failed` needs a genuinely occupied port,
# so it is the one variant that cannot be provoked in memory. Under an
# EXTERNAL timeout like every socket suite: a `serve` that blocked instead of
# returning would hang, and a hang is a failure, never a stalled gate.
echo "--- WP20 socket contract: listen failure is observed (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp20-socket" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp20-socket" ||
  fail "the WP20 socket observer contract did not pass within the timeout"

# ---------------------------------------------------------------------------
# WP21 — THE FAULT-BEHAVIOUR GUARANTEE (ADR-020; zero public symbols).
#
# `driver_run`, the private Response and `ERROR_BODY_INTERNAL` are all
# package-private, so the internal half runs in a THROWAWAY package exactly
# like WP2-WP20.
# ---------------------------------------------------------------------------
echo "--- WP21 fault behaviour, internal (throwaway package) ---"
DRUSE_WP21_TMP="$(mktemp -d -t druse-wp21-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP21_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP21_TMP/"
cp "$DRUSE_ROOT"/tests/wp21-internal/*.odin "$DRUSE_WP21_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP21_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp21-internal"
rm -rf "$DRUSE_WP21_TMP"
trap - EXIT
test ! -d "$DRUSE_WP21_TMP" || fail "the throwaway WP21 internal-test package was not removed"
echo "PASS: WP21 internal tests ran against the real sources; throwaway package removed"

# The consumer-visible half. It imports nothing from the machinery on purpose:
# ADR-020's whole point is that an application relies on this guarantee WITHOUT
# a symbol to call, so the suite that proves it must have nothing to call.
#
# IT RUNS TWICE — default and `-o:speed`. The Phase-2 Test Gate item names both
# build modes, and it names them because WP13 measured that build mode changes
# which faults exist at all: `-o:speed` elides bounds checks that `-o:none`
# performs. A guarantee proven only at the default optimization level is not
# the guarantee the phases doc records.
echo "--- WP21 fault-behaviour contract, default build (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp21-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp21-public-surface"

echo "--- WP21 fault-behaviour contract, -o:speed build (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp21-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -o:speed \
  -out:"$DRUSE_BIN_TMP/wp21-public-surface-speed" ||
  fail "the WP21 fault-behaviour contract does not hold at -o:speed"

# WP21 over a real socket. WP8 opened a socket but never drove a FAULTING
# request across it, so "under BOTH web.serve and web.test_request" rested on
# its weaker transport. A zero status has no wire representation, which is
# exactly why this belongs on a socket. External timeout, like every socket
# suite.
echo "--- WP21 fault behaviour over a real socket (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp21-socket" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp21-socket" ||
  fail "the WP21 socket fault-behaviour contract did not pass within the timeout"

# item 5b — dual-stack bind over a real socket. It belongs on a socket for the
# same reason WP21 does: the property (an IPv4 client reaches a `::` listener
# and its client_ip is the UNMAPPED dotted-quad, and an IPv6 client reaches the
# same listener) has no in-memory representation — test_request has no socket
# family. Without the peer unmapping an IPv4 client on a dual-stack socket would
# render as `::ffff:...` and silently break trust_proxies (ADR-046). External
# timeout, like every socket suite.
echo "--- item 5b dual-stack bind + IPv4-mapped peer unmapping over a real socket (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/item5b-dual-stack" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/item5b-dual-stack" ||
  fail "the item-5b dual-stack socket contract did not pass within the timeout"

# ---------------------------------------------------------------------------
# WP22 — THE `logger` MIDDLEWARE (application ledger 42 -> 43).
#
# The line buffer, its bounds, the escaper and the commit-guard helper are all
# package-private, so the internal half runs in a THROWAWAY package exactly
# like WP2-WP21.
# ---------------------------------------------------------------------------
echo "--- WP22 logger, internal behavior: the fixed buffer and its truncation contract (throwaway package) ---"
DRUSE_WP22_TMP="$(mktemp -d -t druse-wp22-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP22_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP22_TMP/"
cp "$DRUSE_ROOT"/tests/wp22-internal/*.odin "$DRUSE_WP22_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP22_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp22-internal"
rm -rf "$DRUSE_WP22_TMP"
trap - EXIT
test ! -d "$DRUSE_WP22_TMP" || fail "the throwaway WP22 internal-test package was not removed"
echo "PASS: WP22 internal tests ran against the real sources; throwaway package removed"

# WP22 public surface — an EXTERNAL consumer of the logged LINE. For this one
# component the output IS the contract, so the suite asserts the exact bytes:
# the route field is the registered pattern and never the path, the status is
# the committed one or `-`, and no query, header or body byte ever appears.
echo "--- WP22 public surface contract: web.logger and the bytes it writes (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp22-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp22-public-surface"

# ---------------------------------------------------------------------------
# WP23 — THE `request_id` MIDDLEWARE AND ITS TRUST POLICY (ledger 43 -> 44).
#
# The committed Response, the overlay slot, the request-local ID storage and
# the validator are all package-private, so the internal half runs in a
# THROWAWAY package exactly like WP2-WP22. It is where the SECURITY assertions
# live: `Recorded_Response` exposes no headers by design, so "a rejected value
# never reaches a response header" is unobservable from outside the package.
# ---------------------------------------------------------------------------
echo "--- WP23 request_id, internal behavior: response header, overlay, validator (throwaway package) ---"
DRUSE_WP23_TMP="$(mktemp -d -t druse-wp23-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP23_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP23_TMP/"
cp "$DRUSE_ROOT"/tests/wp23-internal/*.odin "$DRUSE_WP23_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP23_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp23-internal"
rm -rf "$DRUSE_WP23_TMP"
trap - EXIT
test ! -d "$DRUSE_WP23_TMP" || fail "the throwaway WP23 internal-test package was not removed"
echo "PASS: WP23 internal tests ran against the real sources; throwaway package removed"

# WP23 public surface — the TRUST POLICY as an external consumer meets it: a
# CR/LF value is discarded rather than repaired, an oversized one is replaced,
# and a well-formed one is honoured.
echo "--- WP23 public surface contract: request_id trust policy (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp23-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp23-public-surface"

# WP27 — the allocation audit. Where per-request allocation actually goes, for
# the three items the post-Phase-1 audit named (A-8, A-12, A-13).
#
# It runs as a THROWAWAY internal package because two of the three procedures
# under measurement — `inbound_header_pairs` and
# `response_headers_neutral_transport` — are `@(private)`. Measuring them
# through a public surface would be measuring something else and calling it
# these.
#
# WP27 measures and decides; it changes no behaviour. The decisions are recorded
# in planning/history/allocation-audit.md, and the fixes belong to WP29 and WP35 where
# they can be regression-tested against the WP26 baseline.
echo "--- WP27 allocation audit: A-8, A-12, A-13, measured (throwaway package) ---"
DRUSE_WP27_TMP="$(mktemp -d -t druse-wp27-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP27_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP27_TMP/"
cp "$DRUSE_ROOT"/tests/wp27-internal/*.odin "$DRUSE_WP27_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP27_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp27-internal"
rm -rf "$DRUSE_WP27_TMP"
trap - EXIT
test ! -d "$DRUSE_WP27_TMP" || fail "the throwaway WP27 internal-test package was not removed"
echo "PASS: WP27 allocation audit ran against the real sources; throwaway package removed"

# WP35 — R-16 measured. Not a happy-state document: this suite is the TRIPWIRE
# for the moment a later work package pools something, and WP36's timeouts are
# the likeliest candidate. If it goes red it has done its job and must not be
# "fixed" by weakening it.
echo "--- WP35 arena and oversize policy: R-16 measured (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp35-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp35-public-surface"

# WP33 — more than one path parameter. No public symbol: web.path and
# web.path_int keep their signatures and stay the one canonical accessor. The
# suite pins the bound AND what happens past it, because the capacity ledger
# does not accept a bound without that half.
echo "--- WP33 multi-parameter routes without a map (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp33-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp33-public-surface"

# WP36 — configurable limits. THREE public symbols, ledger 47 -> 50, and the
# least reversible change in the phase. The suite spends most of itself on the
# two expensive failures: an application that configures NOTHING must behave
# exactly as before, and both transports must enforce the same number — which is
# why the budget lives on the App and not on `serve`.
echo "--- WP36 configurable limits: Limits, DEFAULT_LIMITS, limits (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp36-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp36-public-surface"

# WP37 — typed application state. TWO public symbols, ledger 45 -> 47. ADR-004
# option A only: ONE value, APP-scoped, set before serving. There is no
# request-scoped state and there will not be one (ADR-028, accepted) — the suite
# pins what ships, and `check_examples.sh` keeps a comment from scheduling what
# does not.
echo "--- WP37 typed application state: app_with_state and state (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp37-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp37-public-surface"

# WP34 — route identity. ONE public symbol, ledger 44 -> 45. The suite pins the
# signature by assignment and spends the rest of itself on WHICH STRING comes
# back: the registered pattern, never the request path. The static half of that
# rule lives in check_public_api.sh §8b, which checks every write to the slot —
# a test can only check the routes someone thought to write.
echo "--- WP34 route identity: the pattern, never the path (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp34-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp34-public-surface"

# WP30 — registration conflict diagnostics. NO public symbol: the five verbs and
# `mount` keep their frozen signatures, and registration still reports through
# the ADR-019 mechanism rather than a return value. The public suite sees only
# what an application can see — the 500 — and spends most of its tests on the
# routes that must KEEP serving, because a rejection rule that quietly grew
# would break applications that were correct when they were written.
echo "--- WP30 registration conflicts: the public half (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp30-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp30-public-surface"

# The internal half: `poisoned` is private, the diagnostic goes to the log, and
# which branch `serve` took is not observable from outside the package. All
# three are the contract, so the suite runs as a throwaway internal package
# against the real sources — the WP2-WP18 arrangement.
echo "--- WP30 registration conflicts: diagnose and poison (throwaway package) ---"
DRUSE_WP30_TMP="$(mktemp -d -t druse-wp30-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP30_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP30_TMP/"
cp "$DRUSE_ROOT"/tests/wp30-internal/*.odin "$DRUSE_WP30_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP30_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp30-internal"
rm -rf "$DRUSE_WP30_TMP"
trap - EXIT
test ! -d "$DRUSE_WP30_TMP" || fail "the throwaway WP30 internal-test package was not removed"
echo "PASS: WP30 conflict diagnostics ran against the real sources; throwaway package removed"

# WP32b — automatic HEAD and OPTIONS.
#
# It runs as a THROWAWAY internal package for a reason that is itself the
# design: `web.test_request` takes a `Method`, and `Method` has no HEAD and no
# OPTIONS. Both are resolved from the raw token before a `Method` value exists,
# so the frozen six-member enum stays byte-for-byte as the gate pins it — and a
# public-surface suite that COULD send either method would be evidence the enum
# had grown.
echo "--- WP32b automatic HEAD and OPTIONS (throwaway package) ---"
DRUSE_WP32_TMP="$(mktemp -d -t druse-wp32-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP32_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP32_TMP/"
cp "$DRUSE_ROOT"/tests/wp32-internal/*.odin "$DRUSE_WP32_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP32_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp32-internal"
rm -rf "$DRUSE_WP32_TMP"
trap - EXIT
test ! -d "$DRUSE_WP32_TMP" || fail "the throwaway WP32 internal-test package was not removed"
echo "PASS: WP32b HEAD/OPTIONS ran against the real sources; throwaway package removed"

# WP31b — the path policy. Rejection rules, and the much larger set that is NOT
# rejected: a policy that quietly grew would break applications whose paths were
# legal the day they were written. The trailing-slash case has its own test
# because the obvious implementation of the interior-empty-segment rule breaks
# `/users/`, a legal Phase-1 pattern.
echo "--- WP31b path policy: reject, do not transform (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp31-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp31-public-surface"

# WP28 — the route representation shootout, correctness half.
#
# It asserts that seven representations return byte-identical answers, and that a
# disagreement is CONSTRUCTIBLE — because "the candidates agree" would otherwise
# be true of a harness that called the same matcher seven times. A representation
# that misses a route looks magnificent in a benchmark; a scan that stops early
# is exactly what fast looks like from outside.
#
# No timing is asserted (FINDING-E). The numbers come from tests/wp28-runner,
# run by hand, and are recorded in planning/history/router-shootout.md.
echo "--- WP28 route shootout: seven representations must agree (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp28-shootout" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp28-shootout"

env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" build "$DRUSE_ROOT/tests/wp28-runner" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp28-runner"
echo "PASS: the WP28 shootout runner still builds"

# WP26 — the benchmark harness. Phase 3 may not start without one (entry
# condition E-3), and this step is what makes the instrument trustworthy.
#
# It asserts NO TIMING, on purpose. FINDING-A measured five different binaries
# from an identical source tree, so code layout — and therefore branch
# prediction and cache behaviour — varies between builds. A gate that failed on
# a timing delta would fail randomly, and a gate that fails randomly gets
# switched off. What it asserts is that the instrument is sound: percentiles
# return observed values, the tolerance derivation is relative and needs more
# than one run, the sweep covers the whole route table rather than route 0
# forever, every benchmarked response is verified AND the verification is able
# to fail, and per-dispatch allocation is exactly deterministic.
#
# The timings themselves come from `build/check_wp26_bench.sh`, which is run by
# hand — it takes ~15 minutes — and recorded in planning/phase-2-baseline.md.
echo "--- WP26 benchmark harness: the instrument, not the numbers (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp26-bench" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp26-bench"

# The baseline runner must keep COMPILING even though the gate never runs it.
# A measurement program that silently stopped building would be discovered at
# the moment someone needed a baseline, which is the worst possible moment.
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" build "$DRUSE_ROOT/tests/wp26-runner" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp26-runner"
echo "PASS: the WP26 baseline runner still builds"

# G-11 — the test-support teardown must not ship in applications that never
# test. Promised by planning/public-api-guardrails.md and, until now, never
# actually asserted.
echo "--- G-11 test-support teardown cost (nm) ---"
env DRUSE_COMPILER="$DRUSE_COMPILER" bash "$DRUSE_ROOT/build/check_g11_teardown.sh"

# WP10 — the three Phase-1 examples are part of the compatibility contract:
# they compile in this gate, or the documentation that teaches them is wrong.
# WP10 — the documentation fragments compile. A `<!-- fragment: -->` marker in a
# doc claims the snippet is real Phase-1 code; this is what makes that true.
echo "--- WP10 documentation fragments (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp10-doc-fixtures" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp10-doc-fixtures"

echo "--- WP10 example programs (odin build) ---"
env DRUSE_COMPILER="$DRUSE_COMPILER" bash "$DRUSE_ROOT/build/check_examples.sh"

# WP10 — documentation parity. It reads the canonical ledger out of
# check_public_api.sh, so the reference cannot drift from the package while both
# still look green.
echo "--- WP10 documentation parity ---"
bash "$DRUSE_ROOT/build/check_docs.sh"

echo "--- Phase-1 public API anti-accretion contract ---"
bash "$DRUSE_ROOT/build/check_public_api.sh"

echo "--- WP3 mutation checks: forbidden dual-ledger states are rejected ---"
bash "$DRUSE_ROOT/build/check_wp3_mutations.sh"

# WP11 — the Phase-1 freeze. Every step above proves a BEHAVIOR; this one proves
# that the SHAPE of the frozen contract, the dependency set beneath it and the
# evidence trail behind it are exactly what planning/phase-1-freeze.md records.
# It runs last on purpose: it is the step that turns a green gate into a freeze,
# and it should only ever be reached with every behavior already proven.
echo "--- WP11 Phase-1 spec freeze (signatures, dependencies, evidence) ---"
env DRUSE_ODIN_BIN="$DRUSE_COMPILER" bash "$DRUSE_ROOT/build/check_phase1_freeze.sh"

# WP25 — the PHASE-2 freeze. Phase 1 froze symbols, signatures and dependencies;
# this one freezes the project's own SENTENCES: the claim ledger (every strong
# promise carries a negative control and a stated non-guarantee), the lifetime
# ledger, and the capacity ledger — including what this framework does NOT
# bound. Prose has no compiler, and drifts while every test stays green.
echo "--- WP25 Phase-2 freeze (claims, lifetimes, capacities) ---"
bash "$DRUSE_ROOT/build/check_phase2_freeze.sh"

# WP38 — the Phase-3 freeze. Same shape as the Phase-2 gate and one lesson
# older: it pins Phase 3's totals as HISTORY rather than comparing them to the
# live count, because a freeze document that must be edited whenever a later
# phase ships is not a freeze. It also re-runs the usage-laboratory instrument
# and enforces the ADR-029 stopping condition — a guarded program past 25
# concepts is a reserved matter and stops for the owner.
echo "--- WP38 Phase-3 freeze (ledgers amended, suites re-run, budget enforced) ---"
bash "$DRUSE_ROOT/build/check_phase3_freeze.sh"

# WP39/WP40 — the Phase-4 specs. They ship no symbol, which is exactly why they
# need a gate: a zero-symbol package's deliverable is a guarantee plus a
# statement, and an unchecked statement decays into folklore (the WP21 lesson).
echo "--- WP39/WP40 Phase-4 spec (lifecycle states, capacity rows, the reservation) ---"
bash "$DRUSE_ROOT/build/check_phase4_spec.sh"

# WP56 — the Phase-4 freeze. Same shape as its predecessors and one lesson
# older: it pins Phase 4's totals as HISTORY, and it holds the two things this
# phase would lose first — the record of what was NOT delivered, and the record
# that re-running the mutation suites REPAIRED three controls.
echo "--- WP56 Phase-4 freeze (ledger, deficiencies, undelivered work, repaired controls) ---"
bash "$DRUSE_ROOT/build/check_phase4_freeze.sh"

# WP65 — the Phase-5 freeze.
echo "--- WP65 Phase-5 freeze gate ---"
bash "$DRUSE_ROOT/build/check_phase5_freeze.sh"

# WP66 — the next phase starts from a question and thresholds fixed before the
# experiments. This gate also prevents the old roadmap/backlog from silently
# restoring the rules the owner amended.
echo "--- WP66 Phase-6 spec and governance gate ---"
bash "$DRUSE_ROOT/build/check_phase6_spec.sh"

# WP85 — Phase 7 also starts from thresholds fixed before its experiments. The
# gate pins the streaming capacity numbers, the ADR reopenings and the
# inherited ADR-039 work so a prototype cannot renegotiate them after a result.
echo "--- WP85 Phase-7 spec and governance gate ---"
bash "$DRUSE_ROOT/build/check_phase7_spec.sh"

# WP101 — the Phase-7 freeze. Pins the ledger diff (63 -> 68), the ten exit
# gates with G7-6/G7-9's honest deferrals, the non-deliveries and the design
# decisions a refactor would reverse.
echo "--- WP101 Phase-7 freeze gate ---"
bash "$DRUSE_ROOT/build/check_phase7_freeze.sh"

# WP87 — the streaming lifecycle corpus is committed RED under control: the
# buffered oracle green, both corpora failing completely for the sentinel's
# reason, and no sentinel package linked into the product.
echo "--- WP87 stream/body lifecycle corpus (RED under control) ---"
env DRUSE_COMPILER="$DRUSE_COMPILER" bash "$DRUSE_ROOT/build/check_wp87_controls.sh"

# WP88/WP89 — the registry and cross-lane delivery. The corpus flips green
# unedited; the generation-check mutation proves G7-3 is guarded by tests,
# not by luck; the package stays unlinked until WP90.
echo "--- WP88/WP89 stream registry and cross-lane delivery controls ---"
env DRUSE_COMPILER="$DRUSE_COMPILER" bash "$DRUSE_ROOT/build/check_wp88_controls.sh"

# WP67 — the desired decoder/schema suites are committed RED. The control
# proves each is red for the pre-registered reason and that the current 500 is
# identical on the memory and real-socket transports.
echo "--- WP67 JSON failure anatomy and RED controls ---"
env DRUSE_COMPILER="$DRUSE_COMPILER" bash "$DRUSE_ROOT/build/check_wp68_controls.sh"

# C-01 (Closure) — the async-operation inventory. It runs in the gate because
# its whole value is being unable to go stale: the census fails the build when
# an `nbio` operation is added without a row stating its owner, cancellation and
# deadline. That absence is what let the orphaned recv and the missing write
# deadline survive; a ledger nobody re-derives is a ledger that stops being true.
# H-1 (Hardening) — the security-backlog reconciliation. It runs in the gate so
# that a fix for any of the 14 scan findings going red is impossible to miss: the
# gate fails if a finding loses the named test that pins it.
echo "--- H-1 security backlog: 14 findings reconciled, each fix pinned by a test ---"
bash "$DRUSE_ROOT/build/check_security_backlog.sh"

echo "--- C-01 async-operation inventory: census, ten questions, interruption phases ---"
timeout 180 env DRUSE_COMPILER="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_c01_controls.sh"

# C-02 (Closure) — the resource x property matrix as a LIVING GATE. It is the
# single canonical list of what this core does and does not bound, and it runs
# here because the eleven parallel lists it replaced had already drifted into
# asserting that shipped features did not exist. A list that is not gated is a
# list that tells an operator to work around a solved problem.
# H-3 (Hardening) — web.Server_Stats / web.stats(). It runs in the gate because a
# counter that is not exercised silently stops moving, and the whole point of
# H-3 is that the send side stops being invisible.
echo "--- H-3 write observability: Server_Stats counters wired and proven ---"
timeout 120 env DRUSE_COMPILER="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_h3_controls.sh"

echo "--- C1 (F8-1): Status gains 409/413/429/503, wired and proven ---"
timeout 120 env DRUSE_ODIN_BIN="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_c1_controls.sh"

echo "--- C2 (F8-2/F8-4): set_header + bytes, wired and proven ---"
timeout 120 env DRUSE_ODIN_BIN="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_c2_controls.sh"

echo "--- C3 (F8-6): query_int_opt, wired and proven ---"
timeout 120 env DRUSE_ODIN_BIN="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_c3_controls.sh"

echo "--- C4 (F8-5): stream_live, wired and proven ---"
timeout 120 env DRUSE_ODIN_BIN="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_c4_controls.sh"

echo "--- C6 (F8-7): Expect: 100-continue honored, wired and proven ---"
timeout 60 bash "$DRUSE_ROOT/build/check_c6_controls.sh"

echo "--- C-02 readiness matrix: every resource x limit/deadline/cancel/saturation/metric/shutdown ---"
bash "$DRUSE_ROOT/build/check_readiness_matrix.sh"

# C-03 (Closure) — the closed fault-injection campaign. It runs in the gate
# because both defects it fixed are ones a green build would otherwise hide: an
# RST flood that starves admission, and a drain loop that ignored .Will_Close
# and so never ended for a `Connection: close` client. Neither showed up in any
# earlier suite, because both are STATES nobody drove rather than scenarios
# anybody thought of.
echo "--- C-03 fault campaign: RST flood, lane contention, disconnects, coincident deadlines ---"
timeout 300 env DRUSE_COMPILER="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_c03_controls.sh"

# C-04 (Closure) — response-memory attribution. It runs in the gate because RSS
# cannot identify a live owner: the socket soak checks short-run stability, the
# direct arena assertion proves oversize blocks are released, and its mutant
# proves that assertion can turn red.
echo "--- C-04 response memory: RSS high-water plus growing-arena reclamation ---"
timeout 180 env DRUSE_COMPILER="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_c04_controls.sh"

# C-04b (ADR-045) — the per-response size limit the C-04 audit specified and
# handed forward. It runs in the gate because it converts an out-of-memory that
# kills every in-flight request into one typed 500, and a guard that is not
# wired on the SHARED path would let test_request and a socket disagree (R-10) —
# exactly the divergence class the whole two-transport design exists to prevent.
echo "--- C-04b per-response limit: max_response_bytes replaces an over-limit response with a 500 ---"
timeout 120 env DRUSE_ODIN_BIN="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_c04b_controls.sh"

# C-08 (Closure) — the httprouter comparative corpus. It runs in the gate for
# two reasons that have nothing to do with performance: the BSD-3 attribution
# must survive, and the corpus is NEGATIVE — each case pins a deliberate
# difference from httprouter, so losing one silently permits a regression toward
# semantics this project refused on security grounds.
# C-05 (Closure) — combined saturation. It runs in the gate because the lab is
# what caught F-C05-1: an unbounded wait inside handler_lane_enter that wedged
# shutdown in 4 runs out of 6, past every deadline. A lab that only ran on
# demand would have let the regression back in.
echo "--- C-05 combined saturation: degradation, recovery, observability and bounded stop ---"
timeout 240 env DRUSE_COMPILER="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_c05_controls.sh"

# C-06 (Closure) — the reverse-proxy contract. It runs in the gate because the
# matrix DELEGATES TLS and total memory to this topology, and the project's own
# classification rule says a delegation is acceptable only if the topology is
# mandatory, documented AND TESTED. The third word is this gate.
echo "--- C-06 reverse-proxy contract: buffering off, and the trusted-hop client address ---"
timeout 180 env DRUSE_COMPILER="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_c06_controls.sh"

# R1-WP03 keeps C-06 as the fast behavioral fixture and adds the reviewed real
# proxy topology: pinned Caddy image, static invariants, mutation controls and
# native config validation when the immutable image is already available.
echo "--- R1-WP03 pinned Caddy topology: policy, negative controls and config validation ---"
timeout 180 env DRUSE_COMPILER="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_proxy_config.sh"

# R1-WP04 — one source of truth for the supported deployment profile. The
# checker derives the multi-server ceiling and vendor disposition count, then
# proves nine stale/false variants are rejected for their semantic reason.
echo "--- R1-WP04 normative supported profile and semantic controls ---"
bash "$DRUSE_ROOT/build/check_supported_profile.sh"

echo "--- R1-WP05 controlled-pilot policy and runbook controls ---"
bash "$DRUSE_ROOT/build/check_pilot_runbooks.sh"

echo "--- R1-WP06 deploy, crash/restart, drain and rollback controls ---"
timeout 180 env DRUSE_COMPILER="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_pilot_exercise.sh"

echo "--- R1-WP07 evidence-backed controlled-pilot freeze ---"
bash "$DRUSE_ROOT/build/check_r1_freeze.sh"

# C-07 (Closure) — the record and the verdict. It runs LAST of the Closure gates
# and it checks the verdict's own evidence: every artifact it cites still exists
# and is still wired into this gate, the exit condition is quoted verbatim rather
# than paraphrased, the one open defect is still named, and every deferral still
# carries a trigger. A verdict that outlives its evidence is a claim.
echo "--- C-07 Closure record and verdict: the evidence behind the verdict still stands ---"
bash "$DRUSE_ROOT/build/check_c07_controls.sh"

echo "--- C-08 httprouter negative corpus: precedence, no path correction, no catch-all ---"
env DRUSE_COMPILER="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_c08_controls.sh"

# WP51 — the vendor maintenance policy. It runs in the gate because it is the
# PRECONDITION for WP46: a patch that predates the policy governing patches is
# how a fork starts, and a policy nobody re-reads is how one starts quietly.
echo "--- WP51 vendor policy (provenance, patch dispositions, the corpus rule) ---"
bash "$DRUSE_ROOT/build/check_vendor_policy.sh"

# WP41 — the deterministic fault laboratory. Real sockets, seeded faults, a
# replayable trail. It runs in the gate rather than on demand because its two
# findings are LIVE defects: a truncated or trickling client is never
# disconnected. When a read deadline ships those assertions must be amended in
# the same change, and a suite nobody runs is a suite nobody amends.
echo "--- WP41 fault laboratory: seeded faults over real sockets (odin test) ---"
# WP91 hardening: this was the ONE socket suite running without the external
# timeout the 11f rule requires of every socket suite — and a failing run was
# observed to hang the whole gate (2026-07-23, a replay-determinism failure
# left a server thread alive). The timeout turns a hang into a failure.
timeout 300 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp41-fault" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp41-fault" ||
  fail "the WP41 fault laboratory did not pass within the timeout"

# WP48 — trusted proxies. The suite runs over `test_request`, which has no peer,
# and that is the sharpest test of the default: with nothing trusted, a forged
# X-Forwarded-For must be ignored however the App is configured.
echo "--- WP48 trusted proxies: the peer, never the header (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp48-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp48-public-surface"

# WP48 / ADR-037 — the RIGHT-TO-LEFT walk, internal because it needs a peer and
# `test_request` has none. A throwaway package (web sources + the internal
# test), driven through `driver_run` with an explicit `Inbound.peer`, proves a
# spoofed leftmost entry is ignored behind a trusted proxy.
echo "--- WP48 client_ip walks X-Forwarded-For from the right (throwaway package) ---"
DRUSE_WP48_TMP="$(mktemp -d -t druse-wp48-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP48_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP48_TMP/"
cp "$DRUSE_ROOT"/tests/wp48-internal/*.odin "$DRUSE_WP48_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP48_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp48-internal"
rm -rf "$DRUSE_WP48_TMP"
trap - EXIT
test ! -d "$DRUSE_WP48_TMP" || fail "the throwaway WP48 internal-test package was not removed"
echo "PASS: WP48 right-walk ran against the real sources; throwaway package removed"

# WP49 — secure headers, and the D-14.3 decision that made them testable from a
# public suite at all: `Recorded_Response.headers`.
echo "--- WP49 secure headers: opt-in, on every response (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp49-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp49-public-surface"

# WP50 — the observable drop policy. One integer, because a framework that
# exported a metrics abstraction would have chosen a vendor for its users.
echo "--- WP50 observability: the drop policy is observable (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp50-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp50-public-surface"

# WP60 — CORS. The public half: what an application can observe about its own
# policy, plus the five fail-closed configurations.
echo "--- WP60 CORS: the policy an application can observe (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp60-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp60-public-surface"

# WP60 — the preflight, internal for the WP32b reason: a preflight is an OPTIONS
# request and `Method` has no OPTIONS member. A public suite that could send one
# would be evidence the frozen enum had grown.
echo "--- WP60 CORS preflight (throwaway package) ---"
DRUSE_WP60_TMP="$(mktemp -d -t druse-wp60-internal-XXXXXXXX)"
trap 'rm -rf "$DRUSE_WP60_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_WP60_TMP/"
cp "$DRUSE_ROOT"/tests/wp60-internal/*.odin "$DRUSE_WP60_TMP/"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_WP60_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/wp60-internal"
rm -rf "$DRUSE_WP60_TMP"
trap - EXIT
test ! -d "$DRUSE_WP60_TMP" || fail "the throwaway WP60 internal-test package was not removed"
echo "PASS: WP60 preflight ran against the real sources; throwaway package removed"

# WP63 — multipart forms. Mostly the malformed cases: a parser that salvages
# what it can hands the handler a missing field that looks like a blank one.
echo "--- WP63 multipart forms: a malformed form yields nothing (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp63-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/wp63-public-surface"

# WP61 — static files. Mostly a corpus of what it REFUSES: traversal, encoded
# traversal, dotfiles, backslashes, empty segments, symlinks, oversized files.
echo "--- WP61 static files: the rejections are the feature (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp61-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/wp61-public-surface"
rm -rf "$DRUSE_ROOT/tests/wp61-public-surface/fixture"

# WP58/WP59 — the drain deadline. Under an EXTERNAL timeout, because the defect
# this suite was written against presents as a hang: a suite that hangs here
# would stall the gate rather than fail it, and "the gate is still running" is
# not a test result. The bound is generous — the suite's own phases take about
# four seconds — so a timeout means genuinely stuck, never slow.
echo "--- WP58/59 drain deadline: stop returns with connections held open (odin test) ---"
# RUNS PARALLEL SINCE WP123, and that is an assertion rather than a default.
# This suite used to need `-define:ODIN_TEST_THREADS=1`: `web.stop` acted on the
# process-global server without consulting the App it was handed, so
# `wp65_is_draining_is_false_until_stop` — which stops a SERVERLESS App twice —
# shut down the server `wp58_drain_anatomy` was measuring, and its eight
# keep-alive dials found nothing ("expected held to be 8, got 0"). Measured then
# on a 4-vCPU host: 3 failures in 15 runs parallel, 0 in 15 serialized.
#
# WP123 gave every App its own server handle, so a stop on an App that never
# served reaches nothing. Re-measured on the same host after the change: 15
# parallel runs, 15 green. Running it parallel is now the CONTROL — serializing
# it again would hide a regression in exactly the state this package changed,
# and `build/check_test.sh` fails if anyone does.
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  timeout 120 \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp58-drain" \
  "-collection:druse=$DRUSE_ROOT" \
  -out:"$DRUSE_BIN_TMP/wp58-drain" \
  || fail "the drain suite failed or timed out; a timeout means the drain is stuck, which is the defect it exists to catch"

# ---------------------------------------------------------------------------
# WP123 / ADR-018 — two servers in one process, each answering for itself.
#
# The suite the work package exists to turn green, and the one that would have
# been meaningless before it: each of its four tests starts TWO servers through
# `web.serve` and asserts that the counters, the stop, the stream registry and
# the upload admission belong to the App each was asked about. Deliberately
# PARALLEL (see build/check_test.sh) — running the tests concurrently is the
# capability this bought, and serializing them would prove nothing about it.
echo "--- WP123 two servers in one process, reporting and draining separately (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  timeout 120 \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp123-two-servers" \
  "-collection:druse=$DRUSE_ROOT" \
  -out:"$DRUSE_BIN_TMP/wp123-two-servers" \
  || fail "two servers in one process did not report or drain independently; a timeout means a stop reached the wrong server and the other is still blocked in serve"

bash "$DRUSE_ROOT/build/check_wp123_controls.sh"

# ---------------------------------------------------------------------------
# Suites that were in the tree but in no gate script.
#
# A test nobody runs is not coverage, and these were being CITED as coverage:
# `tests/wp7_5-c2-upload` is the behaviour evidence recorded in
# planning/phase-1-freeze.md for three frozen public symbols (`Upload`,
# `Upload_Config`, `enable_upload`); `tests/multipart-content` is the case the
# July audit identified as the one that actually catches the multipart defect
# (the similarly-named wp63 case does not, finding S2);
# `tests/h2-graceful-acquire` is the evidence in the closure record that a
# server which cannot acquire its event loop fails gracefully instead of
# aborting. All eleven orphans were run and pass; the six with a citation are
# wired in here. wp118-accept-multishot and g76-scale-sockets are left out
# deliberately, with their reasons, in build/check_suite_inventory.sh — which
# this gate RUNS, and which fails on any new orphan.
#
# `nbio-timeout` took three tries, and the middle one is the lesson. It was a
# genuine orphan -- three @(test) procedures the orphan detector could not see,
# because the detector lived in build/check_test.sh, which this gate only
# parses. Wiring it in made the gate pass here and fail on every fresh clone,
# because the suite was excluded through `.git/info/exclude` and existed in one
# working copy and nowhere else: a green local run standing in for a green
# build, which is diagnosability rule 4 with the machine as the hidden variable.
# It was taken back out, and then COMMITTED (OQ-34), which is what should have
# happened first. build/check_suite_inventory.sh now refuses any suite the gate
# names that git does not track, so this cannot recur silently.
#
# THREADS=1 for the ones that drive a server, and the REASON changed under this
# line without the line changing with it. It used to be "one server per
# process": `web.stop` acted on a process-global slot, so any test stopping any
# App stopped everyone's server. WP123 ended that. These suites are still
# serialized, for two reasons it did not touch — each keeps a test-local
# `g_server` of its own, and the repository has no port allocator, so they share
# hand-kept candidate lists. Neither is a framework constraint, and neither was
# measured away; see `tests/wp123-two-servers` for what parallel now looks like
# when a suite is written for it.
echo "--- Previously ungated suites: multipart, HEAD framing, ingest, upload ---"
for DRUSE_UNGATED in \
  multipart-content \
  head-content-length \
  ingest-leak \
  h2-graceful-acquire \
  nbio-timeout \
  wp7_5-c1-inbound-stream \
  wp7_5-c2-upload; do
  env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
    timeout 180 \
    "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/$DRUSE_UNGATED" \
    "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
    -out:"$DRUSE_BIN_TMP/$DRUSE_UNGATED" ||
    fail "tests/$DRUSE_UNGATED failed; it is cited as evidence for a merged fix or a frozen symbol"
done
echo "PASS: the previously ungated evidence suites run in the gate"

# The raw-wire corpus is only worth its runtime if its cases DETECT the defects
# they are named after. It could not report a failure at all until this
# session's logger fix, so that had never been established for any of them.
# The nine fixes merged in 44bdcda were controlled by hand at merge time. This
# asks whether anything in the tree still notices if they are reverted — the
# multipart one was guarded only by a suite CI did not run until this session.
# The public gate must exist and must run THIS script.
#
# It lives here, not in check_docs.sh, and the reason is a failure worth
# recording: it was in check_docs.sh first, and check_docs.sh is run by other
# controls against THROWAWAY COPIES of the tree that carry docs/ but not
# .github/. Those copies then failed a check about repository infrastructure,
# and check_wp21_controls.sh reported BROKEN PROBE -- correctly, because its
# baseline could no longer pass. A rule about the repository belongs in the
# script that only ever runs against the repository.
echo "--- The public gate exists and runs this script ---"
test -f "$DRUSE_ROOT/.github/workflows/gate.yml" ||
  fail "the GitHub Actions gate workflow is missing; the README's build badge would be a claim with nothing behind it"
grep -q 'bash build/check.sh' "$DRUSE_ROOT/.github/workflows/gate.yml" ||
  fail "the workflow no longer runs build/check.sh; a green badge would promise something weaker than this gate"
echo "PASS: the public workflow runs the same gate this script is"

# --- the platform claim and the assertion that proves it say the same thing ---
#
# The portability job passes only when the compile failure names one of four
# tokens, and README's Platform section quotes those tokens in prose. They were
# duplicated with nothing keeping them together: editing the README's sentence
# would fail nothing, and that paragraph is exactly where CI is supposed to send
# a reader. A claim and its proof drifting apart is the subject of
# planning/diagnosability.md, one layer out.
#
# `sched_yield` and `setsockopt_base` are the two symbols the README names, and
# the two a real Windows run reported for the first time on 2026-07-31 (PR #155)
# after the assertion was made to match the cause. If the transport stops
# binding them, both places move together, and this says so.
echo "--- The platform claim and its CI assertion agree ---"
for druse_symbol in sched_yield setsockopt_base; do
  grep -q "$druse_symbol" "$DRUSE_ROOT/.github/workflows/gate.yml" ||
    fail "the portability job no longer matches '$druse_symbol', but README's Platform section still names it as a symbol the compile stops at. One of the two is now false."
  grep -q "$druse_symbol" "$DRUSE_ROOT/README.md" ||
    fail "README's Platform section no longer names '$druse_symbol', but the portability job still accepts it as proof of the platform claim. The paragraph CI sends a reader back to must name what CI actually checked."
done
echo "PASS: README and the portability assertion name the same symbols"

# --- the supervisor contract: the shipped unit and the documents agree -------
#
# Same class of rule as the block above, and it belongs here for the same
# reason: it is about repository artefacts, not about the library.
#
# `ops/deploy/druse.service` is COPIED VERBATIM by the operator, and until
# 2026-07-31 nothing ever read it. Ten documents drifted to `Restart=always`
# against a unit shipping `Restart=on-failure`, and docs/operations.md
# contradicted itself between its §1 excerpt and its checklist. The positive
# case below is not evidence on its own -- 0b1fea8 is what a positive case with
# a typo in it proves -- so the gate MUTATES a throwaway copy and requires red.
# --- inventories: nothing in build/ or tests/ is unaccounted for -------------
#
# Two questions the gate could not answer about itself until 2026-07-31, both
# found by asking what a green run actually proves (diagnosability rule 4):
#
#   1. Is every control script in build/ EXECUTED, or only `bash -n`'d? Seventeen
#      were wired into a loop after an audit found four of them broken; nothing
#      stopped the next one from being forgotten.
#   2. Is every suite in tests/ RUN? A detector for this existed -- inside
#      check_test.sh, which this gate only parses, because check_test.sh invokes
#      this gate several times and calling it from here would recurse. So the
#      detector never ran, and tests/nbio-timeout sat unexecuted with three
#      @(test) procedures. The detector now lives in its own file, here.
#
# Cheap, no compiler, so they run early and fail fast.
echo "--- Inventory: every control script in build/ is executed ---"
bash "$DRUSE_ROOT/build/check_gate_inventory.sh" "$DRUSE_ROOT"

echo "--- Inventory: every test suite is gated or exempt on the record ---"
bash "$DRUSE_ROOT/build/check_suite_inventory.sh" "$DRUSE_ROOT"

# Both inventories are checks about omissions, so a green result from either is
# worth exactly what its negative control is worth. Mutate a copy and require
# red -- 0b1fea8 is what a positive case with a typo in it proves.
DRUSE_INV_PROBE="$(mktemp -d)"
trap 'rm -rf "$DRUSE_INV_PROBE"' EXIT
cp -r "$DRUSE_ROOT/build" "$DRUSE_ROOT/tests" "$DRUSE_INV_PROBE/"
printf '#!/usr/bin/env bash\necho unwired\n' \
  > "$DRUSE_INV_PROBE/build/check_zz_negative_control.sh"

# The orphan probe's name is BUILT AT RUNTIME and never appears as a literal in
# any file. It has to be: the probe copies build/ wholesale, so a name written
# literally here would travel into the copy, and check_suite_inventory.sh would
# find it "referenced" and clear it -- the control would pass by describing
# itself. That happened on the first attempt, which is why the name is $$.
DRUSE_ORPHAN_PROBE="zz-orphan-$$"
mkdir -p "$DRUSE_INV_PROBE/tests/$DRUSE_ORPHAN_PROBE"
printf 'package test_zz\nimport "core:testing"\n@(test)\nzz :: proc(t: ^testing.T) {}\n' \
  > "$DRUSE_INV_PROBE/tests/$DRUSE_ORPHAN_PROBE/zz_test.odin"

if bash "$DRUSE_ROOT/build/check_gate_inventory.sh" "$DRUSE_INV_PROBE" >/dev/null 2>&1; then
  fail "BROKEN CONTROL: the gate inventory passed against a build/ containing a control script nothing invokes. It is not detecting unwired scripts, so its green result above means nothing."
fi
if bash "$DRUSE_ROOT/build/check_suite_inventory.sh" "$DRUSE_INV_PROBE" >/dev/null 2>&1; then
  fail "BROKEN CONTROL: the suite inventory passed against a tests/ containing a suite no gate script runs. It is not detecting orphans, so its green result above means nothing."
fi
echo "PASS: both inventories detect an unwired script and an orphan suite (negative controls)"
rm -rf "$DRUSE_INV_PROBE"
trap - EXIT

echo "--- The supervisor contract: unit and documents agree ---"
bash "$DRUSE_ROOT/build/check_supervisor_contract.sh" "$DRUSE_ROOT"

DRUSE_SUPERVISOR_PROBE="$(mktemp -d)"
trap 'rm -rf "$DRUSE_SUPERVISOR_PROBE"' EXIT
cp -r "$DRUSE_ROOT/ops" "$DRUSE_ROOT/docs" "$DRUSE_SUPERVISOR_PROBE/"
sed -i 's/^Restart=on-failure/Restart=always/' \
  "$DRUSE_SUPERVISOR_PROBE/ops/deploy/druse.service"
if bash "$DRUSE_ROOT/build/check_supervisor_contract.sh" \
     "$DRUSE_SUPERVISOR_PROBE" >/dev/null 2>&1; then
  fail "BROKEN CONTROL: the supervisor contract check passed against a unit mutated to Restart=always while the documents still say on-failure. It is not detecting drift, so its green result above means nothing."
fi
sed -i 's/^Restart=always/Restart=on-failure/' \
  "$DRUSE_SUPERVISOR_PROBE/ops/deploy/druse.service"
sed -i '/^LimitNOFILE=/d' \
  "$DRUSE_SUPERVISOR_PROBE/ops/deploy/druse.service"
if bash "$DRUSE_ROOT/build/check_supervisor_contract.sh" \
     "$DRUSE_SUPERVISOR_PROBE" >/dev/null 2>&1; then
  fail "BROKEN CONTROL: the supervisor contract check passed after LimitNOFILE was removed. It is not guarding the R1 resource budget."
fi
echo "PASS: the supervisor contract check detects Restart drift and a missing LimitNOFILE (negative controls)"
rm -rf "$DRUSE_SUPERVISOR_PROBE"
trap - EXIT

echo "--- R1 runtime budget: derived limits and pre-bind negative controls ---"
bash "$DRUSE_ROOT/build/check_r1_resource_controls.sh" "$DRUSE_ROOT"

echo "--- R1 real-process shutdown: signals, sockets, exit status and supervisor bound ---"
env DRUSE_ODIN_BIN="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_r1_shutdown_controls.sh" "$DRUSE_ROOT"

echo "--- Merged-fix mutation controls (44bdcda stays guarded) ---"
env DRUSE_COMPILER="$DRUSE_COMPILER" bash "$DRUSE_ROOT/build/check_merged_fix_mutations.sh"

# The per-type JSON validation gate is an ADOPTED DEFAULT, so the gate must hold
# it to the two things adoption promises: the skip never skips a type that can
# carry a non-finite float, and the build-time rollback is a real validation
# rather than a decorative branch. Both positive states and three mutations.
echo "--- Per-type JSON validation gate: adopted default + rollback controls ---"
env DRUSE_ODIN_BIN="$DRUSE_COMPILER" bash "$DRUSE_ROOT/build/check_typegate_controls.sh"

echo "--- WP9 raw-wire corpus: mutation controls (the cases must detect) ---"
env DRUSE_COMPILER="$DRUSE_COMPILER" bash "$DRUSE_ROOT/build/check_wp9_mutations.sh"

# --- the mutation-control scripts, EXECUTED ------------------------------
#
# WHY THIS STAGE EXISTS. Seventeen control scripts were `bash -n`'d at the top
# of this gate and never run by it. An audit executed them: FOUR were broken,
# and had been for as long as nobody had looked.
#
#	check_wp20  the `observe` signature gained a guard; the mutation's
#	            pattern stopped matching, AND its probe tree copied only
#	            web/internal/transport, so it could not compile either
#	check_wp21  same tree problem — `ingest` and `stream` were added to
#	            web/internal later and the transport imports them
#	check_wp23  the request-id counter became an atomic add; the uniqueness
#	            guard has been unguarded since that refactor
#	check_wp36  the dispatched check moved behind an accessor
#
# A syntax check proves a script PARSES. It cannot prove the mutation still
# applies, that the probe tree still compiles, or that the suite still detects
# what the script is named after — and every one of those four failures is
# exactly the kind this project's evidence standard exists to catch. As
# check_wp9_mutations.sh puts it: an unapplied mutation is a control that
# stopped controlling.
#
# COST, measured: 261 s for all seventeen, the slowest being wp41 at 48 s.
# M6 — allocation failure on the response path is a degraded 500, not a dead
# process. The suite drives `copy_response` through an allocator rigged to fail
# at each of its allocations in turn; before the fix, budget 0 produced
# "Index 0 is out of range 0..<0" and Illegal_Instruction, which under ADR-020
# is the whole process. Serial: it asserts on a shared transport type and needs
# no ports.
# M8 — orphaned spool files are swept at boot, and nothing else in the
# directory is. A crash leaves partials behind and nothing removed them, so
# they accumulated across restarts until a disk filled. The suite's second half
# is the line the sweep must not cross: files the application put in the
# directory are not the framework's to delete. Serial: it owns a fixed port.
echo "--- M8 boot sweep of orphaned spool files (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/m8-spool-sweep" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/m8-spool-sweep" ||
  fail "the M8 boot-sweep contract did not pass within the timeout"
env DRUSE_COMPILER="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_m8_controls.sh"

# M9 — distinguish live per-connection retention from allocator/RSS high-water.
echo "--- M9 request-buffer retention: counting allocator + negative control ---"
timeout 240 env DRUSE_COMPILER="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_m9_controls.sh"

echo "--- M6 allocation-failure degradation on the response path (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/m6-allocation-failure" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/m6-allocation-failure" ||
  fail "the M6 allocation-failure contract did not pass within the timeout"

echo "--- mutation-control scripts (executed, not merely parsed) ---"
for druse_control in c7 wp16 wp17 wp18 wp19 wp20 wp21 wp22 wp23 wp24 wp25 \
                       wp30 wp36 wp37 wp38 wp39 wp41; do
  timeout 900 env DRUSE_ODIN_BIN="$DRUSE_COMPILER" \
    ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
    bash "$DRUSE_ROOT/build/check_${druse_control}_controls.sh" >/dev/null 2>&1 ||
    fail "build/check_${druse_control}_controls.sh did not pass. It is a MUTATION CONTROL: it weakens a guard and requires the suite named after it to go red. A failure here is either a real regression or a control that has gone stale against a refactor — and a stale control is the more likely, so check whether its patterns still match the code before doubting the code."
  echo "control: check_${druse_control}_controls.sh -> all mutations detected"
done

# Diagnosability of the release instrument itself. The mutation controls above
# prove a test CAN fail; this one proves that when the soak instrument fails,
# the artefact NAMES the cause. It was added after a 12-hour run counted 674
# transport failures and could explain none of them.
echo "--- soak instrument: a failure it observes is a failure it can name ---"
env DRUSE_COMPILER="$DRUSE_COMPILER" bash "$DRUSE_ROOT/build/check_soak_controls.sh"

# R2-WP03 — observability that does not compete with the load it describes.
# The soak instrument above can now name a failure it observes; this one proves
# the server can still be observed while it is failing. AUD-P2-009: `/stats` is
# an ordinary route on the Handler lanes, so under saturation it stops
# answering — and an absent scrape is indistinguishable from a lost packet.
# Seven mutants, because a control that only knows how to say "failed" is
# indistinguishable from a control that is broken.
echo "--- R2-WP03 observability: saturation is visible, and absence has a cause ---"
env DRUSE_COMPILER="$DRUSE_COMPILER" bash "$DRUSE_ROOT/build/check_r2_observability_controls.sh"

# R2-WP08 — the deployment-identity criterion, amended on 2026-08-03 after
# `verify-rebuild.sh` measured that this toolchain does not build byte-identical
# output for identical input. The criterion stopped asking the BUILD to be
# reproducible and started asking the ARTEFACT to be the same file. That is a
# stronger claim, and like every claim here it needs a mutant: M2 deploys a file
# of exactly the approved size with different content, which is the precise
# shape the rebuild measurement produced.
echo "--- R2-WP08 release identity: the deployed hash is the approved hash ---"
bash "$DRUSE_ROOT/build/check_release_identity.sh"

# The benchmark summary must notice when two servers did not do the same work.
# It did not, once, and a comparison of four servers went out in which one
# answered with 21.6% more bytes than the others.
echo "--- benchmark summary: a comparison it presents is a comparison it checked ---"
bash "$DRUSE_ROOT/build/check_bench_controls.sh"

# The gate leaves NO artifact in the working tree.
echo "--- WP69 blocking boundary: process-isolated liveness evidence ---"
bash "$DRUSE_ROOT/build/check_wp69_controls.sh"

echo "--- WP70 thread-safe core: immutable publication and exact-once stop ---"
bash "$DRUSE_ROOT/build/check_wp70_controls.sh"

echo "--- WP71 bounded synchronous Handler concurrency ---"
bash "$DRUSE_ROOT/build/check_wp71_controls.sh"

echo "--- WP72 combined concurrency, shutdown and Phase-5 feature verdict ---"
env DRUSE_WP72_PREREQS_ALREADY_GREEN=1 DRUSE_COMPILER="$DRUSE_COMPILER" \
  bash "$DRUSE_ROOT/build/check_wp72_controls.sh"

# WP90 — ADR-039 on the raw wire: a stalled write is ABORTED (RST) at
# `max_write_time`, an idle keep-alive closes at `max_idle_time`, zero keeps
# the shipped behaviour for both, and the WP46 read deadline still fires.
# Serial (-define:ODIN_TEST_THREADS=1): seven servers on fixed ports.
# Four suites that guarded real fixes and that nothing in this repository ran.
# They were referenced only by the gates of experiment worktrees kept outside
# version control, so `head-content-length` and `ingest-leak` — the regression
# tests for two of the seven subsystem-audit fixes — were guarded by a gate that
# does not exist here. All four passed when finally executed, so this closes a
# coverage hole rather than a regression. planning/diagnosability.md: an
# instrument nobody runs proves nothing.
for druse_orphan in head-content-length ingest-leak wp118-accept-multishot \
                    wp7_5-c1-inbound-stream; do
  echo "--- $druse_orphan (odin test) ---"
  timeout 180 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
    "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/$druse_orphan" \
    "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
    -out:"$DRUSE_BIN_TMP/$druse_orphan" ||
    fail "tests/$druse_orphan did not pass. It was outside the gate until 2026-07-30; if it is failing now, it has been failing unobserved."
done

echo "--- WP90 write/idle deadlines on the raw wire (odin test) ---"
timeout 180 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp90-deadlines" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/wp90-deadlines" ||
  fail "the WP90 write/idle deadline contract did not pass within the timeout"

# WP90b — the detached-stream adapter on the raw wire: chunked commit without
# a body, incremental frames from the owner-lane pump, terminator on close,
# disconnect teardown with observable slot release. Serial: fixed ports and
# the one-server-per-process transport global.
# WP91 — F5/F6 dead: static responses run the ordinary middleware chain
# (secure_headers and auth cover files), with the refusal/routing boundaries
# pinned unchanged. Serial: the suite shares one fixture directory.
echo "--- WP91 static responses through the middleware chain (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp91-commit-security" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/wp91-static" ||
  fail "the WP91 static-through-middleware contract did not pass within the timeout"
rm -rf "$DRUSE_ROOT/tests/wp91-commit-security/fixture"

# WP91 — stream commit security on the raw wire: exactly one envelope even
# for a confused dispatch, CR/LF header values cannot split the commit, and a
# slow consumer under forced short writes receives every byte exactly once.
echo "--- WP91 stream commit/partial-write security (odin test) ---"
timeout 180 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp91-stream-security" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/wp91-stream" ||
  fail "the WP91 stream commit-security contract did not pass within the timeout"

echo "--- WP90b detached-stream adapter on the raw wire (odin test) ---"
timeout 180 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp90-streaming" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/wp90-streaming" ||
  fail "the WP90b detached-stream adapter contract did not pass within the timeout"

# WP92 — backpressure policy: refusal/slow-abort counters, the safe-without-
# tuning stream write deadline, and fast/slow stream isolation on the wire.
echo "--- WP92 response backpressure and slow-consumer policy (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp92-backpressure" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/wp92-backpressure" ||
  fail "the WP92 backpressure contract did not pass within the timeout"

# WP95 — drain: open detached streams terminate within max_drain_time (the one
# process deadline, no second grace clock), and large-body admission refuses
# once draining. Serial: fixed port + the one-server-per-process global.
echo "--- WP95 stream/body drain within the process deadline (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp95-drain" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/wp95-drain" ||
  fail "the WP95 drain contract did not pass within the timeout"

# WP96 — the PUBLIC streaming API (web.stream/stream_send/stream_close) end to
# end through web.serve, and the G7-6 scale claim on the registry (3,000
# streams open/receive/drain without a leak — in memory, faithful and reliable
# where 3,000 real sockets are not on a shared machine).
echo "--- WP96 public streaming API end to end (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp96-public-stream" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/wp96-public-stream" ||
  fail "the WP96 public streaming API did not pass within the timeout"
# STREAM-001 — a stream must not be killed by the PREVIOUS stream's connection
# teardown. `runtime.links` is indexed by registry slot and `retire` frees the
# slot immediately, so back-to-back streams reuse one `Stream_Link`; the finished
# stream's connection still carried a teardown hook pointing at it, and the hook
# closed and retired the NEW stream's token. Truncated response, 200 status,
# clean close, no log line — found while qualifying the R2 campaign host, on two
# independent servers, one of them in this gate.
#
# The suite requests six streams because the defect ALTERNATED: two requests pass
# half the time by landing on the good phase.
echo "--- STREAM-001 back-to-back streams are not truncated (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/stream001-slot-reuse" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/stream001-slot-reuse" ||
  fail "STREAM-001 regression: a detached stream was truncated by the previous stream's teardown"
echo "--- WP96 registry scale: 3,000 streams open/receive/drain (odin test) ---"
env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp96-scale" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/wp96-scale" ||
  fail "the WP96 3,000-stream scale contract failed"

# WP98 — streaming interop: events arrive incrementally through a transparent
# forwarding proxy (the proxied arm) and directly (the control), Last-Event-ID
# crosses the proxy unchanged. A buffering proxy is a config concern documented
# in operations; this proves the framework's bytes are incrementally flushable.
echo "--- WP98 streaming interop and proxy laboratory (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp98-interop" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/wp98-interop" ||
  fail "the WP98 interop/proxy contract did not pass within the timeout"

# WP99 — the large-transfer/progress vertical slice: an application composes the
# two streaming directions over PUBLIC contracts only (web.stream + workers +
# App_State-owned stream state). Proves progress reconnection reads current
# state, the download streams, a graceful close delivers the FINAL event, and a
# slow client does not stall a fast one.
echo "--- WP99 large-transfer/progress vertical slice (odin test) ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp99-slice" \
  "-collection:druse=$DRUSE_ROOT" -define:ODIN_TEST_THREADS=1 \
  -out:"$DRUSE_BIN_TMP/wp99-slice" ||
  fail "the WP99 integration slice did not pass within the timeout"

# ENC1 — Druse's quoted-string writer must produce THE SAME BYTES as
# `core:io`'s. The suite is exhaustive where exhaustion is possible: every rune
# in the Unicode range, every single byte, every two-byte sequence. The oracle
# is the live `core:io` procedure, so a toolchain bump that changes core's
# escaping turns this red instead of drifting the wire silently.
#
# The writer is package-private, so this uses the WP2-WP19 THROWAWAY-package
# arrangement: the real `web/` sources plus the test file, compiled together and
# removed afterwards.
echo "--- ENC1 quoted-string writer: byte-for-byte vs core:io (odin test) ---"
DRUSE_ENC1_TMP="$(mktemp -d -t druse-enc1-XXXXXXXX)"
trap 'rm -rf "$DRUSE_ENC1_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_ENC1_TMP/"
cp "$DRUSE_ROOT"/tests/enc1-quoted-string/*.odin "$DRUSE_ENC1_TMP/"
timeout 300 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ENC1_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/enc1-quoted-string" ||
  fail "the ENC1 quoted-string equivalence suite did not pass within the timeout"
rm -rf "$DRUSE_ENC1_TMP"
trap - EXIT
test ! -d "$DRUSE_ENC1_TMP" || fail "the throwaway ENC1 test package was not removed"
echo "PASS: ENC1 ran against the real sources; throwaway package removed"

# ENC3 — the Druse-owned marshal walk. Two assertions per type: the coverage
# `json_own_supports` claims is PINNED, and where it claims coverage the bytes
# must equal the stdlib's. The pinned boolean is the load-bearing half: the walk
# falls back for what it does not cover, and a fallback is correct by
# construction, so an output-only test would stay green while a widened
# coverage claim rotted.
echo "--- ENC3 own marshal walk: pinned coverage + byte parity (odin test) ---"
DRUSE_ENC3_TMP="$(mktemp -d -t druse-enc3-XXXXXXXX)"
trap 'rm -rf "$DRUSE_ENC3_TMP"' EXIT
cp "$DRUSE_ROOT"/web/*.odin "$DRUSE_ENC3_TMP/"
cp "$DRUSE_ROOT"/tests/enc3-own-marshal/*.odin "$DRUSE_ENC3_TMP/"
timeout 180 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ENC3_TMP" \
  "-collection:druse=$DRUSE_ROOT" -out:"$DRUSE_BIN_TMP/enc3-own-marshal" ||
  fail "the ENC3 own-marshal suite did not pass within the timeout"
rm -rf "$DRUSE_ENC3_TMP"
trap - EXIT
test ! -d "$DRUSE_ENC3_TMP" || fail "the throwaway ENC3 test package was not removed"
echo "PASS: ENC3 ran against the real sources; throwaway package removed"

# The own-marshal path is a build-time rollback in the other direction: it is
# OFF by default, so the state that needs proving is the one that is not
# compiled by every other step. The public contract must be identical in both.
echo "--- WP6 public surface under -define:DRUSE_JSON_OWN_MARSHAL=true ---"
timeout 120 env ODIN_ROOT="$DRUSE_COMPILER_DIR" PATH="$DRUSE_COMPILER_DIR:/usr/bin:/bin" \
  "$DRUSE_COMPILER" test "$DRUSE_ROOT/tests/wp6-public-surface" \
  "-collection:druse=$DRUSE_ROOT" -define:DRUSE_JSON_OWN_MARSHAL=true \
  -out:"$DRUSE_BIN_TMP/wp6-own-marshal" ||
  fail "the WP6 contract does not hold with the Druse-owned marshal walk enabled"
echo "PASS: the public response contract is identical with the own marshal walk on"

# The gate leaves NO artifact in the working tree.
rm -rf "$DRUSE_BIN_TMP"
if find "$DRUSE_ROOT" -maxdepth 1 -type f -name 'druse-*' -print -quit | grep -q .; then
  fail "a test-runner binary was left in the repository root"
fi
echo "PASS: the gate left no test-runner binary in the working tree"
