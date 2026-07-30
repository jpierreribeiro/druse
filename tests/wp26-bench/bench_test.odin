// WP26 — the benchmark harness, and the properties that make its numbers mean
// something.
//
// WHAT THIS SUITE ASSERTS, AND WHAT IT DELIBERATELY DOES NOT.
//
// It does NOT assert a speed. Not one test here fails because something got
// slower, and that is a design decision rather than an omission. FINDING-A
// measured this toolchain producing five different binaries from an IDENTICAL
// source tree, because the vendored `nbio` emits polymorphic instantiations
// whose mangled parameter names vary between runs. A nondeterministic linker
// means nondeterministic code layout, and layout moves branch prediction and
// cache behaviour. A gate that failed on a timing delta would fail randomly,
// and a gate that fails randomly gets switched off — which would cost more
// than the regression it was meant to catch.
//
// What it asserts instead is that THE INSTRUMENT IS SOUND:
//
//   * the percentile function returns values the machine actually observed;
//   * the tolerance derivation is relative and needs more than one run;
//   * every benchmarked response is verified, and — the load-bearing half —
//     that the verification is ABLE TO FAIL;
//   * the sweep hits the whole route table rather than route 0 forever;
//   * per-dispatch allocation is exactly constant, which is noise-free and is
//     where a representation change would actually show up.
//
// The timings themselves are produced by `build/check_wp26_bench.sh` and
// recorded in `planning/phase-2-baseline.md`, where a distribution can be
// reported honestly and a derived tolerance can sit beside it.
package test_wp26_bench

import "core:mem"
import "core:testing"
import bench "druse:tests/support/bench"
import web "druse:web"

// ---------------------------------------------------------------------------
// The instrument's own arithmetic.
// ---------------------------------------------------------------------------

// Nearest-rank means every percentile is a value that was really observed.
// An interpolated p99 is a number the machine never produced, and this project
// does not report those.
@(test)
wp26_percentile_returns_an_observed_value :: proc(t: ^testing.T) {
	sorted := []i64{10, 20, 30, 40, 50, 60, 70, 80, 90, 100}

	testing.expect_value(t, bench.percentile_sorted(sorted, 50), 50)
	testing.expect_value(t, bench.percentile_sorted(sorted, 95), 100)
	testing.expect_value(t, bench.percentile_sorted(sorted, 99), 100)

	// The edges are clamped rather than wrapping or indexing out of range.
	testing.expect_value(t, bench.percentile_sorted(sorted, 0), 10)
	testing.expect_value(t, bench.percentile_sorted(sorted, 100), 100)

	// An empty sample set has no percentile, and returns 0 rather than
	// pretending. The callers above it check `ok` before reading a summary.
	testing.expect_value(t, bench.percentile_sorted([]i64{}, 50), 0)
}

// The tolerance floor is derived from repeated runs, so it must be relative —
// an absolute nanosecond figure would be wrong the moment the hardware changes,
// and would be inherited silently rather than re-derived.
@(test)
wp26_spread_is_relative_and_needs_two_runs :: proc(t: ^testing.T) {
	// One run cannot establish a spread. Refusing is the point: a "tolerance"
	// derived from a single observation is a number chosen by taste wearing a
	// measurement's clothes.
	_, one_ok := bench.spread([]i64{100})
	testing.expect(t, !one_ok, "a single run must not yield a tolerance")

	// 100 -> 110 is 10%, which is 1000 basis points.
	bp, ok := bench.spread([]i64{100, 105, 110, 102})
	testing.expect(t, ok, "four runs must yield a spread")
	testing.expect_value(t, bp, 1000)

	// Identical runs mean no observed noise, which is a valid answer.
	zero, zero_ok := bench.spread([]i64{200, 200, 200})
	testing.expect(t, zero_ok, "identical runs still yield a spread")
	testing.expect_value(t, zero, 0)
}

// ---------------------------------------------------------------------------
// The workload.
// ---------------------------------------------------------------------------

// A routing benchmark that only ever hits the first route flatters a linear
// scan spectacularly, and the flattery survives into a representation choice.
// `planning/phase-3-plan.md` names this failure explicitly; this test pins the
// property that prevents it.
@(test)
wp26_the_sweep_covers_every_route :: proc(t: ^testing.T) {
	w: bench.Workload
	testing.expect(t, bench.workload_init(&w, 64, .Mixed), "the workload must build")
	defer bench.workload_destroy(&w)

	testing.expect_value(t, len(w.paths), 64)
	testing.expect_value(t, len(w.patterns), 64)

	// Every generated path must be distinct: 64 paths that are all the same
	// string would satisfy a length check and still hit one route.
	seen := make(map[string]bool)
	defer delete(seen)
	for p in w.paths {
		seen[p] = true
	}
	testing.expect_value(t, len(seen), 64)

	// And every one of them must actually match a registered route, or the
	// benchmark would be timing the miss path.
	for p in w.paths {
		res := web.test_request(&w.app, .GET, p)
		testing.expect_value(t, res.status, bench.BENCH_STATUS)
	}
}

// The three shapes exist because route representations differ mainly in how
// they treat the static/parametric distinction, and a structure that wins on
// all-static tables can lose on mixed ones.
@(test)
wp26_every_shape_dispatches :: proc(t: ^testing.T) {
	for shape in bench.Shape {
		w: bench.Workload
		testing.expect(t, bench.workload_init(&w, 16, shape), "the workload must build")
		defer bench.workload_destroy(&w)

		samples: bench.Samples
		testing.expect(t, bench.samples_init(&samples, 64), "samples must reserve")
		defer bench.samples_destroy(&samples)

		result := bench.dispatch_run(&w, 64, 8, &samples)
		testing.expect(t, result.verified, "every shape must dispatch cleanly")
		testing.expect_value(t, result.mismatches, 0)
		testing.expect_value(t, result.summary.n, 64)
		// A monotonic clock over real work cannot report a zero-width
		// distribution; if max were 0 the timer is not wired to anything.
		testing.expect(t, result.summary.max > 0, "the clock must have measured something")
	}
}

// ---------------------------------------------------------------------------
// Semantic equivalence — and the control that makes it worth asserting.
// ---------------------------------------------------------------------------

// RG-1's amendment, as a test. A reference study threw away an entire
// ApacheBench run because `ab` speaks HTTP/1.0, the strict server rejected
// every request, and the tool reported 100% non-2xx AS THROUGHPUT. A load
// generator that gets rejected still reports a number.
@(test)
wp26_a_clean_run_is_verified :: proc(t: ^testing.T) {
	w: bench.Workload
	testing.expect(t, bench.workload_init(&w, 32, .Mixed), "the workload must build")
	defer bench.workload_destroy(&w)

	samples: bench.Samples
	testing.expect(t, bench.samples_init(&samples, 128), "samples must reserve")
	defer bench.samples_destroy(&samples)

	result := bench.dispatch_run(&w, 128, 16, &samples)
	testing.expect(t, result.verified, "a well-formed workload must verify")
	testing.expect_value(t, result.mismatches, 0)
}

// THE POSITIVE CONTROL, and the most important test in this file.
//
// The assertion above proves nothing on its own: if `dispatch_run` could never
// report a mismatch — a typo in the comparison, a status that is never
// checked — then `verified == true` would be true of everything, including a
// run in which the server answered 404 to every request. So the verification
// must be shown to FAIL when it should.
//
// The workload is corrupted the way a real mistake would corrupt it: a path
// that no registered pattern matches, which is exactly what a route
// representation with an off-by-one would produce.
@(test)
wp26_an_unmatched_path_makes_the_run_unverified :: proc(t: ^testing.T) {
	w: bench.Workload
	testing.expect(t, bench.workload_init(&w, 8, .All_Static), "the workload must build")
	defer bench.workload_destroy(&w)

	// Replace one path with one nothing matches. The Workload owns its paths,
	// so the replaced string is freed here and the new one is handed over to be
	// freed by `workload_destroy` — the ownership contract does not get a
	// holiday because this is a test.
	delete(w.paths[3])
	w.paths[3] = "/bench/nothing-matches-this"

	samples: bench.Samples
	testing.expect(t, bench.samples_init(&samples, 32), "samples must reserve")
	defer bench.samples_destroy(&samples)

	result := bench.dispatch_run(&w, 32, 0, &samples)

	testing.expect(t, !result.verified, "an unmatched path must invalidate the run")
	testing.expect(t, result.mismatches > 0, "the mismatch must be counted")
	testing.expect_value(t, result.first_bad, web.Status.Not_Found)

	// The replacement is a literal, not owned storage; hand back an owned
	// string so `workload_destroy` frees a consistent set.
	w.paths[3] = ""
}

// ---------------------------------------------------------------------------
// Allocation — the one quantity here with no noise at all.
// ---------------------------------------------------------------------------

// This is where a representation change would actually be caught by a gate.
//
// Timing on this toolchain cannot distinguish a 3% change from layout noise.
// An allocation count distinguishes 68 from 69 with total certainty, on any
// machine, every time. So the gate's regression assertion is allocation-shaped,
// and the timing lives in a recorded baseline instead.
//
// THE PERIMETER, stated because the project's capacity ledger requires it: this
// measures `web.test_request`, which includes the test transport and the
// response recorder. It is NOT the perimeter of Phase-2 claim C-5, which
// measured zero allocations around `driver_run`/`driver_cleanup` and explicitly
// NOT around `test_request`. Nothing here widens C-5, and no number produced
// here may be quoted as if it did.
//
// WHERE THE TRACKER IS INSTALLED, and why it is not a detail. The App captures
// an allocator at registration (`route_register` stores
// `a.private.routes.allocator`) and keeps using it afterwards. A tracker
// installed AFTER the App exists therefore sees none of the App's own work.
// The tracker here is installed BEFORE `workload_init` so that the App's
// allocator IS the tracked one — which is the only arrangement in which the
// dispatch delta means what it claims.
//
// `context.temp_allocator` is deliberately NOT tracked. A probe measured this
// path performing zero temp allocations, so tracking it adds nothing — and
// wrapping the temp allocator underneath the `odin test` runner's own memory
// tracking hangs the runner, which is a thing worth writing down rather than
// rediscovering.
//
// WHAT IS ASSERTED, and what is refused. No threshold is invented here: a
// "must be under N allocations" test would be a number chosen by taste. What is
// asserted is the three properties that make a recorded number trustworthy —
// registration cost is independent of the measurement, dispatch cost scales
// with dispatches, and identical input produces an identical count. The counts
// themselves are recorded in `planning/phase-2-baseline.md`, where WP27's
// allocation audit will start from them.
@(test)
wp26_dispatch_allocation_is_deterministic :: proc(t: ^testing.T) {
	measure :: proc(
		iterations: int,
	) -> (
		registration: i64,
		dispatch: i64,
		ok: bool,
	) {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)

		// The whole context is replaced, so everything constructed below —
		// including the App and every pattern it clones — allocates through the
		// tracker. It is restored by scope exit.
		ctx := context
		ctx.allocator = mem.tracking_allocator(&track)
		context = ctx

		w: bench.Workload
		if !bench.workload_init(&w, 32, .Mixed) {
			return 0, 0, false
		}
		defer bench.workload_destroy(&w)
		registration = i64(track.total_allocation_count)

		samples: bench.Samples
		if !bench.samples_init(&samples, iterations) {
			return 0, 0, false
		}
		defer bench.samples_destroy(&samples)

		// The sample array is reserved before the fence, so its allocation is
		// not counted as dispatch work and no `append` reallocates inside the
		// measured region.
		before := i64(track.total_allocation_count)
		result := bench.dispatch_run(&w, iterations, 0, &samples)
		after := i64(track.total_allocation_count)

		if !result.verified {
			return 0, 0, false
		}
		return registration, after - before, true
	}

	reg_64, disp_64, ok_64 := measure(64)
	testing.expect(t, ok_64, "the 64-iteration run must verify")
	reg_128, disp_128, ok_128 := measure(128)
	testing.expect(t, ok_128, "the 128-iteration run must verify")
	reg_again, disp_again, ok_again := measure(64)
	testing.expect(t, ok_again, "the repeat run must verify")

	// 1. Registration cost belongs to the table, not to the measurement. If it
	//    moved with the iteration count, the differencing below would be
	//    measuring the harness rather than the framework.
	testing.expect_value(t, reg_128, reg_64)
	testing.expect_value(t, reg_again, reg_64)
	testing.expect(t, reg_64 > 0, "registering 32 routes must allocate")

	// 2. Dispatch cost scales with dispatches. If it did not, the fence is in
	//    the wrong place and the delta is not dispatch work at all.
	testing.expect(t, disp_128 > disp_64, "twice the dispatches must allocate more")
	testing.expect(t, disp_64 > 0, "dispatch through the test transport allocates")

	// 3. THE LOAD-BEARING ONE: identical input, identical count, exactly. Every
	//    allocation assertion in this repository rests on the allocator being
	//    deterministic. If this ever goes flaky, they are all worth less than
	//    they appear, and that is a finding rather than a retry.
	testing.expect_value(t, disp_again, disp_64)
}
