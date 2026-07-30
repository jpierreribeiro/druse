# F-003 — accept starvation / event-loop wedge under sustained handler-lane saturation

Date: 2026-07-23
Scope: authorized testing. Method: source review + targeted liveness probes
(`/tmp/attacklab/liveness_probe2.py`). No fix proposed (report only).
Component: `vendor/odin-http/server.odin` (WP71 bounded-concurrency lane
machinery), interacting with slow application handlers.
Severity: HIGH availability — remote, unauthenticated: a modest number of
concurrent requests to any slow endpoint wedges the server into not accepting
new connections, and it does not recover on its own.

## Summary

While every synchronous Handler lane is occupied, NO lane has a pending
`accept`. New connections pile up in the kernel listen backlog. Under
sustained load against a slow route the server reaches a state where all
worker threads spin in their event loop (`R` state, `wchan=0`) yet the
backlog only grows and fresh connections time out — a wedge, not mere
queueing delay. Observed to persist for > 40 s after the load stops, with the
backlog still climbing (54 → 62); no spontaneous recovery.

## Mechanism (from source)

Each `Server_Thread` (lane) holds at most one pending accept in `td.accept`.

- `on_accept` (server.odin:608): on a successful accept, the lane re-arms
  `td.accept = nbio.accept_poly(...)` ONLY if `!td.handler_active` (line 627).
- `handler_lane_enter` (server.odin:696): when a request enters synchronous
  application code, it CANCELS the lane's pending accept
  (`nbio.remove(td.accept)`, line 710) and sets `handler_active = true`.
  It is not re-armed here.
- `handler_lane_leave` (server.odin:728): re-arms the accept ONLY when the
  handler returns (line 733-735).

Consequence: with `thread_count` lanes (7 worker + 1 = 8 here), the instant
all lanes are inside a Handler there are ZERO pending accepts process-wide.
The listen socket keeps a backlog (default 1000+), so clients still complete
the TCP handshake but are never accepted. Health checks, new clients, and
load-balancer probes all stall.

Why it wedges rather than recovers: recovery depends on a lane returning
from its Handler and calling `handler_lane_leave`. Under a continuous trickle
of slow requests (a single-digit number of clients re-issuing a slow route,
or one RST/disconnect pattern that re-queues work), lanes are re-occupied
before they can re-arm, so the no-accept window is continually renewed. The
observed steady state is all threads running but none accepting — the event
loop ticks, the backlog grows.

## Reproduction (minimal, no flood)

Target app has `GET /slow` sleeping 300 ms. Drive 12 concurrent clients
repeatedly hitting `/slow`, then time one fresh connection:

    python3 /tmp/attacklab/liveness_probe2.py 12

Observed:

    probe0: FAILED after 5005ms: timed out
    probe1: FAILED after 5005ms: timed out
    ...  (health-check connects never accepted)

Server state at that moment: 8 threads, all `R`, listen backlog 54 and
growing; 6 s later still refusing (rc=28 timeout); 40 s later backlog 62,
still not accepting. Process never crashes and never logs.

With fewer concurrent slow clients (<= lane count) the server answers
normally (connect 0 ms), confirming the threshold is lane saturation, not
raw connection count.

## Impact

- Availability: any application with a slow/blocking route can be taken
  offline by a small, cheap, unauthenticated client pool — far below what
  `max_connections` or body limits would flag.
- Stealth: no crash, no error log, no ASan event. Monitoring that only
  checks "process alive" sees a healthy server; only a real request reveals
  the outage.
- Interaction with F-002 fix: the F-002 fix (refuse contended dispatch with
  503) does not cause this — the wedge is in the vendored lane machinery and
  predates it (on the unfixed code the same saturation first triggered the
  F-002 UAF). The 503 path makes the refusal visible to the refused client,
  but the underlying no-accept window is unchanged.

## Root-cause note for whoever fixes it

The design ties "one pending accept per lane" to "lane not in a Handler",
so admission capacity collapses to zero exactly when the server is busiest.
Any fix has to keep at least one pending accept alive independent of Handler
occupancy (e.g. a dedicated accept lane, or re-arming accept before/while a
Handler runs rather than only after it returns). This is vendored odin-http
code, so it is the same report-upstream question as F-001; unlike F-001 the
behaviour also depends on uruquim's WP71 lane-enter/leave patch (PATCH 13),
so the reproducer and analysis belong to this repo even if the accept loop
is upstream's.

## Evidence artifacts

- Probe: `/tmp/attacklab/liveness_probe2.py`
- Prior heavy-load run (F-002 validation) showing the same wedge after an
  RST flood: `/tmp/attacklab/fix3_rec.log` (empty; server wedged, no crash).
- Related: F-002 report (docs/reports/2026-07-23-security-f001-f002.md),
  "Known remaining issue" section.
