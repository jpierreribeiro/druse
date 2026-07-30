// C4 — corrective WP for friction F8-5: web.stream_live, the disconnect predicate
// a subscriber registry needs to prune a departed client WITHOUT sending to it.
//
// The registry's `is_live` (which the public wrapper reads) is unit-tested here
// against a real Registry — open→live, close→dead, stale generation→dead,
// out-of-range→dead. The public `web.stream_live` wrapper's TRUE path needs a
// real socket (the in-memory transport opens no stream), so its live-over-the-
// wire behaviour is a VPS/socket exercise; the zero-value FALSE path is checked
// here directly.
package test_c4_stream_live

import "core:testing"
import web "druse:web"
import stream "druse:web/internal/stream"

@(test)
c4_is_live_tracks_open_and_close :: proc(t: ^testing.T) {
	r: stream.Registry
	ok := stream.registry_init(&r, stream.Capacity{
		max_streams = 2, max_events_stream = 8, max_bytes_stream = 128,
		max_bytes_total = 1024, tick_progress = 64,
	})
	testing.expect(t, ok)
	defer stream.registry_destroy(&r)

	tok, _ := stream.open(&r, 1)
	testing.expect(t, stream.is_live(&r, tok), "a freshly opened stream is live")

	// A stale generation on the same slot is not live (the reused-slot collapse).
	stale := stream.Token{slot = tok.slot, generation = tok.generation + 1}
	testing.expect(t, !stream.is_live(&r, stale), "a stale generation is not live")

	// An out-of-range slot is not live.
	testing.expect(t, !stream.is_live(&r, stream.Token{slot = 99, generation = 1}), "an out-of-range slot is not live")

	// After close, the token is no longer live.
	testing.expect(t, stream.close(&r, tok), "close succeeds on the open token")
	testing.expect(t, !stream.is_live(&r, tok), "a closed stream is not live")
}

@(test)
c4_public_stream_live_false_for_zero_value :: proc(t: ^testing.T) {
	// The zero-value Stream (a failed open) is never live — the public predicate
	// answers false without touching any registry.
	s: web.Stream
	testing.expect(t, !web.stream_live(s), "the zero-value stream is not live")
}
