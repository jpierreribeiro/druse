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
stats :: proc() -> Server_Stats
refused_connections :: proc() -> int
```

`Server_Stats` carries `refused_connections`, `responses_sent`,
`response_bytes`, `send_errors`, `write_deadline_aborts`, `lane_collisions`,
`stream_refused_full`, `stream_refused_budget` and `stream_aborted_slow`.

Rising `write_deadline_aborts` means slow clients hitting
`Limits.max_write_time`; rising `refused_connections` means you are at
`max_connections`.

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
