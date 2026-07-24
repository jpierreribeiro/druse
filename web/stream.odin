// WP96 — the public streaming surface: the fewest concepts that express open,
// bounded send and close (spec §5). Five application symbols:
//
//   Stream        — an opaque, stale-safe value token. Copyable, holds no
//                   pointer into framework memory; a token for a closed or
//                   reused stream refuses.
//   stream        — open a detached response from a Handler, then RETURN. The
//                   response outlives the Context; later code sends on the token.
//   Stream_Send   — the closed result of a bounded send {Sent, Full, Closed}.
//   stream_send   — enqueue bounded output from ANY thread. Never blocks; a full
//                   queue is Sent-refused (Full), never waited on.
//   stream_close  — end the stream. Idempotent.
//
// This is opt-in and adds no concept to ordinary buffered endpoints (G7-8): a
// Handler that never calls `stream` links none of the pump. Names are frozen by
// the Phase-7 freeze (WP101); the mechanism they cover is the WP86-evidenced
// candidate C, private in `web/internal/stream` and reached only through the
// transport boundary — the core still names no backend or stream type.
package web

// uruquim:file application

import transport "uruquim:web/internal/transport"

// Stream is a value the application holds and passes to `stream_send` /
// `stream_close`. It carries only a stale-safe identity, so a copy retained
// past the stream's life targets nothing: the send or close refuses.
Stream :: struct {
	private: Stream_Handle,
}

@(private)
Stream_Handle :: struct {
	slot:       i32,
	generation: u64,
	live:       bool, // false for the zero value / a failed open
}

// Stream_Send is the closed outcome of a bounded send. There is no fourth
// state: a stale token collapses to Closed, because from the application's
// view a reused-slot stream and a closed one are equally "not mine".
Stream_Send :: enum {
	Sent, // copied into stream-owned storage and queued for the owner lane
	Full, // the bounded queue refused it; nothing waited, nothing was dropped
	Closed, // the stream is closed, drained, or this token is stale
}

// stream opens a detached response bound to the current request's connection
// and returns a token. After a successful open the Handler MUST return without
// calling a responder: the response now outlives the Context, and later code
// sends on the token from any thread.
//
// It commits the status/headers exactly once (200, plus whatever the chain —
// `secure_headers`, `cors`, the request id — contributed), then hands the wire
// to the connection-owning lane. `ok` is false when there is no connection to
// detach (the in-memory test transport) or the stream cap is reached; the
// Handler then falls back to an ordinary buffered response.
stream :: proc(ctx: ^Context, content_type := "") -> (s: Stream, ok: bool) {
	if ctx.private.stream_detached || ctx.private.stream_exchange == nil {
		return Stream{}, false
	}
	slot, generation, opened := transport.stream_begin(ctx.private.stream_exchange)
	if !opened {
		return Stream{}, false
	}
	// Commit the stream's head: 200 with the chain's finished headers and no
	// body. `serve_dispatch` reads `stream_detached` and tells the adapter to
	// frame it chunked; the ADR-008 single-commit guard still applies, so a
	// Handler that also calls a responder cannot append a second envelope.
	//
	// `content_type` is the ONE header a stream's protocol must set itself and
	// the chain cannot know — `text/event-stream` for SSE, `application/json`
	// for a chunked JSON feed. Empty (the default) sets none, so an existing
	// caller is unchanged and a proxy-only stream carries no media type.
	response_commit(&ctx.private.response, .OK, response_stream_headers(ctx, content_type), nil)
	ctx.private.stream_detached = true
	return Stream{private = Stream_Handle{slot = slot, generation = generation, live = true}}, true
}

// stream_send enqueues bounded output. Callable from any thread — a Handler
// lane, a worker, an application thread. It copies the bytes into stream-owned
// storage, so `data` may be reused immediately. It never blocks: a full queue
// returns Full, and the application chooses whether to retry, drop or coalesce.
stream_send :: proc(s: Stream, data: []u8) -> Stream_Send {
	if !s.private.live {
		return .Closed
	}
	switch transport.stream_push(s.private.slot, s.private.generation, data) {
	case .Sent:
		return .Sent
	case .Full:
		return .Full
	case .Closed:
		return .Closed
	}
	return .Closed
}

// stream_close ends the stream: the owner lane writes the terminating chunk and
// retires the connection. Idempotent — a second close, or a close of a stale
// token, is a safe no-op.
stream_close :: proc(s: Stream) {
	if !s.private.live {
		return
	}
	transport.stream_end(s.private.slot, s.private.generation)
}

// stream_live reports whether this stream is still open and would accept a send
// (corrective WP C4, friction F8-5). It lets an application prune a departed
// subscriber from a registry WITHOUT sending to it — the disconnect signal a
// hub needs that a bare `stream_send` could only give as a side effect. It is
// read-only, safe from any thread, and answers `false` for the zero value, a
// closed/drained stream, or a stale (reused-slot) token — the same "not mine"
// collapse `stream_send` makes. A `true` result is a point-in-time observation:
// the peer may still leave the instant after, which is why a hub also prunes on
// a `Closed` send. On the in-memory test transport (no real connection) it is
// always `false`.
stream_live :: proc(s: Stream) -> bool {
	if !s.private.live {
		return false
	}
	return transport.stream_live(s.private.slot, s.private.generation)
}

// response_stream_headers finishes the framework-owned trailing headers for a
// stream's committed head, exactly as the buffered responders do (so a stream
// carries `secure_headers`, the request id and any chain contribution). It adds
// `content_type` when the caller gave one, and never a Content-Length: the
// adapter frames the body chunked.
@(private)
response_stream_headers :: proc(ctx: ^Context, content_type: string) -> []Header_Pair {
	if len(content_type) > 0 {
		ctx.private.response_headers[0] = Header_Pair {
			name  = CONTENT_TYPE_HEADER_NAME,
			value = content_type,
		}
		return response_headers_finish(ctx, 1)
	}
	return response_headers_finish(ctx, 0)
}
