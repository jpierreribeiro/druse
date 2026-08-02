#!/usr/bin/env bash
# R1-WP04 — one normative support profile, derived facts and semantic mutants.
set -euo pipefail

VERIFY_ONLY=0
if test "${1:-}" = --verify-only; then
  VERIFY_ONLY=1
  shift
fi

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PROFILE="$ROOT/docs/supported-profile.md"

fail() {
  echo "SUPPORTED-PROFILE-FAIL: $*" >&2
  exit 1
}
command -v rg >/dev/null 2>&1 || fail "rg is required for stale-claim detection"

need() {
  local text=$1 reason=$2
  grep -Fq "$text" <<<"$PROFILE_FLAT" || fail "$reason"
}

test -s "$PROFILE" || fail "docs/supported-profile.md is missing"
test -s "$ROOT/odin-version.txt" || fail "the pinned Odin toolchain record is missing"
PROFILE_FLAT="$(tr '\n' ' ' < "$PROFILE" | tr -s ' ')"

# The profile owns the operational claim. These exact phrases are deliberate:
# each is independently mutated below, so a neighbouring true statement cannot
# accidentally keep a removed capability green.
need '**Status: NORMATIVE — R1 controlled-pilot profile.**' "normative status missing"
need '**Linux x86-64 only.**' "platform claim is not Linux x86-64 only"
need 'exact Odin revision in `odin-version.txt`' "pinned toolchain policy missing"
need 'Druse serves **HTTP/1.1**' "native HTTP/1.1 boundary missing"
need 'does not terminate TLS' "TLS delegation missing"
need 'does not provide a native HTTP/2 server' "native HTTP/2 exclusion missing"
need 'reviewed reverse proxy' "mandatory proxy boundary missing"
need 'Handlers are synchronous' "synchronous Handler model missing"
need 'closes newly accepted sockets without writing an HTTP response' "saturation behavior missing"
need '`web.stop(&app)` publishes draining' "shutdown capability missing"
need 'cannot unwind a blocked Handler' "cooperative shutdown limitation missing"
need '`TimeoutStopSec=30`' "supervisor outer deadline missing"
need '`max_response_bytes` caps one committed response body' "response cap semantics missing"
need 'does not prevent OOM' "response cap is being presented as an OOM guarantee"
need '`druse-crystals` contains first-party optional Odin packages' "Druse Crystals context missing"
need 'not part of the R1 proof or support claim' "Druse Crystals was pulled into the R1 claim"

# Source-derived multi-server ceiling and the deliberately narrower R1 profile.
SERVER_CAP="$(awk '/SERVER_TABLE_CAP[[:space:]]*::/ {print $3; exit}' "$ROOT/web/internal/transport/server_registry.odin")"
test "$SERVER_CAP" = 16 || fail "server registry ceiling changed from the reviewed 16 (got ${SERVER_CAP:-missing})"
need "up to $SERVER_CAP concurrent servers per process" "multi-server ceiling missing"
need 'uses one listener and one App per process' "R1 one-server recommendation missing"
grep -Fq 'DRUSE_SERVER_COUNT=1' "$ROOT/ops/deploy/runtime-limits.example" ||
  fail "runtime profile no longer implements the one-server R1 recommendation"

# Runtime values repeated in the table are checked against the canonical file.
for pair in \
  'DRUSE_MAX_CONNECTIONS=1024|1,024' \
  'DRUSE_RESERVED_CONNECTIONS=16|16' \
  'DRUSE_MAX_DRAIN_TIME_SEC=10|10 s' \
  'DRUSE_MAX_RESPONSE_BYTES=8388608|8 MiB' \
  'DRUSE_TIMEOUT_STOP_SEC=30|TimeoutStopSec=30' \
  'DRUSE_MEMORY_MAX_BYTES=1073741824|MemoryMax=1G'; do
  source_value=${pair%%|*}
  profile_value=${pair#*|}
  grep -Fq "$source_value" "$ROOT/ops/deploy/runtime-limits.example" ||
    fail "canonical runtime value missing: $source_value"
  grep -Fq "$profile_value" "$PROFILE" ||
    fail "supported profile drifted from runtime value: $source_value"
done

need '`max_body` | 4 MiB' "default max_body missing"
need '`max_request_line` | 8,000 bytes' "default request-line limit missing"
need '`max_headers` | 8,000 bytes' "default header limit missing"
need '`max_request_time` | 30 s' "default request deadline missing"
need '`max_json_nodes` | 100,000' "default JSON structure limit missing"
need '`max_write_time=0`, `max_idle_time=0` and' "default-off limit set missing"
need '`max_response_bytes=0`' "default-off response cap missing"
need 'opt-in through' "upload opt-in policy missing"
need '`web.upload`/`web.upload_persist` API exists' "public upload capability missing"

# The vendor count is derived from the canonical disposition table. No literal
# in this checker changes when the ledger grows.
POLICY="$ROOT/planning/vendor-policy.md"
POLICY_NUMS="$(grep -oE '^\| [0-9]+ \| .* \| .* \| \*\*(OFFER UPSTREAM|CARRY|APPEARS FIXED UPSTREAM)' "$POLICY" |
  awk -F'|' '{gsub(/ /, "", $2); print $2}' | sort -n)"
POLICY_ROWS="$(printf '%s\n' "$POLICY_NUMS" | grep -c . || true)"
test "$POLICY_ROWS" -gt 0 || fail "canonical vendor disposition ledger is empty"
diff <(printf '%s\n' "$POLICY_NUMS") <(seq 1 "$POLICY_ROWS") >/dev/null ||
  fail "canonical vendor disposition ledger is not contiguous 1..$POLICY_ROWS"
need "**$POLICY_ROWS dispositions**" "vendor disposition count drifted from the canonical ledger"
POLICY_FLAT="$(tr '\n' ' ' < "$POLICY" | tr -s ' ')"
VENDOR_FLAT="$(tr '\n' ' ' < "$ROOT/vendor/odin-http/VENDOR.md" | tr -s ' ')"
grep -Fq "**$POLICY_ROWS dispositions**" <<<"$POLICY_FLAT" ||
  fail "vendor policy summary drifted from its own derived row count"
grep -Fq "currently records $POLICY_ROWS" <<<"$VENDOR_FLAT" ||
  fail "vendor provenance document does not delegate the current ledger count"

# Every document named by WP04 either points at the profile or delegates its
# narrower vendor concern to the canonical ledger.
POINTER_DOCS=(
  README.md SECURITY.md docs/ai-context.md docs/canonical-patterns.md
  docs/operations.md docs/platform-contract.md docs/standards-registry.md
  planning/release-readiness.md planning/wp123-per-server-state-spec.md
)
for doc in "${POINTER_DOCS[@]}"; do
  grep -Fq 'docs/supported-profile.md' "$ROOT/$doc" ||
    fail "$doc does not point at the normative supported profile"
done
grep -Fq '../../planning/vendor-policy.md' "$ROOT/vendor/odin-http/VENDOR.md" ||
  fail "VENDOR.md still presents a parallel live patch ledger"

# These were the concrete contradictions WP04 found. Keep the patterns narrow
# enough that historical analysis may discuss the old claim without asserting it.
STALE_DOCS=(
  README.md SECURITY.md docs/ai-context.md docs/canonical-patterns.md
  docs/operations.md docs/platform-contract.md docs/standards-registry.md
  planning/release-readiness.md planning/wp123-per-server-state-spec.md
)
if rg -n -i \
    'only one server per process is supported|One server per process remains|no public upload API yet|Still ahead: graceful shutdown|graceful shutdown (does not exist|não existe)' \
    "${STALE_DOCS[@]/#/$ROOT/}"; then
  fail "a reconciled document reintroduced a known false capability claim"
fi

echo "supported profile: Linux x86-64, HTTP/1.1 behind proxy, server ceiling $SERVER_CAP, R1 server count 1, vendor dispositions $POLICY_ROWS"

test "$VERIFY_ONLY" -eq 0 || exit 0

# Semantic mutation controls. The verifier runs against a minimal copied tree,
# and every mutant must fail for its own missing/false claim.
TMP="$(mktemp -d -t druse-supported-profile-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/docs" "$TMP/planning" "$TMP/vendor/odin-http" \
  "$TMP/web/internal/transport" "$TMP/ops/deploy"
cp "$ROOT/odin-version.txt" "$TMP/"
cp "$ROOT/docs/supported-profile.md" "$TMP/docs/"
for doc in ai-context.md canonical-patterns.md operations.md platform-contract.md standards-registry.md; do
  cp "$ROOT/docs/$doc" "$TMP/docs/$doc"
done
cp "$ROOT/README.md" "$ROOT/SECURITY.md" "$TMP/"
cp "$ROOT/planning/release-readiness.md" "$ROOT/planning/wp123-per-server-state-spec.md" \
  "$ROOT/planning/vendor-policy.md" "$TMP/planning/"
cp "$ROOT/vendor/odin-http/VENDOR.md" "$TMP/vendor/odin-http/"
cp "$ROOT/web/internal/transport/server_registry.odin" "$TMP/web/internal/transport/"
cp "$ROOT/ops/deploy/runtime-limits.example" "$TMP/ops/deploy/"
ORIGINAL="$TMP/docs/supported-profile.original"
cp "$TMP/docs/supported-profile.md" "$ORIGINAL"

mutant() {
  local name=$1 expected=$2 expression=$3
  cp "$ORIGINAL" "$TMP/docs/supported-profile.md"
  sed -i "$expression" "$TMP/docs/supported-profile.md"
  if bash "$ROOT/build/check_supported_profile.sh" --verify-only "$TMP" >"$TMP/$name.log" 2>&1; then
    fail "$name mutant was accepted"
  fi
  grep -Fq "$expected" "$TMP/$name.log" || {
    cat "$TMP/$name.log" >&2
    fail "$name mutant failed for the wrong reason (expected: $expected)"
  }
  echo "supported-profile control: $name rejected for the expected reason"
}

mutant shutdown 'shutdown capability missing' \
  's/`web.stop(&app)` publishes draining/Graceful shutdown does not exist; the old stop hook once published draining/'
mutant upload 'public upload capability missing' \
  's/`web.upload`\/`web.upload_persist` API exists/no public upload API yet/'
mutant single-server 'multi-server ceiling missing' \
  's/up to 16 concurrent servers per process/only one server per process is supported/'
mutant missing-ceiling 'multi-server ceiling missing' \
  's/up to 16 concurrent servers per process/up to an implementation-defined number of concurrent servers per process/'
mutant oom-guarantee 'response cap is being presented as an OOM guarantee' \
  's/does not prevent OOM/prevents OOM/'
mutant vendor-count 'vendor disposition count drifted' \
  's/\*\*43 dispositions\*\*/\*\*42 dispositions\*\*/'
mutant native-http2 'native HTTP/2 exclusion missing' \
  's/does not provide a native HTTP\/2 server/provides a native HTTP\/2 server/'
mutant native-tls 'TLS delegation missing' \
  's/does not terminate TLS/terminates TLS natively/'
mutant non-linux 'platform claim is not Linux x86-64 only' \
  's/\*\*Linux x86-64 only\.\*\*/\*\*Linux, macOS and Windows\.\*\*/'

echo "PASS: R1-WP04 normative supported profile and semantic mutation controls"
