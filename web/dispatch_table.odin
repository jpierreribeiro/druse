// WP4 — ROUTE TABLE: the App-owned storage the five registration procedures
// write into, and its teardown.
//
// Nothing in this file is public. There is no exported `Route`, `Router`,
// `Params`, `Param` or `Route_Info`, and no accessor for any of them: WP4 adds
// behavior, not surface, and the ledgers stay at 32 application + 2
// test-support = 34 (planning/phase-1-plan.md §WP4 D1).
//
// WHY THIS LIVES IN `web/` AND NOT `web/internal/dispatch/`. The plan proposed a
// subpackage. In Odin a subdirectory is a SEPARATE PACKAGE, and this code must
// name `App`, `Handler`, `Context`, `Method` and the internal `Response` — so a
// subpackage would have to import `uruquim:web`, which is the back-edge WP3
// already ratified as a compile cycle (probe C5). The alternatives are
// duplicating the types, bridging through an untyped pointer, or freezing an
// internal ABI, and all three are forbidden. The dispatcher is therefore
// package-private files in the existing package, and
// `build/check_public_api.sh` permits exactly these two file names rather than
// being relaxed to accept subdirectories (D2).
//
// THIS IS THE INTERIM DISPATCHER, not the router. It is a linear table, and it
// is deliberately not the Phase-3 data structure: the compact per-method tree
// with its precomputed chains, conflict diagnostics and normalization policy
// belongs to Phase 3. WP4's only job is to make the OBSERVABLE contract —
// precedence, per-method isolation, 404, 405 with `Allow` — true and
// test-pinned, so that replacing this table later changes nothing publicly.
package web
// uruquim:file application

import "core:strings"

// Route_Entry is one registered route.
//
// The table is a flat array of these: contiguous, cache-friendly to scan, and
// trivially replaceable. There is no node, no child pointer and no tree.
//
// OWNERSHIP. `pattern` is OWNED by the App — a clone made at registration with
// the table's allocator, and released exactly once by `routes_destroy`. It is
// deliberately not the caller's string: retaining a caller-supplied view would
// leave every route dangling as soon as the caller reused its buffer, and a
// registration-time clone is the one allocation the spec explicitly permits
// (`knowledge-base/02-odin-idioms-guidelines.md`, "Registration MAY allocate").
//
// `has_param` and `valid` are computed once at registration rather than
// re-derived on every request. `has_param` is what makes static-over-parametric
// precedence a property of the PATTERN instead of the registration order: lookup
// scans static entries first and parametric entries second, so both registration
// orders resolve identically.
//
// `valid` marks a pattern this interim dispatcher cannot interpret — no leading
// `/`, more than one `:param`, or an unnamed `:`. Invalid entries stay in the
// table but are skipped by both lookup and the `Allow` builder, so they never
// match and never make a path look "known". See `pattern_classify`.
// WP17: `chain_start`/`chain_len` name this route's flattened chain as an
// INDEX PAIR into the App-owned pool — never a `[]Handler`. WP12 P8 measured a
// stored slice dangling into `0xAAAAAAAAAAAAAAAA` the moment the pool
// reallocates, and P8b measured the same defect reading back CORRECTLY on the
// plain heap; index pairs are immune by construction because dispatch
// re-slices the pool's CURRENT storage (spec §2.2). `handler` remains the
// route's own terminal step, stored for its own sake (the pattern's identity),
// and it is also the last element inside the chain's bound.
@(private)
Route_Entry :: struct {
	method:      Method,
	pattern:     string,
	handler:     Handler,
	has_param:   bool,
	valid:       bool,
	chain_start: int,
	chain_len:   int,
}

// Route_Param is the captured path parameter for one request.
//
// It lives in `Context_Internal`, NOT on `Context`. There is no public
// `ctx.params` and no public accessor in Phase 1 (D1): WP5 makes the existing
// `web.path` and `web.path_int` extractors read this storage, which keeps one
// canonical access path instead of announcing a second public field.
//
// LIFETIME. `value` is a VIEW over the request path and is valid only for the
// duration of the request, exactly like every other request-derived view
// (planning/public-api-guardrails.md G-05). `name` is a view over the
// App-owned pattern and is valid until `destroy`. Neither is copied: copying
// would be a per-request allocation that a direct view makes unnecessary.
@(private)
Route_Param :: struct {
	name:  string,
	value: string,
	found: bool,
}

// ROUTE_PARAM_MAX is how many `:param` segments one pattern may declare.
//
// WHAT HAPPENS WHEN IT IS FULL, because the capacity ledger does not accept a
// bound without one: a pattern declaring MORE than this is marked INVALID at
// registration, exactly as a two-param pattern was in Phase 1. It never
// matches, never contributes to an `Allow` value, and cannot silently behave
// like a supported pattern. Fail-closed, and the same answer WP4 already gave.
//
// Eight is well past anything a REST path uses — `/orgs/:org/repos/:repo/
// issues/:number` is three. The number is a compile-time bound on request-local
// storage, so raising it costs bytes on every Context and lowering it after
// anyone ships a route would turn that route into a 404.
@(private)
ROUTE_PARAM_MAX :: 8

// Route_Params is the fixed inline capture set for one request.
//
// C-6's convergent design, and the reason WP33 exists as a work package rather
// than a patch: a small fixed array of VIEWS in request-local storage. Not a
// map, not an allocation, not a bag. G-03 is the boundary — this adds capacity
// to an existing private slot, it does not add a general-purpose keyed store,
// and `web.path` stays the one canonical accessor (G-01).
@(private)
Route_Params :: struct {
	slot:  [ROUTE_PARAM_MAX]Route_Param,
	count: int,
}

// ALLOW_HEADER_NAME is the exact 405 header name. Not `allow`, not `ALLOW`.
@(private)
ALLOW_HEADER_NAME :: "Allow"

// ALLOW_METHOD_ORDER is the deterministic order an `Allow` value lists methods
// in. It is a property of the FRAMEWORK, never of the application's
// registration sequence, so two applications that register the same methods in
// different orders produce byte-identical `Allow` headers.
//
// `.UNKNOWN` is absent and unreachable: no public procedure registers it, so it
// can never own a route and can never appear here.
@(private)
ALLOW_METHOD_ORDER :: [5]Method{.GET, .POST, .PUT, .PATCH, .DELETE}

// ALLOW_TOKEN_HEAD and ALLOW_TOKEN_OPTIONS are the two methods the FRAMEWORK
// serves and an application cannot register (audit R8). They are tokens rather
// than `Method` members on purpose: `Method` names what a route can be
// registered under, and adding two verbs no public procedure accepts would put
// unconstructible states in a public enum to serve a string. See `allow_value`.
@(private)
ALLOW_TOKEN_HEAD :: "HEAD"

@(private)
ALLOW_TOKEN_OPTIONS :: "OPTIONS"

// ALLOW_VALUE_MAX is the byte length of the longest possible `Allow` value,
// "GET, HEAD, POST, PUT, PATCH, DELETE, OPTIONS" — every registrable method
// plus the two the framework serves itself, comma-and-space separated:
// 3+4+4+3+5+6+7 tokens = 32, plus six ", " separators = 12. The value is built
// into a fixed request-local buffer of exactly this size, so producing a 405
// allocates nothing, and a buffer one byte short would truncate the header
// rather than fail loudly — which is why this is derived and not estimated.
@(private)
ALLOW_VALUE_MAX :: 44

// route_register is the SINGLE registration path. `get`, `post`, `put`, `patch`
// and `delete` are one-line delegations to it, so there is exactly one place
// where a route is validated, cloned and stored.
//
// ALLOCATION. The table is LAZY, like the WP3 test-support state: an App that
// registers no route allocates nothing. The first registration creates the
// dynamic array with `context.allocator`, and every pattern clone afterwards
// uses that same allocator — read back from the array — so registration and
// teardown can never disagree about which allocator owns the storage.
//
// IT STILL RETURNS NO ERROR, and it never will: registration reports through
// the ADR-019 fail-closed mechanism, not through a return value. Inventing an
// error contract here would freeze a public registration-error API that no work
// package has ratified — and the five verbs' signatures are frozen anyway.
//
// A MALFORMED PATTERN is stored as given and marked invalid by
// `pattern_classify`; both lookup and the `Allow` builder skip invalid entries,
// so it never matches a request and never contributes a method to a 405. That
// is WP4's guarantee and it is unchanged.
//
// A CONFLICTING PATTERN is a different thing and, since WP30, has a different
// answer: a second registration for the same method and the same path shape
// REJECTS the application fail-closed, because the second route could never
// serve and Phase 1's silence about that was the D5 debt this phase pays. The
// detection lives in `index_insert`, where an occupied slot IS the conflict.
// The App is poisoned by the time this returns, so the next `route_register`
// takes the early exit above and the first diagnosis stands.
@(private)
route_register :: proc(a: ^App, method: Method, pattern: string, handler: Handler) {
	if app_is_serving(a) {
		app_reject_late_configuration(a)
		return
	}
	// WP18: a registration on an already-rejected owner stays quiet (the first
	// diagnosis stands); a registration on a CLOSED Router — one that `mount`
	// already copied — fails closed, because the route would otherwise be
	// silently dead (never mounted, never served, never reported).
	if a.private.poisoned {
		return
	}
	if a.private.closed {
		router_poison_closed(a)
		return
	}

	if a.private.routes == nil {
		a.private.routes = make([dynamic]Route_Entry, context.allocator)
	}

	owned := strings.clone(pattern, a.private.routes.allocator)
	has_param, valid := pattern_classify(owned)

	// WP17: flatten `globals ++ handler` into the App-owned pool NOW, at
	// registration — never at dispatch (spec §2.2). The set of globals is fixed
	// by the ADR-019 guard before any route exists, so a chain flattened here
	// can never be stale.
	chain_start, chain_len := chain_flatten(a, handler)

	append(
		&a.private.routes,
		Route_Entry {
			method = method,
			pattern = owned,
			handler = handler,
			has_param = has_param,
			valid = valid,
			chain_start = chain_start,
			chain_len = chain_len,
		},
	)

	// WP29: index at REGISTRATION, never at dispatch. A tree built lazily on
	// the first request would allocate inside that request, and claim C-5's
	// perimeter would start to include a one-off cost only the first caller
	// pays.
	_ = index_insert(a, len(a.private.routes) - 1)
}

// routes_destroy releases the table exactly once and returns it to its zero
// state.
//
// It frees every owned pattern with the allocator that created it, then the
// array itself. It is a no-op for an App that registered no route, and a second
// call is a safe no-op — `web.destroy` is specified as call-once, but a
// teardown that double-frees when called twice is a worse failure than one that
// simply does nothing.
@(private)
routes_destroy :: proc(a: ^App) {
	// The index first: its maps key on views into the patterns freed below, so
	// freeing it afterwards would be reading storage this procedure had already
	// released. Order is the contract, not a preference.
	index_destroy(a)

	if a.private.routes == nil {
		return
	}

	// Captured before the array is freed: after `delete_dynamic_array` the
	// array's own allocator field is no longer a safe thing to read.
	allocator := a.private.routes.allocator

	for entry in a.private.routes {
		delete_string(entry.pattern, allocator)
	}

	delete_dynamic_array(a.private.routes)
	a.private.routes = nil
}

// method_token converts a `Method` to its on-the-wire token.
//
// Package-internal and total: every input maps to a token, it never allocates,
// and it returns a static string. `.UNKNOWN` maps to the empty token, which
// `method_from_token` converts back to `.UNKNOWN`.
//
// It lives here, beside the route table, because it is method VOCABULARY shared
// by two callers: the `Allow` builder below and the WP3 test-support facade.
// Keeping one mapping is what stops the framework and its test transport from
// ever disagreeing about what a method is called.
@(private)
method_token :: proc(method: Method) -> string {
	switch method {
	case .GET:
		return "GET"
	case .POST:
		return "POST"
	case .PUT:
		return "PUT"
	case .PATCH:
		return "PATCH"
	case .DELETE:
		return "DELETE"
	case .UNKNOWN:
		return ""
	}
	return ""
}
