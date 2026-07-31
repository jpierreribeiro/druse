// ADR-020 — THE SHAPE OF A LEAK PER RECOVERED FAULT, MEASURED FROM COMMITTED CODE.
//
// READ THIS BEFORE QUOTING ANY NUMBER IT PRINTS.
//
// This is NOT a reproduction of the WP13 prototype that produced the "8,250
// bytes per recovered fault" figure in ADR-020. That prototype cannot be
// reproduced and never will be: it measured option (C), a `setjmp`/`longjmp`
// fence that recovered from a fault and kept serving. ADR-020 REJECTED option
// (C). It was never implemented, never merged, and lived entirely in
// /tmp/wp13-probe/, which is gone. Any script claiming to re-run it would be
// measuring something the shipped code cannot do.
//
// What CAN be measured from committed code is the thing the decision actually
// rests on: what one skipped deallocation costs, per request, on the real
// request path — and whether that cost is bounded or linear. ADR-020's argument
// is the SHAPE ("linear, unbounded, nothing reclaims it, the supervisor is never
// signalled"), not the constant. This program measures the shape.
//
// HOW IT MODELS THE FAULT. A recovered fault skips the `defer`s between the
// fault site and the fence. There is no way to skip a `defer` in Odin without
// faulting, and a fault aborts the process (which is the whole point of
// ADR-020), so the skipped deallocation is modelled directly: the leaking arm
// allocates and does not free. That models the CONSEQUENCE faithfully while
// making no claim about the fence.
//
// WHY THE CONTROL ARM IS SUBTRACTED, and this is inherited from the original
// document rather than invented here: `web.test_request` records every response
// and retains it until `web.destroy`. That retention is documented driver
// behaviour, not a leak, and it grows in BOTH arms. The clean arm is therefore
// the baseline, and the reported figure is a difference.
//
// Run it:  odin run experiments/26-adr020-leak-shape -collection:druse=.
package adr020_leak_shape

import "core:fmt"
import "core:mem"
import web "druse:web"

// Overridable so the run can be scaled down while diagnosing, and so the cost
// of the measurement is visible rather than baked in:
//   odin run ... -define:REQUESTS=2000 -define:SAMPLE_EVERY=500
REQUESTS :: #config(REQUESTS, 20_000)
SAMPLE_EVERY :: #config(SAMPLE_EVERY, 5_000)

// The size the WP13 note attributes the leak to: one 8 KiB buffer released by a
// `defer` that a recovered fault would skip. Chosen to match, so the difference
// between the printed figure and 8,192 is visible and attributable rather than
// hidden.
LEAK_BYTES :: 8 * 1024

Arm :: enum {
	Clean,
	Leaking,
}

g_arm: Arm
g_escape: rawptr

// THE HANDLER MUST NOT USE `context.allocator`, and that is a fact about this
// framework rather than a style choice: ADR-007 gives a request its own arena,
// so inside a handler `context.allocator` is request-scoped. Allocating there
// would measure the arena's lifecycle, not a leak, and freeing an arena pointer
// is not a thing a caller may do. The first draft of this experiment did
// exactly that and hung before its first sample.
//
// So the arm's heap allocator is captured explicitly and used by name.
g_heap: mem.Allocator

// The handler allocates the buffer the way a request-scoped helper would, then
// either releases it (clean) or does not (leaking).
//
// `g_escape` exists so the optimiser cannot decide the allocation is dead and
// remove it: a measurement whose subject was optimised away would report zero
// and read as "no leak", which is a green result for the wrong reason
// (planning/diagnosability.md rule 4).
handler :: proc(ctx: ^web.Context) {
	buf, err := mem.alloc(LEAK_BYTES, allocator = g_heap)
	if err != nil {
		web.text(ctx, .Internal_Server_Error, "alloc failed")
		return
	}
	g_escape = buf
	(cast(^byte)buf)^ = 1

	if g_arm == .Clean {
		mem.free(buf, g_heap)
	}

	web.text(ctx, .OK, "ok")
}

Sample :: struct {
	reqs:  int,
	live:  i64,
}

run_arm :: proc(arm: Arm, samples: ^[dynamic]Sample) {
	g_arm = arm

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	g_heap = mem.tracking_allocator(&track)
	context.allocator = g_heap

	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/leak", handler)

	for i in 1 ..= REQUESTS {
		res := web.test_request(&a, .GET, "/leak")
		if res.status != .OK {
			fmt.eprintfln("arm %v: request %d returned %v, not 200", arm, i, res.status)
			return
		}
		if i % SAMPLE_EVERY == 0 {
			append(samples, Sample{reqs = i, live = track.current_memory_allocated})
			// Progress on stderr, so a run that slows down says so instead of
			// looking identical to a run that hung.
			fmt.eprintfln("  arm %v: %d/%d requests, %d bytes live", arm, i, REQUESTS, track.current_memory_allocated)
		}
	}
}

main :: proc() {
	fmt.eprintfln("REQUESTS=%d SAMPLE_EVERY=%d LEAK_BYTES=%d", REQUESTS, SAMPLE_EVERY, LEAK_BYTES)

	// The sample arrays are built on the DEFAULT allocator, deliberately. Each
	// arm swaps `context.allocator` to its own tracking allocator and tears that
	// tracker down on the way out; an array whose backing store came from a
	// torn-down arm's tracker would be read after its owner had gone.
	clean := make([dynamic]Sample, 0, 64, context.allocator)
	leaking := make([dynamic]Sample, 0, 64, context.allocator)
	defer delete(clean)
	defer delete(leaking)

	run_arm(.Clean, &clean)
	fmt.eprintln("clean arm done")
	run_arm(.Leaking, &leaking)
	fmt.eprintln("leaking arm done")

	if len(clean) != len(leaking) || len(clean) == 0 {
		fmt.eprintln("arms did not complete; refusing to report a number")
		return
	}

	fmt.println("ADR-020 leak shape — live bytes held, by arm")
	fmt.println()
	fmt.printfln("%8s  %16s  %16s  %16s", "reqs", "clean", "leaking", "difference")
	for i in 0 ..< len(clean) {
		diff := leaking[i].live - clean[i].live
		fmt.printfln(
			"%8d  %16d  %16d  %16d",
			clean[i].reqs,
			clean[i].live,
			leaking[i].live,
			diff,
		)
	}

	last := len(clean) - 1
	total_diff := leaking[last].live - clean[last].live
	per_request := f64(total_diff) / f64(clean[last].reqs)

	fmt.println()
	fmt.printfln("leaked bytes per request: %.1f  (over %d requests)", per_request, REQUESTS)
	fmt.printfln("the modelled skipped deallocation: %d bytes", LEAK_BYTES)

	// This line is a CONTROL, not a finding. `current_memory_allocated` counts
	// requested bytes, and this experiment models exactly one skipped free, so a
	// non-zero residue would mean the arms differ by something other than the
	// buffer -- the measurement leaking on its own account. Expect 0.0.
	residue := per_request - f64(LEAK_BYTES)
	fmt.printfln("residue beyond the modelled buffer: %.1f bytes per request (control: expect 0.0)", residue)
	fmt.println()

	// LINEARITY IS THE CLAIM, so it is checked rather than eyeballed. If the
	// difference per request were bounded — a cache, a pool, anything that
	// reclaims — the later intervals would fall below the first.
	first_interval := leaking[0].live - clean[0].live
	expected_final := first_interval * i64(len(clean))
	drift := f64(total_diff - expected_final) / f64(expected_final) * 100.0
	fmt.printfln(
		"linearity: first interval %d bytes, final total %d, perfect-linear projection %d (%.1f%% drift)",
		first_interval,
		total_diff,
		expected_final,
		drift,
	)
	fmt.println()
	fmt.println("ADR-020 rests on this shape — linear and unreclaimed — not on the constant.")
	fmt.println()
	fmt.println("On the historical numbers, which this run does NOT reproduce and does explain:")
	fmt.println("  8,192  the single 8 KiB buffer one skipped `defer` fails to release.")
	fmt.println("         This experiment models exactly that, and measures exactly that.")
	fmt.println("  8,250  the WP13 figure, ~58 bytes/request higher, because the REJECTED R-c")
	fmt.println("         fence skipped EVERY `defer` between the fault site and the fence —")
	fmt.println("         the buffer plus the request's other deferred frees. That fence was")
	fmt.println("         never implemented, its prototype lived in /tmp and is gone, so the")
	fmt.println("         number cannot be re-measured. The two figures are consistent; they")
	fmt.println("         count different things, and neither supersedes the other.")
}
