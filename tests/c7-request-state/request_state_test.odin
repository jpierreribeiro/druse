// C7 — corrective WP for friction F8-3: web.request_state, ONE typed
// request-scoped value (the narrow ADR-028 reopening). The ledger's RED test:
// RED before C7 (a middleware had nowhere to hand a handler a typed value), GREEN
// after. Driven through the public in-memory transport.
package test_c7_request_state

import "core:testing"
import web "druse:web"

Auth :: struct {
	account_id: i64,
	name:       string,
}

// The middleware resolves an identity and stamps it into the request's typed slot;
// the handler reads it back WITHOUT recomputing — the hand-off F8-3 measured the
// absence of.
@(private = "file")
auth_mw :: proc(ctx: ^web.Context) {
	a := web.request_state(ctx, Auth)
	a.account_id = 42
	a.name = "grace"
	web.next(ctx)
}

@(private = "file")
me_handler :: proc(ctx: ^web.Context) {
	a := web.request_state(ctx, Auth) // same type -> the SAME pointer the middleware wrote
	if a.account_id != 42 {
		web.text(ctx, .Internal_Server_Error, "state did not flow")
		return
	}
	web.text(ctx, .OK, a.name)
}

@(test)
c7_request_state_flows_from_middleware_to_handler :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.use(&a, auth_mw)
	web.get(&a, "/me", me_handler)

	res := web.test_request(&a, .GET, "/me")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "grace") // the middleware's value reached the handler
}

// A second request must NOT see the first request's value: a fresh Context per
// request means the slot starts unset.
@(private = "file")
first_or_default_handler :: proc(ctx: ^web.Context) {
	a := web.request_state(ctx, Auth)
	// A fresh request's slot is zeroed on first access, so account_id is 0 unless
	// THIS request wrote it. This handler never writes, so it must always read 0.
	if a.account_id == 0 {
		web.text(ctx, .OK, "clean")
	} else {
		web.text(ctx, .OK, "leaked")
	}
}

@(test)
c7_request_state_does_not_leak_across_requests :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/clean", first_or_default_handler)

	r1 := web.test_request(&a, .GET, "/clean")
	testing.expect_value(t, r1.body, "clean")
	r2 := web.test_request(&a, .GET, "/clean")
	testing.expect_value(t, r2.body, "clean") // still clean — no cross-request leak
}

// Two accesses with the same type in one request return the SAME pointer, so a
// write through one is visible through the other.
@(private = "file")
same_pointer_handler :: proc(ctx: ^web.Context) {
	p1 := web.request_state(ctx, Auth)
	p1.account_id = 7
	p2 := web.request_state(ctx, Auth)
	if p1 == p2 && p2.account_id == 7 {
		web.text(ctx, .OK, "same")
	} else {
		web.text(ctx, .Internal_Server_Error, "different")
	}
}

@(test)
c7_same_type_returns_same_pointer :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/same", same_pointer_handler)

	res := web.test_request(&a, .GET, "/same")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "same")
}
