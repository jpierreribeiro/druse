// WP1 — COMPILING PUBLIC API SKELETON. NO HTTP BEHAVIOR.
//
// This file declares the canonical request context and the canonical handler
// type. It contains no request parsing, no response state, and no dispatch.
package web
// uruquim:file application

import "core:mem"

// Handler is the one and only handler shape (ADR-011). It takes the request
// context and returns nothing: handlers respond through the response helpers.
// Do not add a second handler signature, and do not return `error`,
// `Handler_Error`, `Handler_Outcome`, or any other result from a handler.
Handler :: proc(ctx: ^Context)

// Context is the canonical, non-parametric request context.
//
// It is deliberately NOT an extension bag: it will never expose `user_data`,
// `locals`, `values`, `map[string]any`, `map[any]any`, or a public `rawptr`
// (planning/public-api-guardrails.md G-03). Middleware-produced values reach handlers through typed
// extraction procedures.
//
// WP2 adds `request`. There is NO public `response` field and there never will
// be one: the response object and its commit state are framework-internal, and
// applications respond through the helpers (ADR-008). Keeping
// the API responder-only is what stops a hand-written status or `committed`
// flag from becoming an ordinary thing for an application to do.
//
// There is NO public `params` and NO public `route` field, and there will not
// be one (amended in WP4). WP4 matches routes and captures the path parameter
// into the private slot below; WP5 makes the existing `web.path` and
// `web.path_int` extractors read it, which keeps one canonical access path
// instead of announcing a second public field.
//
// WP34 amends the second half of that sentence and not the first: route
// identity became PUBLIC, through the accessor `web.route` (OQ-18, CLOSED) —
// a procedure, not a field. The distinction is the point. A field would be a
// second thing to keep in sync and a place for a future `ctx.route = …` to
// exist; an accessor reads the private slot below, is the only way to ask, and
// carries its redaction rule (the pattern, never the path) in one place the
// gate can check.
//
// LIFETIME: `request` is a bundle of views over transport-owned storage, valid
// only for the duration of this request. Copy explicitly to persist, and never
// hand `ctx` or a request view to background work (planning/public-api-guardrails.md G-05).
Context :: struct {
	request: Request,

	private: Context_Internal,
}

// Context_Internal is package-private: application code cannot NAME this type.
// It is encapsulated BY CONTRACT, not by the compiler — Odin has no per-field
// privacy, and fields stay reachable through a public field. Do not rely on
// this for safety guarantees (ADR-008, "Scope of the guarantee").
// WP2 gave it the response state, WP4 the routing state, and WP7 the
// request-lifetime arena and body-consumption state. A middleware chain cursor
// belongs to Phase 2.
//
// It deliberately holds NO pointer back to the App. `dispatch` receives the App
// explicitly instead, which keeps the request context free of a reference whose
// lifetime it would otherwise have to justify.
@(private)
Context_Internal :: struct {
	// The single-commit guard's storage. It lives here, and not on Context,
	// so that no application can address it as public API — reachability
	// through `private` is accepted and is not a security boundary
	// (ADR-008, "Scope of the guarantee"). WP6 wires the public responders
	// onto `response_commit`; WP2 leaves it untouched by any public path.
	response: Response,

	// WP4 — the captured path parameter, or the zero value when the matched
	// route was static. `value` is a view over the request path and `name` a
	// view over the App-owned pattern; neither is copied, and neither survives
	// the request. WP5 exposes it through `web.path`/`web.path_int`.
	param: Route_Params,

	// WP4 — request-local storage for the 405 `Allow` header.
	//
	// The value and its header pair must outlive `dispatch`, because the
	// committed response holds VIEWS over them and the caller reads that
	// response after dispatch returns. Building them in a local would hand back
	// views into a dead stack frame. A fixed buffer sized to the longest
	// possible value is what makes producing a 405 allocation-free; the
	// alternative, allocating a string per 405, would put an allocation on a
	// path that an unauthenticated client can trigger at will.
	allow_buffer: [ALLOW_VALUE_MAX]u8,

	// WP6 — request-local storage for the committed response's header pairs.
	//
	// It replaces WP4's single-slot `allow_header`: a 405 now carries `Allow`
	// AND `Content-Type`, so two slots are the Phase-1 worst case
	// (`RESPONSE_HEADER_MAX`). Every name and value stored here is a STATIC
	// string, or — for `Allow` — a view over `allow_buffer` above, so the array
	// holds no allocation and needs no teardown.
	//
	// It lives on the Context, not in a local, for the same reason
	// `allow_buffer` does: the committed response holds a VIEW over it and is
	// read after `dispatch` returns.
	response_headers: [RESPONSE_HEADER_MAX]Header_Pair,

	// C2 (friction F8-2) — request-local storage for APPLICATION-set headers
	// (`web.set_header`). Unlike every framework header, these names and values
	// are supplied by the handler and may be handler-local, so `set_header` COPIES
	// them into `app_header_buffer` and the pairs in `app_headers` are views over
	// that buffer — on exactly the `allow_buffer` terms, so the committed response
	// (which appends them via `response_headers_finish`) can read them after
	// `dispatch` returns, with no allocation and no teardown. `app_header_count`
	// bounds the pairs (`APP_HEADER_MAX`); `app_header_used` the bytes
	// (`APP_HEADER_BUFFER`). Both are zero on a request no handler set a header on.
	app_headers:      [APP_HEADER_MAX]Header_Pair,
	app_header_buffer: [APP_HEADER_BUFFER]u8,
	app_header_count: int,
	app_header_used:  int,

	// C2 (friction F8-4) — request-local storage for the `web.bytes` caller's
	// `Content-Type`, copied here so the committed response's view outlives the
	// handler (the same reason as `app_header_buffer`). Media types are short; a
	// content type exceeding this is rejected by `web.bytes`.
	content_type_buffer: [CONTENT_TYPE_MAX]u8,

	// C7 (friction F8-3) — ONE typed, request-scoped value (`web.request_state`),
	// the narrow reopening of ADR-028: NOT an untyped `Context` bag, NOT the
	// type-erased dynamic keying that ADR was right to reject. A single
	// application-declared type per request, stored zero-allocation in this fixed
	// request-local buffer. `request_state_set` is false on a fresh Context (one
	// is built per request in `serve_dispatch`/`test_request`, so keep-alive gets
	// a clean slate); the first `request_state` call zeroes the buffer and stamps
	// the type, and every later call in the same request asserts the same type —
	// so a middleware that wrote `^Auth` and a handler that reads `^Auth` share it,
	// while a handler asking for a different type aborts on the typeid mismatch
	// (the type confusion ADR-028 feared, made impossible rather than merely
	// discouraged).
	request_state_buffer: [REQUEST_STATE_MAX]u8,
	request_state_type:   typeid,
	request_state_set:    bool,

	// WP5 — request-local storage for the extractor error envelope, on exactly
	// the same terms as `allow_buffer` above and for exactly the same reason:
	// the committed response holds a VIEW over it, and it is read after the
	// extractor returns.
	//
	// A fixed buffer, not an allocation. There is no request-lifetime arena
	// until WP7 (ADR-006), so an allocated envelope would have no owner and no
	// point of release — and a malformed `?page=x` is something an
	// unauthenticated client can send at will, so allocating there would be a
	// remote memory-pressure lever. `ERROR_BODY_MAX` is the exact worst case,
	// derived from the ratified codes and messages in `web/errors.odin` and
	// re-checked there by `#assert`.
	//
	// Only the FIRST commit ever writes here: `error_commit_parameter` consults
	// the commit guard before touching the buffer, so a second failure cannot
	// rewrite the bytes the first response is still pointing at.
	error_buffer: [ERROR_BODY_MAX]u8,

	// WP17 — the middleware chain cursor (ADR-005). `chain` is a VIEW over the
	// App-owned pool, materialised by `chain_enter` for this request only; it
	// owns nothing and is never freed. `chain_index` is MONOTONIC: `next` reads
	// it, advances it, then calls that step, and it is never rewound — with the
	// terminal step inside the bound, that is what makes a second `next()` a
	// silent no-op (ADR-022 item 3, the WP12 integrator's constraint).
	chain:       []Handler,
	chain_index: int,

	// WP17 — the precomputed miss decision (ADR-023). `dispatch` holds the App
	// and decides 404-vs-405 BEFORE entering the miss chain; the terminal — an
	// ordinary Handler, which receives only this Context — acts on the record.
	// This is what keeps the deliberately-absent App back-pointer absent.
	// `miss_allow` is a view over `allow_buffer` below, request-local like
	// everything else here.
	miss_kind:  Miss_Kind,
	miss_allow: string,

	// WP96 — the transport's opaque per-request handle, threaded from the
	// neutral inbound so `web.stream` can open a detached response bound to
	// THIS connection. Nil on the in-memory test transport, which has no
	// connection to detach — `web.stream` there returns ok=false, and the
	// buffered path is what test_request exercises. A rawptr, never a
	// transport type: the core still names none.
	stream_exchange: rawptr,
	// WP96 — set by `web.stream` when this request detached its response, read
	// by `serve_dispatch` to tell the adapter to commit headers and hand the
	// wire to the owner-lane pump instead of writing a body.
	stream_detached: bool,

	// Phase 7.5-C2 — the owned upload spool (`^ingest.Spool`) for this request,
	// threaded from the neutral inbound, or nil when the body was not spooled.
	// `web.upload` reads it; `driver_cleanup` cancels it (deleting the file)
	// unless `web.upload_persist` transferred ownership. A rawptr for the same
	// reason `stream_exchange` is one: the core names no owning transport type.
	upload: rawptr,

	// WP91 (F5/F6) — the mounts pointer the static terminal serves from,
	// stamped by `dispatch` when a mount owns the path, in the same spirit as
	// `miss_kind`: `dispatch` holds the App and decides; the terminal — an
	// ordinary Handler receiving only this Context — acts on the record. A
	// pointer to one App-owned record, not an App back-pointer (the observer
	// precedent).
	static_mounts: ^Static_Mounts,

	// WP20 — the observer this request reports to (copied from the App by the
	// driver, nil when none is registered) and the REGISTERED PATTERN this
	// request matched (empty on a miss).
	//
	// The observer is a PROCEDURE POINTER, not an `^App`: the back-pointer
	// `Context_Internal` deliberately does not have (WP4 D3) stays absent, and
	// a failure inside a handler still reaches the observer. `route` is a view
	// over the App-owned pattern, valid until `destroy` — which is what lets an
	// observer store an event by value without dangling (§6.2).
	observer: proc(event: Framework_Event),
	route:    string,

	// WP37 — the application's typed state, COPIED from the App by the driver
	// at the start of the request, exactly as `observer` above is.
	//
	// The copy is the design, not an optimisation. A back-pointer to the App
	// would be the reference `Context_Internal` has deliberately not had since
	// WP4 D3, and adding one for this would undo that decision for a pointer
	// and a `typeid` that fit in two words. `state` reads these; nothing else
	// does; neither is owned, so neither needs teardown.
	state:      rawptr,
	state_type: typeid,

	// WP49 — whether `secure_headers` is in this application's chain.
	//
	// A FLAG READ BY THE RESPONSE BUILDER, not a stamp applied as the chain
	// unwinds, and the distinction is the whole reason it works: the driver
	// finalizes a missing response AFTER the chain has unwound (WP22 measured
	// it), so a stamping middleware would miss the 500 — which is exactly the
	// response an attacker is most likely to be looking at.
	secure_headers: bool,

	// WP48 — the connected peer's address (a view over transport-owned storage,
	// request-scoped) and the App's trusted-proxy set, copied by the driver.
	//
	// The PEER is stored, never a forwarded header: `client_ip` decides which
	// to return, and storing the decision instead of the inputs would make the
	// trust rule invisible at the point it matters.
	peer:    string,
	trusted: Trusted_Proxies,

	// WP60 — the cross-origin policy, copied from the App by the driver, plus
	// what `cors_resolve` decided about THIS request.
	//
	// `cors_origin` is a VIEW over the arrived `Origin` header, request-scoped
	// like every other view here. `cors_active` says the origin was allowed and
	// the response carries the headers; `cors_preflight` says the request was an
	// OPTIONS carrying `Access-Control-Request-Method`, which is answered
	// without running a handler.
	cors:                  Cors_Config,
	cors_origin:           string,
	cors_active:           bool,
	cors_preflight:        bool,
	// Request-local storage for the rendered `Access-Control-Max-Age`, on the
	// same terms as `allow_buffer`: the committed response holds a view over it.
	cors_max_age_buffer:   [CORS_MAX_AGE_DIGITS]u8,

	// WP61 — request-local storage for the rendered ETag, on the `allow_buffer`
	// terms: the committed response holds a view over it and reads it after
	// dispatch returns.
	static_etag_buffer:    [STATIC_ETAG_MAX]u8,

	// WP63 — the parsed multipart form, or the record that it could not be
	// parsed. A FIXED array rather than an allocation: `max_body` bounds the
	// bytes but not the work, and a parser that allocated per part would turn a
	// bounded body into an unbounded loop. Every string in it is a view over
	// the request body.
	multipart:             Multipart_Form,

	// WP36 — the byte budget this request is held to, copied from the App by
	// the driver alongside the observer and the state.
	//
	// RESOLVED, NOT RE-DERIVED. `limits` validated these values once, before
	// any request existed; the request path only COMPARES against them. Nothing
	// here re-interprets a limit or discovers a contradiction under load, which
	// is the whole point of validating at the call rather than at the read.
	limits: Limits,

	// WP19 — the ADR-027 request-header OVERLAY, read by `web.header` before
	// the arrived headers ("the effective request header"). ONE slot, on
	// purpose: Phase 2 has exactly one writer — WP23's request-ID middleware —
	// and a second slot ships only when a work package ratifies a second
	// writer. Both strings are either static or App/request-owned by the
	// writer's contract; the slot itself allocates nothing and needs no
	// teardown. WP19 ships the READ path; nothing in this work package writes
	// it outside the tests.
	overlay:     Header_Pair,
	overlay_set: bool,

	// WP23 — request-local storage for the EFFECTIVE request ID (ADR-027).
	//
	// It lives here, and is a FIXED array, for exactly the reasons
	// `allow_buffer` above is: the committed response holds a VIEW over it
	// through the `X-Request-Id` header and reads it after `dispatch` returns,
	// so a local would hand back a view into a dead frame — and an allocation
	// would sit on a path any unauthenticated client can trigger at will.
	//
	// The ID is ALWAYS copied in here, whether it was generated or accepted from
	// the client. Keeping a view over the inbound header in the accept branch
	// would work today, and would make the value's lifetime depend on which
	// branch produced it; one owner and one lifetime is worth the 64-byte copy.
	request_id_buffer: [REQUEST_ID_MAX]u8,
	request_id_value:  string,
	request_id_set:    bool,

	// WP7 — the single-consumer body capability (ADR-012 A). `.Fresh` is the
	// zero value, so a new Context begins with the body available. `web.body`
	// moves it to `.Consumed` on its first call, before the limit and parse.
	body_state: Body_State,

	// WP32b: the method the framework is answering on the application's behalf,
	// if any. It is set by `driver_run` from the raw token and read by
	// `dispatch` and by the drivers — a handler never sees it, because a HEAD
	// response must be identical to the GET response except for the body.
	implicit: Implicit_Method,

	// WP7 — the request-lifetime arena that owns decoded nested body data
	// (ADR-006). It is LAZY: this zero value holds no allocation, so a request
	// that never binds a body — or whose body is empty or over-limit — creates
	// no arena. `arena_active` says whether it has been initialized, and the
	// driver frees it exactly once via `request_arena_destroy` after the
	// response is captured. It belongs to the REQUEST, never the App or the
	// Response, and the WP6 Response-owned buffers are never migrated into it.
	request_arena: mem.Dynamic_Arena,
	arena_active:  bool,
}
