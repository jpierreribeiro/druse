// TRANSPORT AUDIT B4 — A BOUNDED TICK OF ONE SECOND OR MORE MUST WORK.
//
// `_flush_submissions` built its `linux.Time_Spec` by putting the WHOLE
// duration into `tv_nsec` and never setting `tv_sec`, so any timeout of one
// second or more produced `tv_nsec >= 1e9` — a value POSIX defines as invalid
// for a timespec.
//
// THE CONTROL WAS RUN AND IT DID NOT FAIL. Restoring
// `ts.time_nsec = uint(timeout)` and re-running these three cases on Linux
// 6.18.5 passes all of them: the kernel NORMALISES an over-large `tv_nsec` on
// the io_uring EXT_ARG path rather than rejecting it, and the tick waits the
// correct duration anyway. The audit that produced this fix predicted EINVAL
// and a consequently dead lane; that prediction is **falsified on this kernel**
// and the correction is recorded in
// `docs/reports/2026-07-27-subsystem-audit-and-fixes.md`.
//
// The split stays, because relying on a normalisation that no interface
// documents is fragile across kernels and io_uring paths and costs nothing to
// avoid. But it is a conformance repair, NOT a fix for an observed failure, and
// these tests are a REGRESSION GUARD, not evidence that a defect was closed.
// They pass with the fix and without it. Said plainly so that nobody later
// mistakes a green run here for a controlled result.
//
// The other three transport fixes in 44bdcda are races and need the stress
// harnesses in `experiments/23-accept-stall` and `experiments/24-shutdown-race`.
package test_nbio_timeout

import "core:nbio"
import "core:testing"
import "core:time"

// A tick with no operations outstanding returns when the timeout expires, so
// these measure the timeout path itself rather than any I/O behaviour.

@(test)
bounded_tick_of_one_second_is_not_einval :: proc(t: ^testing.T) {
	err := nbio.acquire_thread_event_loop()
	if err != nil {
		testing.fail_now(t, "could not acquire an event loop")
	}
	defer nbio.release_thread_event_loop()

	start := time.now()
	terr := nbio.tick(time.Second)
	elapsed := time.since(start)

	testing.expectf(t, terr == nil, "a 1 s bounded tick must not error, got %v", terr)
	// It must actually have waited, not returned instantly with a rejected
	// timespec. Generous lower bound: the failure mode is ~0 ms, not 900 ms.
	testing.expectf(
		t,
		elapsed >= 500 * time.Millisecond,
		"a 1 s bounded tick must wait, elapsed %v",
		elapsed,
	)
}

@(test)
bounded_tick_past_one_second_is_not_einval :: proc(t: ^testing.T) {
	err := nbio.acquire_thread_event_loop()
	if err != nil {
		testing.fail_now(t, "could not acquire an event loop")
	}
	defer nbio.release_thread_event_loop()

	// 2.5 s exercises both halves of the split: a non-zero seconds field AND a
	// non-zero sub-second remainder.
	start := time.now()
	terr := nbio.tick(2500 * time.Millisecond)
	elapsed := time.since(start)

	testing.expectf(t, terr == nil, "a 2.5 s bounded tick must not error, got %v", terr)
	testing.expectf(
		t,
		elapsed >= 2 * time.Second,
		"a 2.5 s bounded tick must wait about that long, elapsed %v",
		elapsed,
	)
}

@(test)
sub_second_bound_still_works :: proc(t: ^testing.T) {
	// The regression guard for the fix itself: the durations the tree already
	// used must be unchanged. This case passes before AND after, which is why
	// it cannot stand alone as evidence.
	err := nbio.acquire_thread_event_loop()
	if err != nil {
		testing.fail_now(t, "could not acquire an event loop")
	}
	defer nbio.release_thread_event_loop()

	start := time.now()
	terr := nbio.tick(100 * time.Millisecond)
	elapsed := time.since(start)

	testing.expectf(t, terr == nil, "a 100 ms bounded tick must not error, got %v", terr)
	testing.expectf(
		t,
		elapsed >= 50 * time.Millisecond,
		"a 100 ms bounded tick must wait, elapsed %v",
		elapsed,
	)
}
