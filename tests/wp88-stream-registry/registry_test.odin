// WP88/WP89 — registry and cross-lane delivery, beyond the corpus.
//
// The WP87 corpus fixes the single-thread contract; this suite proves the
// pieces the corpus could not see: the ring store's wraparound accounting,
// the process-wide byte budget, the executor-agnostic wake hook, FIFO
// integrity under real concurrent producers, and the owner-lane consumption
// pair (next_event/complete_event) that WP90's writer will drive.
package test_wp88_stream_registry

import "core:sync"
import "core:thread"
import "core:testing"
import stream "druse:web/internal/stream"

@(private)
wake_count: int // atomic

@(private)
count_wake :: proc(user: rawptr) {
	sync.atomic_add(&wake_count, 1)
}

@(test)
wp88_defaults_resolve_to_the_preregistered_numbers :: proc(t: ^testing.T) {
	c := stream.resolve(stream.Capacity{})
	testing.expect_value(t, c.max_streams, 1024)
	testing.expect_value(t, c.max_events_stream, 64)
	testing.expect_value(t, c.max_bytes_stream, 256 * 1024)
	testing.expect_value(t, c.max_bytes_total, 16 * 1024 * 1024)
	testing.expect_value(t, c.tick_progress, 64 * 1024)
}

@(test)
wp88_ring_store_wraps_and_accounts_exactly :: proc(t: ^testing.T) {
	r: stream.Registry
	ok := stream.registry_init(&r, stream.Capacity{
		max_streams = 1, max_events_stream = 8, max_bytes_stream = 128,
		max_bytes_total = 1024, tick_progress = 64,
	})
	testing.expect(t, ok)
	defer stream.registry_destroy(&r)
	tok, _ := stream.open(&r, 1)

	a := make([]u8, 50)
	for &b, i in a {b = u8('A' + i % 26)}
	b50 := make([]u8, 50)
	for &b, i in b50 {b = u8('a' + i % 26)}
	c50 := make([]u8, 50)
	for &b, i in c50 {b = u8('0' + i % 10)}
	defer {delete(a); delete(b50); delete(c50)}

	testing.expect_value(t, stream.try_send(&r, tok, a), stream.Send_Result.Sent)    // offset 0
	testing.expect_value(t, stream.try_send(&r, tok, b50), stream.Send_Result.Sent)  // offset 50
	// 100/128 used: a third 50-byte event needs a 28-byte wrap gap → 78 > 28 free.
	testing.expect_value(t, stream.try_send(&r, tok, c50), stream.Send_Result.Full)

	// The owner lane consumes the oldest event, freeing its 50 bytes…
	view, has := stream.next_event(&r, tok)
	testing.expect(t, has)
	testing.expect_value(t, string(view), string(a))
	testing.expect(t, stream.complete_event(&r, tok))
	// …and now the wrapped send fits (gap 28 + 50 = 78 ≤ 78 free).
	testing.expect_value(t, stream.try_send(&r, tok, c50), stream.Send_Result.Sent)

	// FIFO continues across the wrap with exact bytes.
	view, has = stream.next_event(&r, tok)
	testing.expect(t, has)
	testing.expect_value(t, string(view), string(b50))
	testing.expect(t, stream.complete_event(&r, tok))
	view, has = stream.next_event(&r, tok)
	testing.expect(t, has)
	testing.expect_value(t, string(view), string(c50))
	testing.expect(t, stream.complete_event(&r, tok))
	_, has = stream.next_event(&r, tok)
	testing.expect(t, !has, "the queue must be empty after the wrapped cycle")
	testing.expect_value(t, stream.queued_events(&r, tok), 0)
}

@(test)
wp88_process_budget_refuses_across_streams :: proc(t: ^testing.T) {
	r: stream.Registry
	_ = stream.registry_init(&r, stream.Capacity{
		max_streams = 2, max_events_stream = 8, max_bytes_stream = 128,
		max_bytes_total = 160, tick_progress = 64,
	})
	defer stream.registry_destroy(&r)
	one, _ := stream.open(&r, 1)
	two, _ := stream.open(&r, 2)
	chunk := make([]u8, 100)
	defer delete(chunk)
	testing.expect_value(t, stream.try_send(&r, one, chunk), stream.Send_Result.Sent)
	// Stream two has its whole per-stream cap free, but the PROCESS budget
	// (160) has only 60 left: the send must refuse there.
	testing.expect_value(t, stream.try_send(&r, two, chunk), stream.Send_Result.Full)
	// Closing stream one returns its reservation and unblocks stream two.
	testing.expect(t, stream.close(&r, one))
	testing.expect_value(t, stream.try_send(&r, two, chunk), stream.Send_Result.Sent)
}

@(test)
wp88_wake_hook_fires_on_publish_close_and_drain :: proc(t: ^testing.T) {
	sync.atomic_store(&wake_count, 0)
	r: stream.Registry
	_ = stream.registry_init(&r, stream.Capacity{
		max_streams = 1, max_events_stream = 4, max_bytes_stream = 64,
		max_bytes_total = 64, tick_progress = 16,
	}, count_wake, nil)
	defer stream.registry_destroy(&r)
	tok, _ := stream.open(&r, 1)
	payload := [8]u8{}
	_ = stream.try_send(&r, tok, payload[:])
	testing.expect_value(t, sync.atomic_load(&wake_count), 1)
	_ = stream.close(&r, tok)
	testing.expect_value(t, sync.atomic_load(&wake_count), 2)
	stream.drain_begin(&r)
	testing.expect_value(t, sync.atomic_load(&wake_count), 3)
}

@(test)
wp88_owner_pair_refuses_a_stale_token :: proc(t: ^testing.T) {
	r: stream.Registry
	_ = stream.registry_init(&r, stream.Capacity{
		max_streams = 1, max_events_stream = 4, max_bytes_stream = 64,
		max_bytes_total = 64, tick_progress = 16,
	})
	defer stream.registry_destroy(&r)
	tok, _ := stream.open(&r, 1)
	payload := [8]u8{}
	_ = stream.try_send(&r, tok, payload[:])
	_ = stream.close(&r, tok)
	_, has := stream.next_event(&r, tok)
	testing.expect(t, !has, "a closed token exposes nothing to write")
	testing.expect(t, !stream.complete_event(&r, tok), "a closed token completes nothing")
}

// --- concurrent producers against a draining owner --------------------------

PRODUCERS :: 4
SENDS_PER_PRODUCER :: 500

@(private)
Producer :: struct {
	r:      ^stream.Registry,
	tok:    stream.Token,
	id:     u8,
	sent:   int,
	thread: ^thread.Thread,
}

@(private)
producer_main :: proc(p: ^Producer) {
	// Each event: [id, seq_hi, seq_lo, id] — enough to verify integrity and
	// per-producer order on the consumer side.
	for seq in 0 ..< SENDS_PER_PRODUCER {
		msg := [4]u8{p.id, u8(seq >> 8), u8(seq & 0xff), p.id}
		for {
			switch stream.try_send(p.r, p.tok, msg[:]) {
			case .Sent:
				p.sent += 1
			case .Full:
				thread.yield() // the producer's policy; the framework never blocks
				continue
			case .Closed, .Stale, .Unimplemented:
			}
			break
		}
	}
}

@(test)
wp89_concurrent_producers_deliver_exactly_once_in_producer_order :: proc(t: ^testing.T) {
	r: stream.Registry
	_ = stream.registry_init(&r, stream.Capacity{
		max_streams = 1, max_events_stream = 16, max_bytes_stream = 256,
		max_bytes_total = 256, tick_progress = 64,
	})
	defer stream.registry_destroy(&r)
	tok, _ := stream.open(&r, 1)

	producers: [PRODUCERS]Producer
	for &p, i in producers {
		p = Producer{r = &r, tok = tok, id = u8('A' + i)}
		p.thread = thread.create_and_start_with_poly_data(&p, producer_main)
	}

	// The "owner lane": drain until every producer's total has arrived.
	received := 0
	next_seq: [PRODUCERS]int
	order_ok := true
	integrity_ok := true
	for received < PRODUCERS * SENDS_PER_PRODUCER {
		view, has := stream.next_event(&r, tok)
		if !has {
			thread.yield()
			continue
		}
		if len(view) != 4 || view[0] != view[3] || view[0] < 'A' || view[0] >= 'A' + PRODUCERS {
			integrity_ok = false
			break
		}
		idx := int(view[0] - 'A')
		seq := int(view[1]) << 8 | int(view[2])
		if seq != next_seq[idx] {
			order_ok = false
			break
		}
		next_seq[idx] += 1
		if !stream.complete_event(&r, tok) {
			integrity_ok = false
			break
		}
		received += 1
	}
	for &p in producers {
		thread.join(p.thread)
		thread.destroy(p.thread)
	}
	testing.expect(t, integrity_ok, "every event must arrive intact: same producer id at both ends, valid length")
	testing.expect(t, order_ok, "each producer's events must arrive in its send order")
	testing.expect_value(t, received, PRODUCERS * SENDS_PER_PRODUCER)
	total_sent := 0
	for &p in producers {total_sent += p.sent}
	testing.expect_value(t, total_sent, PRODUCERS * SENDS_PER_PRODUCER)
	testing.expect_value(t, stream.queued_events(&r, tok), 0)
}

// --- M2: the wake must be invoked with the slot lock RELEASED ---------------
//
// THE DEFECT THIS PINS. A revision moved `try_send`'s wake call inside `s.mu`
// to close a slot-reuse race. The wake reaches `nbio.exec`, which for a foreign
// event loop SPINS until the target lane's 128-entry queue accepts the op:
//
//     for !mpsc_enqueue(&l.queue, op) { wake_up(l); _yield() }
//
// The owner lane drains that queue only at the top of its tick. If the lane is
// already inside a pump callback blocked on this very `s.mu`, it can never
// reach the drain, the queue never empties, and the producer spins forever
// holding the lock. Two threads, no progress, no diagnostic.
//
// The registry cannot see `nbio`, so this asserts the property that makes the
// deadlock impossible instead of the deadlock itself: at the moment the wake
// runs, the slot mutex is free. A `try_lock` that FAILS here means the wake is
// back under the lock. Deliberately not written as "call try_send re-entrantly
// and see if it hangs" — a test that proves a lock bug by deadlocking can only
// hang the runner, which is the WP58 harness rule.
@(private)
Lock_Probe :: struct {
	reg:      ^stream.Registry,
	slot:     i32,
	ran:      int,
	was_free: bool,
}

@(private)
probe_wake :: proc(user: rawptr) {
	p := (^Lock_Probe)(user)
	p.ran += 1
	// The producer holds no other lock here, so a failure to acquire means the
	// wake itself is running underneath `s.mu`.
	if sync.mutex_try_lock(&p.reg.slots[p.slot].mu) {
		p.was_free = true
		sync.mutex_unlock(&p.reg.slots[p.slot].mu)
	} else {
		p.was_free = false
	}
}

@(test)
wp88_the_slot_wake_runs_outside_the_slot_lock :: proc(t: ^testing.T) {
	r: stream.Registry
	testing.expect(t, stream.registry_init(&r, stream.Capacity{}))
	defer stream.registry_destroy(&r)

	probe: Lock_Probe
	probe.reg = &r

	tok, opened := stream.open(&r, 1, probe_wake, &probe)
	testing.expect_value(t, opened, stream.Open_Result.Opened)
	probe.slot = tok.slot

	testing.expect_value(t, stream.try_send(&r, tok, []u8{'a'}), stream.Send_Result.Sent)
	testing.expect_value(t, probe.ran, 1)
	testing.expect(
		t,
		probe.was_free,
		"try_send invoked the slot wake while still holding s.mu; a wake that reaches a full cross-thread queue will spin under this lock and deadlock the owner lane",
	)

	// `close` takes the same path and must obey the same rule.
	probe.ran = 0
	probe.was_free = false
	testing.expect(t, stream.close(&r, tok))
	testing.expect_value(t, probe.ran, 1)
	testing.expect(
		t,
		probe.was_free,
		"close invoked the slot wake while still holding s.mu; same deadlock, same lock",
	)
	_ = stream.retire(&r, tok.slot)
}
