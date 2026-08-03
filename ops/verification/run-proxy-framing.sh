#!/usr/bin/env bash
# R2-WP06 — the raw-wire framing corpus, replayed THROUGH the pinned proxy.
#
#   usage: run-proxy-framing.sh [OUTPUT_DIR]
#
# WHY. `tests/wp9-wire` sends the corpus straight at Druse and proves Druse
# refuses each malformed framing. That is necessary and it is not the smuggling
# question. Request smuggling is a DISAGREEMENT: the front hop and the back hop
# read the same bytes as two different requests, and every published attack in
# the class lives in that gap rather than in either parser alone.
#
# `docs/supported-profile.md` makes a reviewed reverse proxy the supported edge,
# so the pair — Caddy in front, Druse behind — is what production runs. Nothing
# in this repository had ever put a malformed frame through the pair and
# compared the two answers.
#
# WHAT A FINDING LOOKS LIKE HERE. Not "the proxy rejected it": that is the
# proxy doing its job and it is the common case. The finding is any case where
# the pair's behaviour differs from Druse's own in a way that lets bytes Druse
# would refuse reach it as something else — or, worse, where the proxy forwards
# and Druse ACCEPTS what it refuses when spoken to directly.
#
# The output is a table of (direct, proxied) outcomes. Divergence is reported,
# not judged: this script's job is to produce the comparison that nobody had.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/evidence/$(date -u +%F)-r2-proxy-framing}"
WORK="$(mktemp -d -t druse-proxyframe-XXXXXXXX)"
CADDY="druse-proxyframe-$$"
ORIGIN_PORT="${DRUSE_FRAMING_ORIGIN_PORT:-18301}"
PROXY_PORT="${DRUSE_FRAMING_PROXY_PORT:-18443}"
SERVER_PID=""

cleanup() {
  [[ -n "$SERVER_PID" ]] && kill -TERM "$SERVER_PID" 2>/dev/null
  docker rm -f "$CADDY" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "PROXY-FRAMING: $*" >&2; exit 1; }

for t in docker openssl python3 curl; do
  command -v "$t" >/dev/null 2>&1 || fail "$t is required"
done
docker info >/dev/null 2>&1 || fail "the docker daemon is unavailable; the supported edge cannot be started"

if   [[ -n "${DRUSE_COMPILER:-}" ]];     then ODIN="$DRUSE_COMPILER"
elif [[ -n "${DRUSE_ODIN_BIN:-}" ]];     then ODIN="$DRUSE_ODIN_BIN"
elif command -v odin >/dev/null 2>&1;    then ODIN="$(command -v odin)"
else fail "no Odin compiler"; fi
ODIN="$(readlink -f "$ODIN")"

mkdir -p "$OUT/raw" "$OUT/analysis" "$WORK/certs" "$WORK/logs"
chmod 0777 "$WORK/logs"

# THE ORIGIN MUST SERVE THE CORPUS'S OWN ROUTES. The first run of this script
# used tests/r1-real-proxy/server and was INVALID: that fixture serves /health,
# /ok and /body while the corpus targets /ping, /echo and /smuggled, so every
# handler-dependent case answered 404 on both legs and nothing could be read.
#
# tests/support/wire_origin is the wp9 fixture as a standalone binary, with the
# same routes and the same status codes -- including /smuggled, which is the
# instrument: a request that crosses the pair as TWO requests shows up as a hit
# on a route nobody addressed, and that is the finding a single hop cannot
# produce.
env ODIN_ROOT="$(cd "$(dirname "$ODIN")" && pwd)" "$ODIN" build \
  "$ROOT/tests/support/wire_origin" -collection:druse="$ROOT" -o:speed \
  -out:"$WORK/origin" >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log" >&2; fail "origin build failed"; }

"$WORK/origin" "$ORIGIN_PORT" >"$WORK/origin.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 200); do
  curl --noproxy '*' -fsS --max-time 1 "http://127.0.0.1:$ORIGIN_PORT/ping" >/dev/null 2>&1 && break
  sleep 0.1
done

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=framing-ca' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "$WORK/certs/ca-key.pem" -out "$WORK/certs/ca.pem" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj '/CN=proxy.test' \
  -addext 'subjectAltName=DNS:proxy.test' \
  -keyout "$WORK/certs/server-key.pem" -out "$WORK/certs/server.csr" >/dev/null 2>&1
openssl x509 -req -days 1 -in "$WORK/certs/server.csr" -CA "$WORK/certs/ca.pem" \
  -CAkey "$WORK/certs/ca-key.pem" -CAcreateserial -copy_extensions copy \
  -out "$WORK/certs/server.pem" >/dev/null 2>&1

. "$ROOT/ops/proxy/caddy/image.env"
docker run -d --name "$CADDY" --platform "$DRUSE_CADDY_PLATFORM" \
  --add-host host.docker.internal:host-gateway \
  -p "127.0.0.1:$PROXY_PORT:$PROXY_PORT" \
  -e DRUSE_PROXY_PORT="$PROXY_PORT" \
  -e DRUSE_UPSTREAM="host.docker.internal:$ORIGIN_PORT" \
  -v "$ROOT/ops/proxy/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$WORK/certs:/certs:ro" -v "$WORK/logs:/logs" \
  "$DRUSE_CADDY_IMAGE" >/dev/null 2>&1 || fail "the pinned Caddy did not start"

for _ in $(seq 1 200); do
  openssl s_client -connect "127.0.0.1:$PROXY_PORT" -servername proxy.test \
    -CAfile "$WORK/certs/ca.pem" -verify_return_error </dev/null >/dev/null 2>&1 && break
  sleep 0.1
done

# The comparison itself. Python speaks both legs so the malformed bytes go on
# the wire untouched: curl would normalise the very framing under test.
DRUSE_CA="$WORK/certs/ca.pem" DRUSE_ORIGIN_PORT="$ORIGIN_PORT" \
DRUSE_PROXY_PORT="$PROXY_PORT" DRUSE_CORPUS="$ROOT/tests/support/transport_conformance/corpus.odin" \
python3 "$ROOT/ops/verification/proxy_framing_compare.py" \
  >"$OUT/raw/comparison.txt" 2>"$OUT/raw/comparison.err"

# The origin prints its counters on shutdown. `/smuggled` at anything but zero
# is the headline result of this whole comparison.
kill -TERM "$SERVER_PID" 2>/dev/null
for _ in $(seq 1 100); do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.1; done
SERVER_PID=""
cp "$WORK/origin.log" "$OUT/raw/origin.log" 2>/dev/null
grep -h "wire_origin_counters" "$WORK/origin.log" >"$OUT/raw/origin-counters.txt" 2>/dev/null ||
  echo "wire_origin_counters=UNAVAILABLE (the origin did not print them)" >"$OUT/raw/origin-counters.txt"
docker logs "$CADDY" >"$OUT/raw/caddy.log" 2>&1
{
  echo "utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
  echo "caddy_image=$DRUSE_CADDY_IMAGE"
  echo "odin=$("$ODIN" version 2>&1 | head -n 1)"
} >"$OUT/environment.txt"
echo "comparison written to $OUT/raw/comparison.txt" >&2
