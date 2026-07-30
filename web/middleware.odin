// WP17 — MIDDLEWARE: `use`, `next`, the registration-time chain flattening,
// the miss chain, and the ADR-019 fail-closed registration-order guard.
//
// Middleware IS the frozen `Handler` type (ADR-005; D-12.1 measured that a
// distinct proc type converts implicitly in BOTH directions on this toolchain,
// so it costs nothing at call sites and protects nothing). `use` and `next` are
// the ONLY two symbols this file exports; everything else is package-private.
//
// THE MECHANISM, in three sentences. `use` appends to an App-owned list of
// globals, which is legal only before the first registration and before the
// first dispatch (ADR-019, ADR-023). Registration flattens `globals ++ handler`
// into one App-owned pool, and each route stores the INDEX PAIR
// `chain_start, chain_len` — never a `[]Handler`, which WP12 P8 measured
// dangling into `0xAAAAAAAAAAAAAAAA` the moment the pool reallocates (and,
// worse, P8b measured reading back CORRECTLY on the plain heap: a latent
// corruption). Dispatch re-slices the pool through the pair and walks it with a
// monotonic per-request cursor; `next` is the walk.
//
// THE POOL INVARIANT (spec §2.2, stated as contract, not assumption): the pool
// is APPEND-ONLY and is never compacted, cleared or reordered before `destroy`.
// Index pairs are sound because of exactly this; a future edit that compacts
// the pool re-creates the P8 corruption with indices instead of pointers.
//
// WHY THE DISPATCH FILES DO NOT CONTAIN THIS CODE. `dispatch` delegates to
// `chain_enter`/`mw_miss_prepare`/`mw_poison_intercept` here: the WP4 dispatch
// files stay a matcher (build/check_public_api.sh §9e pins that layout), and
// Phase 3 can replace the route table without touching the chain machinery.
package web
// druse:file application

// use registers `middleware` to run, in registration order, around EVERY
// dispatch — routed requests and 404/405 misses alike (ADR-023).
//
// A middleware is an ordinary `Handler` that calls `next(ctx)` to run the rest
// of the chain. Code after `next` runs as the chain unwinds, in exact reverse
// registration order (ADR-022). Returning WITHOUT calling `next` short-circuits
// the chain: downstream middleware and the route handler do not run, and the
// middleware's own response is what the client receives.
//
// ORDERING IS A SECURITY BOUNDARY, so it is enforced, not documented. `use`
// after ANY registered route — or after the first dispatch — REJECTS THE WHOLE
// APPLICATION fail-closed (ADR-019): every request answers 500 and `serve`
// refuses to start. WP12 D-12.5 measured the alternative: a mis-ordered auth
// program whose protected route answered `200 OK`, with the secret body, to an
// unauthenticated caller — no error, no warning, no runtime symptom. Register
// every `use` before the first `get`/`post`/`put`/`patch`/`delete`.
//
// OWNERSHIP: the App owns its middleware list and chain pool; both are created
// lazily (an application that never calls `use` and registers no route
// allocates nothing here) and released exactly once by `destroy`.
use :: proc(a: ^App, middleware: Handler) {
	if app_is_serving(a) {
		app_reject_late_configuration(a)
		return
	}
	if a.private.poisoned {
		// Already rejected and already reported; the first diagnosis names the
		// first offence, which is the one that orders the fix.
		return
	}
	if a.private.closed {
		// WP18: this is a Router that `mount` already copied (mount closes the
		// router); a middleware added now could never run.
		router_poison_closed(a)
		return
	}
	if len(a.private.routes) > 0 || a.private.has_mounted {
		// `mount()` counts as a registration (ADR-019), even a mount that
		// carried no routes — the ordering rule is about the timeline, not the
		// table's size.
		mw_poison_use_after_route(a)
		return
	}
	if app_has_dispatched(a) {
		mw_poison_use_after_dispatch(a)
		return
	}

	if a.private.mw_globals == nil {
		a.private.mw_globals = make([dynamic]Handler, context.allocator)
	}
	append(&a.private.mw_globals, middleware)
}

// next runs the remainder of the current chain — later middleware, then the
// terminal step — and returns when all of it has returned.
//
// Code after `next` therefore runs as this middleware's frame resumes, and the
// unwind order is the exact reverse of entry order (ADR-022 items 1-2). At
// unwind time the response is ordinarily committed already; a further response
// attempt goes through the ordinary responders and is rejected by the existing
// single-commit guard, first response surviving byte-identically.
//
// The cursor is MONOTONIC and per-request: a second `next` call by the same
// middleware finds the chain exhausted and is a silent no-op, and so is `next`
// from a route handler (ADR-022 items 3-4). That no-op is a DESIGN CONSTRAINT,
// not a free property: it holds because the terminal step is the LAST ELEMENT
// INSIDE the cursor's bound, never a fall-through after it. WP12's integrator
// built the counter-example — an equally monotonic cursor whose terminal sat
// outside the bound ran the handler TWICE; the commit guard rejects a duplicate
// response, but a duplicated database write is invisible to it. The WP17
// mutation control re-creates that cursor and must observe the double run.
//
// It allocates nothing and never rewinds.
next :: proc(ctx: ^Context) {
	i := ctx.private.chain_index
	if i >= len(ctx.private.chain) {
		return
	}
	ctx.private.chain_index = i + 1
	ctx.private.chain[i](ctx)
}

// ---------------------------------------------------------------------------
// Chain construction and entry (package-private).
// ---------------------------------------------------------------------------

// chain_flatten appends `globals ++ terminal` to the App-owned pool and returns
// the index pair that names the new chain. Called once per registration and
// once for the lazily-built miss chain; never at dispatch.
//
// The pool is created lazily with `context.allocator` on the first flatten,
// like the route table, and every later append reads the array's own stored
// allocator, so registration and teardown cannot disagree about ownership.
@(private)
chain_flatten :: proc(a: ^App, terminal: Handler) -> (start: int, length: int) {
	if a.private.mw_pool == nil {
		a.private.mw_pool = make([dynamic]Handler, context.allocator)
	}
	start = len(a.private.mw_pool)
	for middleware in a.private.mw_globals {
		append(&a.private.mw_pool, middleware)
	}
	append(&a.private.mw_pool, terminal)
	length = len(a.private.mw_pool) - start
	return
}

// chain_enter materialises one chain from the pool — a VIEW over App-owned
// storage, valid for this request because nothing registers during dispatch —
// resets the cursor, and runs the first step. It allocates nothing (WP12 P9:
// zero allocations, zero bytes, temp allocator untouched, negative control
// caught).
@(private)
chain_enter :: proc(a: ^App, ctx: ^Context, start: int, length: int) {
	ctx.private.chain = a.private.mw_pool[start:start + length]
	ctx.private.chain_index = 0
	next(ctx)
}

// mw_destroy releases the middleware storage exactly once and returns it to
// the zero state. Handlers are procedure values — the arrays own no elements —
// so the teardown is the two arrays themselves. Idempotent, like every other
// teardown in the package.
@(private)
mw_destroy :: proc(a: ^App) {
	if a.private.mw_globals != nil {
		delete_dynamic_array(a.private.mw_globals)
		a.private.mw_globals = nil
	}
	if a.private.mw_pool != nil {
		delete_dynamic_array(a.private.mw_pool)
		a.private.mw_pool = nil
	}
	a.private.miss_start = 0
	a.private.miss_len = 0
	a.private.miss_built = false
	// WP91 — the static chain is invalidated by the same events for the same
	// reason: it embeds the global middleware list.
	a.private.static_start = 0
	a.private.static_len = 0
	a.private.static_built = false
}

// ---------------------------------------------------------------------------
// The miss chain (ADR-023): global middleware observe a 404 and a 405.
// ---------------------------------------------------------------------------

// Miss_Kind is the precomputed decision the miss terminal acts on. It exists so
// the terminal can stay an ordinary `Handler`: a Handler receives only the
// Context, and the 404/405 decision needs the App-owned table, so `dispatch` —
// which holds the App — decides BEFORE entering the chain and records the
// outcome here. This is what removes WP12 P13's one design wart (an App
// back-pointer on the Context, which WP4 D3 forbids) without a branch in
// `next`.
@(private)
Miss_Kind :: enum u8 {
	// `bare()`: the MECHANISM (middleware observe the miss) is on; the POLICY
	// (what a miss answers) stays absent. The terminal commits nothing and the
	// driver's existing 500 finalization applies unchanged (ADR-023 item 2).
	None,
	Not_Found,
	Method_Not_Allowed,
}

// mw_miss_prepare decides what the miss terminal will commit. The `Allow`
// value is built into the fixed request-local buffer on the Context, exactly
// as WP4 did it, so preparing a miss allocates nothing.
@(private)
mw_miss_prepare :: proc(a: ^App, ctx: ^Context) {
	if !a.private.default_responses {
		ctx.private.miss_kind = .None
		return
	}
	allow, other_methods_exist := allow_value(a, ctx.request.path, ctx.private.allow_buffer[:])
	if other_methods_exist {
		ctx.private.miss_kind = .Method_Not_Allowed
		ctx.private.miss_allow = allow
		return
	}
	ctx.private.miss_kind = .Not_Found
}

// miss_terminal is the last step INSIDE the miss chain's index bound — the
// same structural position a route handler occupies in a routed chain, which
// is precisely what keeps a second `next()` a no-op (ADR-022 item 3).
//
// The bodies are the same STATIC WP6 envelope constants the dispatcher used
// before WP17, committed through the same guard; the envelopes and the 405
// `Allow` header are byte-identical with and without middleware (P13).
@(private)
miss_terminal :: proc(ctx: ^Context) {
	switch ctx.private.miss_kind {
	case .None:
	// `bare()`: commit nothing, on purpose.
	case .Not_Found:
		response_commit(
			&ctx.private.response,
			.Not_Found,
			response_json_headers(ctx),
			transmute([]u8)string(ERROR_BODY_NOT_FOUND_ROUTE),
		)
	case .Method_Not_Allowed:
		response_commit(
			&ctx.private.response,
			.Method_Not_Allowed,
			response_allow_headers(ctx, ctx.private.miss_allow),
			transmute([]u8)string(ERROR_BODY_METHOD_NOT_ALLOWED),
		)
	}
}

// miss_chain_ensure builds the miss chain LAZILY, at most once per App, on the
// first miss. It is never invalidated: ADR-019 rejects `use()` after any
// registration and ADR-023 rejects it after the first dispatch, so the set of
// globals is fixed before any miss can happen — P13's rebuild-on-invalidation
// pool growth ([3, 6, 10, 15]) does not ship.
@(private)
miss_chain_ensure :: proc(a: ^App) {
	if a.private.miss_built {
		return
	}
	start, length := chain_flatten(a, miss_terminal)
	a.private.miss_start = start
	a.private.miss_len = length
	a.private.miss_built = true
}

// ---------------------------------------------------------------------------
// The fail-closed guard (ADR-019, extended by ADR-023).
// ---------------------------------------------------------------------------

// mw_poison_intercept answers every request on a poisoned App with the
// standard 500 envelope. It sits on the DISPATCH path — not in `serve` — so
// the in-memory transport and a real socket reject identically (ADR-019
// property (a)): a guard only in `serve` would let `test_request` answer 200
// where the socket answers 500, breaking R-10 parity on exactly the security
// property the two transports exist to keep identical.
@(private)
mw_poison_intercept :: proc(a: ^App, ctx: ^Context) -> bool {
	if !a.private.poisoned {
		return false
	}
	error_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)
	return true
}

// MW_POISON_DETAIL_MAX bounds the composed diagnostic's variable tail: the
// route count and the first unprotectable pattern. A pattern longer than the
// remaining space is TRUNCATED — the diagnostic is for the developer who wrote
// the pattern, and its prefix identifies it; truncation never touches the
// approved sentence, which is a compile-time constant.
@(private)
MW_POISON_DETAIL_MAX :: 256

// mw_poison_use_after_route rejects the application and emits the
// owner-approved ADR-019 diagnostic (spec §5), extended per property (c) with
// the count of already-registered routes and the FIRST registered pattern —
// the route the mis-ordered middleware cannot protect.
//
// The extension is composed into a fixed stack buffer through plain copies and
// a bounded manual integer encoding — the WP5-escaper precedent — because
// `core:fmt` costs every application ~37 KiB (WP6 measured the same class of
// import) and is banned from the package. The logger consumes the string
// synchronously and retains nothing, so a stack buffer is sound.
@(private)
mw_poison_use_after_route :: proc(a: ^App, loc := #caller_location) {
	a.private.poisoned = true

	logger := context.logger
	if logger.procedure == nil {
		return
	}

	buf: [len(FRAMEWORK_MESSAGE_USE_AFTER_ROUTE) + MW_POISON_DETAIL_MAX]u8
	n := copy(buf[:], FRAMEWORK_MESSAGE_USE_AFTER_ROUTE)
	n += copy(buf[n:], " Routes already registered: ")
	n += mw_write_int(buf[n:], len(a.private.routes))
	n += copy(buf[n:], "; first unprotectable pattern: ")
	n += copy(buf[n:], a.private.routes[0].pattern)

	logger.procedure(logger.data, .Error, string(buf[:n]), logger.options, loc)
}

// mw_poison_use_after_dispatch is the ADR-023 member of the same diagnostic
// family: `use()` after the App has already dispatched a request. There is no
// pattern to name — the offence is temporal — so the message is the static
// constant alone.
@(private)
mw_poison_use_after_dispatch :: proc(a: ^App, loc := #caller_location) {
	a.private.poisoned = true

	logger := context.logger
	if logger.procedure == nil {
		return
	}
	logger.procedure(logger.data, .Error, FRAMEWORK_MESSAGE_USE_AFTER_DISPATCH, logger.options, loc)
}

// mw_write_int encodes a non-negative int in decimal into `dst`, returning the
// byte count written. Bounded (an int is at most 20 decimal bytes),
// allocation-free, and deliberately not `core:fmt` (see above).
@(private)
mw_write_int :: proc(dst: []u8, value: int) -> int {
	v := value
	if v < 0 {
		v = 0
	}
	tmp: [20]u8
	i := len(tmp)
	for {
		i -= 1
		tmp[i] = '0' + u8(v % 10)
		v /= 10
		if v == 0 {
			break
		}
	}
	return copy(dst, string(tmp[i:]))
}
