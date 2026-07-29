// WP6 internal behavior tests — response rendering, body ownership, the error
// envelope, and the marshal-failure path.
//
// This file declares `package web` but does NOT live in `web/`, and it must
// never be moved there. The declarations it covers — `Response`,
// `response_commit`, `response_commit_owned`, `response_destroy`, the envelope
// machinery and the typed framework-error report — are all package-private, and
// on the pinned toolchain an `@(test)` procedure must be compiled as part of
// the package it tests. Compiling it inside the shipped package would link
// `core:testing` into every application binary (+41,592 bytes measured on
// 819fdc7). `build/check.sh` therefore assembles a THROWAWAY package from the
// real `web/` sources plus this file, exactly as it already does for WP2-WP5.
//
// WHY THESE TESTS ARE INTERNAL. Four WP6 contracts cannot be observed from
// outside the package:
//
//   - WHO OWNS a rendered body and whether the teardown released it exactly
//     once — `Recorded_Response` deliberately exposes only status and body;
//   - the exact `Content-Type`, because Phase 1 ratifies no header accessor;
//   - that a rejected commit FREES the body it could not transfer, which is
//     visible only to a tracking allocator;
//   - that the marshal failure is LOGGED BEFORE the 500 is committed, which is
//     an ordering property observable only from inside.
//
// THE LOG-ORDERING ORACLE. `wp6_recording_logger` installs a logger whose
// procedure records, at the moment it is called, whether the response was
// already committed. That turns "logged before commit" from a claim about
// source order into an executed assertion.
//
// `#+private` is kept as a defensive default: if this file were ever copied
// back into the package, its declarations still would not be exported.
#+private
package web

import json_oracle "core:encoding/json"
import "core:log"
import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

// Payloads. Declared at file scope so every test marshals the same shapes.

@(private = "file")
Wp6_User :: struct {
	id:   int    `json:"id"`,
	name: string `json:"name"`,
}

@(private = "file")
Wp6_Nested :: struct {
	user:  Wp6_User `json:"user"`,
	tags:  []string `json:"tags"`,
	scores: []int   `json:"scores"`,
}

// wp6_expect_json parses a committed body with the OFFICIAL parser in STRICT
// `.JSON` mode — not `DEFAULT_SPECIFICATION`, which is JSON5 and would accept
// unquoted keys and trailing commas that are NOT valid JSON.
@(private = "file")
wp6_expect_json :: proc(
	t: ^testing.T,
	body: []u8,
	loc := #caller_location,
) -> (
	root: json_oracle.Value,
	ok: bool,
) {
	value, err := json_oracle.parse(body, json_oracle.Specification.JSON, false, context.allocator)
	if !testing.expect_value(t, err, json_oracle.Error.None, loc = loc) {
		return nil, false
	}
	return value, true
}

// wp6_expect_envelope asserts the standardized envelope. `expect_field` of ""
// means the member must be ABSENT ENTIRELY — not null, not empty string.
@(private = "file")
wp6_expect_envelope :: proc(
	t: ^testing.T,
	body: []u8,
	code: string,
	message: string,
	expect_field: string,
	field_present: bool,
	loc := #caller_location,
) {
	value, parsed := wp6_expect_json(t, body, loc)
	if !parsed {
		return
	}
	defer json_oracle.destroy_value(value, context.allocator)

	root := value.(json_oracle.Object) or_else nil
	if !testing.expect(t, root != nil, "the envelope root must be a JSON object", loc = loc) {
		return
	}
	inner := root["error"].(json_oracle.Object) or_else nil
	if !testing.expect(t, inner != nil, "'error' must be a JSON object", loc = loc) {
		return
	}

	testing.expect_value(t, string(inner["code"].(json_oracle.String) or_else ""), code, loc = loc)
	testing.expect_value(
		t,
		string(inner["message"].(json_oracle.String) or_else ""),
		message,
		loc = loc,
	)

	_, has_field := inner["field"]
	testing.expect(
		t,
		has_field == field_present,
		"'field' presence does not match the contract",
		loc = loc,
	)
	if field_present {
		testing.expect_value(
			t,
			string(inner["field"].(json_oracle.String) or_else ""),
			expect_field,
			loc = loc,
		)
	}
}

// wp6_header finds a response header by exact name.
@(private = "file")
wp6_header :: proc(res: ^Response, name: string) -> (value: string, found: bool) {
	for pair in res.headers {
		if pair.name == name {
			return pair.value, true
		}
	}
	return "", false
}

@(private = "file")
wp6_expect_content_type :: proc(
	t: ^testing.T,
	res: ^Response,
	expected: string,
	loc := #caller_location,
) {
	value, found := wp6_header(res, "Content-Type")
	if !testing.expect(t, found, "the response must carry a Content-Type", loc = loc) {
		return
	}
	testing.expect_value(t, value, expected, loc = loc)
}

@(private = "file")
wp6_noop_handler :: proc(ctx: ^Context) {
}

// ---------------------------------------------------------------------------
// The log-ordering oracle.
//
// The recorded flag is captured INSIDE the logger procedure, so it reflects the
// state of the response at the instant the framework logged — which is the only
// way to prove ordering rather than assert it.
// ---------------------------------------------------------------------------

// WP6_LOG_MARKER is a substring of the framework's marshal-failure message. It
// is what separates the framework's own log records from the test runner's.
@(private = "file")
WP6_LOG_MARKER :: "could not be serialized"

@(private = "file")
Wp6_Log_Record :: struct {
	framework_calls:  int,
	last_level:       log.Level,
	committed_at_log: bool,
	response:         ^Response,

	// The runner's logger, CHAINED rather than replaced. This is load-bearing:
	// `testing.expect*` reports a failed assertion by logging it at Error level
	// through `context.logger`, and the runner counts failures by observing
	// those records. A logger that swallowed them would make every test in this
	// file incapable of failing — it would report PASS no matter what the code
	// did. Every record is therefore forwarded before anything is recorded.
	inner:            log.Logger,
}

@(private = "file")
wp6_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Wp6_Log_Record)(data)

	// The framework's own marshal diagnostic is the EVENT UNDER TEST: it is
	// recorded and deliberately NOT forwarded. The runner treats any Error-level
	// record as a failed assertion, so forwarding an expected diagnostic would
	// fail every test that successfully provokes one.
	if level == .Error && strings.contains(text, WP6_LOG_MARKER) {
		record.framework_calls += 1
		record.last_level = level
		if record.response != nil {
			record.committed_at_log = record.response.committed
		}
		return
	}

	// Everything else is forwarded, and that is load-bearing: `testing.expect*`
	// reports a failed assertion by logging it at Error level through
	// `context.logger`, and the runner counts failures by observing those
	// records. Swallowing them would make every test in this file incapable of
	// failing — it would report PASS no matter what the code did.
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

// wp6_recording_logger wraps whatever logger is currently installed. It stores
// no text and allocates nothing, so it needs no teardown.
@(private = "file")
wp6_recording_logger :: proc(record: ^Wp6_Log_Record) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = wp6_logger_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

// ---------------------------------------------------------------------------
// 1-10. Rendering
// ---------------------------------------------------------------------------

@(test)
wp6_json_renders_a_struct_value :: proc(t: ^testing.T) {
	ctx: Context
	defer response_destroy(&ctx.private.response)

	json(&ctx, .OK, Wp6_User{id = 42, name = "ada"})

	testing.expect(t, ctx.private.response.committed)
	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), `{"id":42,"name":"ada"}`)
}

@(test)
wp6_json_renders_slices_and_nested_structs :: proc(t: ^testing.T) {
	ctx: Context
	defer response_destroy(&ctx.private.response)

	payload := Wp6_Nested {
		user   = Wp6_User{id = 7, name = "grace"},
		tags   = []string{"a", "b"},
		scores = []int{1, 2, 3},
	}
	json(&ctx, .OK, payload)

	value, parsed := wp6_expect_json(t, ctx.private.response.body)
	if !parsed {
		return
	}
	defer json_oracle.destroy_value(value, context.allocator)

	root := value.(json_oracle.Object) or_else nil
	testing.expect(t, root != nil)
	user := root["user"].(json_oracle.Object) or_else nil
	testing.expect(t, user != nil, "nested structs must round-trip")
	testing.expect_value(t, string(user["name"].(json_oracle.String) or_else ""), "grace")

	tags := root["tags"].(json_oracle.Array) or_else nil
	testing.expect_value(t, len(tags), 2)
	scores := root["scores"].(json_oracle.Array) or_else nil
	testing.expect_value(t, len(scores), 3)
}

@(test)
wp6_json_escapes_special_characters :: proc(t: ^testing.T) {
	ctx: Context
	defer response_destroy(&ctx.private.response)

	// Quotes, backslashes, a control character and multi-byte UTF-8. The
	// official encoder does the escaping; this proves the rendered bytes really
	// are valid JSON and round-trip to the original value.
	json(&ctx, .OK, Wp6_User{id = 1, name = "he said \"hi\"\\ok\nnewline é"})

	value, parsed := wp6_expect_json(t, ctx.private.response.body)
	if !parsed {
		return
	}
	defer json_oracle.destroy_value(value, context.allocator)

	root := value.(json_oracle.Object) or_else nil
	testing.expect(t, root != nil)
	testing.expect_value(
		t,
		string(root["name"].(json_oracle.String) or_else ""),
		"he said \"hi\"\\ok\nnewline é",
	)
}

@(test)
wp6_json_preserves_an_arbitrary_status :: proc(t: ^testing.T) {
	for status in ([]Status{.OK, .Created, .Accepted, .Bad_Request, .Internal_Server_Error}) {
		ctx: Context
		defer response_destroy(&ctx.private.response)

		json(&ctx, status, Wp6_User{id = 1, name = "x"})
		testing.expect_value(t, ctx.private.response.status, status)
	}
}

@(test)
wp6_json_sets_the_exact_content_type :: proc(t: ^testing.T) {
	ctx: Context
	defer response_destroy(&ctx.private.response)

	json(&ctx, .OK, Wp6_User{id = 1, name = "x"})

	wp6_expect_content_type(t, &ctx.private.response, "application/json")
	testing.expect_value(t, len(ctx.private.response.headers), 1)
}

@(test)
wp6_text_sets_the_exact_content_type :: proc(t: ^testing.T) {
	ctx: Context
	defer response_destroy(&ctx.private.response)

	text(&ctx, .OK, "pong")

	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), "pong")
	wp6_expect_content_type(t, &ctx.private.response, "text/plain; charset=utf-8")
}

@(test)
wp6_text_copies_the_caller_buffer :: proc(t: ^testing.T) {
	// `text` must OWN its body. Retaining the caller's view would dangle the
	// moment the caller reused its storage — the exact class of bug the
	// ownership rules exist to prevent (G-05).
	backing := make([]u8, len("pong"))
	defer delete_slice(backing)
	copy(backing, transmute([]u8)string("pong"))

	ctx: Context
	defer response_destroy(&ctx.private.response)

	text(&ctx, .OK, string(backing))
	slice.fill(backing, '#')

	testing.expect_value(
		t,
		string(ctx.private.response.body),
		"pong",
	)
}

@(test)
wp6_no_content_is_empty_and_header_free :: proc(t: ^testing.T) {
	ctx: Context
	defer response_destroy(&ctx.private.response)

	no_content(&ctx)

	testing.expect(t, ctx.private.response.committed)
	testing.expect_value(t, ctx.private.response.status, Status.No_Content)
	testing.expect_value(t, len(ctx.private.response.body), 0)

	// No Content-Type: there is no content to describe.
	testing.expect_value(t, len(ctx.private.response.headers), 0)
}

@(test)
wp6_no_content_allocates_nothing :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	ctx: Context
	defer response_destroy(&ctx.private.response)

	no_content(&ctx)

	testing.expect_value(t, len(track.allocation_map), 0)
}

@(test)
wp6_ok_is_byte_identical_to_json_ok :: proc(t: ^testing.T) {
	payload := Wp6_User{id = 42, name = "ada"}

	via_ok: Context
	defer response_destroy(&via_ok.private.response)
	ok(&via_ok, payload)

	via_json: Context
	defer response_destroy(&via_json.private.response)
	json(&via_json, .OK, payload)

	testing.expect_value(t, via_ok.private.response.status, via_json.private.response.status)
	testing.expect_value(
		t,
		string(via_ok.private.response.body),
		string(via_json.private.response.body),
	)
	testing.expect_value(t, len(via_ok.private.response.headers), len(via_json.private.response.headers))
}

@(test)
wp6_created_is_byte_identical_to_json_created :: proc(t: ^testing.T) {
	payload := Wp6_User{id = 42, name = "ada"}

	via_created: Context
	defer response_destroy(&via_created.private.response)
	created(&via_created, payload)

	via_json: Context
	defer response_destroy(&via_json.private.response)
	json(&via_json, .Created, payload)

	testing.expect_value(t, via_created.private.response.status, Status.Created)
	testing.expect_value(
		t,
		string(via_created.private.response.body),
		string(via_json.private.response.body),
	)
}

// ---------------------------------------------------------------------------
// 11-19. Ownership
// ---------------------------------------------------------------------------

@(private = "file")
wp6_render_handler :: proc(ctx: ^Context) {
	ok(ctx, Wp6_User{id = 5, name = "owned"})
}

@(test)
wp6_body_survives_the_handler_return :: proc(t: ^testing.T) {
	// The body is read AFTER dispatch returns. If it lived in the handler's
	// frame, or in scratch storage reset at return, this would read garbage.
	a := app()
	defer destroy(&a)
	get(&a, "/u", wp6_render_handler)

	ctx: Context
	defer response_destroy(&ctx.private.response)
	ctx.request.method = .GET
	ctx.request.path = "/u"
	dispatch(&a, &ctx)

	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), `{"id":5,"name":"owned"}`)
}

@(test)
wp6_response_owns_the_rendered_body :: proc(t: ^testing.T) {
	ctx: Context
	defer response_destroy(&ctx.private.response)

	json(&ctx, .OK, Wp6_User{id = 1, name = "x"})

	testing.expect(
		t,
		ctx.private.response.owned_body,
		"a rendered body must be owned, not borrowed",
	)
}

@(test)
wp6_teardown_releases_exactly_once :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	ctx: Context
	json(&ctx, .OK, Wp6_User{id = 1, name = "x"})
	testing.expect(t, len(track.allocation_map) > 0, "rendering must have allocated")

	response_destroy(&ctx.private.response)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
wp6_second_teardown_is_a_no_op :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	ctx: Context
	json(&ctx, .OK, Wp6_User{id = 1, name = "x"})

	response_destroy(&ctx.private.response)
	// A second teardown must not double free. `web.destroy` is specified as
	// call-once, but a teardown that corrupts the heap when called twice is a
	// worse failure than one that simply does nothing.
	response_destroy(&ctx.private.response)
	response_destroy(&ctx.private.response)

	testing.expect_value(t, len(track.bad_free_array), 0)
	testing.expect_value(t, len(track.allocation_map), 0)

	// It also returns the response to its zero state.
	testing.expect(t, !ctx.private.response.committed)
	testing.expect(t, !ctx.private.response.owned_body)
	testing.expect_value(t, len(ctx.private.response.body), 0)
}

@(test)
wp6_teardown_never_frees_a_borrowed_body :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	// A borrowed body: a static constant, exactly like the automatic 404.
	ctx: Context
	response_commit(&ctx.private.response, .OK, nil, transmute([]u8)string("borrowed"))
	testing.expect(t, !ctx.private.response.owned_body)

	response_destroy(&ctx.private.response)

	// Freeing a static string would be a bad free; the tracker would see it.
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
wp6_rejected_owned_commit_frees_the_body_it_could_not_transfer :: proc(t: ^testing.T) {
	// The ownership rule that is easiest to get wrong: if the guard refuses the
	// commit, the buffer that was already rendered has no owner. Dropping it
	// would leak on a path a handler can trigger by responding twice.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	ctx: Context
	defer response_destroy(&ctx.private.response)

	// First response: borrowed, so nothing is owned yet.
	response_commit(&ctx.private.response, .OK, nil, transmute([]u8)string("first"))
	before := len(track.allocation_map)

	// A second, owned commit must be rejected AND must not leak.
	rendered := make([]u8, 16)
	accepted := response_commit_owned(
		&ctx.private.response,
		.Bad_Request,
		nil,
		rendered,
		context.allocator,
	)
	testing.expect(t, !accepted, "the guard must reject the second commit")
	testing.expect_value(t, len(track.allocation_map), before)

	// And the first response is untouched.
	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), "first")
	testing.expect(t, !ctx.private.response.owned_body)
}

@(test)
wp6_responding_after_commit_neither_allocates_nor_modifies :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	ctx: Context
	defer response_destroy(&ctx.private.response)

	ok(&ctx, Wp6_User{id = 1, name = "first"})
	first_body := string(ctx.private.response.body)
	after_first := len(track.allocation_map)

	// Every later responder must return without rendering, allocating or
	// touching the committed response.
	json(&ctx, .Created, Wp6_User{id = 2, name = "second"})
	text(&ctx, .OK, "late")
	no_content(&ctx)
	bad_request(&ctx, "late")
	unauthorized(&ctx, "late")
	forbidden(&ctx, "late")
	not_found(&ctx, "late")
	internal_error(&ctx)

	testing.expect_value(t, len(track.allocation_map), after_first)
	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), first_body)
	wp6_expect_content_type(t, &ctx.private.response, "application/json")
}

@(test)
wp6_a_full_render_teardown_cycle_leaks_nothing :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	// Every responder that can allocate, each in its own response.
	{
		ctx: Context
		json(&ctx, .OK, Wp6_Nested{user = {1, "a"}, tags = {"x"}, scores = {1}})
		response_destroy(&ctx.private.response)
	}
	{
		ctx: Context
		text(&ctx, .OK, "some text")
		response_destroy(&ctx.private.response)
	}
	{
		ctx: Context
		bad_request(&ctx, "invalid input")
		response_destroy(&ctx.private.response)
	}
	{
		ctx: Context
		not_found(&ctx, "user")
		response_destroy(&ctx.private.response)
	}
	{
		ctx: Context
		internal_error(&ctx)
		response_destroy(&ctx.private.response)
	}

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

// ---------------------------------------------------------------------------
// 20-27. Error helpers and automatic errors
// ---------------------------------------------------------------------------

@(test)
wp6_error_helpers_produce_the_ratified_envelopes :: proc(t: ^testing.T) {
	{
		ctx: Context
		defer response_destroy(&ctx.private.response)
		bad_request(&ctx, "invalid input")
		testing.expect_value(t, ctx.private.response.status, Status.Bad_Request)
		wp6_expect_envelope(t, ctx.private.response.body, "bad_request", "invalid input", "", false)
		wp6_expect_content_type(t, &ctx.private.response, "application/json")
	}
	{
		ctx: Context
		defer response_destroy(&ctx.private.response)
		unauthorized(&ctx, "authentication required")
		testing.expect_value(t, ctx.private.response.status, Status.Unauthorized)
		wp6_expect_envelope(
			t,
			ctx.private.response.body,
			"unauthorized",
			"authentication required",
			"",
			false,
		)
	}
	{
		ctx: Context
		defer response_destroy(&ctx.private.response)
		forbidden(&ctx, "insufficient permission")
		testing.expect_value(t, ctx.private.response.status, Status.Forbidden)
		wp6_expect_envelope(
			t,
			ctx.private.response.body,
			"forbidden",
			"insufficient permission",
			"",
			false,
		)
	}
	{
		ctx: Context
		defer response_destroy(&ctx.private.response)
		not_found(&ctx, "user")
		testing.expect_value(t, ctx.private.response.status, Status.Not_Found)
		wp6_expect_envelope(
			t,
			ctx.private.response.body,
			"not_found",
			"Resource 'user' not found",
			"",
			false,
		)
	}
	{
		ctx: Context
		defer response_destroy(&ctx.private.response)
		internal_error(&ctx)
		testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
		wp6_expect_envelope(
			t,
			ctx.private.response.body,
			"internal_error",
			"Internal server error",
			"",
			false,
		)
	}
}

@(test)
wp6_field_is_absent_not_empty :: proc(t: ^testing.T) {
	// AMEND-2: `field` is OMITTED when no input field caused the error. A
	// `"field":""` or `"field":null` would be a different wire contract, and
	// clients that check for presence would misread it.
	ctx: Context
	defer response_destroy(&ctx.private.response)

	bad_request(&ctx, "nope")

	value, parsed := wp6_expect_json(t, ctx.private.response.body)
	if !parsed {
		return
	}
	defer json_oracle.destroy_value(value, context.allocator)

	root := value.(json_oracle.Object) or_else nil
	inner := root["error"].(json_oracle.Object) or_else nil
	testing.expect(t, inner != nil)

	_, has_field := inner["field"]
	testing.expect(t, !has_field, "'field' must be omitted entirely, never null or empty")

	// The raw bytes must not mention it either.
	testing.expect(
		t,
		!strings.contains(string(ctx.private.response.body), "field"),
		"the rendered envelope must not contain a field member at all",
	)
}

@(test)
wp6_error_messages_are_escaped :: proc(t: ^testing.T) {
	ctx: Context
	defer response_destroy(&ctx.private.response)

	message := "he said \"hi\"\\ and \n broke é lines"
	bad_request(&ctx, message)

	wp6_expect_envelope(t, ctx.private.response.body, "bad_request", message, "", false)
}

@(test)
wp6_not_found_escapes_the_resource_name :: proc(t: ^testing.T) {
	ctx: Context
	defer response_destroy(&ctx.private.response)

	not_found(&ctx, "us\"er\\x")

	wp6_expect_envelope(
		t,
		ctx.private.response.body,
		"not_found",
		"Resource 'us\"er\\x' not found",
		"",
		false,
	)
}

@(test)
wp6_extractor_errors_keep_field_and_gain_content_type :: proc(t: ^testing.T) {
	// WP5's envelopes are unchanged except for the Content-Type WP6 adds. Their
	// `field` must still be PRESENT — the two WP5 codes are the ones AMEND-2
	// says always carry it.
	ctx: Context
	defer response_destroy(&ctx.private.response)

	// WP33: captures live in a fixed inline array plus a count.


	ctx.private.param.slot[0] = Route_Param{name = "id", value = "banana", found = true}


	ctx.private.param.count = 1
	_, ok_parse := path_int(&ctx, "id")
	testing.expect(t, !ok_parse)

	testing.expect_value(t, ctx.private.response.status, Status.Bad_Request)
	wp6_expect_envelope(
		t,
		ctx.private.response.body,
		"invalid_path_parameter",
		"Path parameter 'id' must be an integer",
		"id",
		true,
	)
	wp6_expect_content_type(t, &ctx.private.response, "application/json")

	// It still uses the fixed request-local buffer, so it is NOT owned.
	testing.expect(
		t,
		!ctx.private.response.owned_body,
		"the WP5 envelope stays on the fixed Context buffer",
	)
}

@(test)
wp6_automatic_404_is_a_json_envelope :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "/known", wp6_noop_handler)

	ctx: Context
	defer response_destroy(&ctx.private.response)
	ctx.request.method = .GET
	ctx.request.path = "/absent"
	dispatch(&a, &ctx)

	testing.expect_value(t, ctx.private.response.status, Status.Not_Found)
	wp6_expect_envelope(t, ctx.private.response.body, "not_found", "Route not found", "", false)
	wp6_expect_content_type(t, &ctx.private.response, "application/json")
}

@(test)
wp6_automatic_405_is_a_json_envelope_and_keeps_allow :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "/users", wp6_noop_handler)
	post(&a, "/users", wp6_noop_handler)

	ctx: Context
	defer response_destroy(&ctx.private.response)
	ctx.request.method = .DELETE
	ctx.request.path = "/users"
	dispatch(&a, &ctx)

	testing.expect_value(t, ctx.private.response.status, Status.Method_Not_Allowed)
	wp6_expect_envelope(
		t,
		ctx.private.response.body,
		"method_not_allowed",
		"Method not allowed",
		"",
		false,
	)

	// D3: `Allow` FIRST, `Content-Type` second, deterministically.
	testing.expect_value(t, len(ctx.private.response.headers), 2)
	testing.expect_value(t, ctx.private.response.headers[0].name, "Allow")
	testing.expect_value(t, ctx.private.response.headers[0].value, "GET, HEAD, POST, OPTIONS")
	testing.expect_value(t, ctx.private.response.headers[1].name, "Content-Type")
	testing.expect_value(t, ctx.private.response.headers[1].value, "application/json")
}

@(test)
wp6_automatic_errors_do_not_overwrite_a_committed_response :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "/users", wp6_noop_handler)

	// 404 path.
	ctx: Context
	defer response_destroy(&ctx.private.response)
	ok(&ctx, Wp6_User{id = 1, name = "first"})
	ctx.request.method = .GET
	ctx.request.path = "/absent"
	dispatch(&a, &ctx)
	testing.expect_value(t, ctx.private.response.status, Status.OK)

	// 405 path.
	ctx2: Context
	defer response_destroy(&ctx2.private.response)
	ok(&ctx2, Wp6_User{id = 2, name = "first"})
	ctx2.request.method = .POST
	ctx2.request.path = "/users"
	dispatch(&a, &ctx2)
	testing.expect_value(t, ctx2.private.response.status, Status.OK)
	testing.expect_value(t, len(ctx2.private.response.headers), 1)
}

@(test)
wp6_bare_still_installs_no_automatic_errors :: proc(t: ^testing.T) {
	a := bare()
	defer destroy(&a)
	get(&a, "/known", wp6_noop_handler)

	ctx: Context
	defer response_destroy(&ctx.private.response)
	ctx.request.method = .GET
	ctx.request.path = "/absent"
	dispatch(&a, &ctx)

	testing.expect(t, !ctx.private.response.committed, "bare() installs no 404")
	testing.expect_value(t, len(ctx.private.response.body), 0)
	testing.expect_value(t, len(ctx.private.response.headers), 0)
}

@(test)
wp6_automatic_errors_allocate_nothing :: proc(t: ^testing.T) {
	// D5: the 404/405 bodies are STATIC constants. If they were marshalled,
	// `dispatch` would allocate on a path any unauthenticated client can
	// trigger, and would link the encoder into every application.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	a := app()
	defer destroy(&a)
	get(&a, "/users", wp6_noop_handler)
	after_registration := len(track.allocation_map)

	ctx: Context
	ctx.request.method = .GET
	ctx.request.path = "/absent"
	dispatch(&a, &ctx)
	testing.expect_value(t, ctx.private.response.status, Status.Not_Found)

	ctx2: Context
	ctx2.request.method = .POST
	ctx2.request.path = "/users"
	dispatch(&a, &ctx2)
	testing.expect_value(t, ctx2.private.response.status, Status.Method_Not_Allowed)

	testing.expect_value(t, len(track.allocation_map), after_registration)
	testing.expect(t, !ctx.private.response.owned_body, "the 404 body is a static constant")
	testing.expect(t, !ctx2.private.response.owned_body, "the 405 body is a static constant")
}

// ---------------------------------------------------------------------------
// 28-34. Marshal failure
// ---------------------------------------------------------------------------

@(test)
wp6_pointer_payload_follows_the_rejection_path :: proc(t: ^testing.T) {
	// ADR-003 / R-13: the pinned marshaller rejects pointer payloads with
	// `Unsupported_Type`. Phase 1 is value-only, so this must become one
	// complete 500 — never a partial body and never a silent success.
	record: Wp6_Log_Record

	ctx: Context
	defer response_destroy(&ctx.private.response)
	record.response = &ctx.private.response

	context.logger = wp6_recording_logger(&record)

	user := Wp6_User{id = 1, name = "x"}
	json(&ctx, .OK, &user)

	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
	wp6_expect_envelope(
		t,
		ctx.private.response.body,
		"internal_error",
		"Internal server error",
		"",
		false,
	)
}

@(test)
wp6_proc_payload_follows_the_rejection_path :: proc(t: ^testing.T) {
	record: Wp6_Log_Record

	ctx: Context
	defer response_destroy(&ctx.private.response)
	record.response = &ctx.private.response
	context.logger = wp6_recording_logger(&record)

	json(&ctx, .OK, wp6_noop_handler)

	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
	wp6_expect_envelope(
		t,
		ctx.private.response.body,
		"internal_error",
		"Internal server error",
		"",
		false,
	)
}

@(test)
wp6_marshal_failure_is_logged_before_the_commit :: proc(t: ^testing.T) {
	// The ordering contract of R-05, asserted rather than claimed: the flag is
	// captured INSIDE the logger, so it reports the state of the response at
	// the instant the framework logged.
	record: Wp6_Log_Record

	ctx: Context
	defer response_destroy(&ctx.private.response)
	record.response = &ctx.private.response
	context.logger = wp6_recording_logger(&record)

	user := Wp6_User{id = 1, name = "x"}
	json(&ctx, .OK, &user)

	testing.expect_value(t, record.framework_calls, 1)
	testing.expect_value(t, record.last_level, log.Level.Error)
	testing.expect(
		t,
		!record.committed_at_log,
		"the marshal failure must be logged BEFORE the 500 is committed",
	)
	testing.expect(t, ctx.private.response.committed, "and the 500 must then be committed")
}

@(test)
wp6_marshal_failure_leaves_no_partial_body :: proc(t: ^testing.T) {
	record: Wp6_Log_Record

	ctx: Context
	defer response_destroy(&ctx.private.response)
	record.response = &ctx.private.response
	context.logger = wp6_recording_logger(&record)

	user := Wp6_User{id = 99, name = "leaked-payload-marker"}
	json(&ctx, .OK, &user)

	// Not one byte of the payload may reach the client.
	body := string(ctx.private.response.body)
	testing.expect(
		t,
		!strings.contains(body, "leaked-payload-marker"),
		"no partial payload may escape into the error response",
	)
	testing.expect(t, !strings.contains(body, "99"))
}

@(test)
wp6_marshal_failure_after_commit_does_not_marshal_or_log :: proc(t: ^testing.T) {
	record: Wp6_Log_Record

	ctx: Context
	defer response_destroy(&ctx.private.response)
	record.response = &ctx.private.response

	text(&ctx, .OK, "already answered")
	context.logger = wp6_recording_logger(&record)

	user := Wp6_User{id = 1, name = "x"}
	json(&ctx, .OK, &user)

	testing.expect_value(t, record.framework_calls, 0)
	testing.expect_value(t, ctx.private.response.status, Status.OK)
	testing.expect_value(t, string(ctx.private.response.body), "already answered")
}

@(test)
wp6_repeated_marshal_failure_does_not_double_commit_or_leak :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	record: Wp6_Log_Record

	ctx: Context
	record.response = &ctx.private.response
	context.logger = wp6_recording_logger(&record)

	user := Wp6_User{id = 1, name = "x"}
	json(&ctx, .OK, &user)
	first_body := string(ctx.private.response.body)

	// A second failing render must find the response already committed and do
	// nothing at all — no marshal, no log, no allocation, no second commit.
	json(&ctx, .Created, &user)
	json(&ctx, .OK, &user)

	testing.expect_value(t, record.framework_calls, 1)
	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
	testing.expect_value(t, string(ctx.private.response.body), first_body)

	response_destroy(&ctx.private.response)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
wp6_marshal_failure_allocates_nothing_net :: proc(t: ^testing.T) {
	// Any partial buffer the marshaller returned on failure must be released,
	// so the whole failed render is net-zero once the 500 is torn down.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)

	record: Wp6_Log_Record

	ctx: Context
	record.response = &ctx.private.response
	context.logger = wp6_recording_logger(&record)

	user := Wp6_User{id = 1, name = "x"}
	json(&ctx, .OK, &user)

	response_destroy(&ctx.private.response)

	testing.expect_value(t, len(track.allocation_map), 0)
	testing.expect_value(t, len(track.bad_free_array), 0)
}
