package main

// ENC2 — does a Druse-owned marshaller produce THE SAME BYTES as
// `core:encoding/json`, over everything an application can hand it?
//
// Run:
//
//	odin run experiments/25-marshal-parity -collection:druse=.
//
// The string writer was already proven byte-for-byte in
// `tests/enc1-quoted-string`, exhaustively, over every rune and every byte.
// That proves one primitive. It says nothing about field ordering, `omitempty`,
// embedded-field flattening, map iteration order, integer widths, enum
// rendering or the rejection set — which is what a whole document is made of.
//
// So this compares WHOLE DOCUMENTS. For every case: marshal with core, marshal
// with the prototype, and require the bytes to be equal. For the types core
// refuses, require the prototype to refuse too — an encoder that silently
// serialises what the reference rejects has changed the public contract, not
// just the speed.
//
// This is the "compiling prototypes ratify" half of the freeze discipline. It
// is throwaway: no product package imports it.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

// ---------------------------------------------------------------------------
// The corpus
// ---------------------------------------------------------------------------

Small :: struct {
	id:   int,
	name: string,
}

Tagged :: struct {
	id:      int `json:"identifier"`,
	skipped: int `json:"-"`,
	plain:   string,
}

Omit :: struct {
	always: int,
	s:      string   `json:"s,omitempty"`,
	sl:     []int    `json:"sl,omitempty"`,
	m:      map[string]int `json:"m,omitempty"`,
	keep:   int      `json:"keep,omitempty"`,
}

Inner :: struct {
	a: int,
	b: string,
}

Embedding :: struct {
	using _: Inner,
	c:       bool,
}

Nested :: struct {
	head:  Small,
	items: []Small,
}

Widths :: struct {
	i8v:   i8,
	u8v:   u8,
	i16v:  i16,
	u16v:  u16,
	i32v:  i32,
	u32v:  u32,
	i64v:  i64,
	u64v:  u64,
	intv:  int,
	uintv: uint,
}

Floats :: struct {
	f32v: f32,
	f64v: f64,
}

Bools :: struct {
	plain: bool,
	eight: b8,
	wide:  b64,
}

Colour :: enum {
	Red,
	Green,
	Blue,
}

Flags :: enum {
	A,
	B,
	C,
}

Exotic :: struct {
	colour: Colour,
	flags:  bit_set[Flags],
	r:      rune,
}

Variant :: union {
	int,
	string,
	Small,
}

Unions :: struct {
	empty: Variant,
	held:  Variant,
}

Strings :: struct {
	plain:    string,
	quoted:   string,
	newline:  string,
	latin1:   string,
	above_ff: string,
	astral:   string,
	invalid:  string,
}

// The sequence below carries deliberate invalid UTF-8: a lone continuation
// byte. core renders it `\xHH`, which is not valid JSON, and the prototype must
// do the same or the contract is not equivalence.
INVALID_UTF8 :: "ok\xffend"

// `any` and `typeid` are only reachable as FIELDS. As a whole payload the
// compiler unwraps them at the call boundary and the case tests nothing.
Any_Holder :: struct {
	held: any,
}

Typeid_Holder :: struct {
	held: typeid,
}

Narrow :: struct {
	half:    f16,
	c64:     complex64,
	big_i:   i128,
	big_u:   u128,
	c_str:   cstring,
}

Empties :: struct {
	s:   string,
	sl:  []int,
	dyn: [dynamic]int,
	m:   map[string]int,
	st:  struct {},
}

// ---------------------------------------------------------------------------
// The harness
// ---------------------------------------------------------------------------

failures := 0
checked := 0

compare :: proc(label: string, v: any) {
	checked += 1

	theirs, err := json.marshal(v, {}, context.allocator)
	defer delete(theirs)

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	res := druse_marshal(&b, v)
	ours := strings.to_string(b)

	their_failed := err != nil
	our_failed := res != .None

	if their_failed || our_failed {
		if their_failed && our_failed {
			fmt.printf("  ok    %-28s both refuse (core=%v, druse=%v)\n", label, err, res)
		} else {
			failures += 1
			fmt.printf(
				"  FAIL  %-28s core %s, druse %s\n",
				label,
				"refused" if their_failed else "accepted",
				"refused" if our_failed else "accepted",
			)
			if !their_failed {
				fmt.printf("        core  = %s\n", string(theirs))
			}
			if !our_failed {
				fmt.printf("        druse = %s\n", ours)
			}
		}
		return
	}

	if ours == string(theirs) {
		fmt.printf("  ok    %-28s %s\n", label, truncate(string(theirs)))
	} else {
		failures += 1
		fmt.printf("  FAIL  %-28s bytes differ\n", label)
		fmt.printf("        core  = %s\n", string(theirs))
		fmt.printf("        druse = %s\n", ours)
	}
}

truncate :: proc(s: string) -> string {
	return s if len(s) <= 78 else s[:78]
}

main :: proc() {
	fmt.println("ENC2 — whole-document parity against core:encoding/json\n")

	// --- scalars -----------------------------------------------------------
	fmt.println("scalars")
	i := 42
	compare("int", i)
	neg := -7
	compare("negative int", neg)
	f := 1.5
	compare("f64 1.5", f)
	s := "hello"
	compare("string", s)
	t := true
	compare("bool", t)

	// --- structs -----------------------------------------------------------
	fmt.println("\nstructs")
	small := Small{id = 42, name = "ada"}
	compare("small struct", small)

	tagged := Tagged{id = 7, skipped = 99, plain = "kept"}
	compare("json tags and skip", tagged)

	omit_empty := Omit{always = 1, keep = 5}
	compare("omitempty, all empty", omit_empty)

	omit_full := Omit{always = 1, s = "x", sl = []int{1, 2}, keep = 5}
	omit_full.m = make(map[string]int)
	defer delete(omit_full.m)
	omit_full.m["present"] = 1
	compare("omitempty, populated", omit_full)

	embedding := Embedding{c = true}
	embedding.a = 3
	embedding.b = "flat"
	compare("using _ flattening", embedding)

	nested := Nested{head = small, items = []Small{{1, "one"}, {2, "two"}}}
	compare("nested struct + slice", nested)

	empty_slice := Nested{head = small, items = {}}
	compare("empty slice", empty_slice)

	// --- numeric widths ----------------------------------------------------
	fmt.println("\nnumeric widths")
	widths := Widths {
		i8v   = -128,
		u8v   = 255,
		i16v  = -32768,
		u16v  = 65535,
		i32v  = -2147483648,
		u32v  = 4294967295,
		i64v  = -9223372036854775808,
		u64v  = 18446744073709551615,
		intv  = -1,
		uintv = 1,
	}
	compare("every integer width", widths)

	floats := Floats{f32v = 1.5, f64v = 1.5}
	compare("f32 and f64", floats)

	narrow := Narrow {
		half  = 1.5,
		c64   = complex(f32(1.5), f32(-2.5)),
		big_i = -170141183460469231731687303715884105728,
		big_u = 340282366920938463463374607431768211455,
		c_str = "c string",
	}
	compare("f16, complex, i128/u128, cstring", narrow)

	bools := Bools{plain = true, eight = true, wide = false}
	compare("bool, b8, b64", bools)

	// --- collections -------------------------------------------------------
	fmt.println("\ncollections")
	arr := [3]int{1, 2, 3}
	compare("fixed array", arr)

	dyn := make([dynamic]int, 0, 4)
	defer delete(dyn)
	append(&dyn, 10, 20, 30)
	compare("dynamic array", dyn)

	ms := make(map[string]int)
	defer delete(ms)
	ms["only"] = 1
	compare("map[string]int, one key", ms)

	// Several keys. Hash order is unspecified, but BOTH marshallers walk the
	// same Raw_Map buckets in the same order, so the comparison is still exact
	// — and it is the only way to test that the comma placement between map
	// entries matches.
	many := make(map[string]int)
	defer delete(many)
	many["alpha"] = 1
	many["beta"] = 2
	many["gamma"] = 3
	many["delta"] = 4
	compare("map[string]int, four keys", many)

	mi := make(map[int]string)
	defer delete(mi)
	mi[7] = "seven"
	compare("map[int]string, one key", mi)

	empty_map := make(map[string]int)
	defer delete(empty_map)
	compare("empty map", empty_map)

	empties := Empties{}
	compare("every empty container", empties)

	// --- exotic but reachable ----------------------------------------------
	fmt.println("\nexotic but reachable")
	exotic := Exotic{colour = .Green, flags = {.A, .C}, r = 'x'}
	compare("enum, bit_set, rune", exotic)

	unions := Unions{}
	unions.held = 5
	compare("union, nil and held", unions)

	n: json.Null
	compare("json.Null", n)

	// --- strings, where the escaping lives ---------------------------------
	fmt.println("\nstrings")
	strs := Strings {
		plain    = "plain ascii",
		quoted   = `a "quote" and a \ backslash`,
		newline  = "line\nbreak\ttab",
		latin1   = "café",
		above_ff = "日本",
		astral   = "astral \U0001F600 here",
		invalid  = INVALID_UTF8,
	}
	compare("every escaping shape", strs)

	// The key/value asymmetry, isolated. core writes object keys with
	// for_json = false, so a control byte in a KEY comes out as a non-JSON
	// escape while the same byte in a VALUE is spelled correctly.
	bell := make(map[string]string)
	defer delete(bell)
	bell["k\ax"] = "v\ay"
	compare("control byte in a key", bell)

	// --- the rejection set -------------------------------------------------
	fmt.println("\nthe rejection set (both must refuse)")
	p := &small
	compare("pointer payload", p)

	pr := main
	compare("procedure payload", pr)

	// NOT `var_any: any = small`. Passing that to a proc taking `any` UNWRAPS
	// it — both marshallers would see a `Small` and happily serialise it, and
	// the case would report "ok" while testing nothing at all. The `any` has to
	// be reached as a struct FIELD to stay an `any`.
	holder := Any_Holder{held = small}
	compare("any inside a struct", holder)

	tid := typeid_of(Small)
	compare("typeid payload", tid)

	tid_holder := Typeid_Holder{held = typeid_of(Small)}
	compare("typeid inside a struct", tid_holder)

	q: quaternion128
	compare("quaternion payload", q)

	mat: matrix[2, 2]f32
	compare("matrix payload", mat)

	mp: [^]int
	compare("multi-pointer payload", mp)

	// --- verdict -----------------------------------------------------------
	fmt.printf("\n%d cases, %d disagreements\n", checked, failures)
	if failures != 0 {
		fmt.println("ENC2: NOT equivalent. The prototype may not move into web/.")
		os.exit(1)
	}
	fmt.println("ENC2: byte-for-byte equivalent over the corpus.")
}
