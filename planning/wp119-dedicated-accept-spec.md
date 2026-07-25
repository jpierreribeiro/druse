# WP119 — dedicated accept / thread-per-core (Spec Gate)

**Status: SPEC, 2026-07-25.** The flamegraph named WP119 the #1 lever for BOTH CPU and
throughput. This is its Spec Gate: the model, the honest WP71 trade-off, and the
prototype-first validation plan. No framework rewrite until the prototype measures the gain.

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
