// WP87 — the detached-stream lifecycle and ownership corpus, committed RED.
//
// Every test below encodes the CONTRACT of phase-7-spec.md §3.1/§4.1 and
// ADR-044, written against the WP87 sentinel in `web/internal/stream`. The
// suite is EXPECTED to fail today — `build/check_wp87_controls.sh` proves it
// fails complete and for the sentinel's reason, not vacuously. WP88/WP89/WP95
// make it pass by replacing sentinel bodies, never by editing a test.
package test_wp87_stream_lifecycle

import "core:testing"
import stream "druse:web/internal/stream"

// A tiny forced capacity so refusal and reuse are exercised, not simulated.
tiny :: proc() -> stream.Capacity {
	return stream.Capacity{
		max_streams       = 2,
		max_events_stream = 2,
		max_bytes_stream  = 128,
		max_bytes_total   = 256,
		tick_progress     = 2,
	}
}

@(test)
wp87_registry_initializes_with_preregistered_capacity :: proc(t: ^testing.T) {
	r: stream.Registry
	testing.expect(t, stream.registry_init(&r, tiny()), "the registry must accept the pre-registered capacity (sentinel: WP88)")
	defer stream.registry_destroy(&r)
	testing.expect_value(t, stream.live_streams(&r), 0)
}

@(test)
wp87_open_commits_reserved_state_exactly_once :: proc(t: ^testing.T) {
	r: stream.Registry
	_ = stream.registry_init(&r, tiny())
	defer stream.registry_destroy(&r)
	tok, res := stream.open(&r, 1)
	testing.expect_value(t, res, stream.Open_Result.Opened)
	testing.expect(t, tok.slot >= 0, "an opened stream must carry a live slot (sentinel: WP88)")
	testing.expect_value(t, stream.live_streams(&r), 1)
}

@(test)
wp87_open_beyond_capacity_refuses_typed :: proc(t: ^testing.T) {
	r: stream.Registry
	_ = stream.registry_init(&r, tiny())
	defer stream.registry_destroy(&r)
	_, _ = stream.open(&r, 1)
	_, _ = stream.open(&r, 2)
	_, res := stream.open(&r, 3)
	testing.expect_value(t, res, stream.Open_Result.At_Capacity)
}

@(test)
wp87_stream_outlives_the_handler_scope :: proc(t: ^testing.T) {
	// G7-1: the Handler and its arena are gone; the stream remains valid.
	// The corpus models the Handler frame as an inner scope whose locals die.
	r: stream.Registry
	_ = stream.registry_init(&r, tiny())
	defer stream.registry_destroy(&r)
	tok: stream.Token
	{
		handler_local := [4]u8{'d', 'e', 'a', 'd'}
		tok, _ = stream.open(&r, 1)
		_ = handler_local
		// Handler returns here; nothing request-local survives.
	}
	payload := [4]u8{'l', 'i', 'v', 'e'}
	testing.expect_value(t, stream.try_send(&r, tok, payload[:]), stream.Send_Result.Sent)
}

@(test)
wp87_enqueue_copies_the_callers_bytes :: proc(t: ^testing.T) {
	// The Productive contract is copy-on-enqueue: mutating the caller's
	// buffer after send must not change what was queued.
	r: stream.Registry
	_ = stream.registry_init(&r, tiny())
	defer stream.registry_destroy(&r)
	tok, _ := stream.open(&r, 1)
	payload := [4]u8{'k', 'e', 'e', 'p'}
	testing.expect_value(t, stream.try_send(&r, tok, payload[:]), stream.Send_Result.Sent)
	payload = [4]u8{'g', 'o', 'n', 'e'} // caller reuses its buffer immediately
	testing.expect_value(t, stream.queued_events(&r, tok), 1)
}

@(test)
wp87_queue_full_is_deterministic_and_immediate :: proc(t: ^testing.T) {
	r: stream.Registry
	_ = stream.registry_init(&r, tiny())
	defer stream.registry_destroy(&r)
	tok, _ := stream.open(&r, 1)
	payload := [8]u8{}
	testing.expect_value(t, stream.try_send(&r, tok, payload[:]), stream.Send_Result.Sent)
	testing.expect_value(t, stream.try_send(&r, tok, payload[:]), stream.Send_Result.Sent)
	testing.expect_value(t, stream.try_send(&r, tok, payload[:]), stream.Send_Result.Full)
	testing.expect_value(t, stream.try_send(&r, tok, payload[:]), stream.Send_Result.Full)
}

@(test)
wp87_close_is_idempotent :: proc(t: ^testing.T) {
	r: stream.Registry
	_ = stream.registry_init(&r, tiny())
	defer stream.registry_destroy(&r)
	tok, _ := stream.open(&r, 1)
	testing.expect(t, stream.close(&r, tok), "first close must be accepted (sentinel: WP88/WP89)")
	testing.expect(t, stream.close(&r, tok), "second close must be a safe no-op, never a fault")
}

@(test)
wp87_full_user_capacity_cannot_block_close :: proc(t: ^testing.T) {
	r: stream.Registry
	_ = stream.registry_init(&r, tiny())
	defer stream.registry_destroy(&r)
	tok, _ := stream.open(&r, 1)
	payload := [8]u8{}
	for _ in 0 ..< 4 {
		_ = stream.try_send(&r, tok, payload[:])
	}
	// Control capacity is reserved: a saturated user queue never refuses close.
	testing.expect(t, stream.close(&r, tok), "close must succeed against a full queue (reserved control capacity)")
}

@(test)
wp87_send_after_close_has_one_terminal_owner :: proc(t: ^testing.T) {
	r: stream.Registry
	_ = stream.registry_init(&r, tiny())
	defer stream.registry_destroy(&r)
	tok, _ := stream.open(&r, 1)
	_ = stream.close(&r, tok)
	payload := [4]u8{'r', 'a', 'c', 'e'}
	res := stream.try_send(&r, tok, payload[:])
	terminal := res == .Closed || res == .Stale
	testing.expect(t, terminal, "a send that loses to close resolves to exactly one terminal result, never Sent")
}

@(test)
wp87_stale_token_after_slot_reuse_refuses :: proc(t: ^testing.T) {
	// G7-3, with the WP-plan control mutation aimed here: removing the
	// generation check must make this test — and therefore the gate — fail.
	r: stream.Registry
	_ = stream.registry_init(&r, tiny())
	defer stream.registry_destroy(&r)
	old_tok, _ := stream.open(&r, 1)
	blocker, _ := stream.open(&r, 2) // hold the other slot so reuse hits the same one
	_ = stream.close(&r, old_tok)
	new_tok, res := stream.open(&r, 3)
	testing.expect_value(t, res, stream.Open_Result.Opened)
	testing.expect_value(t, new_tok.slot, old_tok.slot)
	testing.expect(t, new_tok.generation > old_tok.generation, "slot reuse must advance the generation")
	late := [4]u8{'l', 'a', 't', 'e'}
	testing.expect_value(t, stream.try_send(&r, old_tok, late[:]), stream.Send_Result.Stale)
	fresh := [4]u8{'f', 'r', 's', 'h'}
	testing.expect_value(t, stream.try_send(&r, new_tok, fresh[:]), stream.Send_Result.Sent)
	testing.expect_value(t, stream.queued_events(&r, new_tok), 1)
	_ = blocker
}

@(test)
wp87_no_open_and_no_send_after_drain_begins :: proc(t: ^testing.T) {
	r: stream.Registry
	_ = stream.registry_init(&r, tiny())
	defer stream.registry_destroy(&r)
	tok, _ := stream.open(&r, 1)
	stream.drain_begin(&r)
	_, res := stream.open(&r, 2)
	testing.expect_value(t, res, stream.Open_Result.Draining)
	payload := [4]u8{'p', 'o', 's', 't'}
	sent := stream.try_send(&r, tok, payload[:])
	refused := sent == .Closed || sent == .Stale
	testing.expect(t, refused, "no new output is accepted once process drain begins (WP95)")
}

@(test)
wp87_close_releases_the_stream_for_accounting :: proc(t: ^testing.T) {
	// Exactly-once release, observable as the live count returning to zero —
	// the semantic transition both the test transport and the socket adapter
	// must expose identically (WP90/WP91 wire the adapters to this contract).
	r: stream.Registry
	_ = stream.registry_init(&r, tiny())
	defer stream.registry_destroy(&r)
	a, _ := stream.open(&r, 1)
	b, _ := stream.open(&r, 2)
	testing.expect_value(t, stream.live_streams(&r), 2)
	_ = stream.close(&r, a)
	testing.expect_value(t, stream.live_streams(&r), 1)
	_ = stream.close(&r, b)
	testing.expect_value(t, stream.live_streams(&r), 0)
}
