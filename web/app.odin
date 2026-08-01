// WP1 — COMPILING PUBLIC API SKELETON. NO HTTP BEHAVIOR.
//
// This file declares application construction and teardown. It installs no
// default policy, allocates nothing, and builds no router.
package web
// druse:file application

import transport "druse:web/internal/transport"
import testing "druse:web/testing"

// App owns the application's resources.
//
// Ownership contract (ADR-001, ratified by experiment 01): `app()` returns App
// by value and stores no pointer to the pre-return local. The caller keeps that
// value, passes `&app` to every mutating operation, and calls `destroy` on that
// same value exactly once. App is non-copyable by contract: a copy must never
// be destroyed independently.
App :: struct {
	private: App_Internal,
}

// App_Internal is package-private: application code cannot NAME this type.
// It is encapsulated BY CONTRACT, not by the compiler — Odin has no per-field
// privacy, and fields stay reachable through a public field. Do not rely on
// this for safety guarantees (ADR-008, "Scope of the guarantee").
@(private)
App_Internal :: struct {
	// WP4 route table: a flat array of registered routes, owned by the App.
	// It is LAZY — this zero value holds no allocation, so `app()`/`bare()`
	// still allocate nothing and an application that registers no route never
	// creates a table. `destroy` frees it, and every pattern it owns, exactly
	// once. The entry type and the whole matching strategy are internal: Phase 3
	// replaces this table wholesale without any public change.
	routes: [dynamic]Route_Entry,

	// WP29 route index: the radix tree chosen by the WP28 shootout. It is an
	// INDEX over `routes` — it stores integers into that array and owns nothing
	// else — so the flat table remains the single owner of every pattern,
	// handler and chain index pair. Like everything else here it is LAZY: an
	// application that registers no route allocates nothing for it.
	route_index: Route_Index,

	// WP4 default-policy flag: whether dispatch installs the automatic 404 and
	// 405. `app()` sets it; `bare()` leaves it false. It is the mechanism behind
	// the documented app()/bare() distinction, and it deliberately is NOT
	// middleware — Phase 2 owns that.
	//
	// The remaining Phase-1 defaults are not here yet: the fixed 4 MiB body cap
	// is WP7, and no allocator or production transport is wired before WP8.
	default_responses: bool,

	// WP17 middleware storage (ADR-005). All of it is LAZY: an application that
	// never calls `use` and registers no route allocates nothing here.
	//
	// `mw_globals` is the `use` list, in registration order. `mw_pool` is the
	// flattened chain pool every route's `chain_start`/`chain_len` index pair
	// points into; it is APPEND-ONLY and never compacted before `destroy` —
	// the invariant that makes index pairs immune to the P8 dangling-slice
	// corruption (spec §2.2). Both are freed exactly once by `destroy` via
	// `mw_destroy`.
	mw_globals: [dynamic]Handler,
	mw_pool:    [dynamic]Handler,

	// The miss chain (ADR-023): built lazily at the first miss, at most once —
	// `use()` is rejected after any registration AND after the first dispatch,
	// so the chain can never be invalidated once built.
	miss_start: int,
	miss_len:   int,
	miss_built: bool,

	// WP91 (F5/F6) — the static chain: global middleware ending in the static
	// terminal, built lazily like the miss chain. A static response now runs
	// the SAME middleware every route runs, so `secure_headers` and auth
	// cover files exactly as they cover handlers.
	static_start: int,
	static_len:   int,
	static_built: bool,

	// WP17 fail-closed state (ADR-019). `poisoned` is the private predicate a
	// test observes (`use()` returns void and cannot signal by return);
	// `dispatched` records that a first dispatch happened, which is what closes
	// the ADR-023 edge (`use()` after a served miss but before any route).
	poisoned: bool,
	// Atomic publication flags. `dispatched` closes the test-transport
	// registration edge; `serving` publishes the immutable real-server snapshot.
	// No route or policy storage is mutated once `serving` becomes non-zero.
	dispatched: u32,
	serving:    u32,
	// WP123 / ADR-018 — the handle of the server THIS App is running, or
	// `SERVER_HANDLE_NONE` when it is not running one.
	//
	// It is what replaces the transport's single `g_server` slot for every
	// question that used to be process-wide: `stop`, `stats`,
	// `refused_connections`, and — through the `Stream` token — every send on a
	// detached response. A process may now run two servers without the second
	// one silently answering for the first.
	//
	// A handle rather than a pointer, and that is not a detail: the runtime it
	// names lives in `serve`'s stack frame, so a pointer held by another thread
	// would be a use-after-free the moment `serve` returned. The handle carries a
	// generation, so a stale one names nothing and every operation on it is the
	// documented no-op. It is also ONE machine word, because `stop` is documented
	// as callable from a signal handler and must read it with a single atomic
	// load — which a multi-field struct could not offer.
	//
	// Written only by the transport's `on_server` callback, from inside `serve`;
	// read atomically from any thread.
	server:     transport.Server_Handle,
	// WP-6.5.3 — `draining` is set once, by `stop`, and read by `is_draining`.
	// It is the framework's own copy of "a stop was requested", kept so a
	// readiness handler can answer the orchestrator without reaching into the
	// transport. Written before `transport.request_stop` so the answer is never
	// behind the refusal. Atomic because `stop` may run in a signal handler.
	draining:   u32,

	// WP18 fail-closed state (ADR-019/ADR-024). `closed` marks a Router that
	// `mount` has already copied: a later registration on it would be silently
	// dead, so it fails closed instead. `has_mounted` records that this App
	// performed a mount — `mount()` counts as a registration for the ADR-019
	// ordering rule even when the mounted router carried no routes.
	closed:      bool,
	has_mounted: bool,

	// WP36 — the application's byte budget (ADR-029 §2b shape: options struct +
	// package default constant). It is NOT lazy and cannot be: the zero value
	// of `Limits` is three zeros, which would mean "answer 413 to every body".
	// Every constructor therefore initialises it to `DEFAULT_LIMITS`, and
	// `build/check_public_api.sh` asserts that every one of them does — a new
	// constructor that forgot would ship an application that rejects all
	// traffic. Three ints, no allocation; the laziness claim is unaffected.
	limits: Limits,

	// Phase 7.5-C2 — the large-body upload opt-in (`web.enable_upload`). LAZY and
	// off by default: the zero value disables spooling, so an App that never calls
	// `enable_upload` behaves exactly as before (a >max_body body is answered
	// 413). When on, `serve` resolves `upload` into the transport's spool
	// primitives. `upload.dir` is required to enable; no allocation here.
	upload_enabled: bool,
	upload:         Upload_Config,

	// WP48 — the trusted-proxy set (ADR-013). A fixed inline array, no
	// allocation, no teardown; the driver copies it onto each request beside
	// the observer, the state and the limits.
	trusted: Trusted_Proxies,

	// WP60 — the cross-origin policy (ADR-034). Copied onto each request beside
	// the limits and the trusted set. Bounded and inline: no allocation, no
	// teardown, and the origin strings are the caller's on the `trust_proxies`
	// contract.
	cors: Cors_Config,

	// WP61 — the static-file mounts (ADR-034). Bounded and inline like the
	// trusted set and the CORS policy; the prefix and directory strings are the
	// caller's, read on the request path.
	static: Static_Mounts,

	// WP61 — the static file server, registered LAZILY by `static` on first
	// mount (guardrail 3). Nil in every application that mounts no directory,
	// which is what keeps `core:os` out of those binaries. See the note at the
	// assignment in `web/static.odin`.
	static_serve: proc(ctx: ^Context, mounts: ^Static_Mounts) -> bool,

	// WP37 — ADR-004 option A: the application's typed state, as an untyped
	// pointer plus the `typeid` that makes it typed again at the boundary.
	//
	// The App stores the POINTER and owns nothing: the caller created the value
	// and the caller outlives the App with it. `destroy` therefore has nothing
	// to release here, and adding a teardown would be the framework freeing
	// memory it never allocated.
	//
	// The `rawptr` is PRIVATE, which is the whole basis on which G-03 permits
	// it: `app_with_state` takes `^$T` and `state` returns `^T`, so no exported
	// signature carries an untyped pointer. `state_type` is not decoration —
	// it is the only thing standing between a wrong `web.state(ctx, T)` and a
	// silently mistyped cast.
	state:      rawptr,
	state_type: typeid,

	// WP20 — the application's framework-error observer (ADR-026), or nil.
	// ONE slot: `observe` replaces rather than appends (last wins), so no
	// storage is owned and nothing needs teardown. The driver copies this
	// pointer onto each request's Context, which is how a failure inside a
	// handler reaches the observer without the Context holding an `^App`.
	observer: proc(event: Framework_Event),

	// WP3 test-support state (the in-memory `web.test_request` transport). It is
	// LAZY: this zero value holds no allocation, so `app()`/`bare()` allocate
	// nothing and an application that never calls `test_request` never creates a
	// recorder. The type belongs to the machinery package `web/testing`; `web`
	// names it but the machinery never names a `web` type, keeping the
	// dependency one-way.
	test_transport: testing.Test_Transport,

	// The test-support teardown, registered LAZILY by `test_request` on first
	// use (planning/public-api-guardrails.md G-11).
	//
	// This indirection exists to eliminate a shipped cost, not to be clever.
	// `web.destroy` runs in EVERY application, so calling `testing.destroy`
	// directly from it creates a STATIC call edge into the machinery — and that
	// edge links the recorder teardown, plus its `delete_dynamic_array` and
	// `delete_slice` instantiations, into binaries that never test anything.
	// Through a proc pointer the only reference lives inside `test_request`, so
	// when `test_request` is dead-code-eliminated the teardown goes with it.
	//
	// The permitted residual is exactly this pointer field — one word of struct
	// and its nil initialization — never the teardown routine itself. Asserted
	// by `build/check_g11_teardown.sh`, which fails if `nm` finds any
	// `web/testing` teardown symbol in an application that never tests.
	test_teardown: proc(t: ^testing.Test_Transport),
}

// app creates an application with the progressive Phase-1 defaults.
//
// WP4 delivers two of them: a consistent 404 for an unmatched path, and a
// minimal 405 — with an exact `Allow` header listing the methods registered for
// that path — when the path exists under a different method. WP6 gave both the
// standardized error envelope.
//
// Still NOT delivered, and not claimed: the fixed 4 MiB request-body cap (WP7),
// panic recovery (Phase 2), configurable limits and read/write timeouts
// (Phase 3), and graceful shutdown hardening (Phase 4).
//
// It allocates nothing. The route table is created on the first registration.
app :: proc() -> App {
	return App{private = App_Internal{default_responses = true, limits = DEFAULT_LIMITS}}
}

// bare creates an application with none of the default middleware or policies,
// for callers that want full control.
//
// WP4 makes the distinction real for the first time. A `bare` application still
// dispatches every route it registers, but it installs NO automatic 404 and no
// automatic 405: an unmatched request simply leaves the response uncommitted,
// and deciding what to do about it belongs to the caller.
bare :: proc() -> App {
	// `bare()` installs no POLICY. Limits are not policy — they are the byte
	// budget that keeps a request from consuming the process — so a bare
	// application gets the same defaults. There is no way to ask for none, and
	// there should not be: "unlimited" is not a configuration, it is a denial
	// of service waiting for one request.
	return App{private = App_Internal{limits = DEFAULT_LIMITS}}
}

// destroy releases everything the application owns.
//
// Call it exactly once, on the original value returned by `app` or `bare`.
//
// WP4: releases the route table and every pattern the App cloned at
// registration, exactly once. It is a no-op for an application that registered
// no route.
//
// WP3/G-11: releases the test-support state by calling the teardown that
// `test_request` registered on its first call. For an application that never
// called `test_request` the pointer is nil and this is a genuine no-op — and,
// because the pointer is the only reference to it, the teardown routine is not
// even linked into that binary (planning/public-api-guardrails.md G-11).
//
// Calling `testing.destroy` directly here instead would be a static edge from
// every application's `destroy` into the machinery, linking the recorder
// teardown into binaries that never test. That is the cost this indirection
// exists to remove.
//
// The request arena and the transport own no App-lifetime state, so there is
// nothing further for `destroy` to release.
destroy :: proc(a: ^App) {
	routes_destroy(a)
	mw_destroy(a)

	if a.private.test_teardown != nil {
		a.private.test_teardown(&a.private.test_transport)
	}
}
