// WP28 — the shootout runner. Six representations, measured against each other.
//
// It reports numbers and chooses nothing. The choice is made in
// `planning/router-shootout.md`, from these numbers plus the stopping rule
// FINDING-E derived: **the cardinalities where this machine can discriminate
// are 500 and 5,000.** At 5 routes the p95 spread of unchanged code is ±57.6%,
// so a candidate "winning" there by 20% has won nothing measurable.
//
// The alternating order is the same as WP26's and for the same reason: the
// outer loop is the repetition, the inner loops are the configuration and the
// candidate. Measuring all ten repetitions of one candidate back to back would
// hand it a warm cache for its whole block and the next candidate a cold one,
// and the measured difference would be the order.
//
// Correctness is NOT checked here — `tests/wp28-shootout` does that in the
// gate, and this program refuses to be the place where a wrong answer looks
// fast.
package wp28_runner

import "core:fmt"
import "core:os"
import "core:time"
import bench "druse:tests/support/bench"
import sh "druse:tests/support/shootout"

CARDINALITIES :: [?]int{5, 50, 500, 5_000}
REPETITIONS :: 10
WARMUP_FRACTION :: 10

// Iterations shrink as the table grows, because the linear baseline is O(n) per
// lookup and a fixed count would make the 5,000-route sweep take longer than
// anyone will wait — which is itself a finding about the baseline. `n` is
// reported per row, so nothing here is hidden by the scaling.
iterations_for :: proc(count: int) -> int {
	switch {
	case count <= 50:
		return 20_000
	case count <= 500:
		return 10_000
	case:
		return 2_000
	}
}

CANDIDATES :: [?]string {
	"linear",
	"linear_improved",
	"bucketed",
	"hybrid",
	"radix_ptr",
	"radix_idx",
	"radix_arr",
}

main :: proc() {
	fmt.println("# WP28 route representation shootout")
	fmt.printf("# repetitions=%d, alternating (repetition outer, candidate inner)\n", REPETITIONS)
	fmt.println("# columns: rep candidate routes shape n min_ns p50_ns p95_ns p99_ns max_ns")

	names := CANDIDATES

	// p95 per (candidate, config, repetition), for the medians and spreads at
	// the end.
	config_count := len(CARDINALITIES) * len(sh.Shape)
	p95 := make([][]i64, len(names) * config_count)
	defer {
		for row in p95 {
			delete(row)
		}
		delete(p95)
	}
	for i in 0 ..< len(p95) {
		p95[i] = make([]i64, REPETITIONS)
	}

	for rep in 0 ..< REPETITIONS {
		ci := 0
		for count in CARDINALITIES {
			for shape in sh.Shape {
				patterns, paths := sh.generate_patterns(count, shape)
				iterations := iterations_for(count)
				warmup := iterations / WARMUP_FRACTION

				lin: sh.Linear;imp: sh.Linear_Improved;buc: sh.Bucketed
				hyb: sh.Hybrid;rp: sh.Radix_Ptr;ri: sh.Radix_Idx;ra: sh.Radix_Arr
				ok := sh.linear_build(&lin, patterns[:])
				ok &= sh.linear_improved_build(&imp, patterns[:])
				ok &= sh.bucketed_build(&buc, patterns[:])
				ok &= sh.hybrid_build(&hyb, patterns[:])
				ok &= sh.radix_ptr_build(&rp, patterns[:])
				ok &= sh.radix_idx_build(&ri, patterns[:])
				ok &= sh.radix_arr_build(&ra, patterns[:])
				if !ok {
					fmt.eprintf("FAILED: a table did not build at %d/%v\n", count, shape)
					os.exit(1)
				}

				for cand in 0 ..< len(names) {
					samples: bench.Samples
					if !bench.samples_init(&samples, iterations) {
						fmt.eprintln("FAILED: samples_init")
						os.exit(1)
					}

					misses := 0

					for i in 0 ..< warmup {
						path := paths[i % len(paths)]
						m := run_one(cand, &lin, &imp, &buc, &hyb, &rp, &ri, &ra, path)
						if !m.ok {
							misses += 1
						}
					}

					for i in 0 ..< iterations {
						path := paths[i % len(paths)]
						start := tick()
						m := run_one(cand, &lin, &imp, &buc, &hyb, &rp, &ri, &ra, path)
						bench.samples_add(&samples, elapsed(start))
						if !m.ok {
							misses += 1
						}
					}

					// Semantic equivalence as a gate condition: a candidate that
					// missed a registered path measured the miss path, and its
					// timing is worthless. The gate suite proves agreement; this
					// is the belt to that pair of braces.
					if misses > 0 {
						fmt.eprintf(
							"FAILED: %s missed %d registered paths at %d/%v\n",
							names[cand],
							misses,
							count,
							shape,
						)
						os.exit(1)
					}

					summary, sok := bench.summarize(&samples)
					if !sok {
						fmt.eprintln("FAILED: no summary")
						os.exit(1)
					}
					fmt.printf(
						"%d %s %d %v %d %d %d %d %d %d\n",
						rep,
						names[cand],
						count,
						shape,
						summary.n,
						summary.min,
						summary.p50,
						summary.p95,
						summary.p99,
						summary.max,
					)
					p95[cand * config_count + ci][rep] = summary.p95
					bench.samples_destroy(&samples)
				}

				sh.linear_destroy(&lin)
				sh.linear_improved_destroy(&imp)
				sh.bucketed_destroy(&buc)
				sh.hybrid_destroy(&hyb)
				sh.radix_ptr_destroy(&rp)
				sh.radix_idx_destroy(&ri)
				sh.radix_arr_destroy(&ra)
				sh.free_patterns(&patterns, &paths)
				ci += 1
			}
		}
	}

	fmt.println("#")
	fmt.println("# median p95 per candidate and configuration, plus that cell's own spread")
	fmt.println("# columns: candidate routes shape median_p95_ns spread_bp")

	for cand in 0 ..< len(names) {
		ci := 0
		for count in CARDINALITIES {
			for shape in sh.Shape {
				row := p95[cand * config_count + ci]
				med := median(row)
				bp, _ := bench.spread(row)
				fmt.printf("%s %d %v %d %d\n", names[cand], count, shape, med, bp)
				ci += 1
			}
		}
	}
}

// The clock, wrapped so the measured region is one call in one place.
@(private = "file")
tick :: proc() -> time.Tick {
	return time.tick_now()
}

@(private = "file")
elapsed :: proc(start: time.Tick) -> i64 {
	return time.duration_nanoseconds(time.tick_since(start))
}

// run_one dispatches to a candidate by index.
//
// An explicit switch rather than an array of procedure pointers: the indirect
// call a table would add is a cost the real router would never pay, and it
// would be paid identically by every candidate — which sounds fair and simply
// adds noise to every row.
@(private = "file")
run_one :: proc(
	cand: int,
	lin: ^sh.Linear,
	imp: ^sh.Linear_Improved,
	buc: ^sh.Bucketed,
	hyb: ^sh.Hybrid,
	rp: ^sh.Radix_Ptr,
	ri: ^sh.Radix_Idx,
	ra: ^sh.Radix_Arr,
	path: string,
) -> sh.Match {
	switch cand {
	case 0:
		return sh.linear_match(lin, path)
	case 1:
		return sh.linear_improved_match(imp, path)
	case 2:
		return sh.bucketed_match(buc, path)
	case 3:
		return sh.hybrid_match(hyb, path)
	case 4:
		return sh.radix_ptr_match(rp, path)
	case 5:
		return sh.radix_idx_match(ri, path)
	case 6:
		return sh.radix_arr_match(ra, path)
	}
	return sh.MISS
}

@(private = "file")
median :: proc(values: []i64) -> i64 {
	// A local insertion sort: `slice.sort` would reorder the caller's row, and
	// these rows are read again by the loop above.
	buf: [REPETITIONS]i64
	n := len(values)
	copy(buf[:], values)
	for i in 1 ..< n {
		v := buf[i]
		j := i - 1
		for j >= 0 && buf[j] > v {
			buf[j + 1] = buf[j]
			j -= 1
		}
		buf[j + 1] = v
	}
	return buf[n / 2]
}
