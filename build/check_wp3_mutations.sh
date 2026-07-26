#!/usr/bin/env bash
# WP3 mutation checks — prove the dual-ledger guardrails actually REJECT the
# states they claim to forbid (WP3 prompt, TESTS-FIRST item 6).
#
# Each case copies the shipped package, tests, and checker into a throwaway
# tree, applies ONE forbidden mutation, runs the copied `check_public_api.sh`
# against that tree, and asserts it fails with the expected message. A guardrail
# that passes on a bad tree is worse than no guardrail; this file makes the
# rejection an executable, versioned fact rather than a claim.
#
# It never mutates the real repository: all work happens under `mktemp -d`.
set -euo pipefail

URUQUIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "MUTATION-FAIL: $*" >&2
  exit 1
}

# Run the copied checker on a mutated tree; require a non-zero exit AND the
# expected diagnostic. A wrong-reason failure is itself a failure.
#
# Every sed-based mutation goes through `mutate_sed` below, so by the time
# expect_reject runs, the edit is KNOWN to have applied — an "accepted" result
# here therefore really is a guardrail that stopped rejecting the state, not a
# probe that silently failed to create it.
expect_reject() { # tree label expected-substring
  local tree="$1" label="$2" expected="$3" out
  if out="$(bash "$tree/build/check_public_api.sh" 2>&1)"; then
    echo "$out" >&2
    fail "the mutated tree for '$label' PASSED the checker. The mutation was verified applied, so the guardrail that is supposed to reject this state no longer does."
  fi
  if ! grep -qF "$expected" <<<"$out"; then
    echo "$out" >&2
    fail "'$label' was rejected for the wrong reason; expected: $expected"
  fi
  echo "PASS (mutation): $label -> rejected"
}

# The mirror image: an edit that is a legal refactor must be ACCEPTED. These
# controls are what keep the checker pinned to CONTRACT rather than to the
# current spelling of the source (WP16).
expect_accept() { # tree label
  local tree="$1" label="$2" out
  if ! out="$(bash "$tree/build/check_public_api.sh" 2>&1)"; then
    echo "$out" >&2
    fail "the legal refactor '$label' was REJECTED. The checker is pinning implementation text instead of contract; a behaviour-preserving edit must pass without a gate change."
  fi
  echo "PASS (refactor control): $label -> accepted"
}

# Apply a sed mutation and PROVE it changed the file. A probe whose edit never
# applied exercises an unmutated tree and proves nothing — and the report it
# produced used to accuse the guardrail instead of the probe. BROKEN PROBE is
# its own failure, distinct from a broken guardrail.
mutate_sed() { # label file sed-args...
  local label="$1" file="$2" before after
  shift 2
  before="$(md5sum "$file" | cut -d' ' -f1)"
  sed -i "$@" "$file"
  after="$(md5sum "$file" | cut -d' ' -f1)"
  if test "$before" = "$after"; then
    fail "BROKEN PROBE ('$label'): the mutation edit left ${file##*/} unchanged. The probe's pattern no longer matches the source, so this case would exercise an UNMUTATED tree and prove nothing. Fix the probe before trusting the suite."
  fi
}

fresh_tree() {
  local t
  t="$(mktemp -d -t uruquim-wp3-mutation-XXXXXXXX)"
  mkdir -p "$t/build" "$t/web/testing" "$t/web/internal/transport" "$t/tests" "$t/vendor"
  # WP87: the checker now pins web/internal/ to exactly {transport, stream,
  # ingest}, so the fresh tree must carry the two sentinel packages too.
  mkdir -p "$t/web/internal/stream" "$t/web/internal/ingest"
  cp "$URUQUIM_ROOT"/build/check_public_api.sh "$t/build/"
  # The checker's 11f section reads its caller to prove every socket suite
  # runs under an external timeout, so the caller travels with it.
  cp "$URUQUIM_ROOT"/build/check.sh "$t/build/"
  cp "$URUQUIM_ROOT"/web/*.odin "$t/web/"
  cp "$URUQUIM_ROOT"/web/testing/*.odin "$t/web/testing/"
  cp "$URUQUIM_ROOT"/web/internal/transport/*.odin "$t/web/internal/transport/"
  cp "$URUQUIM_ROOT"/web/internal/stream/*.odin "$t/web/internal/stream/"
  cp "$URUQUIM_ROOT"/web/internal/ingest/*.odin "$t/web/internal/ingest/"
  cp -r "$URUQUIM_ROOT"/vendor/odin-http "$t/vendor/odin-http"
  cp -r "$URUQUIM_ROOT"/tests/. "$t/tests/"
  printf '%s' "$t"
}

TREES=()
cleanup() { for t in "${TREES[@]:-}"; do test -n "$t" && rm -rf "$t"; done; }
trap cleanup EXIT

# 1. An extra symbol in the APPLICATION ledger.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nextra_app_symbol :: proc() {}\n' >>"$T/web/serve.odin"
expect_reject "$T" "extra application-ledger symbol" \
  "exports symbols outside the ratified Phase-1 surface"

# 2. An extra symbol in the TEST-SUPPORT ledger.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nextra_ts_symbol :: proc() {}\n' >>"$T/web/test_support.odin"
expect_reject "$T" "extra test-support-ledger symbol" \
  "outside the 2-symbol test-support ledger"

# 3. A subdirectory outside the permitted set. `web/testing/` (WP3) and
#    `web/internal/` (WP8) are allowed; anything else is scope creep.
T="$(fresh_tree)"; TREES+=("$T")
mkdir -p "$T/web/middleware"
printf 'package middleware\n' >"$T/web/middleware/x.odin"
expect_reject "$T" "disallowed web/ subdirectory" \
  "unexpected subdirectory"

# 4. core:testing imported by the machinery.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nimport _ "core:testing"\n' >>"$T/web/testing/recorder.odin"
expect_reject "$T" "core:testing in machinery" \
  "web/testing/ imports core:testing"

# 5. The back-edge import (uruquim:web) inside the machinery.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nimport _ "uruquim:web"\n' >>"$T/web/testing/recorder.odin"
expect_reject "$T" "uruquim:web import in machinery" \
  "web/testing/ imports uruquim:web"

# 6. An @(init) proc in the machinery.
T="$(fresh_tree)"; TREES+=("$T")
printf '\n@(init)\nboot :: proc() {}\n' >>"$T/web/testing/recorder.odin"
expect_reject "$T" "@(init) in machinery" \
  "an @(init) proc appears in the test-support facade or machinery"

# 7. A bridge export beyond the locked set.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nextra_bridge :: proc() {}\n' >>"$T/web/testing/test_transport.odin"
expect_reject "$T" "extra web/testing bridge export" \
  "outside the locked bridge set"

# 8. A FOURTH field smuggled onto Recorded_Response.
#
# RE-AIMED BY WP49. This mutation used to ADD `headers`, because `headers` was
# the forbidden field. WP49 ratified it (D-14.3), so the mutation now adds a
# fourth field instead — the list is exact in both directions, and what this
# probe has always really tested is that the list is EXACT, not that one
# particular name was absent.
T="$(fresh_tree)"; TREES+=("$T")
python3 - "$T/web/test_support.odin" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
old = "\theaders: []string,\n}"
assert old in s, "BROKEN PROBE: the Recorded_Response field block was not found; the probe no longer matches the source"
s = s.replace(old, "\theaders: []string,\n\tcommitted: bool,\n}", 1)
open(p, "w").write(s)
PY
expect_reject "$T" "a fourth field on Recorded_Response" \
  "must expose exactly status, body and headers"

echo "PASS: WP3 mutation checks (8 forbidden states all rejected)"

# ---------------------------------------------------------------------------
# WP4 mutation checks — the section-9 dispatch guardrails must REJECT the states
# they claim to forbid, for the same reason as every case above: a guardrail
# that passes on a bad tree is worse than no guardrail.
# ---------------------------------------------------------------------------

# 9. A BRAND-NEW exported symbol in the WP4 dispatch files. The frozen 32-symbol
#    ledger catches this first, which is the stronger message of the two.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nexported_dispatch_helper :: proc() {}\n' >>"$T/web/dispatch_match.odin"
expect_reject "$T" "new exported symbol in the WP4 dispatch files" \
  "exports symbols outside the ratified Phase-1 surface"

# 9b. A RATIFIED symbol exported from a dispatch file. The ledger cannot see
#     this — the name is still expected and the count is still 32 — so it is
#     exactly the case section 9a exists for: the interim dispatcher must stay
#     entirely internal, and it must not become a second home for public API.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nserve :: proc(a: ^App, port: int) {}\n' >>"$T/web/dispatch_match.odin"
expect_reject "$T" "ratified symbol exported from a dispatch file" \
  "the WP4 dispatch files export a symbol"

# 10. `dispatch` losing its explicit App parameter (D3). The probe is
#     parameter-NAME agnostic, matching the checker: renaming dispatch's
#     private parameters is legal, dropping the ^App argument is not.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "dispatch without the explicit App parameter" "$T/web/dispatch_match.odin" \
  -E 's/^dispatch :: proc\([a-z_]+: \^App, ([a-z_]+: \^Context)\) \{$/dispatch :: proc(\1) {/'
expect_reject "$T" "dispatch without the explicit App parameter" \
  "dispatch does not take (^App, ^Context) explicitly"

# 11. A non-canonical `Allow` header name.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "lowercase Allow header name" "$T/web/dispatch_table.odin" \
  's/^ALLOW_HEADER_NAME :: "Allow"$/ALLOW_HEADER_NAME :: "allow"/'
expect_reject "$T" "lowercase Allow header name" \
  "the 405 header name is not exactly"

# 12. A scrambled `Allow` method order — the value must not depend on it.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "non-canonical Allow method order" "$T/web/dispatch_table.odin" \
  's/^ALLOW_METHOD_ORDER :: .*$/ALLOW_METHOD_ORDER :: [5]Method{.DELETE, .PATCH, .PUT, .POST, .GET}/'
expect_reject "$T" "non-canonical Allow method order" \
  "the Allow method order is not the canonical"

# 13. A later-phase routing construct entering the interim dispatcher (R-12).
T="$(fresh_tree)"; TREES+=("$T")
printf '\n@(private)\nradix_node_lookup :: proc() {}\n' >>"$T/web/dispatch_match.odin"
expect_reject "$T" "radix construct in the interim dispatcher" \
  "later-phase routing construct"

# 14. The dispatcher deciding a status outside 404/405.
T="$(fresh_tree)"; TREES+=("$T")
printf '\n@(private)\nwp4_extra_status :: proc(res: ^Response) {\n\tresponse_commit(res, .Internal_Server_Error, nil, nil)\n}\n' \
  >>"$T/web/dispatch_match.odin"
expect_reject "$T" "dispatcher deciding a status outside 404/405" \
  "decides a status outside 404/405"

# 15. A missing WP4 dispatch file. With the file set derived rather than
#     enumerated (WP16), the rejection comes from the section-9 structural
#     check that names the missing contract, not from a filename diff.
T="$(fresh_tree)"; TREES+=("$T")
test -f "$T/web/dispatch_match.odin" ||
  fail "BROKEN PROBE ('missing WP4 dispatch file'): the copied tree has no dispatch_match.odin to remove"
rm -f "$T/web/dispatch_match.odin"
expect_reject "$T" "missing WP4 dispatch file" \
  "web/dispatch_match.odin is missing"

echo "PASS: WP4 mutation checks (8 forbidden dispatch states all rejected)"

# ---------------------------------------------------------------------------
# WP5 mutation checks — the section-10 extractor guardrails must REJECT the
# states they claim to forbid.
#
# The `#optional_ok` case is the one that matters most. Section 10b is a
# NEGATIVE grep, and a negative grep passes just as happily when the pattern is
# wrong, when the file it reads is empty, or when the variable it scans was
# renamed out from under it. Without the mutation below, "the checker rejects
# #optional_ok" would be an untested claim about a guardrail whose entire job is
# to catch a one-word regression (ADR-002, R-07).
# ---------------------------------------------------------------------------

# 16. `#optional_ok` re-added to a value-producing extractor.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "#optional_ok on path_int" "$T/web/extract.odin" \
  's/^path_int :: proc(ctx: \^Context, name: string) -> (value: int, ok: bool) {$/path_int :: proc(ctx: ^Context, name: string) -> (value: int, ok: bool) #optional_ok {/'
grep -q '#optional_ok' "$T/web/extract.odin" ||
  fail "MUTATION-SETUP: #optional_ok was not injected into the copied extract.odin"
expect_reject "$T" "#optional_ok re-added to path_int" \
  "#optional_ok appears in web/"

# 16b. The same directive on `query_int_or` — the extractor most likely to be
#      mistaken for a total function and "simplified" with the directive.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "#optional_ok on query_int_or" "$T/web/extract.odin" \
  's/^query_int_or :: proc(ctx: \^Context, name: string, default_value: int) -> (value: int, ok: bool) {$/query_int_or :: proc(ctx: ^Context, name: string, default_value: int) -> (value: int, ok: bool) #optional_ok {/'
grep -q '#optional_ok' "$T/web/extract.odin" ||
  fail "MUTATION-SETUP: #optional_ok was not injected into query_int_or"
expect_reject "$T" "#optional_ok re-added to query_int_or" \
  "#optional_ok appears in web/"

# 17. A changed extractor signature. The 32-symbol ledger cannot see this: the
#     name is still present and the count is still 32, but the public contract
#     changed.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "altered query_int_or signature" "$T/web/extract.odin" \
  's/^query_int_or :: proc(ctx: \^Context, name: string, default_value: int) -> (value: int, ok: bool) {$/query_int_or :: proc(ctx: ^Context, name: string, default_value: i64) -> (value: i64, ok: bool) {/'
expect_reject "$T" "altered query_int_or signature" \
  "the ratified web.query_int_or signature is not exactly"

# 18. (RETIRED IN WP6.) This case asserted that `web.bad_request` was still an
#     empty stub. WP6 implemented it, so the mutation now describes the
#     delivered feature rather than a forbidden state. The WP6 cases at the end
#     of this file replace it.

# 20-21. (RETIRED IN WP7.) These asserted that a body cap and a working
#     `web.body` did not exist yet. WP7 delivered both, so the mutations now
#     describe the shipped feature rather than a forbidden state. The WP7 cases
#     at the end of this file replace them with the positive contract.

# 22. A misspelled error code. Clients match on `code`, so a typo is a silent
#     compatibility break rather than a visible failure.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "misspelled invalid_query_parameter" "$T/web/errors.odin" \
  's/invalid_query_parameter/invalid_query_param/g'
expect_reject "$T" "misspelled invalid_query_parameter code" \
  "the ratified error code 'invalid_query_parameter' is missing"

echo "PASS: WP5 mutation checks (8 forbidden extractor states all rejected)"

# ---------------------------------------------------------------------------
# WP6 mutation checks — the section-10c response/envelope guardrails must REJECT
# the states they claim to forbid.
#
# Several of these guardrails are NEGATIVE greps, and a negative grep passes
# just as happily when its pattern is wrong, when the variable it scans was
# renamed, or when the file it reads moved. These cases are what make the
# rejection a fact.
# ---------------------------------------------------------------------------

# 23. The JSON encoder reaching the interim dispatcher. WP6 D5 keeps the
#     automatic 404/405 bodies static precisely so that `dispatch` — reachable
#     from every application that calls web.app() — neither allocates nor links
#     the marshaller.
T="$(fresh_tree)"; TREES+=("$T")
printf '\n@(private)\nwp6_bad_render :: proc(ctx: ^Context) {\n\tdata, _ := encoding_json.marshal(1, {}, context.allocator)\n\t_ = data\n}\n' \
  >>"$T/web/dispatch_match.odin"
expect_reject "$T" "encoder used by the interim dispatcher" \
  "the WP4 dispatcher marshals a response"

# 24. The encoder imported by a file that must stay encoder-free. `extract.odin`
#     legitimately imports it since WP7 (body decoding), so the mutation targets
#     the dispatcher, which must never marshal.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nimport _ "core:encoding/json"\n' >>"$T/web/dispatch_match.odin"
expect_reject "$T" "encoder imported into the dispatcher" \
  "a WP4 dispatch file imports the JSON encoder"

# 25. Response teardown exported. Response lifetime is framework business; an
#     application must never be handed a cleanup call (ADR-014 D1).
T="$(fresh_tree)"; TREES+=("$T")
python3 - "$T/web/response.odin" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = "@(private)\nresponse_destroy :: proc(res: ^Response) {"
assert old in s, "MUTATION-SETUP: response_destroy declaration not found"
open(p, "w").write(s.replace(old, "response_destroy :: proc(res: ^Response) {", 1))
PY2
expect_reject "$T" "response_destroy exported" \
  "exports symbols outside the ratified Phase-1 surface"

# 26. `field` smuggled into the general envelope. AMEND-2 says it is OMITTED,
#     and the omission must be a property of the TYPE.
T="$(fresh_tree)"; TREES+=("$T")
python3 - "$T/web/errors.odin" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = """Error_Envelope_Body :: struct {
	code:    string `json:"code"`,
	message: string `json:"message"`,
}"""
assert old in s, "MUTATION-SETUP: Error_Envelope_Body not found"
new = """Error_Envelope_Body :: struct {
	code:    string `json:"code"`,
	message: string `json:"message"`,
	field:   string `json:"field"`,
}"""
open(p, "w").write(s.replace(old, new, 1))
PY2
expect_reject "$T" "field added to the general envelope" \
  "must carry exactly code and message"

# 27. `omitempty` used to omit `field`. It decides on EMPTINESS, so it would also
#     drop a field legitimately named "" — a different contract from AMEND-2.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "omitempty in the envelope" "$T/web/errors.odin" \
  's|`json:"message"`|`json:"message,omitempty"`|'
expect_reject "$T" "omitempty in the envelope" \
  "omitempty is used in web/"

# 28. A wrong Content-Type. Clients dispatch on it, so a silent change here is a
#     compatibility break rather than a visible failure.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "non-canonical JSON Content-Type" "$T/web/response.odin" \
  's|^CONTENT_TYPE_JSON :: "application/json"$|CONTENT_TYPE_JSON :: "text/json"|'
expect_reject "$T" "non-canonical JSON Content-Type" \
  "the JSON Content-Type is not exactly"

# 29. The text Content-Type losing its charset.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "text Content-Type without charset" "$T/web/response.odin" \
  's|^CONTENT_TYPE_TEXT :: "text/plain; charset=utf-8"$|CONTENT_TYPE_TEXT :: "text/plain"|'
expect_reject "$T" "text Content-Type without charset" \
  "the text Content-Type is not exactly"

# 30. Pointer-payload support adopted without a ratified amendment (R-13).
T="$(fresh_tree)"; TREES+=("$T")
printf '\n@(private)\nwp6_deref_payload :: proc() {}\n' >>"$T/web/respond.odin"
expect_reject "$T" "pointer dereference support introduced" \
  "pointer-payload dereference"

# 31. The response ownership machinery removed. `response_commit_owned` is what
#     makes ADR-014 true; losing it must not pass quietly.
T="$(fresh_tree)"; TREES+=("$T")
python3 - "$T/web/response.odin" <<'PY2'
import sys
p = sys.argv[1]
s = open(p).read()
old = "response_commit_owned :: proc("
assert old in s, "MUTATION-SETUP: response_commit_owned not found"
open(p, "w").write(s.replace(old, "response_commit_owned_renamed :: proc(", 1))
PY2
expect_reject "$T" "response_commit_owned removed" \
  "internal WP6 declaration 'response_commit_owned' is missing"

echo "PASS: WP6 mutation checks (9 forbidden response states all rejected)"

# ---------------------------------------------------------------------------
# WP7 mutation checks — the section-10d body-binding guardrails must REJECT the
# states they claim to forbid. Several are structural greps over the source of
# `body`; a grep that passes on a bad tree is worse than no grep, so each is
# exercised against a tree that actually contains the defect.
# ---------------------------------------------------------------------------

# 32. The body cap removed entirely. AMENDED BY WP36: the guard compares against
#     the request's RESOLVED budget now, not the fixed constant.
T="$(fresh_tree)"; TREES+=("$T")
python3 - "$T/web/extract.odin" <<'PY2'
import sys, re
p = sys.argv[1]; s = open(p).read()
# Drop the whole "if len(raw) > BODY_LIMIT { ... }" block.
s = re.sub(r"\tcap := ctx\.private\.limits\.max_body\n(?:.*\n)*?\tif len\(raw\) > cap \{\n(?:.*\n)*?\t\}\n", "", s, count=1)
open(p, "w").write(s)
PY2
expect_reject "$T" "body cap removed" \
  "does not read the request's resolved max_body"

# 33. `>` weakened to `>=`, which would reject a body of exactly the limit.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "cap comparison weakened to >=" "$T/web/extract.odin" \
  's/len(raw) > cap/len(raw) >= cap/'
expect_reject "$T" "cap comparison weakened to >=" \
  "a body of exactly the limit would be rejected"

# 34. Parsing before the limit check — swap the two so unmarshal precedes the cap.
T="$(fresh_tree)"; TREES+=("$T")
python3 - "$T/web/extract.odin" <<'PY2'
import sys
p = sys.argv[1]; s = open(p).read()
# Move the limit guard to AFTER the unmarshal by deleting it and re-inserting a
# copy below the unmarshal line. Simplest: relocate the guard past the parse.
guard_start = s.index("\tcap := ctx.private.limits.max_body")
# WP36: the guard is now two blocks -- the zero-budget fallback and the
# comparison -- so the end is the brace closing the SECOND one, not the first.
compare_at = s.index("\tif len(raw) > cap {", guard_start)
guard_end = s.index("\t}\n", compare_at) + len("\t}\n")
guard = s[guard_start:guard_end]
s = s[:guard_start] + s[guard_end:]
anchor = "\terr := encoding_json.unmarshal("
i = s.index(anchor)
# Insert the guard right after the unmarshal statement's line.
line_end = s.index("\n", i) + 1
s = s[:line_end] + guard + s[line_end:]
open(p, "w").write(s)
PY2
expect_reject "$T" "parse before the cap" \
  "parses before checking the body cap"

# 35. Decoding with context.allocator instead of the request arena.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "unmarshal into context.allocator" "$T/web/extract.odin" \
  's/request_arena_allocator(ctx)/context.allocator/'
expect_reject "$T" "unmarshal into context.allocator" \
  "unmarshals with context.allocator"

# 35b. The fused decoder must obey the same arena ownership rule as the stdlib
#      fallback; proving only one branch would leave the default fast path
#      outside ADR-006.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "fused decode into context.allocator" "$T/web/json_decode.odin" \
  's/request_arena_allocator(ctx)/context.allocator/'
expect_reject "$T" "fused decode into context.allocator" \
  "fused decoder uses context.allocator"

# 36. Dropping strict .JSON mode (defaulting to JSON5).
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "strict JSON mode dropped" "$T/web/extract.odin" \
  's/unmarshal(raw, dst, .JSON, /unmarshal(raw, dst, /'
expect_reject "$T" "strict JSON mode dropped" \
  "does not unmarshal in strict .JSON mode"

# 37. The teardown removed from a driver. AMENDED IN WP9: both drivers now tear
#     down through the shared `driver_cleanup`, so the mutation removes THAT
#     call rather than the arena call it contains.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "teardown removed from the in-memory driver" "$T/web/test_support.odin" \
  '/driver_cleanup(&ctx)/d'
expect_reject "$T" "teardown removed from the in-memory driver" \
  "does not call driver_cleanup"

# 37b. The arena release removed from inside the shared cleanup.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "arena release removed" "$T/web/serve.odin" \
  '/request_arena_destroy(ctx)/d'
expect_reject "$T" "arena release removed from driver_cleanup" \
  "driver_cleanup does not release the request arena"

# 38. The body capability consumed AFTER the parse (allowing a second decode).
T="$(fresh_tree)"; TREES+=("$T")
python3 - "$T/web/extract.odin" <<'PY2'
import sys
p = sys.argv[1]; s = open(p).read()
line = "\tctx.private.body_state = .Consumed\n"
assert line in s, "MUTATION-SETUP: consume line not found"
s = s.replace(line, "", 1)  # remove the early consume
# Re-insert it AFTER the unmarshal call's line.
anchor = "\terr := encoding_json.unmarshal("
i = s.index(anchor); line_end = s.index("\n", i) + 1
s = s[:line_end] + line + s[line_end:]
open(p, "w").write(s)
PY2
expect_reject "$T" "capability consumed after parse" \
  "consumes the capability after parsing"

# 39. RE-AIMED for corrective WP C1 (F8-1): 413 is now the PUBLIC
#     `Status.Payload_Too_Large` member. Removing it must be rejected — the public
#     code returns it by name, so the member is load-bearing.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "remove public 413 member" "$T/web/respond.odin" \
  '/^\tPayload_Too_Large     = 413,$/d'
expect_reject "$T" "removed public 413 member" \
  "the public Status.Payload_Too_Large = 413 member is missing"

# 40. A configurable body limit smuggled in.
T="$(fresh_tree)"; TREES+=("$T")
printf '\n@(private)\nset_body_limit :: proc(a: ^App, n: int) {}\n' >>"$T/web/app.odin"
expect_reject "$T" "configurable body limit" \
  "WP7 non-goal matching"

# 41. A new public symbol in the arena machinery.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nBody_Arena :: struct {}\n' >>"$T/web/request_arena.odin"
expect_reject "$T" "public symbol in the arena machinery" \
  "exports symbols outside the ratified Phase-1 surface"

echo "PASS: WP7 mutation checks (10 forbidden body-binding states all rejected)"

# ---------------------------------------------------------------------------
# WP8 mutation checks — the transport-boundary guardrails must REJECT the states
# they claim to forbid. The boundary is what keeps the backend replaceable, so a
# grep that passes on a bad tree would be worse than no grep.
# ---------------------------------------------------------------------------

# 42. The adapter importing `web` — the back-edge the one-way boundary forbids
#     (ADR-009 / WP8 D1).
T="$(fresh_tree)"; TREES+=("$T")
printf '\nimport _ "uruquim:web"\n' >>"$T/web/internal/transport/boundary.odin"
expect_reject "$T" "transport importing uruquim:web" \
  "web/internal/transport imports uruquim:web"

# 43. The backend imported OUTSIDE the adapter — here, straight into `web`.
#     Only web/internal/transport may name odin-http.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nimport _ "uruquim:vendor/odin-http"\n' >>"$T/web/serve.odin"
expect_reject "$T" "backend imported into web/" \
  "the vendored backend must be imported by exactly one file"

# 44. A backend type in an EXPORTED signature. G-06 already bans
#     transport-shaped names in exported declarations; this proves it fires.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nserve_raw :: proc(s: ^http.Server) {}\n' >>"$T/web/serve.odin"
expect_reject "$T" "backend type in an exported signature" \
  "exports symbols outside the ratified Phase-1 surface"

# 45. A new public transport symbol (serve_with / serve_transport / stop).
T="$(fresh_tree)"; TREES+=("$T")
printf '\nserve_with :: proc(a: ^App, port: int) {}\n' >>"$T/web/serve.odin"
expect_reject "$T" "serve_with added to the public surface" \
  "exports symbols outside the ratified Phase-1 surface"

# 46. RE-AIMED for corrective WP C1 (F8-1): the body-too-large path must use the
#     NAMED public member, not a private `Status(413)` cast. Reintroducing the
#     private cast must be rejected — the inverse of the old WP7 D3 control.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "private Status(413) cast reintroduced" "$T/web/errors.odin" \
  's/^\t\t\.Payload_Too_Large,$/\t\tStatus(413),/'
expect_reject "$T" "private Status(413) cast in the body-too-large path" \
  "the body-too-large path still casts a private Status(413)"

# 47. An unexpected subdirectory under web/internal/.
T="$(fresh_tree)"; TREES+=("$T")
mkdir -p "$T/web/internal/memory"
printf 'package memory\n' >"$T/web/internal/memory/x.odin"
expect_reject "$T" "extra web/internal subdirectory" \
  "web/internal/ has an unexpected subdirectory"

# 48. rawptr surfacing in an EXPORTED declaration (the G-03 narrowing must still
#     bite on the public side).
T="$(fresh_tree)"; TREES+=("$T")
printf '\nHandler_Raw :: proc(user: rawptr)\n' >>"$T/web/context.odin"
expect_reject "$T" "rawptr in an exported declaration" \
  "exports symbols outside the ratified Phase-1 surface"

echo "PASS: WP8 mutation checks (7 forbidden transport states all rejected)"

# ---------------------------------------------------------------------------
# WP9 mutation checks — the conformance guardrails must REJECT the states they
# claim to forbid. Several are structural greps over the harness and the
# adapter; a grep that passes on a bad tree would be worse than no grep.
# ---------------------------------------------------------------------------

# 49. `core:testing` inside the SHIPPED package. The whole reason the harness
#     lives under tests/ (WP9 D1) is that web/testing/ ships in every binary.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nimport _ "core:testing"\n' >>"$T/web/testing/recorder.odin"
expect_reject "$T" "core:testing in the shipped test-support machinery" \
  "web/testing/ imports core:testing"

# 50. Networking added to web/testing/. The in-memory transport must never grow
#     a socket; that is what keeps the contract suite honest about being
#     socket-free.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nimport _ "core:net"\n' >>"$T/web/testing/recorder.odin"
expect_reject "$T" "networking added to web/testing" \
  "test transport must be in-memory"

# 51. The transport importing web — the one-way boundary again, now that WP9
#     added a second importer of the transport package.
T="$(fresh_tree)"; TREES+=("$T")
printf '\nimport _ "uruquim:web"\n' >>"$T/web/internal/transport/boundary.odin"
expect_reject "$T" "transport importing uruquim:web (WP9)" \
  "web/internal/transport imports uruquim:web"

# 52. HEAD->GET re-enabled. The backend must not rewrite a method before the
#     core decides (WP9 D7). The adapter is addressed the way the checker
#     addresses it — as the one file importing the backend — so renaming it
#     breaks neither the guardrail nor this probe.
T="$(fresh_tree)"; TREES+=("$T")
T_ADAPTER="$(grep -rlE '"uruquim:vendor/odin-http"' "$T/web/internal/transport" | head -1)"
test -n "$T_ADAPTER" || fail "BROKEN PROBE ('HEAD->GET re-enabled'): no adapter found in the copied tree"
mutate_sed "HEAD->GET re-enabled" "$T_ADAPTER" \
  's/opts.redirect_head_to_get = false/opts.redirect_head_to_get = true/'
expect_reject "$T" "HEAD->GET re-enabled" \
  "redirect_head_to_get must stay false"

# 53. The backend's automatic 100-continue re-enabled, which would make the
#     server answer "continue" and then wait for a body (WP9 D5).
T="$(fresh_tree)"; TREES+=("$T")
T_ADAPTER="$(grep -rlE '"uruquim:vendor/odin-http"' "$T/web/internal/transport" | head -1)"
test -n "$T_ADAPTER" || fail "BROKEN PROBE ('automatic 100-continue re-enabled'): no adapter found in the copied tree"
mutate_sed "automatic 100-continue re-enabled" "$T_ADAPTER" \
  's/opts.auto_expect_continue = false/opts.auto_expect_continue = true/'
expect_reject "$T" "automatic 100-continue re-enabled" \
  "auto_expect_continue must stay false"

# 54-55. (RETIRED IN WP16.) These asserted the vendor patches by grepping the
#     vendor sources for their exact code shape — the same over-specification
#     audit A-10 flagged: a correct re-application spelled differently failed,
#     while an unrelated matching line elsewhere passed. The patches are now
#     held by EXECUTABLE evidence: reverting one fails the raw-wire corpus run
#     in build/check.sh (two of the reversions crash the server, which is what
#     the corpus observes), and deleting the corpus case that observes it is
#     rejected statically — case 56 below proves that rejection fires.

# 56. A vendor-patch corpus case deleted from the wire corpus. The static half
#     of the WP16 vendor-patch evidence: the corpus must keep carrying a named
#     case per patch, or a reversion would go unobserved.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "vendor-patch corpus case deleted" \
  "$T/tests/support/transport_conformance/corpus.odin" \
  '/name = "CL+TE is rejected (smuggling vector)",/d'
expect_reject "$T" "vendor-patch corpus case deleted" \
  "the raw-wire corpus no longer carries the case"

echo "PASS: WP9 mutation checks (6 forbidden conformance states all rejected; the two vendor code-shape cases are retired to the executable corpus)"

# ---------------------------------------------------------------------------
# WP16 mutation checks — the DERIVED contracts must still reject what the old
# enumerated ones rejected, and legal refactors must now be ACCEPTED. Both
# directions are contract: a gate that fails honest refactors gets bypassed,
# and a gate that stops rejecting strays has quietly died.
# ---------------------------------------------------------------------------

# 57. A stray file that declares no ledger. This is what replaces the old
#     filename list: legitimacy travels with the file, and a file that does
#     not declare itself does not ship.
T="$(fresh_tree)"; TREES+=("$T")
printf 'package web\n\n@(private)\noops :: proc() {}\n' >"$T/web/oops.odin"
expect_reject "$T" "stray web/oops.odin with no ledger marker" \
  "declares no ledger"

# 57b. A stray file in the machinery, equally unclassified.
T="$(fresh_tree)"; TREES+=("$T")
printf 'package web_testing\n\n@(private)\noops :: proc() {}\n' >"$T/web/testing/oops.odin"
expect_reject "$T" "stray web/testing/oops.odin with no machinery marker" \
  "markers; exactly one is required"

# 57c. A file carrying BOTH ledger markers — the two counts must never overlap.
T="$(fresh_tree)"; TREES+=("$T")
printf '// uruquim:file test-support\n' >>"$T/web/serve.odin"
expect_reject "$T" "web/serve.odin marked with both ledgers" \
  "ledger markers; exactly one is required"

# 58. REFACTOR CONTROL: renaming response_commit's private parameters. This is
#     the WP16 point — the commit primitive's SHAPE is contract, its private
#     parameter names are not.
T="$(fresh_tree)"; TREES+=("$T")
#     (This suite is static text analysis, so only the declaration line needs
#     the rename for the control to mean what it claims.)
mutate_sed "private parameter rename in response_commit" "$T/web/response.odin" \
  -E 's/^response_commit :: proc\(res: \^Response, status: Status, headers: \[\]Header_Pair, body: \[\]u8\) -> bool \{$/response_commit :: proc(target: ^Response, code: Status, header_pairs: []Header_Pair, payload: []u8) -> bool {/'
expect_accept "$T" "private parameter rename in response_commit"

# 58b. REFACTOR CONTROL: renaming dispatch's private parameters.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "private parameter rename in dispatch" "$T/web/dispatch_match.odin" \
  -E 's/^dispatch :: proc\(a: \^App, ctx: \^Context\) \{$/dispatch :: proc(the_app: ^App, request_ctx: ^Context) {/'
expect_accept "$T" "private parameter rename in dispatch"

# 59. REFACTOR CONTROL: a vendor patch re-applied in a different but equivalent
#     spelling. The evidence for the patch is the wire corpus, not the byte
#     shape of the fix, so `if len(token) != 0 {` rewritten as
#     `if len(token) > 0 {` must pass the static gate.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "vendor patch respelled equivalently" "$T/vendor/odin-http/body.odin" \
  's/if len(token) != 0 {/if len(token) > 0 {/'
expect_accept "$T" "vendor patch respelled equivalently"

# 60. REFACTOR CONTROL: a marked application file split out of an existing one.
#     The derived file set accepts a new file that declares its ledger; the
#     ledger diffs still bound what it may export.
T="$(fresh_tree)"; TREES+=("$T")
printf 'package web\n// uruquim:file application\n\n@(private)\nwp16_split_helper :: proc() {}\n' \
  >"$T/web/errors_split.odin"
expect_accept "$T" "new marked application file (a split), exporting nothing"

# 61. A ratified symbol deleted from the package. The ledger is exact in BOTH
#     directions: losing a frozen symbol is as much a break as gaining one.
T="$(fresh_tree)"; TREES+=("$T")
mutate_sed "ratified symbol deleted from the package" "$T/web/errors.odin" \
  '/^unauthorized :: proc/d'
expect_reject "$T" "ratified symbol deleted from the package" \
  "web/ is missing part of the ratified Phase-1 surface"

echo "PASS: WP16 mutation checks (5 stray/overlap/deletion states rejected, 4 refactor controls accepted)"
