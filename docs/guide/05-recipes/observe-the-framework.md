# See what the framework is doing

**Assumes:** [`../02-build-notes/01-nothing-to-hello.md`](../02-build-notes/01-nothing-to-hello.md).

Two surfaces. One pushes typed failure events; the other is a counter snapshot
you pull.

## Push: one observer, typed events

```odin
observe :: proc(a: ^App, observer: proc(event: Framework_Event))
```

```odin
	web.observe(&app, on_event)
```

**One observer per application.** There is no list to append to.

```odin
Framework_Event :: struct {
	kind:         Framework_Error,
	method:       Method,
	route:        string,
	status:       Status,
	payload_type: typeid,
}
```

`route` is the **registered pattern** — `/users/:id`, never the path a client
sent. That is by construction: nothing request-derived can reach an observer,
so an event cannot leak a user id into your logs.

The nine failures it reports:

```odin
Framework_Error :: enum {
	None, Response_Marshal_Failed, Body_Decode_Failed, Body_Consumed_Twice,
	No_Response_Committed, Invalid_Serve_Port, Serve_Listen_Failed,
	Use_After_Route, Response_Too_Large,
}
```

A closed enum, so counters derived from it are bounded by the enum, not by
traffic.

**`Body_Consumed_Twice` and `No_Response_Committed` are bugs in your code.** The
first means a second `web.body` call decoded nothing; the second means a handler
returned without answering and the standardized 500 went out.

## Pull: counters

```odin
stats :: proc(a: ^App) -> Server_Stats
refused_connections :: proc(a: ^App) -> int
```

Both name the App whose server they describe, so a process running two listeners
reports on each separately rather than on whichever started last.

`Server_Stats` carries ten **running totals** — `refused_connections`,
`saturation_refusals`, `responses_sent`, `response_bytes`, `send_errors`,
`write_deadline_aborts`, `handler_dwell_ns`, `stream_refused_full`,
`stream_refused_budget`, `stream_aborted_slow` — which you difference, and four
**levels and ceilings** — `active_connections`, `handlers_active`,
`handler_capacity`, `connection_capacity` — which you read as they are.

Rising `write_deadline_aborts` means slow clients hitting `Limits.max_write_time`;
rising `refused_connections` means you are at `max_connections`. Rising
`saturation_refusals` means every Handler lane was active and the dedicated
acceptor closed newly accepted sockets before parsing HTTP.

**Alert on `handlers_active / handler_capacity`, not on a flat counter.** Every
running total above is written when work *completes*, so at full lane occupancy
all of them freeze and `Δhandler_dwell_ns / (handler_capacity × wall time)` reads
zero while utilization is one. A saturated server and an idle one draw the same
flat lines; the occupancy level is what separates them.

`handler_capacity` is the lane count the process resolved, which matters because
`max_handlers = 0` is the default and lands on the host's core count.
`connection_capacity` is `max_connections - reserved_conns`, the ceiling
admission actually enforces.

## Do not scrape this over a route

A `/metrics` handler runs on the same Handler lanes as your traffic, so it stops
answering under exactly the pressure you wanted to see — and every failure an
HTTP scrape can produce is also producible by a lost packet, so you cannot tell
saturation from a network problem.

`web.stats` allocates nothing, takes no lock and is safe from any thread. Call
it from a thread that owns no lane and write the result somewhere a sampler
outside the process can read it. `examples/10-config-and-health` has a working
exporter; `ops/monitoring/` has the format, a sampler, alert rules and a
dashboard; `docs/operations.md` §6.0 has the reasoning.

## Draining

```odin
is_draining :: proc(a: ^App) -> bool
```

True after `web.stop`, while in-flight requests finish. Use it so a readiness
endpoint reports unready before the process exits and the load balancer stops
sending work. Liveness must **not** use it: a draining process is alive.

## Prometheus

`crystals:web/metrics` renders both surfaces as one exposition — `install`
attaches it to the observer surface, `routes` gives you a router to mount. Its
output is bounded by the enum, and the only event datum it reads is `kind`.
