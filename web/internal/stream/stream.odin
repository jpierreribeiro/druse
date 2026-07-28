// Private detached-stream lifecycle — implemented by WP88 (registry,
// stale-safe identity) and WP89 (cross-lane bounded delivery) against the
// contract the WP87 corpus committed RED.
//
// Shape selected by WP86 (candidate C) and bound by ADR-044:
//   - contiguous slots, an explicit free list and a generation counter —
//     never a pointer graph; a Token is a value that cannot expose registry
//     memory or an adapter handle;
//   - try_send may run on ANY Handler lane or approved application thread:
//     validate generation → reserve bounded capacity → copy into
//     stream-owned storage → publish → wake the owner → return a closed
//     typed result. It never blocks and never touches a socket;
//   - close travels on reserved control capacity (accepted against a full
//     queue), is idempotent, and invalidates the generation BEFORE queued
//     items are released;
//   - the wakeup is executor-agnostic (phase-7-spec.md §6.3): a procedure
//     value installed at init, so nothing here assumes the producer or the
//     owner is a Handler lane;
//   - capacities are the §4.1 pre-registered defaults; zero selects them.
//
// Still not imported by `web` (that wiring is WP90); a buffered-only binary
// links none of this, and no name here is a ledger candidate (WP101).
package uruquim_internal_stream

import "core:mem"
import "core:sync"

// The closed result of a bounded cross-thread send.
Send_Result :: enum {
	Unimplemented, // retained for ABI stability with the WP87 corpus; no code path returns it since WP89
	Sent,
	Full,
	Closed,
	Stale,
}

// The typed outcome of opening a detached stream at the registry.
Open_Result :: enum {
	Unimplemented, // as above: kept, never returned since WP88
	Opened,
	At_Capacity,
	Draining,
}

// A value token: never a pointer into registry memory (ADR-044). A delayed
// holder of an old token must be refused after slot reuse.
Token :: struct {
	slot:       i32,
	generation: u64,
}

// Pre-registered capacity contract (phase-7-spec.md §4.1). Zero means "use
// the registered default", mirroring the Limits convention.
Capacity :: struct {
	max_streams:       int,
	max_events_stream: int,
	max_bytes_stream:  int,
	max_bytes_total:   int,
	tick_progress:     int,
}

// §4.1 registered defaults.
DEFAULT_MAX_STREAMS :: 1024
DEFAULT_MAX_EVENTS_STREAM :: 64
DEFAULT_MAX_BYTES_STREAM :: 256 * 1024
DEFAULT_MAX_BYTES_TOTAL :: 16 * 1024 * 1024
DEFAULT_TICK_PROGRESS :: 64 * 1024

// The executor-agnostic wakeup hook: installed at init, called after publish.
Wake_Proc :: proc(user: rawptr)

@(private)
Slot_State :: enum u8 {
	Free,
	Open,
	Closing,
}

// One queued event: an (offset, len) view into the slot's ring storage.
@(private)
Event :: struct {
	offset: int,
	len:    int,
}

@(private)
Slot :: struct {
	mu:              sync.Mutex,
	generation:      u64,
	state:           Slot_State,
	connection_id:   u64,
	close_requested: bool,
	// WP90 — the per-stream owner wake, installed at open by the adapter.
	// When set, the OWNER (not the registry) frees the slot via `retire`,
	// because the owner may hold zero-copy views into the slot's ring store
	// while a send is in flight; reusing the slot before the owner is done
	// would let a new stream overwrite bytes mid-send. When nil (the unit /
	// corpus configuration), close frees immediately, which is the WP87
	// contract unchanged.
	wake:            Wake_Proc,
	wake_user:       rawptr,
	// Bounded FIFO of events over a circular byte store, both allocated once
	// at init. `bytes_head` is where the oldest event's bytes begin.
	events:          []Event,
	events_head:     int,
	events_count:    int,
	store:           []u8,
	store_head:      int,
	store_used:      int, // includes wrap gaps, so reservation stays honest
}

Registry :: struct {
	slots:        []Slot,
	free_list:    []i32,
	free_top:     int,
	free_mu:      sync.Mutex,
	live:         int, // guarded by free_mu; corpus-observable
	total_bytes:  int, // atomic: process-wide queued-byte reservation
	draining:     bool, // atomic
	cap:          Capacity,
	wake:         Wake_Proc,
	wake_user:    rawptr,
	allocator:    mem.Allocator,
	initialized:  bool,

	// WP92 — refusal and disconnect accounting, atomics like the WP47
	// admission counters and for the same reason: capacity refusals are a
	// RESULT an operator sizes queues by, not a log line per event.
	refused_stream_full: int, // per-stream event/byte cap refused a send
	refused_budget_full: int, // the process-wide byte budget refused a send
	aborted_slow:        int, // owner tore a stream down on write error/deadline
}

resolve :: proc(cap: Capacity) -> Capacity {
	c := cap
	if c.max_streams <= 0 {c.max_streams = DEFAULT_MAX_STREAMS}
	if c.max_events_stream <= 0 {c.max_events_stream = DEFAULT_MAX_EVENTS_STREAM}
	if c.max_bytes_stream <= 0 {c.max_bytes_stream = DEFAULT_MAX_BYTES_STREAM}
	if c.max_bytes_total <= 0 {c.max_bytes_total = DEFAULT_MAX_BYTES_TOTAL}
	if c.tick_progress <= 0 {c.tick_progress = DEFAULT_TICK_PROGRESS}
	return c
}

registry_init :: proc(r: ^Registry, cap: Capacity, wake: Wake_Proc = nil, wake_user: rawptr = nil) -> bool {
	if r.initialized {
		return false
	}
	c := resolve(cap)
	r.allocator = context.allocator
	// Only the slot HEADERS and the free list are allocated eagerly (small:
	// a Slot is slice headers + counters). The per-slot event ring and byte
	// store are allocated LAZILY on a slot's first open and kept for reuse —
	// so a server that never opens a stream pays a few hundred KiB, not
	// max_streams × max_bytes_stream (which at the §4.1 defaults is 256 MiB).
	// This is the difference between "pay only when used" and taxing every
	// buffered-only server for a feature it never touches (G7-8).
	slots, s_err := make([]Slot, c.max_streams, r.allocator)
	if s_err != nil {
		return false
	}
	free_list, f_err := make([]i32, c.max_streams, r.allocator)
	if f_err != nil {
		delete(slots, r.allocator)
		return false
	}
	// Explicit free list, filled so the LOWEST slot is handed out first —
	// deterministic reuse, which the forced-tiny-capacity tests rely on.
	for i in 0 ..< c.max_streams {
		free_list[i] = i32(c.max_streams - 1 - i)
	}
	r.slots = slots
	r.free_list = free_list
	r.free_top = c.max_streams
	r.live = 0
	r.total_bytes = 0
	r.draining = false
	r.cap = c
	r.wake = wake
	r.wake_user = wake_user
	r.initialized = true
	return true
}

registry_destroy :: proc(r: ^Registry) {
	if !r.initialized {
		return
	}
	// Free only the slots that were ever opened (and so allocated their ring).
	for &s in r.slots {
		if s.events != nil {delete(s.events, r.allocator)}
		if s.store != nil {delete(s.store, r.allocator)}
	}
	delete(r.slots, r.allocator)
	delete(r.free_list, r.allocator)
	r^ = Registry{}
}

// open runs on the connection-owning lane, during dispatch (WP90 wires it).
// The optional per-stream wake transfers slot-release ownership to the
// caller: when set, close leaves the slot in `Closing` and the owner must
// call `retire` after its own teardown (see the Slot.wake comment).
open :: proc(
	r: ^Registry,
	connection_id: u64,
	wake: Wake_Proc = nil,
	wake_user: rawptr = nil,
) -> (Token, Open_Result) {
	if !r.initialized {
		return Token{slot = -1}, .At_Capacity
	}
	if sync.atomic_load(&r.draining) {
		return Token{slot = -1}, .Draining
	}
	sync.mutex_lock(&r.free_mu)
	if r.free_top == 0 {
		sync.mutex_unlock(&r.free_mu)
		return Token{slot = -1}, .At_Capacity
	}
	r.free_top -= 1
	idx := r.free_list[r.free_top]
	r.live += 1
	sync.mutex_unlock(&r.free_mu)

	s := &r.slots[idx]
	sync.mutex_lock(&s.mu)
	// Lazily allocate this slot's ring on first open; kept for reuse until the
	// registry is destroyed. If allocation fails, hand the slot back and
	// report capacity — an open that cannot get its buffer is not open.
	if s.events == nil || s.store == nil {
		events, e_err := make([]Event, r.cap.max_events_stream, r.allocator)
		store, b_err := make([]u8, r.cap.max_bytes_stream, r.allocator)
		if e_err != nil || b_err != nil {
			if e_err == nil {delete(events, r.allocator)}
			if b_err == nil {delete(store, r.allocator)}
			sync.mutex_unlock(&s.mu)
			sync.mutex_lock(&r.free_mu)
			r.free_list[r.free_top] = idx
			r.free_top += 1
			r.live -= 1
			sync.mutex_unlock(&r.free_mu)
			return Token{slot = -1}, .At_Capacity
		}
		s.events = events
		s.store = store
	}
	s.state = .Open
	s.connection_id = connection_id
	s.close_requested = false
	s.wake = wake
	s.wake_user = wake_user
	s.events_head = 0
	s.events_count = 0
	s.store_head = 0
	s.store_used = 0
	tok := Token{slot = idx, generation = s.generation}
	sync.mutex_unlock(&s.mu)
	return tok, .Opened
}

// try_send: the WP89 six-step contract. Any thread; never blocks; never
// touches the socket; no mutex is held during any socket write because no
// socket write happens here at all — the owner lane drains separately.
try_send :: proc(r: ^Registry, tok: Token, data: []u8) -> Send_Result {
	if !r.initialized || tok.slot < 0 || int(tok.slot) >= len(r.slots) {
		return .Stale
	}
	s := &r.slots[tok.slot]
	sync.mutex_lock(&s.mu)
	// 1. validate the generation while holding the slot.
	if s.generation != tok.generation {
		sync.mutex_unlock(&s.mu)
		return .Stale
	}
	if s.state != .Open || s.close_requested || sync.atomic_load(&r.draining) {
		sync.mutex_unlock(&s.mu)
		return .Closed
	}
	// 2. reserve bounded capacity: event slot, per-stream bytes, then the
	//    process-wide byte budget (reserve-then-check keeps it atomic).
	if s.events_count >= len(s.events) {
		sync.mutex_unlock(&s.mu)
		sync.atomic_add(&r.refused_stream_full, 1)
		return .Full
	}
	needed, gap := store_reserve(s, len(data))
	if needed < 0 {
		sync.mutex_unlock(&s.mu)
		sync.atomic_add(&r.refused_stream_full, 1)
		return .Full
	}
	if sync.atomic_add(&r.total_bytes, needed) + needed > r.cap.max_bytes_total {
		sync.atomic_sub(&r.total_bytes, needed)
		sync.mutex_unlock(&s.mu)
		sync.atomic_add(&r.refused_budget_full, 1)
		return .Full
	}
	// 3. copy into stream-owned storage. When a wrap gap was reserved, the
	// modular arithmetic lands the event exactly at the store's origin:
	// tail + gap ≡ 0 (mod len).
	offset := (s.store_head + s.store_used + gap) % len(s.store)
	copy(s.store[offset:offset + len(data)], data)
	// 4. publish to the owner lane's FIFO.
	e := &s.events[(s.events_head + s.events_count) % len(s.events)]
	e.offset = offset
	e.len = len(data)
	s.events_count += 1
	s.store_used += needed
	// The slot's own wake is captured under the lock so a concurrent close
	// (which clears ownership at retire) cannot race the read.
	slot_wake := s.wake
	slot_user := s.wake_user
	sync.mutex_unlock(&s.mu)
	// 5. wake the owner, OUTSIDE the lock — and it must stay outside.
	//
	// A previous revision moved this call inside `s.mu` to close a slot-reuse
	// race (M2). That deadlocks. The wake reaches `nbio.exec`, which for a
	// FOREIGN event loop spins until the target lane's queue accepts the op:
	//
	//     for !mpsc_enqueue(&l.queue, op) { wake_up(l); _yield() }
	//
	// That queue holds 128 entries. Meanwhile the owner lane drains it only at
	// the TOP of its tick; if the lane is already inside a pump callback that
	// is blocked on this very `s.mu`, it can never reach the drain, the queue
	// never empties, and the producer spins forever holding the lock. Wake
	// outside the lock and the owner always makes progress.
	//
	// The race that motivated the move is closed where it actually lives
	// instead: the owner lane is published atomically in `stream_open` and the
	// pump refuses to run on a lane the link no longer names. See
	// `stream_pump_arm` / `stream_pump` in the adapter.
	if slot_wake != nil {
		slot_wake(slot_user)
	} else if r.wake != nil {
		r.wake(r.wake_user)
	}
	sync.mutex_unlock(&s.mu)
	// 6. a closed typed result.
	return .Sent
}

// store_reserve computes how many ring bytes an event of `size` needs
// (payload plus any wrap gap) without mutating the slot, returning -1 when
// the per-stream byte cap refuses. Caller holds s.mu.
@(private)
store_reserve :: proc(s: ^Slot, size: int) -> (needed: int, gap: int) {
	if size > len(s.store) {
		return -1, 0
	}
	tail := (s.store_head + s.store_used) % len(s.store)
	gap = 0
	if tail + size > len(s.store) {
		// Not enough contiguous space at the tail: skip to the origin.
		gap = len(s.store) - tail
	}
	needed = size + gap
	if s.store_used + needed > len(s.store) {
		return -1, 0
	}
	return needed, gap
}

// close: reserved control capacity — accepted against a full queue, safe to
// repeat. The generation advances the moment close is accepted, BEFORE any
// queued item is released (ADR-044 §3): from that instant the old token is
// stale everywhere.
close :: proc(r: ^Registry, tok: Token) -> bool {
	if !r.initialized || tok.slot < 0 || int(tok.slot) >= len(r.slots) {
		return false
	}
	s := &r.slots[tok.slot]
	sync.mutex_lock(&s.mu)
	if s.generation != tok.generation {
		// Already closed under this token (idempotent) — or a genuinely
		// foreign token. Idempotence wins: a repeated close of a slot this
		// token once owned must be a safe no-op, and a foreign token cannot
		// distinguish itself from history without exposing registry memory.
		sync.mutex_unlock(&s.mu)
		return true
	}
	if s.state == .Free {
		sync.mutex_unlock(&s.mu)
		return true
	}
	s.generation += 1 // stale-safety first: no NEW producer can reach this slot…
	s.close_requested = true
	s.state = .Closing
	owned := s.wake != nil
	slot_wake := s.wake
	slot_user := s.wake_user
	if !owned {
		// No owner (the corpus/unit contract): nothing drains the queue, so
		// release it here and free the slot immediately.
		release_queued(r, s)
		s.state = .Free
		s.close_requested = false
	}
	// OWNED (the adapter): the queue is NOT discarded. The owner-lane pump
	// drains the already-queued events through the slot-based owner path
	// (which ignores the now-bumped generation, since the owner is trusted),
	// writes the terminator, and calls `retire`. This is what lets an
	// application deliver a FINAL event and then close without losing it —
	// close is graceful for queued output while staying stale-safe against
	// new producers.
	sync.mutex_unlock(&s.mu)

	if !owned {
		sync.mutex_lock(&r.free_mu)
		r.free_list[r.free_top] = tok.slot
		r.free_top += 1
		r.live -= 1
		sync.mutex_unlock(&r.free_mu)
	}

	if slot_wake != nil {
		// The owner terminates on its own lane (terminator frame, connection
		// retirement) and then calls `retire` to free the slot.
		slot_wake(slot_user)
	} else if r.wake != nil {
		r.wake(r.wake_user)
	}
	return true
}

// rebind_wake replaces an open slot's wake registration. It exists for the
// adapter's open sequence: the link address is only known after `open`
// hands out the slot index, and no producer can hold the token before the
// opener returns it, so the window is single-threaded by construction.
rebind_wake :: proc(r: ^Registry, tok: Token, wake: Wake_Proc, wake_user: rawptr) -> bool {
	if !r.initialized || tok.slot < 0 || int(tok.slot) >= len(r.slots) {
		return false
	}
	s := &r.slots[tok.slot]
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if s.generation != tok.generation || s.state != .Open {
		return false
	}
	s.wake = wake
	s.wake_user = wake_user
	return true
}

// is_live reports whether `tok` still names an OPEN stream that would accept a
// send — the query a subscriber registry needs to prune a departed client WITHOUT
// sending to it (corrective WP C4, friction F8-5). It mirrors `try_send`'s
// admission guard exactly (generation match, `.Open`, not close-requested, not
// draining), read-only and under the slot lock, so a stale/reused/closing token
// answers false just as a send to it would collapse to `Closed`. Safe from any
// thread.
is_live :: proc(r: ^Registry, tok: Token) -> bool {
	if !r.initialized || tok.slot < 0 || int(tok.slot) >= len(r.slots) {
		return false
	}
	s := &r.slots[tok.slot]
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if s.generation != tok.generation || s.state != .Open || s.close_requested {
		return false
	}
	return !sync.atomic_load(&r.draining)
}

// retire frees an OWNED slot after the owner's teardown is complete: the
// terminator is on the wire (or the connection aborted) and no zero-copy view
// into the slot's ring store can be in flight any more. Owner lane only.
retire :: proc(r: ^Registry, slot: i32) -> bool {
	if !r.initialized || slot < 0 || int(slot) >= len(r.slots) {
		return false
	}
	s := &r.slots[slot]
	sync.mutex_lock(&s.mu)
	if s.state == .Free || s.wake == nil {
		sync.mutex_unlock(&s.mu)
		return false
	}
	s.state = .Free
	s.close_requested = false
	s.wake = nil
	s.wake_user = nil
	release_queued(r, s) // idempotent: zero when close already released
	sync.mutex_unlock(&s.mu)

	sync.mutex_lock(&r.free_mu)
	r.free_list[r.free_top] = slot
	r.free_top += 1
	r.live -= 1
	sync.mutex_unlock(&r.free_mu)
	return true
}

// release_queued drops every queued event and returns the byte total handed
// back to the process budget. Caller holds s.mu. This is the single release
// path close, drain and (later) adapter-error teardown share — exactly once
// by construction, because the queue is emptied under the lock.
@(private)
release_queued :: proc(r: ^Registry, s: ^Slot) -> int {
	freed := s.store_used
	s.events_head = 0
	s.events_count = 0
	s.store_head = 0
	s.store_used = 0
	if freed > 0 {
		sync.atomic_sub(&r.total_bytes, freed)
	}
	return freed
}

// drain_begin stops admission and refuses further output; WP95 wires it into
// the process lifecycle so `max_drain_time` stays the only deadline. Every
// owned stream is woken so its owner lane can flush what is queued and
// terminate.
drain_begin :: proc(r: ^Registry) {
	if !r.initialized {
		return
	}
	sync.atomic_store(&r.draining, true)
	for &s in r.slots {
		sync.mutex_lock(&s.mu)
		w := s.wake
		u := s.wake_user
		live := s.state == .Open
		sync.mutex_unlock(&s.mu)
		if live && w != nil {
			w(u)
		}
	}
	if r.wake != nil {
		r.wake(r.wake_user)
	}
}

// draining reports whether admission has stopped — the owner pump reads it to
// terminate a stream whose queue has emptied under drain.
draining :: proc(r: ^Registry) -> bool {
	if !r.initialized {
		return false
	}
	return sync.atomic_load(&r.draining)
}

// --- owner-lane consumption (WP90 wires the real writer to these) ----------

// next_event exposes the oldest queued event's bytes to the OWNER LANE ONLY.
// The view is valid until complete_event; no lock is held by the caller
// between the two, but only the owner lane may call them, which is the
// single-writer contract (G7-2) — enforced by construction in the adapter.
next_event :: proc(r: ^Registry, tok: Token) -> (data: []u8, ok: bool) {
	if !r.initialized || tok.slot < 0 || int(tok.slot) >= len(r.slots) {
		return nil, false
	}
	s := &r.slots[tok.slot]
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if s.generation != tok.generation || s.events_count == 0 {
		return nil, false
	}
	e := s.events[s.events_head]
	return s.store[e.offset:e.offset + e.len], true
}

// complete_event releases the oldest event after the owner lane wrote it.
complete_event :: proc(r: ^Registry, tok: Token) -> bool {
	if !r.initialized || tok.slot < 0 || int(tok.slot) >= len(r.slots) {
		return false
	}
	s := &r.slots[tok.slot]
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if s.generation != tok.generation || s.events_count == 0 {
		return false
	}
	e := s.events[s.events_head]
	// Advance the byte head past the event, absorbing any wrap gap the
	// reservation inserted before it.
	consumed := e.len
	if e.offset == 0 && s.store_head != 0 {
		consumed += len(s.store) - s.store_head // the gap that forced the wrap
	}
	s.store_head = (e.offset + e.len) % len(s.store)
	s.store_used -= consumed
	if s.store_used == 0 {
		s.store_head = 0
	}
	s.events_head = (s.events_head + 1) % len(s.events)
	s.events_count -= 1
	sync.atomic_sub(&r.total_bytes, consumed)
	return true
}

// --- owner-lane SLOT-based drain (graceful close) ---------------------------
//
// After `close` bumps the generation, the token-based `next_event`/
// `complete_event` refuse — correct for a stale PRODUCER, wrong for the OWNER,
// which must still flush the events queued before close. These slot-based
// twins ignore the generation because only the owning lane calls them, and
// they exist precisely so a graceful close delivers the final queued events
// before the terminator.

owner_next_event :: proc(r: ^Registry, slot: i32) -> (data: []u8, ok: bool) {
	if !r.initialized || slot < 0 || int(slot) >= len(r.slots) {
		return nil, false
	}
	s := &r.slots[slot]
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if s.state == .Free || s.events_count == 0 {
		return nil, false
	}
	e := s.events[s.events_head]
	return s.store[e.offset:e.offset + e.len], true
}

owner_complete_event :: proc(r: ^Registry, slot: i32) -> bool {
	if !r.initialized || slot < 0 || int(slot) >= len(r.slots) {
		return false
	}
	s := &r.slots[slot]
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if s.events_count == 0 {
		return false
	}
	e := s.events[s.events_head]
	consumed := e.len
	if e.offset == 0 && s.store_head != 0 {
		consumed += len(s.store) - s.store_head
	}
	s.store_head = (e.offset + e.len) % len(s.store)
	s.store_used -= consumed
	if s.store_used == 0 {
		s.store_head = 0
	}
	s.events_head = (s.events_head + 1) % len(s.events)
	s.events_count -= 1
	sync.atomic_sub(&r.total_bytes, consumed)
	return true
}

// owner_state reports (queued events, close_requested) for the owning lane, so
// the pump knows when a closed stream has flushed everything and may write the
// terminator. Slot-based, generation-independent.
owner_state :: proc(r: ^Registry, slot: i32) -> (queued: int, close_requested: bool, live: bool) {
	if !r.initialized || slot < 0 || int(slot) >= len(r.slots) {
		return 0, false, false
	}
	s := &r.slots[slot]
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	return s.events_count, s.close_requested, s.state != .Free
}

// --- corpus-observable state ------------------------------------------------

queued_events :: proc(r: ^Registry, tok: Token) -> int {
	if !r.initialized || tok.slot < 0 || int(tok.slot) >= len(r.slots) {
		return -1
	}
	s := &r.slots[tok.slot]
	sync.mutex_lock(&s.mu)
	defer sync.mutex_unlock(&s.mu)
	if s.generation != tok.generation {
		return -1
	}
	return s.events_count
}

live_streams :: proc(r: ^Registry) -> int {
	if !r.initialized {
		return -1
	}
	sync.mutex_lock(&r.free_mu)
	defer sync.mutex_unlock(&r.free_mu)
	return r.live
}

// WP92 — the accounting an operator sizes queues by. `note_abort` is called
// by the owner on its error/deadline teardown path.
Counters :: struct {
	refused_stream_full: int,
	refused_budget_full: int,
	aborted_slow:        int,
}

counters :: proc(r: ^Registry) -> Counters {
	if !r.initialized {
		return Counters{}
	}
	return Counters {
		refused_stream_full = sync.atomic_load(&r.refused_stream_full),
		refused_budget_full = sync.atomic_load(&r.refused_budget_full),
		aborted_slow        = sync.atomic_load(&r.aborted_slow),
	}
}

note_abort :: proc(r: ^Registry) {
	if r.initialized {
		sync.atomic_add(&r.aborted_slow, 1)
	}
}
