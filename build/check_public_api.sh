#!/usr/bin/env bash
# Phase-1 public API contract — static repository assertions.
#
# Surface checkpoints: WP1 = 29 symbols; WP2 = 32 (29 + Request + Method +
# Header_View). The count is EXACT in both directions: a
# missing symbol and an extra symbol are equally a failure.
#
# WP3 (planning/public-api-guardrails.md G-11) adds a SECOND, separate ledger.
# The application ledger stays frozen at exactly 32. The test-support facade in
# `web/test_support.odin` — package `web`, exactly `Recorded_Response` and
# `test_request` — is its own 2-symbol ledger. The exported union is exactly 34.
# The machinery lives in `web/testing/` (package `testing`), imports neither
# `druse:web` (cycle) nor `core:testing`, and exposes a locked, minimal set of
# bridge declarations the facade calls across the package boundary.
#
# Verification-only: this script never modifies sources. It enforces the
# anti-accretion guardrails of `planning/public-api-guardrails.md`
# against the shipped public package.
#
# SCOPE (planning/public-api-guardrails.md G-06 and its false-positive rules): the transport-leak and
# dynamic-storage scans read ONLY the exported public package `web/` and, once
# it exists, `examples/`. They deliberately never read `knowledge-base/`,
# `planning/`, `docs/`, or `experiments/`. Backend names are
# expected and legitimate in internal architecture documentation; a textual
# mention there is not leakage.
set -euo pipefail

DRUSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRUSE_WEB="$DRUSE_ROOT/web"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# The web/ file-set contract — DERIVED, not enumerated (WP16, audit A-6).
#
# Phase 1 pinned an exact filename list here, which made every honest refactor
# (splitting errors.odin, adding a ratified Phase-2 file) a gate edit. The
# contract was never really "these thirteen names": it is that every file in
# the shipped package DECLARES WHICH LEDGER IT BELONGS TO, so the two ledgers
# can be scanned without a hand-maintained list and a stray file cannot slide
# in unclassified. Each top-level web/*.odin therefore carries exactly one
# marker line, directly under its package declaration:
#
#     // druse:file application     (application-ledger surface + internals)
#     // druse:file test-support    (the G-11 test-support facade)
#
# and each web/testing/*.odin carries:
#
#     // druse:file test-machinery
#
# A file with no marker, two markers, or a marker foreign to its directory
# fails this gate: legitimacy travels WITH the file, so splitting a file or
# adding a ratified one needs no build/ edit, while web/oops.odin dropped in
# without declaring itself is still rejected. What keeps this honest is that
# the marker never decides what may be EXPORTED — the two-way ledger diffs
# below still pin every public symbol exactly, in both directions.
#
# NO TEST FILE may appear in the shipped package regardless of marker: see
# section 0. Subdirectory structure stays exact: only web/testing/ (WP3) and
# web/internal/transport/ (WP8) exist.
DRUSE_FILE_MARKER_RE='// druse:file (application|test-support)'
DRUSE_MACHINERY_MARKER='// druse:file test-machinery'

# ---------------------------------------------------------------------------
# Expected exported surface — the 32 Phase-1 symbols plus the Phase-2 growth
# ratified so far: WP17 adds `use` and `next` (spec §9.2), taking the
# application ledger to 34. The Knowledge Base and planning/phase-2-spec.md
# define the surface; the permanent contracts below and in tests/ record its
# executable evidence.
#
# WP2 adds exactly three names. `Header_View_Internal`, `Header_Pair`,
# `Response`, `response_commit`, `method_from_token` and `header_view_from_pairs`
# are package-private and must NEVER appear in this list. There is no public
# `Response`, no `method_raw`, and no header lookup in Phase 1.
# ---------------------------------------------------------------------------
DRUSE_EXPECTED_EXPORTS="App
Context
Cors_Options
DEFAULT_LIMITS
Framework_Error
Framework_Event
Handler
Header_View
Limits
Method
Request
Router
Static_Options
Status
Stream
Stream_Send
Uploaded_File
app
app_with_state
bad_request
bare
bearer_token
body
bytes
client_ip
cors
created
delete
destroy
forbidden
form_field
form_file
get
header
internal_error
is_draining
json
limits
logger
mount
next
no_content
not_found
observe
ok
patch
path
path_int
post
put
query
query_int
query_int_opt
query_int_or
refused_connections
request_id
request_state
route
router
secure_headers
serve
set_header
state
static
stats
stop
stream
stream_close
stream_live
stream_send
text
trust_proxies
unauthorized
upload
upload_persist
use
Upload
Upload_Config
enable_upload
Server_Stats"

# ---------------------------------------------------------------------------
# Expected test-support ledger after WP3 — exactly two public symbols, both in
# package `web`, both declared in `web/test_support.odin`
# (planning/public-api-guardrails.md G-11). `Recorded_Response` exposes only
# `status` and `body`;
# no `headers`, `committed`, allocator or transport field is public.
# ---------------------------------------------------------------------------
DRUSE_EXPECTED_TESTSUPPORT_EXPORTS="Recorded_Response
test_request"

# The exact, locked set of declarations package `testing` (web/testing/) exports
# so the facade can call it across the package boundary. These are UNSUPPORTED
# INTERNALS, not a second public API: they are not part of the 34-symbol web
# surface, are undocumented for direct consumption, and this list exists to stop
# the bridge from growing silently. Growth here is a human-review item.
#
# GROWN BY ONE AT WP49, and recorded here rather than absorbed: `last_headers`
# lets the facade return response headers without naming a machinery type. The
# alternative was exporting `Header` into `Recorded_Response`, which would have
# put a machinery type on the PUBLIC surface — a far larger widening than one
# private bridge procedure returning strings.
DRUSE_EXPECTED_BRIDGE_EXPORTS="Header
Request
Test_Transport
build_request
capture
destroy
last_headers"

test -d "$DRUSE_WEB" || fail "web/ does not exist; WP1 has not created the public package"
DRUSE_TESTING="$DRUSE_WEB/testing"

# ---------------------------------------------------------------------------
# Derive the ledger membership of every shipped file from its own marker.
# A file that declares nothing is rejected here, before any content scan runs:
# an unclassified file would otherwise be scanned under a ledger it never
# claimed, and a stray file would be scanned under none.
# ---------------------------------------------------------------------------
DRUSE_TS_FILES=()
DRUSE_APP_FILES=()
while IFS= read -r DRUSE_FILE; do
  DRUSE_MARKS="$(grep -cxE "$DRUSE_FILE_MARKER_RE" "$DRUSE_FILE" || true)"
  if test "$DRUSE_MARKS" -eq 0; then
    fail "web/$(basename "$DRUSE_FILE") declares no ledger. Every shipped top-level file must carry exactly one marker line — '// druse:file application' or '// druse:file test-support' — directly under its package declaration, so the two G-11 ledgers can be derived without a hand-maintained file list. A file that does not declare itself does not ship."
  fi
  if test "$DRUSE_MARKS" -gt 1; then
    fail "web/$(basename "$DRUSE_FILE") carries $DRUSE_MARKS ledger markers; exactly one is required, because a file scanned under both ledgers would let the two counts overlap"
  fi
  if grep -qx '// druse:file test-support' "$DRUSE_FILE"; then
    DRUSE_TS_FILES+=("$DRUSE_FILE")
  else
    DRUSE_APP_FILES+=("$DRUSE_FILE")
  fi
done < <(find "$DRUSE_WEB" -mindepth 1 -maxdepth 1 -name '*.odin' -type f | LC_ALL=C sort)

test "${#DRUSE_TS_FILES[@]}" -gt 0 ||
  fail "no web/*.odin file is marked '// druse:file test-support'; the G-11 test-support facade is missing"
test "${#DRUSE_APP_FILES[@]}" -gt 0 ||
  fail "no web/*.odin file is marked '// druse:file application'; the shipped package has no application surface"

# Every structural scan below reads CODE, not comments: a comment that names a
# forbidden construct in order to prohibit it must not be reported as that
# construct. (No string literal in the public package contains "//".)
druse_code_only() {
  sed -E 's://.*$::' "$DRUSE_WEB"/*.odin
}

# ---------------------------------------------------------------------------
# 0. The shipped package carries NO test code (permanent)
#
# `Response`, `response_commit`, `method_from_token` and `Header_Pair` are
# package-private, and on the pinned toolchain an `@(test)` procedure must be
# compiled as part of the package it tests. Doing that inside `web/` would link
# `core:testing` into EVERY application binary — measured on 819fdc7 at +41,592
# bytes for a minimal consumer (42,624 -> 84,216), against +248 bytes for
# `core:strings`. That is exactly the hidden cost
# `knowledge-base/02-odin-idioms-guidelines.md` forbids.
#
# The internal tests therefore live in `tests/wp2-internal/`, still declaring
# `package web`, and `build/check.sh` compiles them against the real sources in
# a throwaway `mktemp -d` package. Both halves of that arrangement are asserted
# here:
#
#   a. web/ contains no `*_test.odin` file and imports no `core:testing`;
#   b. the out-of-tree internal test package exists and really is `package web`
#      — otherwise the harness would be silently testing nothing.
#
# These are permanent bans, not WP2 conveniences. A future work package that
# needs internal tests adds them to `tests/wp2-internal/` (or its own sibling),
# never to the shipped package.
# ---------------------------------------------------------------------------
if find "$DRUSE_WEB" -mindepth 1 -maxdepth 1 -name '*_test.odin' -print -quit | grep -q .; then
  fail "web/ contains a test file; internal tests belong in tests/wp2-internal/ and are compiled by build/check.sh in a throwaway package (core:testing must never reach an application binary)"
fi

if grep -lE '"core:testing"' "$DRUSE_WEB"/*.odin; then
  fail "web/ imports core:testing; it would be linked into every application binary (+41,592 bytes measured on 819fdc7)"
fi

DRUSE_INTERNAL_TESTS="$DRUSE_ROOT/tests/wp2-internal"
test -d "$DRUSE_INTERNAL_TESTS" ||
  fail "tests/wp2-internal/ is missing; the internal-behavior tests have no home outside the shipped package"
grep -qx 'package web' "$DRUSE_INTERNAL_TESTS"/*.odin ||
  fail "tests/wp2-internal/ does not declare 'package web'; it could not reach the package-private declarations it exists to test"

# ---------------------------------------------------------------------------
# 0b. WP3 test machinery (planning/public-api-guardrails.md G-11)
#
# The facade `web/test_support.odin` and the machinery `web/testing/` carry the
# same permanent bans as the rest of the shipped package, plus the ones the
# one-way dependency rests on:
#
#   - no `*_test.odin` and no `core:testing` in `web/testing/` — the machinery
#     ships in application binaries exactly like `web/`, so it must not drag the
#     test runner in either;
#   - `web/testing/` must NOT import `druse:web`: the back-edge is a compile
#     cycle (ratified as probe C5), and forbidding the import statically catches
#     it before the slower compile probe runs;
#   - no `@(init)` anywhere in the test-support facade or the machinery: the
#     App's test-support state is zero/lazy, created only on the first
#     `test_request`, and an `@(init)` would run in every application binary
#     (planning/public-api-guardrails.md G-11, "no test-support package init side effect").
# ---------------------------------------------------------------------------
test -d "$DRUSE_TESTING" ||
  fail "web/testing/ is missing; WP3 has not created the test machinery"

if find "$DRUSE_TESTING" -mindepth 1 -maxdepth 1 -name '*_test.odin' -print -quit | grep -q .; then
  fail "web/testing/ contains a test file; internal machinery tests belong in tests/wp3-internal/ and are compiled by build/check.sh in a throwaway package"
fi

if grep -lE '"core:testing"' "$DRUSE_TESTING"/*.odin; then
  fail "web/testing/ imports core:testing; the machinery ships in every application binary and must not link the test runner"
fi

if grep -lE '"core:testing"' "${DRUSE_TS_FILES[@]}"; then
  fail "the test-support facade imports core:testing; the facade ships in every application binary"
fi

if grep -nE '"druse:web"' "$DRUSE_TESTING"/*.odin; then
  fail "web/testing/ imports druse:web; the dependency is one-way and the back-edge is a compile cycle (WP3 C5)"
fi

# `@(init)` (with or without a run-order argument) is banned in both the facade
# and the machinery: it would run unconditionally in every binary.
if grep -nE '^@\(init' "${DRUSE_TS_FILES[@]}" "$DRUSE_TESTING"/*.odin; then
  fail "an @(init) proc appears in the test-support facade or machinery; the state must be zero/lazy (planning/public-api-guardrails.md G-11)"
fi

# The machinery may import `core:` freely; it may import nothing else. In
# particular it names no backend and does not reach back into `druse:web`.
DRUSE_TESTING_IMPORTS="$(grep -hE '^import' "$DRUSE_TESTING"/*.odin || true)"
if test -n "$DRUSE_TESTING_IMPORTS"; then
  if grep -vE '"core:' <<<"$DRUSE_TESTING_IMPORTS"; then
    fail "web/testing/ imports a package outside the core collection"
  fi
fi

# The test transport is IN-MEMORY: no socket, port, or network syscall on its
# path. Neither the facade nor the machinery may import a networking package.
# This makes "no sockets" a static property, not just a runtime observation.
if grep -nE '"core:(net|nbio|sys)' \
  "${DRUSE_TS_FILES[@]}" "$DRUSE_TESTING"/*.odin; then
  fail "the test-support facade or machinery imports a networking/syscall package; the test transport must be in-memory (KB §Test transport)"
fi

# The machinery file set is DERIVED like the top-level one: every
# web/testing/*.odin declares itself with '// druse:file test-machinery'.
# The bridge-export lock below is what actually bounds the machinery's
# surface; the marker is what keeps an unclassified stray file out.
while IFS= read -r DRUSE_TF; do
  DRUSE_TF_MARKS="$(grep -cxF "$DRUSE_MACHINERY_MARKER" "$DRUSE_TF" || true)"
  if test "$DRUSE_TF_MARKS" -ne 1; then
    fail "web/testing/$(basename "$DRUSE_TF") carries $DRUSE_TF_MARKS '$DRUSE_MACHINERY_MARKER' markers; exactly one is required — machinery files declare themselves, so a stray file cannot ship unclassified"
  fi
  if grep -qxE "$DRUSE_FILE_MARKER_RE" "$DRUSE_TF"; then
    fail "web/testing/$(basename "$DRUSE_TF") carries a top-level ledger marker; machinery files are '$DRUSE_MACHINERY_MARKER' only"
  fi
done < <(find "$DRUSE_TESTING" -mindepth 1 -maxdepth 1 -name '*.odin' -type f | LC_ALL=C sort)
if find "$DRUSE_TESTING" -mindepth 1 -maxdepth 1 -type f ! -name '*.odin' -print -quit | grep -q .; then
  fail "web/testing/ contains a non-Odin file; the machinery ships as Odin source only"
fi
if test -n "$(find "$DRUSE_TESTING" -mindepth 1 -maxdepth 1 -type d -print -quit)"; then
  fail "web/testing/ has subdirectories; the machinery is flat"
fi
# The declared package name is `web_testing`, NOT `testing`: a package named
# `testing` collides with `core:testing` at link time (link-name prefixing
# requires a unique package name across the binary). The import ALIAS in the
# facade is still `testing`, so callers write `testing.*` and the C5 cyclic
# diagnostic still names 'testing'.
grep -qx 'package web_testing' "$DRUSE_TESTING"/*.odin ||
  fail "web/testing/ does not declare 'package web_testing'"

# The export inventory below reads only files that are NOT `#+private`, which
# is exactly what the compiler exports. This narrows the scan to match the
# language; it never widens what may be exported.
#
# `test_support.odin` is held out of this list: it is the SEPARATE test-support
# ledger (planning/public-api-guardrails.md G-11) and is scanned on its own below, so a symbol added
# to the facade can never be laundered into the frozen application count.
DRUSE_PUBLIC_FILES=()
while IFS= read -r DRUSE_FILE; do
  if head -n 20 "$DRUSE_FILE" | grep -qx '#+private'; then
    continue
  fi
  if grep -qx '// druse:file test-support' "$DRUSE_FILE"; then
    continue
  fi
  DRUSE_PUBLIC_FILES+=("$DRUSE_FILE")
done < <(find "$DRUSE_WEB" -mindepth 1 -maxdepth 1 -name '*.odin' -type f | LC_ALL=C sort)

test "${#DRUSE_PUBLIC_FILES[@]}" -gt 0 || fail "web/ contains no public production file"

druse_public_code_only() {
  sed -E 's://.*$::' "${DRUSE_PUBLIC_FILES[@]}"
}

druse_testsupport_code_only() {
  sed -E 's://.*$::' "${DRUSE_TS_FILES[@]}"
}

# ---------------------------------------------------------------------------
# 1. File set — every file classified (derived above), no non-Odin strays.
#
# The ledger-marker scan at the top of this script already rejected any
# top-level *.odin file that does not declare its ledger. What remains here is
# that nothing else ships at the top level: a stray non-Odin file in the
# package directory is either build debris or scope creep.
# ---------------------------------------------------------------------------
if find "$DRUSE_WEB" -mindepth 1 -maxdepth 1 -type f ! -name '*.odin' -print -quit | grep -q .; then
  find "$DRUSE_WEB" -mindepth 1 -maxdepth 1 -type f ! -name '*.odin' -printf '    %f\n' >&2
  fail "web/ contains a non-Odin top-level file; the shipped package is Odin source only"
fi
echo "public API contract: every web/*.odin file declares its ledger (${#DRUSE_APP_FILES[@]} application + ${#DRUSE_TS_FILES[@]} test-support)"

# WP3 added `web/testing/`; WP8 adds `web/internal/` (the private transport
# boundary and adapter). No other subdirectory is permitted. Both are internal:
# neither adds a symbol to the application ledger, which the inventory below
# still pins at exactly 32.
DRUSE_WEB_SUBDIRS="$(find "$DRUSE_WEB" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort)"
DRUSE_WEB_SUBDIRS_EXPECTED="$(printf 'internal\ntesting\n')"
if test "$DRUSE_WEB_SUBDIRS" != "$DRUSE_WEB_SUBDIRS_EXPECTED"; then
  echo "--- web/ subdirectories (only 'internal' and 'testing' are allowed) ---" >&2
  echo "$DRUSE_WEB_SUBDIRS" >&2
  fail "web/ has an unexpected subdirectory; Phase 1 permits only web/testing/ and web/internal/"
fi

# WP8 — the transport boundary and adapter live under web/internal/transport/.
# It is a SEPARATE package that must never import `druse:web` (the one-way
# boundary, ADR-009 / WP8 D1); the adapter is the only place the backend may be
# imported. These are static guards; the compile probes back them.
DRUSE_WEB_INTERNAL="$DRUSE_WEB/internal"
if test -d "$DRUSE_WEB_INTERNAL"; then
  DRUSE_INTERNAL_SUBDIRS="$(find "$DRUSE_WEB_INTERNAL" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | LC_ALL=C sort)"
  # Amended by WP87 (2026-07-23): Phase 7 adds exactly two private lifecycle
  # packages — `stream` (WP88/WP89) and `ingest` (WP94) — fixed as sentinels
  # by the WP87 corpus. They are one-way like transport: never importers of
  # `druse:web`, and `web` may not import them until their implementing WP
  # lands (enforced by check_wp87_controls.sh). Anything else remains refused.
  DRUSE_INTERNAL_EXPECTED="$(printf 'ingest\nstream\ntransport\n')"
  if test "$DRUSE_INTERNAL_SUBDIRS" != "$DRUSE_INTERNAL_EXPECTED"; then
    echo "--- web/internal subdirectories (only 'ingest', 'stream', 'transport' are allowed) ---" >&2
    echo "$DRUSE_INTERNAL_SUBDIRS" >&2
    fail "web/internal/ has an unexpected subdirectory; WP8 (amended by WP87) permits only transport/, stream/ and ingest/"
  fi
  for DRUSE_P7_PKG in stream ingest; do
    if grep -nE '"druse:web"' "$DRUSE_WEB_INTERNAL/$DRUSE_P7_PKG"/*.odin; then
      fail "web/internal/$DRUSE_P7_PKG imports druse:web; the internal boundary is one-way (ADR-009 Amendment 1)"
    fi
  done
  DRUSE_TRANSPORT="$DRUSE_WEB_INTERNAL/transport"
  if grep -nE '"druse:web"' "$DRUSE_TRANSPORT"/*.odin; then
    fail "web/internal/transport imports druse:web; the transport boundary is one-way (ADR-009 / WP8 D1)"
  fi

  # Exactly ONE file may name the vendored backend, and it must live inside
  # web/internal/transport/ — that file IS the adapter, whatever it is named.
  # The backend lives in the `druse:` collection, so the general dependency
  # rule below cannot catch this — an import anywhere else would put a
  # replaceable third-party type on the wrong side of the boundary
  # (G-06 / WP8 D1). The adapter's NAME is not contract: renaming it is the
  # first step of swapping the backend, and must not need a gate edit.
  DRUSE_BACKEND_USERS="$(grep -rlE '"druse:vendor/odin-http"' "$DRUSE_WEB" | LC_ALL=C sort -u)"
  DRUSE_BACKEND_USER_COUNT="$(grep -c . <<<"$DRUSE_BACKEND_USERS" || true)"
  if test "$DRUSE_BACKEND_USER_COUNT" -ne 1; then
    echo "--- files importing the vendored backend (exactly one is permitted) ---" >&2
    echo "${DRUSE_BACKEND_USERS:-<none>}" >&2
    fail "the vendored backend must be imported by exactly one file — the adapter — and it is imported by $DRUSE_BACKEND_USER_COUNT (ADR-009 / WP8 D1)"
  fi
  case "$DRUSE_BACKEND_USERS" in
    "$DRUSE_TRANSPORT"/*.odin) : ;;
    *)
      fail "the vendored backend is imported outside web/internal/transport/ (by ${DRUSE_BACKEND_USERS#"$DRUSE_ROOT/"}); only the adapter behind the boundary may name it (ADR-009 / WP8 D1)"
      ;;
  esac
  DRUSE_ADAPTER="$DRUSE_BACKEND_USERS"
fi

# ---------------------------------------------------------------------------
# 2. Exported-symbol inventory (planning/public-api-guardrails.md G-01, G-09)
#
# A top-level declaration is exported unless the immediately preceding
# attribute line marks it private. Struct/enum members are indented and are
# therefore never mistaken for declarations.
# ---------------------------------------------------------------------------
druse_exported_names() {
  awk '
    /^[[:space:]]*$/ { next }
    /^\/\// { next }
    /^@\(/ { pending_attr = 1; if ($0 ~ /^@\(private/) { pending_private = 1 } next }
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*::/ {
      name = $1
      if (pending_private) { pending_private = 0; pending_attr = 0; next }
      pending_attr = 0
      print name
      next
    }
    { pending_attr = 0; pending_private = 0 }
  ' <<<"$DRUSE_WEB_PUBLIC_CODE" | LC_ALL=C sort -u
}

DRUSE_WEB_CODE="$(druse_code_only)"
DRUSE_WEB_PUBLIC_CODE="$(druse_public_code_only)"
DRUSE_ACTUAL_EXPORTS="$(druse_exported_names)"
DRUSE_EXPECTED_EXPORTS_SORTED="$(LC_ALL=C sort -u <<<"$DRUSE_EXPECTED_EXPORTS")"

# `comm` must collate the way the inputs were sorted. Without LC_ALL=C it
# applies the ambient locale to lists sorted in C order and aborts with
# "input is not in sorted order" — which fails safe under `set -e`, but hides
# WHICH symbol was added or lost. The diagnostic is the point of this section.
DRUSE_EXTRA="$(LC_ALL=C comm -13 <(echo "$DRUSE_EXPECTED_EXPORTS_SORTED") <(echo "$DRUSE_ACTUAL_EXPORTS"))"
DRUSE_MISSING="$(LC_ALL=C comm -23 <(echo "$DRUSE_EXPECTED_EXPORTS_SORTED") <(echo "$DRUSE_ACTUAL_EXPORTS"))"

if test -n "$DRUSE_EXTRA"; then
  echo "--- unexpected exported symbols ---" >&2
  echo "$DRUSE_EXTRA" >&2
  fail "web/ exports symbols outside the ratified Phase-1 surface (planning/public-api-guardrails.md G-01/G-09)"
fi
if test -n "$DRUSE_MISSING"; then
  echo "--- missing exported symbols ---" >&2
  echo "$DRUSE_MISSING" >&2
  fail "web/ is missing part of the ratified Phase-1 surface"
fi

echo "public API contract: application ledger is exactly 80 symbols (32 Phase-1 + Phase-2 twelve + the Phase-3 six + WP44 stop + WP48 client_ip/trust_proxies + WP49 secure_headers + WP50 refused_connections + WP60 cors/Cors_Options + WP61 static/Static_Options + WP63 form_field/form_file/Uploaded_File + WP-6.5.3 is_draining + WP96 stream/Stream/stream_send/Stream_Send/stream_close + WP7.5-C2 enable_upload/upload/upload_persist/Upload/Upload_Config + Closure-H3 stats/Server_Stats + C2 set_header/bytes + C3 query_int_opt + C4 stream_live + C7 request_state)"

# ---------------------------------------------------------------------------
# 2b. Test-support ledger (planning/public-api-guardrails.md G-11)
#
# `web/test_support.odin` exports EXACTLY `Recorded_Response` and
# `test_request`, and nothing else. Held apart from the application count so the
# two ledgers cannot grow against each other under one number.
# ---------------------------------------------------------------------------
DRUSE_TESTSUPPORT_PUBLIC_CODE="$(druse_testsupport_code_only)"
DRUSE_TESTSUPPORT_ACTUAL_EXPORTS="$(DRUSE_WEB_PUBLIC_CODE="$DRUSE_TESTSUPPORT_PUBLIC_CODE" druse_exported_names)"
DRUSE_TESTSUPPORT_EXPECTED_SORTED="$(LC_ALL=C sort -u <<<"$DRUSE_EXPECTED_TESTSUPPORT_EXPORTS")"

DRUSE_TS_EXTRA="$(LC_ALL=C comm -13 <(echo "$DRUSE_TESTSUPPORT_EXPECTED_SORTED") <(echo "$DRUSE_TESTSUPPORT_ACTUAL_EXPORTS"))"
DRUSE_TS_MISSING="$(LC_ALL=C comm -23 <(echo "$DRUSE_TESTSUPPORT_EXPECTED_SORTED") <(echo "$DRUSE_TESTSUPPORT_ACTUAL_EXPORTS"))"
if test -n "$DRUSE_TS_EXTRA"; then
  echo "--- unexpected test-support exports ---" >&2
  echo "$DRUSE_TS_EXTRA" >&2
  fail "the test-support facade exports outside the 2-symbol test-support ledger (planning/public-api-guardrails.md G-11)"
fi
if test -n "$DRUSE_TS_MISSING"; then
  echo "--- missing test-support exports ---" >&2
  echo "$DRUSE_TS_MISSING" >&2
  fail "the test-support facade is missing part of the test-support ledger"
fi

# `Recorded_Response` exposes exactly `status`, `body` and `headers`, in that
# order, and NO other field — no `committed`, no allocator, no transport.
#
# AMENDED BY WP49, and the amendment is the decision D-14.3 deferred. This check
# previously forbade `headers` BY NAME, which was right for as long as the only
# response header worth asserting was one the framework set for itself: an
# internal `package web` test could see it, and the type stayed at two fields.
#
# `secure_headers` ends that. Its entire purpose is letting an APPLICATION
# assert its own security posture, and an application that cannot observe the
# headers it asked for has to test through a socket — which is exactly what
# `test_request` exists to avoid. **A test-support API that cannot see what the
# framework sets pushes people back to the thing it replaced.**
#
# The field is `[]string` in wire form rather than a pair type or a map: a pair
# type would export `Header_Pair`, and a map would export a lookup contract and
# an allocation. Strings are the vocabulary the bridge already shares.
#
# The list stays EXACT in both directions. This is a widening by one field with
# a recorded reason, not a relaxation.
# EXTRACTED WITH `sed -n ... p`, not with a bare substitution, and WP49 is why.
# A substitution REPLACES matching lines and passes everything else through
# unchanged — so a struct with doc comments in it yielded the comment text as
# though it were field names. That went unnoticed because this struct had no
# comments until a field arrived that needed explaining.
DRUSE_RECORDED_FIELDS="$(awk '/^Recorded_Response :: struct \{/{f=1;next} /^\}/{f=0} f' \
  <<<"$DRUSE_TESTSUPPORT_PUBLIC_CODE" | sed -nE 's/^[[:space:]]*([a-z_]+):[[:space:]]*[^=].*/\1/p')"
DRUSE_RECORDED_EXPECTED="$(printf 'status\nbody\nheaders\n')"
if test "$DRUSE_RECORDED_FIELDS" != "$DRUSE_RECORDED_EXPECTED"; then
  echo "--- expected Recorded_Response fields ---" >&2
  echo "$DRUSE_RECORDED_EXPECTED" >&2
  echo "--- actual Recorded_Response fields ---" >&2
  echo "$DRUSE_RECORDED_FIELDS" >&2
  fail "Recorded_Response must expose exactly status, body and headers (WP49 / D-14.3). The list is exact in both directions: a new field is a decision, not an edit."
fi

# 2c. The exported union is EXACTLY 34 (32 application + 2 test-support), and the
# two ledgers are disjoint.
DRUSE_APP_COUNT="$(grep -c . <<<"$DRUSE_ACTUAL_EXPORTS")"
DRUSE_TS_COUNT="$(grep -c . <<<"$DRUSE_TESTSUPPORT_ACTUAL_EXPORTS")"
DRUSE_UNION="$(printf '%s\n%s\n' "$DRUSE_ACTUAL_EXPORTS" "$DRUSE_TESTSUPPORT_ACTUAL_EXPORTS" | LC_ALL=C sort -u | grep -c .)"
if test "$DRUSE_APP_COUNT" -ne 80; then
  fail "application ledger is $DRUSE_APP_COUNT, not 80 (… + C4 stream_live + C7 stats/Server_Stats + C2 set_header/bytes + C3 query_int_opt + C4 stream_live + C7 request_state)"
fi
if test "$DRUSE_TS_COUNT" -ne 2; then
  fail "test-support ledger is $DRUSE_TS_COUNT, not 2"
fi
if test "$DRUSE_UNION" -ne 82; then
  fail "exported union is $DRUSE_UNION, not 82 (the two ledgers must be disjoint)"
fi
echo "public API contract: test-support ledger is exactly 2; exported union is exactly 82"

# ---------------------------------------------------------------------------
# 2d. Bridge exports — the LOCKED, minimal set package `testing` exports so the
# facade can call it across the package boundary.
#
# These are unsupported internals, not a public API. The list is exact in both
# directions so the bridge cannot grow silently: a new machinery export is a
# human-review item, exactly like a new public symbol.
# ---------------------------------------------------------------------------
druse_testing_public_code() {
  DRUSE_TESTING_FILES=()
  while IFS= read -r DRUSE_TF; do
    if head -n 20 "$DRUSE_TF" | grep -qx '#+private'; then
      continue
    fi
    DRUSE_TESTING_FILES+=("$DRUSE_TF")
  done < <(find "$DRUSE_TESTING" -mindepth 1 -maxdepth 1 -name '*.odin' -type f | LC_ALL=C sort)
  sed -E 's://.*$::' "${DRUSE_TESTING_FILES[@]}"
}
DRUSE_BRIDGE_ACTUAL="$(DRUSE_WEB_PUBLIC_CODE="$(druse_testing_public_code)" druse_exported_names)"
DRUSE_BRIDGE_EXPECTED_SORTED="$(LC_ALL=C sort -u <<<"$DRUSE_EXPECTED_BRIDGE_EXPORTS")"
DRUSE_BRIDGE_EXTRA="$(LC_ALL=C comm -13 <(echo "$DRUSE_BRIDGE_EXPECTED_SORTED") <(echo "$DRUSE_BRIDGE_ACTUAL"))"
DRUSE_BRIDGE_MISSING="$(LC_ALL=C comm -23 <(echo "$DRUSE_BRIDGE_EXPECTED_SORTED") <(echo "$DRUSE_BRIDGE_ACTUAL"))"
if test -n "$DRUSE_BRIDGE_EXTRA"; then
  echo "--- unexpected web/testing bridge exports ---" >&2
  echo "$DRUSE_BRIDGE_EXTRA" >&2
  fail "web/testing/ exports a declaration outside the locked bridge set; minimize it or record the growth for human review"
fi
if test -n "$DRUSE_BRIDGE_MISSING"; then
  echo "--- missing web/testing bridge exports ---" >&2
  echo "$DRUSE_BRIDGE_MISSING" >&2
  fail "web/testing/ no longer exports part of the locked bridge set the facade depends on"
fi
echo "public API contract: web/testing bridge exports match the locked minimal set"

# ---------------------------------------------------------------------------
# 3. Later-phase surface must not exist yet
#
# `test_request` was removed from this list by WP3 (ratified test-support
# symbol); `use`/`next` by WP17 and `router`/`mount` by WP18 (ratified
# application symbols, spec §9.2 — pinned by the inventory above). `group`
# `cors` LEFT THIS LIST on 2026-07-21. It was reserved here for a later phase,
# and Phase 5 is that phase: ADR-034 moved CORS into the core, so the name is
# now ratified rather than pending. A reserved name that ships is the list doing
# its job — it kept the name from being taken by accident before a work package
# had argued for it. `group` stays FOREVER: ADR-024 rejects it in every phase.
# `Response` stays
# forbidden; `Recorded_Response` is a different exact name and is allowed.
# The application ledger scanned here excludes test_support.odin, so the two
# ratified test-support names never reach this loop.
# ---------------------------------------------------------------------------
# `bytes` and `set_header` were promoted to the public surface by corrective WP C2
# (frictions F8-2/F8-4), so they are no longer later-phase names. `conflict` stays
# banned: C1 named `.Conflict` as a Status member, not a `web.conflict` proc.
for DRUSE_FUTURE in group \
  serve_with serve_transport app_init \
  redirect conflict recovery body_limit \
  Response Header Header_Pair Header_View_Internal Params Route_Info \
  Transport method_raw headers commit; do
  if grep -qx "$DRUSE_FUTURE" <<<"$DRUSE_ACTUAL_EXPORTS"; then
    fail "later-phase symbol '$DRUSE_FUTURE' is exported by the Phase-1 package"
  fi
done

# ---------------------------------------------------------------------------
# 4. Context is not an extension bag (planning/public-api-guardrails.md G-03)
#
# `any`, a dynamic bag, and the handler-error result types are forbidden
# ANYWHERE in web/. `rawptr` is forbidden only in EXPORTED declarations: WP8
# introduces ONE private `rawptr` — the neutral transport-callback user pointer
# in `serve_dispatch` — which is the boundary between the core and the untyped
# backend callback, exactly the narrowing this check anticipated (and the shape
# Phase 3 will reuse for app_with_state's typeid-validated rawptr, ADR-004). It
# never appears in a public signature.
# ---------------------------------------------------------------------------
if grep -nE '^[[:space:]]*(user_data|locals|values)[[:space:]]*:' <<<"$DRUSE_WEB_CODE"; then
  fail "web/ declares an untyped request-local storage field (planning/public-api-guardrails.md G-03)"
fi
for DRUSE_BAG in 'map\[string\]any' 'map\[any\]any' '\bany\b' \
  'Handler_Error' 'Handler_Outcome'; do
  if grep -nE "$DRUSE_BAG" <<<"$DRUSE_WEB_CODE"; then
    fail "web/ uses a forbidden construct matching /$DRUSE_BAG/ (planning/public-api-guardrails.md G-03, ADR-011)"
  fi
done
# `rawptr` is banned only in EXPORTED declarations (G-03 narrowing); that check
# runs in section 6 below, once the exported-block extraction is available.

# The machinery is production code too: no `any`, no `rawptr`, no state bag, no
# duplicated public web type. It moves data as neutral records only.
DRUSE_TESTING_CODE="$(sed -E 's://.*$::' "$DRUSE_TESTING"/*.odin)"
for DRUSE_BAG in 'map\[string\]any' 'map\[any\]any' '\bany\b' '\brawptr\b'; do
  if grep -nE "$DRUSE_BAG" <<<"$DRUSE_TESTING_CODE"; then
    fail "web/testing/ uses a forbidden construct matching /$DRUSE_BAG/ (WP3 prompt: no any/rawptr/state bag in machinery)"
  fi
done

# ---------------------------------------------------------------------------
# 5. Canonical handler shape (ADR-011)
# ---------------------------------------------------------------------------
grep -qx 'Handler :: proc(ctx: ^Context)' "$DRUSE_WEB/context.odin" ||
  fail "the canonical handler is not exactly 'Handler :: proc(ctx: ^Context)'"

# ---------------------------------------------------------------------------
# 6. Transport / backend leakage (planning/public-api-guardrails.md G-06)
#
# 6a. Hard backend identifiers have no legitimate use anywhere in web/.
# 6b. Backend-shaped type names must not appear in EXPORTED declarations. An
#     exported declaration block is the declaration line plus, for aggregate
#     types, its body up to the closing brace in column 1.
# ---------------------------------------------------------------------------
# Scoped to the exported package files and application examples. It does NOT
# recurse into web/internal/, where a future adapter (WP8) is exactly where
# backend names belong.
DRUSE_LEAK_TEXT="$DRUSE_WEB_CODE"
if test -d "$DRUSE_ROOT/examples"; then
  DRUSE_LEAK_TEXT+="
$(find "$DRUSE_ROOT/examples" -name '*.odin' -exec sed -E 's://.*$::' {} +)"
fi

for DRUSE_BACKEND in 'odin[-_]http' 'nbio' 'laytan'; do
  if grep -niE "$DRUSE_BACKEND" <<<"$DRUSE_LEAK_TEXT"; then
    fail "backend identifier matching /$DRUSE_BACKEND/ reached the public package or examples (planning/public-api-guardrails.md G-06)"
  fi
done

# WHAT COUNTS AS AN EXPORTED DECLARATION, and WP37 sharpened this in both
# directions.
#
# For a TYPE, the declaration is the whole block: an exported struct's fields
# are surface, so `Context :: struct { x: rawptr }` must be caught.
#
# For a PROCEDURE, the declaration is the SIGNATURE and stops at the opening
# brace. The body is implementation. That is what G-03 has always said in
# words — "it never appears in a public signature" — and until WP37 nothing
# tested the difference, because no exported body had needed an untyped
# pointer. `app_with_state` does: it converts `^$T` to the private `rawptr`
# field the App stores, which is precisely the typeid-validated narrowing the
# ban's own comment above anticipates by name.
#
# The parenthesis count is not decoration either. The previous version treated
# any declaration line that did not end in `{` as complete, so a MULTI-LINE
# exported signature — `test_request :: proc(` and its four parameter lines —
# was never scanned at all. A `rawptr` parameter there would have passed. That
# hole is closed here: the signature is followed to its closing paren whether it
# spans one line or five.
druse_exported_blocks() {
  awk '
    function paren_delta(line,   i, c, d, n) {
      d = 0; n = length(line)
      for (i = 1; i <= n; i++) { c = substr(line, i, 1)
        if (c == "(") d++
        else if (c == ")") d-- }
      return d
    }
    /^[[:space:]]*$/ { next }
    /^\/\// { next }
    /^@\(/ { if ($0 ~ /^@\(private/) { pending_private = 1 } next }
    /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*::/ {
      if (pending_private) { pending_private = 0; skipping = ($0 ~ /\{[[:space:]]*$/); next }
      print
      if ($0 ~ /::[[:space:]]*proc/) {
        depth = paren_delta($0)
        if (depth > 0) { in_signature = 1; emitting = 0 }
        else { in_signature = 0; emitting = 0; skipping = ($0 ~ /\{[[:space:]]*$/) }
      } else {
        emitting = ($0 ~ /\{[[:space:]]*$/)
      }
      next
    }
    in_signature {
      print
      depth += paren_delta($0)
      if (depth <= 0) { in_signature = 0; skipping = ($0 ~ /\{[[:space:]]*$/) }
      next
    }
    /^\}/ { emitting = 0; skipping = 0; next }
    emitting { print }
    { pending_private = 0 }
  ' <<<"$DRUSE_WEB_PUBLIC_CODE"
}

DRUSE_EXPORTED_BLOCKS="$(druse_exported_blocks)"

# G-03 (narrowed): `rawptr` is forbidden in EXPORTED declarations, never in the
# whole package — WP8's one private `rawptr` is the neutral transport-callback
# user pointer in `serve_dispatch`, which appears in no public signature.
if grep -nE '\brawptr\b' <<<"$DRUSE_EXPORTED_BLOCKS"; then
  fail "web/ exposes rawptr in an exported declaration (planning/public-api-guardrails.md G-03)"
fi

# Word-bounded: `Internal_Server_Error` is an HTTP status name, not a
# transport type, and must not be reported as leakage.
for DRUSE_TYPE in '\bTransport\b' '\bSocket\b' '\bTCP\b' '\bConnection\b' \
  '\bServer\b' '\bnet\.' '\bhttp\.'; do
  if grep -nE "$DRUSE_TYPE" <<<"$DRUSE_EXPORTED_BLOCKS"; then
    fail "transport-shaped name matching /$DRUSE_TYPE/ appears in an exported declaration (planning/public-api-guardrails.md G-06)"
  fi
done

# ---------------------------------------------------------------------------
# 7. Dependency policy — the public package may only import `core:` or
#    `druse:` packages. This is what keeps the odin-http -> core:net/http
#    migration a non-event for applications.
# ---------------------------------------------------------------------------
DRUSE_IMPORTS="$(grep -hE '^import' "$DRUSE_WEB"/*.odin || true)"
if test -n "$DRUSE_IMPORTS"; then
  if grep -vE '"(core|druse):' <<<"$DRUSE_IMPORTS"; then
    fail "web/ imports a package outside the core/druse collections"
  fi
fi

# ---------------------------------------------------------------------------
# 8. WP2 request/response model (planning/phase-1-plan.md §WP2;
#    planning/public-api-guardrails.md G-03/G-04/G-05; ADR-007/ADR-008)
#
# The three symbols WP2 adds are already pinned by the inventory above. What
# follows pins the SHAPE the inventory cannot see: which fields are public,
# which spelling the enum uses, and which internals stayed internal.
# ---------------------------------------------------------------------------

# 8a. Method is the exact ratified set, spelled in UPPERCASE. `.GET`, never
#     `.Get`. HEAD and OPTIONS are absent by decision: with this set they
#     convert to `.UNKNOWN`, which is the ratified Phase-1 behavior.
DRUSE_METHOD_BODY="$(awk '/^Method :: enum u8 \{/{f=1;next} /^\}/{f=0} f' \
  <<<"$DRUSE_WEB_PUBLIC_CODE" | tr -d '\t ,' | grep -v '^$' | LC_ALL=C sort)"
DRUSE_METHOD_EXPECTED="$(printf 'DELETE\nGET\nPATCH\nPOST\nPUT\nUNKNOWN\n')"
if test "$DRUSE_METHOD_BODY" != "$DRUSE_METHOD_EXPECTED"; then
  echo "--- expected Method members ---" >&2
  echo "$DRUSE_METHOD_EXPECTED" >&2
  echo "--- actual Method members ---" >&2
  echo "$DRUSE_METHOD_BODY" >&2
  fail "Method is not the ratified Phase-1 set"
fi

# 8b. Request exposes exactly the five ratified fields, in the spec's order.
DRUSE_REQUEST_FIELDS="$(awk '/^Request :: struct \{/{f=1;next} /^\}/{f=0} f' \
  <<<"$DRUSE_WEB_PUBLIC_CODE" | sed -E 's/^[[:space:]]*([a-z_]+):.*/\1/' | grep -v '^$')"
DRUSE_REQUEST_EXPECTED="$(printf 'method\npath\nquery\nheaders\nbody\n')"
if test "$DRUSE_REQUEST_FIELDS" != "$DRUSE_REQUEST_EXPECTED"; then
  echo "--- expected Request fields ---" >&2
  echo "$DRUSE_REQUEST_EXPECTED" >&2
  echo "--- actual Request fields ---" >&2
  echo "$DRUSE_REQUEST_FIELDS" >&2
  fail "Request does not expose exactly the ratified fields (spec §Request/Response ownership)"
fi

# 8c. Header_View announces no representation. Exposing `pairs` as a public
#     field would freeze the pair layout into the API and export Header_Pair
#     with it; the nested private slot is the whole point of the wrapper.
DRUSE_HEADER_VIEW_FIELDS="$(awk '/^Header_View :: struct \{/{f=1;next} /^\}/{f=0} f' \
  <<<"$DRUSE_WEB_PUBLIC_CODE" | sed -E 's/^[[:space:]]*([a-z_]+):.*/\1/' | grep -v '^$')"
if test "$DRUSE_HEADER_VIEW_FIELDS" != "private"; then
  echo "--- actual Header_View fields ---" >&2
  echo "$DRUSE_HEADER_VIEW_FIELDS" >&2
  fail "Header_View must expose only the nested private slot"
fi

# 8d. Context carries `request` and NEVER a `response` field. Applications
#     respond through the helpers; the commit state is internal (ADR-008).
DRUSE_CONTEXT_FIELDS="$(awk '/^Context :: struct \{/{f=1;next} /^\}/{f=0} f' \
  <<<"$DRUSE_WEB_PUBLIC_CODE" | sed -E 's/^[[:space:]]*([a-z_]+):.*/\1/' | grep -v '^$')"
DRUSE_CONTEXT_EXPECTED="$(printf 'request\nprivate\n')"
if test "$DRUSE_CONTEXT_FIELDS" != "$DRUSE_CONTEXT_EXPECTED"; then
  echo "--- expected Context fields ---" >&2
  echo "$DRUSE_CONTEXT_EXPECTED" >&2
  echo "--- actual Context fields ---" >&2
  echo "$DRUSE_CONTEXT_FIELDS" >&2
  fail "Context must expose exactly 'request' and the private slot: no public response, params or route (ADR-008)"
fi

# 8e-pre. The internal Response carries the minimum state WP4 depends on.
#
# WP4's TESTS-FIRST contract requires "405-when-other-method with exact Allow
# header", and WP4 depends on WP2/WP3 — it lands BEFORE WP6. Without internal
# header storage, WP4 could not express or test its own ratified contract, so
# `headers` is WP2 state, not deferred work. `Response` does not own that
# storage yet: headers and body are views until WP6 defines the concrete
# allocation and lifetime of a rendered response.
DRUSE_RESPONSE_FIELDS="$(awk '/^Response :: struct \{/{f=1;next} /^\}/{f=0} f' \
  <<<"$DRUSE_WEB_PUBLIC_CODE" | sed -E 's/^[[:space:]]*([a-z_]+):.*/\1/' | grep -vE '^[[:space:]]*$')"
# AMENDED IN WP6 (ADR-014): `owned_body` and `body_allocator` record whether the
# committed body is an allocation this Response must release. Both are
# package-private, so the application ledger is unaffected.
DRUSE_RESPONSE_EXPECTED="$(printf 'status\nheaders\nbody\ncommitted\nowned_body\nbody_allocator\n')"
if test "$DRUSE_RESPONSE_FIELDS" != "$DRUSE_RESPONSE_EXPECTED"; then
  echo "--- expected internal Response fields ---" >&2
  echo "$DRUSE_RESPONSE_EXPECTED" >&2
  echo "--- actual internal Response fields ---" >&2
  echo "$DRUSE_RESPONSE_FIELDS" >&2
  fail "the internal Response must carry status, headers, body and committed (planning/phase-1-plan.md §WP2; WP4 needs the Allow header)"
fi

# The commit primitive records all three together, so a rejected attempt
# cannot replace one of them while the guard blocks the others. The parameter
# NAMES are private and not contract (WP16): what is pinned is the shape —
# one ^Response, one Status, one []Header_Pair, one []u8, returning bool.
grep -qE '^response_commit :: proc\([a-z_]+: \^Response, [a-z_]+: Status, [a-z_]+: \[\]Header_Pair, [a-z_]+: \[\]u8\) -> bool \{$' \
  <<<"$DRUSE_WEB_PUBLIC_CODE" ||
  fail "response_commit does not take a Status, a []Header_Pair and a []u8 together and return bool; the commit must be atomic across all three (its private parameter names are free to change — the shape is not)"

# 8e. The internal model stayed internal. Each of these must be declared, and
#     each must be preceded by @(private) — the inventory in section 2 already
#     proves they are not exported, and this proves they still exist and were
#     not quietly promoted.
for DRUSE_INTERNAL in Response Header_Pair Header_View_Internal \
  response_commit method_from_token header_view_from_pairs; do
  grep -qE "^${DRUSE_INTERNAL} ::" <<<"$DRUSE_WEB_PUBLIC_CODE" ||
    fail "internal WP2 declaration '$DRUSE_INTERNAL' is missing from web/"
  grep -qx "$DRUSE_INTERNAL" <<<"$DRUSE_ACTUAL_EXPORTS" &&
    fail "internal WP2 declaration '$DRUSE_INTERNAL' became exported"
done

# 8f. WP2 decides no HTTP status automatically. 404/405/501 are WP4/WP9, and a
#     status literal in the request/response model would mean WP2 started
#     making response policy decisions.
DRUSE_WP2_CODE="$(sed -E 's://.*$::' \
  "$DRUSE_WEB/request.odin" "$DRUSE_WEB/response.odin" "$DRUSE_WEB/headers.odin")"
if grep -nE '\b(404|405|501|Not_Found|Method_Not_Allowed)\b' <<<"$DRUSE_WP2_CODE"; then
  fail "the WP2 model decides an HTTP status; 404/405/501 decisions belong to WP4/WP9"
fi

# 8g. WP19 delivered the header lookups; their exact ratified signatures are
#     pinned here, redundantly with the freeze snapshot on purpose (a named
#     assertion encodes the DECISION and survives snapshot laundering). Both
#     return (value, ok); 10a's package-wide #optional_ok ban covers them.
grep -qxF 'header :: proc(ctx: ^Context, name: string) -> (value: string, ok: bool) {' \
  <<<"$DRUSE_WEB_PUBLIC_CODE" ||
  fail "the ratified web.header signature changed (WP19; freeze Amendment 5)"
grep -qxF 'bearer_token :: proc(ctx: ^Context) -> (value: string, ok: bool) {' \
  <<<"$DRUSE_WEB_PUBLIC_CODE" ||
  fail "the ratified web.bearer_token signature changed (WP19; freeze Amendment 5)"

# ---------------------------------------------------------------------------
# 8h. WP20 — the typed framework-error observer (ADR-026, spec §6.2).
#
# THE REDACTION CONSTRAINT IS A GATE ASSERTION, not a convention. The event is
# the one thing an observer ever receives, so its FIELD TYPES are what bound
# what an observer can learn. Two assertions, both exact:
#
#   * the field set is exactly the ratified five, in order — so a new field
#     cannot appear without this line changing;
#   * NO field whose type mentions `string` may be named anything but `route`.
#     `route` is a registered pattern (low-cardinality, App-owned); a
#     `path: string`, a `message: string` or a `headers: []string` would each
#     put request-derived, attacker-influenced bytes into an observer, and
#     each fails here. The spec calls this HARD; this is where it is enforced.
DRUSE_EVENT_BODY="$(awk '/^Framework_Event :: struct \{/{f=1;next} /^\}/{f=0} f' \
  <<<"$DRUSE_WEB_PUBLIC_CODE" | grep -vE '^[[:space:]]*$')"
DRUSE_EVENT_FIELDS="$(sed -E 's/^[[:space:]]*([a-z_]+):.*/\1/' <<<"$DRUSE_EVENT_BODY")"
DRUSE_EVENT_EXPECTED="$(printf 'kind\nmethod\nroute\nstatus\npayload_type\n')"
if test "$DRUSE_EVENT_FIELDS" != "$DRUSE_EVENT_EXPECTED"; then
  echo "--- expected Framework_Event fields ---" >&2
  echo "$DRUSE_EVENT_EXPECTED" >&2
  echo "--- actual ---" >&2
  echo "$DRUSE_EVENT_FIELDS" >&2
  fail "Framework_Event must carry exactly kind, method, route, status, payload_type (ADR-026 / spec §6.1)"
fi

DRUSE_EVENT_STRING_FIELDS="$(grep -E 'string' <<<"$DRUSE_EVENT_BODY" |
  sed -E 's/^[[:space:]]*([a-z_]+):.*/\1/' | grep -vE '^[[:space:]]*$' || true)"
if test "$DRUSE_EVENT_STRING_FIELDS" != "route"; then
  echo "--- string-typed Framework_Event fields (only 'route' is permitted) ---" >&2
  echo "${DRUSE_EVENT_STRING_FIELDS:-<none>}" >&2
  fail "a Framework_Event field other than 'route' carries string data. The event MUST NOT expose request-derived bytes: route identity is the registered pattern and is low-cardinality, while a path/message/header field would hand attacker-controlled text to an observer (spec §6.2, HARD)."
fi

# The observer registration keeps its ratified shape: the observer takes the
# event BY VALUE and takes nothing else. A `^Context` parameter here would let
# an observer respond, which the accepted design forbids by type.
grep -qxF 'observe :: proc(a: ^App, observer: proc(event: Framework_Event)) {' \
  <<<"$DRUSE_WEB_PUBLIC_CODE" ||
  fail "the ratified web.observe signature changed; an observer must receive the event by value and nothing else (ADR-026)"

# EVERY framework-detected failure is observed exactly once (spec §6.3). The
# invariant that keeps that true as the package grows: one emission per report
# site. A future work package that adds a `framework_report` and forgets the
# emission fails here rather than shipping a silently unobservable failure.
DRUSE_REPORT_CALLS="$(grep -oE 'framework_report\(' <<<"$DRUSE_WEB_CODE" | grep -c . || true)"
DRUSE_OBSERVE_CALLS="$(grep -oE 'framework_observe_(request|app)\(' <<<"$DRUSE_WEB_CODE" | grep -c . || true)"
if test "$DRUSE_REPORT_CALLS" -ne "$DRUSE_OBSERVE_CALLS"; then
  fail "web/ has $DRUSE_REPORT_CALLS framework_report call(s) but $DRUSE_OBSERVE_CALLS observer emission(s). Every framework-detected failure is observed exactly once (spec §6.3): a reported failure with no emission is invisible to every observer."
fi
test "$DRUSE_REPORT_CALLS" -gt 0 ||
  fail "no framework_report call sites were found; the report/observe pairing check would be vacuous"
echo "public API contract: Framework_Event admits no request-derived string; $DRUSE_REPORT_CALLS reports, $DRUSE_OBSERVE_CALLS emissions"

# ---------------------------------------------------------------------------
# 8c. WP36 — EVERY CONSTRUCTOR SETS THE BUDGET.
#
# `Limits`'s zero value is three zeros, which does not mean "unset": it means
# "answer 413 to every request with a body". The field therefore cannot be lazy
# like the rest of `App_Internal`, and every constructor must initialise it.
#
# There are four today — `app`, `bare`, `app_with_state` and `router` — and the
# fifth is the one this check exists for: a constructor added by a later work
# package that forgets, and ships an application which rejects all traffic while
# every behavioural test that uses `app()` stays green.
#
# DEFENCE IN DEPTH, and it should be read as that. `web.body` resolves a zero
# budget to the default, so a forgetful constructor produces an application that
# runs on the DEFAULTS rather than one that rejects all traffic — the safe
# outcome, and the right one for a framework-internal slip. This check exists so
# the slip is still caught at the gate instead of being silently absorbed.
#
# The check is a count rather than a list of names, so it needs no maintenance
# when a constructor is added: every literal `App_Internal` value built anywhere
# in the package must carry `limits = DEFAULT_LIMITS`.
# ---------------------------------------------------------------------------
DRUSE_APP_INTERNAL_LITERALS="$(grep -cE 'App_Internal[[:space:]]*\{' <<<"$DRUSE_WEB_CODE" || true)"
DRUSE_LIMITS_INITS="$(grep -cE 'limits[[:space:]]*=[[:space:]]*DEFAULT_LIMITS' <<<"$DRUSE_WEB_CODE" || true)"
test "$DRUSE_APP_INTERNAL_LITERALS" -gt 0 ||
  fail "no App_Internal literal was found; the WP36 constructor check would be vacuous"
if test "$DRUSE_APP_INTERNAL_LITERALS" -ne "$DRUSE_LIMITS_INITS"; then
  fail "web/ builds $DRUSE_APP_INTERNAL_LITERALS App_Internal value(s) but sets limits = DEFAULT_LIMITS in $DRUSE_LIMITS_INITS of them. A constructor that leaves Limits at its zero value ships an application that answers 413 to every request with a body, and every test written against app() would stay green (WP36)."
fi
echo "public API contract: all $DRUSE_APP_INTERNAL_LITERALS App constructors initialise Limits to DEFAULT_LIMITS"

# ---------------------------------------------------------------------------
# 8d. WP43/WP123 — THE TRANSPORT'S PROCESS-WIDE STATE, BY NAME AND BY FILE.
#
# `web.serve` once wrote its `Config` into a package variable that the backend
# handler read on every request. With one server per process that is fine; with
# two it is a SILENT CROSS-WIRE — the second `serve` overwrites the first's
# dispatch pointer and requests to one application run the other's. Nothing
# diagnoses it, because from each server's own point of view nothing is wrong.
# That is the worst shape a defect can have.
#
# WP43 moved the config into per-server state reached through the backend
# handler's own `user_data`, and carved out ONE exception by name: `g_server`,
# a single slot holding the running server. WP123 removed that slot — the
# process-wide record is now a table of live servers keyed by a stale-safe
# handle — so the exception is gone and the shape of this check changes with it.
#
# TWO FILES, TWO DIFFERENT RULES, and the split is the point:
#
#   * the ADAPTER may declare NO package variable that is per-request state.
#     The two it does declare are `STREAM_CRLF` and `STREAM_TERMINATOR`, byte
#     literals Odin cannot express as `::` constants — they are written once at
#     init and never again, and they are named here rather than pattern-matched
#     so a third cannot arrive quietly beside them.
#
#   * the REGISTRY file may declare exactly `g_servers`, and that file exists so
#     the process-wide record lives somewhere whose whole subject is being
#     process-wide, instead of hiding among per-request machinery.
#
# THE PATTERN NOW MATCHES CAPITALS. It used to anchor on `^[a-z_]`, so
# `STREAM_CRLF` and `STREAM_TERMINATOR` were invisible to it: the check reported
# "no package-level variables" about a file with two, and the message promised
# more than the check delivered. Screaming case is the convention for a constant,
# not a guarantee of one — a mutable global spelled in capitals would have walked
# straight through.
# ---------------------------------------------------------------------------
DRUSE_ADAPTER="$DRUSE_WEB/internal/transport/odin_http_adapter.odin"
DRUSE_REGISTRY="$DRUSE_WEB/internal/transport/server_registry.odin"
test -f "$DRUSE_ADAPTER" || fail "the transport adapter is missing"
test -f "$DRUSE_REGISTRY" || fail "the transport server registry is missing; WP123 put the one process-wide record in its own file, and this check depends on that separation"

# Package-level variable declarations: `name: Type` at column 0, no `::`.
druse_package_globals() { # file
  sed -E 's://.*$::' "$1" |
    grep -nE '^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*[^:=]' |
    sed -E 's/^[0-9]+:([A-Za-z_][A-Za-z0-9_]*):.*/\1/' | LC_ALL=C sort -u || true
}

DRUSE_ADAPTER_GLOBALS="$(druse_package_globals "$DRUSE_ADAPTER")"
DRUSE_ADAPTER_UNEXPECTED="$(grep -vxE 'STREAM_CRLF|STREAM_TERMINATOR' <<<"$DRUSE_ADAPTER_GLOBALS" | grep -c . || true)"
if test "$DRUSE_ADAPTER_UNEXPECTED" -ne 0; then
  echo "--- unexpected package-level variables in the adapter ---" >&2
  grep -vxE 'STREAM_CRLF|STREAM_TERMINATOR' <<<"$DRUSE_ADAPTER_GLOBALS" >&2
  fail "the transport adapter declares a package-level variable other than the two ratified byte literals (STREAM_CRLF, STREAM_TERMINATOR). Per-server state in a package global cross-wires two servers silently (WP43/WP123): the second serve overwrites the first's, and nothing diagnoses it. The process-wide server table belongs in server_registry.odin."
fi

DRUSE_REGISTRY_GLOBALS="$(druse_package_globals "$DRUSE_REGISTRY")"
DRUSE_REGISTRY_UNEXPECTED="$(grep -vxF 'g_servers' <<<"$DRUSE_REGISTRY_GLOBALS" | grep -c . || true)"
if test "$DRUSE_REGISTRY_UNEXPECTED" -ne 0; then
  echo "--- unexpected package-level variables in the server registry ---" >&2
  grep -vxF 'g_servers' <<<"$DRUSE_REGISTRY_GLOBALS" >&2
  fail "the transport server registry declares a package-level variable other than the one ratified exception 'g_servers'. One process-wide record is the whole budget: naming it means a SECOND cannot arrive quietly."
fi
grep -qF 'g_servers' <<<"$DRUSE_REGISTRY_GLOBALS" ||
  fail "server_registry.odin no longer declares 'g_servers'. If the server table moved, this check is now guarding an empty file while the real global sits somewhere unexamined."

echo "public API contract: the adapter holds no package global but its two byte literals; the one process-wide record is g_servers, in the registry file"

# ---------------------------------------------------------------------------
# 9. WP4 route registration and dispatch (planning/phase-1-plan.md §WP4 D1-D5)
#
# WP4 adds BEHAVIOR, not surface. The inventory above already proves the ledger
# stayed at 32; what follows pins the properties the inventory cannot see.
# ---------------------------------------------------------------------------
DRUSE_DISPATCH_TABLE="$DRUSE_WEB/dispatch_table.odin"
DRUSE_DISPATCH_MATCH="$DRUSE_WEB/dispatch_match.odin"
test -f "$DRUSE_DISPATCH_TABLE" ||
  fail "web/dispatch_table.odin is missing; WP4 has not created the route table"
test -f "$DRUSE_DISPATCH_MATCH" ||
  fail "web/dispatch_match.odin is missing; WP4 has not created the matcher"

# ---------------------------------------------------------------------------
# 8b. WP34 route identity — THE PATTERN, NEVER THE PATH.
#
# IT RUNS HERE, after the two presence checks above, and the ordering is load-
# bearing: the assignment it inspects lives in the matcher, so a MISSING matcher
# would otherwise trip this check's vacuity guard first and report a redaction
# failure for a file that is simply absent. A gate that diagnoses the wrong
# thing is worse than one that diagnoses late (WP16 control: 'missing WP4
# dispatch file' must be rejected for its own reason).
#
# `web.route` hands an application the same low-cardinality string
# `Framework_Event.route` carries, and it is the same constraint (C-2, the
# OpenTelemetry `http.route` rule) wearing a different name: a metric or a log
# label keyed on `/users/42` has one time series per user id, and it puts a user
# identifier into a dashboard nobody meant to put it in.
#
# The check above keeps the EVENT free of request-derived strings. This one
# keeps the ACCESSOR honest, because the two could otherwise drift apart while
# both look correct — one procedure returning the pattern and another quietly
# returning the path is exactly the drift a single-name guardrail (G-01) exists
# to prevent.
#
# Three assertions, in the order they can fail:
#
#   * the accessor's shape is exactly the ratified one;
#   * it reads the private route slot and NOTHING else — a body that reached
#     `ctx.request.path` would compile, pass every behavioural test that only
#     checks static routes, and leak on the first parametric one;
#   * every WRITE to that slot is the matched entry's PATTERN. The redaction
#     lives at the assignment; an accessor cannot be more honest than the value
#     it returns.
# ---------------------------------------------------------------------------
grep -qxF 'route :: proc(ctx: ^Context) -> string {' <<<"$DRUSE_WEB_PUBLIC_CODE" ||
  fail "the ratified web.route signature changed; it takes the Context and returns one string (WP34)"

DRUSE_ROUTE_BODY="$(awk '/^route :: proc\(ctx: \^Context\) -> string \{/{f=1;next} /^\}/{f=0} f' \
  <<<"$DRUSE_WEB_PUBLIC_CODE" | grep -vE '^[[:space:]]*$')"
if test "$DRUSE_ROUTE_BODY" != "	return ctx.private.route"; then
  echo "--- actual web.route body ---" >&2
  echo "${DRUSE_ROUTE_BODY:-<empty>}" >&2
  fail "web.route must return ctx.private.route and nothing else. It returns the REGISTERED PATTERN, never the request path: a path-valued route identity is unbounded cardinality and carries request bytes into whatever an application labels with it (C-2, the same rule Framework_Event is held to)."
fi

DRUSE_ROUTE_WRITES="$(grep -nE 'ctx\.private\.route[[:space:]]*=' <<<"$DRUSE_WEB_CODE" || true)"
test -n "$DRUSE_ROUTE_WRITES" ||
  fail "nothing assigns ctx.private.route; the redaction check below would be vacuous"
if grep -vE 'ctx\.private\.route[[:space:]]*=[[:space:]]*entry\.pattern[[:space:]]*$' \
  <<<"$DRUSE_ROUTE_WRITES"; then
  fail "ctx.private.route is assigned something other than the matched entry's pattern. Route identity is the REGISTERED PATTERN — '/users/:id', never '/users/42' — and this is the assignment that decides it (WP34, C-2)."
fi
echo "public API contract: web.route returns the registered pattern; every write to the slot is entry.pattern"

DRUSE_WP4_CODE="$(sed -E 's://.*$::' "$DRUSE_DISPATCH_TABLE" "$DRUSE_DISPATCH_MATCH")"

# 9a. EVERY declaration the two WP4 files add is package-private. The route
#     table, the entry type, the matcher and `dispatch` are all internal: Phase
#     3 replaces them wholesale, and an exported one would freeze the interim
#     dispatcher into the public API.
DRUSE_WP4_EXPORTS="$(DRUSE_WEB_PUBLIC_CODE="$DRUSE_WP4_CODE" druse_exported_names)"
if test -n "$DRUSE_WP4_EXPORTS"; then
  echo "--- exported symbols in the WP4 dispatch files ---" >&2
  echo "$DRUSE_WP4_EXPORTS" >&2
  fail "the WP4 dispatch files export a symbol; every dispatch declaration must be package-private (planning/phase-1-plan.md §WP4 D1/D2)"
fi

# 9b. `dispatch` takes the App EXPLICITLY (D3). The WP3 stub `dispatch(ctx)` had
#     no access to the App-owned table; no pointer to App is stored on Context.
#     Its private parameter names are free to change (WP16); the shape —
#     (^App, ^Context), in that order — is the D3 contract.
grep -qE '^dispatch :: proc\([a-z_]+: \^App, [a-z_]+: \^Context\) \{$' <<<"$DRUSE_WP4_CODE" ||
  fail "dispatch does not take (^App, ^Context) explicitly, in that order; the dispatcher reaches the route table through the App argument, never through a stored back-pointer (planning/phase-1-plan.md §WP4 D3)"

# 9c. The App holds no back-pointer inside the Context. A stored `^App` would
#     make the request context outlive-sensitive and is not how dispatch reaches
#     the table (D3).
if grep -nE '^[[:space:]]*[a-z_]+:[[:space:]]*\^App' <<<"$(awk '/^Context_Internal :: struct \{/{f=1;next} /^\}/{f=0} f' <<<"$DRUSE_WEB_CODE")"; then
  fail "Context_Internal stores a pointer to App; dispatch receives the App explicitly instead (planning/phase-1-plan.md §WP4 D3)"
fi

# 9d. The `Allow` header name and its canonical method order are exact and
#     deterministic (D4). The order is a property of the framework, never of the
#     application's registration sequence.
grep -qE '^ALLOW_HEADER_NAME :: "Allow"$' <<<"$DRUSE_WP4_CODE" ||
  fail "the 405 header name is not exactly \"Allow\" (planning/phase-1-plan.md §WP4 D4)"
grep -qE '^ALLOW_METHOD_ORDER :: \[5\]Method\{\.GET, \.POST, \.PUT, \.PATCH, \.DELETE\}$' \
  <<<"$DRUSE_WP4_CODE" ||
  fail "the Allow method order is not the canonical GET, POST, PUT, PATCH, DELETE (planning/phase-1-plan.md §WP4 D4)"

# 9e. WP4 is the INTERIM dispatcher. Radix/trie/wildcard vocabulary belongs
#     to Phase 3; finding it here means Phase 3 started early (R-12).
#     `middleware`/`chain_cursor` stay banned in these two files for a NEW
#     reason since WP17 delivered the machinery: the chain mechanics live in
#     web/middleware.odin, and the dispatch files only delegate through
#     `chain_enter`/`mw_*` — so Phase 3 can replace the table without
#     touching the chains, and the WP4 files stay a matcher.
for DRUSE_EARLY in 'radix' '\btrie\b' 'wildcard' 'Route_Node' 'Resolved_Route' \
  'middleware' 'chain_cursor'; do
  if grep -niE "$DRUSE_EARLY" <<<"$DRUSE_WP4_CODE"; then
    fail "later-phase routing construct matching /$DRUSE_EARLY/ appears in the WP4 dispatcher (Phase 2/3 scope, R-12)"
  fi
done

# 9f. WP4 decides 404 and 405 — and NOTHING else. A 501 for an unknown method,
#     or any other automatic status, is a response policy WP4 has no mandate to
#     freeze (D4).
if grep -nE '\b(501|Not_Implemented|Internal_Server_Error|Bad_Request|Unauthorized|Forbidden)\b' \
  <<<"$DRUSE_WP4_CODE"; then
  fail "the WP4 dispatcher decides a status outside 404/405; .UNKNOWN never becomes a 501 (planning/phase-1-plan.md §WP4 D4)"
fi

# 9g. The WP4 internal tests live OUTSIDE the shipped package, like WP2/WP3.
DRUSE_WP4_TESTS="$DRUSE_ROOT/tests/wp4-internal"
test -d "$DRUSE_WP4_TESTS" ||
  fail "tests/wp4-internal/ is missing; the WP4 internal-behavior tests have no home outside the shipped package"
grep -qx 'package web' "$DRUSE_WP4_TESTS"/*.odin ||
  fail "tests/wp4-internal/ does not declare 'package web'; it could not reach the package-private dispatcher it exists to test"

# ---------------------------------------------------------------------------
# 10. WP5 canonical extractors (planning/phase-1-plan.md §WP5; ADR-002; ADR-008)
#
# WP5 adds BEHAVIOR, not surface. The inventory above already proves the ledger
# stayed at 32 + 2 = 34; what follows pins the properties the inventory cannot
# see: the exact signatures, the absence of `#optional_ok`, and the fact that
# neither WP6 nor WP7 started early.
# ---------------------------------------------------------------------------
# The extractor checks below match the WHOLE public package rather than one
# filename (WP16): the contract is what the code says, not which file says it.

# 10a. `#optional_ok` appears NOWHERE in the shipped package (ADR-002 option B,
#      R-07).
#
#      The directive is not part of a procedure's type, so no signature
#      assertion below can see it and no public contract test can observe it.
#      This static ban plus the three compile probes in `build/check.sh` are the
#      only enforcement there is: with the directive, `id := web.path_int(...)`
#      compiles and silently drops an error the extractor already responded to.
#
#      It is checked BEFORE the signature assertions on purpose. Adding the
#      directive also breaks the exact-signature match below, so testing
#      signatures first would report "the signature changed" for what is really
#      a re-introduced `#optional_ok` — a true failure with a misleading cause.
#      The mutation cases in `build/check_wp3_mutations.sh` pin this ordering.
if grep -nE '#optional_ok' <<<"$DRUSE_WEB_CODE"; then
  fail "#optional_ok appears in web/; the HTTP extractors must force the caller to handle ok (ADR-002, R-07)"
fi

# 10b. The five extractor signatures are EXACT. These are the ratified Phase-1
#      shapes (spec §Canonical Extractor Control Flow and §Canonical query
#      extractor family); WP5 implements them and changes none of them.
#
#      A signature change is a public API change even when the symbol count is
#      unmoved, which is precisely what the 32-symbol ledger cannot detect.
#
#      These match the WHOLE public package, not one filename (WP16): the
#      signature is the contract — including its public parameter and result
#      names, which the freeze snapshot pins too — but WHERE it is declared is
#      an internal layout choice, free to change in a refactor.
druse_expect_signature() { # exact-declaration-line label
  local decl="$1" label="$2"
  grep -qxF "$decl {" <<<"$DRUSE_WEB_PUBLIC_CODE" ||
    fail "the ratified $label signature is not exactly '$decl' (planning/phase-1-plan.md §WP5)"
}

druse_expect_signature \
  'path :: proc(ctx: ^Context, name: string) -> string' 'web.path'
druse_expect_signature \
  'path_int :: proc(ctx: ^Context, name: string) -> (value: int, ok: bool)' 'web.path_int'
druse_expect_signature \
  'query :: proc(ctx: ^Context, name: string) -> (value: string, found: bool)' 'web.query'
druse_expect_signature \
  'query_int :: proc(ctx: ^Context, name: string) -> (value: int, ok: bool)' 'web.query_int'
druse_expect_signature \
  'query_int_or :: proc(ctx: ^Context, name: string, default_value: int) -> (value: int, ok: bool)' \
  'web.query_int_or'
druse_expect_signature \
  'body :: proc(ctx: ^Context, dst: ^$T) -> bool' 'web.body'

# 10c. WP6 shipped the responders WP5 deliberately left inert.
#
#      The "these must be empty stubs" assertions this section carried during
#      WP5 are GONE: keeping them would assert the absence of a delivered
#      feature. What replaces them pins the WP6 contract instead.
#
#      The real WP6 D5 contract is that the DISPATCHER stays encoder-free —
#      its automatic 404/405 bodies are compile-time constants. The old form
#      additionally pinned the encoder-importing files by NAME
#      (errors/extract/respond), which made splitting errors.odin a gate edit
#      while proving nothing extra: in Odin an import anywhere in the package
#      links the encoder regardless, so which non-dispatch file writes the
#      `import` line is layout, not contract (WP16). What is asserted is the
#      contract itself, on the dispatch files by name — they ARE contract
#      (planning/phase-1-plan.md §WP4 D2) — first the import, then any
#      marshal call (the check below).
if grep -lE '"core:encoding/json"' "$DRUSE_DISPATCH_TABLE" "$DRUSE_DISPATCH_MATCH"; then
  fail "a WP4 dispatch file imports the JSON encoder; the dispatcher stays encoder-free so the automatic 404/405 path never marshals (WP6 D5)"
fi

# The interim dispatcher must not marshal. Its 404/405 bodies are compile-time
# constants, which is what keeps it allocation-free and keeps the encoder out of
# every application that calls `web.app()` (WP6 D5).
if grep -nE 'encoding_json|marshal' <<<"$DRUSE_WP4_CODE"; then
  fail "the WP4 dispatcher marshals a response; the automatic 404/405 bodies must stay static constants (WP6 D5)"
fi

# 10c-i. The response ownership machinery stayed INTERNAL. Each must exist and
#        each must be package-private: the ledger in section 2 proves they are
#        not exported, and this proves they were not quietly removed either.
for DRUSE_WP6_INTERNAL in Response response_commit response_commit_owned \
  response_destroy Error_Envelope Framework_Report framework_report; do
  grep -qE "^${DRUSE_WP6_INTERNAL} ::" <<<"$DRUSE_WEB_PUBLIC_CODE" ||
    fail "internal WP6 declaration '$DRUSE_WP6_INTERNAL' is missing from web/"
  grep -qx "$DRUSE_WP6_INTERNAL" <<<"$DRUSE_ACTUAL_EXPORTS" &&
    fail "internal WP6 declaration '$DRUSE_WP6_INTERNAL' became exported; response ownership is not public API (ADR-014)"
done

# 10c-ii. No public cleanup symbol. An application must never be asked to free a
#         response: the driver does it (ADR-014 D1).
for DRUSE_CLEANUP in response_destroy response_free response_release \
  free_response destroy_response; do
  if grep -qx "$DRUSE_CLEANUP" <<<"$DRUSE_ACTUAL_EXPORTS"; then
    fail "'$DRUSE_CLEANUP' is exported; response teardown is framework business and must stay private"
  fi
done

# 10c-iii. The exact ratified Content-Type values (WP6 D3).
grep -qE '^CONTENT_TYPE_JSON :: "application/json"$' <<<"$DRUSE_WEB_PUBLIC_CODE" ||
  fail "the JSON Content-Type is not exactly \"application/json\" (WP6 D3)"
grep -qE '^CONTENT_TYPE_TEXT :: "text/plain; charset=utf-8"$' <<<"$DRUSE_WEB_PUBLIC_CODE" ||
  fail "the text Content-Type is not exactly \"text/plain; charset=utf-8\" (WP6 D3)"

# 10c-iv. `field` is OMITTED for a general error, never emitted empty or null
#         (AMEND-2). The envelope struct WP6 marshals must therefore have NO
#         `field` member at all — the omission is a property of the type, not of
#         a runtime emptiness check.
DRUSE_ENVELOPE_FIELDS="$(awk '/^Error_Envelope_Body :: struct \{/{f=1;next} /^\}/{f=0} f' \
  <<<"$DRUSE_WEB_PUBLIC_CODE" | sed -E 's/^[[:space:]]*([a-z_]+):.*/\1/' | grep -vE '^[[:space:]]*$')"
DRUSE_ENVELOPE_EXPECTED="$(printf 'code\nmessage\n')"
if test "$DRUSE_ENVELOPE_FIELDS" != "$DRUSE_ENVELOPE_EXPECTED"; then
  echo "--- expected Error_Envelope_Body members ---" >&2
  echo "$DRUSE_ENVELOPE_EXPECTED" >&2
  echo "--- actual ---" >&2
  echo "$DRUSE_ENVELOPE_FIELDS" >&2
  fail "the general error envelope must carry exactly code and message; 'field' is omitted by TYPE, not by omitempty (AMEND-2)"
fi
if grep -nE 'omitempty' <<<"$DRUSE_WEB_CODE"; then
  fail "omitempty is used in web/; it decides on EMPTINESS and would also drop a field legitimately named \"\" (AMEND-2)"
fi

# 10c-v. Pointer payload support was NOT adopted. ADR-003's value-only baseline
#        stands until a human ratifies an amendment; the WP6 prototype is
#        recorded in the PR, not shipped.
if grep -nE 'Type_Info_Pointer|dereference|deref' <<<"$DRUSE_WEB_CODE"; then
  fail "web/ appears to implement pointer-payload dereference; ADR-003 is value-only until a spec amendment is ratified (R-13)"
fi

# 10d. WP7 body binding — the positive contract that REPLACES the WP5/WP6 bans.
#
# WP7 shipped body binding, the request-lifetime arena and the 4 MiB cap, so the
# temporary "these must not exist" grep bans are gone. What replaces them pins
# the shape WP7 must actually have.
DRUSE_ARENA_FILE="$DRUSE_WEB/request_arena.odin"
test -f "$DRUSE_ARENA_FILE" ||
  fail "web/request_arena.odin is missing; WP7 has not created the request arena machinery"
DRUSE_ARENA_CODE="$(sed -E 's://.*$::' "$DRUSE_ARENA_FILE")"

# 10d-i. The arena file exports NOTHING. Every declaration is package-private:
#        BODY_LIMIT, Body_State and the request_arena_* procedures are internal,
#        so the application ledger is unchanged (WP7 D1).
DRUSE_ARENA_EXPORTS="$(DRUSE_WEB_PUBLIC_CODE="$DRUSE_ARENA_CODE" druse_exported_names)"
if test -n "$DRUSE_ARENA_EXPORTS"; then
  echo "--- exported symbols in web/request_arena.odin ---" >&2
  echo "$DRUSE_ARENA_EXPORTS" >&2
  fail "web/request_arena.odin exports a symbol; the arena machinery must be package-private (WP7 D1)"
fi

# 10d-ii. The DEFAULT cap is EXACTLY 4 MiB, spelled as the arithmetic the
#         reviewer saw, and the comparison rejects only a STRICTLY larger body
#         (WP7 D3).
#
# AMENDED BY WP36, which made the cap configurable. What the check pinned was
# two different things wearing one expression: the DEFAULT value, and the
# boundary rule. Both survive, separately.
#
#   * `BODY_LIMIT` is still exactly `4 * 1024 * 1024` — it is now the source of
#     `DEFAULT_LIMITS.max_body`, so an application that never calls
#     `web.limits` is held to the number Phase 1 fixed, and a silent change to
#     the default fails here;
#   * `DEFAULT_LIMITS.max_body` must BE `BODY_LIMIT`, so the constant and the
#     ledger row cannot drift apart;
#   * `web.body` compares against the PER-REQUEST resolved budget with `>`,
#     never `>=`: exactly the limit is accepted, at whatever number the
#     application chose.
grep -qE '^BODY_LIMIT :: 4 \* 1024 \* 1024$' <<<"$DRUSE_ARENA_CODE" ||
  fail "BODY_LIMIT is not exactly '4 * 1024 * 1024' (WP7 D3); it is the value DEFAULT_LIMITS.max_body carries"
grep -qE 'max_body[[:space:]]*=[[:space:]]*BODY_LIMIT' <<<"$DRUSE_WEB_PUBLIC_CODE" ||
  fail "DEFAULT_LIMITS.max_body is not BODY_LIMIT; the shipped default and the capacity ledger's row would drift apart (WP36)"

# The other two defaults are pinned the same way and for the same reason. The
# freeze snapshot records `DEFAULT_LIMITS` by the NAMES of its constants, so
# without these three lines the numbers behind those names could change with the
# snapshot unmoved — and a changed default is a behaviour change for every
# application that never mentioned limits.
grep -qxE 'REQUEST_LINE_LIMIT :: 8000' <<<"$DRUSE_WEB_CODE" ||
  fail "REQUEST_LINE_LIMIT is not exactly 8000, the vendored backend's own default (WP36)"
grep -qxE 'HEADER_BLOCK_LIMIT :: 8000' <<<"$DRUSE_WEB_CODE" ||
  fail "HEADER_BLOCK_LIMIT is not exactly 8000, the vendored backend's own default (WP36)"
if grep -nE 'len\([a-z_]+\) >= (BODY_LIMIT|cap|ctx\.private\.limits\.max_body)' <<<"$DRUSE_WEB_PUBLIC_CODE"; then
  fail "the body cap uses '>=', so a body of exactly the limit would be rejected; it must be '>' (WP7 D3)"
fi
grep -qE 'cap[[:space:]]*:=[[:space:]]*ctx\.private\.limits\.max_body' <<<"$DRUSE_WEB_PUBLIC_CODE" ||
  fail "web.body does not read the request's resolved max_body. A hard-coded constant here would make web.limits a knob that lies (WP7 D3, as amended by WP36)."
grep -qE 'len\([a-z_]+\) > cap' <<<"$DRUSE_WEB_PUBLIC_CODE" ||
  fail "web.body does not compare the body length against the resolved cap with '>' (WP7 D3)"

# 10d-iii. The cap is checked BEFORE the parser. `unmarshal` must appear AFTER
#          the budget guard in the source of `body`, so an over-limit body is
#          never handed to the decoder (WP7 D3). WP36 changed what the guard
#          compares against, not where it sits — and this is the check that
#          keeps that true, because a configurable limit checked after the parse
#          would be a limit that bounds nothing.
DRUSE_BODY_SRC="$(awk '/^body :: proc/{f=1} f{print} f && /^}/{exit}' <<<"$DRUSE_WEB_PUBLIC_CODE")"
DRUSE_LIMIT_LINE="$(grep -nE 'len\([a-z_]+\) > cap' <<<"$DRUSE_BODY_SRC" | head -1 | cut -d: -f1)"
DRUSE_PARSE_LINE="$(grep -nE 'unmarshal\(' <<<"$DRUSE_BODY_SRC" | head -1 | cut -d: -f1)"
test -n "$DRUSE_LIMIT_LINE" -a -n "$DRUSE_PARSE_LINE" ||
  fail "web.body must contain both the max_body guard and the unmarshal call (WP7 D3)"
test "$DRUSE_LIMIT_LINE" -lt "$DRUSE_PARSE_LINE" ||
  fail "web.body parses before checking the body cap; the cap must gate the parser (WP7 D3)"

# 10d-iv. Decoding is STRICT JSON. The pinned encoder's default spec is JSON5,
#         which would accept unquoted keys, comments and single-quoted strings,
#         so the unmarshal call must pass `.JSON` explicitly (WP7 D5).
grep -qE 'unmarshal\([a-z_]+, dst, \.JSON,' <<<"$DRUSE_WEB_PUBLIC_CODE" ||
  fail "web.body does not unmarshal in strict .JSON mode; JSON5 would be accepted (WP7 D5)"

# 10d-v. Body data is decoded into the ARENA, never context.allocator directly.
#        Both the stdlib fallback and the fused tree decoder must receive the
#        request arena, or nested data would outlive nothing and leak (ADR-006).
grep -qE 'request_arena_allocator\(ctx\)' <<<"$DRUSE_WEB_PUBLIC_CODE" ||
  fail "web.body does not decode into the request arena allocator (ADR-006 / WP7 D4)"
if grep -nE 'unmarshal\([^)]*context\.allocator' <<<"$DRUSE_WEB_PUBLIC_CODE"; then
  fail "web.body unmarshals with context.allocator; decoded data must live in the request arena (ADR-006)"
fi
if grep -nE 'json_tree_decode\([^)]*context\.allocator' <<<"$DRUSE_WEB_PUBLIC_CODE"; then
  fail "web.body fused decoder uses context.allocator; decoded data must live in the request arena (ADR-006)"
fi
grep -qE 'json_tree_decode\([^)]*request_arena_allocator\(ctx\)' <<<"$DRUSE_WEB_PUBLIC_CODE" ||
  fail "web.body fused decoder does not use the request arena allocator (ADR-006)"

# 10d-vi. The single-consumer state machine exists and consumes BEFORE parsing.
#         `.Consumed` must be assigned before the unmarshal call (ADR-012 A).
DRUSE_CONSUME_LINE="$(grep -nE 'body_state = \.Consumed' <<<"$DRUSE_BODY_SRC" | head -1 | cut -d: -f1)"
test -n "$DRUSE_CONSUME_LINE" ||
  fail "web.body never marks the body capability consumed; ADR-012 requires single use"
test "$DRUSE_CONSUME_LINE" -lt "$DRUSE_PARSE_LINE" ||
  fail "web.body consumes the capability after parsing; it must consume before (ADR-012 A)"

# 10d-vii. The driver frees the arena. `request_arena_destroy` must be called
#          from the test-support facade (the response driver), or a bound body
#          leaks (WP7 D4).
# AMENDED IN WP9: both drivers now tear down through the SHARED `driver_cleanup`
# (which calls response_destroy then request_arena_destroy in the D4 order), so
# the assertion is that each driver invokes that cleanup — not that each one
# repeats the arena call literally.
grep -qE 'driver_cleanup\(' "${DRUSE_TS_FILES[@]}" ||
  fail "the test-support facade does not call driver_cleanup; the driver must free the response and the arena (WP7 D4)"
grep -qE 'driver_cleanup\(' "$DRUSE_WEB/serve.odin" ||
  fail "web/serve.odin does not call driver_cleanup; the real transport must free the response and the arena (WP7 D4)"
DRUSE_SERVE_WITHOUT_COMMENTS="$(sed -E 's://.*$::' "$DRUSE_WEB/serve.odin")"
grep -qE 'request_arena_destroy\([a-z_]+\)' <<<"$DRUSE_SERVE_WITHOUT_COMMENTS" ||
  fail "driver_cleanup does not release the request arena (WP7 D4)"

# 10d-viii. NO configurable body limit, replay, or cache entered the package.
#           These are the WP7 non-goals the prompt forbids. The patterns target
#           configurability and replay specifically — a per-request `body_limit`
#           FIELD, a setter, a size knob, a replay/cache — without matching the
#           fixed `BODY_LIMIT` constant that the cap legitimately uses.
for DRUSE_WP7_BAN in 'set_body_limit' 'max_body_size' 'body_replay' '\breplay\b' \
  'body_cache' 'Body_Cache' 'body_limit[[:space:]]*:' 'configurable'; do
  if grep -nE "$DRUSE_WP7_BAN" <<<"$DRUSE_WEB_CODE"; then
    fail "web/ contains a WP7 non-goal matching /$DRUSE_WP7_BAN/ (no configurable limit, replay or cache)"
  fi
done

# 10d-ix. The two WP7 wire codes are spelled exactly right (docs/errors.md).
for DRUSE_CODE in invalid_json body_too_large; do
  grep -qE "\"$DRUSE_CODE\"" <<<"$DRUSE_WEB_CODE" ||
    fail "the ratified WP7 error code '$DRUSE_CODE' is missing from web/ (docs/errors.md)"
done

# 10d-x. 413 is now the PUBLIC `Status.Payload_Too_Large` member (corrective WP
#        C1, friction F8-1): three independent applications were forced to cast a
#        raw `Status(413)`, so the code is named on the public surface. The
#        body-too-large path must therefore reference the NAMED member, not a
#        private `Status(413)` cast — the inverse of the old WP7 D3 control.
if grep -qE 'STATUS_BODY_TOO_LARGE|Status\(413\)' <<<"$DRUSE_WEB_CODE"; then
  fail "the body-too-large path still casts a private Status(413); use the public .Payload_Too_Large member (C1/F8-1)"
fi
awk '/^Status :: enum int \{/{f=1;next} /^\}/{f=0} f' <<<"$DRUSE_WEB_PUBLIC_CODE" |
  grep -qE 'Payload_Too_Large += 413' ||
  fail "the public Status.Payload_Too_Large = 413 member is missing (C1/F8-1)"

# 10e. The two WP5 error codes are spelled exactly as the ratified wire contract
#      requires (docs/errors.md). A typo here is a silent compatibility break:
#      clients match on `code`.
for DRUSE_CODE in invalid_path_parameter invalid_query_parameter; do
  grep -qE "\"$DRUSE_CODE\"" <<<"$DRUSE_WEB_CODE" ||
    fail "the ratified error code '$DRUSE_CODE' is missing from web/ (docs/errors.md)"
done

# 10f. The WP5 internal tests live OUTSIDE the shipped package, like WP2/WP3/WP4.
DRUSE_WP5_TESTS="$DRUSE_ROOT/tests/wp5-internal"
test -d "$DRUSE_WP5_TESTS" ||
  fail "tests/wp5-internal/ is missing; the WP5 internal-behavior tests have no home outside the shipped package"
grep -qx 'package web' "$DRUSE_WP5_TESTS"/*.odin ||
  fail "tests/wp5-internal/ does not declare 'package web'; it could not reach the package-private envelope machinery it exists to test"

# The three discard probes must exist: they are the ONLY executable evidence
# that `#optional_ok` was not re-added.
for DRUSE_PROBE_FILE in discard_path_int_ok discard_query_int_ok discard_query_int_or_ok; do
  test -f "$DRUSE_ROOT/tests/wp5-public-surface/probes/$DRUSE_PROBE_FILE.odin" ||
    fail "the WP5 negative probe '$DRUSE_PROBE_FILE.odin' is missing; ADR-002 would be unenforced"
done

echo "public API contract: every shipped file declares its ledger; subdirectory structure is exact"
echo "public API contract: application ledger 80 + test-support ledger 2 = union 82"
echo "public API contract: Method is the ratified UPPERCASE set; Request has the five ratified fields"
echo "public API contract: Response, Header_Pair and Header_View_Internal stayed internal"
echo "public API contract: web/testing machinery imports no druse:web / core:testing, declares no @(init)"
echo "public API contract: no later-phase symbol, dynamic storage, or backend leak"
echo "public API contract: WP4 dispatch files export nothing; dispatch takes the App explicitly"
echo "public API contract: Allow is exactly 'Allow' in canonical GET, POST, PUT, PATCH, DELETE order"
echo "public API contract: no radix/wildcard/middleware construct entered the interim dispatcher"
echo "public API contract: the five extractor signatures are exact and carry no #optional_ok"
echo "public API contract: the dispatcher neither imports the JSON encoder nor marshals"
echo "public API contract: response ownership and the envelope machinery stayed internal"
echo "public API contract: Content-Type values are exact and 'field' is omitted by type"
# ---------------------------------------------------------------------------
# 11. WP9 transport conformance (planning/phase-1-plan.md §WP9 D1-D7)
#
# WP9 is test-only work plus a hardened adapter. These pin the properties the
# conformance suites rely on but cannot themselves observe.
# ---------------------------------------------------------------------------
# The adapter was DERIVED in section 1 as the single file that imports the
# vendored backend; its filename is not contract (WP16).
test -n "${DRUSE_ADAPTER:-}" ||
  fail "no adapter was derived; no file under web/internal/transport/ imports the vendored backend, so the WP8 adapter is missing"
DRUSE_ADAPTER_CODE="$(sed -E 's://.*$::' "$DRUSE_ADAPTER")"

# 11a. The backend must not rewrite a method before the core decides (D7), and
#      must not answer 100-continue on its own (D5). Corrective WP C6 (F8-7)
#      keeps auto_expect_continue OFF — the vendored auto-continue blocked waiting
#      for a body — but the adapter now HONORS 100-continue by reading the body
#      (no interim response) instead of a hard 417; other expectations still 417.
grep -qE 'opts\.redirect_head_to_get = false' <<<"$DRUSE_ADAPTER_CODE" ||
  fail "redirect_head_to_get must stay false; HEAD must not be silently converted to GET (WP9 D7)"
grep -qE 'opts\.auto_expect_continue = false' <<<"$DRUSE_ADAPTER_CODE" ||
  fail "auto_expect_continue must stay false; the vendored auto-continue blocks, so 100-continue is honored by reading the body, not by an interim response (WP9 D5 / C6 F8-7)"

# 11b. The five vendored framing patches are held by EXECUTABLE evidence, not
#      by the shape of their code (WP16, audit A-10).
#
#      The old form of this section grepped the vendor sources for the exact
#      spelling of each patch — so a correct re-application written as
#      `if len(token) > 0 {` failed the gate, while an unrelated line that
#      happened to match passed it. Code-shape greps prove spelling, not
#      behaviour. The real evidence is the raw-wire corpus: every one of the
#      five patches exists because a corpus case FAILED before it, and the
#      corpus runs against the real adapter on every gate run
#      (build/check.sh, the wp9-wire step). Reverting a patch therefore fails
#      the gate BEHAVIOURALLY — two of the reversions crash the server
#      process, which is exactly what the corpus observes.
#
#      What a behavioural check cannot see is the corpus case being DELETED
#      together with the reversion. So the static assertion that remains is
#      coverage: the corpus must keep carrying a named case for each of the
#      five patches (vendor/odin-http/VENDOR.md §Local patches). Deleting the
#      case is caught here; reverting the patch is caught by the run.
DRUSE_WIRE_CORPUS="$DRUSE_ROOT/tests/support/transport_conformance/corpus.odin"
test -f "$DRUSE_WIRE_CORPUS" ||
  fail "tests/support/transport_conformance/corpus.odin is missing; the raw-wire corpus is the executable evidence behind the five vendor patches"
druse_expect_wire_case() { # case-name patch-description
  grep -qF "name = \"$1\"," "$DRUSE_WIRE_CORPUS" ||
    fail "the raw-wire corpus no longer carries the case \"$1\" — the executable evidence for the vendor patch '$2' (vendor/odin-http/VENDOR.md §Local patches). The patch is held by this case failing before it and passing after it; without the case, reverting the patch would go unobserved."
}
druse_expect_wire_case "negative Content-Length is rejected" \
  "Content-Length must be a whole non-negative decimal (patch 1, remote DoS)"
druse_expect_wire_case "chunk without CRLF is rejected" \
  "a malformed chunk is rejected, not asserted (patch 2, remote DoS)"
druse_expect_wire_case "CL+TE is rejected (smuggling vector)" \
  "Content-Length + Transfer-Encoding is rejected, not repaired (patch 3)"
druse_expect_wire_case "duplicate identical Content-Length is rejected" \
  "any repeated Content-Length is rejected (patch 4)"
druse_expect_wire_case "valid unknown method reaches the core, not a backend 501" \
  "an unknown method token is preserved for the core to decide (patch 5)"
# And the wp9-wire suite must actually execute that corpus data, or the five
# cases above are dead text.
grep -rqE 'wire_corpus' "$DRUSE_ROOT/tests/wp9-wire"/*.odin ||
  fail "tests/wp9-wire/ no longer runs the shared wire corpus; the five vendor-patch cases would be dead data"

# 11c. The conformance harness is TEST-ONLY and never reaches the shipped
#      package (WP9 D1 — this is why it is not in web/testing/).
DRUSE_HARNESS="$DRUSE_ROOT/tests/support/transport_conformance"
test -d "$DRUSE_HARNESS" ||
  fail "tests/support/transport_conformance/ is missing; the shared conformance harness has no home"
grep -qE 'transport_contract_test :: proc' "$DRUSE_HARNESS"/*.odin ||
  fail "the harness does not define transport_contract_test(t, factory) (architecture spec §Three test suites)"
grep -qE 'Transport_Factory :: struct' "$DRUSE_HARNESS"/*.odin ||
  fail "the harness does not define Transport_Factory"
if grep -rn 'transport_conformance' "$DRUSE_WEB" 2>/dev/null; then
  fail "the shipped package references the test-only conformance harness"
fi
grep -qx "Transport_Factory" <<<"$DRUSE_ACTUAL_EXPORTS" &&
  fail "Transport_Factory became a public symbol; it is test-only (WP9 D1)"

# 11d. The raw-wire corpus must NOT be pointed at the in-memory transport: it
#      has no TCP parser, so that would be meaningless green (WP9 D1).
if grep -rn 'wire_corpus' "$DRUSE_ROOT/tests/wp9-semantic" "$DRUSE_ROOT/tests/wp9-semantic-internal" 2>/dev/null; then
  fail "the raw-wire corpus is referenced by a SEMANTIC suite; it runs only against real adapters (WP9 D1)"
fi

# 11e. The semantic matrix must run on BOTH factories — one suite each.
grep -rqE 'transport_contract_test' "$DRUSE_ROOT/tests/wp9-semantic-internal"/*.odin ||
  fail "the in-memory factory does not run the shared semantic matrix (WP9 D1)"
grep -rqE 'transport_contract_test' "$DRUSE_ROOT/tests/wp9-semantic"/*.odin ||
  fail "the real-HTTP factory does not run the shared semantic matrix (WP9 D1)"

# 11f. Every SOCKET suite runs under an external timeout: a hang is a failure,
#      never a stalled gate.
#
#      The old form grepped its caller for the substring 'timeout [0-9]+ env',
#      which proved only that SOME command somewhere used a timeout. This form
#      names the contract per suite: for each socket-binding test directory,
#      the check.sh command that invokes it (continuation lines joined) must
#      begin under `timeout N`. wp9-semantic-internal is deliberately absent —
#      it is the in-memory factory and binds nothing.
DRUSE_CHECK_SH_JOINED="$(awk '{ if (sub(/\\$/, "")) { buf = buf $0; next } print buf $0; buf = "" }' \
  "$DRUSE_ROOT/build/check.sh")"
for DRUSE_SOCKET_SUITE in wp8-socket wp9-semantic wp9-wire; do
  DRUSE_SUITE_INVOCATIONS="$(grep -E "\" test \".*tests/$DRUSE_SOCKET_SUITE\"" <<<"$DRUSE_CHECK_SH_JOINED" || true)"
  test -n "$DRUSE_SUITE_INVOCATIONS" ||
    fail "build/check.sh no longer invokes the socket suite tests/$DRUSE_SOCKET_SUITE; the transport contract it proves would go unexercised"
  if grep -vqE 'timeout [0-9]+ ' <<<"$DRUSE_SUITE_INVOCATIONS"; then
    echo "$DRUSE_SUITE_INVOCATIONS" >&2
    fail "the socket suite tests/$DRUSE_SOCKET_SUITE runs without an external 'timeout N' wrapper in build/check.sh; a hanging adapter would stall the gate instead of failing it"
  fi
done

echo "public API contract: WP9 harness is test-only; both factories run the shared matrix"
echo "public API contract: the adapter keeps HEAD and Expect under core control; the wire corpus covers all five vendor patches"

# ---------------------------------------------------------------------------
# ADR-047 — the core installs NO crash signal handler, and no fault hook
#
# ACCEPTED 2026-07-25. A library that claims SIGSEGV/SIGABRT is process-wide
# state: it collides with the supervisor's core-dump capture, an APM agent's
# crash reporter and the operator's debugger, and an async-signal handler that
# gets safety wrong turns a clean crash into a hang or a corrupted core. What
# ships instead is `ops/deploy/druse.service` (Restart=on-failure) plus the
# `coredumpctl` workflow in docs/operations.md, which names the faulting handler
# on the stack with its full call chain — strictly more than a breadcrumb.
#
# This is gated because it is the decision a well-meaning change reverses by
# accident: "a bounds trap kills the process with no diagnostics" invites
# exactly the handler ADR-047 refused. The ADR names its own reversal path — a
# new ADR carrying an async-signal-safety proof — so a future author who really
# wants this has a door, and it is not this grep.
#
# Comments are stripped first: an ADR reference that names the construct in
# order to forbid it must not be reported as the construct.
# ---------------------------------------------------------------------------
DRUSE_FAULT_CODE="$(sed -E 's://.*$::' $(find "$DRUSE_ROOT/web" -name '*.odin'))"
if grep -qE '\b(sigaction|libc\.signal|signal\.signal)\b' <<<"$DRUSE_FAULT_CODE"; then
  fail "web/ installs a signal handler. ADR-047 decided the core installs none: it fights the operator's crash tooling and the supervisor + coredump own a fault. Reversing it needs its own ADR with an async-signal-safety proof, not a grep change."
fi
if grep -qE 'assertion_failure_proc[[:space:]]*=' <<<"$DRUSE_FAULT_CODE"; then
  fail "web/ overrides context.assertion_failure_proc. Besides ADR-047's minimal-core rule, this cannot do what motivates it: bounds failures go through a \"contextless\" trap in the pinned runtime (base/runtime/error_checks.odin) and never consult the context, so the hook would catch explicit asserts only while reading as general fault isolation."
fi
# The vendored backend ships `server_shutdown_on_interrupt` (a SIGINT handler).
# It is unreferenced in this tree and must stay that way: `web.stop` is the
# shutdown entry point, and it is already documented as signal-handler-safe.
if grep -rn 'server_shutdown_on_interrupt' "$DRUSE_ROOT/web" --include='*.odin' >/dev/null 2>&1; then
  fail "web/ calls the vendored server_shutdown_on_interrupt, installing a process-wide SIGINT handler from a library (ADR-047). Applications install their own and call web.stop, which is safe from a signal handler by design."
fi

# T1 — nothing may pass `trigger_wake_up = false` to a cross-thread `nbio.exec`.
# The MPSC tolerates a producer stalled between claiming a slot and storing into
# it only because every producer wakes the loop afterwards; skipping the wake can
# strand that item and everything queued behind it until an unrelated wake
# arrives. Druse never passes the parameter at all, which is the simplest way
# to be right; this keeps it so.
if grep -rnE 'exec\([^)]*trigger_wake_up[[:space:]]*(:?=)[[:space:]]*false' \
  "$DRUSE_ROOT/web" "$DRUSE_ROOT/vendor/odin-http" --include='*.odin' >/dev/null 2>&1; then
  fail "a caller passes trigger_wake_up=false to nbio.exec. For a cross-thread exec that breaks the MPSC wake invariant (vendor/nbio/mpsc.odin): the item can sit undelivered behind a stalled producer until an unrelated wake arrives (transport audit T1)."
fi

echo "public API contract: no signal handler and no assertion hook in the core (ADR-047)"
echo "public API contract: no cross-thread exec skips the MPSC wake (T1)"
echo "public API contract: WP7 arena is private; the 4 MiB cap gates the parser; strict JSON; 413 is the public Status.Payload_Too_Large member (C1)"
echo "PASS: Phase-1 public API anti-accretion contract (WP1 + WP2 + WP3 + WP4 + WP5 + WP6 + WP7)"
