// WP37 — TYPED APPLICATION STATE: `app_with_state` and `state`.
//
// ADR-004 option A, delivered: a `rawptr` plus a `typeid` on the App, and an
// accessor that asserts before it casts. TWO symbols and not one — the ledger
// moves 45 → 47 — because construction and access are different operations
// with different failure modes.
//
// WHAT THIS IS FOR: ONE VALUE, APP-SCOPED, SET BEFORE SERVING. A database
// handle, a configuration struct, a template cache. It is created before the
// first request and read by every one of them.
//
// REQUEST-SCOPED state is a SEPARATE thing, `web.request_state` (below). ADR-028
// originally decided it "does not exist"; corrective WP C7 (friction F8-3, an
// ADR-028 amendment) reopened that under the Corrective Program's owner mandate,
// on a narrow reading: ADR-028 was right to reject Go's `context.WithValue` and
// Rust's `http::Extensions` — TYPE-ERASED, dynamically-keyed state crossing
// library boundaries, which Uruquim does not have — but a SINGLE
// application-declared TYPE per request, typeid-checked, is not that pattern. It
// is the same `rawptr`+`typeid` discipline as `web.state`, applied per request,
// which is what lets a middleware hand a handler a computed value (the measured
// auth-prologue boilerplate F8-3 recorded) without an untyped bag. See
// `web.request_state`.
//
// WHY THE CALL SITE HAS NO GENERIC NOISE. ADR-004 weighed option B — a
// parametric `App(S)`/`Context(S)` — and rejected it because it puts a type
// argument on EVERY handler signature, which is the generic noise the spec
// refuses. The price of option A is a runtime assert instead of a compile
// error, and that price is paid honestly below.
//
// WHY `rawptr` IS ALLOWED HERE. G-03 bans `rawptr` in EXPORTED declarations,
// and neither exported signature has one: `app_with_state` takes `^$T` and
// `state` returns `^T`. The `rawptr` is a PRIVATE field, which is the exact
// narrowing `build/check_public_api.sh` anticipated in the comment beside the
// ban — the same shape `serve_dispatch`'s transport user pointer already uses.
// The untyped pointer is an implementation detail sealed between two typed
// boundaries, and the `typeid` is what keeps the seal honest.
package web
// uruquim:file application

// app_with_state creates an application with the same defaults as `app()` and
// one typed value every handler can reach.
//
// The App stores the POINTER, not a copy: the state stays where the caller put
// it, the caller owns it, and mutations through `state` are visible on the
// original. That is what makes a database pool usable — a copy would be a
// second pool.
//
// LIFETIME IS THE CALLER'S PROBLEM AND IS STATED PLAINLY: the pointed-to value
// must outlive the App. A pointer to a local in a procedure that returns before
// `serve` is a dangling pointer, and no assert can catch it — the type is still
// right and the memory is still mapped. Put it in `main`, beside the App.
//
// A NIL STATE REJECTS THE APPLICATION (AMEND-1, fail-closed per ADR-019). It is
// the same answer registration gives to every other unusable input: an App that
// accepted nil here would abort inside the first request instead, which is the
// same failure discovered later and by a client.
app_with_state :: proc(state: ^$T) -> App {
	if state == nil {
		// Poisoned BEFORE it is returned, so `serve` refuses to start and every
		// dispatch answers 500. The diagnostic is emitted here because there is
		// no later moment at which the caller is still looking at this call.
		state_poison_nil()
		return App {
			private = App_Internal {
				default_responses = true,
				poisoned = true,
				limits = DEFAULT_LIMITS,
			},
		}
	}

	return App {
		private = App_Internal {
			default_responses = true,
			limits = DEFAULT_LIMITS,
			state = rawptr(state),
			state_type = typeid_of(T),
		},
	}
}

// state_poison_nil emits the AMEND-1 diagnostic.
//
// It is a separate procedure only because `#caller_location` may be used as a
// default argument and nowhere else, and giving `app_with_state` such a
// parameter would put a `runtime.Source_Code_Location` on a frozen public
// signature and a `base:runtime` import in the dependency snapshot — a real
// cost for a slightly better line number. The location reported is this call
// site, exactly as `mount_poison`'s is.
@(private)
state_poison_nil :: proc(loc := #caller_location) {
	logger := context.logger
	if logger.procedure == nil {
		return
	}
	logger.procedure(logger.data, .Error, FRAMEWORK_MESSAGE_NIL_STATE, logger.options, loc)
}

// state returns the application's state as a `^T`.
//
// It asserts, before the cast, that state was registered at all and that `T` is
// EXACTLY the registered type. Both are programmer errors, not runtime
// conditions: an application either registered its state or did not, and it
// either asks for the type it registered or asks for a different one. Neither
// varies with the request, so neither can be discovered by a client — a failing
// assert aborts on the first request in development, which is the documented
// fault model (ADR-020: run under a supervisor).
//
// EXACT TYPE, NOT ASSIGNABLE TYPE. `typeid` equality is the whole check; there
// is no subtyping walk and no "close enough". Casting a `^Config` to a
// `^Database` because both are pointers is the defect this exists to make
// impossible, and a loose comparison would restore it.
//
// The returned pointer is the caller's original: writing through it mutates the
// value `app_with_state` was given, which is the point.
state :: proc(ctx: ^Context, $T: typeid) -> ^T {
	assert(
		ctx.private.state != nil,
		"uruquim: web.state was called on an application built with web.app() or web.bare(); only web.app_with_state registers state (ADR-004).",
	)
	assert(
		ctx.private.state_type == typeid_of(T),
		"uruquim: web.state was asked for a type other than the one registered with web.app_with_state; the requested and registered types must match exactly (ADR-004, AMEND-1).",
	)
	return (^T)(ctx.private.state)
}

// REQUEST_STATE_MAX bounds the ONE request-scoped value `request_state` stores in
// fixed request-local storage (no allocation, no teardown). A request-state type
// larger than this aborts at the call site — a programmer error, discovered in
// development, never by a client (ADR-020). 256 bytes holds the realistic case (a
// resolved identity: an id, a role, a couple of string views) with room to spare.
@(private)
REQUEST_STATE_MAX :: 256

// request_state returns a pointer to the request's ONE typed, request-scoped
// value — corrective WP C7 (friction F8-3), the narrow ADR-028 reopening.
//
// WHAT IT IS FOR. A value one part of a request computes and another reads: a
// middleware resolves the caller's identity and stamps it here; the handler reads
// it without re-querying. It is the typed hand-off F8-3 measured the absence of —
// every protected handler repeating the auth-resolve prologue because a `web.use`
// middleware had nowhere to leave a typed result.
//
// IT IS NOT AN UNTYPED BAG (the ADR-028 boundary). There is exactly ONE value per
// request and it has exactly ONE type: the first call in a request zeroes the
// buffer and stamps `$R`; every later call ASSERTS the same `$R`, so a handler
// asking for a type other than the one the middleware wrote aborts on the typeid
// mismatch rather than reinterpreting the bytes. This is `web.state`'s discipline
// (a private `rawptr` sealed between typed boundaries, kept honest by a `typeid`),
// applied per request instead of per application.
//
// LIFETIME. The storage is the Context's, valid for the request and no longer; a
// `^R` must not escape the request. A fresh Context is built per request
// (`serve_dispatch`, `test_request`), so `request_state_set` starts false and a
// keep-alive connection never leaks one request's value into the next. Zero
// allocation, no teardown.
//
// The returned pointer is stable within the request: two calls with the same `$R`
// return the SAME `^R`, so the middleware's writes are what the handler reads.
request_state :: proc(ctx: ^Context, $R: typeid) -> ^R {
	#assert(size_of(R) <= REQUEST_STATE_MAX)
	if !ctx.private.request_state_set {
		// Zero the fixed buffer (all of it — the array zero needs no allocator and
		// no import) so the caller reads a clean value, not a previous request's
		// bytes, before anyone writes.
		ctx.private.request_state_buffer = {}
		ctx.private.request_state_type = typeid_of(R)
		ctx.private.request_state_set = true
	} else {
		assert(
			ctx.private.request_state_type == typeid_of(R),
			"uruquim: web.request_state was asked for a type other than the one first stored this request; a request holds exactly one typed value and every access must use that same type (ADR-028 amendment / C7).",
		)
	}
	return (^R)(&ctx.private.request_state_buffer)
}
