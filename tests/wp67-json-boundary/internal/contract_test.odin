// WP67 internal RED contract: allocator/decoder failure must fail closed.
#+private
package web

import "core:mem"
import "core:strings"
import "core:testing"

Wp67_Allocated_Input :: struct {
	name: string   `json:"name"`,
	tags: []string `json:"tags"`,
}

@(test)
wp67_decoder_allocation_failure_must_not_return_success_with_zero_values :: proc(t: ^testing.T) {
	ctx: Context
	defer request_arena_destroy(&ctx)
	ctx.request.body = transmute([]u8)string(`{"name":"a\\nb","tags":["x","y"]}`)
	// The 500 is the expected outcome under test; suppress its expected Error
	// diagnostic so core:testing does not count the log record as a test error.
	//
	// THE SCOPE IS THE POINT, and it used to be wrong. The restore was `defer`red,
	// so the nil logger stayed installed for the REST OF THE TEST — including
	// every assertion below. `testing.expect*` reports a failure by calling
	// `log.errorf` through `context.logger`, so all three assertions were
	// unreportable and this suite could not fail. Measured: a deliberately
	// impossible assertion here passed. Same defect as the one found in
	// `tests/wp9-wire`, in a different shape.
	//
	// The nil ALLOCATOR is restored on the same line for a second reason: a
	// failing `expect_value` formats its message, and formatting under
	// `mem.nil_allocator` is its own way to lose a failure.
	previous_logger := context.logger
	previous_allocator := context.allocator

	// The pinned stdlib currently returns err=nil and zeroes when allocations
	// fail. The framework must detect or avoid that path; a successful bind with
	// empty values is data corruption, not graceful degradation.
	context.logger = {}
	context.allocator = mem.nil_allocator()
	dst: Wp67_Allocated_Input
	ok := body(&ctx, &dst)
	context.logger = previous_logger
	context.allocator = previous_allocator

	testing.expect(t, !ok, "allocation failure must fail the bind")
	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
	testing.expect_value(
		t,
		string(ctx.private.response.body),
		`{"error":{"code":"internal_error","message":"Internal server error"}}`,
	)
}

// --- audit J3/J4: the structural cost bound -------------------------------
//
// `json_scan_structure` is what stands between a well-formed 4 MiB body and
// 588 MB of RSS, so its arithmetic is tested directly rather than inferred from
// a 413. The cases below are chosen for where a plausible implementation is
// WRONG, not for coverage of where it is obviously right.

Node_Case :: struct {
	body:  string,
	nodes: int,
	depth: int,
	why:   string,
}

@(test)
j3_json_scan_structure_counts_nodes_exactly :: proc(t: ^testing.T) {
	cases := []Node_Case {
		{`{}`, 1, 1, "an empty object is one node, not two"},
		{`[]`, 1, 1, "an empty array is one node"},
		{`{ }`, 1, 1, "whitespace does not make a container non-empty"},
		{`[1,2,3]`, 4, 1, "array plus three scalars"},
		{`{"a":1}`, 3, 1, "object plus one value plus one key"},
		{`{"a":{"b":2}}`, 5, 2, "two objects, one value, two keys"},
		// THE ONE THAT MATTERS. This is the J3 shape in miniature. Counting
		// containers instead of non-empty containers reports 5 here and
		// double-counts 1.4 million empty objects on the real body.
		{`[{},{}]`, 3, 2, "an array of two empty objects is three nodes"},
		{`[{},{},{}]`, 4, 2, "and four for three"},
		// Punctuation inside a string is not structure. A body that counted it
		// would refuse legitimate traffic carrying JSON-ish text.
		{`{"a":"{{{,,,::"}`, 3, 1, "punctuation inside a string is content, not structure"},
		{`{"a":"x\"y"}`, 3, 1, "an escaped quote does not end the string early"},
		{`[[[[]]]]`, 4, 4, "nesting depth is reported alongside the count"},
		{`1`, 1, 0, "a bare scalar is one node at depth zero"},
	}
	for c in cases {
		nodes, depth := json_scan_structure(transmute([]u8)c.body)
		testing.expectf(t, nodes == c.nodes, "%s: %q counted %d nodes, expected %d", c.why, c.body, nodes, c.nodes)
		testing.expectf(t, depth == c.depth, "%s: %q reported depth %d, expected %d", c.why, c.body, depth, c.depth)
	}
}

// The J3 shape at full scale, counted rather than decoded — the arithmetic must
// hold at 1.4M elements, not only at three.
@(test)
j3_json_scan_structure_holds_at_the_measured_scale :: proc(t: ^testing.T) {
	ELEMENTS :: 100_000
	b: [dynamic]u8
	defer delete_dynamic_array(b)
	append(&b, '[')
	for i in 0 ..< ELEMENTS {
		if i > 0 {
			append(&b, ',')
		}
		append(&b, '{')
		append(&b, '}')
	}
	append(&b, ']')

	nodes, depth := json_scan_structure(b[:])
	// One array plus ELEMENTS empty objects. Nothing else.
	testing.expectf(
		t,
		nodes == ELEMENTS + 1,
		"the J3 shape at %d elements counted %d nodes, expected %d; an off-by-one-per-element here is a 2x error on the body this bound exists for",
		ELEMENTS,
		nodes,
		ELEMENTS + 1,
	)
	testing.expect_value(t, depth, 2)
}

J3_Item :: struct {
	a: int `json:"a"`,
}

// End to end: the refusal an application and a client actually see.
@(test)
j3_a_body_over_max_json_nodes_is_refused_413 :: proc(t: ^testing.T) {
	NODES :: 500

	handler :: proc(ctx: ^Context) {
		items: []J3_Item
		if !body(ctx, &items) {
			return
		}
		text(ctx, .OK, "decoded")
	}

	build :: proc(elements: int) -> [dynamic]u8 {
		b: [dynamic]u8
		append(&b, '[')
		for i in 0 ..< elements {
			if i > 0 {
				append(&b, ',')
			}
			append(&b, '{', '"', 'a', '"', ':', '1', '}')
		}
		append(&b, ']')
		return b
	}

	a := app()
	defer destroy(&a)
	l := DEFAULT_LIMITS
	l.max_json_nodes = NODES
	limits(&a, l)
	post(&a, "/items", handler)

	// Each element is one object + one value + one key = 3 nodes, plus the
	// array. 100 elements is 301 — comfortably under.
	under := build(100)
	defer delete_dynamic_array(under)
	res_ok := test_request(&a, .POST, "/items", string(under[:]))
	testing.expectf(t, res_ok.status == Status.OK, "a body inside the node budget must decode; got %v", res_ok.status)

	// 400 elements is 1201 nodes, over the 500 budget, and still a tiny body —
	// which is the whole finding: `max_body` cannot see this.
	over := build(400)
	defer delete_dynamic_array(over)
	res_big := test_request(&a, .POST, "/items", string(over[:]))
	testing.expectf(
		t,
		res_big.status == Status.Payload_Too_Large,
		"a body over the node budget must be refused 413; got %v (body is only %d bytes, so max_body cannot be what refuses it)",
		res_big.status,
		len(over),
	)
	testing.expectf(
		t,
		strings.contains(res_big.body, "body_too_complex"),
		"the envelope must say the body is too COMPLEX, not too large: a client that retries by shrinking bytes has misread it. Got: %s",
		res_big.body,
	)
	testing.expectf(
		t,
		strings.contains(res_big.body, "500"),
		"and must report the effective limit as a number the client can act on. Got: %s",
		res_big.body,
	)
}

// Zero means no limit, and it must really mean it — otherwise an application
// that opts out is silently held to the default.
//
// THE PAIR IS THE TEST. Asserting only that the opted-out app decodes proves
// nothing unless the SAME body is refused by the default, so both run here on
// one body sized to sit above `JSON_NODE_LIMIT`. A first draft of this used a
// 15,001-node body — under the 100,000 default — and would have passed even if
// the zero were ignored entirely.
@(test)
j3_zero_max_json_nodes_means_no_limit :: proc(t: ^testing.T) {
	handler :: proc(ctx: ^Context) {
		items: []J3_Item
		if !body(ctx, &items) {
			return
		}
		text(ctx, .OK, "decoded")
	}

	// Each element is 3 nodes, so 40,000 elements is 120,001 — above the
	// 100,000 default and still well inside `max_body`.
	b: [dynamic]u8
	defer delete_dynamic_array(b)
	append(&b, '[')
	for i in 0 ..< 40_000 {
		if i > 0 {
			append(&b, ',')
		}
		append(&b, '{', '"', 'a', '"', ':', '1', '}')
	}
	append(&b, ']')
	payload := string(b[:])

	nodes, _ := json_scan_structure(b[:])
	testing.expectf(
		t,
		nodes > JSON_NODE_LIMIT,
		"this test needs a body above the default of %d to mean anything; it has %d nodes",
		JSON_NODE_LIMIT,
		nodes,
	)

	{
		a := app()
		defer destroy(&a)
		limits(&a, DEFAULT_LIMITS)
		post(&a, "/items", handler)
		res := test_request(&a, .POST, "/items", payload)
		testing.expectf(
			t,
			res.status == Status.Payload_Too_Large,
			"the default must refuse a %d-node body; got %v",
			nodes,
			res.status,
		)
	}
	{
		a := app()
		defer destroy(&a)
		l := DEFAULT_LIMITS
		l.max_json_nodes = 0
		limits(&a, l)
		post(&a, "/items", handler)
		res := test_request(&a, .POST, "/items", payload)
		testing.expectf(
			t,
			res.status == Status.OK,
			"with max_json_nodes = 0 the same %d-node body must decode; got %v",
			nodes,
			res.status,
		)
	}
}
