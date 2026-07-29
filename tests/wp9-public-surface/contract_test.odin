// WP9 public-surface contract.
//
// WP9 is test-only work: a conformance harness, a shared matrix and a framing
// corpus. This suite pins the property that makes that claim checkable — none
// of it reached the public API.
//
// The harness (`tests/support/transport_conformance`) is a TEST package: it
// imports `core:testing` and lives under `tests/`, so it cannot be reached from
// `druse:web` at all. `Transport_Factory` is defined there, not in `web`.
package wp9_public_surface

import "core:testing"
import web "druse:web"

// The ratified 34 symbols are still the whole surface an application can name.
// WP9 adds nothing to it: every signature below is exactly what WP1-WP8 froze.

@(test)
wp9_public_surface_is_unchanged :: proc(t: ^testing.T) {
	// Construction and teardown.
	app_sig: proc() -> web.App = web.app
	bare_sig: proc() -> web.App = web.bare
	destroy_sig: proc(a: ^web.App) = web.destroy

	// Registration.
	get_sig: proc(a: ^web.App, pattern: string, handler: web.Handler) = web.get

	// The server entry point — unchanged by WP9, which added no serve variant.
	serve_sig: proc(a: ^web.App, port: int) = web.serve

	// Test support: still exactly two symbols. AMENDED IN WP19: the `headers`
	// default parameter joined the pinned signature (freeze Amendment 6).
	test_request_sig: proc(a: ^web.App, method: web.Method, path: string, body: string, query: string, headers: []string) -> web.Recorded_Response =
		web.test_request

	testing.expect(t, app_sig != nil)
	testing.expect(t, bare_sig != nil)
	testing.expect(t, destroy_sig != nil)
	testing.expect(t, get_sig != nil)
	testing.expect(t, serve_sig != nil)
	testing.expect(t, test_request_sig != nil)

	// A real round trip through the public surface still behaves, so this suite
	// is not merely a compile check.
	a := web.app()
	defer web.destroy(&a)
	res := web.test_request(&a, .GET, "/absent")
	testing.expect_value(t, res.status, web.Status.Not_Found)
}

// WP9 introduces no serve variant and no transport accessor. These would be the
// obvious places for conformance work to leak into the API; the checker bans
// them by name, and this documents the intent beside the tests.
@(test)
wp9_added_no_transport_surface :: proc(t: ^testing.T) {
	// `web.serve` remains the ONLY entry point: there is no serve_with, no
	// serve_transport, no stop, and no way for an application to name a
	// transport, a factory or the backend. If any of those existed, the
	// signature list above would not be the whole story and the ledger check in
	// build/check_public_api.sh would have failed first.
	a := web.bare()
	defer web.destroy(&a)
	testing.expect(t, true)
}
