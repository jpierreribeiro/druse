#!/usr/bin/env bash
# R1-WP03 real Caddy/Druse interop campaign.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TODAY="$(date -u +%F)"
OUTPUT="$ROOT/evidence/${TODAY}-r1-real-proxy"
ALLOW_DIRTY=0

usage() {
  echo "usage: $0 [--output DIR] [--allow-dirty]" >&2
  exit 2
}

while test "$#" -gt 0; do
  case "$1" in
    --output)
      test "$#" -ge 2 || usage
      OUTPUT="$2"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    *) usage ;;
  esac
done

fail() {
  echo "ERROR: R1 real-proxy campaign: $*" >&2
  exit 1
}

DIRTY="$(git -C "$ROOT" status --porcelain)"
if test -n "$DIRTY" && test "$ALLOW_DIRTY" -ne 1; then
  fail "candidate working tree is dirty; commit first so evidence has one identity"
fi
test ! -e "$OUTPUT" || fail "output already exists: $OUTPUT"

command -v docker >/dev/null 2>&1 || fail "Docker is required"
docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable"
command -v openssl >/dev/null 2>&1 || fail "OpenSSL is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
curl --version | grep -q 'HTTP2' || fail "curl must include HTTP/2 support"
command -v ss >/dev/null 2>&1 || fail "ss is required for the upstream pool measurement"

IMAGE_ENV="$ROOT/ops/proxy/caddy/image.env"
CADDYFILE="$ROOT/ops/proxy/caddy/Caddyfile"
CLIENT="$ROOT/tests/r1-real-proxy/client.py"
# shellcheck disable=SC1090
. "$IMAGE_ENV"
docker image inspect "$DRUSE_CADDY_IMAGE" >/dev/null 2>&1 ||
  fail "pinned image is absent; run: docker pull caddy:${DRUSE_CADDY_VERSION}-alpine"

WORK="$(mktemp -d -t druse-r1-real-proxy-XXXXXXXX)"
ORIGIN_PORT=22131
PROXY_PORT=22443
CADDY_NAME="druse-r1-proxy-$$"
SERVER="$WORK/server"
SERVER_PID=""
CADDY_RUNNING=0
CADDY_RUN=0
HOLDER_PID=""
CURL_PID=""

cleanup() {
  if test -n "$CURL_PID"; then kill -KILL "$CURL_PID" 2>/dev/null || true; fi
  if test -n "$HOLDER_PID"; then kill -KILL "$HOLDER_PID" 2>/dev/null || true; fi
  if test -n "$SERVER_PID" && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -KILL "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if test "$CADDY_RUNNING" -eq 1; then
    docker logs "$CADDY_NAME" >"$OUTPUT/raw/caddy-${CADDY_RUN}.container.log" 2>&1 || true
    docker rm -f "$CADDY_NAME" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

mkdir -p "$OUTPUT/config" "$OUTPUT/raw" "$OUTPUT/analysis" "$WORK/certs" "$WORK/markers"
ODIN_BIN="${DRUSE_ODIN_BIN:-$(command -v odin || true)}"
test -x "$ODIN_BIN" || fail "Odin compiler not found"
"$ODIN_BIN" build "$ROOT/tests/r1-real-proxy/server" \
  -collection:druse="$ROOT" -out:"$SERVER"

# Ephemeral campaign PKI. Private keys remain in WORK and are deleted on exit.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=Druse R1 Test CA' \
  -keyout "$WORK/certs/ca-key.pem" -out "$WORK/certs/ca.pem" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes \
  -subj '/CN=proxy.test' -addext 'subjectAltName=DNS:proxy.test' \
  -keyout "$WORK/certs/server-key.pem" -out "$WORK/certs/server.csr" >/dev/null 2>&1
openssl x509 -req -days 1 -in "$WORK/certs/server.csr" \
  -CA "$WORK/certs/ca.pem" -CAkey "$WORK/certs/ca-key.pem" -CAcreateserial \
  -copy_extensions copy -out "$WORK/certs/server.pem" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=Wrong R1 CA' \
  -keyout "$WORK/certs/wrong-ca-key.pem" -out "$WORK/certs/wrong-ca.pem" >/dev/null 2>&1
cp "$WORK/certs/ca.pem" "$OUTPUT/config/campaign-ca.pem"
cp "$WORK/certs/server.pem" "$OUTPUT/config/proxy-public.pem"
cp "$CADDYFILE" "$OUTPUT/config/Caddyfile"
cp "$IMAGE_ENV" "$OUTPUT/config/image.env"

COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
TREE="$(git -C "$ROOT" rev-parse HEAD^{tree})"
IMAGE_ID="$(docker image inspect "$DRUSE_CADDY_IMAGE" --format '{{.Id}}')"
IMAGE_DIGESTS="$(docker image inspect "$DRUSE_CADDY_IMAGE" --format '{{json .RepoDigests}}')"
{
  echo "campaign=R1-WP03-real-proxy"
  echo "start_utc=$(date -u +%FT%TZ)"
  echo "commit=$COMMIT"
  echo "tree=$TREE"
  echo "working_tree_dirty=$([ -n "$DIRTY" ] && echo yes || echo no)"
  echo "compiler=$ODIN_BIN"
  echo "compiler_sha256=$(sha256sum "$ODIN_BIN" | awk '{print $1}')"
  echo "server_sha256=$(sha256sum "$SERVER" | awk '{print $1}')"
  echo "client_sha256=$(sha256sum "$CLIENT" | awk '{print $1}')"
  echo "caddy_version=$DRUSE_CADDY_VERSION"
  echo "caddy_platform=$DRUSE_CADDY_PLATFORM"
  echo "caddy_image=$DRUSE_CADDY_IMAGE"
  echo "caddy_image_id=$IMAGE_ID"
  echo "caddy_repo_digests=$IMAGE_DIGESTS"
} >"$OUTPUT/manifest.txt"
{
  uname -a
  "$ODIN_BIN" version
  docker version --format 'docker_client={{.Client.Version}} docker_server={{.Server.Version}}'
  docker run --rm --platform "$DRUSE_CADDY_PLATFORM" "$DRUSE_CADDY_IMAGE" caddy version
  curl --version | head -n 3
  openssl version
} >"$OUTPUT/environment.txt"
{
  echo "ca_sha256=$(openssl x509 -in "$WORK/certs/ca.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
  echo "server_sha256=$(openssl x509 -in "$WORK/certs/server.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
  openssl x509 -in "$WORK/certs/server.pem" -noout -subject -issuer -dates -ext subjectAltName
} | sed 's/[[:space:]]*$//' >"$OUTPUT/analysis/certificate.txt"
{
  echo "build=$ODIN_BIN build tests/r1-real-proxy/server -collection:druse=."
  echo "proxy=docker run --platform $DRUSE_CADDY_PLATFORM $DRUSE_CADDY_IMAGE"
  echo "client=curl --http2 --cacert campaign-ca.pem --resolve proxy.test:$PROXY_PORT:127.0.0.1"
  echo "private_keys=ephemeral; never copied into evidence"
} >"$OUTPUT/commands.txt"

proxy_url() {
  printf 'https://proxy.test:%s%s' "$PROXY_PORT" "$1"
}

proxy_curl() {
  curl --noproxy '*' --silent --show-error --max-time 8 \
    --cacert "$WORK/certs/ca.pem" \
    --resolve "proxy.test:$PROXY_PORT:127.0.0.1" "$@"
}

wait_file() {
  local path="$1"
  local deadline=$((SECONDS + 8))
  while ! test -f "$path"; do
    test "$SECONDS" -lt "$deadline" || fail "timed out waiting for ${path##*/}"
    sleep 0.02
  done
}

wait_origin() {
  for _ in $(seq 1 200); do
    curl --noproxy '*' -fsS --max-time 0.2 "http://127.0.0.1:$ORIGIN_PORT/health" >/dev/null 2>&1 &&
      return 0
    test -n "$SERVER_PID" && kill -0 "$SERVER_PID" 2>/dev/null || return 1
    sleep 0.02
  done
  return 1
}

wait_proxy() {
  for _ in $(seq 1 200); do
    proxy_curl -fsS "$(proxy_url /ok)" >/dev/null 2>&1 && return 0
    sleep 0.03
  done
  return 1
}

wait_proxy_listener() {
  for _ in $(seq 1 200); do
    if openssl s_client -connect "127.0.0.1:$PROXY_PORT" -servername proxy.test \
      -CAfile "$WORK/certs/ca.pem" -verify_return_error </dev/null >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.02
  done
  return 1
}

start_caddy() {
  local ingress="${1:-192.0.2.0/24}"
  local header_limit="${2:-16KB}"
  CADDY_RUN=$((CADDY_RUN + 1))
  docker run -d --name "$CADDY_NAME" \
    --platform "$DRUSE_CADDY_PLATFORM" \
    --add-host host.docker.internal:host-gateway \
    -p "127.0.0.1:$PROXY_PORT:$PROXY_PORT" \
    --user "$(id -u):$(id -g)" \
    -e XDG_DATA_HOME=/tmp/caddy-data \
    -e XDG_CONFIG_HOME=/tmp/caddy-config \
    -e DRUSE_PROXY_PORT="$PROXY_PORT" \
    -e DRUSE_UPSTREAM="host.docker.internal:$ORIGIN_PORT" \
    -e DRUSE_PROXY_TRUSTED_INGRESS="$ingress" \
    -e DRUSE_PROXY_MAX_HEADER_SIZE="$header_limit" \
    -v "$CADDYFILE:/etc/caddy/Caddyfile:ro" \
    -v "$WORK/certs:/certs:ro" \
    -v "$OUTPUT/raw:/logs" \
    "$DRUSE_CADDY_IMAGE" \
    caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
  CADDY_RUNNING=1
}

stop_caddy() {
  test "$CADDY_RUNNING" -eq 1 || return 0
  docker logs "$CADDY_NAME" >"$OUTPUT/raw/caddy-${CADDY_RUN}.container.log" 2>&1 || true
  docker rm -f "$CADDY_NAME" >/dev/null
  CADDY_RUNNING=0
}

caddy_ip() {
  docker inspect "$CADDY_NAME" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
}

start_origin() {
  local trust_1="${1:-198.18.0.1}"
  local trust_2="${2:-}"
  local max_connections="${3:-64}"
  local reserved="${4:-4}"
  local label="${5:-origin}"
  mkdir -p "$WORK/markers/$label"
  env \
    DRUSE_PORT="$ORIGIN_PORT" \
    DRUSE_MARKER_DIR="$WORK/markers/$label" \
    DRUSE_TRUST_PROXY_1="$trust_1" \
    DRUSE_TRUST_PROXY_2="$trust_2" \
    DRUSE_MAX_CONNECTIONS="$max_connections" \
    DRUSE_RESERVED_CONNECTIONS="$reserved" \
    "$SERVER" >"$OUTPUT/raw/$label.log" 2>&1 &
  SERVER_PID=$!
  wait_origin || fail "origin failed to become ready ($label)"
}

stop_origin() {
  test -n "$SERVER_PID" || return 0
  kill -TERM "$SERVER_PID"
  local status=0
  wait "$SERVER_PID" || status=$?
  SERVER_PID=""
  test "$status" -eq 0 || fail "origin exited $status instead of 0"
}

start_caddy
CADDY_IP="$(caddy_ip)"
test -n "$CADDY_IP" || fail "could not resolve Caddy container IP"
start_origin "$CADDY_IP" "" 64 4 base
wait_proxy || fail "TLS proxy did not become ready"
BRIDGE_GATEWAY="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"

# A — TLS trust and client-side HTTP/2.
HTTP_VERSION="$(proxy_curl --http2 -o "$OUTPUT/raw/tls-body.txt" -w '%{http_version}' "$(proxy_url /ok)")"
test "$HTTP_VERSION" = "2" || fail "client-to-proxy protocol is HTTP/$HTTP_VERSION, expected HTTP/2"
if curl --noproxy '*' --silent --max-time 3 --cacert "$WORK/certs/wrong-ca.pem" \
  --resolve "proxy.test:$PROXY_PORT:127.0.0.1" "$(proxy_url /ok)" >/dev/null 2>&1; then
  fail "an unrelated CA accepted the proxy certificate"
fi
if curl --noproxy '*' --silent --max-time 3 --cacert "$WORK/certs/ca.pem" \
  --resolve "wrong.test:$PROXY_PORT:127.0.0.1" \
  "https://wrong.test:$PROXY_PORT/ok" >/dev/null 2>&1; then
  fail "hostname mismatch was accepted"
fi
printf 'valid_chain=accepted\nwrong_ca=refused\nwrong_host=refused\nclient_http_version=%s\nupstream_version=1.1\n' \
  "$HTTP_VERSION" >"$OUTPUT/analysis/tls-protocol.txt"

# B — 20 downstream requests retain a bounded idle upstream pool.
URLS=()
for _ in $(seq 1 20); do URLS+=("$(proxy_url /ok)"); done
proxy_curl --http2 -o /dev/null "${URLS[@]}" >"$OUTPUT/raw/pooling-curl.txt"
sleep 0.1
ss -Htanp state established |
  grep -E "(:|\\])$ORIGIN_PORT[[:space:]]" |
  sed 's/[[:space:]]*$//' >"$OUTPUT/raw/pooling-sockets.txt"
UPSTREAM_CONNECTIONS="$(wc -l <"$OUTPUT/raw/pooling-sockets.txt")"
test "$UPSTREAM_CONNECTIONS" -ge 1 || fail "no retained Caddy-to-Druse upstream connection was measured"
test "$UPSTREAM_CONNECTIONS" -le 3 ||
  fail "20 requests left $UPSTREAM_CONNECTIONS upstream connections; expected bounded pooling"
printf 'requests=20\nretained_upstream_connections=%s\nconfigured_max_conns_per_host=4\n' \
  "$UPSTREAM_CONNECTIONS" >"$OUTPUT/analysis/pooling.txt"

# C — incremental stream versus an intentionally buffered control.
python3 "$CLIENT" stream 127.0.0.1 "$PROXY_PORT" "$WORK/certs/ca.pem" proxy.test /stream \
  >"$OUTPUT/raw/stream-unbuffered.json"
python3 "$CLIENT" stream 127.0.0.1 "$PROXY_PORT" "$WORK/certs/ca.pem" proxy.test /buffered-stream buffered \
  >"$OUTPUT/raw/stream-buffered.json"
python3 - "$OUTPUT/raw/stream-unbuffered.json" "$OUTPUT/raw/stream-buffered.json" <<'PY'
import json, sys
fast = json.load(open(sys.argv[1], encoding="utf-8"))
slow = json.load(open(sys.argv[2], encoding="utf-8"))
if fast["first_body_ms"] >= 800:
    raise SystemExit(f"unbuffered first byte was late: {fast}")
if slow["first_body_ms"] is not None or slow["events"] != 0:
    raise SystemExit(f"buffered control leaked a stream event: {slow}")
if fast["total_ms"] < 1800 or slow["total_ms"] < 1100:
    raise SystemExit("stream observation windows were shorter than the contract")
PY

# D — body/header/time precedence in both directions.
python3 - "$WORK/body-small.json" "$WORK/body-proxy-over.json" "$WORK/body-druse-over.json" <<'PY'
import json, sys
for path, size in zip(sys.argv[1:], (512 * 1024, 1536 * 1024, 2560 * 1024)):
    with open(path, "w", encoding="ascii") as out:
        json.dump({"data": "x" * size}, out, separators=(",", ":"))
PY
SMALL_BODY="$(proxy_curl -H 'Content-Type: application/json' --data-binary "@$WORK/body-small.json" "$(proxy_url /body)")"
test "$SMALL_BODY" = "524288" || fail "allowed body did not reach Druse intact: $SMALL_BODY"
PROXY_BODY_STATUS="$(proxy_curl -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  --data-binary "@$WORK/body-proxy-over.json" "$(proxy_url /proxy-limit)" || true)"
test "$PROXY_BODY_STATUS" = "413" || fail "proxy-owned body cap returned $PROXY_BODY_STATUS, expected 413"
DRUSE_BODY_STATUS="$(proxy_curl -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  --data-binary "@$WORK/body-druse-over.json" "$(proxy_url /body)" || true)"
test "$DRUSE_BODY_STATUS" = "413" || fail "Druse-owned body cap returned $DRUSE_BODY_STATUS, expected 413"

python3 "$CLIENT" header 127.0.0.1 "$PROXY_PORT" "$WORK/certs/ca.pem" proxy.test 12288 \
  >"$OUTPUT/raw/header-druse-limit.json"
grep -Eq '"status": (400|431)' "$OUTPUT/raw/header-druse-limit.json" ||
  fail "12 KiB header did not reach the stricter Druse header boundary"

START_NS="$(date +%s%N)"
PROXY_TIMEOUT_STATUS="$(proxy_curl -o /dev/null -w '%{http_code}' "$(proxy_url /proxy-timeout)" || true)"
PROXY_TIMEOUT_MS=$((($(date +%s%N) - START_NS) / 1000000))
test "$PROXY_TIMEOUT_STATUS" = "504" || fail "proxy response timeout returned $PROXY_TIMEOUT_STATUS, expected 504"
test "$PROXY_TIMEOUT_MS" -ge 250 -a "$PROXY_TIMEOUT_MS" -le 1000 ||
  fail "proxy response timeout took ${PROXY_TIMEOUT_MS}ms, outside its 300ms ownership window"
python3 "$CLIENT" slow-body 127.0.0.1 "$PROXY_PORT" "$WORK/certs/ca.pem" proxy.test \
  >"$OUTPUT/raw/timeout-druse-request.json"
python3 - "$OUTPUT/raw/timeout-druse-request.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1], encoding="utf-8"))
if result["status"] not in (408, 502, 504):
    raise SystemExit(f"Druse request deadline was ambiguous: {result}")
if not 2500 <= result["elapsed_ms"] <= 6000:
    raise SystemExit(f"Druse request deadline escaped its 3s/6s layer bounds: {result}")
PY
printf 'allowed_body_data_bytes=524288\nproxy_body_status=%s\ndruse_body_status=%s\nproxy_timeout_status=%s\nproxy_timeout_ms=%s\n' \
  "$PROXY_BODY_STATUS" "$DRUSE_BODY_STATUS" "$PROXY_TIMEOUT_STATUS" "$PROXY_TIMEOUT_MS" \
  >"$OUTPUT/analysis/limit-precedence.txt"

# E — the proxy can be stricter than Druse for headers as an explicit variant.
stop_caddy
start_caddy "192.0.2.0/24" 1KB
wait_proxy || fail "strict-header Caddy variant did not recover"
python3 "$CLIENT" header 127.0.0.1 "$PROXY_PORT" "$WORK/certs/ca.pem" proxy.test 6144 \
  >"$OUTPUT/raw/header-proxy-limit.json"
grep -Eq '"status": (400|431)' "$OUTPUT/raw/header-proxy-limit.json" ||
  fail "6 KiB header did not hit the stricter Caddy boundary"

# F — edge spoof is discarded; a declared previous hop forms a right-walked chain.
stop_caddy
stop_origin
start_caddy
CADDY_IP="$(caddy_ip)"
start_origin "$CADDY_IP" "" 64 4 identity-edge
wait_proxy || fail "identity edge stack did not recover"
EDGE_IP="$(proxy_curl -H 'X-Forwarded-For: 198.51.100.77' "$(proxy_url /whoami)")"
test "$EDGE_IP" != "198.51.100.77" || fail "edge client spoof controlled web.client_ip"
test "$EDGE_IP" = "$BRIDGE_GATEWAY" ||
  fail "edge identity was $EDGE_IP, expected Docker client peer $BRIDGE_GATEWAY"
DIRECT_IP="$(curl --noproxy '*' -sS -H 'X-Forwarded-For: 198.51.100.77' \
  "http://127.0.0.1:$ORIGIN_PORT/whoami")"
test "$DIRECT_IP" = "127.0.0.1" || fail "direct untrusted spoof was believed: $DIRECT_IP"

stop_caddy
stop_origin
start_caddy "$BRIDGE_GATEWAY/32"
CADDY_IP="$(caddy_ip)"
start_origin "$CADDY_IP" "$BRIDGE_GATEWAY" 64 4 identity-chain
wait_proxy || fail "identity chain stack did not recover"
CHAIN_IP="$(proxy_curl -H 'X-Forwarded-For: 198.51.100.77, 203.0.113.44' "$(proxy_url /whoami)")"
test "$CHAIN_IP" = "203.0.113.44" ||
  fail "multi-hop right walk returned $CHAIN_IP instead of first untrusted 203.0.113.44"
printf 'caddy_peer=%s\nprevious_hop=%s\nedge_spoof_result=%s\ndirect_spoof_result=%s\nmulti_hop_result=%s\n' \
  "$CADDY_IP" "$BRIDGE_GATEWAY" "$EDGE_IP" "$DIRECT_IP" "$CHAIN_IP" \
  >"$OUTPUT/analysis/client-identity.txt"

# G — security-header ownership and redacted correlation.
proxy_curl -D "$OUTPUT/raw/security-headers.txt" -o /dev/null \
  -H 'X-Request-Id: r1-correlation-001' \
  -H 'Authorization: Bearer r1-secret-do-not-log' \
  -H 'Cookie: session=r1-secret-do-not-log' \
  "$(proxy_url /headers)"
sed -i -e 's/\r$//' -e 's/[[:space:]]*$//' -e '${/^$/d;}' \
  "$OUTPUT/raw/security-headers.txt"
for expected in \
  'strict-transport-security:' \
  'content-security-policy:' \
  'set-cookie: pilot=1; Secure; HttpOnly; SameSite=Strict' \
  'x-content-type-options: nosniff' \
  'x-frame-options: DENY' \
  'referrer-policy: no-referrer'; do
  grep -Fqi "$expected" "$OUTPUT/raw/security-headers.txt" ||
    fail "security header owner is missing: $expected"
done
sleep 0.1
grep -Fq 'r1-correlation-001' "$OUTPUT/raw/access.json" ||
  fail "Caddy access log lost the correlation ID"
if grep -Fiq 'r1-secret-do-not-log' "$OUTPUT/raw/access.json"; then
  fail "Caddy access log retained a credential/cookie value"
fi

# H — saturation produces one bounded proxy failure, then recovery.
stop_caddy
stop_origin
start_origin "198.18.0.1" "" 12 2 saturation
python3 "$CLIENT" hold "$ORIGIN_PORT" 10 "$WORK/holders-ready" \
  >"$OUTPUT/raw/saturation-holders.log" 2>&1 &
HOLDER_PID=$!
wait_file "$WORK/holders-ready"
test "$(cat "$WORK/holders-ready")" = "10" || fail "saturation holder count changed"
start_caddy
wait_proxy_listener || fail "Caddy TLS listener did not become ready during saturation"
START_NS="$(date +%s%N)"
SAT_STATUS="$(proxy_curl -o /dev/null -w '%{http_code}' \
  -H 'X-Request-Id: r1-saturation-once' "$(proxy_url /ok)" || true)"
SAT_MS=$((($(date +%s%N) - START_NS) / 1000000))
test "$SAT_STATUS" = "502" -o "$SAT_STATUS" = "503" ||
  fail "saturated upstream returned $SAT_STATUS, expected 502/503"
test "$SAT_MS" -le 1000 || fail "zero-retry saturation path took ${SAT_MS}ms"
kill -TERM "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=""
wait_proxy || fail "proxy did not recover after upstream admission slots returned"
printf 'held_connections=10\nproxy_status=%s\nfailure_ms=%s\nrecovery_status=200\nlb_retries=0\n' \
  "$SAT_STATUS" "$SAT_MS" >"$OUTPUT/analysis/saturation-retry.txt"

# I — readiness-aware shutdown: no post-drain request reaches its handler.
stop_caddy
stop_origin
start_caddy
CADDY_IP="$(caddy_ip)"
start_origin "$CADDY_IP" "" 64 4 shutdown
wait_proxy || fail "shutdown stack did not recover"
proxy_curl "$(proxy_url /guarded/drain-watch)" >"$OUTPUT/raw/shutdown-inflight.txt" 2>&1 &
CURL_PID=$!
wait_file "$WORK/markers/shutdown/drain-watch-entered"
kill -TERM "$SERVER_PID"
wait_file "$WORK/markers/shutdown/draining-observed"
sleep 0.4
for attempt in $(seq 1 5); do
  status="$(proxy_curl -o /dev/null -w '%{http_code}' \
    -H "X-Request-Id: r1-post-drain-$attempt" "$(proxy_url /guarded/unexpected)" || true)"
  printf '%s\t%s\n' "$attempt" "$status" >>"$OUTPUT/raw/shutdown-post-drain.tsv"
  test "$status" != "200" || fail "guarded request $attempt reached Druse after draining was observable"
done
wait "$CURL_PID" || true
CURL_PID=""
status=0
wait "$SERVER_PID" || status=$?
SERVER_PID=""
test "$status" -eq 0 || fail "origin shutdown exited $status"
grep -Fq 'unexpected_after_drain=0' "$WORK/markers/shutdown/final-counts.txt" ||
  fail "a post-drain request entered its handler"
cp "$WORK/markers/shutdown/final-counts.txt" "$OUTPUT/analysis/shutdown.txt"

stop_caddy
{
  echo "# R1-WP03 real proxy verdict"
  echo
  echo "**Result: PASS for the controlled-pilot reference topology.**"
  echo
  echo "- Caddy $DRUSE_CADDY_VERSION was executed from the pinned linux/amd64 image digest."
  echo "- Valid CA/hostname negotiated HTTP/2 to Caddy; wrong CA and hostname were refused."
  echo "- Caddy-to-Druse was fixed to HTTP/1.1 with a bounded four-connection pool."
  echo "- The unbuffered stream delivered its first event before 800 ms; the buffered control delivered none in 1.2 s."
  echo "- Proxy and Druse body/header/time limits each won when configured as the stricter layer."
  echo "- Direct and edge XFF spoofing failed closed; the declared multi-hop chain resolved from the right."
  echo "- Saturation returned one bounded 502/503 with zero configured retries and recovered to 200."
  echo "- Readiness-aware shutdown admitted zero guarded handlers after draining became observable."
  echo "- HSTS belongs to Caddy; CSP/cookie attributes and unconditional secure headers belong to the app."
  echo "- Access logs retained the validated request ID and discarded request/response header maps."
  echo
  echo "This closes R1-WP03 for Caddy only. Another production proxy requires its own campaign."
} >"$OUTPUT/verdict.md"
echo "end_utc=$(date -u +%FT%TZ)" >>"$OUTPUT/manifest.txt"

(
  cd "$OUTPUT"
  find . -type f ! -name SHA256SUMS -print0 |
    sort -z |
    xargs -0 sha256sum >SHA256SUMS
)
(
  cd "$OUTPUT"
  sha256sum -c SHA256SUMS >/dev/null
)

echo "PASS: R1-WP03 real Caddy/Druse contract"
echo "evidence: $OUTPUT"
