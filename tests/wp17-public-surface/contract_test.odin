// WP17 public surface contract — `use` and `next` as an EXTERNAL consumer of
// `druse:web` sees them.
//
// Everything here is expressed with the ratified surface plus the two WP17
// symbols, driven through `web.test_request`. The security-critical test is
// `wp17_mis_ordered_auth_program_does_not_serve_the_protected_route`: it is the
// WP12 D-12.5 demonstration made permanent — the program that measured
// `/admin/users -> 200 OK` to an unauthenticated caller must now fail closed.
//
// ORDER RECORDING uses `context.user_ptr`: middleware are top-level procedures
// of the frozen `Handler` shape (no closures), the context flows unchanged from
// the test frame through `test_request` into every chain step, and each test
// owns its sink as a local, so the parallel test runner cannot interleave two
// tests' marks.
package test_wp17_public

import "core:log"
import "core:strings"
import "core:testing"
import web "druse:web"

// Tests that DELIBERATELY trigger a framework diagnostic (the ADR-019 poison
// report, the driver 500) must swallow the expected `druse:` Error line:
// the pinned test runner records Error-level log output as a test failure
// (the WP6/WP8 idiom). Everything else is forwarded to the runner's logger.
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

NOT_FOUND_ENVELOPE :: `{"error":{"code":"not_found","message":"Route not found"}}`
METHOD_NOT_ALLOWED_ENVELOPE :: `{"error":{"code":"method_not_allowed","message":"Method not allowed"}}`
INTERNAL_ENVELOPE :: `{"error":{"code":"internal_error","message":"Internal server error"}}`

Sink :: struct {
	order:        [128]u8,
	n:            int,
	handler_runs: int,
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

mw_a :: proc(ctx: ^web.Context) {
	mark("A>")
	web.next(ctx)
	mark("<A")
}

mw_b :: proc(ctx: ^web.Context) {
	mark("B>")
	web.next(ctx)
	mark("<B")
}

mw_c :: proc(ctx: ^web.Context) {
	mark("C>")
	web.next(ctx)
	mark("<C")
}

mw_deny :: proc(ctx: ^web.Context) {
	mark("STOP")
	web.text(ctx, .Forbidden, "denied")
}

// The auth guard for the ordering tests. Phase 2 has no header lookup until
// WP19, so the credential travels as a query parameter; what is under test is
// the ORDER, not the credential transport.
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
	sink := (^Sink)(context.user_ptr)
	if sink != nil {
		sink.handler_runs += 1
	}
	web.text(ctx, .OK, "handler")
}

admin_users :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "TOP-SECRET-USERS")
}

contains :: proc(haystack: string, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(haystack) < len(needle) {
		return false
	}
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i + len(needle)] == needle {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Ordering, short-circuit, misses — through the public surface only.
// ---------------------------------------------------------------------------

@(test)
wp17_public_order_across_three_globals :: proc(t: ^testing.T) {
	sink: Sink
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, mw_a)
	web.use(&a, mw_b)
	web.use(&a, mw_c)
	web.get(&a, "/x", handler)

	res := web.test_request(&a, .GET, "/x")

	testing.expect_value(t, order_of(&sink), "A>B>C>H<C<B<A")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "handler")
}

@(test)
wp17_public_short_circuit_response_wins :: proc(t: ^testing.T) {
	sink: Sink
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, mw_a)
	web.use(&a, mw_deny)
	web.get(&a, "/x", handler)

	res := web.test_request(&a, .GET, "/x")

	testing.expect_value(t, order_of(&sink), "A>STOP<A")
	testing.expect_value(t, sink.handler_runs, 0)
	testing.expect_value(t, res.status, web.Status.Forbidden)
	testing.expect_value(t, res.body, "denied")
}

@(test)
wp17_public_middleware_observe_a_404_and_a_405 :: proc(t: ^testing.T) {
	sink: Sink
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, mw_a)
	web.post(&a, "/only", handler)

	miss := web.test_request(&a, .GET, "/nope")
	testing.expect_value(t, miss.status, web.Status.Not_Found)
	testing.expect_value(t, miss.body, NOT_FOUND_ENVELOPE)

	wrong_method := web.test_request(&a, .GET, "/only")
	testing.expect_value(t, wrong_method.status, web.Status.Method_Not_Allowed)
	testing.expect_value(t, wrong_method.body, METHOD_NOT_ALLOWED_ENVELOPE)

	// Both misses entered AND unwound the global middleware (ADR-023).
	testing.expect_value(t, order_of(&sink), "A><AA><A")
	testing.expect_value(t, sink.handler_runs, 0)
}

@(test)
wp17_public_bare_miss_is_observed_and_stays_unanswered :: proc(t: ^testing.T) {
	sink: Sink
	context.user_ptr = &sink
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	a := web.bare()
	defer web.destroy(&a)
	web.use(&a, mw_a)

	res := web.test_request(&a, .GET, "/nope")

	// The middleware observed the miss; `bare()` still installs no policy, so
	// nothing was committed and the driver's 500 finalization applied.
	testing.expect_value(t, order_of(&sink), "A><A")
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
	testing.expect_value(t, res.body, INTERNAL_ENVELOPE)
}

// ---------------------------------------------------------------------------
// The security boundary (ADR-019): ordering is enforced, not documented.
// ---------------------------------------------------------------------------

@(test)
wp17_mis_ordered_auth_program_does_not_serve_the_protected_route :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	a := web.app()
	defer web.destroy(&a)

	// The WP12 D-12.5 transcript: this program measured
	//   GET /admin/users -> 200 OK   [admin_users ran — SECRETS SERVED]
	// on the prototype. It reads top to bottom as "my admin routes and my auth
	// middleware"; nothing about it looks wrong; the only signal is line order.
	web.get(&a, "/admin/users", admin_users)
	web.use(&a, require_auth)
	web.get(&a, "/admin/keys", admin_users)

	res := web.test_request(&a, .GET, "/admin/users")

	// Fail-closed: the mis-ordered application serves NOTHING — not the
	// protected body, not a healthy 200. Every request answers 500.
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
	testing.expect(
		t,
		!contains(res.body, "TOP-SECRET"),
		"an unauthenticated caller must never receive the protected body",
	)

	also := web.test_request(&a, .GET, "/admin/keys")
	testing.expect_value(t, also.status, web.Status.Internal_Server_Error)
}

@(test)
wp17_correctly_ordered_auth_program_protects_and_serves :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)

	web.use(&a, require_auth)
	web.get(&a, "/admin/users", admin_users)

	denied := web.test_request(&a, .GET, "/admin/users")
	testing.expect_value(t, denied.status, web.Status.Unauthorized)
	testing.expect(t, !contains(denied.body, "TOP-SECRET"))

	granted := web.test_request(&a, .GET, "/admin/users", query = "token=s3cret")
	testing.expect_value(t, granted.status, web.Status.OK)
	testing.expect_value(t, granted.body, "TOP-SECRET-USERS")
}

// ---------------------------------------------------------------------------
// Shape and lifetime.
// ---------------------------------------------------------------------------

@(test)
wp17_use_and_next_signatures_are_pinned :: proc(t: ^testing.T) {
	// Pinned as procedure VALUES: a signature change is a compile error here,
	// by design (the WP7/WP9 precedent).
	use_sig: proc(a: ^web.App, middleware: web.Handler) = web.use
	next_sig: proc(ctx: ^web.Context) = web.next

	sink: Sink
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	use_sig(&a, mw_a)
	web.get(&a, "/x", handler)

	res := web.test_request(&a, .GET, "/x")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(t, next_sig != nil)
}

@(test)
wp17_an_app_with_middleware_tears_down_cleanly :: proc(t: ^testing.T) {
	// `odin test` tracks allocations by default: a leaked chain pool or a
	// double free fails this test without any explicit assertion.
	sink: Sink
	context.user_ptr = &sink

	a := web.app()
	web.use(&a, mw_a)
	web.use(&a, mw_b)
	web.get(&a, "/x", handler)

	_ = web.test_request(&a, .GET, "/x")
	_ = web.test_request(&a, .GET, "/nope")

	web.destroy(&a)
}
