// C1 — corrective WP for friction F8-1: the public Status enum gains the
// operationally-essential codes (409/413/429/503) three independent applications
// were forced to spell as raw-int casts. This suite is the ledger's RED test:
// RED before C1 (the named members did not exist), GREEN after.
//
// It runs on the in-memory test transport (web.test_request) — no socket needed —
// and asserts both the enum's backing values and that a handler responding with a
// named member puts the right status on the wire.
package test_c1_status_codes

import "core:testing"
import web "druse:web"

@(test)
c1_named_members_equal_their_http_codes :: proc(t: ^testing.T) {
	// The whole point of F8-1: a status is a checked, named value — not a cast.
	testing.expect_value(t, int(web.Status.Conflict), 409)
	testing.expect_value(t, int(web.Status.Payload_Too_Large), 413)
	testing.expect_value(t, int(web.Status.Too_Many_Requests), 429)
	testing.expect_value(t, int(web.Status.Service_Unavailable), 503)
}

unavailable_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .Service_Unavailable, "not ready")
}

conflict_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .Conflict, "version conflict")
}

too_large_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .Payload_Too_Large, "too big")
}

@(test)
c1_named_members_reach_the_wire :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/unavailable", unavailable_handler)
	web.get(&a, "/conflict", conflict_handler)
	web.get(&a, "/too-large", too_large_handler)

	r1 := web.test_request(&a, .GET, "/unavailable")
	testing.expect_value(t, r1.status, web.Status.Service_Unavailable)
	testing.expect_value(t, int(r1.status), 503)

	r2 := web.test_request(&a, .GET, "/conflict")
	testing.expect_value(t, r2.status, web.Status.Conflict)
	testing.expect_value(t, int(r2.status), 409)

	r3 := web.test_request(&a, .GET, "/too-large")
	testing.expect_value(t, r3.status, web.Status.Payload_Too_Large)
	testing.expect_value(t, int(r3.status), 413)
}
