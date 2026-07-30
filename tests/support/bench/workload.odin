// WP26 benchmark harness — the workload half.
//
// A workload is a route table of a chosen size and shape, plus the exact list
// of request paths that will be replayed against it. Both halves are generated
// together, deliberately: a benchmark whose paths are written by hand drifts
// away from the table it is supposed to exercise, and the drift is invisible.
//
// TWO PROPERTIES THIS FILE EXISTS TO GUARANTEE:
//
// 1. THE SWEEP HITS THE WHOLE TABLE. `planning/phase-3-plan.md` names the
//    failure directly — a routing benchmark must not "only ever hit the first
//    route". A linear scan flatters itself spectacularly when every request
//    matches at index 0, and the flattery survives into a representation
//    decision. `paths` therefore covers every registered route, and the runner
//    walks it round-robin.
//
// 2. EVERY REQUEST IS VERIFIED, NOT COUNTED. This is RG-1's amendment, and it
//    is a measured failure rather than pedantry: a reference study threw away a
//    whole ApacheBench run because `ab` speaks HTTP/1.0, the strict server
//    rejected every request, and the tool cheerfully reported 100% non-2xx AS
//    THROUGHPUT. A load generator that gets rejected still reports a number,
//    and the number looks like a number. `dispatch_run` asserts the status of
//    every single response and refuses to return a timing if even one differs.
package bench_support

import "core:fmt"
import "core:time"
import web "druse:web"

// The status every benchmark handler commits.
//
// `no_content` is the cheapest responder that still commits: no body to encode,
// no allocation to attribute to the handler. What is being measured is the
// dispatch path, so the handler must contribute as close to nothing as the
// public surface allows — while still committing, because a dispatch that
// commits nothing is finalized to a standardized 500 and would measure the
// error path instead.
BENCH_STATUS :: web.Status.No_Content

// Shape decides what the route table is made of.
//
// The three shapes are not a taxonomy for its own sake. WP28 must choose a
// route representation from measurements, and the representations differ
// mainly in how they treat the static/parametric distinction — a structure
// that wins on all-static tables can lose badly on mixed ones. Measuring only
// one shape would answer a question nobody asked.
Shape :: enum u8 {
	All_Static,
	All_Param,
	Mixed,
}

// Workload owns its App, its generated patterns and its generated paths.
//
// OWNERSHIP, stated in the four terms the project's lifetime ledger uses:
// the caller creates it with `workload_init`; the Workload owns every string in
// `patterns` and `paths` and owns the App; both are valid until
// `workload_destroy`; and `workload_destroy` frees all of it exactly once.
//
// The App clones every pattern at registration (`route_register`), so the
// copies in `patterns` are this struct's own and must be freed here too.
Workload :: struct {
	app:      web.App,
	patterns: [dynamic]string,
	paths:    [dynamic]string,
}

@(private = "file")
bench_handler :: proc(ctx: ^web.Context) {
	web.no_content(ctx)
}

// workload_init builds a table of `count` routes in the given shape.
//
// Registration MAY allocate — the project's idiom guide says so explicitly, and
// this is registration. What must not allocate is the dispatch loop, and
// `dispatch_run` measures that separately.
workload_init :: proc(w: ^Workload, count: int, shape: Shape) -> bool {
	if count <= 0 {
		return false
	}

	w.app = web.app()

	patterns, perr := make([dynamic]string, 0, count)
	if perr != nil {
		return false
	}
	w.patterns = patterns

	paths, aerr := make([dynamic]string, 0, count)
	if aerr != nil {
		return false
	}
	w.paths = paths

	for i in 0 ..< count {
		parametric: bool
		switch shape {
		case .All_Static:
			parametric = false
		case .All_Param:
			parametric = true
		case .Mixed:
			// Alternating rather than blocked: a table whose parametric routes
			// are all at the end would let a linear scan short-circuit on the
			// static half and never pay for the rest.
			parametric = i % 2 == 1
		}

		pattern: string
		path: string
		if parametric {
			// Exactly ONE `:param`. WP4's dispatcher stores a pattern with more
			// than one as given and never matches it, so a two-param pattern
			// here would silently become a 404 and the semantic check would
			// (correctly) reject the whole run.
			pattern = fmt.aprintf("/bench/p%d/:id", i)
			path = fmt.aprintf("/bench/p%d/42", i)
		} else {
			pattern = fmt.aprintf("/bench/s%d", i)
			path = fmt.aprintf("/bench/s%d", i)
		}

		append(&w.patterns, pattern)
		append(&w.paths, path)
		web.get(&w.app, pattern, bench_handler)
	}

	return true
}

workload_destroy :: proc(w: ^Workload) {
	web.destroy(&w.app)
	for p in w.patterns {
		delete(p)
	}
	delete(w.patterns)
	for p in w.paths {
		delete(p)
	}
	delete(w.paths)
	w.patterns = nil
	w.paths = nil
}

// Run_Result reports a completed measurement, or why it is not one.
//
// `verified` is not a nicety. A run in which any response carried an
// unexpected status measured the error path, and its timing is worthless — so
// the caller must be unable to read a number without first reading whether the
// number means anything. That is why the timing lives behind `verified` rather
// than beside it.
Run_Result :: struct {
	verified:      bool,
	mismatches:    int,
	first_bad:     web.Status,
	first_bad_idx: int,
	summary:       Summary,
}

// dispatch_run replays the workload's paths `iterations` times and returns the
// distribution of per-dispatch durations.
//
// It measures ONE `web.test_request` per sample: real routing, real middleware
// chain, real response commit, no socket. That boundary is chosen on purpose.
// The socket adds scheduler and kernel noise measured in microseconds, and the
// difference between two route representations is measured in nanoseconds — so
// an end-to-end benchmark cannot see the thing WP28 has to decide. The socket
// tier answers a different question (protocol, keep-alive, concurrency) and is
// recorded separately.
//
// `warmup` iterations run first and are discarded. They are not superstition:
// the first dispatch through a cold table pays for page faults and branch
// predictor training that no steady-state request pays again, and including
// them puts a one-off cost into the p99 of every run.
dispatch_run :: proc(
	w: ^Workload,
	iterations: int,
	warmup: int,
	samples: ^Samples,
) -> Run_Result {
	result := Run_Result {
		verified = true,
	}
	if iterations <= 0 || len(w.paths) == 0 {
		result.verified = false
		return result
	}

	for i in 0 ..< warmup {
		res := web.test_request(&w.app, .GET, w.paths[i % len(w.paths)])
		// The warm-up is verified too. A table that 404s would otherwise warm
		// up the miss path and then be measured on it.
		if res.status != BENCH_STATUS {
			result.verified = false
			result.mismatches += 1
			if result.mismatches == 1 {
				result.first_bad = res.status
				result.first_bad_idx = i
			}
		}
	}

	for i in 0 ..< iterations {
		path := w.paths[i % len(w.paths)]

		start := time.tick_now()
		res := web.test_request(&w.app, .GET, path)
		elapsed := time.tick_since(start)

		if res.status != BENCH_STATUS {
			result.verified = false
			result.mismatches += 1
			if result.mismatches == 1 {
				result.first_bad = res.status
				result.first_bad_idx = i
			}
		}

		samples_add(samples, time.duration_nanoseconds(elapsed))
	}

	summary, ok := summarize(samples)
	if !ok {
		result.verified = false
		return result
	}
	result.summary = summary
	return result
}
