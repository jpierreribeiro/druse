// WP7 internal behavior tests — JSON body binding, the 4 MiB cap, the
// request-lifetime arena, and the single-consumer state machine.
//
// This file declares `package web` but does NOT live in `web/`, and it must
// never be moved there. The declarations it covers — `Context_Internal`,
// `Body_State`, the arena machinery, `Response`, `response_commit` and the
// typed framework report — are all package-private, and on the pinned toolchain
// an `@(test)` procedure must be compiled as part of the package it tests.
// Compiling it inside the shipped package would link `core:testing` into every
// application binary (+41,592 bytes measured on 819fdc7). `build/check.sh`
// therefore assembles a THROWAWAY package from the real `web/` sources plus
// this file, exactly as it already does for WP2-WP6.
//
// WHY THESE TESTS ARE INTERNAL. Four WP7 contracts cannot be observed from
// outside the package: that an over-limit or empty body does NOT initialize the
// arena; that the arena is freed exactly once with no leak; that the body
// capability is consumed before the parser; and that an internal decoder
// failure is LOGGED before the 500. `Recorded_Response` exposes only status and
// body, and there is no public arena or state accessor.
//
// THE LOG-ORDERING ORACLE mirrors WP6: a logger that records, at the instant it
// is called, whether the response was already committed — and swallows the
// framework's own diagnostic so the runner does not count it as a failure,
// while forwarding everything else so real assertion failures stay visible.
#+private
package web

import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// Payloads
// ---------------------------------------------------------------------------

@(private = "file")
Wp7_User :: struct {
	name:  string   `json:"name"`,
	email: string   `json:"email"`,
	tags:  []string `json:"tags"`,
	age:   int      `json:"age"`,
}

// ---------------------------------------------------------------------------
// The log oracle
// ---------------------------------------------------------------------------

@(private = "file")
WP7_LOG_MARKER :: "druse:"

@(private = "file")
Wp7_Log :: struct {
	framework_calls:  int,
	committed_at_log: bool,
	response:         ^Response,
	inner:            log.Logger,
}

@(private = "file")
wp7_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Wp7_Log)(data)

	// The framework's own diagnostic is the EVENT UNDER TEST: record it, do NOT
	// forward it (the runner treats any Error record as a failed assertion).
	if level == .Error && strings.contains(text, WP7_LOG_MARKER) {
		record.framework_calls += 1
		if record.response != nil {
			record.committed_at_log = record.response.committed
		}
		return
	}
	// Everything else is forwarded so real assertion failures still reach the
	// runner.
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

// wp7_recording_logger captures the currently-installed logger into `record`
// and returns the wrapping logger. The caller MUST assign it to its own
// `context.logger` inline: assigning inside a helper would only change that
// helper's context copy, which is discarded on return (Odin passes `context` by
// value into callees).
@(private = "file")
wp7_recording_logger :: proc(record: ^Wp7_Log) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = wp7_logger_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

// ---------------------------------------------------------------------------
// 1-4. Successful binding
// ---------------------------------------------------------------------------

@(test)
wp7_binds_a_simple_object :: proc(t: ^testing.T) {
	ctx: Context
	defer request_arena_destroy(&ctx)
	ctx.request.body = transmute([]u8)string(`{"name":"ada","age":36}`)

	dst: Wp7_User
	ok := body(&ctx, &dst)

	testing.expect(t, ok, "a valid object must bind")
	testing.expect_value(t, dst.name, "ada")
	testing.expect_value(t, dst.age, 36)
	testing.expect(t, !ctx.private.response.committed, "a successful bind commits no response")
}

@(test)
wp7_binds_nested_strings_and_slices :: proc(t: ^testing.T) {
	ctx: Context
	defer request_arena_destroy(&ctx)
	ctx.request.body = transmute([]u8)string(
		`{"name":"grace","email":"g@x.io","tags":["math","navy"],"age":85}`,
	)

	dst: Wp7_User
	ok := body(&ctx, &dst)

	testing.expect(t, ok)
	testing.expect_value(t, dst.email, "g@x.io")
	testing.expect_value(t, len(dst.tags), 2)
	testing.expect_value(t, dst.tags[0], "math")
	testing.expect_value(t, dst.tags[1], "navy")
}

@(test)
wp7_decoded_data_is_independent_of_the_raw_buffer :: proc(t: ^testing.T) {
	// The decoded strings/slices must live in the arena, not alias the request
	// body. Wiping the raw buffer after the bind must not corrupt `dst`.
	raw := `{"name":"ada","tags":["x","y"]}`
	backing := make([]u8, len(raw))
	defer delete_slice(backing)
	copy(backing, raw)

	ctx: Context
	defer request_arena_destroy(&ctx)
	ctx.request.body = backing

	dst: Wp7_User
	ok := body(&ctx, &dst)
	testing.expect(t, ok)

	slice.fill(backing, '#')

	testing.expect_value(t, dst.name, "ada")
	testing.expect_value(t, dst.tags[0], "x")
	testing.expect_value(t, dst.tags[1], "y")
}

@(test)
wp7_decoded_data_lives_in_the_request_arena :: proc(t: ^testing.T) {
	// R-06: the substituted arena allocator is honored. After the bind the arena
	// is active; after teardown a tracking allocator sees no live allocation and
	// no bad free — proving the nested data was arena-owned and freed with it.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	ctx: Context
	ctx.request.body = transmute([]u8)string(`{"name":"ada","tags":["math","engines"]}`)

	dst: Wp7_User
	ok := body(&ctx, &dst)
	testing.expect(t, ok)
	testing.expect(t, ctx.private.arena_active, "a successful bind must have created the arena")
	testing.expect(t, len(track.allocation_map) > 0, "binding nested data must have allocated")

	request_arena_destroy(&ctx)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect(t, !ctx.private.arena_active, "teardown must clear the arena")
}

// ---------------------------------------------------------------------------
// 5-6. Arena teardown lifecycle
// ---------------------------------------------------------------------------

@(test)
wp7_second_teardown_is_a_safe_no_op :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	ctx: Context
	ctx.request.body = transmute([]u8)string(`{"name":"x"}`)
	dst: Wp7_User
	testing.expect(t, body(&ctx, &dst))

	request_arena_destroy(&ctx)
	request_arena_destroy(&ctx)
	request_arena_destroy(&ctx)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
wp7_a_request_that_never_binds_makes_no_arena :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	ctx: Context
	// No body call at all.
	testing.expect(t, !ctx.private.arena_active)
	request_arena_destroy(&ctx)
	testing.expect_value(t, len(track.allocation_map), 0)
}

// ---------------------------------------------------------------------------
// 7-9. Empty and malformed bodies -> 400 invalid_json
// ---------------------------------------------------------------------------

@(private = "file")
wp7_expect_invalid_json :: proc(t: ^testing.T, ctx: ^Context, loc := #caller_location) {
	testing.expect_value(t, ctx.private.response.status, Status.Bad_Request, loc = loc)
	testing.expect_value(
		t,
		string(ctx.private.response.body),
		`{"error":{"code":"invalid_json","message":"Request body must be valid JSON"}}`,
		loc = loc,
	)
}

@(test)
wp7_empty_body_is_invalid_json_and_makes_no_arena :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	ctx: Context
	defer request_arena_destroy(&ctx)
	// body left nil/empty.

	dst: Wp7_User
	ok := body(&ctx, &dst)

	testing.expect(t, !ok)
	wp7_expect_invalid_json(t, &ctx)
	testing.expect(t, !ctx.private.arena_active, "an empty body must not initialize the arena")
	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
wp7_malformed_json_is_invalid_json :: proc(t: ^testing.T) {
	for raw in ([]string{"{", "{\"name\":", "not json", "   ", "{\"a\":1"}) {
		ctx: Context
		defer request_arena_destroy(&ctx)
		ctx.request.body = transmute([]u8)raw

		dst: Wp7_User
		ok := body(&ctx, &dst)
		testing.expectf(t, !ok, "malformed %q must fail", raw)
		wp7_expect_invalid_json(t, &ctx)
	}
}

@(test)
wp7_json5_is_rejected :: proc(t: ^testing.T) {
	// Strict JSON: unquoted keys, single-quoted strings and LEADING comments are
	// all rejected. (On 819fdc7 the pinned parser leniently ignores any content
	// AFTER a complete top-level value — a trailing comma, a trailing comment,
	// or trailing garbage. That deviation is documented in ADR-012 and the docs,
	// and deliberately not asserted here.)
	for raw in ([]string{`{name:"a"}`, `{"a":'b'}`, "// c\n{\"a\":1}"}) {
		ctx: Context
		defer request_arena_destroy(&ctx)
		ctx.request.body = transmute([]u8)raw

		dst: Wp7_User
		ok := body(&ctx, &dst)
		testing.expectf(t, !ok, "JSON5 %q must be rejected", raw)
		wp7_expect_invalid_json(t, &ctx)
	}
}

// ---------------------------------------------------------------------------
// 10-12. The 4 MiB cap -> 413 body_too_large
// ---------------------------------------------------------------------------

@(private = "file")
wp7_json_body_of_size :: proc(n: int, allocator: mem.Allocator) -> []u8 {
	// Builds `{"name":"<padding>"}` of exactly `n` bytes, so the whole body —
	// not just the payload — is `n` bytes. Requires n >= the fixed shell.
	PREFIX :: `{"name":"`
	SUFFIX :: `"}`
	buffer := make([]u8, n, allocator)
	slice.fill(buffer, 'x')
	copy(buffer, PREFIX)
	copy(buffer[n - len(SUFFIX):], SUFFIX)
	return buffer
}

@(test)
wp7_exactly_the_limit_is_not_too_large :: proc(t: ^testing.T) {
	// Exactly BODY_LIMIT bytes is ALLOWED. It is valid JSON, so it binds.
	raw := wp7_json_body_of_size(BODY_LIMIT, context.allocator)
	defer delete_slice(raw)

	ctx: Context
	defer request_arena_destroy(&ctx)
	ctx.request.body = raw

	dst: Wp7_User
	ok := body(&ctx, &dst)

	testing.expect(t, ok, "exactly 4 MiB must be accepted, not treated as 413")
	testing.expect(t, !ctx.private.response.committed)
	testing.expect_value(t, len(dst.name), BODY_LIMIT - len(`{"name":""}`))
}

@(test)
wp7_one_over_the_limit_is_too_large_before_parse_and_arena :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	raw := wp7_json_body_of_size(BODY_LIMIT + 1, context.allocator)
	defer delete_slice(raw)
	before := len(track.allocation_map)

	ctx: Context
	defer request_arena_destroy(&ctx)
	ctx.request.body = raw

	dst: Wp7_User
	ok := body(&ctx, &dst)

	testing.expect(t, !ok)
	// 413 is carried by a private status value; no public Status member exists.
	testing.expect_value(t, int(ctx.private.response.status), 413)
	// The 413 now reports the ACTUAL configured limit in bytes (WP-6.5.5), not a
	// constant "4 MiB". This request runs under the default cap of 4 MiB.
	testing.expect_value(
		t,
		string(ctx.private.response.body),
		`{"error":{"code":"body_too_large","message":"Request body exceeds the limit of 4194304 bytes"}}`,
	)

	// The cap is checked BEFORE the arena and BEFORE the parser: no arena, and
	// no allocation beyond the raw buffer the test itself made.
	testing.expect(t, !ctx.private.arena_active, "an over-limit body must not initialize the arena")
	testing.expect_value(t, len(track.allocation_map), before)
}

@(test)
wp7_body_too_large_reports_413 :: proc(t: ^testing.T) {
	// The private status carries the numeric 413 without a public Status member.
	ctx: Context
	defer request_arena_destroy(&ctx)
	ctx.request.body = wp7_json_body_of_size(BODY_LIMIT + 1, context.allocator)
	defer delete_slice(ctx.request.body)

	dst: Wp7_User
	body(&ctx, &dst)
	testing.expect_value(t, int(ctx.private.response.status), 413)
}

// ---------------------------------------------------------------------------
// 13-16. Single-consumer state machine (ADR-012 A)
// ---------------------------------------------------------------------------

@(test)
wp7_a_successful_first_bind_consumes_the_capability :: proc(t: ^testing.T) {
	ctx: Context
	defer request_arena_destroy(&ctx)
	ctx.request.body = transmute([]u8)string(`{"name":"a"}`)
	testing.expect_value(t, ctx.private.body_state, Body_State.Fresh)

	dst: Wp7_User
	testing.expect(t, body(&ctx, &dst))
	testing.expect_value(t, ctx.private.body_state, Body_State.Consumed)
}

@(test)
wp7_a_failed_first_bind_still_consumes_the_capability :: proc(t: ^testing.T) {
	// Even an invalid first attempt spends the capability, so a retry can never
	// re-parse.
	ctx: Context
	defer request_arena_destroy(&ctx)
	ctx.request.body = transmute([]u8)string(`{bad`)

	dst: Wp7_User
	testing.expect(t, !body(&ctx, &dst))
	testing.expect_value(t, ctx.private.body_state, Body_State.Consumed)
}

@(test)
wp7_second_bind_after_success_reports_and_500s :: proc(t: ^testing.T) {
	// First bind succeeds and commits nothing; a buggy handler binds again. The
	// second call logs the diagnostic and, since nothing is committed, produces
	// a 500. It never re-parses.
	record: Wp7_Log
	ctx: Context
	defer request_arena_destroy(&ctx)
	record.response = &ctx.private.response
	context.logger = wp7_recording_logger(&record)

	ctx.request.body = transmute([]u8)string(`{"name":"ada"}`)

	dst1: Wp7_User
	testing.expect(t, body(&ctx, &dst1))
	testing.expect_value(t, record.framework_calls, 0)

	dst2: Wp7_User
	ok := body(&ctx, &dst2)

	testing.expect(t, !ok, "a second bind reports failure")
	testing.expect_value(t, record.framework_calls, 1)
	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
	testing.expect_value(
		t,
		string(ctx.private.response.body),
		`{"error":{"code":"internal_error","message":"Internal server error"}}`,
	)
	// It did not re-parse into dst2.
	testing.expect_value(t, dst2.name, "")
}

@(test)
wp7_second_bind_after_a_committed_failure_preserves_the_first_response :: proc(t: ^testing.T) {
	// First bind is invalid and commits a 400. The second bind must log the
	// misuse but leave the 400 byte-for-byte — the first response wins.
	record: Wp7_Log
	ctx: Context
	defer request_arena_destroy(&ctx)
	record.response = &ctx.private.response
	context.logger = wp7_recording_logger(&record)

	ctx.request.body = transmute([]u8)string(`{bad`)

	dst1: Wp7_User
	testing.expect(t, !body(&ctx, &dst1))
	wp7_expect_invalid_json(t, &ctx)
	first_body := string(ctx.private.response.body)

	dst2: Wp7_User
	testing.expect(t, !body(&ctx, &dst2))

	testing.expect_value(t, record.framework_calls, 1)
	testing.expect_value(t, ctx.private.response.status, Status.Bad_Request)
	testing.expect_value(t, string(ctx.private.response.body), first_body)
}

@(test)
wp7_second_bind_never_double_commits :: proc(t: ^testing.T) {
	// A committed 413 must survive a second bind unchanged. The second call is a
	// double-use, so it logs the misuse diagnostic — swallow it so the runner
	// does not count that expected Error record as a failure.
	record: Wp7_Log
	ctx: Context
	defer request_arena_destroy(&ctx)
	record.response = &ctx.private.response
	context.logger = wp7_recording_logger(&record)

	// The over-limit buffer is kept in its OWN variable so its cleanup is not
	// lost when `ctx.request.body` is reassigned below.
	big := wp7_json_body_of_size(BODY_LIMIT + 1, context.allocator)
	defer delete_slice(big)
	ctx.request.body = big

	dst: Wp7_User
	testing.expect(t, !body(&ctx, &dst))
	testing.expect_value(t, int(ctx.private.response.status), 413)

	// Second call: give it a VALID body to prove it does not re-parse.
	ctx.request.body = transmute([]u8)string(`{"name":"sneaky"}`)
	testing.expect(t, !body(&ctx, &dst))
	testing.expect_value(t, int(ctx.private.response.status), 413)
	testing.expect_value(t, dst.name, "")
	testing.expect_value(t, record.framework_calls, 1)
}

// ---------------------------------------------------------------------------
// 17-18. Client field mismatch -> stable 400 (WP68)
// ---------------------------------------------------------------------------

@(test)
wp68_incompatible_field_is_a_client_400 :: proc(t: ^testing.T) {
	// Valid JSON whose field value does not fit the declared type is a client
	// error with a stable path. Unsupported destination TYPES remain internal,
	// but an ordinary scalar mismatch is not a framework fault.
	record: Wp7_Log
	ctx: Context
	defer request_arena_destroy(&ctx)
	record.response = &ctx.private.response
	context.logger = wp7_recording_logger(&record)

	// `age` expects an int; a non-numeric string is attributed to that field.
	ctx.request.body = transmute([]u8)string(`{"age":"not-an-int"}`)

	dst: Wp7_User
	ok := body(&ctx, &dst)

	testing.expect(t, !ok)
	testing.expect_value(t, record.framework_calls, 0)
	testing.expect_value(t, ctx.private.response.status, Status.Bad_Request)
	testing.expect_value(
		t,
		string(ctx.private.response.body),
		`{"error":{"code":"invalid_field","message":"Request field has an invalid value","field":"age"}}`,
	)
}

@(test)
wp7_a_failed_bind_leaves_no_leak :: proc(t: ^testing.T) {
	// A partial parse may leave allocations in the arena; teardown must release
	// them. Drive every failure mode and confirm the tracker is clean.
	//
	// Keep a recording logger installed to prove client failures do not emit a
	// framework-fault diagnostic while all temporary allocations are released.
	record: Wp7_Log
	context.logger = wp7_recording_logger(&record)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	for raw in ([]string{
		`{"name":"ada","tags":["a","b","c"`, // truncated mid-array (partial arena)
		`{"age":"x"}`, // type mismatch
		`{bad`, // malformed
	}) {
		ctx: Context
		ctx.request.body = transmute([]u8)raw
		dst: Wp7_User
		body(&ctx, &dst)
		request_arena_destroy(&ctx)
	}

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// ---------------------------------------------------------------------------
// 19. Binding through real dispatch, and the handler runs once
// ---------------------------------------------------------------------------

@(private = "file")
wp7_bind_hits: int

@(private = "file")
wp7_bound_name: string

@(private = "file")
wp7_bind_handler :: proc(ctx: ^Context) {
	wp7_bind_hits += 1
	dst: Wp7_User
	if !body(ctx, &dst) {
		return
	}
	wp7_bound_name = dst.name
	response_commit(&ctx.private.response, .OK, nil, transmute([]u8)string("bound"))
}

@(test)
wp7_binds_through_dispatch_and_runs_handler_once :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	post(&a, "/users", wp7_bind_handler)

	ctx: Context
	defer request_arena_destroy(&ctx)
	ctx.request.method = .POST
	ctx.request.path = "/users"
	ctx.request.body = transmute([]u8)string(`{"name":"through-dispatch"}`)

	before := wp7_bind_hits
	dispatch(&a, &ctx)

	testing.expect_value(t, wp7_bind_hits - before, 1)
	testing.expect_value(t, wp7_bound_name, "through-dispatch")
	testing.expect_value(t, string(ctx.private.response.body), "bound")
}
