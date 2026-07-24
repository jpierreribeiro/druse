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
// uruquim:file application

import encoding_json "core:encoding/json"
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
	if err != nil || !encoding_json.is_valid(data, .JSON) {
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
no_content :: proc(ctx: ^Context) {
	response_commit(&ctx.private.response, .No_Content, nil, nil)
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
//   - the name is empty, or the name or value contains a control byte (CR, LF or
//     NUL) — the header-injection vector, rejected unconditionally;
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
	if len(name) == 0 || header_field_has_control(name) || header_field_has_control(value) {
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

// header_field_has_control reports whether a header name or value carries a byte
// that must never reach the wire unescaped: CR or LF (header/response splitting)
// or NUL. Any of them makes the field unusable, so the responder refuses it.
@(private)
header_field_has_control :: proc(s: string) -> bool {
	for b in transmute([]byte)s {
		if b == '\r' || b == '\n' || b == 0 {
			return true
		}
	}
	return false
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
