// WP18 internal behavior tests — `Router`, `router`, `mount`: prefix
// grammar, chain composition, the close-on-mount rule, and poison propagation.
//
// This file declares `package web` but does NOT live in `web/`: the mounted
// entries' chains, the poison predicate and the closed flag are all
// package-private, and `build/check.sh` assembles the usual THROWAWAY package
// from the real `web/` sources plus this file (the WP2-WP17 arrangement).
//
// ORDER RECORDING follows the WP17 harness exactly: top-level Handler
// procedures write marks through `context.user_ptr` into a sink owned by each
// test, and tests that DELIBERATELY trigger a framework diagnostic install the
// capture logger — which captures `druse:` Error lines and FORWARDS
// everything else, because `testing.expect` reports through `context.logger`
// and a swallow-everything logger makes a test unable to fail (the defect
// WP17's mutation control 6 caught).
#+private
package web

import "base:runtime"
import "core:mem"
import "core:testing"
import transport "druse:web/internal/transport"

// ---------------------------------------------------------------------------
// Harness (the WP17 shape)
// ---------------------------------------------------------------------------

@(private = "file")
Wp18_Sink :: struct {
	order:        [128]u8,
	n:            int,
	handler_runs: int,
	log_buf:      [1024]u8,
	log_n:        int,
	inner:        runtime.Logger,
}

@(private = "file")
wp18_mark :: proc(s: string) {
	sink := (^Wp18_Sink)(context.user_ptr)
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
wp18_order :: proc(sink: ^Wp18_Sink) -> string {
	return string(sink.order[:sink.n])
}

@(private = "file")
wp18_run :: proc(a: ^App, ctx: ^Context, method: Method, path: string) {
	driver_run(
		a,
		ctx,
		transport.Inbound{method = method_token(method), path = path},
	)
}

@(private = "file")
wp18_contains :: proc(haystack: string, needle: string) -> bool {
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

@(private = "file")
wp18_capture_logger_proc :: proc(
	data: rawptr,
	level: runtime.Logger_Level,
	text: string,
	options: runtime.Logger_Options,
	location := #caller_location,
) {
	sink := (^Wp18_Sink)(data)
	if level == .Error && wp18_contains(text, "druse:") {
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
wp18_capture_logger :: proc(sink: ^Wp18_Sink) -> runtime.Logger {
	sink.inner = context.logger
	return runtime.Logger {
		procedure    = wp18_capture_logger_proc,
		data         = sink,
		lowest_level = .Debug,
		options      = context.logger.options,
	}
}

@(private = "file")
wp18_logged :: proc(sink: ^Wp18_Sink) -> string {
	return string(sink.log_buf[:sink.log_n])
}

// ---------------------------------------------------------------------------
// Middleware and handlers — all the frozen Handler shape, all top-level.
// ---------------------------------------------------------------------------

@(private = "file")
wp18_mw_app :: proc(ctx: ^Context) {
	wp18_mark("A>")
	next(ctx)
	wp18_mark("<A")
}

@(private = "file")
wp18_mw_outer :: proc(ctx: ^Context) {
	wp18_mark("O>")
	next(ctx)
	wp18_mark("<O")
}

@(private = "file")
wp18_mw_inner :: proc(ctx: ^Context) {
	wp18_mark("I>")
	next(ctx)
	wp18_mark("<I")
}

@(private = "file")
wp18_mw_guard_deny :: proc(ctx: ^Context) {
	wp18_mark("G")
	text(ctx, .Forbidden, "denied")
}

@(private = "file")
wp18_h :: proc(ctx: ^Context) {
	wp18_mark("H")
	sink := (^Wp18_Sink)(context.user_ptr)
	if sink != nil {
		sink.handler_runs += 1
	}
	text(ctx, .OK, "handler")
}

@(private = "file")
wp18_h_id :: proc(ctx: ^Context) {
	id := path(ctx, "id")
	text(ctx, .OK, id)
}

@(private = "file")
wp18_h_secret :: proc(ctx: ^Context) {
	text(ctx, .OK, "TOP-SECRET")
}

@(private = "file")
wp18_h_noop :: proc(ctx: ^Context) {
	no_content(ctx)
}

// ---------------------------------------------------------------------------
// 1. Mounting and path construction (spec: prefix concatenation is path
//    construction; a bug there mounts routes at unintended paths)
// ---------------------------------------------------------------------------

@(test)
wp18_mounted_route_is_reachable_at_prefix_plus_pattern :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)

	r := router()
	defer destroy(&r)
	get(&r, "/users", wp18_h)
	mount(&a, "/api", &r)

	ctx: Context
	wp18_run(&a, &ctx, .GET, "/api/users")
	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), "handler")
	driver_cleanup(&ctx)

	// The unprefixed path does NOT serve: the route moved, it was not copied
	// to both places.
	ctx2: Context
	wp18_run(&a, &ctx2, .GET, "/users")
	testing.expect_value(t, ctx2.private.response.status, Status.Not_Found)
	driver_cleanup(&ctx2)
}

@(test)
wp18_concatenation_is_verbatim_no_segment_is_swallowed :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)

	r := router()
	defer destroy(&r)
	get(&r, "/users", wp18_h)
	// The root pattern is a real pattern: mounted at "/api" it becomes exactly
	// "/api/" — the WP4 no-normalisation rule carried through construction.
	get(&r, "/", wp18_h_noop)
	mount(&a, "/api", &r)

	// "/api/users", never "/apiusers" and never "/api/users/" — the mounted
	// pattern is prefix + pattern VERBATIM.
	ctx: Context
	wp18_run(&a, &ctx, .GET, "/apiusers")
	testing.expect_value(t, ctx.private.response.status, Status.Not_Found)
	driver_cleanup(&ctx)

	ctx2: Context
	wp18_run(&a, &ctx2, .GET, "/api/")
	testing.expect_value(t, ctx2.private.response.status, Status.No_Content)
	driver_cleanup(&ctx2)

	// "/api" itself matches nothing: the router's "/" becomes "/api/", and
	// `/api` != `/api/` (no trailing-slash folding, WP4 D5).
	ctx3: Context
	wp18_run(&a, &ctx3, .GET, "/api")
	testing.expect_value(t, ctx3.private.response.status, Status.Not_Found)
	driver_cleanup(&ctx3)
}

@(test)
wp18_parametric_routes_survive_mounting :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)

	r := router()
	defer destroy(&r)
	get(&r, "/users/:id", wp18_h_id)
	get(&r, "/users/me", wp18_h)
	mount(&a, "/api", &r)

	// The capture works at the mounted path, and static still beats
	// parametric after mounting (the WP4 precedence rule is a property of the
	// pattern, which mounting must preserve).
	ctx: Context
	wp18_run(&a, &ctx, .GET, "/api/users/42")
	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), "42")
	driver_cleanup(&ctx)

	ctx2: Context
	wp18_run(&a, &ctx2, .GET, "/api/users/me")
	testing.expect_value(t, string(ctx2.private.response.body), "handler")
	driver_cleanup(&ctx2)
}

@(test)
wp18_parametric_prefix_is_path_construction_not_an_error :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)

	r := router()
	defer destroy(&r)
	get(&r, "/posts", wp18_h_id)
	// One :param in the prefix + a static pattern = a valid one-param pattern.
	mount(&a, "/tenants/:id", &r)

	ctx: Context
	wp18_run(&a, &ctx, .GET, "/tenants/acme/posts")
	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), "acme")
	driver_cleanup(&ctx)
}

@(test)
wp18_a_parametric_prefix_now_captures_both :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)

	r := router()
	defer destroy(&r)
	get(&r, "/posts/:post", wp18_h)
	get(&r, "/posts", wp18_h_noop)
	mount(&a, "/tenants/:id", &r)

	// AMENDED BY WP33, AND IT IS A BUG FIX RATHER THAN A RENAME.
	//
	// This test used to be `wp18_two_params_after_concatenation_never_match`
	// and asserted a 404. `":id" + ":post"` concatenated to a two-parameter
	// pattern, which `pattern_classify` refused under Phase 1's one-parameter
	// bound — so MOUNTING A ROUTER UNDER A PARAMETRIC PREFIX was silently
	// broken: every route inside it became unreachable, with no diagnostic.
	//
	// WP33 raised the bound to eight, so the concatenated pattern is ordinary
	// and both captures are available. The old expectation was correct for the
	// old bound and is deliberately reversed, not accidentally broken.
	ctx: Context
	wp18_run(&a, &ctx, .GET, "/tenants/acme/posts/7")
	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, ctx.private.param.count, 2)
	testing.expect_value(t, ctx.private.param.slot[0].name, "id")
	testing.expect_value(t, ctx.private.param.slot[0].value, "acme")
	testing.expect_value(t, ctx.private.param.slot[1].name, "post")
	testing.expect_value(t, ctx.private.param.slot[1].value, "7")
	driver_cleanup(&ctx)

	// The router's other route still serves, with the prefix's own capture.
	ctx2: Context
	wp18_run(&a, &ctx2, .GET, "/tenants/acme/posts")
	testing.expect_value(t, ctx2.private.response.status, Status.No_Content)
	testing.expect_value(t, ctx2.private.param.count, 1)
	testing.expect_value(t, ctx2.private.param.slot[0].value, "acme")
	driver_cleanup(&ctx2)
}

@(test)
wp18_mounted_routes_participate_in_405_allow :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)

	r := router()
	defer destroy(&r)
	get(&r, "/users", wp18_h)
	post(&r, "/users", wp18_h_noop)
	mount(&a, "/api", &r)

	ctx: Context
	wp18_run(&a, &ctx, .PUT, "/api/users")
	testing.expect_value(t, ctx.private.response.status, Status.Method_Not_Allowed)
	testing.expect_value(t, len(ctx.private.response.headers), 2)
	testing.expect_value(t, ctx.private.response.headers[0].name, "Allow")
	testing.expect_value(t, ctx.private.response.headers[0].value, "GET, HEAD, POST, OPTIONS")
	driver_cleanup(&ctx)
}

// ---------------------------------------------------------------------------
// 2. Chain composition (spec §2.1: app globals, then each enclosing router
//    outermost first, then the handler; reverse unwind)
// ---------------------------------------------------------------------------

@(test)
wp18_order_app_then_router_then_handler_exact_reverse_unwind :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, wp18_mw_app)

	r := router()
	defer destroy(&r)
	use(&r, wp18_mw_outer)
	get(&r, "/x", wp18_h)
	mount(&a, "/api", &r)

	res := test_request(&a, .GET, "/api/x")

	testing.expect_value(t, wp18_order(&sink), "A>O>H<O<A")
	testing.expect_value(t, res.status, Status.OK)
}

@(test)
wp18_nested_routers_outer_use_before_inner_use_before_handler :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, wp18_mw_app)

	inner := router()
	defer destroy(&inner)
	use(&inner, wp18_mw_inner)
	get(&inner, "/leaf", wp18_h)

	outer := router()
	defer destroy(&outer)
	use(&outer, wp18_mw_outer)
	mount(&outer, "/in", &inner)

	mount(&a, "/out", &outer)

	res := test_request(&a, .GET, "/out/in/leaf")

	// The §2.1 order, exactly: app globals, outermost router, inner router,
	// handler — unwinding in exact reverse.
	testing.expect_value(t, wp18_order(&sink), "A>O>I>H<I<O<A")
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, res.body, "handler")
}

@(test)
wp18_one_route_router_is_the_route_level_guard :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)

	// ADR-025 option B's canonical shape: a route needing its own guard is a
	// ONE-ROUTE Router mounted at the path. The guard denies without next.
	guarded := router()
	defer destroy(&guarded)
	use(&guarded, wp18_mw_guard_deny)
	get(&guarded, "/", wp18_h_secret)
	mount(&a, "/admin/keys", &guarded)

	get(&a, "/public", wp18_h)

	denied := test_request(&a, .GET, "/admin/keys/")
	testing.expect_value(t, denied.status, Status.Forbidden)
	testing.expect_value(t, denied.body, "denied")
	testing.expect(t, !wp18_contains(denied.body, "TOP-SECRET"))
	testing.expect_value(t, wp18_order(&sink), "G")

	// The guard is the router's, not the app's: other routes are unaffected.
	open_route := test_request(&a, .GET, "/public")
	testing.expect_value(t, open_route.status, Status.OK)
}

@(test)
wp18_router_middleware_do_not_run_on_an_app_miss :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, wp18_mw_app)

	r := router()
	defer destroy(&r)
	use(&r, wp18_mw_outer)
	get(&r, "/x", wp18_h)
	mount(&a, "/api", &r)

	res := test_request(&a, .GET, "/nope")

	// Spec §4 item 1: a miss has no route and no router, so ONLY the app
	// globals observe it — no `O>` appears.
	testing.expect_value(t, wp18_order(&sink), "A><A")
	testing.expect_value(t, res.status, Status.Not_Found)
}

// ---------------------------------------------------------------------------
// 3. Fail-closed (ADR-019 inside Router; mount counts as a registration;
//    mount closes the router; poison propagates)
// ---------------------------------------------------------------------------

@(test)
wp18_use_after_route_inside_a_router_fails_closed :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.logger = wp18_capture_logger(&sink)

	r := router()
	defer destroy(&r)
	get(&r, "/admin", wp18_h_secret)
	use(&r, wp18_mw_outer)

	// ADR-019 applies INSIDE Router, with the same observable predicate.
	testing.expect(t, r.private.poisoned, "use() after a route inside a Router must poison it")
	testing.expect(
		t,
		wp18_contains(wp18_logged(&sink), "web.use was called after a route was already registered"),
		"the ADR-019 diagnostic must fire for a Router exactly as for an App",
	)
}

@(test)
wp18_mounting_a_poisoned_router_poisons_the_app :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.logger = wp18_capture_logger(&sink)

	r := router()
	defer destroy(&r)
	get(&r, "/admin", wp18_h_secret)
	use(&r, wp18_mw_outer) // poisons the router

	a := app()
	defer destroy(&a)
	mount(&a, "/api", &r)

	// Fail-closed propagation: a rejected router must not become a healthy
	// app that silently serves the mis-ordered routes.
	testing.expect(t, a.private.poisoned, "mounting a poisoned router must poison the app")

	res := test_request(&a, .GET, "/api/admin")
	testing.expect_value(t, res.status, Status.Internal_Server_Error)
	testing.expect(t, !wp18_contains(res.body, "TOP-SECRET"))
}

@(test)
wp18_mount_counts_as_a_registration_for_the_app :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.logger = wp18_capture_logger(&sink)

	a := app()
	defer destroy(&a)

	r := router()
	defer destroy(&r)
	get(&r, "/x", wp18_h)
	mount(&a, "/api", &r)

	// ADR-019: `mount()` counts as a registration, so a later app-level use()
	// is the same boot failure.
	use(&a, wp18_mw_app)
	testing.expect(t, a.private.poisoned, "use() after mount() must poison the app")

	res := test_request(&a, .GET, "/api/x")
	testing.expect_value(t, res.status, Status.Internal_Server_Error)
}

@(test)
wp18_mount_closes_the_router :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.logger = wp18_capture_logger(&sink)

	a := app()
	defer destroy(&a)

	r := router()
	defer destroy(&r)
	get(&r, "/x", wp18_h)
	mount(&a, "/api", &r)

	// A registration on a mounted router would be silently dead (mount already
	// copied), so it FAILS CLOSED instead of being ignored.
	get(&r, "/late", wp18_h_secret)
	testing.expect(t, r.private.poisoned, "registering on a mounted router must poison it")
	testing.expect(
		t,
		wp18_contains(wp18_logged(&sink), "after web.mount"),
		"the closed-router diagnostic must name the mount rule",
	)

	// The app mounted BEFORE the offence and is unaffected; the already-mounted
	// route still serves.
	testing.expect(t, !a.private.poisoned)
	res := test_request(&a, .GET, "/api/x")
	testing.expect_value(t, res.status, Status.OK)
}

@(test)
wp18_mounting_a_closed_router_again_fails_closed :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.logger = wp18_capture_logger(&sink)

	a := app()
	defer destroy(&a)

	r := router()
	defer destroy(&r)
	get(&r, "/x", wp18_h)
	mount(&a, "/api", &r)

	b := app()
	defer destroy(&b)
	mount(&b, "/other", &r)

	// mount() closes the router (settled sub-decision); a second mount is the
	// same closed-router offence and rejects the SECOND app.
	testing.expect(t, b.private.poisoned, "mounting a closed router must poison the receiving app")
	testing.expect(t, !a.private.poisoned, "the first app is untouched by the second mount")
}

@(test)
wp18_invalid_prefix_fails_closed_and_names_the_prefix :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.logger = wp18_capture_logger(&sink)

	a := app()
	defer destroy(&a)

	r := router()
	defer destroy(&r)
	get(&r, "/x", wp18_h_secret)

	// The prefix grammar: must begin with '/', must not end with '/', and ""
	// is invalid. A bad prefix mounts a whole router at unintended paths, so
	// it is a boot failure with a diagnostic — never a silent no-op.
	mount(&a, "", &r)

	testing.expect(t, a.private.poisoned, "an empty prefix must fail closed")
	testing.expect(
		t,
		wp18_contains(wp18_logged(&sink), "web.mount was given an invalid prefix"),
		"the invalid-prefix diagnostic must be emitted",
	)

	res := test_request(&a, .GET, "/x")
	testing.expect_value(t, res.status, Status.Internal_Server_Error)
	testing.expect(t, !wp18_contains(res.body, "TOP-SECRET"))
}

@(test)
wp18_prefix_grammar_rejects_each_malformed_shape :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.logger = wp18_capture_logger(&sink)

	// Each shape on a FRESH app, so one rejection cannot mask another.
	malformed := [4]string{"", "api", "/api/", "/"}
	for prefix in malformed {
		a := app()
		r := router()
		get(&r, "/x", wp18_h_noop)
		mount(&a, prefix, &r)
		testing.expectf(t, a.private.poisoned, "prefix %q must fail closed", prefix)
		destroy(&r)
		destroy(&a)
	}
}

// ---------------------------------------------------------------------------
// 4. Ownership and allocation (App and Router are two owners; each destroyed
//    exactly once, neither ever copied)
// ---------------------------------------------------------------------------

@(test)
wp18_app_and_router_each_release_their_own_storage_exactly_once :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	a := app()
	use(&a, wp18_mw_app)

	r := router()
	use(&r, wp18_mw_outer)
	get(&r, "/users/:id", wp18_h_id)
	post(&r, "/users", wp18_h_noop)
	mount(&a, "/api", &r)

	// One routed request and one miss, so every lazy structure exists.
	ctx1: Context
	wp18_run(&a, &ctx1, .GET, "/api/users/1")
	driver_cleanup(&ctx1)
	ctx2: Context
	wp18_run(&a, &ctx2, .GET, "/nope")
	driver_cleanup(&ctx2)

	testing.expect(t, len(track.allocation_map) > 0)

	// Two owners, two destroys, in either order; everything released, nothing
	// released twice. mount COPIED, so destroying the router first cannot
	// dangle the app's mounted entries.
	destroy(&r)

	ctx3: Context
	wp18_run(&a, &ctx3, .GET, "/api/users/7")
	testing.expect_value(t, ctx3.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx3.private.response.body), "7")
	driver_cleanup(&ctx3)

	destroy(&a)
	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)

	// Second destroys are safe no-ops (the WP4/WP17 teardown rule).
	destroy(&a)
	destroy(&r)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
wp18_dispatch_through_a_mounted_chain_allocates_zero :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	use(&a, wp18_mw_app)

	r := router()
	defer destroy(&r)
	use(&r, wp18_mw_outer)
	get(&r, "/z", wp18_h_noop)
	mount(&a, "/api", &r)

	warm: Context
	wp18_run(&a, &warm, .GET, "/api/z")
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
	wp18_run(&a, &ctx, .GET, "/api/z")
	driver_cleanup(&ctx)

	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect_value(t, track.total_memory_allocated, 0)
	testing.expect_value(t, temp_track.total_allocation_count, 0)
}

@(test)
wp18_an_unmounted_router_leaks_nothing :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	context.allocator = mem.tracking_allocator(&track)

	// A router built and destroyed without ever being mounted: its own
	// storage, its own teardown, nothing left behind.
	r := router()
	use(&r, wp18_mw_outer)
	get(&r, "/x", wp18_h)
	destroy(&r)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// ---------------------------------------------------------------------------
// WP18 Amendment 1 — `mount` is FAIL-CLOSED when registration cannot allocate.
//
// The defect these tests exist to refuse: `mount` publishes routes with
// `strings.concatenate` and `append`, and Odin's `append` does NOT panic when
// it cannot allocate — `_append_elem` returns `num_appended = 0` and reports
// the failure through `#optional_allocator_error`, which a call site is free
// to discard. Discarding it means routes vanish with no diagnostic while the
// App still reports healthy: `serve` binds, and every lost route answers 404.
//
// That is fail-OPEN, in the one place ADR-019 exists to make fail-closed. It
// was measured before this test was written: with a fixed `mem.Arena` in
// `context.allocator`, 8 of 12 routes mounted and `poisoned` stayed false.
//
// The fixture is an arena small enough to run out mid-publication. It is a
// legal, documented Odin practice — nothing in the framework is patched to
// provoke this — and Phase 3's arena work (P3-10) makes bounded allocators
// MORE common, not less.
// ---------------------------------------------------------------------------

@(private = "file")
WP18_MOUNT_PATTERNS :: [?]string {
	"/a1", "/a2", "/a3", "/a4", "/a5", "/a6",
	"/a7", "/a8", "/a9", "/a10", "/a11", "/a12",
}

// wp18_mount_under_arena mounts the full pattern set through an arena of
// `size` bytes and reports what the App ended up with.
@(private = "file")
wp18_mount_under_arena :: proc(
	size: int,
) -> (
	mounted: int,
	poisoned: bool,
	closed: bool,
) {
	backing := make([]u8, size)
	defer delete_slice(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)

	a := app()
	r := router()
	for pattern in WP18_MOUNT_PATTERNS {
		get(&r, pattern, wp18_h)
	}

	// Only the MOUNT runs under the bounded arena; building the router used
	// the ordinary allocator, so the failure is isolated to publication.
	previous := context.allocator
	context.allocator = mem.arena_allocator(&arena)
	mount(&a, "/api", &r)
	context.allocator = previous

	// The Router's own storage came from the ORDINARY allocator, so it is
	// released normally. The App's storage came from the arena and is
	// reclaimed wholesale when `backing` goes — destroying it here would hand
	// arena pointers to the ordinary allocator.
	destroy(&r)

	return len(a.private.routes), a.private.poisoned, r.private.closed
}

@(test)
wp18_mount_that_cannot_allocate_rejects_the_application :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.logger = wp18_capture_logger(&sink)

	// 1024 B was measured to publish 8 of 12 routes before running out — the
	// exact partial state the amendment describes.
	mounted, poisoned, _ := wp18_mount_under_arena(1024)

	testing.expect(
		t,
		mounted < len(WP18_MOUNT_PATTERNS),
		"precondition: the arena must be too small to publish every route",
	)
	testing.expect(
		t,
		poisoned,
		"a mount that could not publish every route must reject the application fail-closed (ADR-019), never leave it healthy with routes missing",
	)
	testing.expect(
		t,
		sink.log_n > 0,
		"the rejection must be diagnosed, not silent",
	)
	// STRENGTHENED BY WP38, and the reason belongs in the file. Asserting only
	// "poisoned" made this test pass for the WRONG reason once WP30 shipped: with
	// the append guard removed, `index_insert` was handed a stale index, found
	// the slot occupied and raised a CONFLICT — so the App was still rejected,
	// the test still green, and `check_wp18_controls.sh` control 6 no longer
	// isolated the defect it was written for. Found by re-running every mutation
	// suite at the Phase-3 freeze, which is what that step is for.
	//
	// A fail-closed test must assert the diagnosis, not merely the refusal.
	testing.expect(
		t,
		wp18_contains(wp18_logged(&sink), "could not allocate storage for the routes"),
		"the application must be rejected for the ALLOCATION failure specifically; any other diagnostic means this test is passing for a different reason than it was written for",
	)
}

@(test)
wp18_a_mount_that_cannot_allocate_never_serves :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.logger = wp18_capture_logger(&sink)

	backing := make([]u8, 1024)
	defer delete_slice(backing)
	arena: mem.Arena
	mem.arena_init(&arena, backing)

	a := app()
	r := router()
	for pattern in WP18_MOUNT_PATTERNS {
		get(&r, pattern, wp18_h)
	}

	previous := context.allocator
	context.allocator = mem.arena_allocator(&arena)
	mount(&a, "/api", &r)
	context.allocator = previous
	defer destroy(&r)

	// The consequence that matters, asked of a route that was actually LOST.
	// `/api/a12` is past the point the arena ran out, so today it answers 404
	// — indistinguishable from a route the developer never wrote. A poisoned
	// App answers 500 on EVERY path through the dispatch-path guard, which is
	// what makes the silent 404 impossible.
	ctx: Context
	defer driver_cleanup(&ctx)
	wp18_run(&a, &ctx, .GET, "/api/a12")

	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
	// WP38: for the allocation failure, not for whatever else might reject an
	// App. See the note in the test above.
	testing.expect(
		t,
		wp18_contains(wp18_logged(&sink), "could not allocate storage for the routes"),
		"the 500 must come from the allocation rejection, not from another diagnosis",
	)
}

@(test)
wp18_a_mount_with_room_to_spare_is_unaffected :: proc(t: ^testing.T) {
	sink: Wp18_Sink
	context.logger = wp18_capture_logger(&sink)

	// The positive control. Without it, a `mount` that poisoned
	// unconditionally would pass both tests above while breaking every
	// application — the probe must fail for the RIGHT reason.
	mounted, poisoned, closed := wp18_mount_under_arena(16 * 1024)

	testing.expect_value(t, mounted, len(WP18_MOUNT_PATTERNS))
	testing.expect(t, !poisoned, "a mount that fully succeeded must NOT reject the application")
	testing.expect(t, closed, "a successful mount still closes the Router")
	testing.expect_value(t, sink.log_n, 0)
}
