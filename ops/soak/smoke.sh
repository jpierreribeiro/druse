#!/usr/bin/env bash
# Host smoke for upload, stream and proxy — R2-WP02, run AFTER preflight.sh and
# BEFORE any load is offered.
#
#   usage: smoke.sh [REPORT_PATH]
#
# WHY. `preflight.sh` reads counters, tools, limits and topology. Every one of
# those is a property of the host at rest, and none of them proves that the three
# hard paths of the supported profile work on this machine: a body spooled to
# this filesystem, a response held open across the pinned reverse proxy, and TLS
# terminated in front of both. R2-restricted-production.md §3 puts the smoke in
# the preflight list for that reason, and the acceptance is blunt: a host that
# passes the preflight and fails the smoke is not a qualified host.
#
# THREE LEGS, AND NONE OF THEM MAY BE SKIPPED.
#
#   upload  a body over `max_body` is spooled to disk and read back with its
#           CHECKSUM matching, plus a body under it that must NOT spool;
#   stream  a detached stream delivers every frame, and delivers them
#           INCREMENTALLY — a buffered stream arrives complete and looks
#           identical in the body alone;
#   proxy   both of the above again through the pinned Caddy of
#           ops/proxy/caddy/, over TLS, which is the only supported edge
#           (docs/supported-profile.md).
#
# A missing tool is a REFUSAL, never a skipped leg. That rule is INS-013 in this
# repository's own history: one absent optional tool produced a clean twelve-hour
# artefact with no telemetry in it, and it graded PASS. A smoke that reports
# "2 of 3 legs, docker unavailable" is the same artefact.
#
# Exit 0 means all three legs are green on this host. Everything learned is
# written to REPORT_PATH (default: stdout) either way.
set -uo pipefail

SOAK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SOAK/../.." && pwd)"

REPORT="${1:-/dev/stdout}"
SERVER_CPUS="${DRUSE_SOAK_SERVER_CPUS:-0-3}"
ORIGIN_PORT="${DRUSE_SOAK_SMOKE_PORT:-18081}"
PROXY_PORT="${DRUSE_SOAK_SMOKE_PROXY_PORT:-18443}"

# The smoke is meant to run on a host the preflight has already qualified. It
# can be run on one that failed — that is how the instrument itself is exercised
# — but the artefact then SAYS SO, in a line a later reader cannot miss, because
# a green smoke on an unqualified host is a fact about the smoke and not about
# the host.
ALLOW_UNQUALIFIED="${DRUSE_SOAK_SMOKE_ALLOW_UNQUALIFIED:-0}"

STREAM_FRAMES=10
SMALL_BODY_BYTES=1024   # under the server's 4 KiB max_body
LARGE_BODY_BYTES=65536  # over it

problems=()
notes=()
note() { notes+=("$1"); }
problem() { problems+=("$1"); }

WORK="$(mktemp -d -t druse-smoke-XXXXXXXX)"
CADDY_NAME="druse-smoke-caddy-$$"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -TERM "$SERVER_PID" 2>/dev/null
    for _ in $(seq 1 100); do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$SERVER_PID" 2>/dev/null
  fi
  docker rm -f "$CADDY_NAME" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT

emit_report() {
  {
    echo "smoke_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "hostname=$(hostname 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srmo)"
    echo "server_cpus=$SERVER_CPUS"
    for line in "${notes[@]}"; do echo "$line"; done
    if (( ${#problems[@]} == 0 )); then
      echo "smoke=pass"
    else
      echo "smoke=fail"
      for line in "${problems[@]}"; do echo "problem=$line"; done
    fi
  } >"$REPORT"
}

finish() {
  emit_report
  if (( ${#problems[@]} > 0 )); then
    echo "SMOKE FAILED — this host is not qualified to run the campaign:" >&2
    for line in "${problems[@]}"; do echo "  - $line" >&2; done
    exit 1
  fi
  echo "smoke: upload, stream and proxy are green on this host" >&2
  exit 0
}

# --- 0. the host was qualified first -----------------------------------------
if bash "$SOAK/preflight.sh" "$WORK/preflight.txt" >/dev/null 2>&1; then
  note "preflight=pass"
else
  note "preflight=fail"
  if [[ "$ALLOW_UNQUALIFIED" == "1" ]]; then
    note "smoke_on_unqualified_host=yes (DRUSE_SOAK_SMOKE_ALLOW_UNQUALIFIED=1) — a green result below is a fact about this SCRIPT, not a qualified host"
    while IFS= read -r line; do note "preflight_$line"; done \
      < <(grep '^problem=' "$WORK/preflight.txt" 2>/dev/null)
  else
    problem "the preflight refuses this host; the smoke runs after qualification, not instead of it (set DRUSE_SOAK_SMOKE_ALLOW_UNQUALIFIED=1 to exercise the smoke anyway, and the report will say so)"
    finish
  fi
fi

# --- 1. tools ----------------------------------------------------------------
for tool in curl python3 openssl docker sha256sum; do
  command -v "$tool" >/dev/null 2>&1 ||
    problem "$tool is not installed and one of the three legs depends on it; a missing tool is a refusal, not a skipped leg"
done
docker info >/dev/null 2>&1 ||
  problem "the docker daemon is unavailable and the proxy leg is the supported edge (docs/supported-profile.md); it cannot be dropped"
(( ${#problems[@]} == 0 )) || finish

# --- 2. build the smoke server -----------------------------------------------
# The four-branch compiler chain, copied from build/check_soak_controls.sh
# rather than shortened: CI exports DRUSE_ODIN_BIN and puts nothing on PATH, a
# workstation does the opposite, and a gate that assumed either went red about a
# compiler that was present under another name.
if test -n "${DRUSE_COMPILER:-}"; then
  ODIN="$DRUSE_COMPILER"
elif test -n "${DRUSE_ODIN_BIN:-}"; then
  ODIN="$DRUSE_ODIN_BIN"
elif command -v odin >/dev/null 2>&1; then
  ODIN="$(command -v odin)"
elif test -x /tmp/druse-toolchain/odin; then
  ODIN=/tmp/druse-toolchain/odin
else
  problem "no Odin compiler: set DRUSE_ODIN_BIN or put odin on PATH"
  finish
fi
ODIN="$(readlink -f "$ODIN")"
note "odin=$ODIN"
note "odin_version=$("$ODIN" version 2>&1 | head -n 1)"

mkdir -p "$WORK/bin" "$WORK/spool" "$WORK/certs"
if ! env ODIN_ROOT="$(cd "$(dirname "$ODIN")" && pwd)" \
     "$ODIN" build "$SOAK/smoke-server" -collection:druse="$REPO" \
     -o:speed -out:"$WORK/bin/smoke-server" >"$WORK/build.log" 2>&1; then
  cat "$WORK/build.log" >&2
  problem "ops/soak/smoke-server does not build on this host"
  finish
fi
note "smoke_server_sha256=$(sha256sum "$WORK/bin/smoke-server" | awk '{print $1}')"

# --- 3. start it, pinned where the campaign's server will be pinned -----------
if command -v taskset >/dev/null 2>&1; then
  taskset -c "$SERVER_CPUS" "$WORK/bin/smoke-server" "$ORIGIN_PORT" "$WORK/spool" \
    >"$WORK/server.log" 2>&1 &
else
  problem "taskset is not installed; the smoke cannot run the server where the campaign will"
  finish
fi
SERVER_PID=$!

ready=0
start_ns="$(date +%s%N)"
for _ in $(seq 1 200); do
  if curl --noproxy '*' -fsS --max-time 1 "http://127.0.0.1:$ORIGIN_PORT/health" >/dev/null 2>&1; then
    ready=1; break
  fi
  kill -0 "$SERVER_PID" 2>/dev/null || break
  sleep 0.1
done
if (( ready == 0 )); then
  cat "$WORK/server.log" >&2
  problem "the smoke server never became ready on port $ORIGIN_PORT (see server.log)"
  finish
fi
# Recorded, not asserted. The restart half of the RTO in a campaign's SLO is
# drain time plus start-to-ready, and start-to-ready has never been measured on
# a target host — this is the cheapest honest place to obtain it. The polling
# interval is 100 ms, so the figure is an upper bound with that granularity and
# includes one curl round trip; it is not a startup benchmark.
note "time_to_ready_ms=$(( ( $(date +%s%N) - start_ns ) / 1000000 )) (100 ms poll granularity, upper bound)"
note "origin_port=$ORIGIN_PORT"

# --- bodies, and the checksum the server must agree with ---------------------
# Deterministic content, and the expected FNV-1a computed HERE. The server
# computes the same hash over what it read off the spool; comparing sizes only
# would accept a truncated-and-padded or reordered body, which is exactly the
# class of filesystem or quota fault this leg is looking for.
python3 - "$WORK/large.bin" "$LARGE_BODY_BYTES" <<'PY'
import sys
path, n = sys.argv[1], int(sys.argv[2])
open(path, "wb").write(bytes((i * 31 + 7) & 0xFF for i in range(n)))
PY
head -c "$SMALL_BODY_BYTES" /dev/zero | tr '\0' 'a' >"$WORK/small.bin"

EXPECTED_SUM="$(python3 - "$WORK/large.bin" <<'PY'
import sys
h = 14695981039346656037
for b in open(sys.argv[1], "rb").read():
    h = ((h ^ b) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
print(format(h, "x"))
PY
)"
EXPECTED_BODY="size=$LARGE_BODY_BYTES sum=$EXPECTED_SUM"
note "expected_upload_reply=$EXPECTED_BODY"

# upload_leg LABEL CURL-ARGS... -- runs both bodies against one endpoint.
upload_leg() {
  local label="$1"; shift
  local over under

  over="$("$@" --data-binary "@$WORK/large.bin" 2>/dev/null)"
  if [[ "$over" == "$EXPECTED_BODY" ]]; then
    note "${label}_upload_spooled=ok ($over)"
  else
    problem "$label: a $LARGE_BODY_BYTES-byte body did not come back off the spool intact — expected '$EXPECTED_BODY', got '$over'"
  fi

  under="$("$@" --data-binary "@$WORK/small.bin" 2>/dev/null)"
  if [[ "$under" == "buffered" ]]; then
    note "${label}_upload_buffered=ok"
  else
    # Both directions are asserted. A server that spooled EVERYTHING would pass
    # the check above and would have changed the buffered path for every
    # request, which is the thing keeping the soak candidate unmodified.
    problem "$label: a $SMALL_BODY_BYTES-byte body under max_body should have taken the buffered path and answered 'buffered', got '$under'"
  fi
}

# stream_leg LABEL URL [CA-FILE HOST:PORT:ADDR] — frames AND their arrival times.
#
# The count alone cannot distinguish a stream from a buffered response: both
# deliver ten frames. The proxy leg exists precisely because a reverse proxy
# that buffers turns a stream into a slow 200, so the arrival of the FIRST frame
# well before the LAST is the assertion that matters.
stream_leg() {
  local label="$1" url="$2" cafile="${3:-}" resolve="${4:-}"
  local out
  out="$(python3 - "$url" "$cafile" "$resolve" "$STREAM_FRAMES" <<'PY'
import socket, ssl, sys, time
from urllib.parse import urlsplit

url, cafile, resolve, want = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
parts = urlsplit(url)
host, port = parts.hostname, parts.port
connect_host, connect_port = host, port
if resolve:
    rhost, rport, raddr = resolve.split(":")
    connect_host, connect_port = raddr, int(rport)

started = time.monotonic()
sock = socket.create_connection((connect_host, connect_port), timeout=15)
if parts.scheme == "https":
    ctx = ssl.create_default_context(cafile=cafile or None)
    sock = ctx.wrap_socket(sock, server_hostname=host)
sock.sendall(
    f"GET {parts.path} HTTP/1.1\r\nHost: {host}\r\nAccept: text/event-stream\r\n"
    "Connection: close\r\n\r\n".encode()
)
sock.settimeout(15)

buf, frames = b"", []
while True:
    try:
        chunk = sock.recv(4096)
    except socket.timeout:
        break
    if not chunk:
        break
    buf += chunk
    # Stamp the moment each frame's terminator lands, not the moment the whole
    # body is parsed: the timing is the evidence.
    while b"\n\n" in buf:
        head, buf = buf.split(b"\n\n", 1)
        if b"frame-" in head:
            frames.append(time.monotonic() - started)
sock.close()

status = "unknown"
print(f"frames={len(frames)} want={want}")
if frames:
    print(f"first_frame_s={frames[0]:.3f} last_frame_s={frames[-1]:.3f}")
    print(f"spread_s={frames[-1] - frames[0]:.3f}")
PY
)" || true

  local frames spread
  frames="$(sed -n 's/^frames=\([0-9]*\).*/\1/p' <<<"$out")"
  spread="$(sed -n 's/^spread_s=//p' <<<"$out")"
  while IFS= read -r line; do
    [[ -n "$line" ]] && note "${label}_stream_$line"
  done <<<"$out"

  if [[ "$frames" != "$STREAM_FRAMES" ]]; then
    problem "$label: the stream delivered ${frames:-0} of $STREAM_FRAMES frames"
    return
  fi
  # The producer sleeps 50 ms between frames, so nine gaps are ~450 ms. Half of
  # that is the threshold: comfortably above scheduler noise and far below what
  # a buffering hop would collapse to (every frame within a few milliseconds of
  # the last, because they all arrive together).
  if awk -v s="${spread:-0}" 'BEGIN { exit !(s > 0.2) }'; then
    note "${label}_stream_incremental=ok"
  else
    problem "$label: all $STREAM_FRAMES frames arrived within ${spread:-0}s of each other — the response was buffered somewhere in the path, which is a stream in body only"
  fi
}

# --- 4. LEG 1 and LEG 2 — direct ---------------------------------------------
upload_leg "direct" curl --noproxy '*' -sS --max-time 30 \
  -X POST "http://127.0.0.1:$ORIGIN_PORT/upload" \
  -H 'Content-Type: application/octet-stream'
stream_leg "direct" "http://127.0.0.1:$ORIGIN_PORT/stream"

# --- 5. LEG 3 — through the pinned proxy -------------------------------------
# The image is the one pinned for R1's real-proxy contract, digest and all. A
# different proxy is a different supported edge and would need its own campaign.
IMAGE_ENV="$REPO/ops/proxy/caddy/image.env"
CADDYFILE="$REPO/ops/proxy/caddy/Caddyfile"
if [[ ! -r "$IMAGE_ENV" || ! -r "$CADDYFILE" ]]; then
  problem "ops/proxy/caddy/ is missing; the supported edge cannot be started"
  finish
fi
# shellcheck disable=SC1090
. "$IMAGE_ENV"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=druse-smoke-ca' \
  -keyout "$WORK/certs/ca-key.pem" -out "$WORK/certs/ca.pem" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes \
  -subj '/CN=proxy.test' -addext 'subjectAltName=DNS:proxy.test' \
  -keyout "$WORK/certs/server-key.pem" -out "$WORK/certs/server.csr" >/dev/null 2>&1
openssl x509 -req -days 1 -in "$WORK/certs/server.csr" \
  -CA "$WORK/certs/ca.pem" -CAkey "$WORK/certs/ca-key.pem" -CAcreateserial \
  -copy_extensions copy -out "$WORK/certs/server.pem" >/dev/null 2>&1
test -s "$WORK/certs/server.pem" || { problem "the smoke could not mint a certificate for the proxy leg"; finish; }

mkdir -p "$WORK/logs"
chmod 0777 "$WORK/logs"
note "caddy_image=$DRUSE_CADDY_IMAGE"
if ! docker run -d --name "$CADDY_NAME" \
    --platform "$DRUSE_CADDY_PLATFORM" \
    --add-host host.docker.internal:host-gateway \
    -p "127.0.0.1:$PROXY_PORT:$PROXY_PORT" \
    -e DRUSE_PROXY_PORT="$PROXY_PORT" \
    -e DRUSE_UPSTREAM="host.docker.internal:$ORIGIN_PORT" \
    -v "$CADDYFILE:/etc/caddy/Caddyfile:ro" \
    -v "$WORK/certs:/certs:ro" \
    -v "$WORK/logs:/logs" \
    "$DRUSE_CADDY_IMAGE" >"$WORK/docker.log" 2>&1; then
  cat "$WORK/docker.log" >&2
  problem "the pinned Caddy container did not start"
  finish
fi
note "caddy_image_id=$(docker image inspect --format '{{.Id}}' "$DRUSE_CADDY_IMAGE" 2>/dev/null || echo unknown)"

proxy_up=0
for _ in $(seq 1 200); do
  if openssl s_client -connect "127.0.0.1:$PROXY_PORT" -servername proxy.test \
       -CAfile "$WORK/certs/ca.pem" -verify_return_error </dev/null >/dev/null 2>&1; then
    proxy_up=1; break
  fi
  sleep 0.1
done
if (( proxy_up == 0 )); then
  docker logs "$CADDY_NAME" >&2 2>&1
  problem "the proxy never terminated TLS on port $PROXY_PORT"
  finish
fi

upload_leg "proxy" curl --noproxy '*' -sS --max-time 30 \
  --cacert "$WORK/certs/ca.pem" --resolve "proxy.test:$PROXY_PORT:127.0.0.1" \
  -X POST "https://proxy.test:$PROXY_PORT/upload" \
  -H 'Content-Type: application/octet-stream'
stream_leg "proxy" "https://proxy.test:$PROXY_PORT/stream" \
  "$WORK/certs/ca.pem" "proxy.test:$PROXY_PORT:127.0.0.1"

# --- 6. the server survived all of it ----------------------------------------
if kill -0 "$SERVER_PID" 2>/dev/null; then
  note "server_alive_after_smoke=yes"
else
  problem "the smoke server died during the run; see server.log"
fi

# Spool hygiene. The upload contract is that the file is deleted at request
# teardown unless the handler persists it, and a host that leaks one spool per
# upload leaks one per request for twelve hours.
leftover="$(find "$WORK/spool" -type f 2>/dev/null | wc -l)"
note "spool_files_left=$leftover"
(( leftover == 0 )) ||
  problem "$leftover spool file(s) survived the smoke; teardown is supposed to delete every upload it did not hand to the application"

finish
