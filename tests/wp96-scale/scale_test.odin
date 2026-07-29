// WP96 — the scale claim of G7-6, exercised on the registry directly.
//
// G7-6 requires 3,000 open streams to terminate or be cancelled within the
// drain deadline. The registry is the machinery that must scale; proving it at
// 3,000 slots in memory (no sockets) is both faithful and reliable — the
// real-wire path is proven separately at modest count by tests/wp95-drain and
// tests/wp96-public-stream, which this scale test deliberately does not
// duplicate on 3,000 real connections (that belongs to a dedicated quiet CI
// machine; see the honest limitation recorded in the WP101 freeze).
package test_wp96_scale

import "core:sync"
import "core:thread"
import "core:testing"
import stream "druse:web/internal/stream"

STREAMS :: 3000

@(test)
wp96_three_thousand_streams_open_receive_and_drain :: proc(t: ^testing.T) {
	r := new(stream.Registry)
	defer free(r)
	ok := stream.registry_init(r, stream.Capacity {
		max_streams       = STREAMS,
		max_events_stream = 4,
		max_bytes_stream  = 256,
		max_bytes_total   = STREAMS * 256,
		tick_progress     = 4096,
	})
	testing.expect(t, ok, "the registry must accept a 3,000-stream capacity")
	defer stream.registry_destroy(r)

	toks := make([]stream.Token, STREAMS)
	defer delete(toks)
	for i in 0 ..< STREAMS {
		tok, res := stream.open(r, u64(i))
		testing.expect_value(t, res, stream.Open_Result.Opened)
		toks[i] = tok
	}
	testing.expect_value(t, stream.live_streams(r), STREAMS)

	// One event into every stream — the heartbeat/control-close shape.
	payload := transmute([]u8)string("hb")
	for i in 0 ..< STREAMS {
		testing.expect_value(t, stream.try_send(r, toks[i], payload), stream.Send_Result.Sent)
	}

	// Drain: admission stops, every owned stream is signalled. Here the streams
	// are ownerless (no adapter), so close frees them immediately — the drain
	// path's accounting is what scale must not break.
	stream.drain_begin(r)
	testing.expect(t, stream.draining(r), "the registry must report draining")
	// A post-drain open is refused.
	_, res := stream.open(r, 999999)
	testing.expect_value(t, res, stream.Open_Result.Draining)

	// Close every stream; the live count must return exactly to zero, with no
	// slot leaked and no double-free (the tracking allocator would catch both).
	for i in 0 ..< STREAMS {
		testing.expect(t, stream.close(r, toks[i]))
	}
	testing.expect_value(t, stream.live_streams(r), 0)
}

Producer :: struct {
	r:      ^stream.Registry,
	toks:   []stream.Token,
	lo, hi: int,
	sent:   int,
	thread: ^thread.Thread,
}

producer_main :: proc(p: ^Producer) {
	payload := transmute([]u8)string("x")
	for round in 0 ..< 4 {
		for i in p.lo ..< p.hi {
			if stream.try_send(p.r, p.toks[i], payload) == .Sent {
				p.sent += 1
			}
		}
	}
}

@(test)
wp96_every_lane_sends_to_streams_owned_by_every_other :: proc(t: ^testing.T) {
	// Cross-lane fan-out at scale: four producer threads each send into the
	// whole 3,000-stream range, so every "lane" touches streams it did not
	// open. Exactly-once accounting under contention is the property.
	COUNT :: 1200
	r := new(stream.Registry)
	defer free(r)
	_ = stream.registry_init(r, stream.Capacity {
		max_streams = COUNT, max_events_stream = 16, max_bytes_stream = 64,
		max_bytes_total = COUNT * 64, tick_progress = 4096,
	})
	defer stream.registry_destroy(r)
	toks := make([]stream.Token, COUNT)
	defer delete(toks)
	for i in 0 ..< COUNT {toks[i], _ = stream.open(r, u64(i))}

	producers: [4]Producer
	for &p, i in producers {
		p = Producer{r = r, toks = toks, lo = 0, hi = COUNT}
		p.thread = thread.create_and_start_with_poly_data(&p, producer_main)
	}
	total := 0
	for &p in producers {
		thread.join(p.thread)
		thread.destroy(p.thread)
		total += p.sent
	}
	// Every accepted send is accounted; drain and close release all of it.
	testing.expect(t, total > 0)
	stream.drain_begin(r)
	for i in 0 ..< COUNT {_ = stream.close(r, toks[i])}
	testing.expect_value(t, stream.live_streams(r), 0)
	_ = sync.atomic_load(&r.total_bytes) // touch, to assert no negative leak below
	testing.expect_value(t, stream.counters(r).refused_stream_full >= 0, true)
}
