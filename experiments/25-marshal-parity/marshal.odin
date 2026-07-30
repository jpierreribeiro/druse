package main

// The Druse-owned JSON marshaller, as a THROWAWAY PROTOTYPE.
//
// Specification text proposes; compiling prototypes ratify. This file is the
// prototype half of that rule for the encode work package: it is not the
// framework, it is evidence, and no product package imports it.
//
// WHAT IT IS FOR. `core:encoding/json`'s `marshal_to_writer` calls
// `io.write_quoted_string` directly and offers no hook, so the measured fast
// string writer (`web/json_encode_string.odin`, 8.7x-9.5x on its own corpus)
// cannot be reached without Druse owning the walk. Owning the walk also makes
// float rendering addressable, which is the other 6.8% of the encode profile
// and the reason `/json/medium` is not comparable between servers.
//
// THE CONTRACT IS BYTE-FOR-BYTE EQUIVALENCE with
// `json.marshal(v, Marshal_Options{}, allocator)` — the zero-value options the
// response path uses. That means reproducing three of core's choices that are
// questionable on their merits, and one that is a defect:
//
//   * every rune above U+00FF is escaped as `\uXXXX`, though raw UTF-8 is legal;
//   * an invalid UTF-8 byte becomes `\xHH`, which is not valid JSON at all;
//   * maps iterate in HASH order, and enums render as their underlying integer;
//   * OBJECT KEYS are escaped with `for_json = false` while string VALUES use
//     `for_json = true`. The same U+0007 comes out `\a` in a key and ``
//     in a value, and `\a` is not a JSON escape. Worse, `json.is_valid` — the
//     validator the response path trusts as its last line of defence — does not
//     apply escape rules inside keys, so it passes the invalid body. Measured,
//     not inferred: `{"k\ax":"vy"}` is what core emits and `is_valid`
//     answers true for it.
//
// The fourth item is reproduced here **so that the divergence is a decision
// somebody takes on purpose**, with this experiment as the evidence, rather
// than a difference that appears silently under a performance change. Whether
// Druse should keep emitting it is an owner's call and belongs in an ADR.
//
// WHAT IS DELIBERATELY ABSENT. No symbol named for a pointer type info appears
// anywhere below. R-13 bans the substrings `Type_Info_Pointer`, `dereference`
// and `deref` from `web/` code — by substring, including inside an identifier —
// until ADR-003's value-only baseline is amended. So this walk ENUMERATES what
// it serialises and rejects everything else by falling through to
// `.Unsupported_Type`, which is byte-for-byte and error-for-error what core
// does for pointers, multi-pointers, SOA pointers, procedures, `any`, `typeid`,
// parameters, SIMD vectors, matrices, bit fields and quaternions. `json.Null`
// is the one pointer-shaped type core DOES serialise, and it is recognised by
// comparing typeids, which inspects nothing.

import "base:runtime"
import "core:encoding/json"
import "core:reflect"
import "core:strconv"
import "core:strings"

Marshal_Result :: enum {
	None,
	Unsupported_Type,
}

// druse_marshal renders `v` into `b`, or reports the first type it cannot
// serialise. It never allocates: the Builder owns the only buffer.
druse_marshal :: proc(b: ^strings.Builder, v: any) -> Marshal_Result {
	if v == nil {
		strings.write_string(b, "null")
		return .None
	}

	// The single pointer-shaped type core serialises. Compared by typeid, which
	// reads no pointee and names no pointer type info.
	if v.id == typeid_of(json.Null) {
		strings.write_string(b, "null")
		return .None
	}

	ti := runtime.type_info_base(type_info_of(v.id))
	a := any{v.data, ti.id}

	#partial switch info in ti.variant {
	case runtime.Type_Info_Integer:
		buf: [40]byte
		u := druse_any_int_to_u128(a)
		s := strconv.write_bits_128(buf[:], u, 10, info.signed, 8 * ti.size, "0123456789", nil)
		strings.write_string(b, s)

	case runtime.Type_Info_Rune:
		r := a.(rune)
		strings.write_byte(b, '"')
		druse_write_escaped_rune_for_json(b, r)
		strings.write_byte(b, '"')

	case runtime.Type_Info_Float:
		switch f in a {
		case f16:
			druse_write_float(b, f64(f), 4, 16)
		case f32:
			druse_write_float(b, f64(f), 8, 32)
		case f64:
			druse_write_float(b, f, 16, 64)
		case:
			return .Unsupported_Type
		}

	case runtime.Type_Info_Complex:
		r, i: f64
		switch z in a {
		case complex32:
			r, i = f64(real(z)), f64(imag(z))
		case complex64:
			r, i = f64(real(z)), f64(imag(z))
		case complex128:
			r, i = f64(real(z)), f64(imag(z))
		case:
			return .Unsupported_Type
		}
		strings.write_byte(b, '[')
		druse_write_float(b, r, 16, 64)
		strings.write_string(b, ", ")
		druse_write_float(b, i, 16, 64)
		strings.write_byte(b, ']')

	case runtime.Type_Info_String:
		switch s in a {
		case string:
			druse_write_quoted_string(b, s, for_json = true)
		case cstring:
			druse_write_quoted_string(b, string(s), for_json = true)
		}

	case runtime.Type_Info_Boolean:
		val: bool
		switch x in a {
		case bool:
			val = bool(x)
		case b8:
			val = bool(x)
		case b16:
			val = bool(x)
		case b32:
			val = bool(x)
		case b64:
			val = bool(x)
		}
		strings.write_string(b, val ? "true" : "false")

	case runtime.Type_Info_Array:
		strings.write_byte(b, '[')
		for i in 0 ..< info.count {
			if i != 0 {
				strings.write_byte(b, ',')
			}
			data := uintptr(v.data) + uintptr(i * info.elem_size)
			if r := druse_marshal(b, any{rawptr(data), info.elem.id}); r != .None {
				return r
			}
		}
		strings.write_byte(b, ']')

	case runtime.Type_Info_Slice:
		strings.write_byte(b, '[')
		s := (^runtime.Raw_Slice)(v.data)
		for i in 0 ..< s.len {
			if i != 0 {
				strings.write_byte(b, ',')
			}
			data := uintptr(s.data) + uintptr(i * info.elem_size)
			if r := druse_marshal(b, any{rawptr(data), info.elem.id}); r != .None {
				return r
			}
		}
		strings.write_byte(b, ']')

	case runtime.Type_Info_Dynamic_Array:
		strings.write_byte(b, '[')
		arr := (^runtime.Raw_Dynamic_Array)(v.data)
		for i in 0 ..< arr.len {
			if i != 0 {
				strings.write_byte(b, ',')
			}
			data := uintptr(arr.data) + uintptr(i * info.elem_size)
			if r := druse_marshal(b, any{rawptr(data), info.elem.id}); r != .None {
				return r
			}
		}
		strings.write_byte(b, ']')

	case runtime.Type_Info_Map:
		m := (^runtime.Raw_Map)(v.data)
		strings.write_byte(b, '{')
		if m != nil {
			if info.map_info == nil {
				return .Unsupported_Type
			}
			map_cap := uintptr(runtime.map_cap(m^))
			ks, vs, hs, _, _ := runtime.map_kvh_data_dynamic(m^, info.map_info)
			i := 0
			for bucket in 0 ..< map_cap {
				runtime.map_hash_is_valid(hs[bucket]) or_continue
				if i != 0 {
					strings.write_byte(b, ',')
				}
				i += 1

				key := rawptr(runtime.map_cell_index_dynamic(ks, info.map_info.ks, bucket))
				value := rawptr(runtime.map_cell_index_dynamic(vs, info.map_info.vs, bucket))

				kti := runtime.type_info_base(type_info_of(info.key.id))
				ka := any{key, kti.id}
				#partial switch kinfo in kti.variant {
				case runtime.Type_Info_String:
					name: string
					switch s in ka {
					case string:
						name = s
					case cstring:
						name = string(s)
					}
					druse_write_key(b, name)
				case runtime.Type_Info_Integer:
					buf: [40]byte
					u := druse_any_int_to_u128(ka)
					name := strconv.write_bits_128(
						buf[:],
						u,
						10,
						kinfo.signed,
						8 * kti.size,
						"0123456789",
						nil,
					)
					druse_write_key(b, name)
				case:
					return .Unsupported_Type
				}

				if r := druse_marshal(b, any{value, info.value.id}); r != .None {
					return r
				}
			}
		}
		strings.write_byte(b, '}')

	case runtime.Type_Info_Struct:
		strings.write_byte(b, '{')
		first := true
		if r := druse_marshal_struct_fields(b, v, &first); r != .None {
			return r
		}
		strings.write_byte(b, '}')

	case runtime.Type_Info_Union:
		if len(info.variants) == 0 || v.data == nil {
			strings.write_string(b, "null")
			return .None
		}
		tag_ptr := uintptr(v.data) + info.tag_offset
		tag_any := any{rawptr(tag_ptr), info.tag_type.id}
		tag: i64 = -1
		switch i in tag_any {
		case u8:
			tag = i64(i)
		case i8:
			tag = i64(i)
		case u16:
			tag = i64(i)
		case i16:
			tag = i64(i)
		case u32:
			tag = i64(i)
		case i32:
			tag = i64(i)
		case u64:
			tag = i64(i)
		case i64:
			tag = i64(i)
		case:
			return .Unsupported_Type
		}
		if !info.no_nil {
			if tag == 0 {
				strings.write_string(b, "null")
				return .None
			}
			tag -= 1
		}
		return druse_marshal(b, any{v.data, info.variants[tag].id})

	case runtime.Type_Info_Enum:
		// `use_enum_names` is false in the zero options, so an enum is its
		// underlying integer. Always.
		return druse_marshal(b, any{v.data, info.base.id})

	case runtime.Type_Info_Bit_Set:
		bit_data: u64
		bit_size := u64(8 * ti.size)
		switch bit_size {
		case 0:
			bit_data = 0
		case 8:
			bit_data = u64((^u8)(v.data)^)
		case 16:
			bit_data = u64((^u16)(v.data)^)
		case 32:
			bit_data = u64((^u32)(v.data)^)
		case 64:
			bit_data = u64((^u64)(v.data)^)
		case:
			return .Unsupported_Type
		}
		buf: [40]byte
		s := strconv.write_bits_128(
			buf[:],
			u128(bit_data),
			10,
			false,
			int(bit_size),
			"0123456789",
			nil,
		)
		strings.write_string(b, s)

	case:
		// Everything not enumerated above. This is where pointers, procedures,
		// `any`, `typeid`, matrices, SIMD vectors, bit fields, quaternions and
		// parameter lists land — exactly the set core rejects, reached without
		// naming any of them.
		return .Unsupported_Type
	}

	return .None
}

// druse_marshal_struct_fields reproduces core's field walk: `json:"name"`
// renaming, `json:"-"` skipping, `,omitempty`, and `using _: T` flattening into
// the parent object.
druse_marshal_struct_fields :: proc(b: ^strings.Builder, v: any, first: ^bool) -> Marshal_Result {
	ti := runtime.type_info_base(type_info_of(v.id))
	info := ti.variant.(runtime.Type_Info_Struct)

	for name, i in info.names[:info.field_count] {
		omitempty := false
		tag := reflect.struct_tag_get(reflect.Struct_Tag(info.tags[i]), "json")
		json_name, tag_flags := druse_json_name_from_tag(tag)

		if json_name == "-" {
			continue
		}
		flags := tag_flags
		for flag in strings.split_iterator(&flags, ",") {
			if flag == "omitempty" {
				omitempty = true
			}
		}

		id := info.types[i].id
		data := rawptr(uintptr(v.data) + info.offsets[i])
		the_value := any{data, id}

		if omitempty && druse_is_omitempty(the_value) {
			continue
		}

		if json_name == "" && info.usings[i] && name == "_" {
			// Flattened into the parent: no key, no comma of its own — the
			// nested walk continues the parent's iteration.
			if r := druse_marshal_struct_fields(b, the_value, first); r != .None {
				return r
			}
			continue
		}

		if !first^ {
			strings.write_byte(b, ',')
		}
		first^ = false

		druse_write_key(b, json_name if json_name != "" else name)

		if r := druse_marshal(b, the_value); r != .None {
			return r
		}
	}
	return .None
}

// druse_write_key writes an object key. NOTE the `for_json = false`: this is
// core's behaviour, reproduced deliberately, and it is why a control byte in a
// key comes out as a non-JSON escape. See the file header.
druse_write_key :: proc(b: ^strings.Builder, name: string) {
	druse_write_quoted_string(b, name, for_json = false)
	strings.write_byte(b, ':')
}

// druse_json_name_from_tag splits `json:"name,flag,flag"` into the name and the
// remaining comma-separated flags.
druse_json_name_from_tag :: proc(tag: string) -> (name: string, extra: string) {
	for i in 0 ..< len(tag) {
		if tag[i] == ',' {
			return tag[:i], tag[i + 1:]
		}
	}
	return tag, ""
}

// druse_is_omitempty reproduces core's per-kind emptiness rules exactly.
druse_is_omitempty :: proc(v: any) -> bool {
	if v == nil {
		return true
	}
	ti := runtime.type_info_core(type_info_of(v.id))
	#partial switch info in ti.variant {
	case runtime.Type_Info_String:
		switch x in v {
		case string:
			return x == ""
		case cstring:
			return x == nil || x == ""
		}
	case runtime.Type_Info_Any:
		return v.(any) == nil
	case runtime.Type_Info_Type_Id:
		return v.(typeid) == nil
	case runtime.Type_Info_Dynamic_Array:
		return (^runtime.Raw_Dynamic_Array)(v.data).len == 0
	case runtime.Type_Info_Slice:
		return (^runtime.Raw_Slice)(v.data).len == 0
	case runtime.Type_Info_Union, runtime.Type_Info_Bit_Set:
		return reflect.is_nil(v)
	case runtime.Type_Info_Map:
		return (^runtime.Raw_Map)(v.data).len == 0
	}
	return false
}

// druse_any_int_to_u128 widens any integer to the u128 `strconv.write_bits_128`
// wants, preserving sign for the signed path.
druse_any_int_to_u128 :: proc(a: any) -> u128 {
	switch i in a {
	case i8:
		return u128(i)
	case u8:
		return u128(i)
	case i16:
		return u128(i)
	case u16:
		return u128(i)
	case i32:
		return u128(i)
	case u32:
		return u128(i)
	case i64:
		return u128(i)
	case u64:
		return u128(i)
	case i128:
		return u128(i)
	case u128:
		return i
	case int:
		return u128(i)
	case uint:
		return u128(i)
	case uintptr:
		return u128(i)
	case i16le:
		return u128(i)
	case u16le:
		return u128(i)
	case i32le:
		return u128(i)
	case u32le:
		return u128(i)
	case i64le:
		return u128(i)
	case u64le:
		return u128(i)
	case i128le:
		return u128(i)
	case u128le:
		return u128(i)
	case i16be:
		return u128(i)
	case u16be:
		return u128(i)
	case i32be:
		return u128(i)
	case u32be:
		return u128(i)
	case i64be:
		return u128(i)
	case u64be:
		return u128(i)
	case i128be:
		return u128(i)
	case u128be:
		return u128(i)
	}
	return 0
}
