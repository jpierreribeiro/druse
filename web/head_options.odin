package web
// druse:file application

// WP32b — automatic HEAD and OPTIONS.
//
// The decision is `planning/phase-3-spec.md` §2, accepted by the owner on
// 2026-07-20: automatic HEAD, automatic OPTIONS, **no 501**, and **no change to
// the `Method` enum**.
//
// HEAD WAS A DEFECT, NOT A MISSING FEATURE. `Method` is
// `{UNKNOWN, GET, POST, PUT, PATCH, DELETE}`, so `HEAD /users` mapped to
// `.UNKNOWN` and matched no route — while health checkers, proxies and
// monitoring systems send it. C-1 records that HEAD is effectively mandatory.
//
// WHY THE ENUM DOES NOT GROW. Both methods are resolved BEFORE a `Method` value
// reaches a handler, so the six-member enum stays byte-for-byte as the freeze
// gate pins it: no public symbol, no freeze amendment, and none of FINDING-D's
// two remaining concepts spent. The application never learns that a request was
// a HEAD, which is the RFC's requirement rather than a limitation — a HEAD
// response must be identical to the GET response except for the body, and a
// handler able to tell them apart could violate that.

// Implicit_Method records a method the framework answers on the application's
// behalf.
//
// It lives in `Context_Internal` rather than on `Request`, because `Request` is
// public and this is not a concept an application is asked to hold.
@(private)
Implicit_Method :: enum u8 {
	None,
	Head,
	Options,
}

// implicit_from_token classifies the raw method token and reports the `Method`
// the rest of the pipeline should see.
//
// HEAD becomes GET for every downstream purpose — matching, the `Allow` value,
// the middleware chain and the handler. OPTIONS keeps whatever
// `method_from_token` made of it (`.UNKNOWN`), because it never reaches a route
// at all: `dispatch` answers it before lookup.
@(private)
implicit_from_token :: proc(token: string) -> (method: Method, implicit: Implicit_Method) {
	switch token {
	case "HEAD":
		return .GET, .Head
	case "OPTIONS":
		return method_from_token(token), .Options
	}
	return method_from_token(token), .None
}

// options_answer commits the automatic OPTIONS response, and reports whether it
// did.
//
// It answers `204 No Content` with an `Allow` header built by THE SAME
// machinery a 405 uses — `allow_value` into the request-local buffer, then
// `response_allow_headers`. There is no second Allow machine, and the
// byte-exact ordering ratified by WP4 D4 and pinned by the gate is inherited
// rather than reproduced.
//
// A path matching NO route returns `false` and falls through to the ordinary
// miss, which answers 404. A path that does not exist does not acquire an
// options list.
//
// It is gated on `default_responses` for the same reason the 404 and 405 are:
// `bare()` installs no miss policy, and automatic OPTIONS is miss policy.
//
// It allocates nothing — the `Allow` value is built into
// `Context_Internal.allow_buffer`, the fixed request-local storage the 405
// already uses.
@(private)
options_answer :: proc(a: ^App, ctx: ^Context) -> bool {
	if !a.private.default_responses {
		return false
	}

	allow, exists := allow_value(a, ctx.request.path, ctx.private.allow_buffer[:])
	if !exists {
		return false
	}

	// `miss_allow` is the request-local slot the committed response's header
	// view points into. Storing the value in a local would leave the response
	// holding a view into a dead stack frame — the dangling-view bug the
	// ownership rules exist to prevent, and the same reason `mw_miss_prepare`
	// uses this field rather than a local.
	ctx.private.miss_allow = allow
	return response_commit(
		&ctx.private.response,
		.No_Content,
		response_allow_headers(ctx, ctx.private.miss_allow),
		nil,
	)
}

// response_body_view is what a driver sends, which is not always what the
// handler committed.
//
// For a HEAD request it is empty: the status and every header stay exactly as
// the GET produced them, and only the body is suppressed. Suppressing HERE
// rather than at commit means every responder is covered by one rule instead of
// each one learning about HEAD.
//
// It does NOT touch `response.body` itself. That slice may be an allocation the
// Response owns and `response_destroy` must free, so blanking it would leak.
// The suppression is a view for the driver, not a mutation of the response.
@(private)
response_body_view :: proc(ctx: ^Context) -> []u8 {
	if ctx.private.implicit == .Head {
		return nil
	}
	return ctx.private.response.body
}
