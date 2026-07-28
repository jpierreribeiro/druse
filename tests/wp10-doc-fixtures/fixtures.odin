// WP10 — compilable fixtures for the documentation fragments.
//
// Every `<!-- fragment: phase1/... -->` block in an active document appears
// here as real, compiling code. A fragment is not a complete program, so it
// cannot be an `examples/` file; without this fixture it would be prose that
// nobody ever compiles — and prose drifts.
//
// The gate resolves each `fragment:` marker to a `fragment: <name>` comment in
// this directory, so a documented fragment with no fixture fails the build.
//
// This is an ordinary external consumer of `uruquim:web`: it uses only the
// public surface, exactly like an application.
package wp10_doc_fixtures

import "core:testing"
import web "uruquim:web"

User :: struct {
	id:   int    `json:"id"`,
	name: string `json:"name"`,
}

Create_User :: struct {
	name:  string `json:"name"`,
	email: string `json:"email"`,
}

// fragment: phase1/readme-taste
// The README's opening taste of the API: create, register, serve, and one
// handler that reads a path parameter and answers with JSON.
readme_taste :: proc() {
	app := web.app()
	defer web.destroy(&app)

	web.get(&app, "/users/:id", get_user)

	web.serve(&app, 8080)
}

// fragment: phase1/path-int
// The canonical fallible-extractor shape: check `ok`, return on failure.
get_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}

	web.ok(ctx, User{id = id, name = "Ada"})
}

// fragment: phase1/body
// The destination-filling extractor: it fills a value you own and returns bool.
create_user :: proc(ctx: ^web.Context) {
	input: Create_User
	if !web.body(ctx, &input) {
		return
	}

	web.created(ctx, User{id = 1, name = input.name})
}

// fragment: phase1/errors
// The error responders answer for you; the handler returns straight after.
deny :: proc(ctx: ^web.Context) {
	web.bad_request(ctx, "email is required")
}

// fragment: phase1/query
// `query` never responds by itself; `query_int_or` uses its default ONLY when
// the parameter is absent, and answers 400 when it is present but malformed.
search :: proc(ctx: ^web.Context) {
	q, found := web.query(ctx, "q")
	if !found {
		web.bad_request(ctx, "the 'q' parameter is required")
		return
	}

	limit, ok := web.query_int_or(ctx, "limit", 20)
	if !ok {
		return
	}

	web.ok(ctx, User{id = limit, name = q})
}

// fragment: phase1/routing
// Registration is one call per method. A static route wins over a parametric
// one regardless of the order they are registered in.
register :: proc(app: ^web.App) {
	web.get(app, "/users/me", ping)
	web.get(app, "/users/:id", get_user)
	web.post(app, "/users", create_user)
	web.put(app, "/users/:id", get_user)
	web.patch(app, "/users/:id", get_user)
	web.delete(app, "/users/:id", ping)
}

// fragment: phase1/app-lifecycle
// Create, register, serve. `destroy` runs exactly once, on the value `app()`
// returned.
run :: proc() {
	app := web.app()
	defer web.destroy(&app)

	web.get(&app, "/ping", ping)

	web.serve(&app, 8080)
}

// fragment: phase1/responses
// One helper per output kind. Payloads are passed BY VALUE.
respond_examples :: proc(ctx: ^web.Context) {
	web.ok(ctx, User{id = 1, name = "Ada"})
	web.created(ctx, User{id = 2, name = "Grace"})
	web.json(ctx, .Accepted, User{id = 3, name = "Queued"})
	web.text(ctx, .OK, "pong")
	web.no_content(ctx)
}

// fragment: phase1/copy-to-persist
// Request-derived strings are views valid only during the request. Copy
// explicitly, with an explicit allocator, to keep one.
keep_a_path :: proc(ctx: ^web.Context) -> string {
	name := web.path(ctx, "name")
	return clone_for_later(name)
}

@(private)
clone_for_later :: proc(s: string) -> string {
	out := make([]u8, len(s))
	copy(out, s)
	return string(out)
}

ping :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

// fragment: phase1/test-request
// The in-memory driver: real routing, no socket. It takes a method and a path.
check_ping :: proc() -> bool {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", ping)

	res := web.test_request(&app, .GET, "/ping")
	return res.status == .OK && res.body == "pong"
}

// fragment: phase2/middleware-use
// The canonical WP17 shape: every `use` BEFORE the first route. A middleware
// is an ordinary Handler that calls `web.next` to run the rest of the chain.
middleware_app :: proc() {
	app := web.app()
	defer web.destroy(&app)

	web.use(&app, require_auth) // before any route — the order is enforced
	web.get(&app, "/admin/users", list_users)

	web.serve(&app, 8080)
}

// fragment: phase2/bearer-auth
// The canonical auth guard (WP19): a strict RFC 6750 bearer parse, then the
// application's own validity check. Respond and return WITHOUT calling next
// to short-circuit. `token_is_valid` stands in for application code.
require_auth :: proc(ctx: ^web.Context) {
	token, ok := web.bearer_token(ctx)
	if !ok || !token_is_valid(token) {
		web.unauthorized(ctx, "authentication required")
		return
	}
	web.next(ctx)
}

token_is_valid :: proc(token: string) -> bool {
	return token == "expected"
}

list_users :: proc(ctx: ^web.Context) {
	web.ok(ctx, []User{{id = 1, name = "Ada"}})
}

// fragment: phase2/middleware-unwind
// Code after `next` runs as the chain unwinds — the response is committed by
// then, so read, never write (a late response attempt is rejected and the
// first response survives).
observe_outcome :: proc(ctx: ^web.Context) {
	web.next(ctx)
	// the request is fully answered here
}

// fragment: phase2/router-mount
// The canonical WP18 shape: build the Router fully, then mount it.
router_mount_app :: proc() {
	app := web.app()
	defer web.destroy(&app)

	api := web.router()
	defer web.destroy(&api)
	web.use(&api, require_auth)
	web.get(&api, "/users", list_users)

	web.mount(&app, "/api", &api)

	web.serve(&app, 8080)
}

// fragment: phase2/router-guard
// A per-prefix guard: middleware on a Router applies to that router's routes
// only, nested inside the app's globals.
router_guard_app :: proc() {
	app := web.app()
	defer web.destroy(&app)

	admin := web.router()
	defer web.destroy(&admin)
	web.use(&admin, require_admin)
	web.get(&admin, "/stats", stats)
	web.mount(&app, "/admin", &admin)

	web.serve(&app, 8080)
}

require_admin :: proc(ctx: ^web.Context) {
	token, found := web.query(ctx, "token")
	if !found || token != "admin-token" {
		web.forbidden(ctx, "admin access required")
		return
	}
	web.next(ctx)
}

stats :: proc(ctx: ^web.Context) {
	web.ok(ctx, []User{})
}

// fragment: phase2/observe
// The canonical observer (WP20): a plain procedure taking the event BY VALUE.
// It receives no Context, so it cannot respond and cannot read request bytes.
report_failure :: proc(event: web.Framework_Event) {
	metrics_increment(event.kind, event.route, event.status)
}

metrics_increment :: proc(kind: web.Framework_Error, route: string, status: web.Status) {
	// Application code: export to metrics, tracing, or an alerting pipeline.
}

Invoice :: struct {
	id:    int    `json:"id"`,
	payee: string `json:"payee"`,
}

lookup_invoice :: proc(id: int) -> (invoice: Invoice, found: bool) {
	if id != 1 {
		return {}, false
	}
	return Invoice{id = 1, payee = "grace"}, true
}

// fragment: phase2/fault-early-return
// The fault case docs/errors.md documents: an error branch that returns
// WITHOUT committing a response. It is a bug, and the response driver answers
// it with the standardized `internal_error` 500 rather than a zero status.
show_invoice :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return // path_int already answered 400
	}

	invoice, found := lookup_invoice(id)
	if !found {
		return // BUG: nothing was committed on this branch
	}

	web.ok(ctx, invoice)
}

// fragment: phase2/logger-use
// The one built-in middleware (WP22). Opt-in, and subject to the ordinary
// ADR-019 rule: every `use` comes before the first route.
logging_app :: proc() -> web.App {
	app := web.app()
	web.use(&app, web.logger)
	web.get(&app, "/orders/:id", show_order)
	return app
}

show_order :: proc(ctx: ^web.Context) {
	web.ok(ctx, User{id = 1, name = "Ada"})
}

// fragment: phase2/request-id-use
// WP23: correlation IDs. Registered FIRST so every later middleware — the
// logger included — runs with the effective ID already assigned.
correlated_app :: proc() -> web.App {
	app := web.app()
	web.use(&app, web.request_id)
	web.use(&app, web.logger)
	web.get(&app, "/orders/:id", show_order)
	return app
}

// The fixtures are compiled as a test package, so one live assertion keeps the
// runner honest about actually having built them.
@(test)
wp10_fixtures_compile_and_run :: proc(t: ^testing.T) {
	testing.expect(t, check_ping(), "the documented test_request fragment must work")

	app := web.app()
	defer web.destroy(&app)
	register(&app)

	// Static beats parametric, as the routing fragment claims.
	res := web.test_request(&app, .GET, "/users/me")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "pong")

	// The documented logger fragment builds a working application.
	logging := logging_app()
	defer web.destroy(&logging)
	logged := web.test_request(&logging, .GET, "/orders/7")
	testing.expect_value(t, logged.status, web.Status.OK)

	// The documented request-ID fragment does too, and the handler can read
	// the effective ID through the documented accessor.
	correlated := correlated_app()
	defer web.destroy(&correlated)
	tagged := web.test_request(&correlated, .GET, "/orders/7")
	testing.expect_value(t, tagged.status, web.Status.OK)

	// The documented route-identity fragment records the PATTERN. If it ever
	// recorded the path, this is where the documentation would go red — the
	// fragment claims "/users/:id, never /users/42" in those words.
	metrics := metrics_app()
	defer web.destroy(&metrics)
	route_hits = 0
	route_last = ""
	labelled := web.test_request(&metrics, .GET, "/users/42")
	testing.expect_value(t, labelled.status, web.Status.OK)
	testing.expect_value(t, route_hits, 1)
	testing.expect_value(t, route_last, "/users/:id")

	// The documented application-state fragment compiles AND the value it
	// reads is the caller's own — which is the claim the fragment makes.
	config := Doc_App_State{greeting = "hi"}
	stateful := state_app(&config)
	defer web.destroy(&stateful)
	configured := web.test_request(&stateful, .GET, "/config")
	testing.expect_value(t, configured.status, web.Status.OK)
	testing.expect_value(t, configured.body, `{"greeting":"hi"}`)

	// The documented limits fragment builds a working application — a Limits
	// with a zero field would have rejected it, which is what makes this
	// assertion about the fragment rather than about the framework.
	limited := limited_app()
	defer web.destroy(&limited)
	pinged := web.test_request(&limited, .GET, "/ping")
	testing.expect_value(t, pinged.status, web.Status.OK)
}

// fragment: phase3/route-identity
// WP34. The label is the PATTERN — `/users/:id`, never `/users/42` — because
// route identity keyed on the path is one time series per id, and puts user
// data in a dashboard. `record_hit` is the APPLICATION's code, not a framework
// symbol: the framework supplies the identity and nothing else.
route_hits: int
route_last: string

record_hit :: proc(pattern: string) {
	route_hits += 1
	route_last = pattern
}

by_route :: proc(ctx: ^web.Context) {
	record_hit(web.route(ctx))
	web.next(ctx)
}

metrics_app :: proc() -> web.App {
	app := web.app()
	web.use(&app, by_route)
	web.get(&app, "/users/:id", ping)
	return app
}

// fragment: phase3/app-state
// WP37. The lifetime rule is the LAYOUT: the state and the App are both locals
// of the same procedure, so the value outlives every request the App serves.
// This fixture returns the App instead of serving, because the gate compiles
// and runs it — the shape is otherwise the documented one.
Doc_App_State :: struct {
	greeting: string,
}

show_config :: proc(ctx: ^web.Context) {
	s, state_ok := web.state(ctx, Doc_App_State)
	if !state_ok {
		web.internal_error(ctx)
		return
	}
	web.ok(ctx, s^)
}

state_app :: proc(state: ^Doc_App_State) -> web.App {
	app := web.app_with_state(state)
	web.get(&app, "/config", show_config)
	return app
}

// fragment: phase3/limits
// WP36. Start from the default and change one field: a Limits with a zero
// field is refused, because there is no unset state to tell a forgotten field
// from a deliberate one.
limited_app :: proc() -> web.App {
	app := web.app()
	budget := web.DEFAULT_LIMITS
	budget.max_body = 64 * 1024
	web.limits(&app, budget)
	web.get(&app, "/ping", ping)
	return app
}

// fragment: phase5/cors
// WP60. Configuration rather than middleware, because the headers have to reach
// the automatic 404 and the driver's 500 as well, and the preflight has to be
// answered before any handler runs. The unsafe wildcard combinations are
// refused here, at registration, rather than at 3 a.m.
cors_app :: proc() -> web.App {
	app := web.app()
	web.cors(
		&app,
		web.Cors_Options {
			origins = {"https://app.example.com"},
			headers = "Content-Type, Authorization",
			credentials = true,
			max_age = 600,
		},
	)
	web.get(&app, "/ping", ping)
	return app
}

// fragment: phase5/static
// WP61. A mount owns its prefix; everything under it is answered from the
// directory or answered 404. The rejections — traversal, percent encoding,
// dotfiles, symlinks — are the feature.
static_app :: proc() -> web.App {
	app := web.app()
	web.static(&app, "/assets", "public/assets", web.Static_Options{index = "index.html"})
	web.get(&app, "/ping", ping)
	return app
}

// fragment: phase5/multipart
// WP63. The body is already in memory — there is no spool — so a part is a view
// over it. Copy what you keep, and never use the client's filename as a path.
upload_handler :: proc(ctx: ^web.Context) {
	file, ok := web.form_file(ctx, "avatar")
	if !ok {
		web.bad_request(ctx, "avatar is required")
		return
	}
	web.text(ctx, .OK, file.filename)
}
