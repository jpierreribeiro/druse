// WP18 — ROUTE ORGANISATION: `Router`, `router`, `mount`.
//
// There is deliberately NO `web.group` (ADR-024, G-01): once a detached Router
// can be mounted at a prefix, `group(&app, "/admin")` would be a second
// canonical way to perform one operation. Route-level middleware is a
// ONE-ROUTE Router mounted at the path (ADR-025, option B) — one ordering
// rule, not two.
//
// THE SHAPE, and why it is this one. The plan projected `use`, `destroy` and
// the five verbs becoming procedure groups so Router variants add zero names —
// but `odin doc` renders a group as member NAMES only, so a group over
// `@(private)` members is unfreezable and `build/check_phase1_freeze.sh`
// rejects the construct outright (ADR-021 as amended); exporting the members
// instead would grow the ledger far past the approved 44. `Router` therefore
// embeds an `App` with `using`: Odin's subtype polymorphism converts `^Router`
// to `^App` implicitly at every existing call site, so `use`, the five verbs
// and `destroy` accept a Router with ZERO new names, ZERO procedure groups and
// ZERO mutated signatures (ADR-025 B's frozen-signature constraint holds to
// the byte). Probed on the pinned toolchain before this file was written: all
// seven call sites compile unchanged; the REVERSE conversion (`^App` where
// `^Router` is expected) is a compile error, so `mount` stays Router-only; and
// `odin doc` renders the using-field fully, so the freeze snapshot pins it.
package web
// druse:file application

import "core:strings"

// Router is a detached collection of routes and middleware, built exactly like
// an application and then attached to one with `mount`.
//
// It embeds an `App` (the `using` field), which is what lets every existing
// registration procedure accept `&router` unchanged — `use`, `get`, `post`,
// `put`, `patch`, `delete`, and `destroy`. The embedded App starts like
// `bare()`: no default 404/405 policy of its own, because a mounted router's
// misses belong to the application it is mounted into.
//
// OWNERSHIP: App and Router are TWO owners. `mount` COPIES — the application
// clones every mounted pattern and chain into its own storage — so each value
// is destroyed exactly once with `destroy`, in either order, and neither is
// ever copied by assignment (the App non-copyability contract applies to the
// embedded App verbatim).
//
// ORDER (ADR-019, applied inside Router): every `use(&router, …)` must come
// before the router's first route, and everything must be registered before
// `mount` — mount CLOSES the router, and a later registration on it fails
// closed rather than being silently dropped.
Router :: struct {
	using app: App,
}

// router creates an empty, detached Router.
//
// It allocates nothing: like `app()` and `bare()`, all storage is lazy and is
// created by the first `use` or registration. The zero value installs no
// default responses — a Router owns routes, not miss policy.
router :: proc() -> Router {
	// The embedded App carries the same default budget as any other. A Router
	// does not serve, but it IS an App by embedding, and an App whose limits
	// are three zeros is one that answers 413 to everything.
	return Router{app = App{private = App_Internal{limits = DEFAULT_LIMITS}}}
}

// mount attaches every route of `r` to the application at `prefix`, with the
// combined middleware chain: the application's globals first, then the
// router's own middleware in their `use` order, then the handler (spec §2.1 —
// outermost first). Routers nest: mounting an inner router into an outer one,
// then the outer into the App, composes prefixes and chains in that same
// outermost-first order.
//
// PREFIX GRAMMAR: `prefix` must begin with `/` and must not end with `/`
// (so `""`, `"/"`, `"api"` and `"/api/"` are all rejected), and NOTHING is
// normalised — the mounted pattern is `prefix + pattern` VERBATIM, so a
// router's `"/"` mounted at `"/api"` serves exactly `"/api/"` and not
// `"/api"` (WP4 D5's rule carried through construction). A `:param` in the
// prefix is ordinary path construction; the concatenated pattern is
// classified by the same rule as every registration, so a combined pattern
// with two parameters can never match (WP4 D5).
//
// FAIL-CLOSED (ADR-019 family). Prefix construction is path construction — a
// bug here mounts routes at unintended paths — so every mis-use is a boot
// failure with a diagnostic, never a silent drop: an invalid prefix rejects
// the application; mounting a POISONED router propagates the rejection (a
// mis-ordered router must not become a healthy application); mounting a
// router twice is rejected, because mount CLOSES the router. `mount` also
// counts as a registration for the application, so a later app-level `use`
// fails closed exactly as it would after `get`.
mount :: proc(a: ^App, prefix: string, r: ^Router) {
	if app_is_serving(a) {
		app_reject_late_configuration(a)
		return
	}
	if a.private.poisoned {
		// Already rejected and already reported; the first diagnosis stands.
		return
	}
	if r.private.poisoned {
		mount_poison(a, FRAMEWORK_MESSAGE_MOUNT_POISONED_ROUTER)
		return
	}
	if r.private.closed {
		mount_poison(a, FRAMEWORK_MESSAGE_MOUNT_CLOSED_ROUTER)
		return
	}
	if !mount_prefix_valid(prefix) {
		mount_poison_prefix(a, prefix)
		return
	}

	r.private.closed = true
	a.private.has_mounted = true

	if len(r.private.routes) == 0 {
		return
	}
	if a.private.routes == nil {
		routes, alloc_err := make([dynamic]Route_Entry, context.allocator)
		if alloc_err != nil {
			mount_poison(a, FRAMEWORK_MESSAGE_MOUNT_ALLOCATION_FAILED)
			return
		}
		a.private.routes = routes
	}

	for entry in r.private.routes {
		// EVERY allocation below is checked. Odin's `append` returns
		// `num_appended = 0` rather than panicking when it cannot allocate,
		// and `strings.concatenate` reports the same way — so discarding
		// these results is precisely how routes disappear in silence while
		// the application still reports healthy (WP18 Amendment 1). A partial
		// mount is rejected fail-closed, exactly like a mis-ordered one.
		owned, concat_err := strings.concatenate(
			{prefix, entry.pattern},
			a.private.routes.allocator,
		)
		if concat_err != nil {
			mount_poison(a, FRAMEWORK_MESSAGE_MOUNT_ALLOCATION_FAILED)
			return
		}

		// Combined validity: the router-level classification AND the
		// classification of the concatenated result. An entry that was invalid
		// on the router (say, no leading '/') must never become valid through
		// concatenation — "/api" + "x" spells "/apix", which would otherwise
		// mount a refused registration at a path nobody wrote.
		has_param, valid := pattern_classify(owned)
		valid = valid && entry.valid

		chain_start, chain_len, chain_ok := mount_chain_flatten(a, r, entry)
		if !chain_ok {
			mount_poison(a, FRAMEWORK_MESSAGE_MOUNT_ALLOCATION_FAILED)
			return
		}

		appended, append_err := append(
			&a.private.routes,
			Route_Entry {
				method = entry.method,
				pattern = owned,
				handler = entry.handler,
				has_param = has_param,
				valid = valid,
				chain_start = chain_start,
				chain_len = chain_len,
			},
		)
		if append_err != nil || appended != 1 {
			mount_poison(a, FRAMEWORK_MESSAGE_MOUNT_ALLOCATION_FAILED)
			return
		}

		// WP29: a mounted route joins the index exactly like a directly
		// registered one. `mount` COPIES, so the entry the index points at is
		// the App's own.
		if !index_insert(a, len(a.private.routes) - 1) {
			mount_poison(a, FRAMEWORK_MESSAGE_MOUNT_ALLOCATION_FAILED)
			return
		}

		// WP30: `index_insert` diagnoses a registration conflict in place and
		// still returns true, so the poison is read here rather than from the
		// result. Stopping matters: continuing would copy the rest of the
		// router into an application that is already rejected, and — worse —
		// a second colliding route would log a second diagnostic, when the
		// family's rule is that the FIRST diagnosis stands.
		if a.private.poisoned {
			return
		}
	}
}

// mount_prefix_valid is the whole prefix grammar: begins with '/', does not
// end with '/'. `len > 1` makes "/" invalid by the second rule.
@(private)
mount_prefix_valid :: proc(prefix: string) -> bool {
	if len(prefix) < 2 {
		return false
	}
	if prefix[0] != '/' {
		return false
	}
	if prefix[len(prefix) - 1] == '/' {
		return false
	}
	return true
}

// mount_chain_flatten appends `app globals ++ the router entry's chain` to the
// application's pool and returns the index pair. The router entry's chain
// already spells `router globals ++ … ++ handler` (flattened at the router's
// own registration, or by an inner mount), so prepending the application's
// globals yields exactly the §2.1 order: app, outermost router, …, handler.
// It returns `ok = false` when the pool could not grow. The caller rejects the
// application: a chain that is missing a step would run a route with fewer
// middleware than it was registered with, which is a SECURITY failure — an
// auth guard silently absent from a protected route — and is exactly why this
// cannot be allowed to fail quietly (WP18 Amendment 1).
@(private)
mount_chain_flatten :: proc(
	a: ^App,
	r: ^Router,
	entry: Route_Entry,
) -> (
	start: int,
	length: int,
	ok: bool,
) {
	if a.private.mw_pool == nil {
		pool, alloc_err := make([dynamic]Handler, context.allocator)
		if alloc_err != nil {
			return 0, 0, false
		}
		a.private.mw_pool = pool
	}
	start = len(a.private.mw_pool)
	for middleware in a.private.mw_globals {
		appended, err := append(&a.private.mw_pool, middleware)
		if err != nil || appended != 1 {
			return 0, 0, false
		}
	}
	for step in r.private.mw_pool[entry.chain_start:entry.chain_start + entry.chain_len] {
		appended, err := append(&a.private.mw_pool, step)
		if err != nil || appended != 1 {
			return 0, 0, false
		}
	}
	length = len(a.private.mw_pool) - start
	return start, length, true
}

// mount_poison rejects the application with a static diagnostic — the WP17
// poison mechanism reused: the dispatch-path guard answers 500 on both
// transports and `serve` refuses to start.
@(private)
mount_poison :: proc(a: ^App, message: string, loc := #caller_location) {
	a.private.poisoned = true

	logger := context.logger
	if logger.procedure == nil {
		return
	}
	logger.procedure(logger.data, .Error, message, logger.options, loc)
}

// mount_poison_prefix additionally names the offending prefix, through a fixed
// buffer exactly like the WP17 diagnostic — never `core:fmt`. A prefix longer
// than the buffer tail is truncated; its prefix identifies it, and the
// approved sentence is never touched.
@(private)
mount_poison_prefix :: proc(a: ^App, prefix: string, loc := #caller_location) {
	a.private.poisoned = true

	logger := context.logger
	if logger.procedure == nil {
		return
	}

	buf: [len(FRAMEWORK_MESSAGE_MOUNT_INVALID_PREFIX) + MW_POISON_DETAIL_MAX]u8
	n := copy(buf[:], FRAMEWORK_MESSAGE_MOUNT_INVALID_PREFIX)
	n += copy(buf[n:], " Offending prefix: \"")
	n += copy(buf[n:], prefix)
	n += copy(buf[n:], "\"")

	logger.procedure(logger.data, .Error, string(buf[:n]), logger.options, loc)
}

// router_poison_closed rejects a Router that was written to after `mount`
// copied it. Without this, the late registration would be silently dead — the
// route would never serve and nothing would say so, which is the same class
// of silent wrongness ADR-019 exists to refuse.
@(private)
router_poison_closed :: proc(a: ^App, loc := #caller_location) {
	a.private.poisoned = true

	logger := context.logger
	if logger.procedure == nil {
		return
	}
	logger.procedure(logger.data, .Error, FRAMEWORK_MESSAGE_ROUTER_CLOSED, logger.options, loc)
}
