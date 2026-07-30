// WP6 — SUCCESS RESPONDERS. JSON and text rendering, and the public status type.
//
// Rendering completes BEFORE anything is committed (R-05). That ordering is the
// whole reason a marshal failure can still produce a clean 500: nothing has been
// written when the failure is discovered, so the error path is free to commit a
// fresh envelope rather than patch a half-sent response.
//
// Bodies rendered here are OWNED by the internal `Response` (ADR-014) and are
// released by `response_destroy`, which the response driver calls after the
// response has been captured or written. See `web/response.odin`.
package web
// druse:file application

import encoding_json "core:encoding/json"
import "core:reflect"
import "core:mem"

// The stdlib import is ALIASED because this package exports a procedure named
// `json`. Without the alias the two collide — the same failure experiment 02
// recorded and had to work around.

// Status is the HTTP status enumeration used by the public response helpers.
//
// It exists because the ratified `json(ctx, status, value)` and
// `text(ctx, status, s)` signatures require a status type. Phase 1 named only the
// statuses its public documentation and default-policy contract used; the
// corrective WP C1 (friction F8-1) adds the operationally-essential codes that
// three independent applications were forced to spell as raw-int casts. These are
// ADDITIVE: no existing member moves, and an enum addition does not break a
// `case` match on the current members.
Status :: enum int {
	OK                    = 200,
	Created               = 201,
	Accepted              = 202,
	No_Content            = 204,
	Bad_Request           = 400,
	Unauthorized          = 401,
	Forbidden             = 403,
	Not_Found             = 404,
	Method_Not_Allowed    = 405,
	Conflict              = 409,
	Payload_Too_Large     = 413,
	Too_Many_Requests     = 429,
	Internal_Server_Error = 500,
	Service_Unavailable   = 503,
}

// The per-type validation gate, behind a build flag until it is adopted.
//
// The second pass over every marshalled body exists to catch ONE condition — a
// non-finite float — which is a property of the TYPE. The recorded reasoning
// (below, at the call site) says a compile-time walk cannot express this on the
// pinned toolchain, which is true: `base:intrinsics` resolves a field type only
// by name. What it did not consider is a RUNTIME walk done ONCE PER TYPE:
// `@(static)` inside a parametric procedure gives each instantiation its own
// slot — verified on the pinned toolchain — so the answer costs one integer
// test per request after the first, with no map and no per-request reflection.
//
// That is a different object from the RTTI cache the JSON study measured and
// rejected: that one cached field metadata per request on the decode path and
// cost p99 +17.8%. This caches one integer per type for the life of the process.
@(private) JSON_TYPE_GATE :: #config(DRUSE_JSON_TYPE_GATE, false)
@(private) JSON_FLOAT_WALK_MAX_DEPTH :: 32

// json_type_may_hold_float answers whether a value of `id` can reach the
// marshaller carrying a float. Only a float makes the pinned marshaller emit a
// bare `NaN` or `Inf`, so a type that cannot hold one cannot produce invalid
// JSON and its output does not need re-parsing.
//
// The walk is CONSERVATIVE: anything unrecognised answers `true` and keeps the
// check. A wrong `false` puts invalid JSON on the wire, which is the single
// outcome this mechanism exists to prevent, so every uncertain case pays the
// pass. `any`, procedures and raw pointers are unrecognised by construction —
// their contents are not knowable from the type.
//
// Depth is bounded because a self-referential type would recurse forever;
// reaching the bound answers `true`.
@(private)
json_type_may_hold_float :: proc(id: typeid, depth := 0) -> bool {
	if depth > JSON_FLOAT_WALK_MAX_DEPTH {
		return true
	}
	info := reflect.type_info_base(type_info_of(id))
	if info == nil {
		return true
	}

	#partial switch variant in info.variant {
	case reflect.Type_Info_Float, reflect.Type_Info_Complex, reflect.Type_Info_Quaternion:
		return true
	case reflect.Type_Info_Integer, reflect.Type_Info_Boolean, reflect.Type_Info_String,
	     reflect.Type_Info_Rune, reflect.Type_Info_Enum, reflect.Type_Info_Bit_Set:
		return false
	case reflect.Type_Info_Struct:
		for index in 0 ..< int(variant.field_count) {
			if json_type_may_hold_float(variant.types[index].id, depth + 1) {
				return true
			}
		}
		return false
	case reflect.Type_Info_Array:
		return json_type_may_hold_float(variant.elem.id, depth + 1)
	case reflect.Type_Info_Slice:
		return json_type_may_hold_float(variant.elem.id, depth + 1)
	case reflect.Type_Info_Dynamic_Array:
		return json_type_may_hold_float(variant.elem.id, depth + 1)
	case reflect.Type_Info_Map:
		return json_type_may_hold_float(variant.key.id, depth + 1) ||
			json_type_may_hold_float(variant.value.id, depth + 1)
	// A pointer is deliberately NOT enumerated here, so it falls through to
	// `true` and pays the pass. Following `variant.elem` would be the tighter
	// answer, but R-13 forbids web/ from reading through a pointer payload
	// until ADR-003 is amended, and a guardrail that has to distinguish
	// "inspects a pointee's TYPE" from "dereferences a pointee's VALUE" is a
	// guardrail that can be argued around. The conservative answer costs a
	// validation pass on types that hold pointers and concedes nothing: the
	// pinned marshaller does not follow pointers either, so such a field
	// cannot put a float on the wire in the first place.
	case reflect.Type_Info_Union:
		for member in variant.variants {
			if json_type_may_hold_float(member.id, depth + 1) {
				return true
			}
		}
		return false
	}
	return true
}

// json writes `value` as a JSON response with the given status.
//
// This is the single JSON renderer; `ok` and `created` are exact shorthands
// over it and never diverge from it. Phase-1 payloads are passed BY VALUE:
// `&value` and pointer-typed variables are not accepted payload forms
// (ADR-003), because the pinned marshaller rejects them with
// `Unsupported_Type`.
//
// WP6: the payload is marshalled with the official `core:encoding/json` encoder
// into an allocation the `Response` then OWNS.
//
// ORDER OF OPERATIONS, and every step of it is load-bearing:
//
//  1. If a response was already committed, return IMMEDIATELY — before
//     marshalling, before allocating, and before logging. A handler that
//     responds twice must not pay for the second render, and must not emit a
//     second diagnostic for a payload nobody will ever see.
//  2. Marshal completely. Nothing is committed while this can still fail.
//  3. On failure: release any partial buffer the encoder returned, report the
//     failure through the private typed path — which LOGS on the server, while
//     the response is still uncommitted (R-05) — and commit one complete
//     `internal_error`. Not a single byte of the rejected payload reaches the
//     client.
//  4. On success: transfer the buffer to the response with the JSON
//     `Content-Type`.
//
// PAYLOADS ARE VALUES (ADR-003, OQ-14, R-13). The pinned marshaller rejects
// pointer and procedure payloads with `Unsupported_Type`, so `&value` and
// pointer-typed variables take the step-3 path and produce a 500. This is the
// accepted Phase-1 baseline, not an oversight; adopting one-level dereference
// requires a ratified spec amendment.
json :: proc(ctx: ^Context, status: Status, value: $T) {
	if ctx.private.response.committed {
		return
	}

	data, err := encoding_json.marshal(value, {}, context.allocator)

	// NUM-001 (IEEE 754 boundary; RFC 8259 §6). The pinned marshaller writes a
	// non-finite float — `NaN`, `+Inf`, `-Inf` — as a BARE token, which is not
	// valid JSON: a strict client parser rejects it. The framework promises
	// strict JSON on the wire, so it must not emit a body it would itself
	// refuse. Validate the marshaller's own output with the same strict
	// validator the decode path trusts; an invalid body (a non-finite float is
	// the only way finite-input marshalling produces one) is treated exactly
	// like a marshal failure — a logged 500 — rather than put on the wire. The
	// cost is one allocation-free pass over the output, and it is the framework
	// verifying its own contract, not an optional nicety.
	// ROUTER AUDIT P3 (NOT TAKEN, AND WHY). This full second pass over every
	// marshalled body exists to catch one condition — a non-finite float — which
	// is a property of the TYPE, so in principle it could be answered once per
	// instantiation and skipped entirely for the float-free DTOs that dominate.
	// It cannot be written today: the gate needs a compile-time walk over `T`'s
	// fields, and the pinned toolchain's `base:intrinsics` exposes
	// `type_struct_field_count` but resolves a field type only BY NAME
	// (`type_field_type($T, $name: string)`) — there is no field-type-by-index,
	// so the recursion is not expressible. A runtime type walk is the RTTI cache
	// the JSON study already measured and REJECTED (round-trip p99 +17.8%), and a
	// byte-scan pre-filter for `N`/`I` is defeated by ordinary text. Guessing here
	// would silently disable a check that keeps invalid JSON off the wire, so the
	// cost stays until the intrinsic exists. Recorded rather than left implicit.
	json_invalid := false
	when JSON_TYPE_GATE {
		// 0 unknown, 1 validate, 2 skip. Per-instantiation, so this is one
		// integer per response type for the life of the process. Two lanes
		// racing on the first write compute the SAME value, so the race is
		// benign — neither can install a wrong answer.
		@(static) gate: int
		if gate == 0 {
			gate = json_type_may_hold_float(T) ? 1 : 2
		}
		if gate == 1 {
			json_invalid = !encoding_json.is_valid(data, .JSON)
		}
	} else {
		json_invalid = !encoding_json.is_valid(data, .JSON)
	}
	if err != nil || json_invalid {
		// The encoder may hand back a partially-filled buffer alongside the
		// error. It has no owner, so it is released here.
		if data != nil {
			delete_slice(data, context.allocator)
		}

		framework_report(T, .Response_Marshal_Failed)
		internal_error(ctx)
		// Emitted AFTER the commit, so the event's `status` is the status the
		// framework actually sent rather than a prediction (WP20).
		framework_observe_request(T, ctx, .Response_Marshal_Failed)
		return
	}

	response_commit_owned(
		&ctx.private.response,
		status,
		response_json_headers(ctx),
		data,
		context.allocator,
	)
}

// ok writes a 200 JSON response.
//
// It is exactly `json(ctx, .OK, value)` — a fixed-status shorthand with no
// extra serialization, headers, or error handling.
ok :: proc(ctx: ^Context, value: $T) {
	json(ctx, .OK, value)
}

// created writes a 201 JSON response.
//
// It is exactly `json(ctx, .Created, value)`.
created :: proc(ctx: ^Context, value: $T) {
	json(ctx, .Created, value)
}

// text writes a plain-text response with the given status.
//
// WP6: `s` is COPIED into an allocation the `Response` owns. Retaining the
// caller's string instead would dangle as soon as the caller reused its
// storage — the response is read after the handler returns, so a view into
// handler-local or request-local data is exactly the bug the ownership rules
// exist to prevent (G-05).
//
// An allocation failure leaves the response uncommitted rather than committing
// a truncated body: a partial response is worse than none, and the caller's
// handler simply returns without answering.
text :: proc(ctx: ^Context, status: Status, s: string) {
	if ctx.private.response.committed {
		return
	}

	body, err := mem.alloc_bytes(len(s), allocator = context.allocator)
	if err != nil {
		return
	}
	copy(body, s)

	response_commit_owned(
		&ctx.private.response,
		status,
		response_text_headers(ctx),
		body,
		context.allocator,
	)
}

// no_content writes a 204 response with no body.
//
// It sets NO `Content-Type`: there is no content to describe, and announcing a
// media type for an empty body would be a claim about nothing. It allocates
// nothing.
//
// ROUTER AUDIT C1 — it DOES carry the framework's trailing headers, and used not
// to. This was the one responder that passed `nil` instead of going through
// `response_headers_finish`, so a 204 left without `Access-Control-Allow-Origin`,
// without `X-Request-Id`, without the secure headers, and silently dropped every
// pair the handler had recorded with `web.set_header` — contradicting that
// procedure's documented promise to ride on whatever response is committed.
//
// The CORS case is the sharp one: 204 is the canonical success for DELETE, so a
// browser fetch against a CORS-configured app failed the origin check on exactly
// the route shape that most often answers 204, while every other status worked.
no_content :: proc(ctx: ^Context) {
	response_commit(&ctx.private.response, .No_Content, response_headers_finish(ctx, 0), nil)
}

// set_header records an APPLICATION response header, to ride on whatever response
// the handler then commits (corrective WP C2, friction F8-2). It is the public
// path applications need for `Set-Cookie`, `Cache-Control`, `Content-Disposition`,
// `Location`, and the like — the surface Phase 1 deliberately omitted.
//
// It returns `true` when the header was accepted and `false` when it was refused,
// so the caller hears about a mistake rather than a header silently vanishing. It
// refuses when:
//
//   - the response is already committed (the header list is finished and being
//     read — a header set now could never appear);
//   - the name is not a valid field-name token, or the value contains a control
//     byte — any byte outside RFC 9110 §5.5's `SP / HTAB / VCHAR / obs-text`.
//     CR and LF are the header-injection vector; the rest of C0 and DEL are
//     refused because a field value containing them is malformed and the next
//     hop is left to guess (audit H1);
//   - the name is framework- or transport-owned (`Content-Type`, `Content-Length`,
//     `Transfer-Encoding`, `Connection`, `X-Request-Id`), which the framework sets
//     itself — use `web.bytes`/`web.json`/`web.text` to choose a content type;
//   - the per-request pair budget (`APP_HEADER_MAX`) or byte budget
//     (`APP_HEADER_BUFFER`) is exhausted.
//
// The name and value are COPIED into request-local storage, so the caller may
// pass handler-local strings freely — the committed response reads its own copy
// after the handler returns. No allocation, no teardown (the `allow_buffer`
// idiom). Order is preserved and application headers are emitted AFTER every
// framework header, so a handler can never shadow a framework-owned one.
set_header :: proc(ctx: ^Context, name: string, value: string) -> bool {
	if ctx.private.response.committed {
		return false
	}
	// The NAME must be a valid HTTP field-name token (RFC 9110 §5.1): non-empty,
	// no control bytes, no separators. This is stricter than the value's control-
	// byte check on purpose — a name with a space or `:` produces a malformed
	// header line that a proxy may reparse, so an app passing untrusted input as a
	// name is rejected here rather than emitting an ambiguous header.
	if !header_name_is_token(name) {
		return false
	}
	// The VALUE may carry SP, HTAB, VCHAR and obs-text — never a control byte.
	if header_field_has_control(value) {
		return false
	}
	if header_name_is_reserved(name) {
		return false
	}
	if ctx.private.app_header_count >= APP_HEADER_MAX {
		return false
	}
	need := len(name) + len(value)
	if ctx.private.app_header_used + need > APP_HEADER_BUFFER {
		return false
	}

	buf := ctx.private.app_header_buffer[:]
	off := ctx.private.app_header_used
	copy(buf[off:], name)
	name_view := string(buf[off:off + len(name)])
	off += len(name)
	copy(buf[off:], value)
	value_view := string(buf[off:off + len(value)])
	off += len(value)

	ctx.private.app_header_used = off
	ctx.private.app_headers[ctx.private.app_header_count] = Header_Pair {
		name  = name_view,
		value = value_view,
	}
	ctx.private.app_header_count += 1
	return true
}

// bytes writes a response with a CALLER-CHOSEN media type and a raw byte body
// (corrective WP C2, friction F8-4). It is the buffered binary responder Phase 1
// omitted: `web.text` sends `text/plain` from a string and `web.json` marshals a
// value, but neither can put arbitrary bytes on the wire with a chosen type — a
// PDF, an image, a CSV export, an attachment download.
//
// `content_type` is COPIED into request-local storage (so the committed
// response's view outlives the handler) after validation: it must be non-empty,
// within `CONTENT_TYPE_MAX`, and free of control bytes (the same header-injection
// guard as `set_header`). An invalid content type is a handler programming error
// and produces a logged 500, never a corrupt header on the wire. `data` is COPIED
// into an allocation the `Response` then OWNS and releases, exactly like
// `web.text`'s body — so the caller may reuse or free `data` immediately.
bytes :: proc(ctx: ^Context, status: Status, content_type: string, data: []u8) {
	if ctx.private.response.committed {
		return
	}
	// An invalid content type is a handler programming error (it should be a
	// trusted, typically static, media type — never built from request input).
	// Answer a clean 500 rather than put a split or empty content type on the
	// wire. No diagnostic is logged: the empty-bodied 500 is the signal, and the
	// contract is "pass a valid media type".
	if len(content_type) == 0 ||
	   len(content_type) > CONTENT_TYPE_MAX ||
	   header_field_has_control(content_type) {
		internal_error(ctx)
		return
	}

	copy(ctx.private.content_type_buffer[:], content_type)
	ct_view := string(ctx.private.content_type_buffer[:len(content_type)])

	body, err := mem.alloc_bytes(len(data), allocator = context.allocator)
	if err != nil {
		return
	}
	copy(body, data)

	response_commit_owned(
		&ctx.private.response,
		status,
		response_bytes_headers(ctx, ct_view),
		body,
		context.allocator,
	)
}

// header_field_has_control reports whether a header value carries a byte that
// must never reach the wire: any byte outside RFC 9110 §5.5's
// `*( SP / HTAB / VCHAR / obs-text )`, which is bytes 0x00–0x08, 0x0A–0x1F and
// 0x7F. HTAB is legal OWS inside a value and is admitted; obs-text (0x80–0xFF)
// is legal field content and is admitted.
//
// AUDIT H1 — this used to name only CR, LF and NUL, on the reasoning that those
// are the splitting bytes. The rest of C0 is not a splitting vector, and the
// egress escape (`write_escaped_newlines`, vendor patch 17) does close CR and
// LF at the socket. What was measured is that a 0x01 in an application header
// value reached the wire byte-for-byte: this server was emitting a field value
// its own spec calls malformed, leaving the next hop to guess. The bytes an
// application can put here do not have to come from a request header — a query
// parameter, a path capture or a database column reaches this sink too, so the
// ingress refusal (vendor patch 38) does not make this check redundant.
//
// It rejects rather than escapes, because `set_header` and `bytes` already
// answer `false` for a refused header and the caller hears about the mistake.
@(private)
header_field_has_control :: proc(s: string) -> bool {
	for b in transmute([]byte)s {
		if b == '\t' {
			continue
		}
		if b < 0x20 || b == 0x7f {
			return true
		}
	}
	return false
}

// header_name_is_token reports whether `name` is a valid HTTP field-name token
// (RFC 9110 §5.1 / RFC 9110 `token` = 1*tchar). tchar excludes controls,
// whitespace and the separators `()<>@,;:\"/[]?={}`, so a name that could produce
// an ambiguous or malformed header line is rejected. Empty is not a token.
@(private)
header_name_is_token :: proc(name: string) -> bool {
	if len(name) == 0 {
		return false
	}
	for b in transmute([]byte)name {
		// tchar = "!#$%&'*+-.^_`|~" / DIGIT / ALPHA
		is_alpha := (b >= 'A' && b <= 'Z') || (b >= 'a' && b <= 'z')
		is_digit := b >= '0' && b <= '9'
		is_sym := false
		switch b {
		case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
			is_sym = true
		}
		if !(is_alpha || is_digit || is_sym) {
			return false
		}
	}
	return true
}

// header_name_is_reserved reports whether a header name is framework- or
// transport-owned and therefore not settable by an application. Case-insensitive,
// because header names are (RFC 9110 §5.1).
@(private)
header_name_is_reserved :: proc(name: string) -> bool {
	@(static, rodata)
	reserved := [?]string {
		"content-type",
		"content-length",
		"transfer-encoding",
		"connection",
		"x-request-id",
	}
	for r in reserved {
		if ascii_fold_equal(name, r) {
			return true
		}
	}
	return false
}
