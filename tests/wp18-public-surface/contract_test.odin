// WP18 public surface contract — `Router`, `router` and `mount` as an
// EXTERNAL consumer of `druse:web` sees them.
//
// The load-bearing property this suite pins: every existing `^App` procedure
// — `use`, the five verbs, `destroy`, and even `test_request` — accepts a
// `^Router` UNCHANGED, because `Router` embeds an `App` with `using`
// (subtype polymorphism). Zero signatures mutated (ADR-025 = B), zero
// procedure groups (the freeze gate rejects private-member groups), exactly
// three new names.
package test_wp18_public

import "core:log"
import "core:strings"
import "core:testing"
import web "druse:web"

INTERNAL_ENVELOPE :: `{"error":{"code":"internal_error","message":"Internal server error"}}`

// The WP17 quiet-logger idiom: tests that DELIBERATELY trigger a framework
// diagnostic swallow the expected `druse:` Error line and forward the rest.
Quiet :: struct {
	inner: log.Logger,
}

quiet_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Quiet)(data)
	if level == .Error && strings.contains(text, "druse:") {
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

quiet_logger :: proc(record: ^Quiet) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = quiet_logger_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

Sink :: struct {
	order: [64]u8,
	n:     int,
}

mark :: proc(s: string) {
	sink := (^Sink)(context.user_ptr)
	if sink == nil {
		return
	}
	for i in 0 ..< len(s) {
		if sink.n < len(sink.order) {
			sink.order[sink.n] = s[i]
			sink.n += 1
		}
	}
}

order_of :: proc(sink: ^Sink) -> string {
	return string(sink.order[:sink.n])
}

mw_app :: proc(ctx: ^web.Context) {
	mark("A>")
	web.next(ctx)
	mark("<A")
}

mw_router :: proc(ctx: ^web.Context) {
	mark("R>")
	web.next(ctx)
	mark("<R")
}

require_auth :: proc(ctx: ^web.Context) {
	token, found := web.query(ctx, "token")
	if !found || token != "s3cret" {
		web.unauthorized(ctx, "authentication required")
		return
	}
	web.next(ctx)
}

handler :: proc(ctx: ^web.Context) {
	mark("H")
	web.text(ctx, .OK, "handler")
}

list_users :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "users")
}

secret :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "TOP-SECRET")
}

// ---------------------------------------------------------------------------
// The canonical shapes.
// ---------------------------------------------------------------------------

@(test)
wp18_public_router_registers_with_the_frozen_verbs_and_mounts :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)

	api := web.router()
	defer web.destroy(&api)
	web.get(&api, "/users", list_users)
	web.post(&api, "/users", handler)
	web.mount(&a, "/api", &api)

	res := web.test_request(&a, .GET, "/api/users")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "users")

	miss := web.test_request(&a, .GET, "/users")
	testing.expect_value(t, miss.status, web.Status.Not_Found)
}

@(test)
wp18_public_nested_order_is_app_outer_inner_handler :: proc(t: ^testing.T) {
	sink: Sink
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, mw_app)

	inner := web.router()
	defer web.destroy(&inner)
	web.use(&inner, mw_router)
	web.get(&inner, "/leaf", handler)

	outer := web.router()
	defer web.destroy(&outer)
	web.mount(&outer, "/in", &inner)

	web.mount(&a, "/out", &outer)

	res := web.test_request(&a, .GET, "/out/in/leaf")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, order_of(&sink), "A>R>H<R<A")
}

@(test)
wp18_public_one_route_router_guards_a_single_path :: proc(t: ^testing.T) {
	// ADR-025 = B: route-level middleware IS a one-route Router.
	a := web.app()
	defer web.destroy(&a)

	guarded := web.router()
	defer web.destroy(&guarded)
	web.use(&guarded, require_auth)
	web.get(&guarded, "/", secret)
	web.mount(&a, "/admin/keys", &guarded)

	web.get(&a, "/public", list_users)

	denied := web.test_request(&a, .GET, "/admin/keys/")
	testing.expect_value(t, denied.status, web.Status.Unauthorized)
	testing.expect(t, !strings.contains(denied.body, "TOP-SECRET"))

	granted := web.test_request(&a, .GET, "/admin/keys/", query = "token=s3cret")
	testing.expect_value(t, granted.status, web.Status.OK)
	testing.expect_value(t, granted.body, "TOP-SECRET")

	open_route := web.test_request(&a, .GET, "/public")
	testing.expect_value(t, open_route.status, web.Status.OK)
}

// ---------------------------------------------------------------------------
// Fail-closed, from the outside.
// ---------------------------------------------------------------------------

@(test)
wp18_public_mis_ordered_router_cannot_reach_production :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	a := web.app()
	defer web.destroy(&a)

	// The D-12.5 program rewritten with a Router: route first, use second.
	r := web.router()
	defer web.destroy(&r)
	web.get(&r, "/users", secret)
	web.use(&r, require_auth)

	web.mount(&a, "/admin", &r)

	// The poison propagates through mount: the whole app is rejected, on the
	// same fail-closed terms as WP17's app-level guard.
	res := web.test_request(&a, .GET, "/admin/users")
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
	testing.expect_value(t, res.body, INTERNAL_ENVELOPE)
	testing.expect(t, !strings.contains(res.body, "TOP-SECRET"))
}

@(test)
wp18_public_use_after_mount_fails_closed :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	a := web.app()
	defer web.destroy(&a)

	r := web.router()
	defer web.destroy(&r)
	web.get(&r, "/x", handler)
	web.mount(&a, "/api", &r)

	web.use(&a, mw_app)

	res := web.test_request(&a, .GET, "/api/x")
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
}

@(test)
wp18_public_registration_after_mount_fails_closed :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	a := web.app()
	defer web.destroy(&a)

	r := web.router()
	defer web.destroy(&r)
	web.get(&r, "/x", handler)
	web.mount(&a, "/api", &r)

	// A route registered on a mounted router can never serve (mount already
	// copied), so it is rejected loudly rather than dropped silently.
	web.get(&r, "/late", secret)

	late_direct := web.test_request(&r, .GET, "/late")
	testing.expect_value(t, late_direct.status, web.Status.Internal_Server_Error)
	testing.expect(t, !strings.contains(late_direct.body, "TOP-SECRET"))

	// The app, mounted before the offence, is unaffected.
	still := web.test_request(&a, .GET, "/api/x")
	testing.expect_value(t, still.status, web.Status.OK)
}

// ---------------------------------------------------------------------------
// Shape and lifetime.
// ---------------------------------------------------------------------------

@(test)
wp18_public_signatures_are_pinned :: proc(t: ^testing.T) {
	// Pinned as procedure VALUES (the WP7/WP17 precedent): a signature change
	// is a compile error here, by design.
	router_sig: proc() -> web.Router = web.router
	mount_sig: proc(a: ^web.App, prefix: string, r: ^web.Router) = web.mount

	// The WP17 pins survive WP18 UNCHANGED — that is the whole point of the
	// subtype shape: no group, no generic, no mutated signature.
	use_sig: proc(a: ^web.App, middleware: web.Handler) = web.use
	get_sig: proc(a: ^web.App, pattern: string, handler: web.Handler) = web.get
	destroy_sig: proc(a: ^web.App) = web.destroy

	r := router_sig()
	defer web.destroy(&r)
	testing.expect(t, mount_sig != nil)
	testing.expect(t, use_sig != nil)
	testing.expect(t, get_sig != nil)
	testing.expect(t, destroy_sig != nil)
}

@(test)
wp18_public_router_tears_down_cleanly_mounted_or_not :: proc(t: ^testing.T) {
	// `odin test` tracks allocations by default: a leak or double free in
	// either owner fails this test without an explicit assertion.
	a := web.app()
	mounted := web.router()
	web.get(&mounted, "/x", handler)
	web.mount(&a, "/api", &mounted)
	_ = web.test_request(&a, .GET, "/api/x")

	unmounted := web.router()
	web.use(&unmounted, mw_router)
	web.get(&unmounted, "/y", handler)

	web.destroy(&mounted)
	web.destroy(&unmounted)
	web.destroy(&a)
}
