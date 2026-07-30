// WP14 — REQUEST BODIES ARE TESTABLE IN MEMORY.
//
// Phase 1 froze `test_request` at method + path, so a handler calling
// `web.body` could never reach its success path without a socket: it always saw
// `invalid_json`. The framework's own tests reached it only by copying
// `web/*.odin` into a throwaway package, which an application cannot do.
//
// WP14 adds the body as a DEFAULT PARAMETER on the existing procedure rather
// than a second name or a procedure group (ADR-021, amended). A group over
// private members renders in `odin doc` as member names only, so the freeze
// snapshot would pin the name and not the signature — measured, and now
// rejected by the gate. A default parameter keeps the whole contract frozen.
package test_wp14_public_surface

import "core:testing"
import web "druse:web"

Create_User :: struct {
	name:  string,
	email: string,
}

create :: proc(ctx: ^web.Context) {
	input: Create_User
	if !web.body(ctx, &input) {
		return
	}
	web.created(ctx, input)
}

// The gap WP14 exists to close: before it, this returned 400 invalid_json,
// because there was no way to give the request a body at all.
@(test)
wp14_a_json_body_reaches_the_handler :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/users", create)

	res := web.test_request(&app, .POST, "/users", `{"name":"Ada","email":"a@b.c"}`)

	testing.expect_value(t, res.status, web.Status.Created)
	testing.expect_value(t, res.body, `{"name":"Ada","email":"a@b.c"}`)
}

// The default keeps every Phase-1 call site working unchanged. This is the
// same three-argument form the frozen surface has always had.
@(test)
wp14_the_three_argument_form_is_unchanged :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/users", create)

	res := web.test_request(&app, .POST, "/users")

	// No body supplied means an empty body, which is still a 400 — exactly the
	// Phase-1 behavior, preserved.
	testing.expect_value(t, res.status, web.Status.Bad_Request)
}

// Parity with the real transport is the property that makes in-memory testing
// trustworthy (R-10): the cap is enforced on this path too, not only on a
// socket. A body over 4 MiB must be rejected before the arena or the parser.
@(test)
wp14_the_body_cap_holds_on_the_memory_transport :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/users", create)

	oversized := make([]u8, 4 * 1024 * 1024 + 1)
	defer delete(oversized)
	for i in 0 ..< len(oversized) {
		oversized[i] = 'x'
	}

	res := web.test_request(&app, .POST, "/users", string(oversized))

	// 413, and asserted as an integer on purpose. Phase 1 deliberately kept 413
	// OUT of the public `Status` enum — the cap is a private HTTP behavior of
	// the transport (planning/phase-1-freeze.md §4). Now that the cap is
	// reachable in memory, that decision has a visible consequence worth
	// pinning: `Recorded_Response.status` can hold a value with no `Status`
	// member, so it must be compared numerically. This is the frozen design
	// meeting the new capability, not a defect — but a user WILL hit it the
	// first time they test the cap, so the contract is recorded here.
	testing.expect_value(t, int(res.status), 413)
}

// Malformed JSON is a 400 through this path too, not a crash or a 500.
@(test)
wp14_malformed_json_is_a_400 :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/users", create)

	res := web.test_request(&app, .POST, "/users", `{"name":`)

	testing.expect_value(t, res.status, web.Status.Bad_Request)
}
