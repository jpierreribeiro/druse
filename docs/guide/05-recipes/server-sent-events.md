# Server-sent events

Package `crystals:web/sse`. Built on the core's streaming calls.

For pushing updates to a browser over one long-lived HTTP response. Simpler
than WebSocket, and it reconnects by itself.

## Open, send, and let the response outlive the handler

```odin
handler :: proc(ctx: ^web.Context) {
	s, ok := sse.open(ctx)
	if !ok {
		web.text(ctx, .Service_Unavailable, "no capacity")
		return
	}
	hand_off(s)
	// the handler RETURNS; the response continues
}
```

**Handle `ok = false`.** The stream lane budget can be full. A handler that
ignores it returns without responding and gets the standardized 500.

## Send an event

```odin
	sse.send(s, sse.Event{...})
```

`Send_Result` reports backpressure the same way the core does: retry the same
event, do not advance. See
[`stream-a-response.md`](stream-a-response.md).

`MAX_EVENT_BYTES` bounds one event. Split anything larger, or send a reference
and let the client fetch it.

## Keep the connection alive

```odin
	sse.comment(s, "ping")
```

A comment is a no-op event that proxies count as traffic. Without one, an idle
connection is closed by whatever sits between you and the browser.

## Resume after a reconnect

```odin
	last, ok := sse.last_event_id(ctx)
```

The browser sends `Last-Event-ID` when it reconnects. Read it and resume from
there, or the user misses everything that happened while they were away.

Give every event an id if you want this to work.

## What it costs

Each open stream holds a connection and a lane for as long as it lives. They
are bounded, and refusals are counted in `web.stats()` —
`stream_refused_full`, `stream_refused_budget`, `stream_aborted_slow`.

Watch those counters. Long-lived connections are how a server runs out of
capacity without any request being slow.
