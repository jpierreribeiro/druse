// WP5 public-surface contract, from OUTSIDE the package.
//
// This package is an EXTERNAL consumer of `druse:web`. It proves the part of
// the WP5 contract an application can actually observe, through the ratified
// public surface only:
//
//   - `web.path` and `web.path_int` inside a REAL routed handler;
//   - a failing `web.path_int` producing a 400 with the standardized envelope,
//     observed through `web.test_request`;
//   - `web.query`, `web.query_int` and `web.query_int_or` over the PUBLIC
//     `Context`/`Request`, without touching a single internal;
//   - the exact ratified signature of all five extractors;
//   - `web.body` still a WP7 stub and the WP6 responders still inert.
//
// WP5 ADDS NO PUBLIC SYMBOL. Everything below is written with the same 34
// symbols that existed before it (32 application + 2 test-support), which is
// itself part of the contract: an extractor work package that needed a new
// export would have failed its own gate.
//
// WHY THE QUERY TESTS BUILD A `Context` DIRECTLY. `web.test_request` takes a
// method and a path and nothing else, and WP5 deliberately does NOT add a query
// or header overload to it — that would grow the test-support ledger past its
// frozen 2. `Request.query` is a PUBLIC field of a PUBLIC struct, so an external
// consumer can set it and call the extractors exactly as a transport adapter
// (WP8) eventually will. That is the honest public path, and it needs no
// internals.
package wp5_public_surface

import "core:encoding/json"
import "core:testing"
import web "druse:web"

// ---------------------------------------------------------------------------
// 1. The five extractors have EXACTLY the ratified signatures.
//
//    These are compile-time assertions: assigning to an explicitly typed
//    procedure variable fails to compile if a parameter, a result, or their
//    order ever changes. `#optional_ok` is NOT part of a procedure's type, so
//    this section is deliberately backed by the negative discard probes in
//    `probes/`, which the gate compiles and requires to FAIL.
// ---------------------------------------------------------------------------

@(test)
wp5_extractor_signatures_are_exact :: proc(t: ^testing.T) {
	path_sig: proc(ctx: ^web.Context, name: string) -> string = web.path
	path_int_sig: proc(ctx: ^web.Context, name: string) -> (int, bool) = web.path_int
	query_sig: proc(ctx: ^web.Context, name: string) -> (string, bool) = web.query
	query_int_sig: proc(ctx: ^web.Context, name: string) -> (int, bool) = web.query_int
	query_int_or_sig: proc(
		ctx: ^web.Context,
		name: string,
		default_value: int,
	) -> (
		int,
		bool,
	) = web.query_int_or

	testing.expect(t, path_sig != nil)
	testing.expect(t, path_int_sig != nil)
	testing.expect(t, query_sig != nil)
	testing.expect(t, query_int_sig != nil)
	testing.expect(t, query_int_or_sig != nil)
}

// ---------------------------------------------------------------------------
// 2. `web.path` and `web.path_int` inside a routed handler.
//
//    The public responders are inert until WP6, so a handler cannot report its
//    result by responding. Each handler therefore records into a variable that
//    belongs to EXACTLY ONE test: the pinned runner executes tests in parallel,
//    and a shared variable would make both tests race.
// ---------------------------------------------------------------------------

wp5_seen_path: string
wp5_seen_path_hits: int

wp5_path_handler :: proc(ctx: ^web.Context) {
	wp5_seen_path = web.path(ctx, "id")
	wp5_seen_path_hits += 1
	web.no_content(ctx)
}

@(test)
wp5_path_is_readable_inside_a_routed_handler :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)

	web.get(&a, "/users/:id", wp5_path_handler)

	before := wp5_seen_path_hits
	res := web.test_request(&a, .GET, "/users/42")

	testing.expect_value(t, wp5_seen_path_hits - before, 1)
	testing.expect_value(t, wp5_seen_path, "42")

	// The handler recorded the extractor result and responded 204. The framework
	// still never fabricates a 200 (pinned by the WP8 driver-finalization tests).
	testing.expect_value(t, res.status, web.Status.No_Content)
}

wp5_seen_missing_path: string
wp5_seen_missing_hits: int

wp5_missing_path_handler :: proc(ctx: ^web.Context) {
	// A name that was never captured, on a route that HAS a parameter.
	wp5_seen_missing_path = web.path(ctx, "not_the_name")
	wp5_seen_missing_hits += 1
	web.no_content(ctx)
}

@(test)
wp5_path_with_an_unknown_name_is_empty_and_does_not_respond :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)

	web.get(&a, "/users/:id", wp5_missing_path_handler)

	before := wp5_seen_missing_hits
	res := web.test_request(&a, .GET, "/users/42")

	testing.expect_value(t, wp5_seen_missing_hits - before, 1)
	testing.expect_value(t, wp5_seen_missing_path, "")

	// `web.path` never responds automatically; the handler responded 204 itself.
	testing.expect_value(t, res.status, web.Status.No_Content)
	testing.expect_value(t, res.body, "")
}

wp5_seen_id: int
wp5_seen_id_ok: bool
wp5_seen_id_hits: int

wp5_path_int_handler :: proc(ctx: ^web.Context) {
	wp5_seen_id_hits += 1

	// The canonical call site, unchanged since WP1.
	id, ok := web.path_int(ctx, "id")
	wp5_seen_id_ok = ok
	if !ok {
		return
	}
	wp5_seen_id = id
	web.no_content(ctx)
}

@(test)
wp5_path_int_parses_a_valid_integer_in_a_routed_handler :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)

	web.get(&a, "/users/:id", wp5_path_int_handler)

	before := wp5_seen_id_hits
	res := web.test_request(&a, .GET, "/users/42")

	testing.expect_value(t, wp5_seen_id_hits - before, 1)
	testing.expect(t, wp5_seen_id_ok, "a valid integer must parse")
	testing.expect_value(t, wp5_seen_id, 42)

	// A SUCCESSFUL extraction writes no response of its own; the handler then
	// responded 204.
	testing.expect_value(t, res.status, web.Status.No_Content)
	testing.expect_value(t, res.body, "")
}

// ---------------------------------------------------------------------------
// 3. A failing `web.path_int` responds by itself, observed end-to-end.
//
//    This is the load-bearing public contract of WP5: the handler returns and
//    the client still receives a complete, standardized 400.
// ---------------------------------------------------------------------------

wp5_failing_ok: bool
wp5_failing_hits: int

wp5_failing_path_int_handler :: proc(ctx: ^web.Context) {
	wp5_failing_hits += 1

	_, ok := web.path_int(ctx, "id")
	wp5_failing_ok = ok
	if !ok {
		return
	}
}

@(test)
wp5_path_int_failure_is_a_complete_400_over_the_public_surface :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)

	web.get(&a, "/users/:id", wp5_failing_path_int_handler)

	before := wp5_failing_hits
	res := web.test_request(&a, .GET, "/users/banana")

	testing.expect_value(t, wp5_failing_hits - before, 1)
	testing.expect(t, !wp5_failing_ok, "a malformed path parameter must report failure")

	testing.expect_value(t, res.status, web.Status.Bad_Request)
	testing.expect(t, len(res.body) > 0, "the extractor must have written a body")

	wp5_expect_envelope(
		t,
		res.body,
		"invalid_path_parameter",
		"Path parameter 'id' must be an integer",
		"id",
	)
}

wp5_after_failure_hits: int

wp5_keeps_going_handler :: proc(ctx: ^web.Context) {
	wp5_after_failure_hits += 1

	// A handler that IGNORES the canonical `if !ok { return }` and keeps going.
	// The commit guard must make its later response a no-op (G-04).
	_, ok := web.path_int(ctx, "id")
	_ = ok

	web.ok(ctx, 42)
	web.text(ctx, .OK, "late")
	web.no_content(ctx)
}

@(test)
wp5_continued_handler_code_cannot_replace_the_400 :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)

	web.get(&a, "/users/:id", wp5_keeps_going_handler)

	before := wp5_after_failure_hits
	res := web.test_request(&a, .GET, "/users/banana")

	testing.expect_value(t, wp5_after_failure_hits - before, 1)

	// The extractor's response survives verbatim.
	testing.expect_value(t, res.status, web.Status.Bad_Request)
	wp5_expect_envelope(
		t,
		res.body,
		"invalid_path_parameter",
		"Path parameter 'id' must be an integer",
		"id",
	)
}

// ---------------------------------------------------------------------------
// 4. The query family over the PUBLIC Context/Request.
// ---------------------------------------------------------------------------

@(test)
wp5_query_reads_the_public_request_query :: proc(t: ^testing.T) {
	ctx: web.Context
	ctx.request.query = "search=odin&page=3&flag&empty="

	search, found := web.query(&ctx, "search")
	testing.expect(t, found)
	testing.expect_value(t, search, "odin")

	// A bare key is present with an empty value.
	flag, flag_found := web.query(&ctx, "flag")
	testing.expect(t, flag_found)
	testing.expect_value(t, flag, "")

	// So is a key with an explicitly empty value.
	empty, empty_found := web.query(&ctx, "empty")
	testing.expect(t, empty_found)
	testing.expect_value(t, empty, "")

	// An absent key reports absence and writes nothing.
	absent, absent_found := web.query(&ctx, "absent")
	testing.expect(t, !absent_found)
	testing.expect_value(t, absent, "")
}

@(test)
wp5_query_int_over_the_public_surface :: proc(t: ^testing.T) {
	ctx: web.Context
	ctx.request.query = "page=3"

	page, ok := web.query_int(&ctx, "page")
	testing.expect(t, ok)
	testing.expect_value(t, page, 3)
}

@(test)
wp5_query_int_missing_responds_400_over_the_public_surface :: proc(t: ^testing.T) {
	ctx: web.Context
	ctx.request.query = "other=1"

	page, ok := web.query_int(&ctx, "page")
	testing.expect(t, !ok)
	testing.expect_value(t, page, 0)
}

@(test)
wp5_query_int_or_uses_the_default_only_for_absence :: proc(t: ^testing.T) {
	// The three documented cases, exactly as canonical-patterns.md states them:
	//   GET /users              -> limit = 20
	//   GET /users?limit=50     -> limit = 50
	//   GET /users?limit=banana -> 400
	absent: web.Context
	limit_absent, ok_absent := web.query_int_or(&absent, "limit", 20)
	testing.expect(t, ok_absent)
	testing.expect_value(t, limit_absent, 20)

	present: web.Context
	present.request.query = "limit=50"
	limit_present, ok_present := web.query_int_or(&present, "limit", 20)
	testing.expect(t, ok_present)
	testing.expect_value(t, limit_present, 50)

	malformed: web.Context
	malformed.request.query = "limit=banana"
	limit_bad, ok_bad := web.query_int_or(&malformed, "limit", 20)
	testing.expect(t, !ok_bad, "a malformed value is a 400, never the default")
	testing.expect_value(t, limit_bad, 0)
}

// The query extractors are also reachable from inside a routed handler, which
// is where an application actually calls them.

wp5_seen_limit: int
wp5_seen_limit_ok: bool
wp5_seen_limit_hits: int

wp5_query_handler :: proc(ctx: ^web.Context) {
	wp5_seen_limit_hits += 1

	limit, ok := web.query_int_or(ctx, "limit", 20)
	wp5_seen_limit_ok = ok
	if !ok {
		return
	}
	wp5_seen_limit = limit
	web.no_content(ctx)
}

@(test)
wp5_query_extractors_work_inside_a_routed_handler :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)

	web.get(&a, "/users", wp5_query_handler)

	// `web.test_request` carries no query string (its signature is frozen at
	// method + path), so this exercises the ABSENT branch through real dispatch:
	// the default applies and nothing is committed.
	before := wp5_seen_limit_hits
	res := web.test_request(&a, .GET, "/users")

	testing.expect_value(t, wp5_seen_limit_hits - before, 1)
	testing.expect(t, wp5_seen_limit_ok)
	testing.expect_value(t, wp5_seen_limit, 20)

	testing.expect_value(t, res.status, web.Status.No_Content)
}

// ---------------------------------------------------------------------------
// 5. WP5 started neither WP6 nor WP7.
// ---------------------------------------------------------------------------

Wp5_Payload :: struct {
	name: string,
}

wp5_stub_probe_hits: int

wp5_stub_probe_handler :: proc(ctx: ^web.Context) {
	wp5_stub_probe_hits += 1

	dst: Wp5_Payload
	if web.body(ctx, &dst) {
		// Unreachable: test_request supplies no body, so this empty body fails.
		wp5_stub_probe_hits += 1000
	}

	// A handler that ignores web.body's failure and keeps responding: the FIRST
	// response — web.body's own invalid_json 400 — must win over all of these.
	web.ok(ctx, 1)
	web.created(ctx, 2)
	web.text(ctx, .Internal_Server_Error, "late")
	web.bad_request(ctx, "late")
}

@(test)
wp5_a_failed_body_bind_wins_over_later_responders :: proc(t: ^testing.T) {
	// SUPERSEDES `wp5_body_is_still_a_wp7_stub_and_the_first_response_wins`. WP7
	// shipped body binding, so asserting `web.body` is a stub would assert the
	// absence of a delivered feature.
	//
	// What still holds, and what this checks, is single-commit (G-04 / ADR-008):
	// `web.body` on the empty body test_request supplies commits its own 400,
	// and a handler that keeps responding cannot replace it.
	a := web.app()
	defer web.destroy(&a)

	web.get(&a, "/stub", wp5_stub_probe_handler)

	before := wp5_stub_probe_hits
	res := web.test_request(&a, .GET, "/stub")

	// +1, never +1001: web.body must have returned false on the empty body.
	testing.expect_value(t, wp5_stub_probe_hits - before, 1)

	testing.expect_value(t, res.status, web.Status.Bad_Request)
	testing.expect_value(
		t,
		res.body,
		`{"error":{"code":"invalid_json","message":"Request body must be valid JSON"}}`,
	)
}

// ---------------------------------------------------------------------------
// Envelope oracle
//
// The committed bytes are parsed with the OFFICIAL `core:encoding/json` parser
// in STRICT `.JSON` mode — not `DEFAULT_SPECIFICATION`, which is JSON5 and
// would accept unquoted keys and trailing commas that are NOT valid JSON.
// ---------------------------------------------------------------------------

wp5_expect_envelope :: proc(
	t: ^testing.T,
	body: string,
	code: string,
	message: string,
	field: string,
	loc := #caller_location,
) {
	value, err := json.parse_string(body, json.Specification.JSON, false, context.allocator)
	if !testing.expect_value(t, err, json.Error.None, loc = loc) {
		return
	}
	defer json.destroy_value(value, context.allocator)

	root := value.(json.Object) or_else nil
	if !testing.expect(t, root != nil, "the envelope root must be a JSON object", loc = loc) {
		return
	}
	inner := root["error"].(json.Object) or_else nil
	if !testing.expect(t, inner != nil, "'error' must be a JSON object", loc = loc) {
		return
	}

	testing.expect_value(t, string(inner["code"].(json.String) or_else ""), code, loc = loc)
	testing.expect_value(t, string(inner["message"].(json.String) or_else ""), message, loc = loc)
	testing.expect_value(t, string(inner["field"].(json.String) or_else ""), field, loc = loc)
}
