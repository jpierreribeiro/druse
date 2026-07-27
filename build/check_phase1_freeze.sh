#!/usr/bin/env bash
#
# WP11 — PHASE 1 SPEC FREEZE GATE.
#
# This is the gate that makes the Phase-1 freeze mean something. Every other
# checker in build/ proves a behavior; this one proves that the SHAPE of the
# public contract, the dependency set it rests on, and the evidence trail behind
# it are all exactly what planning/phase-1-freeze.md says they are.
#
# It deliberately does NOT re-implement the checks that already exist. The
# public-surface counter, the documentation-parity gate and the example gate are
# invoked by build/check.sh in their own steps; duplicating their logic here
# would create two sources of truth that can drift. What this gate adds is the
# part nothing else covers:
#
#   * the FULL normalized signature of all 34 exported symbols, including every
#     struct field, every enum member and every enum backing type, diffed
#     against a committed snapshot;
#   * the direct-import set of every first-party package, diffed against a
#     committed snapshot;
#   * the evidence matrix in the freeze manifest, with every cited file and
#     every cited test identifier resolved against the working tree;
#   * the absence of unfinished-work markers and future-phase vocabulary.
#
# A snapshot diff is the mutation probe: adding a symbol, changing an argument,
# widening an enum, adding a field, moving a symbol between ledgers or renaming
# anything all surface as a diff and fail the gate.
#
set -Eeuo pipefail

URUQUIM_FREEZE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$URUQUIM_FREEZE_ROOT"

URUQUIM_ODIN_BIN="${URUQUIM_ODIN_BIN:-odin}"
URUQUIM_FREEZE_MANIFEST="planning/phase-1-freeze.md"
URUQUIM_FREEZE_SIGNATURES="build/phase1-public-signatures.txt"
URUQUIM_FREEZE_DEPENDENCIES="build/phase1-direct-dependencies.txt"

fail() { echo "FAIL: $*" >&2; exit 1; }

URUQUIM_FREEZE_TMP="$(mktemp -d -t uruquim-freeze-XXXXXXXX)"
trap 'rm -rf "$URUQUIM_FREEZE_TMP"' EXIT

# The two symbols that live in the SEPARATE test-support ledger (G-11). Every
# other exported symbol belongs to the 32-symbol application ledger.
URUQUIM_FREEZE_TEST_SUPPORT='^(Recorded_Response|test_request)$'

# ---------------------------------------------------------------------------
# 1-3. Public signature inventory, normalized and diffed against the snapshot.
# ---------------------------------------------------------------------------
#
# The compiler is the source of truth, not a hand-maintained list. Two views are
# needed: `-short` renders procedure signatures but collapses every type body to
# `{...}`, while the full form expands struct fields and enum members. The
# procedures come from the first, the types from the second.
#
# Normalization removes ONLY the unstable `/* file!offset */` position markers.
# Names, types, arguments, results, genericity, field names, enum members and
# enum backing types are all preserved verbatim: those are the contract.

# The two section extractors, defined ONCE so the positive control below tests
# the same code the gate runs. A control that exercises a copy proves nothing.
URUQUIM_FREEZE_AWK_PROCS='/^\tprocedures$/{on=1;next} /^\t(proc_group|types|fullpath:)$/{on=0} on&&/^\t\t[A-Za-z_]/{print}'
URUQUIM_FREEZE_AWK_GROUPS='/^\tproc_group$/{on=1;next} /^\t(procedures|types|fullpath:)$/{on=0} on&&/^\t\t[A-Za-z_]/{print}'

# ---------------------------------------------------------------------------
# 0. Positive control: prove the extractors can actually SEE a procedure group.
# ---------------------------------------------------------------------------
#
# This exists because they could not. An exported procedure group whose members
# are all `@(private)` is public and cross-package-callable, yet produces no
# `procedures` section at all, so the original extractor returned nothing for it
# and the counted ledger stayed unmoved. `odin doc` was reporting the group the
# whole time; this script was not reading that section.
#
# Without this control the fix is unverifiable: a future edit could break the
# pattern again and every assertion below would still pass, because the real
# package currently exports no groups. A check that cannot fail is not evidence.
uruquim_freeze_selftest_group_extraction() {
  local dir="$URUQUIM_FREEZE_TMP/selftest"
  mkdir -p "$dir/probe"
  cat >"$dir/probe/lib.odin" <<'''SELFTEST'''
package probe
@(private)
sample_a :: proc(x: int) -> int { return x }
@(private)
sample_b :: proc(x: string) -> int { return len(x) }
sample :: proc{ sample_a, sample_b }
SELFTEST

  local doc="$dir/doc.txt"
  env -u ODIN_ROOT "$URUQUIM_ODIN_BIN" doc "$dir/probe" -short >"$doc" 2>/dev/null ||
    fail "the group-extraction self-test could not run odin doc"

  local seen
  seen="$(awk "$URUQUIM_FREEZE_AWK_GROUPS" "$doc" | sed -E '''s@^\t\t@@''' | head -1)"
  case "$seen" in
    "sample :: proc{sample_a, sample_b}") : ;;
    *) fail "the proc_group extractor does not see an exported group whose members are private.
    Expected: sample :: proc{sample_a, sample_b}
    Got:      ${seen:-<nothing>}
  Such a group is public and callable from another package, so if this extractor
  cannot see it, a new public symbol can be added with the ledger unmoved." ;;
  esac

  # And the procedures extractor must NOT swallow the group's member line: the
  # sections are indented identically, so an unbounded range miscounts silently.
  if awk "$URUQUIM_FREEZE_AWK_PROCS" "$doc" | grep -q 'proc{'; then
    fail "the procedures extractor is capturing proc_group lines; the section boundary is wrong"
  fi
}

uruquim_freeze_generate_signatures() { # -> stdout
  local short full
  short="$URUQUIM_FREEZE_TMP/doc-short.txt"
  full="$URUQUIM_FREEZE_TMP/doc-full.txt"

  env -u ODIN_ROOT "$URUQUIM_ODIN_BIN" doc web -collection:uruquim=. -short \
    >"$short" 2>"$URUQUIM_FREEZE_TMP/doc-short.err" ||
    fail "odin doc web -short failed; see $URUQUIM_FREEZE_TMP/doc-short.err"
  env -u ODIN_ROOT "$URUQUIM_ODIN_BIN" doc web -collection:uruquim=. \
    >"$full" 2>"$URUQUIM_FREEZE_TMP/doc-full.err" ||
    fail "odin doc web failed; see $URUQUIM_FREEZE_TMP/doc-full.err"

  # Procedures: from the short view, body placeholder and position marker cut.
  #
  # The section MUST be bounded by every following section header, not just
  # `types`. `odin doc` emits `proc_group` between `procedures` and `types`, and
  # a range that only closes on `types` swallows the group's member lines into
  # the procedure ledger — they are indented identically. That is a silent
  # miscount, so the boundary is explicit.
  awk "$URUQUIM_FREEZE_AWK_PROCS" "$short" \
  | sed -E 's@ /\* [0-9]+![0-9]+ \*/@@; s@ \{\.\.\.\}$@@; s@^\t\t@@' \
  | while IFS= read -r decl; do
      name="${decl%% ::*}"
      if [[ "$name" =~ $URUQUIM_FREEZE_TEST_SUPPORT ]]; then
        printf 'test-support\tproc\t%s\n' "$decl"
      else
        printf 'application\tproc\t%s\n' "$decl"
      fi
    done

  # Procedure groups: their own `odin doc` section, and their own ledger kind.
  #
  # WHY THIS EXISTS. An exported procedure group whose members are all
  # `@(private)` is a PUBLIC, cross-package-callable symbol that produces NO
  # `procedures` section at all — verified on the pinned compiler. Reading only
  # `procedures` therefore missed it entirely, so a new public capability could
  # be added with the counted ledger unmoved. That is precisely the accretion
  # this gate exists to prevent. `odin doc` reports the group faithfully; the
  # omission was in this extractor, not in the compiler.
  awk "$URUQUIM_FREEZE_AWK_GROUPS" "$short" \
  | sed -E 's@ /\* [0-9]+![0-9]+ \*/@@; s@^\t\t@@' \
  | while IFS= read -r decl; do
      name="${decl%% ::*}"
      if [[ "$name" =~ $URUQUIM_FREEZE_TEST_SUPPORT ]]; then
        printf 'test-support\tgroup\t%s\n' "$decl"
      else
        printf 'application\tgroup\t%s\n' "$decl"
      fi
    done

  # Constants: their own `odin doc` section, and — until WP36 — a KIND THIS
  # EXTRACTOR NEVER READ.
  #
  # WHY IT MATTERS, and it is the same hole the proc-group branch above was
  # written for. An exported constant is a public symbol: `check_public_api.sh`
  # counts it, an application can name it, and its VALUE is a promise. Reading
  # only procedures, groups and types meant such a constant was invisible to the
  # snapshot, so its value could be changed with the frozen inventory unmoved —
  # and `DEFAULT_LIMITS` is precisely a constant whose value IS the contract.
  # Found while freezing WP36, closed here.
  #
  # The declaration is taken verbatim, so a changed default is a snapshot diff.
  # It reads the FULL view, not the short one: the short view renders a struct
  # constant as `Limits{...}`, eliding exactly the values that are the promise.
  awk '/^\tconstants$/{on=1;next} /^\t[a-z_]+$/{on=0} /^\tfullpath:/{on=0} on&&/^\t\t[A-Za-z_][A-Za-z0-9_]* ::/{print}' "$full" \
  | sed -E 's@ /\* [0-9]+![0-9]+ \*/@@; s@^\t\t@@' \
  | while IFS= read -r decl; do
      name="${decl%% ::*}"
      if [[ "$name" =~ $URUQUIM_FREEZE_TEST_SUPPORT ]]; then
        printf 'test-support\tconst\t%s\n' "$decl"
      else
        printf 'application\tconst\t%s\n' "$decl"
      fi
    done

  # Types: from the full view, which expands fields and enum members. The full
  # view interleaves doc comments, so only the declaration lines are taken.
  awk '/^\ttypes$/{on=1;next} /^\tfullpath:/{on=0} on&&/^\t\t[A-Z][A-Za-z_]* ::/{print}' "$full" \
  | sed -E 's@ /\* [0-9]+![0-9]+ \*/@@; s@^\t\t@@' \
  | while IFS= read -r decl; do
      name="${decl%% ::*}"
      if [[ "$name" =~ $URUQUIM_FREEZE_TEST_SUPPORT ]]; then
        printf 'test-support\ttype\t%s\n' "$decl"
      else
        printf 'application\ttype\t%s\n' "$decl"
      fi
    done
}

uruquim_freeze_selftest_group_extraction

URUQUIM_FREEZE_ACTUAL_SIG="$URUQUIM_FREEZE_TMP/signatures.actual"
uruquim_freeze_generate_signatures | LC_ALL=C sort >"$URUQUIM_FREEZE_ACTUAL_SIG"

[ -s "$URUQUIM_FREEZE_ACTUAL_SIG" ] ||
  fail "the signature inventory came back empty; odin doc produced nothing parseable"

[ -f "$URUQUIM_FREEZE_SIGNATURES" ] ||
  fail "$URUQUIM_FREEZE_SIGNATURES is missing; the frozen signature snapshot must be committed"

if ! diff -u "$URUQUIM_FREEZE_SIGNATURES" "$URUQUIM_FREEZE_ACTUAL_SIG" \
     >"$URUQUIM_FREEZE_TMP/signatures.diff" 2>&1; then
  echo "--- frozen signature snapshot vs. the compiler's actual output ---" >&2
  sed 's/^/    /' "$URUQUIM_FREEZE_TMP/signatures.diff" >&2
  fail "the exported surface no longer matches $URUQUIM_FREEZE_SIGNATURES. A symbol was added, removed, renamed, moved between ledgers, or its arguments, results, genericity, fields or enum members changed. Phase-1 contracts are frozen: this requires a spec amendment, not a snapshot refresh."
fi

# ---------------------------------------------------------------------------
# 3b. An exported procedure group must not hide its members' signatures.
# ---------------------------------------------------------------------------
#
# `odin doc` renders a group as `name :: proc{member_a, member_b}` — member
# NAMES only. If those members are `@(private)` they never appear in the
# `procedures` section, so the snapshot pins the group's name and nothing else.
# Measured on the pinned compiler: rewriting a private member's parameters from
# `(Method, string, string)` to `(Method, string, []u8, int)` left the snapshot
# line byte-identical. The symbol stays publicly callable the whole time.
#
# That is strictly worse than the blind spot fixed above: this hides a public
# symbol's entire calling contract rather than its existence. There is no way to
# recover the signatures from `odin doc`, so the gate refuses the construct
# instead of pretending to freeze it. A group whose members are all public is
# fine — their signatures are pinned individually.
while IFS=$'\t' read -r ledger kind decl; do
  [ "$kind" = "group" ] || continue
  gname="${decl%% ::*}"
  members="${decl#*proc\{}"; members="${members%\}}"
  IFS=',' read -ra gmembers <<<"$members"
  for m in "${gmembers[@]}"; do
    m="$(printf '%s' "$m" | tr -d '[:space:]')"
    [ -n "$m" ] || continue
    grep -qE "^(application|test-support)"$'\t'"proc"$'\t'"${m} ::" "$URUQUIM_FREEZE_ACTUAL_SIG" ||
      fail "the exported procedure group '$gname' has a member '$m' that is not itself exported, so its signature cannot be frozen.
  \`odin doc\` renders a group as member NAMES only, and private members appear
  nowhere else, so the snapshot would pin '$gname' while its actual parameters
  and results stayed free to change. Verified: rewriting a private member's
  parameter types leaves the snapshot line byte-identical.
  Either export the members so their signatures are pinned individually, or use
  a single procedure with default parameters, which keeps the whole signature in
  the frozen record."
  done
done <"$URUQUIM_FREEZE_ACTUAL_SIG"

# ---------------------------------------------------------------------------
# 4. The ledgers still add up: 63 application + 2 test-support = 65
#    (32 frozen Phase-1 application symbols, plus WP17 use/next — Amendment
#    3 — WP18 Router/router/mount — Amendment 4 — and WP19 header/
#    bearer_token — Amendment 5 — the test_request headers parameter —
#    Amendment 6 — and WP20 observe/Framework_Event/Framework_Error —
#    Amendment 7 — and WP34 route — Amendment 10, the first Phase-3
#    amendment, decided under the ADR-029 delegation — and WP37
#    app_with_state/state — Amendment 11 — and WP36 Limits/DEFAULT_LIMITS/
#    limits — Amendment 12. All ratified.)
# ---------------------------------------------------------------------------
URUQUIM_FREEZE_APP_COUNT="$(grep -c '^application	' "$URUQUIM_FREEZE_ACTUAL_SIG" || true)"
URUQUIM_FREEZE_TS_COUNT="$(grep -c '^test-support	' "$URUQUIM_FREEZE_ACTUAL_SIG" || true)"
URUQUIM_FREEZE_TOTAL="$(( URUQUIM_FREEZE_APP_COUNT + URUQUIM_FREEZE_TS_COUNT ))"

[ "$URUQUIM_FREEZE_APP_COUNT" -eq 80 ] ||
  fail "the application ledger holds $URUQUIM_FREEZE_APP_COUNT symbols, not the recorded 80 (… plus C4 stream_live, plus C7 request_state)"
[ "$URUQUIM_FREEZE_TS_COUNT" -eq 2 ] ||
  fail "the test-support ledger holds $URUQUIM_FREEZE_TS_COUNT symbols, not the frozen 2"
[ "$URUQUIM_FREEZE_TOTAL" -eq 82 ] ||
  fail "the exported union is $URUQUIM_FREEZE_TOTAL, not the recorded 82"

# ---------------------------------------------------------------------------
# 5. Named assertions on the contracts most likely to be eroded quietly.
# ---------------------------------------------------------------------------
#
# These are redundant with the snapshot diff by construction, and that is the
# point: if someone regenerates the snapshot to make a change "pass", these
# still fail, because they encode the DECISION rather than the current state.

uruquim_freeze_expect_decl() { # description exact-line
  grep -qxF "$2" "$URUQUIM_FREEZE_ACTUAL_SIG" ||
    fail "$1 — expected this exact frozen declaration:
    $2
  It is not present in the compiler's output. See planning/phase-1-freeze.md."
}

uruquim_freeze_expect_decl "Method must stay a closed 6-member u8 enum" \
  'application	type	Method :: enum u8 {UNKNOWN, GET, POST, PUT, PATCH, DELETE}'

# Status is the closed int enum. Two corrective WPs have widened it, each with an
# amendment in planning/phase-1-freeze.md and each additive only — no member has
# ever moved:
#   C1 (friction F8-1, Amendment 32) added the operationally-essential codes three
#     independent applications were forced to spell as raw-int casts: 409, 413,
#     429, 503.
#   C8 (friction F8-9, Amendment 38) added the redirect family the enum did not
#     name at all: 301, 302, 303, 307, 308. Without them POST/Redirect/GET could
#     not be written against the core.
# The set is again closed and pinned here. 304 is deliberately absent: it stays a
# private Status(304), framework-internal cache negotiation a handler never returns.
uruquim_freeze_expect_decl "Status must stay the closed 19-member int enum (C1: +409/413/429/503; C8: +301/302/303/307/308)" \
  'application	type	Status :: enum int {OK = 200, Created = 201, Accepted = 202, No_Content = 204, Moved_Permanently = 301, Found = 302, See_Other = 303, Temporary_Redirect = 307, Permanent_Redirect = 308, Bad_Request = 400, Unauthorized = 401, Forbidden = 403, Not_Found = 404, Method_Not_Allowed = 405, Conflict = 409, Payload_Too_Large = 413, Too_Many_Requests = 429, Internal_Server_Error = 500, Service_Unavailable = 503}'

uruquim_freeze_expect_decl "Handler must stay the single handler shape" \
  'application	type	Handler :: proc(ctx: ^Context)'

uruquim_freeze_expect_decl "Context must expose request only — never a response, params or extension bag" \
  'application	type	Context :: struct {request: Request, private: Context_Internal}'

uruquim_freeze_expect_decl "Request must stay the five-field view struct" \
  'application	type	Request :: struct {method: Method, path: string, query: string, headers: Header_View, body: []u8}'

uruquim_freeze_expect_decl "Header_View must stay opaque — Phase 1 ships no header lookup" \
  'application	type	Header_View :: struct {private: Header_View_Internal}'

uruquim_freeze_expect_decl "App must stay opaque" \
  'application	type	App :: struct {private: App_Internal}'

# AMENDED BY WP49 (Amendment 17): `headers` joins the recorded response, and
# D-14.3 is decided. The declaration stays pinned to the byte — this widened by
# ONE field with a recorded reason, and the next field is a decision too.
uruquim_freeze_expect_decl "Recorded_Response must carry status, body and headers — and nothing else" \
  'test-support	type	Recorded_Response :: struct {status: Status, body: string, headers: []string}'

# The extractors' named results are part of the contract: `value, ok` is what
# the canonical pattern reads, and `query` returning `found` rather than `ok`
# says presence, not validity.
uruquim_freeze_expect_decl "path_int must keep its named (value, ok) results" \
  'application	proc	path_int :: proc(ctx: ^Context, name: string) -> (value: int, ok: bool)'
uruquim_freeze_expect_decl "query must keep its named (value, found) results" \
  'application	proc	query :: proc(ctx: ^Context, name: string) -> (value: string, found: bool)'
uruquim_freeze_expect_decl "query_int must keep its named (value, ok) results" \
  'application	proc	query_int :: proc(ctx: ^Context, name: string) -> (value: int, ok: bool)'
uruquim_freeze_expect_decl "query_int_or must keep its default argument and named results" \
  'application	proc	query_int_or :: proc(ctx: ^Context, name: string, default_value: int) -> (value: int, ok: bool)'

# Genericity is contract: these four are the only parametric procedures, and
# `body` fills a destination while `json`/`ok`/`created` take a payload by value.
uruquim_freeze_expect_decl "body must stay destination-filling and generic" \
  'application	proc	body :: proc(ctx: ^Context, dst: ^$T) -> bool'
uruquim_freeze_expect_decl "json must stay generic and take its payload by value" \
  'application	proc	json :: proc(ctx: ^Context, status: Status, value: $T)'
uruquim_freeze_expect_decl "ok must stay generic and take its payload by value" \
  'application	proc	ok :: proc(ctx: ^Context, value: $T)'
uruquim_freeze_expect_decl "created must stay generic and take its payload by value" \
  'application	proc	created :: proc(ctx: ^Context, value: $T)'

# `#optional_ok` would let a caller silently drop `ok` from a value-producing
# extractor (ADR-002). odin doc renders the directive, so its absence is
# checkable directly on the compiler's output.
if grep -q '#optional_ok' "$URUQUIM_FREEZE_ACTUAL_SIG"; then
  fail "an exported procedure carries #optional_ok. Value-producing HTTP extractors deliberately omit it (ADR-002) so that dropping \`ok\` is a compile error."
fi

# ---------------------------------------------------------------------------
# 6-7. Direct dependency inventory, normalized and diffed against the snapshot.
# ---------------------------------------------------------------------------
#
# Taken from the real import statements, per first-party package. The vendored
# backend is inventoried as a unit rather than line by line: it is a pinned
# third-party snapshot (vendor/odin-http/VENDOR.md), and its internal imports
# are upstream's business, not a Uruquim contract.

uruquim_freeze_generate_dependencies() { # -> stdout
  local pkg
  for pkg in web web/testing web/internal/transport \
             examples/01-hello-world examples/02-json-api examples/03-route-params; do
    # shellcheck disable=SC2012
    grep -h -E '^[[:space:]]*import[[:space:]]' "$pkg"/*.odin 2>/dev/null \
    | sed -E 's@^[[:space:]]*@@; s@[[:space:]]+@ @g' \
    | sed -E 's@^import ([a-z_]+ )?"@import "@' \
    | LC_ALL=C sort -u \
    | while IFS= read -r imp; do printf '%s\t%s\n' "$pkg" "$imp"; done
  done
}

URUQUIM_FREEZE_ACTUAL_DEP="$URUQUIM_FREEZE_TMP/dependencies.actual"
uruquim_freeze_generate_dependencies >"$URUQUIM_FREEZE_ACTUAL_DEP"

[ -s "$URUQUIM_FREEZE_ACTUAL_DEP" ] ||
  fail "the dependency inventory came back empty; the import scan found nothing"

[ -f "$URUQUIM_FREEZE_DEPENDENCIES" ] ||
  fail "$URUQUIM_FREEZE_DEPENDENCIES is missing; the frozen dependency snapshot must be committed"

if ! diff -u "$URUQUIM_FREEZE_DEPENDENCIES" "$URUQUIM_FREEZE_ACTUAL_DEP" \
     >"$URUQUIM_FREEZE_TMP/dependencies.diff" 2>&1; then
  echo "--- frozen dependency snapshot vs. the actual imports ---" >&2
  sed 's/^/    /' "$URUQUIM_FREEZE_TMP/dependencies.diff" >&2
  fail "the direct dependency set changed. Every dependency needs an owner and a license in planning/phase-1-freeze.md; update the manifest and the snapshot together, deliberately."
fi

# Structural invariants that must hold no matter what the snapshot says.
grep -q '^web/testing	import "uruquim:web"' "$URUQUIM_FREEZE_ACTUAL_DEP" &&
  fail "web/testing imports uruquim:web — that back-edge is a compile cycle (probe C5) and the one-way boundary must hold"
grep -q '^web/internal/transport	import "uruquim:web"' "$URUQUIM_FREEZE_ACTUAL_DEP" &&
  fail "web/internal/transport imports uruquim:web — the transport boundary is one-way (ADR-009)"
if grep -E '^examples/' "$URUQUIM_FREEZE_ACTUAL_DEP" | grep -q 'vendor/'; then
  fail "an example imports the vendored backend directly; applications reach HTTP only through uruquim:web"
fi
if grep -E '^web/(testing)?	' "$URUQUIM_FREEZE_ACTUAL_DEP" | grep -q '"core:testing"'; then
  fail "core:testing is imported by a package that ships inside application binaries"
fi
if grep -q '^web/testing	import "core:net"' "$URUQUIM_FREEZE_ACTUAL_DEP"; then
  fail "web/testing imports core:net; test_request must reach no socket at all"
fi
if grep -E '^web	' "$URUQUIM_FREEZE_ACTUAL_DEP" | grep -q 'vendor/'; then
  fail "web imports the vendored backend directly; only web/internal/transport may name it (ADR-009)"
fi

# ---------------------------------------------------------------------------
# 8. The freeze manifest, and every evidence reference it makes.
# ---------------------------------------------------------------------------
[ -f "$URUQUIM_FREEZE_MANIFEST" ] ||
  fail "$URUQUIM_FREEZE_MANIFEST is missing; the Phase-1 freeze manifest is a required normative artifact"

# Unfinished-work markers. A freeze manifest that still says TODO is not a
# freeze. `\b` keeps this from firing on the sentence that defines the rule.
for marker in TODO FIXME MISSING UNPROVEN TBD XXX; do
  if grep -nE "(^|[^A-Za-z_\`])$marker([^A-Za-z_\`]|$)" "$URUQUIM_FREEZE_MANIFEST" \
     | grep -vE '^\s*[0-9]+:.*forbidden marker' >"$URUQUIM_FREEZE_TMP/marker.hits"; then
    if [ -s "$URUQUIM_FREEZE_TMP/marker.hits" ]; then
      sed 's/^/    /' "$URUQUIM_FREEZE_TMP/marker.hits" >&2
      fail "$URUQUIM_FREEZE_MANIFEST contains the unfinished-work marker '$marker'. A frozen contract cannot have open work in it."
    fi
  fi
done

# Every symbol must have its OWN ROW in the evidence matrix, carrying the same
# ledger the compiler's inventory assigns it.
#
# Merely appearing somewhere in the manifest is not enough: a symbol is named in
# the ledger lists of §2/§3 and in the prose of §6, so a name check alone would
# still pass after its matrix row was deleted. The row is therefore parsed
# structurally — `| `symbol` | A |` — and its ledger letter is compared against
# the snapshot, so deleting a row or relabelling a ledger both fail.
while IFS=$'\t' read -r ledger kind decl; do
  name="${decl%% ::*}"
  case "$ledger" in
    application)  want='A' ;;
    test-support) want='T' ;;
    *)            fail "unclassifiable ledger '$ledger' for '$name'" ;;
  esac

  rows="$(grep -cE "^\|[[:space:]]*\`${name}\`[[:space:]]*\|" "$URUQUIM_FREEZE_MANIFEST" || true)"
  [ "$rows" -ge 1 ] ||
    fail "the frozen symbol '$name' ($ledger) has no row in the evidence matrix of $URUQUIM_FREEZE_MANIFEST. Every symbol carries its own evidence; blanket coverage is not evidence."
  [ "$rows" -eq 1 ] ||
    fail "the frozen symbol '$name' has $rows rows in the evidence matrix; exactly one is expected"

  grep -qE "^\|[[:space:]]*\`${name}\`[[:space:]]*\|[[:space:]]*${want}[[:space:]]*\|" "$URUQUIM_FREEZE_MANIFEST" ||
    fail "the evidence row for '$name' does not record ledger '$want' ($ledger). The application and test-support ledgers are counted separately (G-11) and a symbol may not drift between them."

  # A row exists; it must also cite real evidence rather than being a placeholder.
  row="$(grep -m1 -E "^\|[[:space:]]*\`${name}\`[[:space:]]*\|" "$URUQUIM_FREEZE_MANIFEST")"
  case "$row" in
    *"::"*) : ;;
    *) fail "the evidence row for '$name' cites no resolvable evidence (no 'path::identifier' reference). A signature without proven behavior is not frozen." ;;
  esac
done <"$URUQUIM_FREEZE_ACTUAL_SIG"

if grep -q 'NOT_FROZEN' "$URUQUIM_FREEZE_MANIFEST"; then
  grep -n 'NOT_FROZEN' "$URUQUIM_FREEZE_MANIFEST" | sed 's/^/    /' >&2
  fail "$URUQUIM_FREEZE_MANIFEST marks at least one symbol NOT_FROZEN. A signature without proven behavior is not frozen, and Phase 1 cannot close over it."
fi

# Every evidence citation resolves. The manifest cites evidence as
# `path/to/file::identifier`; both halves are checked against the working tree,
# so a deleted test or a renamed procedure fails the gate rather than rotting
# silently into an unverifiable claim.
URUQUIM_FREEZE_REFS="$URUQUIM_FREEZE_TMP/evidence.refs"
grep -oE '(build|tests|examples|docs|experiments|web|planning|ops|vendor)/[A-Za-z0-9_./-]+::[A-Za-z0-9_.-]+' \
  "$URUQUIM_FREEZE_MANIFEST" | LC_ALL=C sort -u >"$URUQUIM_FREEZE_REFS" || true

URUQUIM_FREEZE_REF_COUNT="$(wc -l <"$URUQUIM_FREEZE_REFS" | tr -d ' ')"
[ "$URUQUIM_FREEZE_REF_COUNT" -ge 65 ] ||
  fail "$URUQUIM_FREEZE_MANIFEST carries only $URUQUIM_FREEZE_REF_COUNT resolvable evidence citations for 65 recorded symbols; the matrix is incomplete"

URUQUIM_FREEZE_BAD_REFS=0
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  refpath="${ref%%::*}"
  refid="${ref##*::}"
  if [ ! -f "$refpath" ]; then
    echo "    broken evidence: $ref (no such file: $refpath)" >&2
    URUQUIM_FREEZE_BAD_REFS=$(( URUQUIM_FREEZE_BAD_REFS + 1 ))
    continue
  fi
  if ! grep -qF "$refid" "$refpath"; then
    echo "    broken evidence: $ref (identifier '$refid' not found in $refpath)" >&2
    URUQUIM_FREEZE_BAD_REFS=$(( URUQUIM_FREEZE_BAD_REFS + 1 ))
  fi
done <"$URUQUIM_FREEZE_REFS"

[ "$URUQUIM_FREEZE_BAD_REFS" -eq 0 ] ||
  fail "$URUQUIM_FREEZE_BAD_REFS evidence citation(s) in $URUQUIM_FREEZE_MANIFEST do not resolve. Evidence that points at a test which does not exist is worse than no evidence."

# The record of what Phase 1 does NOT do must survive too. Deleting a row from
# the forwarded-items table is how a limitation quietly becomes a claim: the
# feature is still absent, but nothing says so any more, and the next reader
# assumes it shipped. Each forwarded item is therefore required by name.
for forwarded in middleware group radix wildcard 'typed state' 'header accessor' \
                 timeout streaming WebSocket upload 'static file' OpenAPI 'trusted prox'; do
  grep -qiF "$forwarded" "$URUQUIM_FREEZE_MANIFEST" ||
    fail "$URUQUIM_FREEZE_MANIFEST no longer records '$forwarded' as forwarded to a later phase. Phase 1 does not implement it, so the manifest must keep saying so — dropping the row turns an absent feature into an implied one."
done

# ---------------------------------------------------------------------------
# 10. No future-phase vocabulary on the public surface.
# ---------------------------------------------------------------------------
#
# Checked against the compiler's exported inventory, not the sources: a private
# helper may legitimately be called `middleware_free`, but nothing EXPORTED may
# carry Phase-2+ vocabulary, because that is how a future feature gets
# accidentally promised.
# `upload` LEFT THIS LIST on 2026-07-21, for the reason `cors` left the reserved
# names in check_public_api.sh: it was here to stop Phase 1 promising a feature
# it had not built, and Phase 5 built it (ADR-034, WP63). A word that guards an
# unbuilt feature stops guarding anything once the feature ships with its
# evidence — keeping it would only force the next person to spell the symbol
# badly.
# `stream` LEFT THIS LIST on 2026-07-23 for the identical reason: Phase 7 built
# response streaming (ADR-044, WP96) with its evidence, so `web.stream`/`Stream`/
# `stream_send`/`stream_close` are shipped contracts, not a promise. `websocket`
# and `openapi` in particular are still unbuilt and still demand-driven.
URUQUIM_FREEZE_FUTURE='middleware|group|radix|wildcard|user_data|locals|typed_state|static_file|openapi|websocket|recover|timeout|serve_with|serve_transport|header_lookup'
if cut -f3 "$URUQUIM_FREEZE_ACTUAL_SIG" | sed -E 's@ ::.*@@' \
   | grep -qiE "^($URUQUIM_FREEZE_FUTURE)"; then
  cut -f3 "$URUQUIM_FREEZE_ACTUAL_SIG" | sed -E 's@ ::.*@@' \
    | grep -iE "^($URUQUIM_FREEZE_FUTURE)" | sed 's/^/    /' >&2
  fail "an exported symbol carries future-phase vocabulary. Phase 1 must not promise a Phase 2+ feature by name."
fi

# ---------------------------------------------------------------------------
# 11. No open blocker is still assigned to Phase 1.
# ---------------------------------------------------------------------------
#
# The risk register and open-questions log are the record. An item that is still
# a live Phase-1 obligation blocks the freeze; deferral to a later phase does
# not, and neither does an accepted limitation.
for planfile in planning/risk-register.md planning/open-questions.md; do
  [ -f "$planfile" ] || fail "$planfile is missing; the freeze audit reads it"
  if grep -nE 'OPEN_BLOCKER|BLOCKER[[:space:]]*:?[[:space:]]*(OPEN|PHASE[ -]?1)|READY_WITH_BLOCKER' "$planfile" \
     >"$URUQUIM_FREEZE_TMP/blockers.hits" 2>/dev/null; then
    if [ -s "$URUQUIM_FREEZE_TMP/blockers.hits" ]; then
      sed 's/^/    /' "$URUQUIM_FREEZE_TMP/blockers.hits" >&2
      fail "$planfile still records an open blocker assigned to Phase 1. Phase 1 cannot be frozen over an unmet Phase-1 obligation."
    fi
  fi
done

# ---------------------------------------------------------------------------
# Report.
# ---------------------------------------------------------------------------
echo "freeze: signatures      -> $URUQUIM_FREEZE_APP_COUNT application + $URUQUIM_FREEZE_TS_COUNT test-support = $URUQUIM_FREEZE_TOTAL, byte-identical to the snapshot"
echo "freeze: fields/enums    -> Method(u8, 6), Status(int, 19, C1:+409/413/429/503, C8:+301/302/303/307/308), Handler, Context, Request, Header_View, App, Recorded_Response pinned"
echo "freeze: extractors      -> named results pinned, no #optional_ok on any exported procedure"
echo "freeze: dependencies    -> $(wc -l <"$URUQUIM_FREEZE_ACTUAL_DEP" | tr -d ' ') direct imports match the snapshot; boundaries one-way"
echo "freeze: evidence matrix -> $URUQUIM_FREEZE_REF_COUNT citations resolved, all 65 symbols present, none NOT_FROZEN"
echo "freeze: proc_group extraction self-test passed (private-member group is visible)"
echo "freeze: no future-phase vocabulary exported; no open Phase-1 blocker"
echo "PASS: Phase 1 freeze gate"
