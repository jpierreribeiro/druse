// WP19 internal behavior tests — `header`, `bearer_token`, the ADR-027
// overlay READ path, and the `test_request` headers-parameter parsing.
//
// This file declares `package web` but does NOT live in `web/`: the overlay
// slot, `Header_Pair`, `header_view_from_pairs` and the facade's header-line
// splitter are package-private, and `build/check.sh` assembles the usual
// THROWAWAY package from the real `web/` sources plus this file (the
// WP2-WP18 arrangement).
//
// WHAT IS DELIBERATELY ABSENT: a capture logger. The header lookups are PURE —
// they commit no response and log NOTHING (header values are
// attacker-controlled; the WP6 measured rule bans core:log/core:fmt from the
// package) — so no test here expects a diagnostic, and any Error-level log
// line IS a failure the runner should report.
#+private
package web

import "core:mem"
import "core:slice"
import "core:testing"
import transport "druse:web/internal/transport"

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

// wp19_ctx builds a Context whose request carries exactly `pairs`, through the
// same private wrapper the shared driver uses. No dispatch: these are pure
// lookups and need no route.
@(private = "file")
wp19_ctx :: proc(ctx: ^Context, pairs: []Header_Pair) {
	ctx.request.headers = header_view_from_pairs(pairs)
}

@(private = "file")
wp19_run :: proc(a: ^App, ctx: ^Context, method: Method, path: string, headers: []transport.Header) {
	driver_run(
		a,
		ctx,
		transport.Inbound{method = method_token(method), path = path, headers = headers},
	)
}

// ---------------------------------------------------------------------------
// 1. `header` — presence, case, duplicates, purity
// ---------------------------------------------------------------------------

@(test)
wp19_header_present_returns_value_and_true :: proc(t: ^testing.T) {
	pairs := [2]Header_Pair {
		{name = "Content-Type", value = "application/json"},
		{name = "X-Api-Key", value = "k-123"},
	}
	ctx: Context
	wp19_ctx(&ctx, pairs[:])

	value, ok := header(&ctx, "X-Api-Key")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, value, "k-123")

	// PURE lookup: no response side effect, unlike the extractors (WP19 plan —
	// an absent or present header is routinely not an error).
	testing.expect_value(t, ctx.private.response.committed, false)
}

@(test)
wp19_header_absent_returns_empty_and_false :: proc(t: ^testing.T) {
	pairs := [1]Header_Pair{{name = "Content-Type", value = "application/json"}}
	ctx: Context
	wp19_ctx(&ctx, pairs[:])

	value, ok := header(&ctx, "X-Missing")
	testing.expect_value(t, ok, false)
	testing.expect_value(t, value, "")
	testing.expect_value(t, ctx.private.response.committed, false)
}

@(test)
wp19_header_names_are_case_insensitive_both_directions :: proc(t: ^testing.T) {
	pairs := [2]Header_Pair {
		{name = "X-API-KEY", value = "upper-stored"},
		{name = "x-lower-token", value = "lower-stored"},
	}
	ctx: Context
	wp19_ctx(&ctx, pairs[:])

	v1, ok1 := header(&ctx, "x-api-key")
	testing.expect_value(t, ok1, true)
	testing.expect_value(t, v1, "upper-stored")

	v2, ok2 := header(&ctx, "X-LOWER-TOKEN")
	testing.expect_value(t, ok2, true)
	testing.expect_value(t, v2, "lower-stored")
}

@(test)
wp19_header_empty_value_is_present :: proc(t: ^testing.T) {
	// Present with an empty value is (\"\", true) — presence, not validity
	// (the plan's explicit rule).
	pairs := [1]Header_Pair{{name = "X-Empty", value = ""}}
	ctx: Context
	wp19_ctx(&ctx, pairs[:])

	value, ok := header(&ctx, "x-empty")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, value, "")
}

@(test)
wp19_header_scan_takes_the_first_matching_pair :: proc(t: ^testing.T) {
	// THE SCAN RULE, not the duplicate-header contract — the two were conflated
	// and this test carried the wrong name.
	//
	// On the wire a repeated name never reaches the core as two pairs: the
	// transport's `header_parse` joins repeats with `", "` (RFC 9110 §5.3), and
	// `web.test_request` now does the same, so `X-Dup: a` + `X-Dup: b` arrives
	// as the single value `"a, b"`. What THIS pins is the core's behaviour when
	// it is nevertheless handed several pairs of one name: it takes the first
	// match and never concatenates. That is a defensive property of the scan —
	// deterministic, allocation-free — and it stays worth pinning precisely
	// because no transport is supposed to produce this input.
	pairs := [3]Header_Pair {
		{name = "X-Dup", value = "first"},
		{name = "x-dup", value = "second"},
		{name = "X-DUP", value = "third"},
	}
	ctx: Context
	wp19_ctx(&ctx, pairs[:])

	value, ok := header(&ctx, "x-dup")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, value, "first")
}

@(test)
wp19_header_value_is_a_view_invalidated_by_buffer_reuse :: proc(t: ^testing.T) {
	// The WP2 view-invalidation test, ported to the lookup (the plan requires
	// it): the returned value ALIASES transport-owned storage and does not
	// survive its reuse. This is the documented lifetime, demonstrated.
	buf := make([]u8, 5)
	defer delete_slice(buf)
	copy(buf, transmute([]u8)string("token"))

	pairs := make([]Header_Pair, 1)
	defer delete_slice(pairs)
	pairs[0] = Header_Pair{name = "X-Secret", value = string(buf[:])}

	ctx: Context
	wp19_ctx(&ctx, pairs)

	retained, ok := header(&ctx, "x-secret")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, retained, "token")

	// The transport reuses its buffer for the next request.
	slice.fill(buf, '#')

	testing.expect(
		t,
		retained != "token",
		"a retained header value must not survive reuse of the transport buffer",
	)
	testing.expect_value(t, retained, "#####")
}

// ---------------------------------------------------------------------------
// 2. The ADR-027 overlay READ path (spec §7: WP23 writes it, WP19 reads it)
// ---------------------------------------------------------------------------

@(test)
wp19_overlay_shadows_the_arrived_header :: proc(t: ^testing.T) {
	// `web.header` is documented as "the EFFECTIVE request header": a value the
	// framework placed in the private overlay wins over what arrived, which is
	// what lets WP23's request_id middleware replace an invalid client ID
	// without the client's bytes ever being readable downstream.
	pairs := [1]Header_Pair{{name = "X-Request-Id", value = "attacker-supplied"}}
	ctx: Context
	wp19_ctx(&ctx, pairs[:])

	ctx.private.overlay = Header_Pair{name = "X-Request-Id", value = "generated-1"}
	ctx.private.overlay_set = true

	value, ok := header(&ctx, "x-request-id")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, value, "generated-1")
}

@(test)
wp19_overlay_answers_even_when_nothing_arrived :: proc(t: ^testing.T) {
	ctx: Context
	wp19_ctx(&ctx, nil)

	ctx.private.overlay = Header_Pair{name = "X-Request-Id", value = "generated-2"}
	ctx.private.overlay_set = true

	value, ok := header(&ctx, "X-Request-Id")
	testing.expect_value(t, ok, true)
	testing.expect_value(t, value, "generated-2")

	// Other names are untouched by the overlay.
	_, other := header(&ctx, "X-Api-Key")
	testing.expect_value(t, other, false)
}

// ---------------------------------------------------------------------------
// 3. `bearer_token` — the strict RFC 6750 parse
// ---------------------------------------------------------------------------

@(private = "file")
wp19_bearer_ctx :: proc(ctx: ^Context, pairs: []Header_Pair) {
	wp19_ctx(ctx, pairs)
}

@(test)
wp19_bearer_valid_token_is_returned_verbatim :: proc(t: ^testing.T) {
	pairs := [1]Header_Pair{{name = "Authorization", value = "Bearer aB.c_d~e+f/g=="}}
	ctx: Context
	wp19_bearer_ctx(&ctx, pairs[:])

	value, ok := bearer_token(&ctx)
	testing.expect_value(t, ok, true)
	// NOT trimmed, NOT normalised — byte-identical pass-through (the plan's
	// security rule: normalising comparisons invite secret-handling bugs).
	testing.expect_value(t, value, "aB.c_d~e+f/g==")
	testing.expect_value(t, ctx.private.response.committed, false)
}

@(test)
wp19_bearer_scheme_is_case_insensitive :: proc(t: ^testing.T) {
	schemes := [3]string{"bearer tok1", "BEARER tok1", "BeArEr tok1"}
	for raw in schemes {
		pairs := [1]Header_Pair{{name = "Authorization", value = raw}}
		ctx: Context
		wp19_bearer_ctx(&ctx, pairs[:])

		value, ok := bearer_token(&ctx)
		testing.expectf(t, ok, "scheme spelling %q must be accepted", raw)
		testing.expect_value(t, value, "tok1")
	}
}

@(test)
wp19_bearer_rejects_every_malformed_shape :: proc(t: ^testing.T) {
	// Each rejected with (\"\", false) and NO response side effect. The
	// grammar: scheme case-insensitive, EXACTLY one space, non-empty token,
	// no whitespace tolerance anywhere in the token.
	malformed := [8]string {
		"Bearer",         // no space, no token
		"Bearer ",        // empty token
		"Bearer  x",      // two spaces
		"Bearer x ",      // trailing whitespace
		"Bearer a b",     // token with a space
		"Bearer\tx",      // tab, not space
		"Basic abc",      // wrong scheme
		"Bearerx",        // scheme not followed by a space
	}
	for raw in malformed {
		pairs := [1]Header_Pair{{name = "Authorization", value = raw}}
		ctx: Context
		wp19_bearer_ctx(&ctx, pairs[:])

		value, ok := bearer_token(&ctx)
		testing.expectf(t, !ok, "Authorization value %q must be rejected", raw)
		testing.expect_value(t, value, "")
		testing.expect_value(t, ctx.private.response.committed, false)
	}
}

@(test)
wp19_bearer_missing_authorization_is_false :: proc(t: ^testing.T) {
	pairs := [1]Header_Pair{{name = "X-Api-Key", value = "k"}}
	ctx: Context
	wp19_bearer_ctx(&ctx, pairs[:])

	value, ok := bearer_token(&ctx)
	testing.expect_value(t, ok, false)
	testing.expect_value(t, value, "")
}

@(test)
wp19_bearer_first_authorization_wins :: proc(t: ^testing.T) {
	pairs := [2]Header_Pair {
		{name = "Authorization", value = "Bearer first-token"},
		{name = "authorization", value = "Bearer second-token"},
	}
	ctx: Context
	wp19_bearer_ctx(&ctx, pairs[:])

	value, ok := bearer_token(&ctx)
	testing.expect_value(t, ok, true)
	testing.expect_value(t, value, "first-token")
}

// ---------------------------------------------------------------------------
// 4. Allocation — pure lookups allocate NOTHING
// ---------------------------------------------------------------------------

@(test)
wp19_lookups_allocate_zero :: proc(t: ^testing.T) {
	pairs := [3]Header_Pair {
		{name = "Content-Type", value = "application/json"},
		{name = "Authorization", value = "Bearer tok"},
		{name = "X-Api-Key", value = "k-1"},
	}
	ctx: Context
	wp19_ctx(&ctx, pairs[:])

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	temp_track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&temp_track, context.temp_allocator)
	defer mem.tracking_allocator_destroy(&temp_track)

	context.allocator = mem.tracking_allocator(&track)
	context.temp_allocator = mem.tracking_allocator(&temp_track)

	_, _ = header(&ctx, "x-api-key")
	_, _ = header(&ctx, "x-missing")
	_, _ = bearer_token(&ctx)

	testing.expect_value(t, track.total_allocation_count, 0)
	testing.expect_value(t, temp_track.total_allocation_count, 0)
}

// ---------------------------------------------------------------------------
// 5. The facade's header-line splitter and the end-to-end driver path
// ---------------------------------------------------------------------------

@(private = "file")
wp19_echo_header_handler :: proc(ctx: ^Context) {
	value, ok := header(ctx, "x-api-key")
	if !ok {
		not_found(ctx, "header")
		return
	}
	text(ctx, .OK, value)
}

@(test)
wp19_test_request_headers_reach_the_lookup :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "/whoami", wp19_echo_header_handler)

	res := test_request(&a, .GET, "/whoami", headers = {"X-Api-Key: k-42"})
	testing.expect_value(t, res.status, Status.OK)
	testing.expect_value(t, res.body, "k-42")

	miss := test_request(&a, .GET, "/whoami")
	testing.expect_value(t, miss.status, Status.Not_Found)
}

@(test)
wp19_test_request_header_lines_are_split_and_ows_trimmed :: proc(t: ^testing.T) {
	// The facade mirrors the transport's field parsing: split at the FIRST
	// colon, trim optional whitespace (SP/HTAB) around the value — so the
	// in-memory request carries exactly what a socket would deliver.
	a := app()
	defer destroy(&a)
	get(&a, "/whoami", wp19_echo_header_handler)

	padded := test_request(&a, .GET, "/whoami", headers = {"X-Api-Key: \t padded \t "})
	testing.expect_value(t, padded.status, Status.OK)
	testing.expect_value(t, padded.body, "padded")

	// The value keeps its own inner bytes, colons included: only the FIRST
	// colon splits.
	colons := test_request(&a, .GET, "/whoami", headers = {"X-Api-Key: a:b:c"})
	testing.expect_value(t, colons.body, "a:b:c")
}

@(test)
wp19_headers_travel_the_shared_driver_pipeline :: proc(t: ^testing.T) {
	// Same assertion through driver_run directly — the exact pipeline `serve`
	// uses — so parity is exercised on the private path too (R-10).
	a := app()
	defer destroy(&a)
	get(&a, "/whoami", wp19_echo_header_handler)

	inbound_headers := [1]transport.Header{{name = "X-Api-Key", value = "socket-k"}}
	ctx: Context
	wp19_run(&a, &ctx, .GET, "/whoami", inbound_headers[:])
	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), "socket-k")
	driver_cleanup(&ctx)
}
