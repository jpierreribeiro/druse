// WP68 — bounded structural preflight for canonical request JSON.
//
// The pinned standard decoder is still the authority that populates the
// caller's destination. This module supplies only the information it does not
// expose: a field stack and strict unknown-field detection. It deliberately
// does not implement a second JSON grammar. Syntax and string decoding remain
// owned by core:encoding/json.
package web
// druse:file application

import json "core:encoding/json"
import "core:mem"
import "core:reflect"
import "core:strconv"
import "core:strings"

// AUDIT J6 — DUPLICATE-KEY REJECTION IS DELEGATED, DELIBERATELY, AND GUARDED
// BY A TEST RATHER THAN BY A SECOND IMPLEMENTATION.
//
// The finding asks for the behaviour to be OWNED here instead of delegated to a
// nightly toolchain pin. It is not, and the reason is the paragraph below this
// one: this module deliberately does not implement a second JSON grammar.
// Detecting duplicate keys means walking object keys with unquoting applied,
// which is a second parser by another name — and two grammars that can disagree
// about the same body is the defect this file exists to avoid.
//
// WHAT REPLACES OWNERSHIP is a pin plus a test. The compiler commit is pinned
// and `build/check.sh` refuses to run against any other, so the stdlib cannot
// change underneath this without a deliberate act; and the contract test in
// `tests/wp67-json-boundary/decoder` fails the moment it does.
//
// THAT TEST WAS HALF DECORATIVE UNTIL THIS AUDIT. It claimed to check both the
// plain and the `\u`-escaped spelling — the escaped one being the interesting
// case, since those keys collide only after unquoting — and its two request
// bodies were BYTE-FOR-BYTE IDENTICAL. The escaped claim was never sent. It now
// is, both cases go red when their duplication is removed, and a third case
// pins that the refusal comes from duplication rather than from `\u` in a key
// being refused outright.
//
// The parser is already the syntax authority and reports every malformed,
// duplicate-key and trailing-token case the preceding `json.is_valid` pass
// reported. Its disposable tree lives in `temporary`, and `context.allocator`
// is set to that same arena for the whole parse so partial-tree cleanup cannot
// cross allocators. Parsing directly therefore preserves the strict contract
// while avoiding a redundant full tokenization pass on every valid request.
//
// Keep a private build-time rollback control for one release, matching the
// dedicated-accept rollout discipline. Applications do not configure this:
// the efficient path is the native default and the public API is unchanged.
@(private)
JSON_DIRECT_PREFLIGHT_PARSE :: #config(DRUSE_JSON_DIRECT_PREFLIGHT_PARSE, true)

// Experimental fused decode: after the strict parser and shape checker have
// accepted a tree made only of the ordinary DTO subset (structs, slices,
// arrays and scalar fields), populate the destination from that tree instead
// of tokenizing the same bytes again in the stdlib unmarshaller. Types outside
// that subset, recursive schemas and registered custom unmarshalers fall back
// to the authoritative stdlib path before any destination write.
//
// The efficient path is the native default after the dedicated A/B cleared the
// adoption floor. Keep a private rollback for one release while the stdlib
// fallback remains the compatibility authority for the wider type surface.
@(private)
JSON_FUSED_TREE_DECODE :: #config(DRUSE_JSON_FUSED_TREE_DECODE, true)

// The fused decoder and its preceding shape walk used to resolve the same
// struct key independently: validation scanned tags twice (known + unknown)
// and the destination write scanned them a third time. A standalone RTTI cache
// was measured before tree fusion and rejected; it could not remove the later
// stdlib decode's lookups. This descriptor is deliberately narrower and is
// enabled only when the fused path will consume it too, so one request-local
// target table serves both validation and destination writes.
//
// Keep the private rollback alongside JSON_FUSED_TREE_DECODE until the A/B
// campaign has decided whether the integrated form clears the adoption floor.
@(private)
JSON_FUSED_TARGET_DESCRIPTORS :: #config(DRUSE_JSON_FUSED_TARGET_DESCRIPTORS, true)

@(private)
JSON_FIELD_PATH_MAX :: ERROR_NAME_ESCAPED_MAX

// JSON_NEST_DEPTH_MAX bounds structural nesting (arrays and objects) accepted
// from a request body. The pinned `core:encoding/json` validator and parser are
// both recursive-descent over this nesting and impose no depth limit of their
// own, so a small body — under the `max_body` size cap — that is nothing but
// deeply nested brackets can drive recursion until the worker thread's stack
// overflows and the whole process aborts. Real request payloads nest a handful
// of levels; this ceiling is far above any legitimate shape and only refuses
// the pathological one.
@(private)
JSON_NEST_DEPTH_MAX :: 128

// json_int_fits reports whether a JSON integer value fits the destination
// integer type, given its size in bytes and signedness. A JSON integer arrives
// as an i64, so an i64/int destination always fits and a u64/uint destination
// only needs the value to be non-negative; narrower types are bounds-checked
// against their exact range so an out-of-range value is refused rather than
// silently truncated by the authoritative decode.
// json_f64_is_finite rejects NaN and both infinities without importing
// `core:math`, which `package web` deliberately does not depend on. NaN is the
// only value unequal to itself; for either infinity `f - f` is NaN, which is
// unequal to zero. Every finite value passes both.
@(private)
json_f64_is_finite :: proc(f: f64) -> bool {
	if f != f {
		return false
	}
	return f - f == 0
}

@(private)
json_int_fits :: proc(value: i64, size: int, signed: bool) -> bool {
	switch size {
	case 1:
		return signed ? (value >= -128 && value <= 127) : (value >= 0 && value <= 255)
	case 2:
		return signed ? (value >= -32768 && value <= 32767) : (value >= 0 && value <= 65535)
	case 4:
		return signed ? (value >= -2147483648 && value <= 2147483647) : (value >= 0 && value <= 4294967295)
	case 8:
		// i64/int always fits; u64/uint receiving an i64 only needs sign.
		return signed ? true : (value >= 0)
	case:
		// An unusual integer width: do not invent a bound.
		return true
	}
}

@(private)
Json_Decode_Issue_Kind :: enum {
	None,
	Invalid_Json,
	Invalid_Field,
	Unknown_Field,
	Unsupported_Destination,
	Internal,
	// AUDIT J3/J4 — more JSON values and object keys than `max_json_nodes`
	// admits. Distinct from `Invalid_Json`: the body is well-formed and the
	// refusal is a resource decision, so it must not be reported as a syntax
	// error the client could fix by correcting its JSON.
	Too_Many_Nodes,
}

@(private)
Json_Field_Path :: struct {
	bytes: [JSON_FIELD_PATH_MAX]u8,
	len:   int,
}

@(private)
Json_Decode_Issue :: struct {
	kind: Json_Decode_Issue_Kind,
	path: Json_Field_Path,
}

@(private)
json_path_string :: proc(path: ^Json_Field_Path) -> string {
	return string(path.bytes[:path.len])
}

// json_path_push appends a decoded object key without splitting UTF-8. The
// wire renderer applies its own escaped-byte cap later, so both buffers remain
// fixed and attacker-controlled nesting cannot grow request memory.
@(private)
json_path_push :: proc(path: ^Json_Field_Path, field: string) -> int {
	old := path.len
	if old > 0 && path.len < len(path.bytes) {
		path.bytes[path.len] = '.'
		path.len += 1
	}

	i := 0
	for i < len(field) && path.len < len(path.bytes) {
		width := 1
		c := field[i]
		switch {
		case c >= 0xF0: width = 4
		case c >= 0xE0: width = 3
		case c >= 0xC0: width = 2
		}
		if i + width > len(field) || path.len + width > len(path.bytes) {
			break
		}
		copy(path.bytes[path.len:], transmute([]u8)field[i:i + width])
		path.len += width
		i += width
	}
	return old
}

@(private)
json_path_restore :: proc(path: ^Json_Field_Path, old: int) {
	path.len = old
}

// json_struct_target follows the pinned stdlib decoder's field precedence:
// explicit json tags, then ordinary field names, then flattened `using _`
// children. It returns an offset from the outer destination.
@(private)
json_struct_target :: proc(
	info: ^reflect.Type_Info,
	key: string,
	base_offset: uintptr = 0,
) -> (offset: uintptr, field_type: ^reflect.Type_Info, found: bool) {
	fields := reflect.struct_fields_zipped(info.id)
	for field in fields {
		tag, explicit := reflect.struct_tag_lookup(field.tag, "json")
		if !explicit {
			continue
		}
		name := tag
		for i in 0 ..< len(tag) {
			if tag[i] == ',' {
				name = tag[:i]
				break
			}
		}
		if name == key {
			return base_offset + field.offset, field.type, true
		}
	}
	for field in fields {
		tag := reflect.struct_tag_get(field.tag, "json")
		name := tag
		for i in 0 ..< len(tag) {
			if tag[i] == ',' {
				name = tag[:i]
				break
			}
		}
		if name == "" && field.name == key {
			return base_offset + field.offset, field.type, true
		}
	}
	for field in fields {
		if field.is_using && field.name == "_" {
			base := reflect.type_info_base(field.type)
			if _, ok := base.variant.(reflect.Type_Info_Struct); ok {
				if nested_offset, nested_type, nested_ok := json_struct_target(
					base,
					key,
					base_offset + field.offset,
				); nested_ok {
					return nested_offset, nested_type, true
				}
			}
		}
	}
	return 0, nil, false
}

@(private)
Json_Field_Target :: struct {
	name:       string,
	offset:     uintptr,
	field_type: ^reflect.Type_Info,
}

@(private)
Json_Struct_Descriptor :: struct {
	type_id: typeid,
	targets: [dynamic]Json_Field_Target,
}

@(private)
Json_Target_Cache :: struct {
	descriptors: [dynamic]Json_Struct_Descriptor,
	allocator:   mem.Allocator,
	failed:      bool,
}

@(private)
json_tag_name :: proc(tag: string) -> string {
	for i in 0 ..< len(tag) {
		if tag[i] == ',' {
			return tag[:i]
		}
	}
	return tag
}

@(private)
json_descriptor_has_name :: proc(descriptor: ^Json_Struct_Descriptor, name: string) -> bool {
	for target in descriptor.targets {
		if target.name == name {
			return true
		}
	}
	return false
}

@(private)
json_descriptor_append :: proc(
	descriptor: ^Json_Struct_Descriptor,
	name: string,
	offset: uintptr,
	field_type: ^reflect.Type_Info,
) -> bool {
	// Earlier entries win. The construction order below is the decoder's
	// precedence order, so an outer/default field cannot be displaced by a
	// flattened child and a lower-precedence duplicate is simply omitted.
	if json_descriptor_has_name(descriptor, name) {
		return true
	}
	appended, err := append(
		&descriptor.targets,
		Json_Field_Target{name = name, offset = offset, field_type = field_type},
	)
	return err == nil && appended == 1
}

@(private)
json_descriptor_collect :: proc(
	descriptor: ^Json_Struct_Descriptor,
	info: ^reflect.Type_Info,
	base_offset: uintptr = 0,
) -> bool {
	fields := reflect.struct_fields_zipped(info.id)

	// Pass 1: explicit json tags.
	for field in fields {
		tag, explicit := reflect.struct_tag_lookup(field.tag, "json")
		if !explicit {
			continue
		}
		if !json_descriptor_append(
			descriptor,
			json_tag_name(tag),
			base_offset + field.offset,
			field.type,
		) {
			return false
		}
	}

	// Pass 2: ordinary field names (no tag, or an empty tag name).
	for field in fields {
		if json_tag_name(reflect.struct_tag_get(field.tag, "json")) == "" {
			if !json_descriptor_append(
				descriptor,
				field.name,
				base_offset + field.offset,
				field.type,
			) {
				return false
			}
		}
	}

	// Pass 3: flattened `using _` children, recursively retaining their own
	// explicit/default/flattened precedence.
	for field in fields {
		if field.is_using && field.name == "_" {
			base := reflect.type_info_base(field.type)
			if _, ok := base.variant.(reflect.Type_Info_Struct); ok {
				if !json_descriptor_collect(
					descriptor,
					base,
					base_offset + field.offset,
				) {
					return false
				}
			}
		}
	}
	return true
}

@(private)
json_target_cache_lookup :: proc(
	cache: ^Json_Target_Cache,
	info: ^reflect.Type_Info,
	key: string,
) -> (offset: uintptr, field_type: ^reflect.Type_Info, found: bool) {
	info := reflect.type_info_base(info)
	descriptor_index := -1
	for descriptor, i in cache.descriptors {
		if descriptor.type_id == info.id {
			descriptor_index = i
			break
		}
	}

	if descriptor_index < 0 {
		targets, alloc_err := make(
			[dynamic]Json_Field_Target,
			0,
			len(reflect.struct_fields_zipped(info.id)),
			cache.allocator,
		)
		if alloc_err != nil {
			cache.failed = true
			return 0, nil, false
		}
		appended, append_err := append(
			&cache.descriptors,
			Json_Struct_Descriptor{type_id = info.id, targets = targets},
		)
		if append_err != nil || appended != 1 {
			cache.failed = true
			return 0, nil, false
		}
		descriptor_index = len(cache.descriptors) - 1
		if !json_descriptor_collect(&cache.descriptors[descriptor_index], info) {
			cache.failed = true
			return 0, nil, false
		}
	}

	for target in cache.descriptors[descriptor_index].targets {
		if target.name == key {
			return target.offset, target.field_type, true
		}
	}
	return 0, nil, false
}

@(private)
json_struct_resolve :: proc(
	info: ^reflect.Type_Info,
	key: string,
	cache: ^Json_Target_Cache = nil,
) -> (offset: uintptr, field_type: ^reflect.Type_Info, found: bool) {
	if cache != nil {
		return json_target_cache_lookup(cache, info, key)
	}
	return json_struct_target(info, key)
}

@(private)
Json_Tree_Decode_Result :: enum {
	Success,
	Unsupported,
	Internal,
}

// json_tree_type_supported is deliberately narrower than web.body. A false
// result means "use the existing stdlib decoder", never "reject the request".
// The depth ceiling also breaks recursive schemas such as `[]Node`.
@(private)
json_tree_type_supported :: proc(info: ^reflect.Type_Info, depth: int = 0) -> bool {
	if info == nil || depth > 64 {
		return false
	}
	if json._user_unmarshalers != nil {
		if unmarshaler, found := json._user_unmarshalers[info.id]; found && unmarshaler != nil {
			return false
		}
	}

	base_info := reflect.type_info_base(info)
	#partial switch t in base_info.variant {
	case reflect.Type_Info_Boolean:
		return base_info.id == typeid_of(bool)
	case reflect.Type_Info_Integer:
		return t.endianness == .Platform &&
		       (base_info.size == 1 || base_info.size == 2 ||
		        base_info.size == 4 || base_info.size == 8)
	case reflect.Type_Info_Float:
		return t.endianness == .Platform &&
		       (base_info.size == 4 || base_info.size == 8)
	case reflect.Type_Info_String:
		return !t.is_cstring && t.encoding == .UTF_8 && base_info.id == typeid_of(string)
	case reflect.Type_Info_Struct:
		// Raw unions have no independent fields; packed/SOA layouts require
		// layout-specific writes. Keep all three on the stdlib path.
		if .raw_union in t.flags || .packed in t.flags || t.soa_kind != .None {
			return false
		}
		for field in reflect.struct_fields_zipped(base_info.id) {
			if !json_tree_type_supported(field.type, depth + 1) {
				return false
			}
		}
		return true
	case reflect.Type_Info_Slice:
		return json_tree_type_supported(t.elem, depth + 1)
	case reflect.Type_Info_Array:
		return json_tree_type_supported(t.elem, depth + 1)
	}
	return false
}

@(private)
json_tree_assign_integer :: proc(dst: rawptr, info: ^reflect.Type_Info, value: i64) {
	t := reflect.type_info_base(info).variant.(reflect.Type_Info_Integer)
	switch info.size {
	case 1:
		if t.signed { (^i8)(dst)^ = i8(value) } else { (^u8)(dst)^ = u8(value) }
	case 2:
		if t.signed { (^i16)(dst)^ = i16(value) } else { (^u16)(dst)^ = u16(value) }
	case 4:
		if t.signed { (^i32)(dst)^ = i32(value) } else { (^u32)(dst)^ = u32(value) }
	case 8:
		if t.signed { (^i64)(dst)^ = i64(value) } else { (^u64)(dst)^ = u64(value) }
	}
}

@(private)
json_tree_assign_float :: proc(dst: rawptr, info: ^reflect.Type_Info, value: f64) {
	switch info.size {
	case 4: (^f32)(dst)^ = f32(value)
	case 8: (^f64)(dst)^ = value
	}
}

@(private)
json_tree_decode :: proc(
	value: json.Value,
	dst: rawptr,
	info: ^reflect.Type_Info,
	allocator: mem.Allocator,
	target_cache: ^Json_Target_Cache = nil,
) -> Json_Tree_Decode_Result {
	info := reflect.type_info_base(info)

	#partial switch v in value {
	case json.Null:
		mem.zero(dst, info.size)
		return .Success

	case json.Boolean:
		if _, ok := info.variant.(reflect.Type_Info_Boolean); !ok {
			return .Unsupported
		}
		(^bool)(dst)^ = bool(v)
		return .Success

	case json.Integer:
		#partial switch _ in info.variant {
		case reflect.Type_Info_Integer:
			json_tree_assign_integer(dst, info, i64(v))
			return .Success
		case reflect.Type_Info_Float:
			json_tree_assign_float(dst, info, f64(v))
			return .Success
		}
		return .Unsupported

	case json.Float:
		#partial switch _ in info.variant {
		case reflect.Type_Info_Float:
			json_tree_assign_float(dst, info, f64(v))
			return .Success
		}
		return .Unsupported

	case json.String:
		if _, ok := info.variant.(reflect.Type_Info_String); !ok {
			return .Unsupported
		}
		cloned, err := strings.clone(string(v), allocator)
		if err != nil {
			return .Internal
		}
		(^string)(dst)^ = cloned
		return .Success

	case json.Array:
		elem: ^reflect.Type_Info
		base := dst
		#partial switch t in info.variant {
		case reflect.Type_Info_Slice:
			elem = t.elem
			bytes, err := mem.alloc_bytes(t.elem.size * len(v), t.elem.align, allocator)
			if err != nil {
				return .Internal
			}
			raw := (^mem.Raw_Slice)(dst)
			raw.data = raw_data(bytes)
			raw.len = len(v)
			base = raw.data
		case reflect.Type_Info_Array:
			elem = t.elem
		case:
			return .Unsupported
		}
		for child, i in v {
			child_dst := rawptr(uintptr(base) + uintptr(i * elem.size))
			if result := json_tree_decode(child, child_dst, elem, allocator, target_cache); result != .Success {
				return result
			}
		}
		return .Success

	case json.Object:
		if _, ok := info.variant.(reflect.Type_Info_Struct); !ok {
			return .Unsupported
		}
		for key, child in v {
			offset, field_type, found := json_struct_resolve(info, key, target_cache)
			if !found {
				return target_cache != nil && target_cache.failed ? .Internal : .Unsupported
			}
			field_dst := rawptr(uintptr(dst) + offset)
			if result := json_tree_decode(child, field_dst, field_type, allocator, target_cache); result != .Success {
				return result
			}
		}
		return .Success
	}
	return .Unsupported
}

@(private)
json_issue_at :: proc(kind: Json_Decode_Issue_Kind, path: ^Json_Field_Path) -> Json_Decode_Issue {
	return Json_Decode_Issue{kind = kind, path = path^}
}

@(private)
json_destination_is_unsupported :: proc(info: ^reflect.Type_Info) -> bool {
	if reflect.is_pointer(info) || reflect.is_multi_pointer(info) || reflect.is_soa_pointer(info) {
		return true
	}
	#partial switch _ in reflect.type_info_base(info).variant {
	case reflect.Type_Info_Procedure:
		return true
	}
	return false
}

@(private)
json_struct_known_check :: proc(
	object: json.Object,
	info: ^reflect.Type_Info,
	path: ^Json_Field_Path,
	target_cache: ^Json_Target_Cache = nil,
) -> Json_Decode_Issue {
	// Validate each present key against the field the DECODER will write —
	// resolved through `json_struct_resolve`, whose descriptor and rollback
	// target share the same precedence (explicit tag, then name, then flattened
	// `using _`). The old
	// walk shape-checked every declaration in order, so a key shadowed by a
	// higher-precedence field elsewhere (J1: a later tag; J2: an outer field
	// over a flattened child) was double-validated against the wrong type.
	//
	// Keys come from a MAP, so iteration order is not the wire order and not the
	// declaration order. Returning the first failure found would let map layout
	// decide which of several invalid fields the client is told about: the same
	// body with its keys transposed would name a different field. Select the
	// LEXICOGRAPHICALLY SMALLEST failing key instead — the same rule the unknown
	// -key scan in `json_shape_check` already applies, so both halves of the
	// refusal path are stable for the same reason.
	best_key := ""
	best_issue := Json_Decode_Issue{}
	unknown := ""
	for key, child in object {
		_, winner, found := json_struct_resolve(info, key, target_cache)
		if !found {
			if target_cache != nil && target_cache.failed {
				return Json_Decode_Issue{kind = .Internal}
			}
			if unknown == "" || key < unknown {
				unknown = key
			}
			continue
		}
		old := json_path_push(path, key)
		issue := json_shape_check(child, winner, path, target_cache)
		json_path_restore(path, old)
		if issue.kind == .None {
			continue
		}
		// `Json_Decode_Issue` carries the path BY VALUE, so the winner stays
		// valid as the scan continues.
		if best_key == "" || key < best_key {
			best_key = key
			best_issue = issue
		}
	}
	if best_key != "" {
		return best_issue
	}
	if unknown != "" {
		old := json_path_push(path, unknown)
		issue := json_issue_at(.Unknown_Field, path)
		json_path_restore(path, old)
		return issue
	}
	return {}
}

@(private)
json_shape_check :: proc(
	value: json.Value,
	info: ^reflect.Type_Info,
	path: ^Json_Field_Path,
	target_cache: ^Json_Target_Cache = nil,
) -> Json_Decode_Issue {
	if info == nil {
		return json_issue_at(.Unsupported_Destination, path)
	}
	info := reflect.type_info_base(info)
	if json_destination_is_unsupported(info) {
		return json_issue_at(.Unsupported_Destination, path)
	}

	// The stdlib treats JSON null as the zero value for every destination. WP81
	// owns the distinct missing/null/value representation; WP68 preserves the
	// current decode contract until that decision is made.
	#partial switch _ in value {
	case json.Null:
		return {}
	}

	// The stdlib tries non-null union variants in declaration order. Mirror
	// that compatibility without exposing the union itself in the wire error;
	// this covers ordinary optional/Maybe shapes and json.Value.
	if union_info, ok := info.variant.(reflect.Type_Info_Union); ok {
		first_issue: Json_Decode_Issue
		for variant in union_info.variants {
			candidate_path := path^
			issue := json_shape_check(value, variant, &candidate_path, target_cache)
			if issue.kind == .None {
				return {}
			}
			if first_issue.kind == .None {
				first_issue = issue
			}
		}
		if first_issue.kind != .None {
			return first_issue
		}
		return json_issue_at(.Unsupported_Destination, path)
	}

	#partial switch v in value {
	case json.Boolean:
		if _, ok := info.variant.(reflect.Type_Info_Boolean); ok {
			return {}
		}
		return json_issue_at(.Invalid_Field, path)

	case json.Integer:
		#partial switch dst in info.variant {
		case reflect.Type_Info_Integer:
			// The preflight's contract is to classify a value that does not fit
			// the destination as invalid_field. Without this the stdlib decode
			// assigns with a truncating cast, so `{"count":999999}` into a `u8`
			// silently becomes 63 with a 200 — a field feeding a length, quota,
			// index or authorization decision then carries an attacker-chosen
			// wrapped value the application cannot detect. Range-check here.
			if !json_int_fits(i64(v), info.size, dst.signed) {
				return json_issue_at(.Invalid_Field, path)
			}
			return {}
		case reflect.Type_Info_Float, reflect.Type_Info_Complex,
		     reflect.Type_Info_Quaternion, reflect.Type_Info_Bit_Set:
			return {}
		}
		return json_issue_at(.Invalid_Field, path)

	case json.Float:
		#partial switch dst in info.variant {
		case reflect.Type_Info_Integer:
			// THE SAME RULE THE `json.Integer` ARM ENFORCES, VIA THE OTHER TOKEN.
			//
			// This arm used to accept any float for an integer destination, which
			// re-opened the exact hole the range check above exists to close:
			// `{"count":1e6}` and `{"count":999999.0}` tokenize as Float, not
			// Integer, so they skipped the bounds test, fell through to the stdlib
			// decode, and were assigned with a truncating f64->u8 cast — the
			// attacker-chosen wrapped value, answered 200. `{"count":3.7}` was
			// silently truncated to 3 by the same path.
			//
			// A JSON number written with an exponent or a `.0` fraction is still
			// an integer value, so it is accepted when it is integral AND in
			// range; a fractional value is not an integer and is refused rather
			// than rounded.
			f := f64(v)
			if !json_f64_is_finite(f) {
				return json_issue_at(.Invalid_Field, path)
			}
			// Outside i64 the conversion below is itself undefined, so bound it
			// before converting rather than after.
			if f < -9223372036854775808.0 || f >= 9223372036854775808.0 {
				return json_issue_at(.Invalid_Field, path)
			}
			n := i64(f)
			if f64(n) != f {
				return json_issue_at(.Invalid_Field, path) // fractional, not an integer
			}
			if !json_int_fits(n, info.size, dst.signed) {
				return json_issue_at(.Invalid_Field, path)
			}
			return {}
		case reflect.Type_Info_Float, reflect.Type_Info_Complex,
		     reflect.Type_Info_Quaternion:
			// A non-finite inbound value (`1e999` saturates to +Inf in the
			// tokenizer) is refused here rather than handed to the application:
			// the encoder's NUM-001 guard would turn any attempt to echo it into
			// a logged 500, so a six-byte field could drive error volume. Refusing
			// at the boundary keeps the inbound and outbound numeric contracts
			// symmetric.
			if !json_f64_is_finite(f64(v)) {
				return json_issue_at(.Invalid_Field, path)
			}
			return {}
		}
		return json_issue_at(.Invalid_Field, path)

	case json.String:
		text := string(v)
		#partial switch t in info.variant {
		case reflect.Type_Info_String, reflect.Type_Info_Rune:
			return {}
		case reflect.Type_Info_Enum:
			for name in t.names {
				if name == text {
					return {}
				}
			}
			return json_issue_at(.Invalid_Field, path)
		case reflect.Type_Info_Integer:
			// RANGE-CHECK THE QUOTED FORM TOO. This only asked "does it parse as
			// some i128", never "does it fit the destination" — so `{"small":
			// "999999"}` into a `u8` passed the preflight and was truncated by
			// the stdlib decode exactly like the bare-integer form the check
			// above was written to stop. The pinned stdlib accepts quoted
			// numerics for integer destinations (pinned by the WP68 fallback
			// contract), so this arm is reachable in production, not theoretical.
			n, ok := strconv.parse_i128(text)
			if !ok {
				return json_issue_at(.Invalid_Field, path)
			}
			if n < -9223372036854775808 || n > 9223372036854775807 {
				return json_issue_at(.Invalid_Field, path)
			}
			if !json_int_fits(i64(n), info.size, t.signed) {
				return json_issue_at(.Invalid_Field, path)
			}
			return {}
		case reflect.Type_Info_Float:
			_, ok := strconv.parse_f64(text)
			if ok {
				return {}
			}
			return json_issue_at(.Invalid_Field, path)
		}
		return json_issue_at(.Invalid_Field, path)

	case json.Array:
		elem: ^reflect.Type_Info
		capacity := -1
		#partial switch t in info.variant {
		case reflect.Type_Info_Slice:
			elem = t.elem
		case reflect.Type_Info_Dynamic_Array:
			elem = t.elem
		case reflect.Type_Info_Fixed_Capacity_Dynamic_Array:
			elem = t.elem
			capacity = t.capacity
		case reflect.Type_Info_Array:
			elem = t.elem
			capacity = t.count
		case reflect.Type_Info_Enumerated_Array:
			elem = t.elem
			capacity = t.count
		case:
			return json_issue_at(.Invalid_Field, path)
		}
		if capacity >= 0 && len(v) > capacity {
			return json_issue_at(.Invalid_Field, path)
		}
		for item in v {
			if issue := json_shape_check(item, elem, path, target_cache); issue.kind != .None {
				return issue
			}
		}
		return {}

	case json.Object:
		#partial switch t in info.variant {
		case reflect.Type_Info_Struct:
			if .raw_union in t.flags {
				return json_issue_at(.Unsupported_Destination, path)
			}

			// Validate every PRESENT key against the field the decoder would
			// write, selecting the lexicographically smallest failing key, so
			// two invalid values cannot make the selected error depend on map
			// iteration order.
			if issue := json_struct_known_check(v, info, path, target_cache); issue.kind != .None {
				return issue
			}
			return {}

		case reflect.Type_Info_Map:
			for key, child in v {
				old := json_path_push(path, key)
				issue := json_shape_check(child, t.value, path, target_cache)
				json_path_restore(path, old)
				if issue.kind != .None {
					return issue
				}
			}
			return {}

		case:
			return json_issue_at(.Invalid_Field, path)
		}
	}

	return json_issue_at(.Unsupported_Destination, path)
}

// body_json_preflight parses with the standard library into a disposable
// arena, then compares that tree with the destination RTTI. The arena is
// destroyed before the real typed decode, so the caller never owns the
// preflight tree and every failure path has one obvious cleanup point.
// json_scan_structure walks a request body once, without allocating, and
// reports how many JSON nodes it contains and how deeply it nests.
//
// TWO ANSWERS FROM ONE PASS because they guard two different failures. Depth
// guards the stack: the pinned `core:encoding/json` validator and parser are
// both recursive-descent and neither bounds its own recursion, so a body under
// `max_body` that is nothing but `[` overflows a worker thread's stack and
// aborts the process. Node count guards memory and lane time (audit J3/J4): a
// 4 MiB body of `[{},{},…]` peaked at 588 MB of RSS, and a 4 MiB body of
// 322,000 object keys held a Handler lane for 2.08 s. Both are well-formed and
// inside every limit the framework had.
//
// THE COUNT IS EXACT, and the arithmetic is worth stating because the obvious
// version is wrong on precisely the shape that matters:
//
//	every value except the root is the child of exactly one container;
//	a container holding n children carries n-1 commas;
//	so  values = commas + non-empty containers + 1.
//
// Counting containers rather than NON-EMPTY containers double-counts every
// `{}` — and the J3 shape is 1.4 million of them, so that error would land
// exactly on the body this exists to bound. A container is empty when its
// closer arrives with nothing but whitespace since its opener.
//
// Object KEYS are added on (one per `:`). They are not JSON values, so they do
// not belong in the identity above, but each is a string the tree allocates and
// hashes — and they are the entire cost J4 measured, on a body whose value
// count is otherwise unremarkable.
//
// String contents are skipped with escape tracking, so punctuation inside a
// JSON string is never miscounted — a body of `{"a":"{{{{,,,,"}` counts as the
// two nodes it is.
//
// It is called on EVERY JSON body, so it does no work per byte beyond a switch.
@(private)
json_scan_structure :: proc(raw: []u8) -> (nodes: int, max_depth: int) {
	depth := 0
	in_string := false
	escaped := false
	commas := 0
	colons := 0
	non_empty_containers := 0
	// True while nothing but whitespace has been seen since the innermost
	// container opened, which is what makes that container empty.
	fresh_container := false

	for b in raw {
		if in_string {
			if escaped {
				escaped = false
			} else if b == '\\' {
				escaped = true
			} else if b == '"' {
				in_string = false
			}
			continue
		}
		switch b {
		case '"':
			in_string = true
			fresh_container = false
		case '[', '{':
			depth += 1
			if depth > max_depth {
				max_depth = depth
			}
			fresh_container = true
		case ']', '}':
			depth -= 1
			if !fresh_container {
				non_empty_containers += 1
			}
			// The container that just closed is content of its parent, so the
			// parent is not fresh whatever it looked like before.
			fresh_container = false
		case ',':
			commas += 1
			fresh_container = false
		case ':':
			colons += 1
			fresh_container = false
		case ' ', '\t', '\r', '\n':
		// Whitespace leaves `{   }` empty.
		case:
			// A scalar byte: a digit, `-`, or a letter of true/false/null. Its
			// container has content.
			fresh_container = false
		}
	}

	return commas + non_empty_containers + 1 + colons, max_depth
}

@(private)
body_json_preflight :: proc(
	raw: []u8,
	info: ^reflect.Type_Info,
	dst: rawptr,
	ctx: ^Context,
	decoded: ^bool,
) -> Json_Decode_Issue {
	decoded^ = false
	// Reject pathological structural nesting BEFORE the recursive-descent
	// validator and parser ever see the input: neither bounds its own depth, so
	// a body of nothing but `[` overflows the stack and aborts the process. This
	// pre-scan is a single allocation-free pass that counts bracket/brace depth
	// while skipping string contents, so a `[` inside a JSON string is never
	// miscounted. A body deeper than the ceiling is a malformed request.
	//
	// AUDIT J3/J4 — the same pass also counts STRUCTURES, and the body is
	// refused below if it carries more than the lane can afford. See
	// `json_scan_structure` for the arithmetic and `max_json_nodes` for the
	// measurements that set the ceiling.
	node_count, max_depth := json_scan_structure(raw)
	if max_depth > JSON_NEST_DEPTH_MAX {
		return Json_Decode_Issue{kind = .Invalid_Json}
	}

	// Refused BEFORE the parser, which is the whole point: doing this after the
	// tree exists would bound nothing, since building the tree is the cost.
	{
		node_cap := ctx.private.limits.max_json_nodes
		// A zero here is a Context the framework built without a budget, not an
		// application choice — `web.limits` refuses a negative and an
		// application that wants no limit sets zero deliberately. The read path
		// follows `max_body`'s precedent and treats it as "no limit" rather than
		// substituting a default the caller never asked for.
		if node_cap > 0 && node_count > node_cap {
			return Json_Decode_Issue{kind = .Too_Many_Nodes}
		}
	}

	// Rollback control only. Before direct parsing shipped, this allocation-free
	// validator guarded a parser whose partial-tree cleanup consulted
	// `context.allocator`. The direct path below now binds that allocator to the
	// disposable arena for the complete parse, including every error path.
	if !JSON_DIRECT_PREFLIGHT_PARSE && !json.is_valid(raw, .JSON, true) {
		return Json_Decode_Issue{kind = .Invalid_Json}
	}

	temporary: mem.Dynamic_Arena
	mem.dynamic_arena_init(&temporary)
	defer mem.dynamic_arena_destroy(&temporary)
	temporary_allocator := mem.dynamic_arena_allocator(&temporary)

	parser := json.make_parser_from_bytes(
		raw,
		.JSON,
		true,
		temporary_allocator,
	)
	// Duplicate-key rejection is a parse-time error after syntax validation.
	// Keep the parser allocator implicit during that call as well, because the
	// pinned stdlib's error cleanup consults context.allocator for child values.
	previous_allocator := context.allocator
	context.allocator = temporary_allocator
	value, err := json.parse_value(&parser)
	context.allocator = previous_allocator
	if err != .None {
		#partial switch err {
		case .Out_Of_Memory, .Invalid_Allocator:
			return Json_Decode_Issue{kind = .Internal}
		case:
			return Json_Decode_Issue{kind = .Invalid_Json}
		}
	}
	if parser.curr_token.kind != .EOF {
		return Json_Decode_Issue{kind = .Invalid_Json}
	}

	path: Json_Field_Path
	fused_eligible :=
		JSON_FUSED_TREE_DECODE &&
		json_tree_type_supported(info)
	target_cache: Json_Target_Cache
	target_cache_ptr: ^Json_Target_Cache
	if fused_eligible && JSON_FUSED_TARGET_DESCRIPTORS {
		descriptors, cache_err := make(
			[dynamic]Json_Struct_Descriptor,
			temporary_allocator,
		)
		if cache_err != nil {
			return Json_Decode_Issue{kind = .Internal}
		}
		target_cache.descriptors = descriptors
		target_cache.allocator = temporary_allocator
		target_cache_ptr = &target_cache
	}

	issue := json_shape_check(value, info, &path, target_cache_ptr)
	if issue.kind == .Invalid_Field && issue.path.len == 0 {
		issue.path.bytes[0] = '$'
		issue.path.len = 1
	}
	if issue.kind == .None &&
	   fused_eligible {
		request_arena_init(ctx)
		switch json_tree_decode(value, dst, info, request_arena_allocator(ctx), target_cache_ptr) {
		case .Success:
			decoded^ = true
		case .Unsupported:
			// The type-level eligibility check is intentionally conservative,
			// but a value-level edge (for example a string accepted by the
			// stdlib for a numeric destination) can still require fallback.
		case .Internal:
			return Json_Decode_Issue{kind = .Internal}
		}
	}
	return issue
}

@(private)
body_unmarshal_error_is_internal :: proc(err: json.Unmarshal_Error) -> bool {
	switch e in err {
	case json.Error:
		return e == .Out_Of_Memory || e == .Invalid_Allocator
	case json.Unmarshal_Data_Error:
		return e != .Invalid_Data
	case json.Unsupported_Type_Error:
		return true
	}
	return true
}
