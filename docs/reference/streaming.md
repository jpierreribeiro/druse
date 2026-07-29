# Streaming

A response the handler does not buffer whole.

Generated from `build/phase1-public-signatures.txt` and the source. Do
not edit by hand — run `build/gen_reference.py`.

## `stream`

```odin
stream :: proc(ctx: ^Context, content_type := "") -> (s: Stream, ok: bool)
```

stream opens a detached response bound to the current request's connection and returns a token. After a successful open the Handler MUST return without calling a responder: the response now outlives the Context, and later code sends on the token from any thread.

Taught in [`05-recipes/stream-a-response.md`](../guide/05-recipes/stream-a-response.md).

## `Stream`

```odin
Stream :: struct {private: Stream_Handle}
```

Stream is a value the application holds and passes to `stream_send` / `stream_close`. It carries only a stale-safe identity, so a copy retained past the stream's life targets nothing: the send or close refuses.

## `stream_send`

```odin
stream_send :: proc(s: Stream, data: []u8) -> Stream_Send
```

stream_send enqueues bounded output. Callable from any thread — a Handler lane, a worker, an application thread. It copies the bytes into stream-owned storage, so `data` may be reused immediately. It never blocks: a full queue returns Full, and the application chooses whether to retry, drop or coalesce.

Taught in [`05-recipes/stream-a-response.md`](../guide/05-recipes/stream-a-response.md).

## `Stream_Send`

```odin
Stream_Send :: enum {Sent, Full, Closed}
```

Stream_Send is the closed outcome of a bounded send. There is no fourth state: a stale token collapses to Closed, because from the application's view a reused-slot stream and a closed one are equally "not mine".

## `stream_live`

```odin
stream_live :: proc(s: Stream) -> bool
```

stream_live reports whether this stream is still open and would accept a send (corrective WP C4, friction F8-5). It lets an application prune a departed subscriber from a registry WITHOUT sending to it — the disconnect signal a hub needs that a bare `stream_send` could only give as a side effect. It is read-only, safe from any thread, and answers `false` for the zero value, a closed/drained stream, or a stale (reused-slot) token — the same "not mine" collapse `stream_send` makes. A `true` result is a point-in-time observation: the peer may still leave the instant after, which is why a hub …

## `stream_close`

```odin
stream_close :: proc(s: Stream)
```

stream_close ends the stream: the owner lane writes the terminating chunk and retires the connection. Idempotent — a second close, or a close of a stale token, is a safe no-op.
