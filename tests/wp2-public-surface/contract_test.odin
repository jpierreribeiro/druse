// WP2 public-surface contract, from OUTSIDE the package.
//
// This package is an EXTERNAL consumer of `druse:web`. It proves that the
// three symbols WP2 adds — `Request`, `Method`, `Header_View` — exist with the
// exact ratified names, are actually exported, and compose as the spec writes
// them (`knowledge-base/01-architecture-spec.md` §Request/Response ownership).
//
// What is NOT provable from here, and is therefore tested inside the package
// (web/wp2_internal_test.odin): the commit guard, method conversion, and view
// invalidation. Those cover package-private declarations, which no external
// package can name.
//
// The matching NEGATIVE contract — that `Header_Pair`, `Header_View_Internal`
// and `ctx.response` are NOT reachable — cannot be written here either, since
// it must fail to compile. It lives in `probes/`, driven by build/check.sh.
package wp2_public_surface

import "core:testing"
import web "druse:web"

// --- Method: the ratified spelling is UPPERCASE ---

@(test)
wp2_method_members_are_uppercase :: proc(t: ^testing.T) {
	// `.GET`, never `.Get`. The canonical spelling is ratified, and this test
	// fails to COMPILE if a member is renamed.
	m: web.Method = .GET

	testing.expect(t, m == .GET)
	testing.expect(t, m != .POST)

	// The complete Phase-1 set, named explicitly so that adding or removing a
	// member is a visible change to this contract.
	all := [?]web.Method{.UNKNOWN, .GET, .POST, .PUT, .PATCH, .DELETE}
	testing.expect_value(t, len(all), 6)

	// `.UNKNOWN` is the zero value: a zero Request is not accidentally a GET.
	zero: web.Method
	testing.expect(t, zero == .UNKNOWN)
}

// --- Request: exact public field set ---

@(test)
wp2_request_exposes_the_ratified_fields :: proc(t: ^testing.T) {
	r: web.Request

	// Named assignment proves each field exists with the ratified name and
	// type. Views over caller memory, exactly as a transport would build them.
	body := [?]u8{'h', 'i'}
	r.method = .POST
	r.path = "/users"
	r.query = "page=2"
	r.body = body[:]

	testing.expect_value(t, r.method, web.Method.POST)
	testing.expect_value(t, r.path, "/users")
	testing.expect_value(t, r.query, "page=2")
	testing.expect_value(t, string(r.body), "hi")

	// `headers` is a Header_View and composes into Request by value.
	h: web.Header_View
	r.headers = h
	_ = r.headers
}

// --- Context: carries the request, and no public response ---

@(test)
wp2_context_carries_the_request :: proc(t: ^testing.T) {
	ctx: web.Context

	// `ctx.request` is the ONLY public request surface in Phase 1. There is no
	// `ctx.response`, no `ctx.params`, no `ctx.route`: see probes/.
	ctx.request.method = .DELETE
	ctx.request.path = "/users/1"

	testing.expect_value(t, ctx.request.method, web.Method.DELETE)
	testing.expect_value(t, ctx.request.path, "/users/1")
	testing.expect_value(t, ctx.request.query, "")
	testing.expect_value(t, len(ctx.request.body), 0)
}

// --- The handler shape did not change ---

wp2_handler_still_takes_only_context :: proc(ctx: ^web.Context) {
	// A handler reads the request through `ctx.request` and responds through
	// the helpers. WP2 adds no second handler shape and no response object.
	if ctx.request.method == .GET {
		return
	}
}

@(test)
wp2_handler_signature_is_unchanged :: proc(t: ^testing.T) {
	h: web.Handler = wp2_handler_still_takes_only_context
	testing.expect(t, h != nil, "Handler must stay exactly proc(ctx: ^web.Context)")
}

// --- Phase-1 documented lifetime rule, stated as executable intent ---

@(test)
wp2_request_views_are_plain_values_the_caller_may_copy :: proc(t: ^testing.T) {
	// Copying is an ordinary explicit operation on ordinary Odin values: WP2
	// introduces no handle, no accessor, and nothing to unwrap. What the
	// framework does NOT do is copy on the application's behalf.
	r: web.Request
	r.path = "/users"

	saved := make([]u8, len(r.path))
	defer delete(saved)
	copy(saved, transmute([]u8)r.path)

	testing.expect_value(t, string(saved), "/users")
}
