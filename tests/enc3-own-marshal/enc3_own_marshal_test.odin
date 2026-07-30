// ENC3 — the Druse-owned marshal walk produces THE SAME BYTES as the stdlib,
// and knows exactly which types it covers.
//
// This file declares `package web` but does NOT live in `web/`:
// `json_own_supports` and `json_own_write` are package-private, and
// `build/check.sh` assembles the usual THROWAWAY package from the real `web/`
// sources plus this file (the WP2-WP19 arrangement).
//
// TWO ASSERTIONS PER TYPE, and the suite is worth having only because of the
// first one:
//
//	1. `json_own_supports(T)` equals a value PINNED HERE.
//	2. if supported, `json_own_write` output equals `encoding_json.marshal`.
//
// Assertion 2 alone would be a weak test. The walk falls back to the stdlib for
// anything it does not cover, and a fallback produces correct bytes by
// construction — so a `json_own_supports` that lied and claimed a `map` would
// still yield a correct response, and an output-only test would stay green
// while the coverage claim rotted. Pinning the boolean is what makes the
// coverage a fact rather than a comment.
//
// `experiments/25-marshal-parity` is the wider ratification: it carries the
// rejection set, the exotic shapes and the whole-document corpus. This is the
// half that runs in the gate on every commit.
#+private
package web

import encoding_json "core:encoding/json"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// The corpus
// ---------------------------------------------------------------------------

Enc3_Small :: struct {
	id:   int,
	name: string,
}

Enc3_Tagged :: struct {
	id:      int `json:"identifier"`,
	skipped: int `json:"-"`,
	plain:   string,
}

Enc3_Omit :: struct {
	always: int,
	s:      string `json:"s,omitempty"`,
	sl:     []int  `json:"sl,omitempty"`,
	keep:   int    `json:"keep,omitempty"`,
}

Enc3_Inner :: struct {
	a: int,
	b: string,
}

Enc3_Embedding :: struct {
	using _: Enc3_Inner,
	c:       bool,
}

Enc3_Nested :: struct {
	head:  Enc3_Small,
	items: []Enc3_Small,
}

Enc3_Widths :: struct {
	i8v:  i8,
	u8v:  u8,
	i32v: i32,
	u64v: u64,
	intv: int,
}

Enc3_Floats :: struct {
	f32v: f32,
	f64v: f64,
}

Enc3_Colour :: enum {
	Red,
	Green,
	Blue,
}

Enc3_Flag :: enum {
	A,
	B,
	C,
}

Enc3_Exotic :: struct {
	colour: Enc3_Colour,
	flags:  bit_set[Enc3_Flag],
	r:      rune,
	on:     b8,
}

Enc3_Variant :: union {
	int,
	string,
}

Enc3_Unions :: struct {
	empty: Enc3_Variant,
	held:  Enc3_Variant,
}

Enc3_Strings :: struct {
	plain:    string,
	quoted:   string,
	control:  string,
	latin1:   string,
	above_ff: string,
	astral:   string,
	invalid:  string,
}

// Shapes the walk must DECLINE, because covering them needs `base:runtime`,
// which is not in the frozen dependency manifest.
Enc3_HasMap :: struct {
	m: map[string]int,
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

// The suite still speaks `any` because it is a TEST: the G-03 ban covers
// `web/` sources, and this file lives in `tests/`. The walk under test does
// not — it carries `(rawptr, typeid)`, and the call below is where the two
// conventions meet.
@(private = "file")
same_bytes :: proc(t: ^testing.T, label: string, v: any) {
	theirs, err := encoding_json.marshal(v, {}, context.allocator)
	// NOT `delete`: inside `package web` that name is the DELETE-route
	// helper, which takes an `^App`. The builtin needs its explicit spelling.
	defer delete_slice(theirs, context.allocator)
	if !testing.expectf(t, err == nil, "%s: the stdlib refused the payload (%v)", label, err) {
		return
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	if !testing.expectf(
		t,
		json_own_write(&b, v.data, v.id),
		"%s: the Druse walk declined a supported type",
		label,
	) {
		return
	}

	ours := strings.to_string(b)
	testing.expectf(
		t,
		ours == string(theirs),
		"%s: bytes differ\n  stdlib = %s\n  druse  = %s",
		label,
		string(theirs),
		ours,
	)
}

@(private = "file")
supports :: proc(t: ^testing.T, label: string, id: typeid, expected: bool) {
	testing.expectf(
		t,
		json_own_supports(id) == expected,
		"%s: json_own_supports answered %v, the pinned coverage says %v",
		label,
		json_own_supports(id),
		expected,
	)
}

// ---------------------------------------------------------------------------
// Coverage — pinned, so a widened claim is a failure rather than a silent gain
// ---------------------------------------------------------------------------

@(test)
enc3_coverage_is_exactly_what_is_claimed :: proc(t: ^testing.T) {
	supports(t, "int", int, true)
	supports(t, "string", string, true)
	supports(t, "bool", bool, true)
	supports(t, "f64", f64, true)
	supports(t, "rune", rune, true)
	supports(t, "struct", Enc3_Small, true)
	supports(t, "nested struct + slice", Enc3_Nested, true)
	supports(t, "embedded struct", Enc3_Embedding, true)
	supports(t, "enum", Enc3_Colour, true)
	supports(t, "bit_set", bit_set[Enc3_Flag], true)
	supports(t, "union of supported members", Enc3_Variant, true)
	supports(t, "fixed array", [3]int, true)
	supports(t, "dynamic array", [dynamic]int, true)

	// The declined set. These are not defects: for them the emitter is the
	// stdlib, so the bytes are equal by construction. Covering them would add
	// `base:runtime` to a frozen manifest for a path that is off by default.
	supports(t, "map", map[string]int, false)
	// A tag with FLAGS after the name is declined: the only flag the stdlib
	// defines decides on emptiness, and AMEND-2 bans that rule from `web/`.
	// The stdlib owns it, so the whole type goes there and the bytes match by
	// construction.
	supports(t, "a struct with a flagged json tag", Enc3_Omit, false)
	supports(t, "a struct holding a map", Enc3_HasMap, false)
	supports(t, "any", any, false)
	supports(t, "typeid", typeid, false)
	supports(t, "quaternion", quaternion128, false)
	supports(t, "matrix", matrix[2, 2]f32, false)
}

// A self-referential type must terminate rather than recurse for ever, and it
// must terminate in the SAFE direction.
//
// `JSON_OWN_WALK_MAX_DEPTH` answers `false` at the bound, and a struct
// propagates any `false` upward, so a recursive type is DECLINED and goes to
// the stdlib. That is the correct outcome and the opposite of the validation
// gate's bound, which answers `true` there — the two are conservative in
// opposite directions because their fallbacks differ: declining costs the fast
// path, while skipping a validation would cost the guarantee.
@(test)
enc3_a_recursive_type_is_declined_rather_than_looping :: proc(t: ^testing.T) {
	Deep :: struct {
		next: []Deep,
	}
	testing.expect(
		t,
		json_own_supports(Deep) == false,
		"a self-referential type must hit the depth bound and be declined, not accepted",
	)
}

// ---------------------------------------------------------------------------
// Bytes
// ---------------------------------------------------------------------------

@(test)
enc3_documents_match_the_stdlib :: proc(t: ^testing.T) {
	small := Enc3_Small{id = 42, name = "ada"}
	same_bytes(t, "small struct", small)

	tagged := Enc3_Tagged{id = 7, skipped = 99, plain = "kept"}
	same_bytes(t, "json tags and skip", tagged)

	embedding := Enc3_Embedding{c = true}
	embedding.a = 3
	embedding.b = "flat"
	same_bytes(t, "using _ flattening", embedding)

	nested := Enc3_Nested{head = small, items = []Enc3_Small{{1, "one"}, {2, "two"}}}
	same_bytes(t, "nested struct + slice", nested)

	empty := Enc3_Nested{head = small, items = {}}
	same_bytes(t, "empty slice", empty)

	widths := Enc3_Widths{i8v = -128, u8v = 255, i32v = -2147483648, u64v = 18446744073709551615, intv = -1}
	same_bytes(t, "integer widths", widths)

	floats := Enc3_Floats{f32v = 1.5, f64v = 1.5}
	same_bytes(t, "f32 and f64", floats)

	exotic := Enc3_Exotic{colour = .Green, flags = {.A, .C}, r = 'x', on = true}
	same_bytes(t, "enum, bit_set, rune, b8", exotic)

	unions := Enc3_Unions{}
	unions.held = 5
	same_bytes(t, "union, nil and held", unions)

	dyn := make([dynamic]int, 0, 4)
	defer delete_dynamic_array(dyn)
	append(&dyn, 10, 20, 30)
	same_bytes(t, "dynamic array", dyn)

	arr := [3]int{1, 2, 3}
	same_bytes(t, "fixed array", arr)
}

// The escaping shapes, through the marshal path rather than the writer's own
// test, so the KEY spelling and the VALUE spelling are both exercised where
// they actually meet.
@(test)
enc3_escaping_matches_through_the_marshal_path :: proc(t: ^testing.T) {
	strs := Enc3_Strings {
		plain    = "plain ascii",
		quoted   = `a "quote" and a \ backslash`,
		control  = "line\nbreak\ttab\x00nul",
		latin1   = "café",
		above_ff = "日本",
		astral   = "astral \U0001F600 here",
		invalid  = "ok\xffend",
	}
	same_bytes(t, "every escaping shape", strs)
}

// A struct whose FIELD NAME carries a byte the two spellings disagree about.
// The stdlib writes object keys with `for_json = false`, so this comes out as a
// non-JSON escape — and the Druse walk must produce the same non-JSON escape,
// because equivalence is the contract and diverging is a wire decision with its
// own ADR.
@(test)
enc3_a_control_byte_in_a_key_matches :: proc(t: ^testing.T) {
	Keyed :: struct {
		value: string `json:"bell\ax"`,
	}
	same_bytes(t, "control byte in a key", Keyed{value = "v"})
}
