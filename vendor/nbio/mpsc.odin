#+private
package nbio

import "base:runtime"

import "core:sync"

// THE WAKE INVARIANT (DRUSE, transport audit T1) — this queue is only
// correct because of a rule that lives entirely outside it.
//
// `mpsc_enqueue` claims a slot with `atomic_add(&head)` and stores into it as
// a SECOND step. `mpsc_dequeue` reads `buffer[tail]` and STOPS on nil. So a
// producer preempted between its claim and its store leaves a hole at `tail`,
// and every item behind that hole is invisible to the consumer — not lost, but
// not delivered either, until something makes the consumer look again.
//
//     producer A: head=5 claimed .......... (preempted, buffer[5] still nil)
//     producer B: head=6 claimed, stored    (buffer[6] = op)
//     consumer:   tail=5 -> nil -> stops    (B's op is stranded behind A)
//
// What rescues B's item is that A, once it resumes and stores, performs its OWN
// eventfd wake — and that wake re-runs the drain, which now finds both. The
// queue therefore depends on: EVERY PRODUCER WAKES THE LOOP AFTER ITS STORE
// COMPLETES. Nothing in this file enforces that; `exec` in nbio.odin is where
// it is honoured, and `exec`'s `trigger_wake_up := false` is the one way to
// break it (see the warning there).
//
// The consumer is single by construction (the owning event-loop thread), so
// `tail` needs no atomics.
Multi_Producer_Single_Consumer :: struct {
	count:  int,
	head:   int,
	tail:   int,
	buffer: []rawptr,
	mask:   int,
}

mpsc_init :: proc(mpscq: ^Multi_Producer_Single_Consumer, cap: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	assert(runtime.is_power_of_two_int(cap), "cap must be a power of 2")
	mpscq.buffer = make([]rawptr, cap, allocator) or_return
	mpscq.mask   = cap-1
	sync.atomic_thread_fence(.Release)
	return nil
}

mpsc_destroy :: proc(mpscq: ^Multi_Producer_Single_Consumer, allocator: runtime.Allocator) {
	delete(mpscq.buffer, allocator)
}

mpsc_enqueue :: proc(mpscq: ^Multi_Producer_Single_Consumer, obj: rawptr) -> bool {
	count := sync.atomic_add_explicit(&mpscq.count, 1, .Acquire)
	if count >= len(mpscq.buffer) {
		sync.atomic_sub_explicit(&mpscq.count, 1, .Release)
		return false
	}

	head := sync.atomic_add_explicit(&mpscq.head, 1, .Acquire)
	assert(mpscq.buffer[head & mpscq.mask] == nil)
	rv := sync.atomic_exchange_explicit(&mpscq.buffer[head & mpscq.mask], obj, .Release)
	assert(rv == nil)
	return true
}

mpsc_dequeue :: proc(mpscq: ^Multi_Producer_Single_Consumer) -> rawptr {
	ret := sync.atomic_exchange_explicit(&mpscq.buffer[mpscq.tail], nil, .Acquire)
	if ret == nil {
		return nil
	}

	mpscq.tail += 1
	if mpscq.tail >= len(mpscq.buffer) {
		mpscq.tail = 0
	}
	r := sync.atomic_sub_explicit(&mpscq.count, 1, .Release)
	assert(r > 0)
	return ret
}

mpsc_count :: proc(mpscq: ^Multi_Producer_Single_Consumer) -> int {
	return sync.atomic_load_explicit(&mpscq.count, .Relaxed)
}

mpsc_cap :: proc(mpscq: ^Multi_Producer_Single_Consumer) -> int {
	return len(mpscq.buffer)
}