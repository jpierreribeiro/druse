// WP4 — MATCHING AND DISPATCH: turning a method and a path into a handler
// call, a 404, or a 405.
//
// Nothing in this file is public. `dispatch` is the core-private entry point
// the WP3 test-support facade drives today and a real transport adapter (WP8)
// will drive later.
//
// WHAT THIS FILE DELIBERATELY DOES NOT DO. It normalizes NOTHING — not
// slashes, not percent-encoding, not dot segments, not trailing slashes — so
// `/users` and `/users/` are different paths and stay that way. A normalization
// policy is Phase 3 (D5), and quietly adopting one here would freeze it by
// accident. It also allocates nothing: matching walks the two strings in place,
// the captured parameter is a view, and the `Allow` value is built into a fixed
// request-local buffer.
package web
// druse:file application

// segment_next yields the next `/`-separated segment of a path, in place.
//
// `cursor` starts at 1 — just past the leading `/` — and is advanced past the
// segment that is returned. The split is STRICT: no empty segment is skipped
// and no trailing slash is folded away, because either would be a
// normalization decision this work package does not own.
//
//	"/"          -> [""]
//	"/users"     -> ["users"]
//	"/users/"    -> ["users", ""]
//	"/users/42"  -> ["users", "42"]
//
// It allocates nothing: the returned segment is a view into `path`.
@(private)
segment_next :: proc(path: string, cursor: ^int) -> (segment: string, ok: bool) {
	if cursor^ > len(path) {
		return "", false
	}

	start := cursor^
	end := start
	for end < len(path) && path[end] != '/' {
		end += 1
	}

	cursor^ = end + 1
	return path[start:end], true
}

// pattern_classify inspects a pattern ONCE, at registration.
//
// `has_param` lets lookup scan static routes before parametric ones without
// re-examining any pattern, which is what makes precedence depend on the
// pattern's shape rather than on registration order.
//
// `valid` reports whether this interim dispatcher can interpret the pattern at
// all. A pattern is valid when:
//
//   - it begins with `/`;
//   - it contains AT MOST ONE `:param` segment (D5);
//   - every `:param` segment is named — a bare `:` is not a parameter.
//
// An INVALID pattern never matches anything and never contributes to an `Allow`
// value. That is the whole of WP4's answer to a malformed registration, and it
// is deliberately not a diagnostic: registration still accepts the pattern and
// returns nothing, because a public registration-error API is Phase-3 scope
// (D5). What WP4 guarantees is that an unsupported pattern cannot silently
// behave like a supported one.
//
// Both failure modes are silent-wrong-answer bugs if left unchecked, which is
// why they are refused rather than approximated. A second `:param` would match
// a request while capturing only the first segment, discarding the rest without
// telling anyone. An unnamed `:` would capture a value under the empty name,
// which no `web.path(ctx, name)` call in WP5 could ever retrieve.
@(private)
pattern_classify :: proc(pattern: string) -> (has_param: bool, valid: bool) {
	if len(pattern) == 0 || pattern[0] != '/' {
		return false, false
	}

	param_count := 0
	cursor := 1
	for {
		segment, ok := segment_next(pattern, &cursor)
		if !ok {
			break
		}
		if len(segment) == 0 || segment[0] != ':' {
			continue
		}
		if len(segment) == 1 {
			// A bare `:` names nothing.
			return false, false
		}
		param_count += 1
	}

	// WP33: up to ROUTE_PARAM_MAX parameters, not one. Beyond that the pattern
	// is invalid and never matches — the same fail-closed answer Phase 1 gave
	// to a two-param pattern, moved to a higher bound rather than removed.
	if param_count > ROUTE_PARAM_MAX {
		return false, false
	}
	return param_count >= 1, true
}

// route_match matches one pattern against one request path.
//
// Both must begin with `/`, and both must run out of segments TOGETHER: a
// pattern is not a prefix matcher, so `/a/b` does not match `/a` or `/a/b/c`.
// A `:param` segment matches exactly one whole segment and never spans a `/`,
// which is why `/users/:id` does not match `/users/42/posts`.
//
// It assumes its `pattern` was already accepted by `pattern_classify`, so at
// most one `:param` reaches it and that param is named. Callers skip invalid
// entries rather than passing them here; the `:` branch below therefore fires
// at most once per match. Its `captured` guard is defence in depth, not the
// mechanism that enforces D5 — enforcing "one param" by silently keeping the
// first would make a two-param pattern match while discarding a segment.
//
// The leading-`/` guards are likewise defensive for the pattern and load-bearing
// for the path, which arrives from a transport and is never pre-validated.
//
// It allocates nothing. `name` is a view over the App-owned pattern; `value` is
// a view over the request path and is valid only for this request.
@(private)
route_match :: proc(
	pattern: string,
	path: string,
) -> (
	name: string,
	value: string,
	matched: bool,
) {
	if len(pattern) == 0 || pattern[0] != '/' {
		return "", "", false
	}
	if len(path) == 0 || path[0] != '/' {
		return "", "", false
	}

	pattern_cursor := 1
	path_cursor := 1

	captured_name: string
	captured_value: string
	captured: bool

	for {
		pattern_segment, pattern_ok := segment_next(pattern, &pattern_cursor)
		path_segment, path_ok := segment_next(path, &path_cursor)

		// Both must end at the same time. If only one still has segments, the
		// paths have different depths and do not match.
		if !pattern_ok || !path_ok {
			if pattern_ok != path_ok {
				return "", "", false
			}
			return captured_name, captured_value, true
		}

		if len(pattern_segment) > 0 && pattern_segment[0] == ':' {
			if !captured {
				captured_name = pattern_segment[1:]
				captured_value = path_segment
				captured = true
			}
			continue
		}

		if pattern_segment != path_segment {
			return "", "", false
		}
	}
}

// route_lookup finds the handler for one method and path.
//
// TWO PASSES, and that is the whole precedence rule: every static route is
// considered before any parametric one, so `/users/me` wins over `/users/:id`
// regardless of which was registered first. A single-pass "first match wins"
// scan would make behavior depend on registration order — the precise property
// Phase 3's radix tree must be free to change the implementation of without
// changing the result.
//
// Invalid patterns are skipped in both passes, so a registration this
// dispatcher cannot interpret can never win a match.
//
// It allocates nothing. The returned pointer aliases the table, which is stable
// for the duration of a request because nothing registers during dispatch.
@(private)
route_lookup :: proc(
	a: ^App,
	method: Method,
	path: string,
) -> (
	entry: ^Route_Entry,
	param: Route_Params,
	found: bool,
) {
	// WP29: the two-pass scan became a radix walk. The PRECEDENCE RULE IS
	// UNCHANGED and is now structural rather than re-derived — the walk tries a
	// node's static child before its parametric one at every level, so
	// `/users/me` still wins over `/users/:id` regardless of registration
	// order. The observable contract is identical; only the representation
	// moved, which is exactly the freedom the old comment here reserved.
	if len(a.private.route_index.nodes) == 0 {
		return nil, Route_Params{}, false
	}
	if len(path) == 0 || path[0] != '/' {
		return nil, Route_Params{}, false
	}

	captures: [ROUTE_PARAM_MAX]string
	idx, count, ok := index_walk(a, 0, path, 1, method, &captures, 0)
	if !ok {
		return nil, Route_Params{}, false
	}

	captured: Route_Params
	index_params_fill(a, idx, &captures, count, &captured)
	return &a.private.routes[idx], captured, true
}

// allow_value builds the `Allow` header value for a path, into `buffer`.
//
// It reports `allowed = false` when the path matches no route under any method
// — which is what separates a 404 from a 405.
//
// Invalid patterns are skipped, exactly as in `route_lookup`. A pattern that can
// never match must not make a path look "known under another method" either —
// otherwise an unsupported registration would turn a 404 into a 405 advertising
// a method that could never actually serve the request.
//
// The set of methods is collected in a `bit_set`, which gives deduplication for
// free: a path registered twice under GET, or matched by both a static and a
// parametric GET route, still yields "GET" exactly once. The value is then
// emitted in `ALLOW_METHOD_ORDER`, so the output is deterministic and
// independent of both registration order and table order.
//
// It allocates nothing: `buffer` is the caller's fixed request-local storage,
// sized `ALLOW_VALUE_MAX`, and the returned string is a view into it — valid
// exactly as long as that buffer is.
@(private)
allow_value :: proc(a: ^App, path: string, buffer: []u8) -> (value: string, allowed: bool) {
	methods: bit_set[Method]

	// WP29: the same set, collected from the index instead of by scanning the
	// whole table. `index_collect` explores BOTH branches rather than stopping
	// at the first terminal, because a path can be served by a static route
	// under one method and a parametric route under another and `Allow` must
	// name both. Invalid patterns were never indexed, so they are skipped here
	// by construction rather than by a `continue`.
	if len(a.private.route_index.nodes) > 0 && len(path) > 0 && path[0] == '/' {
		index_collect(a, 0, path, 1, &methods)
	}

	if methods == {} {
		return "", false
	}

	// AUDIT R8 — HEAD AND OPTIONS ARE NAMED, because they are served.
	//
	// RFC 9110 §10.2.1: "The Allow header field lists the set of methods
	// supported by the resource." WP32b made HEAD and OPTIONS automatic, and
	// this value went on listing the five registrable verbs — so a GET-only
	// route answered `Allow: GET` while, measured on a socket, HEAD returned
	// 200 and OPTIONS returned 204. The header was not a summary of what the
	// resource supports; it was a summary of what an application had typed.
	//
	// A CLIENT ACTS ON THIS. A cache deciding whether a HEAD is safe to issue, a
	// CORS preflight, an API explorer, a monitor choosing HEAD over GET — each
	// reads `Allow` and is told a method is unsupported that in fact answers.
	//
	// NEITHER IS A `Method` MEMBER, and that is deliberate rather than an
	// obstacle. `Method` is `{UNKNOWN, GET, POST, PUT, PATCH, DELETE}` — the
	// verbs an application can REGISTER — and adding two it cannot register
	// would put unconstructible states in a public enum to serve a string. They
	// are emitted as tokens here instead, which is exactly what they are: the
	// framework's own contribution to a resource's method set.
	//
	// HEAD is conditional on GET because it IS the GET route: `implicit_from_token`
	// maps HEAD to GET before matching, so a path with no GET has no HEAD.
	// OPTIONS is unconditional because `options_answer` answers any path that
	// reaches this procedure at all — this is only called where
	// `default_responses` is on, which is the same gate OPTIONS sits behind.
	n := 0
	emit :: proc(buffer: []u8, n: int, token: string) -> int {
		n := n
		if n > 0 {
			n += copy(buffer[n:], ", ")
		}
		return n + copy(buffer[n:], token)
	}
	for method in ALLOW_METHOD_ORDER {
		if method not_in methods {
			continue
		}
		n = emit(buffer, n, method_token(method))
		// Directly after GET, so the pair reads the way every other server
		// writes it and the order stays a framework property.
		if method == .GET {
			n = emit(buffer, n, ALLOW_TOKEN_HEAD)
		}
	}
	n = emit(buffer, n, ALLOW_TOKEN_OPTIONS)

	return string(buffer[:n]), true
}

// dispatch resolves one request and runs it. It is the core-private entry
// point, and it replaces the inert WP3 stub.
//
// It takes the App EXPLICITLY (D3). The WP3 stub took only the Context and so
// had no access to the App-owned table. The alternative — storing a `^App` on
// the Context — is rejected: it would make the request context outlive-
// sensitive for no benefit, since every caller of `dispatch` already holds the
// App. This signature is internal and replaceable; no public signature changed.
//
// The order of decisions is exactly:
//
//  1. a poisoned App (ADR-019 fail-closed) answers 500, on BOTH transports —
//     this guard lives here, on the shared dispatch path, on purpose;
//  2. a matching route runs its chain — globals, then the handler as the last
//     step inside the bound — once, and dispatch returns;
//  3. otherwise the MISS CHAIN runs (ADR-023): the same globals, terminating
//     in the automatic-response step. Under `app()` that terminal commits the
//     405-with-`Allow` or the 404; under `bare()` it commits nothing, because
//     `bare()` means no default POLICY — the observation mechanism stays on.
//
// The 404-vs-405 decision is made HERE, before the chain runs, because it
// needs the App-owned table and a `Handler` receives only the Context; the
// terminal acts on the precomputed record (see web/middleware.odin).
//
// TWO THINGS IT DOES NOT DO. It never fabricates a 200: a chain that returns
// without responding leaves the response uncommitted, and the framework does
// not invent success on its behalf. And it never overwrites a response that
// was already committed — every automatic response goes through
// `response_commit`, so the ADR-008 guard applies to the framework's own
// writes exactly as it applies to a handler's.
//
// `.UNKNOWN` gets no special case. It is a valid HTTP method the framework
// gives no public meaning to, so it simply matches no route and falls through
// to the ordinary 405/404 rules. It never becomes a 501: that would be a
// response policy WP4 has no mandate to freeze.
//
// The 404 and 405 bodies remain the STATIC envelope constants of WP6 D5,
// committed by the miss terminal; this file stays encoder-free and this
// procedure stays allocation-free at steady state (the one exception is the
// LAZY one-time miss-chain build on the first miss, an App-lifetime
// allocation, not a per-request one).
@(private)
dispatch :: proc(a: ^App, ctx: ^Context) {
	app_mark_dispatched(a)

	if mw_poison_intercept(a, ctx) {
		return
	}

	// WP31b — the path policy, BEFORE matching and before the chain. A path
	// whose meaning depends on who is normalising is refused once, at the
	// boundary, so no route and no middleware ever acts on an ambiguous one
	// (`planning/phase-3-spec.md` §1). It is not a framework failure and emits
	// no event, exactly like a 404.
	// WP91 (F5/F6) — a static mount still owns its prefix ahead of the router
	// AND ahead of the path policy (its own refusal rules answer 404 for every
	// unsafe path, deliberately indistinguishable from absence — the WP61
	// contract, unchanged), but its response now runs the SAME chain as every
	// other: global middleware and the response-header policy cover files.
	// Only GET (HEAD arrives as GET, WP32b) enters the static chain — the
	// same rule `static_serve` applies. A POST under a mount stays the
	// router's business and produces the 405 that names what the path
	// supports, exactly as before.
	if a.private.static_serve != nil && ctx.request.method == .GET {
		if _, _, owned := static_match(&a.private.static, ctx.request.path); owned {
			ctx.private.static_mounts = &a.private.static
			static_chain_ensure(a)
			chain_enter(a, ctx, a.private.static_start, a.private.static_len)
			return
		}
	}

	if path_rejected(ctx.request.path) {
		bad_request(ctx, PATH_REJECT_MESSAGE)
		return
	}

	// WP32b: OPTIONS is answered from the Allow machinery, before lookup. A
	// path matching no route falls through to the ordinary miss, so a path that
	// does not exist does not acquire an options list.
	if ctx.private.implicit == .Options && options_answer(a, ctx) {
		return
	}

	entry, param, found := route_lookup(a, ctx.request.method, ctx.request.path)
	if found {
		ctx.private.param = param
		// WP20: the LOW-CARDINALITY route identity a framework event carries —
		// the registered pattern, App-owned, never the raw path (§6.2). A miss
		// leaves it empty, which is the event's "no route" answer.
		ctx.private.route = entry.pattern
		chain_enter(a, ctx, entry.chain_start, entry.chain_len)
		return
	}

	// The `Allow` value and the 404/405 decision live in request-local storage
	// on the Context, NOT in a local: the committed response holds views over
	// them, and views into a dead stack frame would be exactly the
	// dangling-view bug the ownership rules exist to prevent.
	mw_miss_prepare(a, ctx)
	miss_chain_ensure(a)
	chain_enter(a, ctx, a.private.miss_start, a.private.miss_len)
}
