// WP6 public-surface contract, from OUTSIDE the package.
//
// This package is an EXTERNAL consumer of `druse:web`. Everything below is
// driven end-to-end through `web.test_request`, which is the only way an
// application can observe a response at all in Phase 1 — there is no server yet.
//
// WP6 ADDS NO PUBLIC SYMBOL. Every test here is written with the same 34
// symbols that existed before it (32 application + 2 test-support). A response
// work package that needed a new export — a cleanup call, a header setter, a
// content-type argument — would have failed its own gate.
//
// What is deliberately NOT here: the exact `Content-Type`, because
// `Recorded_Response` has no public `headers` field and Phase 1 ratifies no
// header accessor; and body OWNERSHIP, because an application cannot see it.
// Both are pinned by the internal tests.
package wp6_public_surface

import "core:encoding/json"
import "core:log"
import "core:math"
import "core:strings"
import "core:testing"
import web "druse:web"

// Wp6_Log_Filter drops the framework's own Error-level diagnostics (they begin
// with "druse:") and forwards everything else. `odin test` counts any Error
// record as a failure, so a test that deliberately drives a path the framework
// logs on installs this to keep the runner honest without hiding real failures.
// It is declared on the caller's stack, so it allocates nothing.
Wp6_Log_Filter :: struct {
	inner: log.Logger,
}

wp6_filter_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	filter := (^Wp6_Log_Filter)(data)
	if level == .Error && strings.contains(text, "druse:") {
		return
	}
	if filter.inner.procedure != nil {
		filter.inner.procedure(filter.inner.data, level, text, options, location)
	}
}

wp6_swallow_framework_log :: proc(filter: ^Wp6_Log_Filter) -> log.Logger {
	filter.inner = context.logger
	return log.Logger {
		procedure = wp6_filter_proc,
		data = rawptr(filter),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

User :: struct {
	id:   int    `json:"id"`,
	name: string `json:"name"`,
}

// ---------------------------------------------------------------------------
// Envelope oracle — the official parser in STRICT `.JSON` mode.
// ---------------------------------------------------------------------------

expect_envelope :: proc(
	t: ^testing.T,
	body: string,
	code: string,
	message: string,
	loc := #caller_location,
) {
	value, err := json.parse_string(body, json.Specification.JSON, false, context.allocator)
	if !testing.expect_value(t, err, json.Error.None, loc = loc) {
		return
	}
	defer json.destroy_value(value, context.allocator)

	root := value.(json.Object) or_else nil
	if !testing.expect(t, root != nil, "envelope root must be an object", loc = loc) {
		return
	}
	inner := root["error"].(json.Object) or_else nil
	if !testing.expect(t, inner != nil, "'error' must be an object", loc = loc) {
		return
	}

	testing.expect_value(t, string(inner["code"].(json.String) or_else ""), code, loc = loc)
	testing.expect_value(t, string(inner["message"].(json.String) or_else ""), message, loc = loc)

	// `field` is omitted for every general error (AMEND-2).
	_, has_field := inner["field"]
	testing.expect(t, !has_field, "a general error carries no 'field'", loc = loc)
}

// ---------------------------------------------------------------------------
// Handlers. Each belongs to exactly one test: the pinned runner executes tests
// in parallel, so a handler shared between two of them would race.
// ---------------------------------------------------------------------------

ok_handler :: proc(ctx: ^web.Context) {
	web.ok(ctx, User{id = 42, name = "ada"})
}

created_handler :: proc(ctx: ^web.Context) {
	web.created(ctx, User{id = 7, name = "grace"})
}

json_status_handler :: proc(ctx: ^web.Context) {
	web.json(ctx, .Accepted, User{id = 1, name = "queued"})
}

text_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

no_content_handler :: proc(ctx: ^web.Context) {
	web.no_content(ctx)
}

bad_request_handler :: proc(ctx: ^web.Context) {
	web.bad_request(ctx, "invalid input")
}

unauthorized_handler :: proc(ctx: ^web.Context) {
	web.unauthorized(ctx, "authentication required")
}

forbidden_handler :: proc(ctx: ^web.Context) {
	web.forbidden(ctx, "insufficient permission")
}

not_found_handler :: proc(ctx: ^web.Context) {
	web.not_found(ctx, "user")
}

internal_error_handler :: proc(ctx: ^web.Context) {
	web.internal_error(ctx)
}

double_responder_handler :: proc(ctx: ^web.Context) {
	// A handler that answers twice. The FIRST response must win, and the second
	// must be a complete no-op (G-04 / ADR-008).
	web.ok(ctx, User{id = 1, name = "first"})
	web.bad_request(ctx, "second")
	web.text(ctx, .Internal_Server_Error, "third")
	web.no_content(ctx)
}

pointer_payload_handler :: proc(ctx: ^web.Context) {
	// ADR-003 / R-13: Phase 1 is value-only and the pinned marshaller rejects
	// pointer payloads. The application sees ONE complete 500, never a partial
	// body and never a silent success.
	user := User{id = 1, name = "unmarshalable"}
	web.ok(ctx, &user)
}

// ---------------------------------------------------------------------------
// 1. JSON responses
// ---------------------------------------------------------------------------

@(test)
wp6_ok_returns_200_with_a_json_body :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/users", ok_handler)

	res := web.test_request(&a, .GET, "/users")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, `{"id":42,"name":"ada"}`)
}

@(test)
wp6_created_returns_201 :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/users", created_handler)

	res := web.test_request(&a, .POST, "/users")

	testing.expect_value(t, res.status, web.Status.Created)
	testing.expect_value(t, res.body, `{"id":7,"name":"grace"}`)
}

@(test)
wp6_json_carries_an_arbitrary_status :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/jobs", json_status_handler)

	res := web.test_request(&a, .POST, "/jobs")

	testing.expect_value(t, res.status, web.Status.Accepted)
	testing.expect_value(t, res.body, `{"id":1,"name":"queued"}`)
}

@(test)
wp6_text_returns_a_plain_body :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/ping", text_handler)

	res := web.test_request(&a, .GET, "/ping")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "pong")
}

@(test)
wp6_no_content_returns_204_and_an_empty_body :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.delete(&a, "/users/1", no_content_handler)

	res := web.test_request(&a, .DELETE, "/users/1")

	testing.expect_value(t, res.status, web.Status.No_Content)
	testing.expect_value(t, res.body, "")
}

// ---------------------------------------------------------------------------
// 2. Error helpers
// ---------------------------------------------------------------------------

@(test)
wp6_error_helpers_are_observable_end_to_end :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)

	web.get(&a, "/bad", bad_request_handler)
	web.get(&a, "/unauth", unauthorized_handler)
	web.get(&a, "/forbidden", forbidden_handler)
	web.get(&a, "/missing", not_found_handler)
	web.get(&a, "/boom", internal_error_handler)

	bad := web.test_request(&a, .GET, "/bad")
	testing.expect_value(t, bad.status, web.Status.Bad_Request)
	expect_envelope(t, bad.body, "bad_request", "invalid input")

	unauth := web.test_request(&a, .GET, "/unauth")
	testing.expect_value(t, unauth.status, web.Status.Unauthorized)
	expect_envelope(t, unauth.body, "unauthorized", "authentication required")

	forbidden := web.test_request(&a, .GET, "/forbidden")
	testing.expect_value(t, forbidden.status, web.Status.Forbidden)
	expect_envelope(t, forbidden.body, "forbidden", "insufficient permission")

	missing := web.test_request(&a, .GET, "/missing")
	testing.expect_value(t, missing.status, web.Status.Not_Found)
	expect_envelope(t, missing.body, "not_found", "Resource 'user' not found")

	boom := web.test_request(&a, .GET, "/boom")
	testing.expect_value(t, boom.status, web.Status.Internal_Server_Error)
	expect_envelope(t, boom.body, "internal_error", "Internal server error")
}

// ---------------------------------------------------------------------------
// 3. Automatic 404 / 405 now carry envelopes
// ---------------------------------------------------------------------------

@(test)
wp6_automatic_404_carries_an_envelope :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/known", ok_handler)

	res := web.test_request(&a, .GET, "/absent")

	testing.expect_value(t, res.status, web.Status.Not_Found)
	expect_envelope(t, res.body, "not_found", "Route not found")
}

@(test)
wp6_automatic_405_carries_an_envelope :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/users", ok_handler)

	res := web.test_request(&a, .POST, "/users")

	testing.expect_value(t, res.status, web.Status.Method_Not_Allowed)
	expect_envelope(t, res.body, "method_not_allowed", "Method not allowed")
}

@(test)
wp6_bare_installs_no_route_policy_and_the_driver_finalizes_the_miss :: proc(t: ^testing.T) {
	a := web.bare()
	defer web.destroy(&a)
	web.get(&a, "/known", ok_handler)

	// bare() commits nothing for an unmatched route at the CORE — no automatic
	// 404/405. HTTP cannot send a zero status, so the DRIVER finalizes the miss
	// to a 500 (WP8 D5); its diagnostic is swallowed so the runner does not count
	// it as a failure. The property under test is that bare() adds no route
	// policy — which is exactly why the miss reaches the driver at all.
	filter: Wp6_Log_Filter
	context.logger = wp6_swallow_framework_log(&filter)

	res := web.test_request(&a, .GET, "/absent")

	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
	expect_envelope(t, res.body, "internal_error", "Internal server error")
}

// ---------------------------------------------------------------------------
// 4. Single commit, observed from outside
// ---------------------------------------------------------------------------

@(test)
wp6_the_first_response_wins :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/twice", double_responder_handler)

	res := web.test_request(&a, .GET, "/twice")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, `{"id":1,"name":"first"}`)
}

// ---------------------------------------------------------------------------
// 5. Marshal failure is one complete 500
// ---------------------------------------------------------------------------

// EXPECTED_LOG_MARKER is a substring of the framework's marshal diagnostic.
//
// The framework logs the rejected payload at Error level, on purpose — that is
// the ADR-003 contract. But `odin test` counts every Error-level record as a
// failed assertion, so a test that successfully provokes the diagnostic would
// be reported as failing. The logger below swallows exactly that record and
// forwards everything else, which keeps real assertion failures visible.
EXPECTED_LOG_MARKER :: "could not be serialized"

Expected_Log :: struct {
	seen:  int,
	inner: log.Logger,
}

expected_log_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Expected_Log)(data)
	if level == .Error && strings.contains(text, EXPECTED_LOG_MARKER) {
		record.seen += 1
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

@(test)
wp6_unmarshalable_payload_yields_a_complete_500 :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/broken", pointer_payload_handler)

	expected := Expected_Log {
		inner = context.logger,
	}
	context.logger = log.Logger {
		procedure    = expected_log_proc,
		data         = rawptr(&expected),
		lowest_level = .Debug,
		options      = context.logger.options,
	}

	res := web.test_request(&a, .GET, "/broken")

	// The failure really was reported on the server, exactly once.
	testing.expect_value(t, expected.seen, 1)

	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
	expect_envelope(t, res.body, "internal_error", "Internal server error")

	// Not one byte of the rejected payload may reach the client.
	testing.expect(
		t,
		!strings.contains(res.body, "unmarshalable"),
		"no partial payload may escape into the error response",
	)
}

Measurement :: struct {
	label: string `json:"label"`,
	value: f64    `json:"value"`,
}

non_finite_payload_handler :: proc(ctx: ^web.Context) {
	// NUM-001: the pinned marshaller writes a non-finite float as a bare
	// `+Inf` token, which is not valid JSON. `web.json` must not put it on the
	// wire; it takes the same complete-500 path as any other unencodable value.
	web.ok(ctx, Measurement{label = "temperature", value = math.inf_f64(1)})
}

@(test)
wp6_num001_non_finite_float_yields_a_complete_500 :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/reading", non_finite_payload_handler)

	// Capture the expected framework error, exactly as the marshal-failure test
	// does, so the runner does not count the reported 500 as an unexpected log.
	expected := Expected_Log {
		inner = context.logger,
	}
	context.logger = log.Logger {
		procedure    = expected_log_proc,
		data         = rawptr(&expected),
		lowest_level = .Debug,
		options      = context.logger.options,
	}

	res := web.test_request(&a, .GET, "/reading")

	testing.expect_value(t, expected.seen, 1)

	// A non-finite float is a broken response, answered by a clean 500 —
	// never invalid JSON on the wire.
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
	expect_envelope(t, res.body, "internal_error", "Internal server error")

	// The invalid tokens must never reach the client, and the response body
	// must itself be valid JSON.
	testing.expect(
		t,
		!strings.contains(res.body, "Inf") && !strings.contains(res.body, "NaN"),
		"a non-finite float token must never escape onto the wire",
	)
	testing.expect(
		t,
		json.is_valid(transmute([]u8)res.body, .JSON),
		"the error response body must itself be valid JSON",
	)
}

// ---------------------------------------------------------------------------
// 6. Recorded bodies stay valid across later requests
//
//    This is the public face of the WP6 ownership contract: `test_request`
//    releases the response's own render buffer after the recorder copies it, so
//    a body handed back earlier must be unaffected by everything that follows.
// ---------------------------------------------------------------------------

@(test)
wp6_earlier_bodies_survive_later_requests :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)

	web.get(&a, "/users", ok_handler)
	web.post(&a, "/users", created_handler)
	web.get(&a, "/ping", text_handler)
	web.get(&a, "/bad", bad_request_handler)

	first := web.test_request(&a, .GET, "/users")
	second := web.test_request(&a, .POST, "/users")
	third := web.test_request(&a, .GET, "/ping")
	fourth := web.test_request(&a, .GET, "/bad")
	fifth := web.test_request(&a, .GET, "/absent")

	// Every earlier body is still exactly what it was, after four more requests
	// rendered, committed and tore down their own buffers.
	testing.expect_value(t, first.body, `{"id":42,"name":"ada"}`)
	testing.expect_value(t, first.status, web.Status.OK)
	testing.expect_value(t, second.body, `{"id":7,"name":"grace"}`)
	testing.expect_value(t, third.body, "pong")
	expect_envelope(t, fourth.body, "bad_request", "invalid input")
	expect_envelope(t, fifth.body, "not_found", "Route not found")
}

// ---------------------------------------------------------------------------
// 7. WP5 extraction still works, and WP7 has not started
// ---------------------------------------------------------------------------

extractor_handler :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}
	web.ok(ctx, User{id = id, name = "found"})
}

@(test)
wp6_extraction_still_works_and_its_errors_still_win :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/users/:id", extractor_handler)

	good := web.test_request(&a, .GET, "/users/42")
	testing.expect_value(t, good.status, web.Status.OK)
	testing.expect_value(t, good.body, `{"id":42,"name":"found"}`)

	// The WP5 envelope is unchanged, including its `field`.
	bad := web.test_request(&a, .GET, "/users/banana")
	testing.expect_value(t, bad.status, web.Status.Bad_Request)

	value, err := json.parse_string(bad.body, json.Specification.JSON, false, context.allocator)
	testing.expect_value(t, err, json.Error.None)
	defer json.destroy_value(value, context.allocator)

	root := value.(json.Object) or_else nil
	inner := root["error"].(json.Object) or_else nil
	testing.expect(t, inner != nil)
	testing.expect_value(
		t,
		string(inner["code"].(json.String) or_else ""),
		"invalid_path_parameter",
	)
	testing.expect_value(t, string(inner["field"].(json.String) or_else ""), "id")
}

body_binding_handler :: proc(ctx: ^web.Context) {
	dst: User
	if !web.body(ctx, &dst) {
		return
	}
	// Unreachable via test_request, which supplies no body.
	web.ok(ctx, dst)
}

@(test)
wp6_body_binding_failure_wins_over_the_responders :: proc(t: ^testing.T) {
	// SUPERSEDES `wp6_body_binding_is_still_a_wp7_stub`. WP7 shipped body
	// binding, so asserting the stub would assert the absence of a delivered
	// feature. What holds is that a failing bind — the empty body test_request
	// supplies — commits its own 400, and the WP6 responders still honor the
	// single-commit guard.
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/bind", body_binding_handler)

	res := web.test_request(&a, .POST, "/bind")

	testing.expect_value(t, res.status, web.Status.Bad_Request)
	expect_envelope(t, res.body, "invalid_json", "Request body must be valid JSON")
}
