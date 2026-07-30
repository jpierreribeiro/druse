// WP28 — the shootout's gate half: the candidates agree, or no timing counts.
//
// RG-1's amendment is the reason this file exists before any number is
// reported. **Every candidate must do the same work.** A representation that
// returns the wrong route, or misses a route it should find, will look
// magnificent in a benchmark — a scan that stops early is exactly what "fast"
// looks like from the outside.
//
// The reference study RG-1 cites threw away a whole comparison because the load
// generator spoke HTTP/1.0 and 100% non-2xx was reported as throughput. This
// suite is the same guard, pointed inward: the entrants are checked against
// each other before they are timed against each other.
//
// It asserts NO TIMING. FINDING-E measured a ±57.6% p95 spread on unchanged
// code, so a timing assertion in the gate would fail randomly. The numbers come
// from `tests/wp28-runner`, run by hand, and are recorded in
// `planning/router-shootout.md`.
package test_wp28_shootout

import "core:mem"
import "core:testing"
import sh "druse:tests/support/shootout"

// Every candidate, matched through its own entry point. There is no vtable and
// no `rawptr` dispatch: the project's idiom guide rejects OOP simulation, and a
// shared indirection would also add a call the real router would never make.
@(private = "file")
match_all :: proc(
	lin: ^sh.Linear,
	imp: ^sh.Linear_Improved,
	buc: ^sh.Bucketed,
	hyb: ^sh.Hybrid,
	rp: ^sh.Radix_Ptr,
	ri: ^sh.Radix_Idx,
	ra: ^sh.Radix_Arr,
	path: string,
) -> [7]sh.Match {
	return [7]sh.Match {
		sh.linear_match(lin, path),
		sh.linear_improved_match(imp, path),
		sh.bucketed_match(buc, path),
		sh.hybrid_match(hyb, path),
		sh.radix_ptr_match(rp, path),
		sh.radix_idx_match(ri, path),
		sh.radix_arr_match(ra, path),
	}
}

@(private = "file")
CANDIDATE_NAMES :: [7]string {
	"linear",
	"linear_improved",
	"bucketed",
	"hybrid",
	"radix_ptr",
	"radix_idx",
	"radix_arr",
}

// THE LOAD-BEARING TEST. Seven representations, every shape, every cardinality
// the gate can afford, every registered path plus a set of deliberate misses —
// and all seven must return byte-identical answers.
@(test)
wp28_every_candidate_agrees :: proc(t: ^testing.T) {
	names := CANDIDATE_NAMES

	for shape in sh.Shape {
		for count in ([]int{1, 5, 50, 200}) {
			patterns, paths := sh.generate_patterns(count, shape)
			defer sh.free_patterns(&patterns, &paths)

			lin: sh.Linear;imp: sh.Linear_Improved;buc: sh.Bucketed
			hyb: sh.Hybrid;rp: sh.Radix_Ptr;ri: sh.Radix_Idx;ra: sh.Radix_Arr

			testing.expect(t, sh.linear_build(&lin, patterns[:]), "linear must build")
			defer sh.linear_destroy(&lin)
			testing.expect(t, sh.linear_improved_build(&imp, patterns[:]), "improved must build")
			defer sh.linear_improved_destroy(&imp)
			testing.expect(t, sh.bucketed_build(&buc, patterns[:]), "bucketed must build")
			defer sh.bucketed_destroy(&buc)
			testing.expect(t, sh.hybrid_build(&hyb, patterns[:]), "hybrid must build")
			defer sh.hybrid_destroy(&hyb)
			testing.expect(t, sh.radix_ptr_build(&rp, patterns[:]), "radix_ptr must build")
			defer sh.radix_ptr_destroy(&rp)
			testing.expect(t, sh.radix_idx_build(&ri, patterns[:]), "radix_idx must build")
			defer sh.radix_idx_destroy(&ri)
			testing.expect(t, sh.radix_arr_build(&ra, patterns[:]), "radix_arr must build")
			defer sh.radix_arr_destroy(&ra)

			// Every registered path must be found, by all six, identically.
			for path in paths {
				results := match_all(&lin, &imp, &buc, &hyb, &rp, &ri, &ra, path)
				for r, i in results {
					testing.expectf(
						t,
						r.ok,
						"%s missed a registered path %s (shape %v, %d routes)",
						names[i],
						path,
						shape,
						count,
					)
					testing.expectf(
						t,
						r.route == results[0].route,
						"%s disagreed on route for %s: %d vs %d",
						names[i],
						path,
						r.route,
						results[0].route,
					)
					testing.expectf(
						t,
						r.param == results[0].param,
						"%s disagreed on param for %s: %q vs %q",
						names[i],
						path,
						r.param,
						results[0].param,
					)
				}
			}

			// And the misses. A candidate that never misses is a candidate that
			// matches everything, which would be both very fast and useless.
			misses := []string {
				"/",
				"/bench",
				"/bench/nope",
				"/bench/s0/extra",
				"/nothing/at/all",
				"/bench/s0/",
			}
			for path in misses {
				results := match_all(&lin, &imp, &buc, &hyb, &rp, &ri, &ra, path)
				for r, i in results {
					testing.expectf(
						t,
						r.ok == results[0].ok,
						"%s disagreed on whether %s matches (%v vs %v, shape %v, %d routes)",
						names[i],
						path,
						r.ok,
						results[0].ok,
						shape,
						count,
					)
					if r.ok {
						testing.expectf(
							t,
							r.route == results[0].route,
							"%s disagreed on route for %s",
							names[i],
							path,
						)
					}
				}
			}
		}
	}
}

// THE POSITIVE CONTROL for the agreement test above.
//
// If `match_all` compared things that can never differ — a copy-paste that
// called the same matcher seven times, say — then "all seven agree" would be true
// of everything and the test above would prove nothing. So a disagreement must
// be constructible and must be visible.
//
// A table where a static and a parametric route describe the SAME path is where
// representations genuinely diverge: precedence has to be decided, and a
// candidate that decides it by registration order rather than by class gets a
// different answer.
@(test)
wp28_precedence_is_where_candidates_could_diverge :: proc(t: ^testing.T) {
	// `/bench/fixed` is reachable two ways: as a static route, and through the
	// parametric `/bench/:id`. Static must win, in all seven.
	patterns := []string{"/bench/:id", "/bench/fixed"}

	lin: sh.Linear;imp: sh.Linear_Improved;buc: sh.Bucketed
	hyb: sh.Hybrid;rp: sh.Radix_Ptr;ri: sh.Radix_Idx;ra: sh.Radix_Arr
	testing.expect(t, sh.linear_build(&lin, patterns), "linear must build")
	defer sh.linear_destroy(&lin)
	testing.expect(t, sh.linear_improved_build(&imp, patterns), "improved must build")
	defer sh.linear_improved_destroy(&imp)
	testing.expect(t, sh.bucketed_build(&buc, patterns), "bucketed must build")
	defer sh.bucketed_destroy(&buc)
	testing.expect(t, sh.hybrid_build(&hyb, patterns), "hybrid must build")
	defer sh.hybrid_destroy(&hyb)
	testing.expect(t, sh.radix_ptr_build(&rp, patterns), "radix_ptr must build")
	defer sh.radix_ptr_destroy(&rp)
	testing.expect(t, sh.radix_idx_build(&ri, patterns), "radix_idx must build")
	defer sh.radix_idx_destroy(&ri)
	testing.expect(t, sh.radix_arr_build(&ra, patterns), "radix_arr must build")
	defer sh.radix_arr_destroy(&ra)

	names := CANDIDATE_NAMES

	// The static route is registered SECOND, so a candidate that honours
	// registration order instead of class precedence returns route 0 here — the
	// exact defect this control exists to be able to see.
	results := match_all(&lin, &imp, &buc, &hyb, &rp, &ri, &ra, "/bench/fixed")
	for r, i in results {
		testing.expectf(t, r.ok, "%s must match the static route", names[i])
		testing.expectf(
			t,
			r.route == 1,
			"%s let the parametric route win at /bench/fixed (got route %d); static must win",
			names[i],
			r.route,
		)
		testing.expectf(t, r.param == "", "%s captured a param on a static match", names[i])
	}

	// And the parametric route still works for anything else, with the value
	// captured as a VIEW rather than a copy.
	other := match_all(&lin, &imp, &buc, &hyb, &rp, &ri, &ra, "/bench/42")
	for r, i in other {
		testing.expectf(t, r.ok, "%s must match the parametric route", names[i])
		testing.expectf(t, r.route == 0, "%s matched the wrong route for /bench/42", names[i])
		testing.expectf(t, r.param == "42", "%s captured %q, expected \"42\"", names[i], r.param)
	}
}

// Matching must allocate nothing, in every candidate.
//
// This is the one property in the shootout with no noise at all, and it is a
// DISQUALIFIER rather than a score: a representation that allocates per request
// has lost regardless of its timing, because the timing is measured on a
// machine whose p95 spread is ±57.6% and the allocation is measured exactly.
//
// The map-based candidates are the ones under suspicion here — the idiom guide
// warns about maps in hot dispatch, and this turns the warning into a number.
@(test)
wp28_matching_allocates_nothing :: proc(t: ^testing.T) {
	patterns, paths := sh.generate_patterns(64, .Mixed)
	defer sh.free_patterns(&patterns, &paths)

	lin: sh.Linear;imp: sh.Linear_Improved;buc: sh.Bucketed
	hyb: sh.Hybrid;rp: sh.Radix_Ptr;ri: sh.Radix_Idx;ra: sh.Radix_Arr
	testing.expect(t, sh.linear_build(&lin, patterns[:]), "linear must build")
	defer sh.linear_destroy(&lin)
	testing.expect(t, sh.linear_improved_build(&imp, patterns[:]), "improved must build")
	defer sh.linear_improved_destroy(&imp)
	testing.expect(t, sh.bucketed_build(&buc, patterns[:]), "bucketed must build")
	defer sh.bucketed_destroy(&buc)
	testing.expect(t, sh.hybrid_build(&hyb, patterns[:]), "hybrid must build")
	defer sh.hybrid_destroy(&hyb)
	testing.expect(t, sh.radix_ptr_build(&rp, patterns[:]), "radix_ptr must build")
	defer sh.radix_ptr_destroy(&rp)
	testing.expect(t, sh.radix_idx_build(&ri, patterns[:]), "radix_idx must build")
	defer sh.radix_idx_destroy(&ri)
	testing.expect(t, sh.radix_arr_build(&ra, patterns[:]), "radix_arr must build")
	defer sh.radix_arr_destroy(&ra)

	// The tracker goes on AFTER every table is built, because building is
	// allowed to allocate and lookup is not.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	ctx := context
	ctx.allocator = mem.tracking_allocator(&track)
	context = ctx

	hits := 0
	for path in paths {
		results := match_all(&lin, &imp, &buc, &hyb, &rp, &ri, &ra, path)
		for r in results {
			if r.ok {
				hits += 1
			}
		}
	}

	// The positive half: the loop really did the work. Without it, a matcher
	// that returned immediately would satisfy the zero-allocation assertion
	// perfectly.
	testing.expect_value(t, hits, len(paths) * 7)
	testing.expect_value(t, track.total_allocation_count, 0)
}
