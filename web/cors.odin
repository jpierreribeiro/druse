// WP60 — CROSS-ORIGIN RESOURCE SHARING: `cors` and `Cors_Options`.
//
// TWO SYMBOLS. It is configuration rather than a middleware — `cors(&app, o)`,
// beside `limits(&app, l)` and `trust_proxies(&app, p)` — for a reason the
// `secure_headers` precedent makes concrete: the headers must reach EVERY
// response, including the automatic 404, the 405, an extractor's 400 and the
// driver's 500. WP22 measured that the driver finalizes a missing response
// after the chain has unwound, so a middleware that stamped the response would
// miss exactly the responses a browser most needs to be able to read.
//
// It also has to answer the preflight, which happens BEFORE any handler runs
// and must not run one. A middleware cannot do that without a way to stop the
// chain, which this framework deliberately does not have.
//
// THE SAFETY RULES ARE ENFORCED AT REGISTRATION, NOT AT REQUEST TIME, and that
// is the whole design. A CORS misconfiguration is not an error the server
// notices — it is a hole that works perfectly and quietly hands one origin's
// authenticated data to another. So every combination that is unsafe is
// refused at boot, where an operator is watching, rather than at 3 a.m.:
//
//	`*` with `credentials`     REFUSED. This is the classic hole. A browser
//	                           will not honour it, but a server that thinks it
//	                           is sharing credentials with everyone has a policy
//	                           it never had, and the next change makes it real.
//	`*` alongside real origins REFUSED as ambiguous. It reads as "these, and
//	                           also everyone", which is "everyone".
//	`*` in `headers` with
//	  `credentials`            REFUSED. The wildcard does NOT cover
//	                           `Authorization` in the Fetch standard, so this
//	                           configuration looks like it permits the header
//	                           an authenticated cross-origin request needs and
//	                           does not.
//	no origins at all          REFUSED. An allow-list that allows nothing is
//	                           not a policy, it is an unfinished one.
//
// WHAT IT ECHOES AND WHAT IT DOES NOT. When a request's `Origin` is on the
// list, the response carries that origin back — never the literal `*`, even
// when `*` was configured — together with `Vary: Origin`. Echoing the specific
// origin is what makes a shared cache safe, and `Vary` is what tells the cache
// so. When the origin is NOT on the list, the response carries no CORS header
// at all: the request is still served, and the browser refuses to hand the
// result to the page. Refusing to serve it would break same-origin clients and
// tell an attacker which origins are listed.
//
// THE STRINGS ARE THE CALLER'S, on the `trust_proxies` contract exactly: they
// are read on the request path, so they must outlive the App. String literals
// are what every real call site passes. Cloning them would add an allocation
// and a teardown to a path that has neither.
package web
// uruquim:file application

// The number of exact origins one application may list. A bound rather than a
// dynamic array for the reason every other capacity here is bounded: this is
// configuration, it is known at boot, and a list long enough to need more than
// eight entries wants a reverse proxy rather than a framework field.
@(private)
CORS_ORIGIN_MAX :: 8

@(private)
CORS_WILDCARD :: "*"

@(private)
CORS_ORIGIN_HEADER :: "Origin"
@(private)
CORS_REQUEST_METHOD_HEADER :: "Access-Control-Request-Method"

@(private)
CORS_ALLOW_ORIGIN :: "Access-Control-Allow-Origin"
@(private)
CORS_ALLOW_CREDENTIALS :: "Access-Control-Allow-Credentials"
@(private)
CORS_ALLOW_METHODS :: "Access-Control-Allow-Methods"
@(private)
CORS_ALLOW_HEADERS :: "Access-Control-Allow-Headers"
@(private)
CORS_MAX_AGE :: "Access-Control-Max-Age"
@(private)
CORS_VARY :: "Vary"
@(private)
CORS_VARY_ORIGIN :: "Origin"
@(private)
CORS_TRUE :: "true"

// The methods a preflight is told about when the application does not say.
// Deliberately the five the `Method` enum names, and deliberately not `OPTIONS`
// — a client does not need permission to send the preflight it is already
// sending.
//
// NOT CHANGED BY AUDIT R8, and the difference is in the specifications rather
// than in this project's taste. R8 made `Allow` name HEAD and OPTIONS because
// RFC 9110 §10.2.1 defines that field as the methods the resource SUPPORTS, and
// the server answers both. `Access-Control-Allow-Methods` is a different header
// with a different rule: Fetch safelists GET, HEAD and POST, so a browser
// permits a cross-origin HEAD whether or not it appears here. Adding it would
// change bytes on the wire without changing what any client may do — and the
// existing OPTIONS reasoning above is the same argument already applied once.
// Recorded so this reads as a decision rather than as an inconsistency with
// the sibling header.
@(private)
CORS_DEFAULT_METHODS :: "GET, POST, PUT, PATCH, DELETE"

// The widest decimal `max_age` this can render, which is far wider than any
// browser honours (Chrome caps at 2 hours, Firefox at 24).
@(private)
CORS_MAX_AGE_DIGITS :: 12

// Cors_Options is the policy, by value.
//
// `methods` and `headers` are COMMA-JOINED STRINGS rather than slices, and that
// is a deliberate ergonomic trade: they are written once, they go on the wire
// verbatim, and taking them pre-joined means the framework never builds a
// string at request time and never needs a buffer to build it in. A slice would
// look tidier at the call site and would cost an allocation or a copy on every
// preflight.
Cors_Options :: struct {
	// The exact origins allowed, scheme and host and port, as a browser sends
	// them: `https://app.example.com`. A single `"*"` allows any origin, and is
	// refused in combination with `credentials`.
	//
	// Matching is EXACT and case-sensitive. There is no pattern syntax, no
	// suffix match and no regular expression, because every one of those has
	// produced a published vulnerability by matching `evil-example.com` against
	// a rule meant for `example.com`.
	origins:     []string,

	// The methods a preflight is told are allowed, comma-joined. Empty means
	// `CORS_DEFAULT_METHODS`.
	methods:     string,

	// The request headers a preflight is told are allowed, comma-joined. Empty
	// means none beyond the ones a browser always permits — which is the
	// correct default, because `Content-Type: application/json` already needs
	// to be listed and an application that has not thought about it should find
	// out at development time.
	headers:     string,

	// Whether the browser may send credentials — cookies, TLS client
	// certificates, an `Authorization` header it manages. Refused together with
	// a `"*"` origin.
	credentials: bool,

	// How long, in seconds, a browser may cache the preflight. Zero omits the
	// header and lets the browser use its own default.
	max_age:     int,
}

// Cors_Config is what the App stores: the options with the origin list copied
// into a bounded array, plus the flag that says a policy exists at all.
//
// Separate from `Cors_Options` because the public type takes a slice — pleasant
// at the call site — and the App must not hold a slice header whose backing the
// caller could resize. The STRINGS are still the caller's, on the
// `trust_proxies` contract; only the list of them is copied.
@(private)
Cors_Config :: struct {
	origin:       [CORS_ORIGIN_MAX]string,
	origin_count: int,
	any_origin:   bool,
	methods:      string,
	headers:      string,
	credentials:  bool,
	max_age:      int,
	set:          bool,
}

// cors installs the cross-origin policy. Call it BEFORE the first request, like
// `limits`:
//
//	web.cors(&app, web.Cors_Options{
//	    origins     = {"https://app.example.com"},
//	    headers     = "Content-Type, Authorization",
//	    credentials = true,
//	    max_age     = 600,
//	})
//
// An unsafe or empty policy POISONS the application: `serve` refuses to bind
// and every request answers 500, with the reason on the observer. That is the
// same fail-closed treatment `limits` gives a contradictory budget, and it is
// chosen for the same reason — a security policy that is wrong in a way the
// server tolerates is a policy nobody will discover.
cors :: proc(a: ^App, o: Cors_Options) {
	if app_is_serving(a) {
		app_reject_late_configuration(a)
		return
	}
	if a.private.poisoned {
		// Already rejected and already reported; the first diagnosis stands.
		return
	}
	if app_has_dispatched(a) {
		cors_poison(a, FRAMEWORK_MESSAGE_CORS_AFTER_DISPATCH)
		return
	}
	if len(o.origins) == 0 {
		cors_poison(a, FRAMEWORK_MESSAGE_CORS_INVALID)
		return
	}
	if len(o.origins) > CORS_ORIGIN_MAX {
		cors_poison(a, FRAMEWORK_MESSAGE_CORS_INVALID)
		return
	}
	if o.max_age < 0 {
		cors_poison(a, FRAMEWORK_MESSAGE_CORS_INVALID)
		return
	}

	cfg: Cors_Config
	for origin, i in o.origins {
		if len(origin) == 0 {
			cors_poison(a, FRAMEWORK_MESSAGE_CORS_INVALID)
			return
		}
		if origin == CORS_WILDCARD {
			cfg.any_origin = true
		}
		cfg.origin[i] = origin
	}
	cfg.origin_count = len(o.origins)

	// `*` alongside named origins reads as "these, and also everyone", which is
	// "everyone" with extra words. Refused rather than resolved, because either
	// resolution surprises somebody.
	if cfg.any_origin && cfg.origin_count > 1 {
		cors_poison(a, FRAMEWORK_MESSAGE_CORS_WILDCARD)
		return
	}
	// THE CLASSIC HOLE. A wildcard origin with credentials is refused by every
	// browser, so an application configured this way is broken in a way that
	// looks like a framework bug — and the obvious "fix", echoing the request's
	// origin instead, turns it into a real vulnerability.
	if cfg.any_origin && o.credentials {
		cors_poison(a, FRAMEWORK_MESSAGE_CORS_WILDCARD)
		return
	}
	// The Fetch standard does not let `*` in `Access-Control-Allow-Headers`
	// cover `Authorization`. With credentials on, this configuration reads as
	// permitting the one header such a request most likely needs, and does not.
	if o.credentials && o.headers == CORS_WILDCARD {
		cors_poison(a, FRAMEWORK_MESSAGE_CORS_WILDCARD)
		return
	}

	cfg.methods = o.methods if len(o.methods) > 0 else CORS_DEFAULT_METHODS
	cfg.headers = o.headers
	cfg.credentials = o.credentials
	cfg.max_age = o.max_age
	cfg.set = true

	a.private.cors = cfg
}

// cors_allows reports whether this policy permits `origin`, which is never
// empty when this is called.
@(private)
cors_allows :: proc(cfg: ^Cors_Config, origin: string) -> bool {
	if !cfg.set {
		return false
	}
	if cfg.any_origin {
		return true
	}
	for i in 0 ..< cfg.origin_count {
		if cfg.origin[i] == origin {
			return true
		}
	}
	return false
}

// cors_resolve runs on the shared driver pipeline, before dispatch. It decides
// three things and writes them onto the Context: whether this request gets CORS
// headers at all, which origin to echo, and whether it is a preflight that must
// be answered without running a handler.
//
// It reads the request's `Origin` through `header_lookup` on the ARRIVED
// headers rather than through `web.header`, because the ADR-027 overlay is for
// the request-ID middleware and a request's own `Origin` is not something the
// framework should let anything shadow.
@(private)
cors_resolve :: proc(ctx: ^Context) {
	cfg := &ctx.private.cors
	if !cfg.set {
		return
	}
	origin, has_origin := cors_arrived_header(ctx, CORS_ORIGIN_HEADER)
	if !has_origin || len(origin) == 0 {
		// Not a cross-origin request. A same-origin client must not receive
		// CORS headers it did not ask for.
		return
	}
	if !cors_allows(cfg, origin) {
		// SERVED, BUT UNADORNED. The browser will refuse to hand the result to
		// the page, which is the correct outcome. Refusing the request outright
		// would break same-origin clients that send an `Origin` — every POST
		// from a browser does — and would tell an attacker which origins are on
		// the list.
		return
	}

	// The ECHOED origin, never the configured `*`. A cache that stores one
	// origin's response and serves it to another is the failure `Vary: Origin`
	// exists to prevent, and echoing the literal wildcard would make the
	// response look identical for every origin.
	ctx.private.cors_origin = origin
	ctx.private.cors_active = true

	// A preflight is an OPTIONS carrying `Access-Control-Request-Method`. The
	// header is what distinguishes it from an ordinary OPTIONS, which WP32a
	// already answers with the route's `Allow`.
	if ctx.private.implicit == .Options {
		if _, asks := cors_arrived_header(ctx, CORS_REQUEST_METHOD_HEADER); asks {
			ctx.private.cors_preflight = true
		}
	}
}

// cors_arrived_header reads a header as it ARRIVED, deliberately bypassing the
// ADR-027 overlay that `web.header` consults first.
//
// The overlay exists so the request-ID middleware can present an effective
// header, and it has exactly one writer. A request's own `Origin` decides who
// may read the response, so it is read from the wire and nothing is permitted
// to shadow it.
@(private)
cors_arrived_header :: proc(ctx: ^Context, name: string) -> (value: string, ok: bool) {
	for pair in ctx.request.headers.private.pairs {
		if ascii_fold_equal(pair.name, name) {
			return pair.value, true
		}
	}
	return "", false
}

// cors_commit_preflight answers the preflight and commits, so no handler runs.
//
// 204 rather than 200: there is no body, and the Fetch standard requires only
// an ok status. A 200 with an empty body would be equally valid and would make
// a zero-length body indistinguishable from a missing one in a log.
@(private)
cors_commit_preflight :: proc(ctx: ^Context) {
	response_commit(&ctx.private.response, .No_Content, response_headers_finish(ctx, 0), nil)
}

// cors_headers_append writes this request's CORS headers into the Context's
// response-header array and returns the new count.
//
// It is called from `response_headers_finish`, the one funnel every response
// passes through, which is what makes a 404, a 405 and the driver's 500 carry
// the headers too. A browser that cannot read the error is a browser whose user
// sees a blank page instead of a message.
@(private)
cors_headers_append :: proc(ctx: ^Context, n: int) -> int {
	count := n
	if !ctx.private.cors_active {
		// ROUTER AUDIT C2 — `Vary: Origin` BELONGS ON EVERY RESPONSE OF A
		// CORS-CONFIGURED APP, not only on the ones that carry an allow-origin.
		//
		// The early return used to emit nothing at all here, so a request with no
		// `Origin` (or a disallowed one) produced a response with no `Vary`. A
		// shared cache is then entitled to store that bare response under the URL
		// alone and hand it to a subsequent request from an ALLOWED origin, which
		// receives no `Access-Control-Allow-Origin` and fails the browser's check
		// — a cache-poisoning-shaped CORS failure that reproduces only through an
		// intermediary, which is the hardest kind to diagnose.
		//
		// The condition is "this app negotiates CORS at all", not "this response
		// did": an app that never calls `web.cors` still emits nothing.
		if ctx.private.cors.set {
			ctx.private.response_headers[count] = Header_Pair {
				name  = CORS_VARY,
				value = CORS_VARY_ORIGIN,
			}
			count += 1
		}
		return count
	}
	cfg := &ctx.private.cors

	ctx.private.response_headers[count] = Header_Pair {
		name  = CORS_ALLOW_ORIGIN,
		value = ctx.private.cors_origin,
	}
	count += 1

	// ALWAYS, even for a wildcard policy. The response varies by origin because
	// this framework echoes the origin, and a cache that does not know that will
	// serve one origin's response to another.
	ctx.private.response_headers[count] = Header_Pair {
		name  = CORS_VARY,
		value = CORS_VARY_ORIGIN,
	}
	count += 1

	if cfg.credentials {
		ctx.private.response_headers[count] = Header_Pair {
			name  = CORS_ALLOW_CREDENTIALS,
			value = CORS_TRUE,
		}
		count += 1
	}

	if !ctx.private.cors_preflight {
		return count
	}

	ctx.private.response_headers[count] = Header_Pair {
		name  = CORS_ALLOW_METHODS,
		value = cfg.methods,
	}
	count += 1

	if len(cfg.headers) > 0 {
		ctx.private.response_headers[count] = Header_Pair {
			name  = CORS_ALLOW_HEADERS,
			value = cfg.headers,
		}
		count += 1
	}

	if cfg.max_age > 0 {
		ctx.private.response_headers[count] = Header_Pair {
			name  = CORS_MAX_AGE,
			value = cors_render_max_age(ctx, cfg.max_age),
		}
		count += 1
	}

	return count
}

// cors_render_max_age formats the cache lifetime into request-local storage.
//
// Into the Context, on the same terms as `allow_buffer`: the committed response
// holds a VIEW over the result and is read after dispatch returns, so a local
// would hand back a view into a dead frame. Written by hand rather than through
// `core:strconv` because `package web` linking a formatter for one integer is a
// cost every application pays for a header most never send.
@(private)
cors_render_max_age :: proc(ctx: ^Context, seconds: int) -> string {
	buf := &ctx.private.cors_max_age_buffer
	value := seconds
	end := len(buf)
	for value > 0 && end > 0 {
		end -= 1
		buf[end] = u8('0' + value % 10)
		value /= 10
	}
	return string(buf[end:])
}
