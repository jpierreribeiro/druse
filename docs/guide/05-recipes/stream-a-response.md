# Stream a response

**Assumes:** [`../02-build-notes/01-nothing-to-hello.md`](../02-build-notes/01-nothing-to-hello.md).

For a response you cannot buffer whole: progress, a log tail, server-sent
events.

```odin
stream       :: proc(ctx: ^Context, content_type := "") -> (s: Stream, ok: bool)
stream_send  :: proc(s: Stream, data: []u8) -> Stream_Send
stream_live  :: proc(s: Stream) -> bool
stream_close :: proc(s: Stream)
```

## Open, then return

```odin
handler :: proc(ctx: ^web.Context) {
	s, ok := web.stream(ctx)
	if !ok {
		web.text(ctx, .OK, "fell-back")   // streaming was refused
		return
	}
	hand_off(s)
	// The handler RETURNS here. The response outlives this Context.
}
```

**The handler returns immediately.** The `Stream` outlives it, and so does the
response. Do not hold `ctx` after you return.

**Always handle `ok = false`.** Streaming can be refused when the lane budget is
full; answer with a buffered response. A handler that ignores this returns
without responding and gets the standardized 500.

## Send

`stream_send` returns three values, and `Full` is not an error:

| Result | Meaning | Do |
|---|---|---|
| `Sent` | The bytes are queued | Continue |
| `Full` | Backpressure. Nothing was queued | Retry the **same** bytes |
| `Closed` | The client is gone | Stop |

```odin
	for web.stream_send(s, chunk) == .Full {
		time.sleep(time.Millisecond)
	}
```

Retry the same slice: `Full` queued nothing, so advancing your cursor drops
data silently. Stop on `Closed` — retrying it spins forever.

## Close exactly once

```odin
	web.stream_close(s)
```

The response is not complete until you call it. `stream_live` reports whether
the client is still attached, so a long producer can stop early:

```odin
	for web.stream_live(s) {
		// produce and send
	}
	web.stream_close(s)
```

## Server-sent events

Use `crystals:web/sse` rather than framing events by hand. It is built on these
four calls.

## What it costs

Refusals are counted in `web.stats(&app)`: `stream_refused_full`,
`stream_refused_budget` and `stream_aborted_slow`. Watch them — see
[`observe-the-framework.md`](observe-the-framework.md).
