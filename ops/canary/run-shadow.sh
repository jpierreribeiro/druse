#!/usr/bin/env bash
# R2-WP07 step 1 — run the shadow and prove no response reached a user.
#
#   usage: run-shadow.sh [OUTPUT_DIR]
#
# WHY THIS EXISTS AT ALL. R2-WP07 was recorded as "blocked on real traffic", and
# that reading was wrong. `R2-restricted-production.md` §8 opens its canary
# progression with "shadow ou replay sanitizado, sem resposta ao usuário" — a
# step whose entire definition is that no user is on the other end. It needs a
# candidate, the supported edge, and traffic in the shape of production. All
# three exist here. Steps 2 through 6 need real traffic and this script does not
# reach them; what to do about that is §8.1 of the plan, not this file.
#
# WHAT "SEM RESPOSTA AO USUÁRIO" IS MADE OF. Not an intention to discard. Four
# properties, each asserted rather than described:
#
#   K1  the candidate's listen address is RECORDED, and the framework's inability
#       to restrict it is named rather than papered over — see below;
#   K1b every peer that talked to the candidate during the window was the proxy.
#       This is the property K1 cannot provide, obtained by observation instead;
#   K2  the pinned proxy publishes its port to 127.0.0.1 only, so the supported
#       edge is not an edge to anywhere;
#   K3  the accounting CLOSES — every request the proxy served is one the shadow
#       driver sent, or a proxy-internal health probe, with no remainder. A
#       response that went to a user is a served request nobody here sent, and
#       that is the shape this reconciliation is built to catch.
#
# K1 IS A FINDING, NOT A CONTROL. `web.serve(&app, port)` binds dual-stack Any —
# `::`, falling back to `0.0.0.0` — and the public API takes no bind address
# (`web/serve.odin`, `web/internal/transport/odin_http_adapter.odin`). **A Druse
# application cannot be told to listen on loopback only.** For a shadow that is
# the natural containment and it is unavailable; for any deployment it means the
# process is reachable on every interface the host has, and containment is the
# host's firewall rather than the application's.
#
# This script does not invent an API for it. Readiness rule G5: a plan may name a
# public need, it may not invent a signature. The need is named in
# `R2-restricted-production.md` §8.1 and the containment is obtained here by K1b,
# which is weaker in kind — an observation over a window rather than a property —
# and is labelled that way in the manifest.
#
# K3 is the one that would survive somebody else's topology. K1b and K2 are the
# fence; K3 is the evidence.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$ROOT/evidence/$(date -u +%F)-r2-wp07-shadow}"
WORK="$(mktemp -d -t druse-shadow-XXXXXXXX)"
CADDY="druse-shadow-$$"
UPSTREAM_PORT="${DRUSE_SHADOW_UPSTREAM_PORT:-18601}"
PROXY_PORT="${DRUSE_SHADOW_PROXY_PORT:-18643}"
SECONDS_TO_RUN="${DRUSE_SHADOW_SECONDS:-60}"
SERVER_PID=""
PEER_WATCH_PID=""

cleanup() {
  [[ -n "${PEER_WATCH_PID:-}" ]] && kill "$PEER_WATCH_PID" 2>/dev/null
  [[ -n "$SERVER_PID" ]] && kill -TERM "$SERVER_PID" 2>/dev/null
  docker rm -f "$CADDY" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "SHADOW: $*" >&2; exit 1; }

for t in docker openssl python3 curl; do
  command -v "$t" >/dev/null 2>&1 || fail "$t is required"
done
docker info >/dev/null 2>&1 || fail "the docker daemon is unavailable; the supported edge cannot be started"

if   [[ -n "${DRUSE_COMPILER:-}" ]];     then ODIN="$DRUSE_COMPILER"
elif [[ -n "${DRUSE_ODIN_BIN:-}" ]];     then ODIN="$DRUSE_ODIN_BIN"
elif command -v odin >/dev/null 2>&1;    then ODIN="$(command -v odin)"
else fail "no Odin compiler"; fi
ODIN="$(readlink -f "$ODIN")"

mkdir -p "$OUT/raw" "$OUT/analysis" "$OUT/config" "$WORK/certs" "$WORK/logs"
chmod 0777 "$WORK/logs"

# The candidate is `tests/r1-real-proxy/server`, and the choice is not
# convenience. It is the fixture whose routes the pinned Caddyfile is written
# against — /stream, /proxy-limit, /proxy-timeout, /guarded's /ready — so the
# shadow runs the exact topology the R1 real-proxy campaign proved, which is
# what §8's pre-conditions ask for. A different app would be a different
# topology wearing the same proxy config.
env ODIN_ROOT="$(cd "$(dirname "$ODIN")" && pwd)" "$ODIN" build \
  "$ROOT/tests/r1-real-proxy/server" -collection:druse="$ROOT" -o:speed \
  -out:"$WORK/candidate" >"$WORK/build.log" 2>&1 ||
  { cat "$WORK/build.log" >&2; fail "candidate build failed"; }

CANDIDATE_SHA="$(sha256sum "$WORK/candidate" | awk '{print $1}')"

# K1. The listen address, RECORDED. `web.serve` takes a port and no address, so
# there is nothing to assert here — only something to write down.
DRUSE_PORT="$UPSTREAM_PORT" "$WORK/candidate" >"$WORK/candidate.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 200); do
  curl --noproxy '*' -fsS --max-time 1 "http://127.0.0.1:$UPSTREAM_PORT/health" >/dev/null 2>&1 && break
  sleep 0.1
done
curl --noproxy '*' -fsS --max-time 2 "http://127.0.0.1:$UPSTREAM_PORT/health" >/dev/null 2>&1 ||
  fail "the candidate never became ready on port $UPSTREAM_PORT"

ss -ltn 2>/dev/null | grep ":$UPSTREAM_PORT " >"$WORK/candidate-bind.txt" || true
cp "$WORK/candidate-bind.txt" "$OUT/raw/candidate-bind.txt"
test -s "$WORK/candidate-bind.txt" ||
  fail "no listener found for port $UPSTREAM_PORT; containment cannot be described from an empty observation"
if grep -qE '(0\.0\.0\.0|\*|\[::\]):'"$UPSTREAM_PORT" "$WORK/candidate-bind.txt"; then
  K1_BIND=wildcard
else
  K1_BIND=loopback
fi

# K1b. The property the bind cannot give: watch who actually connects. Sampled
# for the whole window in the background, so a peer that appears for one second
# is still recorded. Every peer must be the proxy container or loopback; anything
# else is a client this shadow did not intend to have.
(
  while :; do
    ss -tn state established "( sport = :$UPSTREAM_PORT )" 2>/dev/null |
      awk 'NR>1 {print $5}' >>"$WORK/peers.txt"
    sleep 0.25
  done
) &
PEER_WATCH_PID=$!

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=shadow-ca' \
  -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' \
  -keyout "$WORK/certs/ca-key.pem" -out "$WORK/certs/ca.pem" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -subj '/CN=proxy.test' \
  -addext 'subjectAltName=DNS:proxy.test' \
  -keyout "$WORK/certs/server-key.pem" -out "$WORK/certs/server.csr" >/dev/null 2>&1
openssl x509 -req -days 1 -in "$WORK/certs/server.csr" -CA "$WORK/certs/ca.pem" \
  -CAkey "$WORK/certs/ca-key.pem" -CAcreateserial -copy_extensions copy \
  -out "$WORK/certs/server.pem" >/dev/null 2>&1

. "$ROOT/ops/proxy/caddy/image.env"
# K2. `-p 127.0.0.1:...` rather than `-p ...`. Docker's default publishes to
# every interface AND writes an iptables rule that bypasses a host firewall, so
# the plain form would put the supported edge on the public internet while every
# other control in this script still read green.
docker run -d --name "$CADDY" --platform "$DRUSE_CADDY_PLATFORM" \
  --add-host host.docker.internal:host-gateway \
  -p "127.0.0.1:$PROXY_PORT:$PROXY_PORT" \
  -e DRUSE_PROXY_PORT="$PROXY_PORT" \
  -e DRUSE_UPSTREAM="host.docker.internal:$UPSTREAM_PORT" \
  -v "$ROOT/ops/proxy/caddy/Caddyfile:/etc/caddy/Caddyfile:ro" \
  -v "$WORK/certs:/certs:ro" -v "$WORK/logs:/logs" \
  "$DRUSE_CADDY_IMAGE" >/dev/null 2>&1 || fail "the pinned Caddy did not start"

docker inspect "$CADDY" --format '{{json .NetworkSettings.Ports}}' >"$OUT/raw/proxy-port-bindings.json" 2>/dev/null
python3 - "$OUT/raw/proxy-port-bindings.json" <<'PY' || fail "K2 FAILED: the pinned proxy is published on a non-loopback address"
import json, sys
ports = json.load(open(sys.argv[1])) or {}
bad = [(p, b) for p, bs in ports.items() for b in (bs or []) if b.get("HostIp") not in ("127.0.0.1", "::1")]
if bad:
    print("non-loopback publish:", bad, file=sys.stderr)
    sys.exit(1)
if not ports:
    print("no published ports recorded; containment cannot be asserted from an empty observation", file=sys.stderr)
    sys.exit(1)
PY

for _ in $(seq 1 200); do
  openssl s_client -connect "127.0.0.1:$PROXY_PORT" -servername proxy.test \
    -CAfile "$WORK/certs/ca.pem" -verify_return_error </dev/null >/dev/null 2>&1 && break
  sleep 0.1
done

# The shadow itself.
DRUSE_SHADOW_CA="$WORK/certs/ca.pem" \
DRUSE_SHADOW_PROXY_PORT="$PROXY_PORT" \
DRUSE_SHADOW_SECONDS="$SECONDS_TO_RUN" \
DRUSE_SHADOW_RATE="${DRUSE_SHADOW_RATE:-40}" \
DRUSE_SHADOW_SEED="${DRUSE_SHADOW_SEED:-20260803}" \
python3 "$ROOT/ops/canary/shadow_replay.py" >"$OUT/raw/driver.json" 2>"$OUT/raw/driver.err"
test -s "$OUT/raw/driver.json" || { cat "$OUT/raw/driver.err" >&2; fail "the shadow driver produced no report"; }

kill "$PEER_WATCH_PID" 2>/dev/null
wait "$PEER_WATCH_PID" 2>/dev/null

# K1b, evaluated. The proxy reaches the host through the docker bridge, so its
# peer address is the bridge's, not loopback.
PROXY_PEER="$(docker inspect "$CADDY" --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' 2>/dev/null)"
sort -u "$WORK/peers.txt" 2>/dev/null >"$OUT/raw/candidate-peers.txt" || : >"$OUT/raw/candidate-peers.txt"
K1B_FOREIGN="$(
  awk -F: -v bridge="${PROXY_PEER:-172.17.0.1}" '
    { addr = $1 }
    addr == "127.0.0.1" || addr == "[::1]" { next }
    addr == bridge { next }
    # The container side of the bridge, whatever address it drew.
    addr ~ /^172\.1[6-9]\./ || addr ~ /^172\.2[0-9]\./ || addr ~ /^172\.3[0-1]\./ { next }
    { print addr }
  ' "$OUT/raw/candidate-peers.txt" | sort -u
)"

sleep 1
# The access log is K3's only input, so where it is and whether it exists are
# recorded rather than assumed. A missing log makes containment `unproven`, and
# an operator seeing that needs to know whether the file was empty or the mount
# was wrong.
docker exec "$CADDY" ls -la /logs >"$OUT/raw/proxy-log-dir.txt" 2>&1 || true
# `docker cp`, not `cp`. Caddy runs as root in the container and writes the
# access log 0600 root:root, and the bind mount carries that ownership straight
# to the host — so an unprivileged `cp` cannot read it. It failed silently, K3
# reported `proxy_access_log=MISSING`, and the containment claim was unproven for
# a reason that had nothing to do with containment. The daemon can read it.
docker cp "$CADDY:/logs/access.json" "$OUT/raw/proxy-access.json" >/dev/null 2>&1 ||
  echo "SHADOW: could not retrieve the proxy access log; K3 will report it" >&2
docker logs "$CADDY" >"$OUT/raw/caddy.log" 2>&1
cp "$WORK/candidate.log" "$OUT/raw/candidate.log" 2>/dev/null || true
cp "$ROOT/ops/proxy/caddy/Caddyfile" "$OUT/config/Caddyfile"

# K3. The reconciliation. This is the claim; the two above are the fence.
python3 "$ROOT/ops/canary/containment_check.py" \
  "$OUT/raw/driver.json" "$OUT/raw/proxy-access.json" >"$OUT/analysis/containment.txt"
K3_RC=$?

{
  echo "utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
  echo "working_tree_dirty_files=$(git -C "$ROOT" status --porcelain | wc -l)"
  echo "candidate=tests/r1-real-proxy/server"
  echo "candidate_sha256=$CANDIDATE_SHA"
  echo "caddy_image=$DRUSE_CADDY_IMAGE"
  echo "odin=$("$ODIN" version 2>&1 | head -n 1)"
  echo "upstream_port=$UPSTREAM_PORT"
  echo "proxy_publish=127.0.0.1:$PROXY_PORT"
  echo "shadow_seconds=$SECONDS_TO_RUN"
  echo "k1_candidate_listen_address=$K1_BIND"
  echo "k1_note=web.serve takes no bind address; a wildcard listen is the framework's only option and is recorded, not asserted"
  echo "k1b_foreign_peers=$(printf '%s' "${K1B_FOREIGN:-none}" | tr '\n' ' ')"
  echo "k1b_peer_observation=$( [[ -z "$K1B_FOREIGN" ]] && echo pass || echo fail)"
  echo "k2_proxy_published_to_loopback_only=pass"
  echo "k3_accounting_closed=$( ((K3_RC == 0)) && echo pass || echo fail)"
} >"$OUT/manifest.txt"

if [[ -n "$K1B_FOREIGN" ]]; then
  echo "SHADOW: K1b FAILED — a peer that is neither the proxy nor loopback talked to the candidate: $K1B_FOREIGN" >&2
  K3_RC=1
fi

(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)

echo "shadow evidence written to $OUT" >&2
exit "$K3_RC"
