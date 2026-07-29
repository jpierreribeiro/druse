# Limits and shutdown

**Assumes:** [`context-and-state.md`](context-and-state.md).

What bounds the server, and how it stops.

## Set limits from the default

```odin
	l := web.DEFAULT_LIMITS
	l.max_write_time = 30 * time.Second
	l.max_idle_time  = 60 * time.Second
	web.limits(&app, l)
```

**Start from `DEFAULT_LIMITS`.** Building a `Limits` literal zeroes every field
you did not name, and an application whose limits are three zeros answers `413`
to everything.

Call `web.limits` before you serve.

## The three that are off by default

| Limit | Default | Turn it on because |
|---|---|---|
| `max_write_time` | `0` — off | A slow reader can hold a response write open |
| `max_idle_time` | `0` — off | Idle keep-alive slots are never reclaimed |
| `max_response_bytes` | `0` — off | Nothing bounds what your handler builds |

`max_request_time` **is** on. It bounds arrival, which is the slowloris
defence.

Size the write timeout to your slowest legitimate client, or keep a reverse
proxy's timeouts in front.

## The ones already bounded

`max_body` (4 MiB), `max_request_line`, `max_headers`, `max_connections`,
`reserved_conns`, `max_drain_time`, `max_handlers`, `max_json_nodes`.

`max_json_nodes` bounds the *structure* of a decoded body, not its size. A
small body of deeply nested arrays costs far more to decode than its byte count
suggests.

`reserved_conns` is worth knowing: it holds capacity back so health checks and
shutdown stay reachable when the server is saturated. Size your database pool
below the handler capacity for the same reason — see
[`../02-build-notes/02-database-and-migrations.md`](../02-build-notes/02-database-and-migrations.md).

## Shutdown is yours to wire

```odin
stop        :: proc(a: ^App)
is_draining :: proc(a: ^App) -> bool
```

`web.stop` is thread-safe and signal-safe. It drains within
`Limits.max_drain_time`.

**Druse installs no `SIGTERM` handler.** Your `main` installs one and calls
`web.stop`. See `docs/operations.md` for the pattern.

```odin
	// on SIGTERM:
	web.stop(&app)
	// web.serve returns; deferred destroys run
```

## Readiness during drain

```odin
	if web.is_draining(&app) {
		web.text(ctx, .Service_Unavailable, "draining")
		return
	}
```

Use it in **readiness**, so the load balancer stops sending work before the
process exits.

Never in **liveness**. A draining process is alive, and a supervisor that kills
it mid-drain undoes the whole point.

## What no limit protects you from

A fault in a handler aborts the process — a panic, a failed assertion, an
out-of-bounds index. Odin has no recoverable panic (ADR-020), so no setting
changes this. Run under a supervisor with `Restart=always`, and run more than
one replica.
