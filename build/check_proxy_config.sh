#!/usr/bin/env bash
# R1-WP03 static contract and mutation controls for the pinned Caddy topology.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL="$ROOT/ops/proxy/caddy/Caddyfile"
CONFIG="${DRUSE_PROXY_CONFIG:-$CANONICAL}"
IMAGE_ENV="$ROOT/ops/proxy/caddy/image.env"
PROXY_README="$ROOT/ops/proxy/caddy/README.md"

fail() {
  echo "R1-PROXY-CONFIG-FAIL: $*" >&2
  exit 1
}

require_literal() {
  local value="$1"
  local reason="$2"
  grep -Fq "$value" "$CONFIG" || fail "$reason"
}

test -r "$CONFIG" || fail "Caddyfile is missing: $CONFIG"
test -r "$IMAGE_ENV" || fail "pinned image.env is missing"
test -r "$PROXY_README" || fail "Caddy deployment contract is missing"
grep -Fq 'four stale attempts plus one fresh attempt' "$PROXY_README" ||
  fail "transparent stale-connection retry ceiling is no longer documented"
grep -Fq 'GET`, `HEAD`, `OPTIONS`, `TRACE`' "$PROXY_README" ||
  fail "transparent retryable methods are no longer documented"
grep -Fq 'different proxy product' "$PROXY_README" ||
  fail "evidence scope no longer says another proxy needs another campaign"
if find "$ROOT/ops/proxy" -type f \( -name '*.key' -o -name '*-key.pem' \) | grep -q .; then
  fail "private proxy key material must never be versioned"
fi

# shellcheck disable=SC1090
. "$IMAGE_ENV"
test "${DRUSE_CADDY_VERSION:-}" = "2.11.4" ||
  fail "the reviewed Caddy version is no longer 2.11.4"
test "${DRUSE_CADDY_PLATFORM:-}" = "linux/amd64" ||
  fail "the proxy platform must remain explicit"
grep -Eq '^DRUSE_CADDY_IMAGE=docker\.io/library/caddy:2\.11\.4-alpine@sha256:[0-9a-f]{64}$' "$IMAGE_ENV" ||
  fail "Caddy image must carry the reviewed tag and immutable sha256 digest"

require_literal 'flush_interval -1' "stream route lost low-latency/no-buffering mode"
require_literal 'response_buffers 1MiB' "buffered negative-control route is missing"
require_literal 'versions 1.1' "upstream protocol is no longer fixed to HTTP/1.1"
require_literal 'keepalive_idle_conns_per_host 4' "upstream idle pool bound is missing"
require_literal 'max_conns_per_host 4' "upstream connection pool is unbounded"
require_literal 'lb_retries 0' "retry count is no longer zero"
require_literal 'lb_try_duration 0s' "retry duration is no longer zero"
require_literal 'health_uri /ready' "shutdown/rollout route lost its readiness check"
require_literal 'health_fails 1' "readiness failure no longer removes the upstream immediately"
require_literal 'request_body {' "proxy-owned body limiter is missing"
require_literal 'max_size 1MB' "proxy-owned body cap changed without reconciliation"
require_literal 'max_header_size {$DRUSE_PROXY_MAX_HEADER_SIZE:16KB}' "proxy header cap/override is missing"
require_literal 'response_header_timeout 300ms' "proxy-owned response timeout is missing"
require_literal 'trusted_proxies_strict' "forwarded chain must be parsed from the right"
require_literal 'client_ip_headers X-Forwarded-For' "forwarded client address header is not explicit"
require_literal 'Strict-Transport-Security' "TLS terminator lost HSTS ownership"
require_literal '@valid_request_id header_regexp X-Request-Id ^[A-Za-z0-9._-]{1,64}$' "proxy log lost request-ID validation"
require_literal 'log_append @valid_request_id request_id' "proxy log lost the validated correlation field"
require_literal 'request>headers delete' "proxy access log would retain inbound headers/secrets"
require_literal 'resp_headers delete' "proxy access log would retain response cookies/headers"

grep -Fq '0.0.0.0/0' "$CONFIG" &&
  fail "a wildcard trusted proxy would let every peer forge client identity"
grep -Fq '::/0' "$CONFIG" &&
  fail "an IPv6 wildcard trusted proxy would let every peer forge client identity"
grep -Fq 'tls_insecure_skip_verify' "$CONFIG" &&
  fail "TLS verification bypass is forbidden in the reference topology"
require_literal '192.0.2.0/24' "default trusted ingress must remain a non-routable documentation network"

PROXY_COUNT="$(grep -Ec '^[[:space:]]*reverse_proxy ' "$CONFIG")"
RETRY_COUNT="$(grep -Ec '^[[:space:]]*lb_retries 0$' "$CONFIG")"
TRY_DURATION_COUNT="$(grep -Ec '^[[:space:]]*lb_try_duration 0s$' "$CONFIG")"
test "$PROXY_COUNT" -gt 0 || fail "no reverse_proxy route found"
test "$RETRY_COUNT" -eq "$PROXY_COUNT" ||
  fail "every reverse_proxy route must state lb_retries 0 ($RETRY_COUNT/$PROXY_COUNT)"
test "$TRY_DURATION_COUNT" -eq "$PROXY_COUNT" ||
  fail "every reverse_proxy route must state lb_try_duration 0s ($TRY_DURATION_COUNT/$PROXY_COUNT)"

if test "${DRUSE_PROXY_CONTROL_PROBE:-0}" = 1; then
  exit 0
fi

test -r "$ROOT/tests/r1-real-proxy/server/main.odin" || fail "real-proxy server fixture is missing"
test -r "$ROOT/tests/r1-real-proxy/client.py" || fail "real-proxy client fixture is missing"
test -x "$ROOT/ops/verification/run-real-proxy-contract.sh" || fail "real-proxy campaign is missing/not executable"
bash -n "$ROOT/ops/verification/run-real-proxy-contract.sh"
python3 -m py_compile "$ROOT/tests/r1-real-proxy/client.py"

ODIN_BIN="${DRUSE_ODIN_BIN:-${DRUSE_COMPILER:-$(command -v odin || true)}}"
test -x "$ODIN_BIN" || fail "Odin compiler not found"
TMP="$(mktemp -d -t druse-r1-proxy-check-XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT
"$ODIN_BIN" build "$ROOT/tests/r1-real-proxy/server" \
  -collection:druse="$ROOT" -out:"$TMP/server"

expect_mutation_rejected() {
  local name="$1"
  local expected="$2"
  shift 2
  local mutant="$TMP/$name.Caddyfile"
  cp "$CANONICAL" "$mutant"
  "$@" "$mutant"
  local output
  if output="$(DRUSE_PROXY_CONFIG="$mutant" DRUSE_PROXY_CONTROL_PROBE=1 "$0" 2>&1)"; then
    fail "negative control '$name' was accepted"
  fi
  grep -Fq "$expected" <<<"$output" ||
    fail "negative control '$name' failed for the wrong reason: $output"
  echo "r1 proxy control: $name rejected for the expected reason"
}

mutate_delete_flush() { sed -i '/flush_interval -1/d' "$1"; }
mutate_enable_retries() { sed -i 's/lb_retries 0/lb_retries 2/g' "$1"; }
mutate_trust_everyone() { sed -i 's#192.0.2.0/24#0.0.0.0/0#' "$1"; }
mutate_log_headers() { sed -i '/request>headers delete/d' "$1"; }
mutate_disable_tls_verify() {
  sed -i '0,/transport http {/s//transport http {\n\t\t\t\ttls_insecure_skip_verify/' "$1"
}

expect_mutation_rejected no-flush 'stream route lost low-latency' mutate_delete_flush
expect_mutation_rejected retries 'retry count is no longer zero' mutate_enable_retries
expect_mutation_rejected wildcard-trust 'wildcard trusted proxy' mutate_trust_everyone
expect_mutation_rejected header-leak 'would retain inbound headers' mutate_log_headers
expect_mutation_rejected insecure-tls 'TLS verification bypass is forbidden' mutate_disable_tls_verify

# A local image makes config validation stronger without turning the fast CI
# gate into an implicit network pull. The evidence campaign always requires it.
if test "${DRUSE_PROXY_SKIP_DOCKER_VALIDATE:-0}" != 1 &&
   command -v docker >/dev/null 2>&1 &&
   docker info >/dev/null 2>&1 &&
   docker image inspect "$DRUSE_CADDY_IMAGE" >/dev/null 2>&1; then
  mkdir -p "$TMP/certs" "$TMP/logs"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj '/CN=proxy.test' -addext 'subjectAltName=DNS:proxy.test' \
    -keyout "$TMP/certs/server-key.pem" -out "$TMP/certs/server.pem" >/dev/null 2>&1
  docker run --rm --platform "$DRUSE_CADDY_PLATFORM" \
    -e DRUSE_PROXY_PORT=22443 \
    -e DRUSE_UPSTREAM=host.docker.internal:22131 \
    -v "$CANONICAL:/etc/caddy/Caddyfile:ro" \
    -v "$TMP/certs:/certs:ro" \
    -v "$TMP/logs:/logs" \
    "$DRUSE_CADDY_IMAGE" \
    caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
  echo "r1 proxy config: validated by Caddy $DRUSE_CADDY_VERSION"
else
  echo "r1 proxy config: Docker/image unavailable; immutable static controls passed"
fi

echo "PASS: R1-WP03 pinned real-proxy configuration and controls"
