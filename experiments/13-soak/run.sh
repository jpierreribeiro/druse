#!/usr/bin/env bash
# Experiment 13 — soak and allocator audit. Changes nothing in the tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ODIN="${DRUSE_ODIN_BIN:-}"
if test -z "$ODIN" && command -v odin >/dev/null 2>&1; then ODIN="$(command -v odin)"; fi
if test -z "$ODIN" && test -x /tmp/druse-toolchain/odin; then ODIN=/tmp/druse-toolchain/odin; fi
if test -z "$ODIN"; then echo "EXP13 -> BLOCKED: no Odin toolchain (set DRUSE_ODIN_BIN)." >&2; exit 2; fi

PORT=58700
ROUNDS="${DRUSE_SOAK_ROUNDS:-800}"
CLIENTS=8

TMP="$(mktemp -d -t druse-exp13-XXXXXXXX)"
trap 'rm -rf "$TMP"; pkill -f exp13-server 2>/dev/null || true' EXIT

mkdir -p "$TMP/druse" "$TMP/c"
cp -r "$ROOT/web" "$ROOT/vendor" "$TMP/druse/"
cat >"$TMP/c/main.odin" <<'ODIN'
package main

import "core:fmt"
import web "druse:web"

Reply :: struct {
	ok: bool `json:"ok"`,
	n:  int  `json:"n"`,
}

Echo :: struct {
	name: string `json:"name"`,
}

served: int

work :: proc(ctx: ^web.Context) {
	served += 1
	web.ok(ctx, Reply{ok = true, n = served})
}

// A handler that ALLOCATES — it binds a body into the request arena — because a
// handler that only returns a constant soaks the accept path and nothing else,
// and the arena is where a leak would live.
echo :: proc(ctx: ^web.Context) {
	input: Echo
	if !web.body(ctx, &input) {
		return
	}
	web.created(ctx, input)
}

main :: proc() {
	app := web.app()
	defer web.destroy(&app)
	web.use(&app, web.request_id)
	web.use(&app, web.secure_headers)
	web.get(&app, "/work", work)
	web.post(&app, "/echo", echo)
	fmt.println("up")
	web.serve(&app, 58700)
}
ODIN

env -u ODIN_ROOT "$ODIN" build "$TMP/c" -collection:druse="$TMP/druse" -o:speed \
  -out:"$TMP/exp13-server" >/dev/null 2>&1 || { echo "EXP13: consumer did not build" >&2; exit 1; }

"$TMP/exp13-server" >/dev/null 2>&1 &
PID=$!
for _ in $(seq 1 200); do
  if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then exec 3<&- 3>&-; break; fi
  sleep 0.05
done

rss() { awk '/VmRSS/{print $2}' "/proc/$1/status" 2>/dev/null || echo 0; }

RSS_START="$(rss "$PID")"
echo "# experiment 13 — soak"
echo "# rounds=$ROUNDS clients=$CLIENTS"
echo "# rss_start_kb=$RSS_START"

per=$(( ROUNDS / CLIENTS ))
for _ in $(seq 1 "$CLIENTS"); do
  (
    for _ in $(seq 1 "$per"); do
      curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 "http://127.0.0.1:$PORT/work" || echo 000
      curl -s -o /dev/null -w '%{http_code}\n' --max-time 5 \
        -H 'Content-Type: application/json' -d '{"name":"soak"}' \
        "http://127.0.0.1:$PORT/echo" || echo 000
    done
  ) &
done >"$TMP/codes"
wait

# THE SLOW-CLIENT AND SLOW-WRITER WORKLOADS the plan named by hand. They are the
# reason WP46's deadline exists, so a soak that omitted them would be soaking
# only the easy path.
python3 - "$PORT" <<'PY' >/dev/null 2>&1 || true
import socket, sys, time
port = int(sys.argv[1])
for _ in range(4):
    try:
        s = socket.create_connection(("127.0.0.1", port), 2); s.settimeout(2)
        for b in b"GET /work HTTP/1.1\r\nHost: x\r\n":
            s.send(bytes([b])); time.sleep(0.01)
        s.close()
    except Exception:
        pass
for _ in range(4):
    try:
        s = socket.create_connection(("127.0.0.1", port), 2); s.settimeout(3)
        s.sendall(b"GET /work HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
        time.sleep(0.3)
        s.recv(4096)
        s.close()
    except Exception:
        pass
PY

RSS_END="$(rss "$PID")"
OK="$(grep -c '^200$' "$TMP/codes" 2>/dev/null || true)"
CREATED="$(grep -c '^201$' "$TMP/codes" 2>/dev/null || true)"
BAD="$(grep -cvE '^(200|201)$' "$TMP/codes" 2>/dev/null || true)"

# STILL ANSWERING? The whole point of a soak: a server that completed the load
# and then died has not survived it.
ALIVE=no
if curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PORT/work"; then ALIVE=yes; fi

kill "$PID" 2>/dev/null || true

echo "# rss_end_kb=$RSS_END"
echo "# http_200=$OK http_201=$CREATED other=$BAD"
echo "# still_answering_after_load=$ALIVE"
echo "# rss_growth_kb=$(( RSS_END - RSS_START ))"
echo "#"
echo "# RSS growth is the LEAK SIGNAL and it is a weak one: an allocator that"
echo "# never returns pages shows flat RSS while leaking. What it catches is"
echo "# UNBOUNDED growth, which is the failure that matters."
