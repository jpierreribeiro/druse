// CANONICAL EXTRACTORS. Path and query extraction (WP5) and JSON body binding
// (WP7) are all implemented here.
//
// This file declares the canonical Phase-1 extractors. WP5 implements the five
// path/query extractors and the two 400 envelopes they commit on failure; WP7
// implements body binding.
//
// WHAT THIS FILE DELIBERATELY DOES NOT DO. It normalizes NOTHING and decodes
// NOTHING: no percent-decoding, no `+`-as-space, no case folding, no key or
// value trimming. `?q=a%20b` yields the literal bytes `a%20b`. A decoding
// policy interacts with transport conformance (WP9) and with the Phase-3
// normalization decision, and adopting one here would freeze it by accident.
//
// It also allocates NOTHING. Both lookups scan in place and return views over
// request-owned storage, and even the error path writes into fixed
// request-local storage on the Context (see `web/errors.odin`).
//
// There are exactly two extractor shapes and no third:
//
//	value, ok := web.path_int(ctx, "id")   // value-producing
//	if !ok { return }
//
//	input: Create_User                     // destination-filling
//	if !web.body(ctx, &input) { return }
//
// Value-producing HTTP extractors deliberately omit `#optional_ok` (ADR-002),
// so the pinned compiler rejects a call that drops `ok` with
// "Assignment count mismatch". Do not add the directive.
package web
// uruquim:file application

import encoding_json "core:encoding/json"

// parse_int_strict parses a WHOLE decimal integer, and nothing else.
//
// Package-internal. It is deliberately NOT `strconv.parse_int`: on the pinned
// toolchain that procedure defaults to base 0, which accepts `0x1f`, `0b101`
// and digit separators like `1_000`, and it reports success without consuming
// the whole string unless the caller checks the byte count. Both behaviors
// would silently widen the ratified contract — `?page=0x10` is not a number a
// caller should be able to send — so this parser accepts exactly:
//
//	an optional '-', then one or more ASCII digits, and nothing more.
//
// A leading `+`, surrounding whitespace, a decimal point, an exponent and an
// empty string are all rejected. The magnitude is accumulated in `u64` and
// bounds-checked BEFORE each multiply, so a value outside `int` is rejected
// rather than wrapped: `min(int)` has a magnitude one larger than `max(int)`,
// and accumulating into a signed `int` would overflow at exactly that value.
//
// It allocates nothing and never panics.
@(private)
parse_int_strict :: proc(s: string) -> (value: int, ok: bool) {
	if len(s) == 0 {
		return 0, false
	}

	negative := s[0] == '-'
	digits := s[1:] if negative else s
	if len(digits) == 0 {
		return 0, false
	}

	// The largest magnitude each sign can represent.
	limit := u64(max(int)) + 1 if negative else u64(max(int))

	magnitude: u64
	for i in 0 ..< len(digits) {
		c := digits[i]
		if c < '0' || c > '9' {
			return 0, false
		}

		d := u64(c - '0')
		// Checked BEFORE the multiply: `magnitude * 10 + d` would already have
		// wrapped by the time it could be compared against the limit.
		if magnitude > (limit - d) / 10 {
			return 0, false
		}
		magnitude = magnitude * 10 + d
	}

	if negative {
		if magnitude == u64(max(int)) + 1 {
			return min(int), true
		}
		return -int(magnitude), true
	}
	return int(magnitude), true
}

// path returns the value of a path parameter.
//
// The parameter is present whenever the route matched, so this extractor
// cannot fail and writes no error response.
//
// The returned string is a view valid only for the current request; copy it
// explicitly with an appropriate allocator to keep it longer.
//
// WP5: reads the single parameter WP4 captured into private Context storage.
// There is no public `ctx.params` and there will not be one (WP4 D1) — this
// procedure is the one canonical way to read a captured parameter.
//
// The name must match EXACTLY. A near-miss returns "" rather than the value of
// whichever parameter happens to be captured: silently answering a different
// question than the one asked is a worse failure than an empty result, and the
// interim dispatcher captures at most one parameter per route (D5), so there is
// no set to search.
//
// It allocates nothing and copies nothing: the result is the same view over the
// request path that `route_match` produced.
path :: proc(ctx: ^Context, name: string) -> string {
	// WP33: a linear scan over at most ROUTE_PARAM_MAX inline slots. Not a map
	// — at this size a scan is faster than a hash, and a per-request map would
	// allocate, which is the thing C-6's design exists to avoid.
	for i in 0 ..< ctx.private.param.count {
		if ctx.private.param.slot[i].name == name {
			return ctx.private.param.slot[i].value
		}
	}
	return ""
}

// path_int returns a path parameter parsed as an integer.
//
// On failure it writes the standardized `invalid_path_parameter` response
// itself and returns ok = false; the handler only returns.
//
// WP5: absent, empty, malformed and out-of-range all produce the SAME 400. See
// `error_invalid_path_parameter` for why they are not distinguished.
//
// It has no `#optional_ok` (ADR-002), so the pinned compiler rejects a call
// that drops `ok` with "Assignment count mismatch". Do not add the directive:
// three negative probes in `tests/wp5-public-surface/probes/` and a static
// checker ban exist to keep it absent.
path_int :: proc(ctx: ^Context, name: string) -> (value: int, ok: bool) {
	raw := path(ctx, name)

	parsed, parsed_ok := parse_int_strict(raw)
	if !parsed_ok {
		error_invalid_path_parameter(ctx, name)
		return 0, false
	}
	return parsed, true
}

// query returns a query-string parameter as text.
//
// This is a plain lookup: it writes no automatic error response. `found`
// reports presence.
//
// The returned string is a view valid only for the current request.
//
// WP5: a direct scan of `ctx.request.query`, which does NOT include the leading
// `?`. Pairs are separated by `&`; a pair splits at its FIRST `=`, so
// `a=b=c` yields the value `b=c`. A key with no `=` is PRESENT with an empty
// value, which is what makes `?flag` distinguishable from an absent `flag`.
// Comparison is exact and case-sensitive. When a key repeats, the first
// occurrence wins — a minimal internal rule, not an announced duplicate-key
// contract.
//
// NO MAP, and no `strings.split`. Both would allocate on the hot path of every
// request that reads a parameter, and a map would additionally have to be built
// and torn down per request to serve lookups that are almost always one or two
// keys deep. A linear scan over a short string is faster in the shapes that
// actually occur and costs nothing when no parameter is read at all.
query :: proc(ctx: ^Context, name: string) -> (value: string, found: bool) {
	q := ctx.request.query

	start := 0
	for start <= len(q) {
		end := start
		for end < len(q) && q[end] != '&' {
			end += 1
		}

		pair := q[start:end]

		separator := -1
		for i in 0 ..< len(pair) {
			if pair[i] == '=' {
				separator = i
				break
			}
		}

		if separator < 0 {
			// A bare key: present, with an empty value. The empty result is
			// taken from the end of `pair` rather than written as `""` so that
			// every value this procedure returns is a view into the request
			// query, with no special case.
			if pair == name {
				return pair[len(pair):], true
			}
		} else if pair[:separator] == name {
			return pair[separator + 1:], true
		}

		start = end + 1
	}

	return "", false
}

// query_int returns a required query parameter parsed as an integer.
//
// A missing or malformed parameter writes the standardized
// `invalid_query_parameter` response and returns ok = false.
//
// WP5: absence and malformation produce DIFFERENT messages under the same code.
// Unlike the path case, both are things the caller can actually fix, and
// "is required" versus "must be an integer" is the difference between adding a
// parameter and correcting one.
//
// It has no `#optional_ok` (ADR-002).
query_int :: proc(ctx: ^Context, name: string) -> (value: int, ok: bool) {
	raw, found := query(ctx, name)
	if !found {
		error_query_parameter_required(ctx, name)
		return 0, false
	}

	parsed, parsed_ok := parse_int_strict(raw)
	if !parsed_ok {
		error_invalid_query_parameter(ctx, name)
		return 0, false
	}
	return parsed, true
}

// query_int_or returns an optional query parameter parsed as an integer.
//
// `default_value` applies ONLY when the parameter is absent. A present but
// malformed value is a 400, never silently replaced by the default.
//
// WP5: this is the load-bearing distinction of the extractor, and the reason it
// still returns `ok`. `?limit=banana` is a mistake the caller should hear about;
// quietly serving page size 20 instead would turn a broken request into a
// successful one. Presence is decided by the KEY, so `?limit=` is present with
// an empty value and is therefore a 400 — not an absence.
//
// It has no `#optional_ok` (ADR-002). The directive is most tempting exactly
// here, because the procedure reads like a total "value or default" function;
// it is not, and the probe `discard_query_int_or_ok.odin` keeps it that way.
query_int_or :: proc(ctx: ^Context, name: string, default_value: int) -> (value: int, ok: bool) {
	raw, found := query(ctx, name)
	if !found {
		return default_value, true
	}

	parsed, parsed_ok := parse_int_strict(raw)
	if !parsed_ok {
		error_invalid_query_parameter(ctx, name)
		return 0, false
	}
	return parsed, true
}

// query_int_opt reads an OPTIONAL typed query parameter and reports its PRESENCE
// distinctly (corrective WP C3, friction F8-6). It is the reader an optional
// typed filter needs, which neither of the others is:
//
//   - `query_int` is the REQUIRED reader — it commits a 400 `'<name>' is required`
//     on absence, so merely reading an optional filter the client did not send
//     fails the whole request (the live bug F8-6 recorded);
//   - `query_int_or` does not commit on absence, but its `ok` is `true` for BOTH
//     absent (→default) and present-valid, so it cannot tell "filter with value D"
//     from "no filter".
//
// This distinguishes the three states with a `present` result:
//
//   - ABSENT — `present=false, ok=true`. No filter; nothing is committed.
//   - PRESENT and valid — `present=true, ok=true`, `value` set.
//   - PRESENT but malformed — `present=false, ok=false`. A 400 is committed: a
//     `?assignee=banana` is a mistake the caller should hear about, never silently
//     ignored. Presence is decided by the KEY, so `?assignee=` (empty value) is
//     present-but-malformed — a 400, not an absence — exactly like `query_int_or`.
//
// Canonical use:
//
//	if v, present, ok := web.query_int_opt(ctx, "assignee"); !ok {
//		return // malformed: the 400 is already committed
//	} else if present {
//		// apply the filter with `v`
//	}
//
// It has no `#optional_ok` (ADR-002): the three results are all load-bearing and
// none may be silently dropped.
query_int_opt :: proc(ctx: ^Context, name: string) -> (value: int, present: bool, ok: bool) {
	raw, found := query(ctx, name)
	if !found {
		return 0, false, true
	}

	parsed, parsed_ok := parse_int_strict(raw)
	if !parsed_ok {
		error_invalid_query_parameter(ctx, name)
		return 0, false, false
	}
	return parsed, true, true
}

// body decodes the JSON request body into a caller-owned destination.
//
// The destination form keeps ownership and storage explicit. On failure the
// extractor writes the standardized error response itself and returns false, so
// the canonical handler simply returns:
//
//	input: Create_User
//	if !web.body(ctx, &input) { return }
//
// WP7 implements it. The order of operations is normative:
//
//  1. SINGLE CONSUMER (ADR-012 A). The body is a one-use capability. The moment
//     this call begins it is marked consumed — before the limit check and
//     before the parser — so a first attempt that fails still spends it. A
//     second call decodes nothing: it logs a private diagnostic and produces a
//     500 only if no response is committed yet; a response the first call
//     already committed is left untouched. Never a double commit, no replay.
//  2. EMPTY body is invalid JSON: 400 `invalid_json`, and NO arena is created.
//  3. The 4 MiB cap is checked BEFORE the arena and BEFORE the parser. Exactly
//     `BODY_LIMIT` bytes is allowed; a strictly larger body is 413
//     `body_too_large`, again with no arena.
//  4. WP68 structurally preflights the standard parser's value against the
//     destination type. Malformed/incomplete input is `invalid_json`; a value
//     of the wrong type is `invalid_field` with a stable path; an undeclared
//     key is `unknown_field`. Unsupported destination types and allocator
//     failure remain private diagnostics answered as 500.
//  5. The authoritative typed decode runs in strict `.JSON` mode against the
//     request-lifetime arena (ADR-006), so nested strings and slices are
//     arena-owned and freed in one shot at request end.
//
// After `body` returns false, the partial content of `dst` is UNDEFINED and
// must be discarded. On success `dst` is fully populated and its nested data is
// valid until the request ends.
body :: proc(ctx: ^Context, dst: ^$T) -> bool {
	// 1. Single consumer. A second call never reaches the parser.
	if ctx.private.body_state == .Consumed {
		framework_report(T, .Body_Consumed_Twice)
		// The first response wins: only fill in a 500 if nothing is committed.
		if !ctx.private.response.committed {
			error_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)
		}
		framework_observe_request(T, ctx, .Body_Consumed_Twice)
		return false
	}
	ctx.private.body_state = .Consumed

	raw := ctx.request.body

	// 2. Empty body: invalid JSON, no arena.
	if len(raw) == 0 {
		error_commit_static(ctx, .Bad_Request, ERROR_BODY_INVALID_JSON)
		return false
	}

	// 3. The cap, before the arena and the parser. WP36 made it CONFIGURABLE:
	// the value is the one `web.limits` validated at boot and the driver copied
	// onto this Context, so both transports enforce the same number.
	//
	// A ZERO BUDGET MEANS THE DEFAULT, and that is a deliberate asymmetry with
	// the public API rather than a contradiction of it. `web.limits` REFUSES a
	// partially-filled `Limits`, so an application can never reach this line
	// with a zero it chose — the only way a zero arrives is a Context the
	// framework itself built without a budget. Reading that as "reject every
	// body" would turn a framework-internal omission into an application that
	// refuses all traffic, which is not failing closed; it is just broken. The
	// public contract refuses ambiguity; the read path is defensive.
	cap := ctx.private.limits.max_body
	if cap <= 0 {
		cap = BODY_LIMIT
	}
	if len(raw) > cap {
		error_commit_body_too_large(ctx, ctx.private.limits.max_body)
		return false
	}

	// 4. Preflight with the stdlib grammar plus the bounded WP68 field-stack
	// checker. It rejects unknown keys and classifies type errors without
	// exposing Odin type names or decoder internals.
	fused_decoded := false
	issue := body_json_preflight(
		raw,
		type_info_of(T),
		rawptr(dst),
		ctx,
		&fused_decoded,
	)
	switch issue.kind {
	case .None:
		// continue to the authoritative typed decoder below
	case .Invalid_Json:
		error_commit_static(ctx, .Bad_Request, ERROR_BODY_INVALID_JSON)
		return false
	case .Invalid_Field:
		error_invalid_body_field(ctx, json_path_string(&issue.path))
		return false
	case .Unknown_Field:
		error_unknown_body_field(ctx, json_path_string(&issue.path))
		return false
	case .Unsupported_Destination, .Internal:
		framework_report(T, .Body_Decode_Failed)
		error_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)
		framework_observe_request(T, ctx, .Body_Decode_Failed)
		return false
	}

	if fused_decoded {
		return true
	}

	// 5. Decode into the request-lifetime arena, strict JSON.
	request_arena_init(ctx)
	err := encoding_json.unmarshal(raw, dst, .JSON, request_arena_allocator(ctx))
	if err != nil {
		if !body_unmarshal_error_is_internal(err) {
			error_commit_static(ctx, .Bad_Request, ERROR_BODY_INVALID_JSON)
		} else {
			// A decoder/destination fault. Log through the typed path while the
			// response is still uncommitted (R-05), then answer 500.
			framework_report(T, .Body_Decode_Failed)
			error_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)
			framework_observe_request(T, ctx, .Body_Decode_Failed)
		}
		return false
	}

	return true
}
