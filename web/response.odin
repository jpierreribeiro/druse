// WP2 — INTERNAL RESPONSE MODEL AND SINGLE-COMMIT GUARD.
//
// Nothing in this file is public. There is no public `Response` type, no
// public commit state, and no `ctx.response` field: applications respond
// exclusively through `web.json`, `web.ok`, `web.created`, `web.text`,
// `web.no_content` and the error helpers (ADR-008).
//
// WP2 delivers the STORAGE and the GUARD only. It renders nothing: no JSON
// marshalling, no error envelope, no response headers, and no automatic status
// decision. Wiring the public responders onto this primitive is WP6; automatic
// 404/405/501 belongs to WP4/WP9.
package web
// druse:file application

import "core:mem"

// Response is the package-internal response state for one request.
//
// It holds exactly what the commit guard needs to be provable: the status,
// headers and body that were committed, and the flag that says a commit
// already happened.
//
// `headers` is WP2 state rather than deferred work because WP4 depends on it.
// WP4's ratified contract includes "405-when-other-method with exact `Allow`
// header" (planning/phase-1-plan.md §WP4), and WP4 depends on WP2/WP3 — it lands BEFORE
// WP6. Without internal header storage, WP4 could not express or test its own
// contract.
//
// OWNERSHIP (amended in WP6, ADR-014). `headers` is always BORROWED: every
// header name and value is a static string, and the pair array lives in
// request-local storage on the Context. `body` is EITHER borrowed — a static
// constant such as the automatic 404 envelope, or the fixed request-local
// buffer the WP5 extractor errors use — OR owned, when a responder rendered it
// dynamically. `owned_body` says which, and `body_allocator` records who made
// the allocation so the teardown cannot disagree with the renderer about how to
// release it.
//
// WP7 may replace this with the request-lifetime arena (ADR-006) without any
// public change: neither this struct, nor the flag, nor the teardown is
// exported.
@(private)
Response :: struct {
	status:    Status,
	headers:   []Header_Pair,
	body:      []u8,
	committed: bool,

	// WP6 — true when `body` is an allocation this Response must release.
	owned_body:     bool,
	body_allocator: mem.Allocator,
}

// response_commit records a response exactly once and reports whether it did.
//
// It returns `true` when this call produced the response, and `false` when a
// response had already been produced — in which case NOTHING is modified: the
// first status, the first headers and the first body all survive verbatim.
// This is the whole of ADR-008 option A, and it is what makes "an extractor's
// error response cannot be replaced by continued handler code" a testable
// property rather than a convention.
//
// The three are recorded ATOMICALLY. A guard that blocked the status while
// letting replacement headers through would still be a double-write, so a
// rejected attempt leaves all three exactly as the first commit left them.
//
// SCOPE OF THE GUARANTEE (ADR-008). This
// prevents the SUPPORTED `web.*` response paths from overwriting a response
// that was already produced. It is NOT a security boundary: the application
// and the framework share one program, `@(private)` hides a declaration's name
// rather than the reachability of fields, and per-field privacy is a syntax
// error in Odin. Code that deliberately assigns to the fields of this struct
// bypasses the guard, and that is accepted. Designs that add indirection —
// opaque handles, side tables — to resist deliberate tampering are REJECTED as
// useless complexity.
//
// It allocates nothing, retains `headers` and `body` as views, and never
// panics.
@(private)
response_commit :: proc(res: ^Response, status: Status, headers: []Header_Pair, body: []u8) -> bool {
	if res.committed {
		return false
	}

	res.status = status
	res.headers = headers
	res.body = body
	res.committed = true
	return true
}

// response_commit_owned records a response whose body is an ALLOCATION, and
// takes ownership of it.
//
// It is the WP6 counterpart of `response_commit` (ADR-014, plan D2), and the
// two differ in exactly one respect: what happens to `body`.
//
// OWNERSHIP IS ALWAYS RESOLVED. On success the allocation belongs to the
// Response and is released by `response_destroy`. On rejection — a response was
// already committed — the allocation is FREED HERE, immediately, because the
// caller rendered it before discovering the guard would refuse it and nothing
// else can own it afterwards. Returning false while leaving the buffer to the
// caller would leak on a path a handler triggers simply by responding twice.
//
// A caller must therefore treat `body` as CONSUMED by this call in both
// outcomes, and must never read or free it afterwards.
//
// A rejected attempt leaves status, headers, body and ownership exactly as the
// first commit left them, exactly like `response_commit`.
@(private)
response_commit_owned :: proc(
	res: ^Response,
	status: Status,
	headers: []Header_Pair,
	body: []u8,
	allocator: mem.Allocator,
) -> bool {
	if res.committed {
		delete_slice(body, allocator)
		return false
	}

	res.status = status
	res.headers = headers
	res.body = body
	res.committed = true
	res.owned_body = true
	res.body_allocator = allocator
	return true
}

// response_destroy releases an owned body exactly once and returns the response
// to its zero state.
//
// WHO CALLS IT. The response DRIVER, after the response has been captured or
// written — never the handler and never `dispatch`. Today the only driver is
// `web.test_request`, which calls this after the recorder has made its own
// owned copies; the WP8 transport adapter must do the same once it exists.
// There is deliberately NO public cleanup symbol: response lifetime is
// framework business, and an application that had to remember to free a
// response would be a worse API than one that cannot see the response at all.
//
// It is IDEMPOTENT. Zeroing clears `owned_body`, so a second call frees
// nothing. `web.destroy` is specified as call-once, but a teardown that
// corrupts the heap when called twice is a worse failure than one that does
// nothing.
//
// It never frees a BORROWED body — a static constant or the fixed request-local
// envelope buffer — because `owned_body` is false for those.
@(private)
response_destroy :: proc(res: ^Response) {
	if res.owned_body {
		delete_slice(res.body, res.body_allocator)
	}
	res^ = Response{}
}

// response_reset_for_override frees an owned body and clears the commit guard so
// the FRAMEWORK — never a handler — can replace a committed response with a
// standardized error before it reaches the transport (C-04 / ADR-045).
//
// It is NOT a hole in the single-commit guard. That guard exists so a HANDLER's
// second write cannot clobber its first; a driver-side finalizer that detects an
// over-limit body is exactly the same class of action as `driver_finalize`'s 500
// for a handler that committed nothing. The re-commit that follows rebuilds its
// headers from request-local state (the request ID, `secure_headers`), so the
// replacement 500 carries them just like the driver's own 500 — this proc only
// drops the abandoned body, it does not touch that state.
@(private)
response_reset_for_override :: proc(res: ^Response) {
	if res.owned_body {
		delete_slice(res.body, res.body_allocator)
	}
	res.body = nil
	res.owned_body = false
	res.body_allocator = {}
	res.committed = false
}

// ---------------------------------------------------------------------------
// WP6 — response headers (plan D3).
//
// Phase 1 sets exactly one header kind of its own, `Content-Type`, plus the
// `Allow` that WP4 already produced for a 405. There is NO public header API and
// no content negotiation: the values below are fixed, and an application that
// needs something else is asking for a Phase-2 feature.
//
// Every name and value is a STATIC string, and the pair array they are written
// into is request-local storage on the Context. Nothing here is allocated, so
// nothing here is torn down.
// ---------------------------------------------------------------------------

// RESPONSE_HEADER_MAX is the worst case: a 405 carries `Allow` and
// `Content-Type` (2), WP60 the CORS headers (up to 4), WP23 appends `X-Request-Id`
// (1), WP49 appends three more when `secure_headers` is on (3), and corrective WP
// C2 (friction F8-2) appends up to `APP_HEADER_MAX` application-set headers.
//
// The bound is arithmetic, not headroom: the framework's own worst case (12) plus
// the application allowance (`APP_HEADER_MAX`). This array is fixed request-local
// storage; every framework writer is a compile-time-known step, and the app path
// is bounded by `APP_HEADER_MAX` with a "when full" behaviour (`set_header`
// refuses). `#assert` below keeps the framework arithmetic honest.
@(private)
FRAMEWORK_HEADER_MAX :: 12
@(private)
RESPONSE_HEADER_MAX :: FRAMEWORK_HEADER_MAX + APP_HEADER_MAX

// C2 (F8-2): the application header allowance. `set_header` writes up to this
// many pairs into request-local storage, copied so they outlive the handler.
@(private)
APP_HEADER_MAX :: 8
// The byte budget for application header names + values combined (request-local,
// no allocation). A header exceeding the remaining budget is refused.
@(private)
APP_HEADER_BUFFER :: 2048

// C2 (F8-4): the byte budget for a `web.bytes` caller's `Content-Type`, copied
// into request-local storage. Media types are short; a longer one is refused.
@(private)
CONTENT_TYPE_MAX :: 128

// The proof that the framework bound is arithmetic. If a future framework writer
// is added without raising FRAMEWORK_HEADER_MAX, this fails at COMPILE time
// rather than overflowing request-local storage at run time.
#assert(FRAMEWORK_HEADER_MAX >= 2 + 4 + 1 + 3)

@(private)
CONTENT_TYPE_HEADER_NAME :: "Content-Type"

// The exact ratified media types. `charset=utf-8` is spelled on the text type
// and NOT on the JSON one, because RFC 8259 defines JSON as UTF-8 and registers
// no charset parameter for `application/json`, while `text/plain` needs one to
// avoid a latin-1 default.
@(private)
CONTENT_TYPE_JSON :: "application/json"

@(private)
CONTENT_TYPE_TEXT :: "text/plain; charset=utf-8"

// response_json_headers returns the single `Content-Type: application/json`
// pair, written into the caller's request-local storage.
//
// The returned slice VIEWS `ctx.private.response_headers`, so it is valid
// exactly as long as the Context is — which is as long as the committed
// response is readable.
@(private)
response_json_headers :: proc(ctx: ^Context) -> []Header_Pair {
	ctx.private.response_headers[0] = Header_Pair {
		name  = CONTENT_TYPE_HEADER_NAME,
		value = CONTENT_TYPE_JSON,
	}
	return response_headers_finish(ctx, 1)
}

// response_text_headers is the `text/plain` counterpart.
@(private)
response_text_headers :: proc(ctx: ^Context) -> []Header_Pair {
	ctx.private.response_headers[0] = Header_Pair {
		name  = CONTENT_TYPE_HEADER_NAME,
		value = CONTENT_TYPE_TEXT,
	}
	return response_headers_finish(ctx, 1)
}

// response_bytes_headers is the C2 (F8-2/F8-4) counterpart for `web.bytes`: the
// `Content-Type` is the CALLER's, not a framework constant. `content_type` must
// already be a stable view (the responder copies it into request-local storage
// before calling here, so it outlives the handler like every other header value).
@(private)
response_bytes_headers :: proc(ctx: ^Context, content_type: string) -> []Header_Pair {
	ctx.private.response_headers[0] = Header_Pair {
		name  = CONTENT_TYPE_HEADER_NAME,
		value = content_type,
	}
	return response_headers_finish(ctx, 1)
}

// response_headers_finish APPENDS the framework-owned trailing headers after
// the `n` pairs the caller has already written, and returns the finished slice.
//
// Today that is exactly one header, WP23's `X-Request-Id`, present only when
// the request-ID middleware set an effective ID for this request.
//
// IT APPENDS, and the position is contract rather than taste: WP4 ratified
// `Allow` FIRST and `Content-Type` second for a 405, and a merged WP17 test
// pins both by INDEX. Seeding a header at slot 0 would renumber them and break
// a contract this work package has no business touching.
//
// EVERY response path funnels through the three builders above, so this is the
// single place the ID is attached — which is what puts it on a 404, a 405 and
// the driver's standardized 500 alike. The alternative, having the middleware
// stamp the response as the chain unwinds, would miss the 500 entirely: WP22
// measured that the driver finalizes a missing response AFTER the chain has
// unwound, and that is precisely the response an operator most wants to
// correlate.
//
// The value is a VIEW over `ctx.private.request_id_buffer`, request-local
// storage on the same Context as `allow_buffer` and for the same reason: the
// committed response holds the view and is read after `dispatch` returns.
@(private)
response_headers_finish :: proc(ctx: ^Context, n: int) -> []Header_Pair {
	count := n

	// WP49 — the security headers, attached at the SAME funnel as the request
	// ID and for the same reason: this is the one place every response path
	// passes through, so a 404, a 405 and the driver's 500 all get them.
	if ctx.private.secure_headers {
		ctx.private.response_headers[count] = Header_Pair {
			name  = SECURE_CONTENT_TYPE_OPTIONS_NAME,
			value = SECURE_CONTENT_TYPE_OPTIONS,
		}
		count += 1
		ctx.private.response_headers[count] = Header_Pair {
			name  = SECURE_FRAME_OPTIONS_NAME,
			value = SECURE_FRAME_OPTIONS,
		}
		count += 1
		ctx.private.response_headers[count] = Header_Pair {
			name  = SECURE_REFERRER_POLICY_NAME,
			value = SECURE_REFERRER_POLICY,
		}
		count += 1
	}

	// WP60 — the cross-origin headers, at the same funnel and for the same
	// reason: a browser that cannot read the 404 or the 500 shows its user a
	// blank page instead of the message the application wrote.
	count = cors_headers_append(ctx, count)

	if ctx.private.request_id_set {
		ctx.private.response_headers[count] = Header_Pair {
			name  = REQUEST_ID_HEADER,
			value = ctx.private.request_id_value,
		}
		count += 1
	}

	// C2 (F8-2) — the application's own headers, set via `web.set_header`, ride on
	// EVERY response path (json/text/bytes/error/404/405/stream) at the same funnel
	// as the framework headers. They are appended LAST so an application header can
	// never shadow a framework-owned one earlier in the list, and each is a view
	// over request-local `app_header_buffer` (copied by `set_header`, so it outlives
	// the handler). `app_header_count` is 0 unless the handler called `set_header`.
	for i in 0 ..< ctx.private.app_header_count {
		ctx.private.response_headers[count] = ctx.private.app_headers[i]
		count += 1
	}
	return ctx.private.response_headers[:count]
}

// response_allow_headers returns `Allow` FIRST and `Content-Type` second, in
// that fixed order (plan D3).
//
// The order is a property of the framework, never of anything a request can
// influence, so two deployments emit byte-identical 405 headers. `allow` is a
// view over `ctx.private.allow_buffer`, which lives on the same Context.
@(private)
response_allow_headers :: proc(ctx: ^Context, allow: string) -> []Header_Pair {
	ctx.private.response_headers[0] = Header_Pair {
		name  = ALLOW_HEADER_NAME,
		value = allow,
	}
	ctx.private.response_headers[1] = Header_Pair {
		name  = CONTENT_TYPE_HEADER_NAME,
		value = CONTENT_TYPE_JSON,
	}
	return response_headers_finish(ctx, 2)
}
