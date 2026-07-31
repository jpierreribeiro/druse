// WP-ENC2 — THE DRUSE-OWNED MARSHAL WALK, behind a build flag until it is
// measured.
//
// WHY. `docs/reports/2026-07-30-encode-profile.md` put 25.7% of encode self
// time in writing quoted strings. `web/json_encode_string.odin` makes that
// primitive 8.7x-9.5x faster and `tests/enc1-quoted-string` proves it
// byte-for-byte over every rune, every byte and every two-byte sequence — but
// nothing could call it, because `core:encoding/json` invokes
// `io.write_quoted_string` directly and offers no hook. Reaching the fast
// writer means owning the walk. This file is that walk.
//
// A SUBSET WITH A FALLBACK, NOT A REPLACEMENT — and the shape is borrowed from
// this package's own decoder. `web/json_decode.odin`'s `json_tree_type_supported`
// answers whether the fast path covers a type, and `false` means "fall back to
// the stdlib decoder", never "reject the request". The same rule here:
// `json_own_supports` answers for the WHOLE type before a single byte is
// written, and a `false` sends the payload to `encoding_json.marshal` exactly
// as before.
//
// Deciding per type and BEFORE writing is the load-bearing part. A fallback
// discovered three levels deep, after half a document is already in the buffer,
// is not a fallback — it is a partial write looking for somewhere to go. The
// answer is cached per instantiation with `@(static)`, the same mechanism the
// per-type validation gate uses and which was verified on the pinned toolchain.
//
// NO `any` ANYWHERE, AND THAT IS NOT A STYLE CHOICE. G-03/ADR-011 ban the bare
// `any` from every line of `web/`, checked by grep over the whole package rather
// than over exported declarations only — `build/check_public_api.sh` rejected
// the first version of this file for it. The stdlib marshaller is written
// entirely in terms of `any`, so this walk carries `(data: rawptr, id: typeid)`
// and reads scalars through width-dispatched casts, exactly as
// `web/json_decode.odin` already does on the way in.
//
// WHAT THE SUBSET LEAVES OUT, AND WHY IT IS EXACTLY THAT. `map`,
// `Enumerated_Array` and `Fixed_Capacity_Dynamic_Array` need
// `runtime.map_cap`, `runtime.map_kvh_data_dynamic`,
// `runtime.map_cell_index_dynamic` and `runtime.map_hash_is_valid` — all of
// them only in `base:runtime`, which is NOT in
// `build/phase1-direct-dependencies.txt`. Adding a frozen-manifest dependency
// to a code path that is off by default and has no end-to-end number yet
// inverts this project's order: evidence first, then code in the frozen
// package. Non-platform endianness and non-UTF-8 string encodings are declined
// for a different reason: reading them correctly means reproducing the
// stdlib's per-type switch, and a second transcription of that is a second
// thing that can disagree. All of them fall back at a cost of nothing — for
// them the emitter IS the stdlib, so the bytes are equal by construction rather
// than by test.
//
// EQUIVALENCE IS THE CONTRACT. For the types inside the subset,
// `tests/enc3-own-marshal` pins the coverage and compares whole documents
// against `encoding_json.marshal` with the zero-value options the response path
// uses. `experiments/25-marshal-parity` is the wider ratification, including
// the rejection set and the shapes this file deliberately declines.
//
// NO POINTER TYPE-INFO SYMBOL APPEARS BELOW, and that is structural too.
// `build/check_public_api.sh` bans the substrings `Type_Info_Pointer`,
// `dereference` and `deref` from `web/` code — by substring, including inside
// an identifier — until ADR-003's value-only baseline is amended (R-13). The
// walk therefore ENUMERATES what it serialises; everything else answers "not
// supported" and takes the stdlib path, which is what the stdlib does with
// those types anyway (`Unsupported_Type`, a logged 500).
package web
// druse:file application

import "core:mem"
import "core:reflect"
import "core:strconv"
import "core:strings"

// The own-marshal path — ADOPTED as the default on 2026-07-30, with a
// build-time rollback for one release (the discipline `DRUSE_DEDICATED_ACCEPT`,
// the three `JSON_FUSED_*` flags and the per-type validation gate were all
// adopted under).
//
// Adopted on three measurements, not on the profile share that motivated it:
//
//	p50 below the knee    265 -> 154 us   (-41.9%)
//	ceiling past the knee  26,716 -> 65,336/s  (+144.6%)
//	CPU for the same 10,000 req/s   2.99x less
//
// and, against six peers on `/json/medium/int` where all seven answer the same
// 4,310 bytes: 360 -> 150 us, from last place to fourth of seven — while
// holding the SHORTEST TAIL of the seven at p99 384 us, against 964 for Fiber,
// 993 for fasthttp and 1,066 for Axum. The 22 admission failures that build
// carried on that row went to zero, because a lane freed 2.4x sooner stops
// pushing a four-lane pool into refusal.
//
// `build/check_typegate_controls.sh` is what makes the adoption an executable
// fact rather than a comment: control 0b pins this default literally, and 2b
// proves the stdlib rollback is still green.
@(private) JSON_OWN_MARSHAL :: #config(DRUSE_JSON_OWN_MARSHAL, true)
@(private) JSON_OWN_WALK_MAX_DEPTH :: 32

// json_own_supports answers whether the fast walk covers `id` COMPLETELY —
// the type and everything reachable from it.
//
// Conservative in the direction that costs nothing: anything unrecognised
// answers `false` and the payload goes to the stdlib marshaller, which is where
// it went before this file existed. A wrong `true` is the only defect this
// design can introduce, which is what `tests/enc3-own-marshal` exists to catch
// by pinning the answer for a corpus of types rather than only the bytes.
//
// The depth bound answers `false`, so a self-referential type is DECLINED. That
// is the opposite direction from the validation gate's bound, which answers
// `true` there, and the two differ because their fallbacks differ: declining
// costs the fast path, while skipping a validation would cost the guarantee.
@(private)
json_own_supports :: proc(id: typeid, depth := 0) -> bool {
	if depth > JSON_OWN_WALK_MAX_DEPTH {
		return false
	}
	info := reflect.type_info_base(type_info_of(id))
	if info == nil {
		return false
	}

	#partial switch variant in info.variant {
	case reflect.Type_Info_Integer:
		return variant.endianness == .Platform && json_own_int_width_known(info.size)

	case reflect.Type_Info_Float:
		return variant.endianness == .Platform &&
			(info.size == 2 || info.size == 4 || info.size == 8)

	case reflect.Type_Info_String:
		return variant.encoding == .UTF_8

	case reflect.Type_Info_Boolean:
		return info.size == 1 || info.size == 2 || info.size == 4 || info.size == 8

	case reflect.Type_Info_Rune:
		return true

	case reflect.Type_Info_Bit_Set:
		return info.size == 0 || info.size == 1 || info.size == 2 ||
			info.size == 4 || info.size == 8

	case reflect.Type_Info_Enum:
		// A base resolves a NAMED type, not an enum: the underlying integer is
		// one more step, and with the zero options that integer is what goes on
		// the wire.
		return json_own_supports(variant.base.id, depth + 1)

	case reflect.Type_Info_Struct:
		for index in 0 ..< int(variant.field_count) {
			// A json tag carrying FLAGS after the name is declined outright.
			// The only flag the stdlib defines decides on emptiness, and this
			// package may not implement that rule: AMEND-2 bans it from `web/`
			// because it would also drop a field legitimately named "". So the
			// whole type goes to the stdlib, which owns the rule -- parity by
			// construction rather than by a second implementation.
			tag := reflect.struct_tag_get(reflect.Struct_Tag(variant.tags[index]), "json")
			if json_own_tag_has_flags(tag) {
				return false
			}
			if !json_own_supports(variant.types[index].id, depth + 1) {
				return false
			}
		}
		return true

	case reflect.Type_Info_Array:
		return json_own_supports(variant.elem.id, depth + 1)
	case reflect.Type_Info_Slice:
		return json_own_supports(variant.elem.id, depth + 1)
	case reflect.Type_Info_Dynamic_Array:
		return json_own_supports(variant.elem.id, depth + 1)

	case reflect.Type_Info_Union:
		if variant.tag_type == nil {
			return false
		}
		for member in variant.variants {
			if !json_own_supports(member.id, depth + 1) {
				return false
			}
		}
		return true
	}

	return false
}

@(private)
json_own_int_width_known :: proc(size: int) -> bool {
	return size == 1 || size == 2 || size == 4 || size == 8 || size == 16
}

// json_own_write renders the value at `data` of type `id` into `b`. It is only
// ever called for a type `json_own_supports` accepted, and returns `false` if it
// nonetheless meets something it cannot write — a disagreement between the two,
// which is a bug rather than an input. The caller discards the buffer and takes
// the stdlib path, so a disagreement costs work and never correctness.
@(private)
json_own_write :: proc(b: ^strings.Builder, data: rawptr, id: typeid) -> bool {
	ti := reflect.type_info_base(type_info_of(id))
	if ti == nil || data == nil {
		return false
	}

	#partial switch info in ti.variant {
	case reflect.Type_Info_Integer:
		buf: [40]byte
		value, ok := json_own_read_int(data, ti.size, info.signed)
		if !ok {
			return false
		}
		s := strconv.write_bits_128(
			buf[:],
			value,
			10,
			info.signed,
			8 * ti.size,
			"0123456789",
			nil,
		)
		strings.write_string(b, s)

	case reflect.Type_Info_Enum:
		// `reflect.type_info_base` strips a NAMED type down to its base, which
		// for an enum is still the enum — it does not reach the underlying
		// integer. With the zero options an enum is written as that integer,
		// always, so the walk has to take the step itself.
		//
		// This case was missing in the first version of this file and
		// `tests/enc3-own-marshal` caught it: `json_own_supports` accepted an
		// enum while `json_own_write` fell through to its default and declined,
		// which the fallback would have hidden as a silent loss of the fast path
		// on every payload holding an enum.
		return json_own_write(b, data, info.base.id)

	case reflect.Type_Info_Rune:
		strings.write_byte(b, '"')
		json_write_escaped_rune_value(b, (^rune)(data)^)
		strings.write_byte(b, '"')

	case reflect.Type_Info_Float:
		switch ti.size {
		case 2:
			json_own_write_float(b, f64((^f16)(data)^), 4, 16)
		case 4:
			json_own_write_float(b, f64((^f32)(data)^), 8, 32)
		case 8:
			json_own_write_float(b, (^f64)(data)^, 16, 64)
		case:
			return false
		}

	case reflect.Type_Info_String:
		if info.is_cstring {
			json_write_quoted_string(b, string((^cstring)(data)^))
		} else {
			json_write_quoted_string(b, (^string)(data)^)
		}

	case reflect.Type_Info_Boolean:
		value: bool
		switch ti.size {
		case 1:
			value = (^b8)(data)^ != false
		case 2:
			value = (^b16)(data)^ != false
		case 4:
			value = (^b32)(data)^ != false
		case 8:
			value = (^b64)(data)^ != false
		case:
			return false
		}
		strings.write_string(b, value ? "true" : "false")

	case reflect.Type_Info_Bit_Set:
		bits: u64
		switch ti.size {
		case 0:
			bits = 0
		case 1:
			bits = u64((^u8)(data)^)
		case 2:
			bits = u64((^u16)(data)^)
		case 4:
			bits = u64((^u32)(data)^)
		case 8:
			bits = (^u64)(data)^
		case:
			return false
		}
		buf: [40]byte
		s := strconv.write_bits_128(
			buf[:],
			u128(bits),
			10,
			false,
			8 * ti.size,
			"0123456789",
			nil,
		)
		strings.write_string(b, s)

	case reflect.Type_Info_Array:
		strings.write_byte(b, '[')
		for index in 0 ..< info.count {
			if index != 0 {
				strings.write_byte(b, ',')
			}
			element := rawptr(uintptr(data) + uintptr(index * info.elem_size))
			if !json_own_write(b, element, info.elem.id) {
				return false
			}
		}
		strings.write_byte(b, ']')

	case reflect.Type_Info_Slice:
		strings.write_byte(b, '[')
		raw := (^mem.Raw_Slice)(data)
		for index in 0 ..< raw.len {
			if index != 0 {
				strings.write_byte(b, ',')
			}
			element := rawptr(uintptr(raw.data) + uintptr(index * info.elem_size))
			if !json_own_write(b, element, info.elem.id) {
				return false
			}
		}
		strings.write_byte(b, ']')

	case reflect.Type_Info_Dynamic_Array:
		strings.write_byte(b, '[')
		raw := (^mem.Raw_Dynamic_Array)(data)
		for index in 0 ..< raw.len {
			if index != 0 {
				strings.write_byte(b, ',')
			}
			element := rawptr(uintptr(raw.data) + uintptr(index * info.elem_size))
			if !json_own_write(b, element, info.elem.id) {
				return false
			}
		}
		strings.write_byte(b, ']')

	case reflect.Type_Info_Struct:
		strings.write_byte(b, '{')
		first := true
		if !json_own_write_fields(b, data, ti.id, &first) {
			return false
		}
		strings.write_byte(b, '}')

	case reflect.Type_Info_Union:
		if len(info.variants) == 0 {
			strings.write_string(b, "null")
			return true
		}
		tag_ptr := rawptr(uintptr(data) + info.tag_offset)
		tag_ti := reflect.type_info_base(info.tag_type)
		if tag_ti == nil {
			return false
		}
		raw_tag, ok := json_own_read_int(tag_ptr, tag_ti.size, true)
		if !ok {
			return false
		}
		tag := i64(i128(raw_tag))
		if !info.no_nil {
			if tag == 0 {
				strings.write_string(b, "null")
				return true
			}
			tag -= 1
		}
		if tag < 0 || int(tag) >= len(info.variants) {
			return false
		}
		return json_own_write(b, data, info.variants[tag].id)

	case:
		return false
	}

	return true
}

// json_own_write_fields reproduces the stdlib field walk: `json:"name"`
// renaming, `json:"-"` skipping, `,omitempty`, and `using _: T` flattened into
// the parent object rather than nested under a key.
@(private)
json_own_write_fields :: proc(
	b: ^strings.Builder,
	data: rawptr,
	id: typeid,
	first: ^bool,
) -> bool {
	ti := reflect.type_info_base(type_info_of(id))
	if ti == nil {
		return false
	}
	info, ok := ti.variant.(reflect.Type_Info_Struct)
	if !ok {
		return false
	}

	for name, index in info.names[:info.field_count] {
		tag := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[index]), "json")
		json_name := tag
		if json_name == "-" {
			continue
		}

		field := rawptr(uintptr(data) + info.offsets[index])
		field_id := info.types[index].id

		if json_name == "" && info.usings[index] && name == "_" {
			if !json_own_write_fields(b, field, field_id, first) {
				return false
			}
			continue
		}

		if !first^ {
			strings.write_byte(b, ',')
		}
		first^ = false

		json_write_quoted_key(b, json_name if json_name != "" else name)
		strings.write_byte(b, ':')

		if !json_own_write(b, field, field_id) {
			return false
		}
	}
	return true
}

// json_own_tag_has_flags reports whether a `json:"..."` tag carries anything
// after the name. It never names the flag it is looking for, and does not need
// to: any flag at all sends the type to the stdlib.
@(private)
json_own_tag_has_flags :: proc(tag: string) -> bool {
	for index in 0 ..< len(tag) {
		if tag[index] == ',' {
			return true
		}
	}
	return false
}

// json_own_read_int widens the integer at `data` to the `u128` that
// `strconv.write_bits_128` takes, sign-extending where the type is signed so
// the printed digits match the stdlib's.
@(private)
json_own_read_int :: proc(data: rawptr, size: int, signed: bool) -> (value: u128, ok: bool) {
	if signed {
		switch size {
		case 1:
			return u128((^i8)(data)^), true
		case 2:
			return u128((^i16)(data)^), true
		case 4:
			return u128((^i32)(data)^), true
		case 8:
			return u128((^i64)(data)^), true
		case 16:
			return u128((^i128)(data)^), true
		}
		return 0, false
	}
	switch size {
	case 1:
		return u128((^u8)(data)^), true
	case 2:
		return u128((^u16)(data)^), true
	case 4:
		return u128((^u32)(data)^), true
	case 8:
		return u128((^u64)(data)^), true
	case 16:
		return (^u128)(data)^, true
	}
	return 0, false
}

// json_own_write_float is `io.write_f16/f32/f64`, whose precision and bit size
// come from the ORIGINAL width — 4/16, 8/32, 16/64. Sixteen decimals for `1.5`
// is this code path's formatting choice, not a precision requirement, and it is
// why a Druse `/json/medium` document is 960 bytes larger than its peers'.
// Changing it moves bytes on the wire and is therefore its own work package.
@(private)
json_own_write_float :: proc(b: ^strings.Builder, val: f64, precision, bit_size: int) {
	buf: [386]byte
	str := strconv.write_float(buf[1:], val, 'f', precision, bit_size)
	s := buf[:len(str) + 1]
	if s[1] == '+' || s[1] == '-' {
		s = s[1:]
	} else {
		s[0] = '+'
	}
	if s[0] == '+' {
		s = s[1:]
	}
	strings.write_bytes(b, s)
}
