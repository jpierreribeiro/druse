// WP26 baseline runner — the program that produces the numbers.
//
// This is NOT part of the mandatory gate's fast path, and the split is
// deliberate. `tests/wp26-bench` asserts that the instrument is sound and
// finishes in milliseconds, so it can run on every push. This program runs the
// repeated, alternating sweep that a derived tolerance requires, which takes
// long enough that putting it in the pre-push gate would eventually get the
// gate switched off — and a gate nobody runs is worse than one that measures
// less.
//
// It prints one machine-readable line per measurement and a derived tolerance
// at the end. `build/check_wp26_bench.sh` runs it and captures the output into
// `planning/phase-2-baseline.md`.
//
// THE ALTERNATING ORDER, which is a correctness property rather than a style:
// the outer loop is the repetition and the inner loop is the configuration, not
// the other way round. Running all ten repetitions of one configuration
// back-to-back would let that configuration keep a warm cache and a trained
// branch predictor for its whole block, and would then hand the next
// configuration a cold one. The measured difference would be the order.
package wp26_runner

import "core:fmt"
import "core:os"
import bench "druse:tests/support/bench"

// The cardinality sweep. RG-2 requires 5, 50, 500 and 5,000 routes, because
// the only property a tree representation uniquely owns is SCALING — a sweep
// that stops at 500 cannot see the thing the shootout exists to decide.
CARDINALITIES :: [?]int{5, 50, 500, 5_000}

// At least ten, per WP26's derivation rule. More would tighten the estimate;
// ten is the floor below which a "tolerance" is a number chosen by taste.
REPETITIONS :: 10

// Iterations per measured run, and the warm-up that is discarded first.
//
// The warm-up is not superstition: the first dispatch through a cold table pays
// for page faults and branch-predictor training that no steady-state request
// pays again, and including it puts a one-off cost into every run's p99.
ITERATIONS :: 20_000
WARMUP :: 2_000

Config :: struct {
	routes: int,
	shape:  bench.Shape,
}

main :: proc() {
	configs: [dynamic]Config
	defer delete(configs)
	for count in CARDINALITIES {
		for shape in bench.Shape {
			append(&configs, Config{routes = count, shape = shape})
		}
	}

	// p95 per (config, repetition), so the spread can be derived per config.
	p95s := make([][]i64, len(configs))
	defer {
		for row in p95s {
			delete(row)
		}
		delete(p95s)
	}
	for i in 0 ..< len(configs) {
		p95s[i] = make([]i64, REPETITIONS)
	}

	fmt.println("# WP26 dispatch baseline")
	fmt.println("#")
	fmt.printf("# iterations=%d warmup=%d repetitions=%d\n", ITERATIONS, WARMUP, REPETITIONS)
	fmt.println("# columns: rep routes shape n min_ns p50_ns p95_ns p99_ns max_ns")

	failures := 0

	for rep in 0 ..< REPETITIONS {
		for cfg, ci in configs {
			w: bench.Workload
			if !bench.workload_init(&w, cfg.routes, cfg.shape) {
				fmt.eprintf("FAILED: workload_init(%d, %v)\n", cfg.routes, cfg.shape)
				os.exit(1)
			}

			samples: bench.Samples
			if !bench.samples_init(&samples, ITERATIONS) {
				fmt.eprintln("FAILED: samples_init")
				os.exit(1)
			}

			result := bench.dispatch_run(&w, ITERATIONS, WARMUP, &samples)

			// SEMANTIC EQUIVALENCE IS A GATE CONDITION, not advice. A run whose
			// responses were not what they should be measured the error path,
			// and its timing is worthless. RG-1's amendment exists because a
			// reference study threw away an entire ApacheBench comparison for
			// exactly this reason: the tool spoke HTTP/1.0, the strict server
			// rejected every request, and 100% non-2xx was reported AS
			// THROUGHPUT. A rejected load generator still reports a number.
			if !result.verified {
				fmt.eprintf(
					"FAILED: rep=%d routes=%d shape=%v -> %d mismatches, first was %v at index %d\n",
					rep,
					cfg.routes,
					cfg.shape,
					result.mismatches,
					result.first_bad,
					result.first_bad_idx,
				)
				failures += 1
			} else {
				s := result.summary
				fmt.printf(
					"%d %d %v %d %d %d %d %d %d\n",
					rep,
					cfg.routes,
					cfg.shape,
					s.n,
					s.min,
					s.p50,
					s.p95,
					s.p99,
					s.max,
				)
				p95s[ci][rep] = s.p95
			}

			bench.samples_destroy(&samples)
			bench.workload_destroy(&w)
		}
	}

	if failures > 0 {
		fmt.eprintf("FAILED: %d unverified runs; no baseline is emitted\n", failures)
		os.exit(1)
	}

	// THE TOLERANCE DERIVATION.
	//
	// For each configuration, the observed spread of its p95 across the ten
	// alternating repetitions, in basis points. A later change counts as a
	// regression only when it exceeds this floor — so the number comes from the
	// machine, and is RE-DERIVED rather than inherited whenever the hardware
	// changes.
	fmt.println("#")
	fmt.println("# derived tolerance: observed p95 spread across repetitions, in basis points")
	fmt.println("# columns: routes shape p95_min_ns p95_max_ns spread_bp")

	worst: i64 = 0
	for cfg, ci in configs {
		lo := p95s[ci][0]
		hi := p95s[ci][0]
		for v in p95s[ci][1:] {
			if v < lo {
				lo = v
			}
			if v > hi {
				hi = v
			}
		}
		bp, ok := bench.spread(p95s[ci])
		if !ok {
			fmt.eprintln("FAILED: tolerance not derivable")
			os.exit(1)
		}
		if bp > worst {
			worst = bp
		}
		fmt.printf("%d %v %d %d %d\n", cfg.routes, cfg.shape, lo, hi, bp)
	}

	fmt.println("#")
	fmt.printf("TOLERANCE_FLOOR_BP %d\n", worst)
	fmt.println(
		"# A later run is a regression only above this floor. It is a property of this machine.",
	)
}
