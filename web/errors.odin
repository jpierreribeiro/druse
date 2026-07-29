// WP6 — ERROR RESPONDERS AND THE STANDARDIZED ENVELOPE.
//
// This file owns every error the framework produces: the five public
// responders, the two WP5 extractor envelopes, the automatic 404/405 bodies,
// and the private typed error-report path that framework-detected failures pass
// through (ADR-011).
//
// The envelope is always:
//
//	{"error": {"code": "...", "message": "...", "field": "..."}}
//
// with `field` OMITTED ENTIRELY when the error is not bound to an input field
// (AMEND-2). Only the two WP5 extractor errors carry one.
//
// Nothing here is public except the five responders themselves. There is no
// exported envelope type, no error-code enum, and no way for an application to
// construct or inspect an envelope: the ledger stays at exactly 32.
package web
// druse:file application

import encoding_json "core:encoding/json"
import "core:mem"
import "core:strings"

// The stdlib JSON import is ALIASED because this package exports a procedure
// named `json`.

// bad_request writes a standardized 400 response.
//
// The message is returned to the client VERBATIM, so it must be safe to expose:
// it is a caller-facing explanation, never an internal diagnostic.
bad_request :: proc(ctx: ^Context, message: string) {
	error_commit_message(ctx, .Bad_Request, ERROR_CODE_BAD_REQUEST, message)
}

// unauthorized writes a standardized 401 response.
unauthorized :: proc(ctx: ^Context, message: string) {
	error_commit_message(ctx, .Unauthorized, ERROR_CODE_UNAUTHORIZED, message)
}

// forbidden writes a standardized 403 response.
forbidden :: proc(ctx: ^Context, message: string) {
	error_commit_message(ctx, .Forbidden, ERROR_CODE_FORBIDDEN, message)
}

// not_found writes a standardized 404 response for the named resource.
//
// The message is composed as `Resource '<resource>' not found`, so callers pass
// the resource NAME ("user"), not a full sentence.
not_found :: proc(ctx: ^Context, resource: string) {
	if ctx.private.response.committed {
		return
	}

	message, message_ok := error_compose_not_found(resource, context.allocator)
	if !message_ok {
		error_commit_static(ctx, .Not_Found, ERROR_BODY_NOT_FOUND_GENERIC)
		return
	}
	defer delete_string(message, context.allocator)

	error_commit_message(ctx, .Not_Found, ERROR_CODE_NOT_FOUND, message)
}

// internal_error writes a standardized 500 response.
//
// It takes no message on purpose: internal failure detail is logged on the
// server, never returned to the client.
//
// Its envelope is a STATIC constant, so producing a 500 cannot itself fail and
// cannot allocate. That is what makes it usable as the terminal fallback of the
// marshal-failure path without any risk of recursion.
internal_error :: proc(ctx: ^Context) {
	error_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)
}

// ---------------------------------------------------------------------------
// WP5 — the narrow, package-private envelope machinery for the two extractor
// errors, and NOTHING else.
//
// WP5 must produce `invalid_path_parameter` and `invalid_query_parameter`
// envelopes, because an extractor that fails without responding would leave the
// client with no answer at all. WP6 then completed the picture: the public
// responders above are live, `error_commit_message` is the generic renderer,
// `Error_Envelope` is the envelope type, and the error codes are the constants
// below. Everything below is `@(private)`, so the application ledger stays at
// exactly 32.
//
// WHY THE JSON IS HAND-WRITTEN. `core:encoding/json` would escape correctly,
// but `json.marshal` ALLOCATES, and Phase 1 has no request-lifetime arena to
// free that allocation from — the arena is WP7 (ADR-006). The alternatives were
// to leak one allocation per failed extraction, or to introduce WP7's arena
// early. Both are worse than emitting the envelope directly. Hand-writing it
// also keeps the encoder out of applications that merely reach an extractor
// error: `build/check_public_api.sh` forbids the import, and the cost
// measurement in the WP5 PR records the difference.
//
// The escaper is not trusted on the strength of that reasoning. Every envelope
// this file produces is parsed back by the OFFICIAL `core:encoding/json` parser
// in strict `.JSON` mode in `tests/wp5-internal/`, including names carrying
// quotes, backslashes, control characters, multi-byte UTF-8, and lengths far
// past the buffer.
//
// LIFETIME AND OWNERSHIP. The envelope is written into
// `ctx.private.error_buffer` — request-local storage owned by the Context,
// exactly like WP4's `allow_buffer` — and the committed `body` is a VIEW over
// it. It stays valid as long as the Context does, which is precisely as long as
// the transport or the WP3 recorder needs in order to copy it out. Nothing is
// allocated and nothing needs freeing, so an unauthenticated client cannot
// drive memory growth by sending malformed parameters.
// ---------------------------------------------------------------------------

// The ratified wire codes (docs/errors.md). Clients match on these strings, so
// they are spelled once and asserted by the checker.
@(private)
ERROR_CODE_INVALID_PATH_PARAMETER :: "invalid_path_parameter"

@(private)
ERROR_CODE_INVALID_QUERY_PARAMETER :: "invalid_query_parameter"

// WP68 — strict request decoding distinguishes syntax from a value that does
// not fit the declared destination and from a key the destination does not
// declare. These are wire codes, not public Odin symbols.
@(private)
ERROR_CODE_INVALID_FIELD :: "invalid_field"

@(private)
ERROR_CODE_UNKNOWN_FIELD :: "unknown_field"

@(private)
ERROR_MESSAGE_INVALID_FIELD :: "Request field has an invalid value"

@(private)
ERROR_MESSAGE_UNKNOWN_FIELD :: "Request field is not recognized"

#assert(
	len("{\"error\":{\"code\":\"") +
	max(len(ERROR_CODE_INVALID_FIELD), len(ERROR_CODE_UNKNOWN_FIELD)) +
	len("\",\"message\":\"") +
	max(len(ERROR_MESSAGE_INVALID_FIELD), len(ERROR_MESSAGE_UNKNOWN_FIELD)) +
	len("\",\"field\":\"") + ERROR_NAME_ESCAPED_MAX + len("\"}}") <=
	ERROR_BODY_MAX,
)

// The three ratified message shapes. Each is a prefix and a suffix wrapped
// around the escaped parameter name.
@(private)
ERROR_MESSAGE_PATH_PREFIX :: "Path parameter '"

@(private)
ERROR_MESSAGE_QUERY_PREFIX :: "Query parameter '"

@(private)
ERROR_MESSAGE_INTEGER_SUFFIX :: "' must be an integer"

@(private)
ERROR_MESSAGE_REQUIRED_SUFFIX :: "' is required"

// ERROR_NAME_ESCAPED_MAX bounds how many ESCAPED bytes of a parameter name the
// envelope carries.
//
// A bound is unavoidable: the envelope goes into fixed storage, and a parameter
// name is application-supplied with no length limit. 64 bytes is far beyond any
// real name — the ratified examples are `id`, `page` and `limit` — while
// keeping the Context small.
//
// Truncation happens on an ESCAPE-UNIT boundary, never inside one: half a
// `\u00XX` sequence or half a multi-byte UTF-8 rune is not valid JSON, and
// "the envelope is always valid JSON" is the property this whole file exists to
// guarantee.
@(private)
ERROR_NAME_ESCAPED_MAX :: 64

// ERROR_BODY_MAX is the exact worst-case envelope length.
//
//	{"error":{"code":"                     18
//	invalid_query_parameter                23  (the longer of the two codes)
//	","message":"                           13
//	Query parameter '' must be an integer   37  (the longest message shell)
//	","field":"                             11
//	"}}                                      3
//	                                       ---
//	                                       105  + the name, escaped, twice
//
// The name appears in both `message` and `field`, so the budget is counted
// twice. `#assert` below re-derives the 105 from the actual constants, so a
// future edit to a message cannot silently outgrow the buffer.
@(private)
ERROR_BODY_MAX :: 105 + 2 * ERROR_NAME_ESCAPED_MAX

#assert(
	len("{\"error\":{\"code\":\"") +
	max(len(ERROR_CODE_INVALID_PATH_PARAMETER), len(ERROR_CODE_INVALID_QUERY_PARAMETER)) +
	len("\",\"message\":\"") +
	max(len(ERROR_MESSAGE_PATH_PREFIX), len(ERROR_MESSAGE_QUERY_PREFIX)) +
	max(len(ERROR_MESSAGE_INTEGER_SUFFIX), len(ERROR_MESSAGE_REQUIRED_SUFFIX)) +
	len("\",\"field\":\"") +
	len("\"}}") <=
	ERROR_BODY_MAX - 2 * ERROR_NAME_ESCAPED_MAX,
)

// error_json_unit_length reports how many bytes of `name`, starting at `i`, form
// ONE indivisible escape unit, and how many bytes that unit occupies once
// escaped.
//
// A unit is never split by truncation. There are four kinds:
//
//   - `"` and `\`      -> 1 source byte, 2 escaped bytes;
//   - a control byte   -> 1 source byte, 6 escaped bytes (`\u00XX`);
//   - a UTF-8 sequence -> 1..4 source bytes, copied verbatim;
//   - anything else    -> 1 source byte, 1 escaped byte.
//
// A multi-byte lead byte claims its continuation bytes so the sequence moves as
// one unit. A malformed lead, or a stray continuation byte, is treated as a
// single byte: this file does not repair invalid UTF-8, and a name that was not
// valid UTF-8 to begin with cannot be made valid by escaping it.
@(private)
error_json_unit_length :: proc(name: string, i: int) -> (source: int, escaped: int) {
	c := name[i]

	switch {
	case c == '"', c == '\\':
		return 1, 2
	case c < 0x20:
		return 1, 6
	case c < 0x80:
		return 1, 1
	}

	// A UTF-8 lead byte: 110xxxxx = 2, 1110xxxx = 3, 11110xxx = 4.
	width := 1
	switch {
	case c >= 0xF0:
		width = 4
	case c >= 0xE0:
		width = 3
	case c >= 0xC0:
		width = 2
	}

	// Never run past the end of the string, and never claim a byte that is not
	// a continuation byte (10xxxxxx) — a truncated or malformed sequence stays
	// as short as it actually is.
	n := 1
	for n < width && i + n < len(name) && name[i + n] & 0xC0 == 0x80 {
		n += 1
	}
	return n, n
}

// error_write_escaped_name appends `name` to `buffer` at `n`, JSON-escaped and
// bounded by ERROR_NAME_ESCAPED_MAX.
//
// It is DETERMINISTIC for a given name, which is what lets the caller emit the
// name twice — once in `message`, once in `field` — and get identical bytes both
// times without a scratch buffer.
@(private)
error_write_escaped_name :: proc(buffer: []u8, n: int, name: string) -> int {
	// A local, not a constant: the pinned compiler rejects indexing a constant
	// string ("Cannot index a constant").
	HEX := "0123456789abcdef"

	n := n
	used := 0
	i := 0

	for i < len(name) {
		source, escaped := error_json_unit_length(name, i)

		// Stop on a unit boundary rather than emitting a partial escape.
		if used + escaped > ERROR_NAME_ESCAPED_MAX {
			break
		}

		c := name[i]
		switch {
		case c == '"':
			n += copy(buffer[n:], "\\\"")
		case c == '\\':
			n += copy(buffer[n:], "\\\\")
		case c < 0x20:
			n += copy(buffer[n:], "\\u00")
			buffer[n] = HEX[c >> 4]
			buffer[n + 1] = HEX[c & 0x0F]
			n += 2
		case:
			n += copy(buffer[n:], name[i:i + source])
		}

		used += escaped
		i += source
	}

	return n
}

// error_commit_parameter builds one WP5 envelope and commits it, exactly once.
//
// THE GUARD COMES FIRST, and that ordering is load-bearing. The envelope buffer
// is shared request-local storage, and an already-committed response holds a
// VIEW over it. Writing the new envelope before consulting `response_commit`
// would overwrite the bytes of the FIRST response — which would still report
// its original status while silently serving a different body. Checking
// `committed` up front means a second failure touches nothing at all.
//
// It allocates nothing, never panics, sets no header, and produces no partial
// response: the body is complete before `response_commit` sees it.
@(private)
error_commit_parameter :: proc(
	ctx: ^Context,
	code: string,
	message_prefix: string,
	name: string,
	message_suffix: string,
) {
	if ctx.private.response.committed {
		return
	}

	buffer := ctx.private.error_buffer[:]
	n := 0

	n += copy(buffer[n:], "{\"error\":{\"code\":\"")
	n += copy(buffer[n:], code)
	n += copy(buffer[n:], "\",\"message\":\"")
	n += copy(buffer[n:], message_prefix)
	n = error_write_escaped_name(buffer, n, name)
	n += copy(buffer[n:], message_suffix)
	n += copy(buffer[n:], "\",\"field\":\"")
	n = error_write_escaped_name(buffer, n, name)
	n += copy(buffer[n:], "\"}}")

	// WP6 adds the `Content-Type`; the body itself stays on the fixed
	// request-local buffer and is therefore still BORROWED, not owned.
	response_commit(
		&ctx.private.response,
		.Bad_Request,
		response_json_headers(ctx),
		buffer[:n],
	)
}

// error_commit_field is the allocation-free WP68 renderer for a decoder
// failure tied to a field path. `field` is already a decoded, bounded path;
// the shared escaper makes it safe JSON and applies the same deterministic
// 64-byte wire bound as the Phase-1 extractor errors.
@(private)
error_commit_field :: proc(ctx: ^Context, code, message, field: string) {
	if ctx.private.response.committed {
		return
	}

	buffer := ctx.private.error_buffer[:]
	n := 0
	n += copy(buffer[n:], "{\"error\":{\"code\":\"")
	n += copy(buffer[n:], code)
	n += copy(buffer[n:], "\",\"message\":\"")
	n += copy(buffer[n:], message)
	n += copy(buffer[n:], "\",\"field\":\"")
	n = error_write_escaped_name(buffer, n, field)
	n += copy(buffer[n:], "\"}}")

	response_commit(
		&ctx.private.response,
		.Bad_Request,
		response_json_headers(ctx),
		buffer[:n],
	)
}

@(private)
error_invalid_body_field :: proc(ctx: ^Context, field: string) {
	error_commit_field(ctx, ERROR_CODE_INVALID_FIELD, ERROR_MESSAGE_INVALID_FIELD, field)
}

@(private)
error_unknown_body_field :: proc(ctx: ^Context, field: string) {
	error_commit_field(ctx, ERROR_CODE_UNKNOWN_FIELD, ERROR_MESSAGE_UNKNOWN_FIELD, field)
}

// error_invalid_path_parameter commits the 400 for a path parameter that is
// absent, empty, malformed, or outside the range of `int`.
//
// All four collapse into ONE message on purpose. Distinguishing "absent" from
// "malformed" here would describe the SERVER's routing to the client: a name
// the handler asked for but the route never captured is a programming error in
// the application, not something the caller can act on.
@(private)
error_invalid_path_parameter :: proc(ctx: ^Context, name: string) {
	error_commit_parameter(
		ctx,
		ERROR_CODE_INVALID_PATH_PARAMETER,
		ERROR_MESSAGE_PATH_PREFIX,
		name,
		ERROR_MESSAGE_INTEGER_SUFFIX,
	)
}

// error_query_parameter_required commits the 400 for a required query parameter
// that is ABSENT.
//
// It is a different message from the one below because the two are different
// problems for the caller: one says "you left it out", the other says "what you
// sent is not a number".
@(private)
error_query_parameter_required :: proc(ctx: ^Context, name: string) {
	error_commit_parameter(
		ctx,
		ERROR_CODE_INVALID_QUERY_PARAMETER,
		ERROR_MESSAGE_QUERY_PREFIX,
		name,
		ERROR_MESSAGE_REQUIRED_SUFFIX,
	)
}

// error_invalid_query_parameter commits the 400 for a query parameter that is
// PRESENT but not a valid integer.
@(private)
error_invalid_query_parameter :: proc(ctx: ^Context, name: string) {
	error_commit_parameter(
		ctx,
		ERROR_CODE_INVALID_QUERY_PARAMETER,
		ERROR_MESSAGE_QUERY_PREFIX,
		name,
		ERROR_MESSAGE_INTEGER_SUFFIX,
	)
}

// ---------------------------------------------------------------------------
// WP6 — the general envelope machinery.
//
// ONE envelope contract, THREE storage strategies, chosen by what the content
// actually needs. The shape is always the same:
//
//	{"error":{"code":"...","message":"...","field":"..."}}
//
// with `field` OMITTED ENTIRELY when no input field caused the error (AMEND-2).
//
//   - STATIC constants, for envelopes whose code and message are fixed: the
//     automatic 404 and 405, and `internal_error`. These allocate nothing and
//     cannot fail, which is what keeps `dispatch` allocation-free (a property
//     WP4 test-pinned) and keeps the JSON encoder out of applications that
//     never render a payload. Committed as BORROWED bodies.
//
//   - The FIXED request-local buffer, for the two WP5 extractor errors. Their
//     content is bounded, they are unchanged by WP6 apart from gaining a
//     `Content-Type`, and they stay off the allocator (see above in this file).
//
//   - An OWNED allocation, for envelopes carrying an arbitrary caller-supplied
//     message. Only these three helpers — `bad_request`, `unauthorized`,
//     `forbidden` — plus `not_found`'s composed message can be unbounded, so
//     only these reach the encoder.
//
// WHY THE OFFICIAL ENCODER HERE AND A HAND-ESCAPER IN WP5. The WP5 envelope
// escapes a bounded parameter NAME into fixed storage, where an allocation
// would have no owner. A WP6 message is arbitrary application text, it already
// requires an owned allocation, and correct escaping of arbitrary text is
// exactly what the official encoder exists to guarantee. Both are validated by
// the official PARSER in strict mode in `tests/wp6-internal/`.
// ---------------------------------------------------------------------------

// The ratified wire codes for the general errors (docs/errors.md). `bad_request`
// was added to the normative list by WP6 D4: the helper was ratified in WP1 and
// the original list simply omitted its code.
@(private)
ERROR_CODE_BAD_REQUEST :: "bad_request"

@(private)
ERROR_CODE_UNAUTHORIZED :: "unauthorized"

@(private)
ERROR_CODE_FORBIDDEN :: "forbidden"

@(private)
ERROR_CODE_NOT_FOUND :: "not_found"

@(private)
ERROR_CODE_METHOD_NOT_ALLOWED :: "method_not_allowed"

@(private)
ERROR_CODE_INTERNAL :: "internal_error"

// The static envelopes. Written out literally rather than assembled, so that
// what ships is exactly what was reviewed, and so that emitting one is a `copy`
// of a constant rather than a render that could fail.
//
// They are `string` constants transmuted to `[]u8` at the commit site; the bytes
// live in the binary's read-only data, so the committed view is valid for the
// whole process and is never freed.
@(private)
ERROR_BODY_NOT_FOUND_ROUTE ::
	`{"error":{"code":"not_found","message":"Route not found"}}`

@(private)
ERROR_BODY_METHOD_NOT_ALLOWED ::
	`{"error":{"code":"method_not_allowed","message":"Method not allowed"}}`

@(private)
ERROR_BODY_INTERNAL ::
	`{"error":{"code":"internal_error","message":"Internal server error"}}`

// The fallback for `not_found` when composing its message fails. Composition
// allocates, and an allocation failure must still produce a complete, valid
// envelope rather than a half-written one.
@(private)
ERROR_BODY_NOT_FOUND_GENERIC ::
	`{"error":{"code":"not_found","message":"Resource not found"}}`

// WP7 — the two body-binding envelopes are STATIC constants: their code and
// message are fixed, they carry no `field`, and emitting one is a `copy` of a
// constant that cannot fail and cannot allocate.
@(private)
ERROR_BODY_INVALID_JSON ::
	`{"error":{"code":"invalid_json","message":"Request body must be valid JSON"}}`

// The 413 envelope is built dynamically by `error_commit_body_too_large`, so it
// can report the ACTUAL configured limit rather than a constant "4 MiB" that
// lied whenever `max_body` was changed.

// The 413 status is the public `Status.Payload_Too_Large` member (corrective WP
// C1, friction F8-1). Before C1 there was no public 413 and this path cast a
// private `Status(413)`; now it names the member like every other responder.

// Error_Envelope is the wire shape for an error WITHOUT a field.
//
// There are two envelope structs rather than one with `json:",omitempty"`
// because omitempty decides on EMPTINESS, not on presence: it would also drop a
// field legitimately named "". Separate types make "this envelope has no field"
// a property of the type rather than a runtime coincidence, which is what
// AMEND-2 actually specifies.
@(private)
Error_Envelope :: struct {
	error: Error_Envelope_Body `json:"error"`,
}

@(private)
Error_Envelope_Body :: struct {
	code:    string `json:"code"`,
	message: string `json:"message"`,
}

// error_commit_static commits one of the constant envelopes as a BORROWED body.
//
// It allocates nothing and cannot fail. The `Content-Type` pair lives in
// request-local storage on the Context, so the committed header is not a view
// into a dead frame.
// error_commit_body_too_large commits the 413 envelope reporting the ACTUAL
// configured byte limit, not a hardcoded "4 MiB". The message was a static
// constant that lied whenever `max_body` was set to anything but the default;
// this builds it into the request-local error buffer with the effective limit
// formatted as an exact decimal byte count — no `core:fmt` (WP6's 37 KiB rule),
// just a digit loop. The body is BORROWED from the fixed buffer, like every
// other dynamic envelope.
@(private)
error_commit_body_too_large :: proc(ctx: ^Context, limit: int) {
	if ctx.private.response.committed {
		return
	}

	effective := limit
	if effective <= 0 {
		effective = BODY_LIMIT
	}

	buffer := ctx.private.error_buffer[:]
	n := 0
	n += copy(buffer[n:], `{"error":{"code":"body_too_large","message":"Request body exceeds the limit of `)
	n = error_write_decimal(buffer, n, effective)
	n += copy(buffer[n:], ` bytes"}}`)

	response_commit(
		&ctx.private.response,
		.Payload_Too_Large,
		response_json_headers(ctx),
		buffer[:n],
	)
}

// error_commit_body_too_many_nodes commits the 413 envelope for audit J3/J4:
// a body that is well-formed and inside `max_body`, but carries more JSON
// values and object keys than `max_json_nodes` admits.
//
// It mirrors `error_commit_body_too_large` deliberately — same status, same
// dynamic-limit construction, same borrowed buffer, no `core:fmt` (WP6's 37 KiB
// rule). The two refusals differ only in the dimension they measure, and a
// client that can act on one can act on the other.
//
// The code is `body_too_complex` rather than `body_too_large`: a client that
// retries by shrinking its BYTES has misread a refusal about STRUCTURE, and
// could shrink a 4 MiB body to 400 KiB while keeping every one of its 322,000
// keys. The message names the node count so the retry is informed.
@(private)
error_commit_body_too_many_nodes :: proc(ctx: ^Context, limit: int) {
	if ctx.private.response.committed {
		return
	}

	effective := limit
	if effective <= 0 {
		effective = JSON_NODE_LIMIT
	}

	buffer := ctx.private.error_buffer[:]
	n := 0
	n += copy(buffer[n:], `{"error":{"code":"body_too_complex","message":"Request body exceeds the limit of `)
	n = error_write_decimal(buffer, n, effective)
	n += copy(buffer[n:], ` JSON values and keys"}}`)

	response_commit(
		&ctx.private.response,
		.Payload_Too_Large,
		response_json_headers(ctx),
		buffer[:n],
	)
}

// error_write_decimal writes a non-negative int as ASCII decimal into `buffer`
// at offset `n`, returning the new offset. Allocation-free, no `core:fmt`.
@(private)
error_write_decimal :: proc(buffer: []u8, n: int, value: int) -> int {
	if value == 0 {
		if n < len(buffer) {
			buffer[n] = '0'
			return n + 1
		}
		return n
	}
	// Extract digits least-significant first into a small scratch, then emit
	// them in order. An int is at most 20 decimal digits.
	digits: [20]u8
	count := 0
	v := value
	for v > 0 && count < len(digits) {
		digits[count] = u8('0' + v % 10)
		v /= 10
		count += 1
	}
	m := n
	for i := count - 1; i >= 0 && m < len(buffer); i -= 1 {
		buffer[m] = digits[i]
		m += 1
	}
	return m
}

@(private)
error_commit_static :: proc(ctx: ^Context, status: Status, body: string) {
	if ctx.private.response.committed {
		return
	}
	response_commit(
		&ctx.private.response,
		status,
		response_json_headers(ctx),
		transmute([]u8)body,
	)
}

// error_enforce_response_size replaces an over-limit committed response with the
// standardized `internal_error` 500 BEFORE it is copied to the transport
// (C-04 / ADR-045). It runs on the SHARED response path, so `test_request` and a
// socket agree by construction (R-10).
//
// WHY 500 AND NOT A TRUNCATION. A half-sent body is a corrupt response; a 500 is
// an honest one. The application built a response larger than the operator's
// declared budget — that is the application's bug or an attacker's amplification,
// and either way the framework must not spend the memory. Replacing it here, at
// the one point the framework is about to hand the body to the transport, is what
// turns an out-of-memory that kills every in-flight request into one typed
// failure the observer sees with a route and a status.
//
// WHY IT MEASURES `len(body)` AND NOT THE WIRE. The retention C-04 measured is
// the body the framework BUILT (F-C04-1), which a HEAD suppresses on the wire but
// still allocated. Counting the built body is what makes the guard match the
// resource it protects.
//
// Zero is unbounded (the default), so an application that never sets the limit
// pays neither the branch cost past the first compare nor any behaviour change.
@(private)
error_enforce_response_size :: proc(ctx: ^Context) {
	limit := ctx.private.limits.max_response_bytes
	if limit <= 0 {
		return
	}
	res := &ctx.private.response
	// Nothing committed yet is `driver_finalize`'s concern, which authors its own
	// 500; a detached stream carries no buffered body to measure.
	if !res.committed || ctx.private.stream_detached {
		return
	}
	if len(res.body) <= limit {
		return
	}

	// Log on the server BEFORE the re-commit, the R-05 ordering every framework
	// failure keeps, then discard the abandoned body and author the 500 exactly
	// as `driver_finalize` does — the headers rebuild from request-local state,
	// so the replacement carries the request ID and `secure_headers`.
	framework_report(App, .Response_Too_Large)
	response_reset_for_override(res)
	error_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)
	framework_observe_request(App, ctx, .Response_Too_Large)
}

// error_commit_message renders an envelope carrying an arbitrary message and
// commits it as an OWNED body.
//
// The render completes BEFORE the commit is attempted, so a failed render never
// leaves a partially-owned buffer, and `response_commit_owned` either takes the
// allocation or destroys it (plan D2).
//
// If the envelope itself cannot be marshalled — which would require the encoder
// to fail on a struct of two plain strings — it falls back to the static
// `internal_error` body rather than recursing into the error path.
@(private)
error_commit_message :: proc(ctx: ^Context, status: Status, code: string, message: string) {
	if ctx.private.response.committed {
		return
	}

	envelope := Error_Envelope {
		error = Error_Envelope_Body{code = code, message = message},
	}

	data, err := encoding_json.marshal(envelope, {}, context.allocator)
	if err != nil {
		if data != nil {
			delete_slice(data, context.allocator)
		}
		error_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)
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

// error_compose_not_found builds `Resource '<resource>' not found`.
//
// The caller owns the result and releases it; the envelope renderer copies it
// while marshalling, so it does not need to outlive the commit.
@(private)
error_compose_not_found :: proc(
	resource: string,
	allocator: mem.Allocator,
) -> (
	message: string,
	ok: bool,
) {
	PREFIX :: "Resource '"
	SUFFIX :: "' not found"

	text, err := strings.concatenate([]string{PREFIX, resource, SUFFIX}, allocator)
	if err != nil {
		return "", false
	}
	return text, true
}

// ---------------------------------------------------------------------------
// The private typed framework-error report (ADR-011).
//
// Framework-detected failures pass through ONE closed, package-private event
// before anything is logged or responded. It is a closed enum plus the payload
// TYPEID — never a stored `any`, which would be exactly the untyped error
// transport ADR-011 forbids.
// ---------------------------------------------------------------------------

// Framework_Error is the closed set of framework-detected failures the
// framework reports. It grows only when a work package ratifies a new one.
//
// PUBLIC since WP20 (ADR-026): it is the `kind` field of `Framework_Event`, so
// an observer must be able to name its members. Making it public changes
// nothing about how the framework uses it — the enum was already closed, and
// the report path is unchanged — but it does mean a new member is now a PUBLIC
// surface change, which is exactly the review pressure a ratified-only growth
// rule wants.
Framework_Error :: enum {
	None,
	Response_Marshal_Failed,
	// WP7 — a request body could not be decoded for a reason that is NOT the
	// client's malformed JSON: an incompatible destination, a nil/non-pointer
	// destination, or another internal decoder failure. It becomes a 500, never
	// `invalid_json`.
	Body_Decode_Failed,
	// WP7 — `web.body` was called more than once on one request (ADR-012 A). The
	// body capability is single-use; a second call is a programming error.
	Body_Consumed_Twice,
	// WP8 — a dispatch returned with no response committed (a handler that did
	// not respond, or bare()'s no-policy). The driver finalizes it as a 500.
	No_Response_Committed,
	// WP8 — `web.serve` was given a port outside 1..65535.
	Invalid_Serve_Port,
	// WP8 — the transport could not bind/listen on the requested port.
	Serve_Listen_Failed,
	// WP17 — `web.use` was called after a route was registered, or after the
	// first dispatch; the application is rejected fail-closed (ADR-019, and the
	// ADR-023 first-dispatch sub-decision). The spec proposes this exact name
	// for the Phase-2 public observer (WP20).
	Use_After_Route,
	// C-04 / ADR-045 — a committed response body was larger than
	// `Limits.max_response_bytes`. The framework replaces it with the
	// standardized `internal_error` 500 BEFORE it is copied to the transport,
	// so an out-of-memory that would kill every in-flight request becomes one
	// typed failure an observer sees with a route and a status. Never fires when
	// `max_response_bytes` is zero (the default), which is unbounded.
	Response_Too_Large,
}

// Framework_Report is the typed event. `payload_type` is a `typeid`, so the
// report names the offending type without capturing the value — the value may
// be unmarshalable, and storing it would put an `any` on a framework path.
@(private)
Framework_Report :: struct {
	kind:         Framework_Error,
	payload_type: typeid,
}

// framework_report logs one framework failure on the SERVER, at Error level.
//
// It never writes to the response and never allocates on its own: producing the
// response is the caller's next step, and keeping the two separate is what lets
// the caller guarantee the log happens BEFORE the commit (R-05).
//
// It uses `context.logger`. Phase 1 introduces no public logger, no observer and
// no middleware: an application that installs no logger simply gets no output,
// because `core:log` no-ops on a nil logger procedure.
//
// WHY IT DOES NOT IMPORT `core:log`, and this is a MEASURED cost decision.
//
// `core:log` reaches `core:os`, `core:strconv` and the terminal-detection code.
// Odin links an imported package whether or not anything references it, so a
// single `import "core:log"` anywhere in `web/` costs every application the
// whole tree. Measured on 819fdc7, on a consumer that only calls
// `app`/`destroy`/`serve` and never responds at all:
//
//	with    import "core:log":  84,584 bytes
//	without import "core:log":  47,768 bytes   (+36,816 for an unused feature)
//
// Making this procedure parametric was tried first and did NOT help, precisely
// because the cost is the import rather than the reference. So the framework
// talks to `context.logger` directly: the logger lives in the implicit context,
// its type comes from `base:runtime`, and reaching it needs no import at all.
//
// THE PRICE, stated plainly: the message is a STATIC string, because formatting
// the payload type would pull in `core:fmt` and reintroduce the same problem.
// The concrete type is therefore carried in the typed REPORT rather than in the
// text. That is the right split anyway — ADR-011 already assigns rich,
// structured error observation to a Phase-2 typed observer, and this keeps
// Phase 1's diagnostic free for applications that never render JSON.
//
// `T` binds the payload type into the typed report as a `typeid`. The report
// stores NO `any`: capturing the value would put untyped error transport on a
// framework path (ADR-011 forbids it), and the value may be exactly the thing
// that could not be marshalled.
//
// An application that installs no logger gets no output: `context.logger`
// carries a nil procedure by default, and this checks for it.
//
// The message text is deliberately stable — `tests/wp6-internal/` matches on a
// substring of it to tell the framework's own diagnostic apart from the test
// runner's records.
@(private)
FRAMEWORK_MESSAGE_MARSHAL_FAILED ::
	"druse: response payload could not be serialized; Phase 1 accepts " +
	"concrete values only, not pointers or procedures (ADR-003). Responding 500."

@(private)
FRAMEWORK_MESSAGE_BODY_DECODE_FAILED ::
	"druse: request body could not be decoded into the destination type; " +
	"the JSON is valid but does not fit it, or the destination is invalid. " +
	"Responding 500."

@(private)
FRAMEWORK_MESSAGE_BODY_CONSUMED_TWICE ::
	"druse: web.body was called more than once on one request; the body is a " +
	"single-use capability (ADR-012). The second call decodes nothing."

@(private)
FRAMEWORK_MESSAGE_NO_RESPONSE ::
	"druse: a handler returned without producing a response; the driver is " +
	"sending 500. A handler must call a web.* responder, or the route is a bare() miss."

@(private)
FRAMEWORK_MESSAGE_INVALID_PORT ::
	"druse: web.serve was given a port outside 1..65535; not binding."

@(private)
FRAMEWORK_MESSAGE_LISTEN_FAILED ::
	"druse: web.serve could not bind/listen on the requested port; returning."

// The owner-approved ADR-019 diagnostic (planning/phase-2-spec.md §5),
// verbatim. The `use()` call site additionally appends the count of
// already-registered routes and the first unprotectable pattern through a
// fixed buffer (web/middleware.odin) — never through `core:fmt`.
@(private)
FRAMEWORK_MESSAGE_USE_AFTER_ROUTE ::
	"druse: web.use was called after a route was already registered; " +
	"ordered middleware cannot protect routes registered before it (ADR-019). " +
	"Register every web.use before the first web.get/post/put/patch/delete/mount. " +
	"This application is rejected fail-closed: every request will answer 500 " +
	"and web.serve will refuse to start."

// The WP18 members of the fail-closed family (ADR-019/ADR-024). Each is a
// compile-time constant emitted through `context.logger` directly, like every
// framework diagnostic — no `core:fmt`, no `core:log` (the WP6 measured rule).

@(private)
FRAMEWORK_MESSAGE_MOUNT_POISONED_ROUTER ::
	"druse: web.mount was given a Router that was already rejected " +
	"fail-closed (ADR-019); the application inherits the rejection, because a " +
	"mis-ordered router must not become a healthy application. Fix the " +
	"Router's registration order — every web.use before its first route — and " +
	"mount it again. This application is rejected fail-closed: every request " +
	"will answer 500 and web.serve will refuse to start."

@(private)
FRAMEWORK_MESSAGE_MOUNT_CLOSED_ROUTER ::
	"druse: web.mount was given a Router that was already mounted; mount " +
	"closes the router (ADR-019/ADR-024). Build a separate Router value for " +
	"each mount. This application is rejected fail-closed: every request will " +
	"answer 500 and web.serve will refuse to start."

@(private)
FRAMEWORK_MESSAGE_ROUTER_CLOSED ::
	"druse: a route or middleware was registered on a Router after web.mount " +
	"had already copied it; mount closes the router (ADR-019/ADR-024), so the " +
	"late registration could never serve. Register everything on a Router " +
	"before mounting it. This Router is rejected fail-closed: every request " +
	"dispatched to it directly will answer 500."

// WP18 Amendment 1 — the fail-closed member for a mount that could not
// allocate. Odin's `append` does NOT panic when it runs out of memory: it
// returns `num_appended = 0` and reports through `#optional_allocator_error`.
// Discarding that made routes disappear with no diagnostic while the
// application still looked healthy, which is fail-OPEN — the exact failure
// ADR-019 exists to refuse. The application is now rejected instead.
@(private)
FRAMEWORK_MESSAGE_MOUNT_ALLOCATION_FAILED ::
	"druse: web.mount could not allocate storage for the routes it was " +
	"copying, so the application would have served only part of the Router. " +
	"Registration allocates from context.allocator; a bounded allocator that " +
	"runs out here would otherwise drop routes SILENTLY and answer 404 for " +
	"them. This application is rejected fail-closed: every request will " +
	"answer 500 and web.serve will refuse to start."

@(private)
FRAMEWORK_MESSAGE_MOUNT_INVALID_PREFIX ::
	"druse: web.mount was given an invalid prefix; a prefix must begin with " +
	"'/' and must not end with '/', and nothing is normalised (ADR-024, WP4 " +
	"D5). This application is rejected fail-closed: every request will answer " +
	"500 and web.serve will refuse to start."

// The ADR-023 member of the same fail-closed family: `use()` after the first
// dispatch. There is no pattern to name — the offence is temporal.
@(private)
FRAMEWORK_MESSAGE_USE_AFTER_DISPATCH ::
	"druse: web.use was called after the application had already dispatched " +
	"a request; the middleware set must be complete before the first dispatch " +
	"(ADR-019/ADR-023). Register every web.use before the first registration " +
	"or request. This application is rejected fail-closed: every request will " +
	"answer 500 and web.serve will refuse to start."

// WP30 — the registration-conflict member of the same fail-closed family.
//
// WHY IT ADDS NO `Framework_Error` MEMBER, decided under the ADR-029
// delegation. The WP18 family — `mount_poison`, `mount_poison_prefix`,
// `router_poison_closed` — poisons with a static diagnostic and NO enum member,
// because the enum names failures that reach an OBSERVER, and an observer is
// registered on an App that is already rejected: `serve` refuses to start and
// every dispatch answers 500 through `mw_poison_intercept`, which reports
// `.Use_After_Route` for the whole poisoned family already. `Framework_Error`
// is a public enum pinned byte-for-byte by the freeze snapshot, so growing it
// is a signature amendment; spending one for a failure no observer can be alive
// to see would buy nothing and cost the ledger. A conflict therefore joins the
// WP18 family exactly as it stands. Reversible in the cheap direction: adding
// the member later is an amendment, removing one would be a break.
//
// The offending route is appended by `route_conflict_poison` through a fixed
// buffer — never `core:fmt` — exactly like the invalid-prefix diagnostic.
@(private)
FRAMEWORK_MESSAGE_ROUTE_CONFLICT ::
	"druse: two routes were registered for the same method and the same path " +
	"shape, so the second could never serve — the first already owns that slot " +
	"and first registration wins. PARAMETER NAMES DO NOT DISTINGUISH ROUTES: " +
	"\"/users/:id\" and \"/users/:uid\" are the same pattern to the router, and " +
	"a prefix given to web.mount can compose one that collides with a route " +
	"registered directly. Remove the duplicate registration, or change the path. " +
	"This application is rejected fail-closed: every request will answer 500 " +
	"and web.serve will refuse to start."

// WP37 — the ADR-004 AMEND-1 member of the fail-closed family: a nil state.
//
// Registration rejects nil rather than storing it, on the same reasoning the
// rest of this family uses: an App that accepted nil here would abort inside
// the first request instead — the same failure, discovered later, by a client.
@(private)
FRAMEWORK_MESSAGE_NIL_STATE ::
	"druse: web.app_with_state was given a nil state pointer; the application " +
	"would abort on the first handler that called web.state (ADR-004, AMEND-1). " +
	"Create the state value first and pass its address. This application is " +
	"rejected fail-closed: every request will answer 500 and web.serve will " +
	"refuse to start."

// The two `web.state` refusals (Phase-1 freeze Amendment 39). They are LOG
// messages, not fail-closed poisons and not `Framework_Error` members: after
// the `(^T, bool)` change the framework has not failed when either fires — it
// answered the question in the return value, and the application owns what
// happens next. They exist so a caller who ignores `ok` still gets a sentence
// naming the mistake instead of a bare segfault.
@(private)
FRAMEWORK_MESSAGE_STATE_UNREGISTERED ::
	"druse: web.state was called on an application built with web.app() or " +
	"web.bare(); only web.app_with_state registers state (ADR-004). It returned " +
	"(nil, false) rather than aborting the process; the handler must check the " +
	"second result before using the first."

@(private)
FRAMEWORK_MESSAGE_STATE_TYPE_MISMATCH ::
	"druse: web.state was asked for a type other than the one registered with " +
	"web.app_with_state; the requested and registered types must match exactly " +
	"(ADR-004, AMEND-1). It returned (nil, false) rather than aborting the " +
	"process; the handler must check the second result before using the first."

// WP36 — the two limits members of the fail-closed family.
//
// Neither adds a `Framework_Error` member, for the WP30 reason: the enum names
// failures that reach an OBSERVER, and an observer cannot be alive to see a
// boot-time rejection.
@(private)
FRAMEWORK_MESSAGE_LIMITS_AFTER_DISPATCH ::
	"druse: web.limits was called after the application had already dispatched " +
	"a request; the byte budget is read on the request path, so changing it " +
	"while serving would make two clients get two different answers to the same " +
	"body. Set every limit before the first request. This application is " +
	"rejected fail-closed: every request will answer 500 and web.serve will " +
	"refuse to start."

@(private)
FRAMEWORK_MESSAGE_LIMITS_INVALID ::
	"druse: web.limits was given a zero or negative budget; a Limits value " +
	"must set every field, because there is no unset state to tell a forgotten " +
	"field apart from a deliberate one. Start from web.DEFAULT_LIMITS and " +
	"change what you mean to change. This application is rejected fail-closed: " +
	"every request will answer 500 and web.serve will refuse to start."

// WP48 — an unusable trusted-proxy set.
@(private)
FRAMEWORK_MESSAGE_TRUST_INVALID ::
	"druse: web.trust_proxies was given more prefixes than the framework " +
	"stores, or an EMPTY prefix. An empty prefix matches every peer, which " +
	"would trust the whole internet through a typo, and a dropped entry would " +
	"leave your configuration quietly untrue. Trusting a proxy decides whose " +
	"X-Forwarded-For is believed, so it fails closed rather than partially. " +
	"This application is rejected fail-closed: every request will answer 500 " +
	"and web.serve will refuse to start."

// WP47 — a reservation that swallows its own budget.
@(private)
FRAMEWORK_MESSAGE_LIMITS_RESERVATION ::
	"druse: web.limits was given a connection reservation at least as large " +
	"as the connection limit, so admission would refuse every connection while " +
	"looking like a working configuration. The reservation is slots held back " +
	"for shutdown, not the budget itself: reserved_conns must be smaller than " +
	"max_connections. This application is rejected fail-closed: every request " +
	"will answer 500 and web.serve will refuse to start."

@(private)
framework_report :: proc($T: typeid, kind: Framework_Error, loc := #caller_location) {
	report := Framework_Report {
		kind         = kind,
		payload_type = T,
	}

	logger := context.logger
	if logger.procedure == nil {
		return
	}

	message: string
	switch report.kind {
	case .None:
		return
	case .Response_Marshal_Failed:
		message = FRAMEWORK_MESSAGE_MARSHAL_FAILED
	case .Body_Decode_Failed:
		message = FRAMEWORK_MESSAGE_BODY_DECODE_FAILED
	case .Body_Consumed_Twice:
		message = FRAMEWORK_MESSAGE_BODY_CONSUMED_TWICE
	case .No_Response_Committed:
		message = FRAMEWORK_MESSAGE_NO_RESPONSE
	case .Invalid_Serve_Port:
		message = FRAMEWORK_MESSAGE_INVALID_PORT
	case .Serve_Listen_Failed:
		message = FRAMEWORK_MESSAGE_LISTEN_FAILED
	case .Use_After_Route:
		message = FRAMEWORK_MESSAGE_USE_AFTER_ROUTE
	case .Response_Too_Large:
		message = FRAMEWORK_MESSAGE_RESPONSE_TOO_LARGE
	}

	logger.procedure(logger.data, .Error, message, logger.options, loc)
}

// C-04 / ADR-045 — a response body larger than `Limits.max_response_bytes`. It
// is the write-side mirror of the 413 for an oversized request body, but a 500
// rather than a 4xx: the client did nothing wrong, the application built a
// response the operator's declared budget refuses, and the framework replaces it
// before spending the memory. The message names no bytes — the size is a
// property of the response, and the typed observer carries the route and status.
@(private)
FRAMEWORK_MESSAGE_RESPONSE_TOO_LARGE ::
	"druse: a handler built a response larger than Limits.max_response_bytes, " +
	"so the framework replaced it with a 500 before copying it to the transport. " +
	"A response is buffered whole (ADR-014), and its construction plus an " +
	"in-flight send can hold multiple body-sized allocations. An unbounded one " +
	"can exhaust the process and kill every in-flight request. " +
	"Lower the response size, raise max_response_bytes, or stream large output " +
	"with web.stream."

// WP60 — the three cross-origin members of the fail-closed family.
//
// A CORS misconfiguration is not an error the server notices. It is a policy
// that works perfectly and quietly shares one origin's authenticated data with
// another, so it is refused at BOOT, where somebody is watching, rather than
// discovered later by whoever finds it first.
@(private)
FRAMEWORK_MESSAGE_CORS_AFTER_DISPATCH ::
	"druse: web.cors was called after the application had already dispatched " +
	"a request; the policy is read on the request path, so changing it while " +
	"serving would let two clients get two different answers about who may " +
	"read a response. Set the policy before the first request. This " +
	"application is rejected fail-closed: every request will answer 500 and " +
	"web.serve will refuse to start."

@(private)
FRAMEWORK_MESSAGE_CORS_INVALID ::
	"druse: web.cors was given an empty origin list, an empty origin, a " +
	"negative max_age, or more origins than the framework stores. An " +
	"allow-list that allows nothing is an unfinished policy rather than a " +
	"restrictive one, and a dropped entry would leave your configuration " +
	"quietly untrue. This application is rejected fail-closed: every request " +
	"will answer 500 and web.serve will refuse to start."

@(private)
FRAMEWORK_MESSAGE_CORS_WILDCARD ::
	"druse: web.cors was given a wildcard that cannot mean what it looks " +
	"like. `*` with credentials = true is refused by every browser, and the " +
	"obvious workaround — echoing whatever Origin arrives — shares " +
	"authenticated data with whichever site asks. `*` alongside named origins " +
	"reads as 'these, and also everyone', which is everyone. `*` in headers " +
	"with credentials does NOT cover Authorization in the Fetch standard, so " +
	"it permits less than it appears to. Name the origins you mean, or drop " +
	"credentials. This application is rejected fail-closed: every request will " +
	"answer 500 and web.serve will refuse to start."

// cors_poison rejects the application with a static diagnostic, reusing the
// WP17/WP18 mechanism exactly as `limits_poison` does.
@(private)
cors_poison :: proc(a: ^App, message: string, loc := #caller_location) {
	a.private.poisoned = true

	logger := context.logger
	if logger.procedure == nil {
		return
	}
	logger.procedure(logger.data, .Error, message, logger.options, loc)
}

// WP61 — the two static-mount members of the fail-closed family.
@(private)
FRAMEWORK_MESSAGE_STATIC_AFTER_DISPATCH ::
	"druse: web.static was called after the application had already " +
	"dispatched a request; a mount owns a path prefix, so adding one while " +
	"serving would change what a path means between two requests. Mount every " +
	"directory before the first request. This application is rejected " +
	"fail-closed: every request will answer 500 and web.serve will refuse to " +
	"start."

@(private)
FRAMEWORK_MESSAGE_STATIC_INVALID ::
	"druse: web.static was given a prefix that is not absolute, a prefix " +
	"ending in a slash, an empty directory, a negative max_file_size, or more " +
	"mounts than the framework stores. A mount that silently does not work is " +
	"a 404 nobody traces back to a typo, and one that silently works on the " +
	"wrong directory is worse. This application is rejected fail-closed: " +
	"every request will answer 500 and web.serve will refuse to start."

@(private)
static_poison :: proc(a: ^App, message: string, loc := #caller_location) {
	a.private.poisoned = true

	logger := context.logger
	if logger.procedure == nil {
		return
	}
	logger.procedure(logger.data, .Error, message, logger.options, loc)
}
