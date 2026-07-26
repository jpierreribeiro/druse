# WP119 — dedicated accept / thread-per-core (Spec Gate)

**Status: IMPLEMENTED CANDIDATE, ADOPTION PENDING TWO-BOX GATE, 2026-07-25.**
The original SO_REUSEPORT model below was refuted by its prototype. A second
model — one shared dedicated acceptor plus one connection-affine handoff —
measured 259k req/s at c100 and 283k at c400 while keeping WP71 and the full
fault/conformance gate green. It is recorded after the original spec so the
change in evidence remains visible.

## Why (measured, not assumed)

`perf` of the full framework (`hello_p28`, `/ping`) — the dominant CPU costs are **context
switches (~8%)** and **io_uring_enter/submit overhead**, plus the **p28 accept dance**
(`io_async_cancel` per request). Header parsing (~5%), arena (~2%) are minor. All three top
costs trace to one root: **N threads share ONE listen socket**, so they contend on accept, the
p28 model cancels/re-arms the accept per request to honor WP71, and connections hand off across
threads (context switches). WP119 removes that root.

## The model — SO_REUSEPORT per lane (thread-per-core ingress)

Each lane thread owns its OWN listen socket, all bound to the same `0.0.0.0:port` via
**SO_REUSEPORT** (Linux hashes each incoming connection to one of the sockets). Consequences:
- **No shared listen socket → no accept contention.**
- **No accept-cancel dance** (the p28 `io_async_cancel`/request is gone): a lane about to run a
  synchronous handler simply does not re-arm its own accept; it need not cancel anything,
  because it was never competing for a shared socket.
- **No cross-thread handoff**: the lane that the kernel routed the connection to is the lane
  that accepts, parses, and runs the handler — same core, no context-switch handoff, better
  cache locality. This is the Seastar/Glommio "keep it on one core" principle the research
  endorsed, and it directly attacks the ~8% context-switch cost.

Odin note: `core:net` on Linux does NOT expose SO_REUSEPORT (`_SOCKET_OPTION_REUSE_PORT :: -1`);
set it via raw `linux.setsockopt(fd, SOL_SOCKET, .REUSEPORT, 1)` (proven in the prototype).

## The honest trade-off — the WP71 guarantee

WP71/Patch-13 guarantees: *a new (health) connection is never trapped behind a lane blocked in
a synchronous handler while another lane is free.* Under a shared socket, the p28 dance enforced
this by cancelling a blocked lane's accept so the kernel gave the connection to a free lane.

**SO_REUSEPORT does NOT preserve this strictly.** The kernel hashes each connection to ONE
socket (by 4-tuple); a connection hashed to a blocked lane waits in that lane's backlog rather
than migrating to a free lane. So a health check unlucky enough to hash to a blocked lane waits.
Three ways to reconcile, decided ONLY if the prototype shows the gain justifies it:
1. **Dedicated health listener** — serve `/health/*` from a separate always-non-blocking
   listener/lane, so a blocked worker lane never delays a health check. Honors the *spirit* of
   WP71 (the load balancer never kills the server) without cross-thread handoff. Cheapest.
2. **eBPF reuseport steering** (`ATTACH_REUSEPORT_EBPF`) — a BPF program routes each connection
   to a free lane. Preserves the guarantee fully; most complex.
3. **Accept partial degradation** — under SO_REUSEPORT a blocked lane only delays the ~1/N of
   connections hashed to it, not all; document it and rely on the lane model + 503 admission for
   blocking handlers. Simplest; a real (small) weakening of WP71.

Recommendation pending measurement: option 1 (dedicated health listener) — it keeps the CPU win
and the operational guarantee that actually matters (health checks answer), at low cost.

## Validation plan (prototype-first, the discipline that killed the multishot thesis)

1. **Prototype (done, compiles):** `bench/echo_reuseport` — N-thread echo, SO_REUSEPORT per
   lane, no shared socket, no accept dance. Compare under `perf` on the c5 against the shared-
   socket model (the framework / an echo with a shared accept): **do context switches and
   io_uring_enter overhead drop? does throughput rise toward the 216k/core the single-thread
   echo hit?** If yes → WP119 is validated and worth the framework rewrite. If no → refuted,
   like the multishot thesis, and we stop.
2. **If validated:** rewrite `vendor/odin-http/server.odin` ingress — per-lane REUSEPORT listen
   sockets replacing the shared `s.tcp_sock` + the p28 accept dance in `handler_lane_enter`.
   Reconcile WP71 via the chosen option above. Re-run `check_wp71_controls.sh`,
   `check_c05_controls.sh`, the full suite, and the fasthttp/net-http benchmark ladder.
3. **Success bar:** recover ~241k throughput AND cut CPU (context switches + accept dance) WITH
   wp71/c05 green (via the reconciliation), keeping the 24× latency edge. Then measure vs
   fasthttp — the real ceiling.

## Files
- `bench/echo_reuseport/main.odin` — the prototype (compiles; measure on c5).
- `vendor/odin-http/server.odin` — the ingress to rewrite IF validated (`listen_tcp`,
  `_server_thread_init`, `handler_lane_enter`/`leave`, `on_accept`).
- `planning/perf-netpoller-study-and-architecture.md` — the measured context.

## Implementation record — shared dedicated acceptor

SO_REUSEPORT was not the necessary property. The hot-path property was removing
accept ownership from Handler lanes, so a request no longer cancels and re-arms
an accept before synchronous application dispatch.

The implemented candidate keeps the existing shared listener and adds one
accept event loop. Each accepted connection is assigned once to the
least-loaded Handler lane; the connection then remains on that lane for parse,
dispatch, send, deadlines, and teardown. This preserves strict WP71 because the
acceptor never blocks in application code and does not assign new connections
to a lane whose Handler is active.

The handoff queue is bounded at eight pending callbacks per lane. If the queue
is full, accept pauses with one owned pending socket until a lane consumes a
handoff. If every Handler is active, the acceptor returns the existing complete
503 plus `Retry-After: 1`. This distinction was required by C-03: an unbounded
handoff queue served only 19/59 healthy probes during an RST flood; the bounded
version served 47/58, 46/57, and 45/56 in three runs and recovered 20/20.

Measured on the available one-box c5 rig (`-o:speed`, server cores 0–3, wrk
cores 4–7):

| load | candidate | fasthttp | ratio | candidate p99 | fasthttp p99 |
|---|---:|---:|---:|---:|---:|
| c100 | 259–260k | 278k | 93.3% | 619–625 µs | 1.13 ms |
| c400 | 283k | 290k | 97.9% | 2.46 ms | 2.76 ms |

`io_uring_enter` fell from about 5.03/request to 0.160/request. This both
validates dedicated accept as the throughput lever and removes the measured
case for a multishot scanner rewrite.

Adoption remains pending because the formal two-box/NIC gate is unavailable,
the c100 p99 ratio narrowly missed the pre-registered 50% ceiling, and p99 grew
about 3.9× from c100 to c400 on four server cores. Full results and gate
evidence are in
`docs/reports/2026-07-25-dedicated-accept-throughput.md`.
