// WP17 internal behavior tests — `use`, `next`, the flattened chains, the miss
// chain, and the ADR-019 fail-closed guard.
//
// This file declares `package web` but does NOT live in `web/`, and it must
// never be moved there: the chain pool, the cursor, the miss machinery and the
// poison state are all package-private, and on the pinned toolchain an
// `@(test)` procedure must be compiled as part of the package it tests.
// `build/check.sh` assembles a THROWAWAY package from the real `web/` sources
// plus this file, exactly as it does for WP2-WP9.
//
// WHY THESE TESTS ARE INTERNAL. Five WP17 contracts cannot be observed from
// outside the package:
//
//   - the exact 405 `Allow` header around the miss chain (`Recorded_Response`
//     has no public headers field);
//   - the byte-identity of a first response after a rejected post-`next`
//     attempt, read from the internal `Response` before teardown;
//   - the zero-allocation dispatch claim, measured around the private
//     `driver_run`/`driver_cleanup` pipeline with `mem.Tracking_Allocator`
//     (deliberately NOT around `test_request`: the recorder copies every
//     response by design, so counting those would measure the test transport,
//     not the chain — WP12 P9);
//   - the poisoned-App predicate (`use()` returns void, so the fail-closed
//     state must be readable somewhere a test can see it — ADR-019 (b));
//   - the index-pair chain surviving pool growth under a poisoning allocator
//     (WP12 P8: the slice-storage defect reads back CORRECTLY on the plain
//     heap, so only a poisoning allocator makes the reproduction deterministic).
//
// ORDER RECORDING. Middleware are plain top-level procedures (the frozen
// `Handler` shape — no closures), so the observed order is written through
// `context.user_ptr` into a sink OWNED BY EACH TEST. The context flows
// unchanged from the test frame through `test_request`/`driver_run` into every
// chain step, and each test's sink is its own local, so the parallel test
// runner cannot interleave two tests' marks (the WP12 probes shared one global
// buffer and needed a single-threaded runner; this arrangement does not).
#+private
package web

import "base:runtime"
import "core:mem"
import "core:testing"
import transport "druse:web/internal/transport"

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

@(private = "file")
Wp17_Sink :: struct {
	order:           [128]u8,
	n:               int,
	handler_runs:    int,
	bounded_entries: int,
	log_buf:         [1024]u8,
	log_n:           int,
	inner:           runtime.Logger,
}

@(private = "file")
wp17_mark :: proc(s: string) {
	sink := (^Wp17_Sink)(context.user_ptr)
	if sink == nil {
		return
	}
	for i in 0 ..< len(s) {
		if sink.n < len(sink.order) {
			sink.order[sink.n] = s[i]
			sink.n += 1
		}
	}
}

@(private = "file")
wp17_order :: proc(sink: ^Wp17_Sink) -> string {
	return string(sink.order[:sink.n])
}

// wp17_run drives one request through the SAME private pipeline `serve` and
// `test_request` share: driver_run (inbound -> Context -> dispatch -> finalize).
// The caller owns the Context so the committed response — including its
// request-local `Allow` storage — can be inspected before `driver_cleanup`.
@(private = "file")
wp17_run :: proc(a: ^App, ctx: ^Context, method: Method, path: string) {
	driver_run(
		a,
		ctx,
		transport.Inbound{method = method_token(method), path = path},
	)
}

// A logger that captures the framework's own `druse:` Error diagnostics into
// the test's sink — so the ADR-019 diagnostic text (property (c): it names the
// offending pattern) is an assertion rather than a claim, and so an EXPECTED
// diagnostic is not recorded by the runner as a test failure. Every other
// message is FORWARDED to the runner's logger: `testing.expect` reports
// failures through `context.logger`, so a logger that swallowed everything
// would make its test unable to fail — a mutation control caught exactly that
// defect in an earlier draft of this file (the WP8 idiom, relearned).
@(private = "file")
wp17_capture_logger_proc :: proc(
	data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options,
	location := #caller_location,
) {
	sink := (^Wp17_Sink)(data)
	if level == .Error && wp17_contains(text, "druse:") {
		for i in 0 ..< len(text) {
			if sink.log_n < len(sink.log_buf) {
				sink.log_buf[sink.log_n] = text[i]
				sink.log_n += 1
			}
		}
		return
	}
	if sink.inner.procedure != nil {
		sink.inner.procedure(sink.inner.data, level, text, options, location)
	}
}

@(private = "file")
wp17_logged :: proc(sink: ^Wp17_Sink) -> string {
	return string(sink.log_buf[:sink.log_n])
}

// wp17_capture_logger installs the capture logger for tests that DELIBERATELY
// trigger a framework diagnostic (the poison family, the driver 500): the
// pinned test runner records Error-level log lines as test failures, so an
// expected diagnostic must be captured, not printed (the WP6/WP8 idiom).
@(private = "file")
wp17_capture_logger :: proc(sink: ^Wp17_Sink) -> runtime.Logger {
	sink.inner = context.logger
	return runtime.Logger {
		procedure    = wp17_capture_logger_proc,
		data         = sink,
		lowest_level = .Debug,
		options      = context.logger.options,
	}
}

@(private = "file")
wp17_contains :: proc(haystack: string, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(haystack) < len(needle) {
		return false
	}
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i + len(needle)] == needle {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Middleware and handlers — all the frozen Handler shape, all top-level.
// ---------------------------------------------------------------------------

@(private = "file")
wp17_mw_a :: proc(ctx: ^Context) {
	wp17_mark("A>")
	next(ctx)
	wp17_mark("<A")
}

@(private = "file")
wp17_mw_b :: proc(ctx: ^Context) {
	wp17_mark("B>")
	next(ctx)
	wp17_mark("<B")
}

@(private = "file")
wp17_mw_c :: proc(ctx: ^Context) {
	wp17_mark("C>")
	next(ctx)
	wp17_mark("<C")
}

// Short-circuit: responds and returns WITHOUT calling next.
@(private = "file")
wp17_mw_stop :: proc(ctx: ^Context) {
	wp17_mark("STOP")
	text(ctx, .Forbidden, "denied")
}

// Post-next attempt through the OWNED commit path (web.text renders and
// allocates; the guard must free the rejected body).
@(private = "file")
wp17_mw_late_owned :: proc(ctx: ^Context) {
	wp17_mark("P>")
	next(ctx)
	text(ctx, .Internal_Server_Error, "late")
	wp17_mark("<P")
}

// Post-next attempt through the STATIC commit path (web.no_content commits via
// response_commit, not response_commit_owned).
@(private = "file")
wp17_mw_late_static :: proc(ctx: ^Context) {
	wp17_mark("N>")
	next(ctx)
	no_content(ctx)
	wp17_mark("<N")
}

// Calls next twice. The second call must be a silent no-op (ADR-022 item 3).
@(private = "file")
wp17_mw_twice :: proc(ctx: ^Context) {
	wp17_mark("T>")
	next(ctx)
	next(ctx)
	wp17_mark("<T")
}

// Neither calls next nor responds (WP12 P7).
@(private = "file")
wp17_mw_neither :: proc(ctx: ^Context) {
	wp17_mark("S")
}

// Bounds its own recursion: if the cursor ever stops advancing, this
// middleware is re-entered instead of its downstream, and it refuses to recurse
// past the bound — so the failure is a wrong entry count and a missing
// handler, not a stack overflow that kills the runner. The WP17 mutation
// control that deletes the cursor advance relies on exactly this test shape.
@(private = "file")
wp17_mw_bounded :: proc(ctx: ^Context) {
	sink := (^Wp17_Sink)(context.user_ptr)
	if sink == nil {
		return
	}
	sink.bounded_entries += 1
	if sink.bounded_entries > 4 {
		return
	}
	next(ctx)
}

// Deliberately allocates at dispatch: the negative control that proves the
// tracking instrument can catch a per-request allocation (WP12 P9).
@(private = "file")
wp17_mw_allocating :: proc(ctx: ^Context) {
	scratch := make([]u8, 48)
	scratch[0] = 1
	delete_slice(scratch)
	next(ctx)
}

@(private = "file")
wp17_h_text :: proc(ctx: ^Context) {
	wp17_mark("H")
	sink := (^Wp17_Sink)(context.user_ptr)
	if sink != nil {
		sink.handler_runs += 1
	}
	text(ctx, .OK, "handler")
}

@(private = "file")
wp17_h_no_content :: proc(ctx: ^Context) {
	sink := (^Wp17_Sink)(context.user_ptr)
	if sink != nil {
		sink.handler_runs += 1
	}
	no_content(ctx)
}

// A handler that calls next itself: the chain is exhausted, so it must be a
// no-op (ADR-022 item 4 — WP12 predicted this and did not test it; this does).
@(private = "file")
wp17_h_calls_next :: proc(ctx: ^Context) {
	wp17_mark("H")
	sink := (^Wp17_Sink)(context.user_ptr)
	if sink != nil {
		sink.handler_runs += 1
	}
	next(ctx)
	text(ctx, .OK, "handler")
}

@(private = "file")
wp17_h_secret :: proc(ctx: ^Context) {
	text(ctx, .OK, "TOP-SECRET-USERS")
}

@(private = "file")
wp17_mw_auth_noop :: proc(ctx: ^Context) {
	next(ctx)
}

// ---------------------------------------------------------------------------
// 1. Execution order and unwind (ADR-005, ADR-022 items 1-2; WP12 P2/P4)
// ---------------------------------------------------------------------------

@(test)
wp17_order_across_three_globals_and_exact_reverse_unwind :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_a)
	use(&a, wp17_mw_b)
	use(&a, wp17_mw_c)
	get(&a, "/x", wp17_h_text)

	res := test_request(&a, .GET, "/x")

	testing.expect_value(t, wp17_order(&sink), "A>B>C>H<C<B<A")
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, res.body, "handler")
}

@(test)
wp17_short_circuit_is_total :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_a)
	use(&a, wp17_mw_stop)
	use(&a, wp17_mw_c)
	get(&a, "/x", wp17_h_text)

	res := test_request(&a, .GET, "/x")

	// No `C>` — later middleware never ran; no `H` — the handler never ran;
	// middleware A still resumed, which is what lets a logger log a rejection.
	testing.expect_value(t, wp17_order(&sink), "A>STOP<A")
	testing.expect_value(t, sink.handler_runs, 0)
	testing.expect_value(t, res.status, Status.Forbidden)
	testing.expect_value(t, res.body, "denied")
}

// ---------------------------------------------------------------------------
// 2. The post-`next` promise (ADR-022 = B1; WP12 P5/P5b)
// ---------------------------------------------------------------------------

@(test)
wp17_post_next_owned_attempt_is_rejected_first_response_byte_identical :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_late_owned)
	get(&a, "/x", wp17_h_text)

	ctx: Context
	wp17_run(&a, &ctx, .GET, "/x")

	// The unwind code ran (<P is present), the late attempt went through the
	// shipped `text` responder and the shipped owned-commit guard, and the FIRST
	// response survives byte-identically.
	testing.expect_value(t, wp17_order(&sink), "P>H<P")
	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), "handler")

	driver_cleanup(&ctx)
}

@(test)
wp17_post_next_static_attempt_is_rejected_first_response_byte_identical :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_late_static)
	get(&a, "/x", wp17_h_text)

	ctx: Context
	wp17_run(&a, &ctx, .GET, "/x")

	testing.expect_value(t, wp17_order(&sink), "N>H<N")
	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), "handler")

	driver_cleanup(&ctx)
}

@(test)
wp17_second_next_is_a_silent_noop_and_the_handler_runs_once :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_twice)
	use(&a, wp17_mw_b)
	get(&a, "/x", wp17_h_text)

	res := test_request(&a, .GET, "/x")

	// WP12 P6, with the integrator's correction encoded: this holds only while
	// the terminal handler sits INSIDE the cursor's index bound. The mutation
	// control that moves it outside the bound must observe handler_runs == 2.
	testing.expect_value(t, wp17_order(&sink), "T>B>H<B<T")
	testing.expect_value(t, sink.handler_runs, 1)
	testing.expect_value(t, res.status, Status.OK)
}

@(test)
wp17_the_cursor_advances_exactly_once_per_step :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_bounded)
	get(&a, "/x", wp17_h_text)

	res := test_request(&a, .GET, "/x")

	// A cursor that stopped advancing would re-enter the bounded middleware
	// until its guard trips (entries == 5, handler never runs, driver 500).
	testing.expect_value(t, sink.bounded_entries, 1)
	testing.expect_value(t, sink.handler_runs, 1)
	testing.expect_value(t, res.status, Status.OK)
}

@(test)
wp17_next_from_the_handler_is_a_noop :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_a)
	get(&a, "/x", wp17_h_calls_next)

	res := test_request(&a, .GET, "/x")

	testing.expect_value(t, wp17_order(&sink), "A>H<A")
	testing.expect_value(t, sink.handler_runs, 1)
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, res.body, "handler")
}

@(test)
wp17_neither_next_nor_respond_is_finalized_to_the_driver_500 :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink
	context.logger = wp17_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_neither)
	get(&a, "/x", wp17_h_text)

	res := test_request(&a, .GET, "/x")

	// The chain stopped without a response; downstream (and the handler) never
	// ran; the existing WP8 D5 driver finalization sends the standard 500.
	testing.expect_value(t, wp17_order(&sink), "S")
	testing.expect_value(t, sink.handler_runs, 0)
	testing.expect_value(t, res.status, Status.Internal_Server_Error)
	testing.expect_value(t, res.body, ERROR_BODY_INTERNAL)
}

// ---------------------------------------------------------------------------
// 3. The miss chain (ADR-023; WP12 P13)
// ---------------------------------------------------------------------------

@(test)
wp17_global_middleware_observe_a_404_with_the_envelope_intact :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_a)
	use(&a, wp17_mw_b)
	get(&a, "/known", wp17_h_text)

	res := test_request(&a, .GET, "/nope")

	// The empty gap between `B>` and `<B` is the terminal step producing the
	// automatic response. The envelope is the unchanged WP6 constant.
	testing.expect_value(t, wp17_order(&sink), "A>B><B<A")
	testing.expect_value(t, res.status, Status.Not_Found)
	testing.expect_value(t, res.body, ERROR_BODY_NOT_FOUND_ROUTE)
}

@(test)
wp17_global_middleware_observe_a_405_with_allow_intact :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_a)
	post(&a, "/only", wp17_h_no_content)

	ctx: Context
	wp17_run(&a, &ctx, .GET, "/only")

	testing.expect_value(t, wp17_order(&sink), "A><A")
	testing.expect_value(t, ctx.private.response.status, Status.Method_Not_Allowed)
	testing.expect_value(t, string(ctx.private.response.body), ERROR_BODY_METHOD_NOT_ALLOWED)

	// The exact WP4 contract, unchanged by the chain: Allow first, then
	// Content-Type, deterministic order.
	testing.expect_value(t, len(ctx.private.response.headers), 2)
	testing.expect_value(t, ctx.private.response.headers[0].name, "Allow")
	testing.expect_value(t, ctx.private.response.headers[0].value, "POST, OPTIONS")
	testing.expect_value(t, ctx.private.response.headers[1].name, "Content-Type")
	testing.expect_value(t, ctx.private.response.headers[1].value, "application/json")

	driver_cleanup(&ctx)
}

@(test)
wp17_bare_miss_enters_and_unwinds_the_chain_committing_nothing :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink
	context.logger = wp17_capture_logger(&sink)

	a := bare()
	defer destroy(&a)
	use(&a, wp17_mw_a)

	res := test_request(&a, .GET, "/nope")

	// The MECHANISM (middleware observe the miss) is on; the POLICY (what a miss
	// answers) stays absent: the terminal is a no-op, nothing commits, and the
	// driver's existing 500 finalization applies unchanged (ADR-023 item 2).
	testing.expect_value(t, wp17_order(&sink), "A><A")
	testing.expect_value(t, res.status, Status.Internal_Server_Error)
	testing.expect_value(t, res.body, ERROR_BODY_INTERNAL)
}

// ---------------------------------------------------------------------------
// 4. Fail-closed registration order (ADR-019 + ADR-023 sub-decision)
// ---------------------------------------------------------------------------

@(test)
wp17_use_after_a_registered_route_poisons_the_app_fail_closed :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink
	context.logger = wp17_capture_logger(&sink)

	a := app()
	defer destroy(&a)

	// The WP12 D-12.5 program: the route reads as protected and IS NOT. WP12
	// measured it serving the secret with 200 OK. Fail-closed means the
	// mis-ordered program serves NOTHING.
	get(&a, "/admin/users", wp17_h_secret)
	use(&a, wp17_mw_auth_noop)

	// (b) the state is observable to a test: a private predicate, not an abort.
	testing.expect(t, a.private.poisoned, "use() after a registration must poison the App")

	res := test_request(&a, .GET, "/admin/users")
	testing.expect_value(t, res.status, Status.Internal_Server_Error)
	testing.expect_value(t, res.body, ERROR_BODY_INTERNAL)
	testing.expect(
		t,
		!wp17_contains(res.body, "TOP-SECRET"),
		"the poisoned App must never serve the protected route's body",
	)
}

@(test)
wp17_use_after_the_first_dispatch_is_rejected_fail_closed :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.logger = wp17_capture_logger(&sink)
	a := app()
	defer destroy(&a)

	// Zero routes, one served miss: the ADR-023 edge. Without this rejection the
	// miss chain built at the first miss would need invalidation machinery.
	_ = test_request(&a, .GET, "/nope")
	use(&a, wp17_mw_a)

	testing.expect(t, a.private.poisoned, "use() after the first dispatch must poison the App")

	res := test_request(&a, .GET, "/nope")
	testing.expect_value(t, res.status, Status.Internal_Server_Error)
}

@(test)
wp17_bare_enforces_the_fail_closed_guard_identically :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.logger = wp17_capture_logger(&sink)
	a := bare()
	defer destroy(&a)

	get(&a, "/admin/users", wp17_h_secret)
	use(&a, wp17_mw_auth_noop)

	testing.expect(t, a.private.poisoned, "bare() must enforce ADR-019 exactly like app()")

	res := test_request(&a, .GET, "/admin/users")
	testing.expect_value(t, res.status, Status.Internal_Server_Error)
	testing.expect(t, !wp17_contains(res.body, "TOP-SECRET"))
}

@(test)
wp17_correctly_ordered_program_is_unaffected :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_a)
	get(&a, "/x", wp17_h_text)

	testing.expect(t, !a.private.poisoned)

	res := test_request(&a, .GET, "/x")
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, wp17_order(&sink), "A>H<A")
}

@(test)
wp17_poison_diagnostic_names_the_offending_pattern :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink
	context.logger = wp17_capture_logger(&sink)

	a := app()
	defer destroy(&a)
	get(&a, "/admin/users", wp17_h_secret)
	use(&a, wp17_mw_auth_noop)

	logged := wp17_logged(&sink)
	// Property (c): the diagnostic names the offending pattern and says what to
	// do. The wording below is the owner-approved ADR-019 text (spec §5).
	testing.expect(
		t,
		wp17_contains(logged, "web.use was called after a route was already registered"),
		"the approved ADR-019 diagnostic must be emitted on the offending use() call",
	)
	testing.expect(
		t,
		wp17_contains(logged, "/admin/users"),
		"the diagnostic must name the already-registered pattern it cannot protect",
	)
	testing.expect(
		t,
		wp17_contains(logged, "rejected fail-closed"),
		"the diagnostic must state the fail-closed consequence",
	)
}

// ---------------------------------------------------------------------------
// 5. Ownership and allocation (ADR-005 acceptance criteria; WP12 P8/P9)
// ---------------------------------------------------------------------------

@(test)
wp17_destroy_frees_the_chain_pool_exactly_once :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	a := app()
	use(&a, wp17_mw_a)
	use(&a, wp17_mw_b)
	get(&a, "/x", wp17_h_no_content)

	// One routed request and one miss, so the lazily-built miss chain exists
	// too and its storage is covered by the teardown assertion.
	ctx1: Context
	wp17_run(&a, &ctx1, .GET, "/x")
	driver_cleanup(&ctx1)
	ctx2: Context
	wp17_run(&a, &ctx2, .GET, "/nope")
	driver_cleanup(&ctx2)

	testing.expect(
		t,
		len(track.allocation_map) > 0,
		"registration must have allocated the App-owned pool",
	)

	destroy(&a)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)

	// A second destroy frees nothing and reports no bad free.
	destroy(&a)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
wp17_dispatch_allocates_zero_through_a_five_middleware_chain :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_a)
	use(&a, wp17_mw_b)
	use(&a, wp17_mw_c)
	use(&a, wp17_mw_a)
	use(&a, wp17_mw_b)
	get(&a, "/z", wp17_h_no_content)

	// Warm-up outside the measurement, so one-time lazy initialisation is not
	// counted (WP12 P9's protocol).
	warm: Context
	wp17_run(&a, &warm, .GET, "/z")
	driver_cleanup(&warm)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	temp_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&temp_track, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&temp_track)

	context.allocator = mem.tracking_allocator(&track)
	context.temp_allocator = mem.tracking_allocator(&temp_track)

	ctx: Context
	wp17_run(&a, &ctx, .GET, "/z")
	driver_cleanup(&ctx)

	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect_value(t, track.total_memory_allocated, 0)
	testing.expect_value(t, temp_track.total_allocation_count, 0)
}

@(test)
wp17_a_second_miss_allocates_zero :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_a)
	get(&a, "/z", wp17_h_no_content)

	// The first miss builds the miss chain (lazy, once). Every later miss is
	// allocation-free: the chain is never invalidated, because use() after the
	// first dispatch is rejected (ADR-023 item 3).
	warm: Context
	wp17_run(&a, &warm, .GET, "/nope")
	driver_cleanup(&warm)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	ctx: Context
	wp17_run(&a, &ctx, .GET, "/nope")
	driver_cleanup(&ctx)

	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect_value(t, track.total_memory_allocated, 0)
}

@(test)
wp17_the_allocation_instrument_catches_an_allocating_chain :: proc(t: ^testing.T) {
	// NEGATIVE CONTROL (WP12 P9): a deliberately allocating middleware must be
	// visible to exactly the instrument the two tests above rely on. A tracking
	// assertion that never fires against a real allocation proves nothing.
	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_allocating)
	get(&a, "/z", wp17_h_no_content)

	warm: Context
	wp17_run(&a, &warm, .GET, "/z")
	driver_cleanup(&warm)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	ctx: Context
	wp17_run(&a, &ctx, .GET, "/z")
	driver_cleanup(&ctx)

	testing.expect(
		t,
		track.total_allocation_count > 0,
		"the tracking instrument must observe the deliberately allocating chain",
	)
}

// ---------------------------------------------------------------------------
// 6. Index pairs survive pool growth (WP12 P8; spec §2.2)
// ---------------------------------------------------------------------------

// A poisoning allocator: every block it releases is filled with 0xAA first.
// WP12 P8b showed the slice-storage defect reading back CORRECTLY on the plain
// heap when the pool happened to grow in place; forcing every resize to move
// and poisoning the old block makes the reproduction deterministic. Slice
// storage under this allocator calls through 0xAAAAAAAAAAAAAAAA; index pairs
// re-slice the live pool and are immune by construction.
@(private = "file")
Wp17_Poison_Data :: struct {
	backing: mem.Allocator,
}

@(private = "file")
wp17_poison_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	data := (^Wp17_Poison_Data)(allocator_data)
	backing := data.backing

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return backing.procedure(backing.data, mode, size, alignment, nil, 0, location)
	case .Free:
		if old_memory != nil && old_size > 0 {
			mem.set(old_memory, 0xAA, old_size)
		}
		return backing.procedure(backing.data, .Free, size, alignment, old_memory, old_size, location)
	case .Resize, .Resize_Non_Zeroed:
		// Never resize in place: allocate a NEW block, copy, poison and free the
		// old one, so a stale view over the old block is deterministically junk.
		new_block, err := backing.procedure(backing.data, .Alloc, size, alignment, nil, 0, location)
		if err != .None {
			return nil, err
		}
		if old_memory != nil && old_size > 0 {
			mem.copy(raw_data(new_block), old_memory, min(old_size, size))
			mem.set(old_memory, 0xAA, old_size)
			_, _ = backing.procedure(backing.data, .Free, 0, 0, old_memory, old_size, location)
		}
		return new_block, .None
	case .Free_All, .Query_Features, .Query_Info:
		return backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, location)
	}
	return nil, .Mode_Not_Implemented
}

@(test)
wp17_chains_survive_pool_growth_under_a_poisoning_allocator :: proc(t: ^testing.T) {
	sink: Wp17_Sink
	context.user_ptr = &sink

	poison := Wp17_Poison_Data{backing = context.allocator}
	context.allocator = mem.Allocator {
		procedure = wp17_poison_allocator_proc,
		data      = &poison,
	}

	a := app()
	defer destroy(&a)
	use(&a, wp17_mw_a)
	get(&a, "/first", wp17_h_text)

	// 64 further registrations force the App-owned pool to reallocate — and
	// under this allocator, to MOVE, with the old storage poisoned. A route
	// whose chain were captured as a []Handler at registration would now call
	// through 0xAA bytes (WP12 P8c reproduced exactly this at 65 routes).
	filler_patterns := [64]string {
		"/f00", "/f01", "/f02", "/f03", "/f04", "/f05", "/f06", "/f07",
		"/f08", "/f09", "/f10", "/f11", "/f12", "/f13", "/f14", "/f15",
		"/f16", "/f17", "/f18", "/f19", "/f20", "/f21", "/f22", "/f23",
		"/f24", "/f25", "/f26", "/f27", "/f28", "/f29", "/f30", "/f31",
		"/f32", "/f33", "/f34", "/f35", "/f36", "/f37", "/f38", "/f39",
		"/f40", "/f41", "/f42", "/f43", "/f44", "/f45", "/f46", "/f47",
		"/f48", "/f49", "/f50", "/f51", "/f52", "/f53", "/f54", "/f55",
		"/f56", "/f57", "/f58", "/f59", "/f60", "/f61", "/f62", "/f63",
	}
	for pattern in filler_patterns {
		get(&a, pattern, wp17_h_no_content)
	}

	ctx: Context
	wp17_run(&a, &ctx, .GET, "/first")

	// The first route's chain still resolves to the right steps after growth.
	testing.expect_value(t, wp17_order(&sink), "A>H<A")
	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), "handler")

	driver_cleanup(&ctx)
}
