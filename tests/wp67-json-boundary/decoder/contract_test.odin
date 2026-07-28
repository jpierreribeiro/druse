// WP67 RED contract for request-decoder classification.
//
// This is an external consumer. It deliberately names only the existing
// `web.body` API; WP68 must change behaviour, not invent a test-only path.
package wp67_json_decoder

import json "core:encoding/json"
import "core:log"
import "core:strings"
import "core:testing"
import web "uruquim:web"

Address :: struct {
	number: int `json:"number"`,
}

Input :: struct {
	name:    string  `json:"name"`,
	age:     int     `json:"age"`,
	address: Address `json:"address"`,
}

Unsupported_Input :: struct {
	callback: proc() `json:"callback"`,
}

Repeated_Item :: struct {
	value: int `json:"value"`,
}

Repeated_Input :: struct {
	items: []Repeated_Item `json:"items"`,
}

Fallback_Level :: enum {
	Low,
	High,
}

Fallback_Input :: struct {
	labels: map[string]int `json:"labels"`,
	level:  Fallback_Level `json:"level"`,
}

Fixed_Input :: struct {
	values: [3]int `json:"values"`,
}

Scalar_Input :: struct {
	flag:     bool   `json:"flag"`,
	small:    i8     `json:"small"`,
	unsigned: u16    `json:"unsigned"`,
	ratio:    f32    `json:"ratio"`,
	name:     string `json:"name"`,
	values:   []i16  `json:"values"`,
}

Log_Filter :: struct {
	inner: log.Logger,
}

filter_log :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	f := (^Log_Filter)(data)
	if level == .Error && strings.contains(text, "uruquim:") {
		return
	}
	if f.inner.procedure != nil {
		f.inner.procedure(f.inner.data, level, text, options, location)
	}
}

filtered_logger :: proc(f: ^Log_Filter) -> log.Logger {
	f.inner = context.logger
	return log.Logger {
		procedure = filter_log,
		data = rawptr(f),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

bind_input :: proc(ctx: ^web.Context) {
	dst: Input
	if !web.body(ctx, &dst) {
		return
	}
	web.no_content(ctx)
}

bind_unsupported :: proc(ctx: ^web.Context) {
	dst: Unsupported_Input
	if !web.body(ctx, &dst) {
		return
	}
	web.no_content(ctx)
}

bind_repeated :: proc(ctx: ^web.Context) {
	dst: Repeated_Input
	if !web.body(ctx, &dst) {
		return
	}
	if len(dst.items) != 2 || dst.items[0].value != 1 || dst.items[1].value != 2 {
		web.text(ctx, .Internal_Server_Error, "decoded values drifted")
		return
	}
	web.no_content(ctx)
}

bind_fallback :: proc(ctx: ^web.Context) {
	dst: Fallback_Input
	if !web.body(ctx, &dst) {
		return
	}
	if dst.labels["answer"] != 42 || dst.level != .High {
		web.text(ctx, .Internal_Server_Error, "fallback values drifted")
		return
	}
	web.no_content(ctx)
}

bind_fixed :: proc(ctx: ^web.Context) {
	dst: Fixed_Input
	if !web.body(ctx, &dst) {
		return
	}
	if dst.values != {1, 2, 3} {
		web.text(ctx, .Internal_Server_Error, "fixed values drifted")
		return
	}
	web.no_content(ctx)
}

bind_scalars :: proc(ctx: ^web.Context) {
	dst: Scalar_Input
	if !web.body(ctx, &dst) {
		return
	}
	if !dst.flag ||
	   dst.small != -12 ||
	   dst.unsigned != 65000 ||
	   dst.ratio != 1.5 ||
	   dst.name != "Ada" ||
	   len(dst.values) != 3 ||
	   dst.values[0] != -1 ||
	   dst.values[1] != 2 ||
	   dst.values[2] != 300 {
		web.text(ctx, .Internal_Server_Error, "scalar values drifted")
		return
	}
	web.no_content(ctx)
}

bind_null_scalars :: proc(ctx: ^web.Context) {
	dst := Scalar_Input {
		flag = true,
		small = 7,
		unsigned = 9,
		ratio = 3.5,
		name = "seed",
	}
	if !web.body(ctx, &dst) {
		return
	}
	if dst.flag ||
	   dst.small != 0 ||
	   dst.unsigned != 0 ||
	   dst.ratio != 0 ||
	   dst.name != "" ||
	   len(dst.values) != 0 {
		web.text(ctx, .Internal_Server_Error, "null did not zero fields")
		return
	}
	web.no_content(ctx)
}

expect_error :: proc(
	t: ^testing.T,
	path, raw: string,
	status: web.Status,
	code: string,
	field: string = "",
	loc := #caller_location,
) {
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/input", bind_input)
	web.post(&a, "/unsupported", bind_unsupported)
	web.post(&a, "/repeated", bind_repeated)
	web.post(&a, "/fallback", bind_fallback)
	web.post(&a, "/fixed", bind_fixed)

	res := web.test_request(&a, .POST, path, raw)
	testing.expect_value(t, res.status, status, loc = loc)
	if len(res.body) == 0 {
		testing.expect(t, false, "the error response must carry an envelope", loc = loc)
		return
	}

	value, parse_err := json.parse_string(res.body, .JSON, false, context.allocator)
	testing.expect_value(t, parse_err, json.Error.None, loc = loc)
	if parse_err != .None {
		return
	}
	defer json.destroy_value(value, context.allocator)

	root := value.(json.Object) or_else nil
	testing.expect(t, root != nil, "the response must be a JSON object", loc = loc)
	if root == nil {
		return
	}
	inner := root["error"].(json.Object) or_else nil
	testing.expect(t, inner != nil, "the response must contain error object", loc = loc)
	if inner == nil {
		return
	}

	actual_code := string(inner["code"].(json.String) or_else "")
	testing.expect_value(t, actual_code, code, loc = loc)
	if field != "" {
		actual_field := string(inner["field"].(json.String) or_else "")
		testing.expect_value(t, actual_field, field, loc = loc)
	}

	// No request body or language type may be reflected into a client error.
	testing.expect(t, !strings.contains(res.body, "Unsupported_Type_Error"), loc = loc)
	testing.expect(t, !strings.contains(res.body, "contract_test.odin"), loc = loc)
	testing.expect(t, !strings.contains(res.body, "callback"), loc = loc)
	testing.expect(t, !strings.contains(res.body, "old"), loc = loc)
}

@(test)
wp67_malformed_json_is_a_client_syntax_error :: proc(t: ^testing.T) {
	expect_error(t, "/input", `{`, .Bad_Request, "invalid_json")
}

@(test)
wp67_wrong_scalar_type_is_an_invalid_field :: proc(t: ^testing.T) {
	expect_error(t, "/input", `{"age":"old"}`, .Bad_Request, "invalid_field", "age")
}

@(test)
wp67_nested_type_mismatch_carries_a_stable_path :: proc(t: ^testing.T) {
	expect_error(
		t,
		"/input",
		`{"address":{"number":"x"}}`,
		.Bad_Request,
		"invalid_field",
		"address.number",
	)
}

@(test)
wp67_unknown_field_is_rejected_by_the_canonical_strict_path :: proc(t: ^testing.T) {
	expect_error(t, "/input", `{"surprise":true}`, .Bad_Request, "unknown_field", "surprise")
}

@(test)
wp68_nested_unknown_field_carries_its_full_path :: proc(t: ^testing.T) {
	expect_error(
		t,
		"/input",
		`{"address":{"extra":true}}`,
		.Bad_Request,
		"unknown_field",
		"address.extra",
	)
}

@(test)
wp68_multiple_unknown_fields_choose_a_stable_result :: proc(t: ^testing.T) {
	expect_error(t, "/input", `{"z":1,"a":2}`, .Bad_Request, "unknown_field", "a")
}

@(test)
wp68_repeated_struct_schema_preserves_nested_unknown_refusal :: proc(t: ^testing.T) {
	expect_error(
		t,
		"/repeated",
		`{"items":[{"value":1},{"value":2,"extra":true}]}`,
		.Bad_Request,
		"unknown_field",
		"items.extra",
	)
}

@(test)
wp68_repeated_struct_values_are_decoded_from_the_strict_tree :: proc(t: ^testing.T) {
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/repeated", bind_repeated)

	res := web.test_request(&a, .POST, "/repeated", `{"items":[{"value":1},{"value":2}]}`)
	testing.expect_value(t, res.status, web.Status.No_Content)
}

@(test)
wp68_value_level_fused_miss_falls_back_without_semantic_drift :: proc(t: ^testing.T) {
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/repeated", bind_repeated)

	// The pinned stdlib accepts numeric strings for integer destinations. The
	// fused scalar subset deliberately does not; it must fall back and preserve
	// the established successful result.
	res := web.test_request(
		&a,
		.POST,
		"/repeated",
		`{"items":[{"value":"1"},{"value":"2"}]}`,
	)
	testing.expect_value(t, res.status, web.Status.No_Content)
}

@(test)
wp68_unsupported_fused_shape_falls_back_to_the_stdlib_decoder :: proc(t: ^testing.T) {
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/fallback", bind_fallback)

	res := web.test_request(
		&a,
		.POST,
		"/fallback",
		`{"labels":{"answer":42},"level":"High"}`,
	)
	testing.expect_value(t, res.status, web.Status.No_Content)
}

@(test)
wp68_fixed_array_values_are_decoded_from_the_strict_tree :: proc(t: ^testing.T) {
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/fixed", bind_fixed)

	res := web.test_request(&a, .POST, "/fixed", `{"values":[1,2,3]}`)
	testing.expect_value(t, res.status, web.Status.No_Content)
}

@(test)
wp68_fused_scalar_subset_preserves_typed_values :: proc(t: ^testing.T) {
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/scalars", bind_scalars)

	res := web.test_request(
		&a,
		.POST,
		"/scalars",
		`{"flag":true,"small":-12,"unsigned":65000,"ratio":1.5,"name":"Ada","values":[-1,2,300]}`,
	)
	testing.expect_value(t, res.status, web.Status.No_Content)
}

@(test)
wp68_null_preserves_the_stdlib_zero_value_contract :: proc(t: ^testing.T) {
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/null-scalars", bind_null_scalars)

	res := web.test_request(
		&a,
		.POST,
		"/null-scalars",
		`{"flag":null,"small":null,"unsigned":null,"ratio":null,"name":null,"values":null}`,
	)
	testing.expect_value(t, res.status, web.Status.No_Content)
}

@(test)
wp68_wrong_root_aggregate_uses_the_root_path :: proc(t: ^testing.T) {
	expect_error(t, "/input", `[]`, .Bad_Request, "invalid_field", "$")
}

Narrow :: struct {
	small: u8 `json:"small"`,
}

bind_narrow :: proc(ctx: ^web.Context) {
	dst: Narrow
	if !web.body(ctx, &dst) {
		return
	}
	web.ok(ctx, dst)
}

@(test)
wp68_out_of_range_integer_is_an_invalid_field :: proc(t: ^testing.T) {
	// A value that does not fit the destination integer type must be refused as
	// invalid_field, not accepted with a 200 and silently truncated by the
	// authoritative decode. `999999` into a `u8` would otherwise wrap to 63.
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/narrow", bind_narrow)

	res := web.test_request(&a, .POST, "/narrow", `{"small":999999}`)
	testing.expect_value(t, res.status, web.Status.Bad_Request)
	testing.expect(t, strings.contains(res.body, "invalid_field"))
	testing.expect(t, strings.contains(res.body, "small"))

	ok := web.test_request(&a, .POST, "/narrow", `{"small":200}`)
	testing.expect_value(t, ok.status, web.Status.OK)
}

@(test)
wp68_over_deep_nesting_is_refused_before_parsing :: proc(t: ^testing.T) {
	// A body that is syntactically valid JSON but nested far past any legitimate
	// shape must be refused by the bounded structural pre-scan as invalid_json,
	// before the recursive-descent validator and parser (which impose no depth
	// bound of their own) can overflow the worker stack and abort the process.
	// The depth guard must win first: without it, this deep array would parse and
	// be classified invalid_field "$" exactly like `[]` above.
	opens := strings.repeat("[", 200)
	defer delete(opens)
	closes := strings.repeat("]", 200)
	defer delete(closes)
	deep := strings.concatenate({opens, closes})
	defer delete(deep)
	expect_error(t, "/input", deep, .Bad_Request, "invalid_json")
}

@(test)
wp68_trailing_tokens_are_not_silently_ignored :: proc(t: ^testing.T) {
	expect_error(t, "/input", `{"age":1} true`, .Bad_Request, "invalid_json")
}

@(test)
wp67_unsupported_destination_remains_an_internal_error :: proc(t: ^testing.T) {
	expect_error(
		t,
		"/unsupported",
		`{"callback":"x"}`,
		.Internal_Server_Error,
		"internal_error",
	)
}

// --- JSON audit: the integer-range contract, through every token form --------

// A `u8` destination and an `i64` one, so both the narrow-truncation case and
// the "no wider integer exists" case are covered by the same bodies.
Ranged :: struct {
	small: u8  `json:"small"`,
	big:   i64 `json:"big"`,
}

bind_ranged :: proc(ctx: ^web.Context) {
	dst: Ranged
	if !web.body(ctx, &dst) {
		return
	}
	web.ok(ctx, dst)
}

Ratio :: struct {
	ratio: f64 `json:"ratio"`,
}

bind_ratio :: proc(ctx: ^web.Context) {
	dst: Ratio
	if !web.body(ctx, &dst) {
		return
	}
	web.ok(ctx, dst)
}

@(test)
audit_out_of_range_integer_is_refused_in_every_token_form :: proc(t: ^testing.T) {
	// THE DEFECT THIS PINS. `wp68_out_of_range_integer_is_an_invalid_field`
	// covers only the bare-integer form, and the range check it exercises ran
	// only on the `json.Integer` arm of the shape check. JSON can write the same
	// magnitude two other ways, and both skipped the check entirely:
	//
	//   {"small":1e6}      tokenizes as json.Float  -> no range check
	//   {"small":"999999"} tokenizes as json.String -> "parses as i128?" only
	//
	// Both then reached the stdlib decode, which assigns with a truncating cast,
	// so a field feeding a length, quota, index or authorization decision
	// carried an attacker-chosen wrapped value under a 200 — the precise outcome
	// the original check was written to prevent, reachable by changing how the
	// number is spelled.
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/ranged", bind_ranged)

	refused :: []string {
		`{"small":1e6,"big":1}`,          // exponent form
		`{"small":999999.0,"big":1}`,     // fraction-zero form
		`{"small":"999999","big":1}`,     // quoted form
		`{"small":3.7,"big":1}`,          // fractional: an integer field is not a rounder
		`{"small":-1,"big":1}`,           // unsigned destination, negative value
		`{"small":1,"big":"99999999999999999999999"}`, // quoted, past i64
	}
	for body in refused {
		res := web.test_request(&a, .POST, "/ranged", body)
		testing.expectf(
			t,
			res.status == web.Status.Bad_Request,
			"%s must be refused, got %v (%s)",
			body,
			res.status,
			res.body,
		)
		testing.expectf(t, strings.contains(res.body, "invalid_field"), "%s -> invalid_field", body)
	}

	// The negative control: forms that ARE in range must still be accepted, or
	// the fix above would be indistinguishable from refusing all floats.
	accepted :: []string {
		`{"small":200,"big":9007199254740993}`, // plain integers
		`{"small":2e2,"big":1}`,                // 200 written with an exponent
		`{"small":200.0,"big":1}`,              // 200 written with a zero fraction
		`{"small":"200","big":"42"}`,           // quoted, in range
	}
	for body in accepted {
		res := web.test_request(&a, .POST, "/ranged", body)
		testing.expectf(
			t,
			res.status == web.Status.OK,
			"%s must be accepted, got %v (%s)",
			body,
			res.status,
			res.body,
		)
	}
}

@(test)
audit_non_finite_float_is_refused_at_the_boundary :: proc(t: ^testing.T) {
	// `1e999` saturates to +Inf in the tokenizer. Accepting it hands the handler
	// a value it never asked for, and the encoder's NUM-001 guard turns any
	// attempt to echo it into a logged 500 — so six bytes of body could drive
	// 500s and error-log volume. The inbound and outbound numeric contracts are
	// now symmetric: what cannot be encoded is not decoded either.
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/ratio", bind_ratio)

	non_finite :: []string{`{"ratio":1e999}`, `{"ratio":-1e999}`}
	for body in non_finite {
		res := web.test_request(&a, .POST, "/ratio", body)
		testing.expectf(
			t,
			res.status == web.Status.Bad_Request,
			"%s is refused, got %v (%s)",
			body,
			res.status,
			res.body,
		)
	}

	ok := web.test_request(&a, .POST, "/ratio", `{"ratio":1.5}`)
	testing.expectf(t, ok.status == web.Status.OK, "a finite float is accepted, got %v (%s)", ok.status, ok.body)
}

@(test)
audit_duplicate_object_keys_are_refused :: proc(t: ^testing.T) {
	// THE UNTESTED CLAIM. The strict-decoder contract states that duplicate keys
	// are refused, and the implementation delegates that entirely to the pinned
	// stdlib parser — with no test anywhere in the tree asserting it. That makes
	// the guarantee invisible to the gate and free to disappear under a
	// toolchain bump, on a nightly pin. Both spellings are checked: the plain
	// form, and the escaped form (`a` is `a`), which only collapses to a
	// duplicate if unquoting happens before the key is inserted.
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/input", bind_input)

	plain := web.test_request(&a, .POST, "/input", `{"name":"a","name":"b"}`)
	testing.expectf(
		t,
		plain.status == web.Status.Bad_Request,
		"a duplicate key is refused, got %v (%s)",
		plain.status,
		plain.body,
	)

	escaped := web.test_request(&a, .POST, "/input", `{"name":"a","name":"b"}`)
	testing.expectf(
		t,
		escaped.status == web.Status.Bad_Request,
		"an escape-spelled duplicate key is refused, got %v (%s)",
		escaped.status,
		escaped.body,
	)
}

// --- JSON audit backlog: J1/J2 field-precedence agreement --------------------
//
// The shape check and the fused decoder used two different precedence rules
// (`json_struct_field` walked plain declaration order; `json_struct_target`
// walks explicit tags first). For a payload key that matches differently under
// each rule, validation and decode disagreed about the destination field, so
// the fast path and the stdlib fallback could classify the same request
// differently. These schemas pin the agreement: the value that passes the
// shape check must be the value the decoder writes.

// The divergence needs one field matching by NAME and a LATER field matching
// by explicit TAG: the tag pass wins for decode, the declaration-order walk
// won for the old shape check.
J1_Input :: struct {
	y: string,
	x: int `json:"y"`,
}

bind_j1 :: proc(ctx: ^web.Context) {
	dst: J1_Input
	if !web.body(ctx, &dst) {
		return
	}
	web.ok(ctx, dst)
}

@(test)
audit_j1_tag_shadow_shape_check_and_decode_agree :: proc(t: ^testing.T) {
	// Key "y" matches field `x` by explicit tag (decode winner) while field
	// `y` matches by name and is declared FIRST. Before the fix, the shape
	// check walked declaration order and validated against `y: string`:
	// `{"y":5}` was wrongly refused and `{"y":"hello"}` passed the check only
	// to miss the fused decode on type.
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/j1", bind_j1)

	// An integer arrives at the tagged `x: int` field: must be ACCEPTED and
	// written there, not refused because `y: string` shadowed it in the check.
	num := web.test_request(&a, .POST, "/j1", `{"y":5}`)
	testing.expectf(t, num.status == web.Status.OK,
		"tagged int field accepts an integer, got %v (%s)", num.status, num.body)

	// A string against the same key fails the tagged int check: must be
	// REFUSED as invalid_field, identically on the fused path and fallback.
	str := web.test_request(&a, .POST, "/j1", `{"y":"hello"}`)
	testing.expectf(t, str.status == web.Status.Bad_Request,
		"a string for the tagged int field is refused, got %v (%s)", str.status, str.body)
	testing.expect(t, strings.contains(str.body, "invalid_field"), "refusal is invalid_field")
}

J2_Child :: struct {
	inner: string `json:"id"`,
}

J2_Input :: struct {
	using _:   J2_Child,
	outer:     int `json:"id"`,
}

bind_j2 :: proc(ctx: ^web.Context) {
	dst: J2_Input
	if !web.body(ctx, &dst) {
		return
	}
	web.ok(ctx, dst)
}

@(test)
audit_j2_flattened_shadow_validates_the_decode_winner_only :: proc(t: ^testing.T) {
	// Key "id" lives in both the flattened child (string) and the outer struct
	// (int). The old `json_struct_known_check` recursed into the child AND
	// checked the outer field, so `{"id":5}` was refused against the child's
	// `id: string` even though the decoder's winner is the outer `id: int`.
	// The winner's type alone must decide.
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/j2", bind_j2)

	num := web.test_request(&a, .POST, "/j2", `{"id":5}`)
	testing.expectf(t, num.status == web.Status.OK,
		"the outer int field wins and accepts an integer, got %v (%s)", num.status, num.body)

	str := web.test_request(&a, .POST, "/j2", `{"id":"x"}`)
	testing.expectf(t, str.status == web.Status.Bad_Request,
		"a string for the winning int field is refused, got %v (%s)", str.status, str.body)
}
