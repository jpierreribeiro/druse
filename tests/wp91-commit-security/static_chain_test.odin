// WP91 (F5/F6) — static responses run the ordinary middleware chain.
//
// The Phase-6-freeze scan recorded the gap as two findings: static files got
// no `secure_headers` (F5) and no global `use` middleware — auth, logging,
// rate limits (F6). The decision (`phase-7-spec.md` §8.2): a mount keeps
// prefix ownership, the response joins the chain. These tests pin the fix on
// the in-memory transport, which shares `driver_run` with the socket
// (R-10) — plus the boundaries that must NOT have moved: refusal semantics,
// non-GET routing and prefix ownership.
package test_wp91_commit_security

import "core:os"
import "core:strings"
import "core:testing"
import web "druse:web"

FIXTURE :: "tests/wp91-commit-security/fixture"

@(private = "file")
make_fixture :: proc() -> bool {
	if os.make_directory(FIXTURE) != nil && !os.exists(FIXTURE) {
		return false
	}
	return os.write_entire_file(FIXTURE + "/app.js", transmute([]u8)string("console.log(1)")) == nil
}

@(private = "file")
drop_fixture :: proc() {
	_ = os.remove(FIXTURE + "/app.js")
	_ = os.remove(FIXTURE)
}

@(private = "file")
State :: struct {
	middleware_hits: int,
	deny:            bool,
}

@(private = "file")
counting_gate :: proc(ctx: ^web.Context) {
	state, state_ok := web.state(ctx, State)
	if !state_ok {
		web.internal_error(ctx)
		return
	}
	state.middleware_hits += 1
	if state.deny {
		web.unauthorized(ctx, "no")
		return
	}
	web.next(ctx)
}

@(private = "file")
guarded_app :: proc(a: ^web.App, state: ^State) -> bool {
	if !make_fixture() {
		return false
	}
	a^ = web.app_with_state(state)
	web.use(a, counting_gate)
	web.use(a, web.secure_headers)
	web.static(a, "/assets", FIXTURE, web.Static_Options{})
	web.get(a, "/ping", proc(ctx: ^web.Context) {web.text(ctx, .OK, "pong")})
	return true
}

@(private = "file")
has_header :: proc(res: web.Recorded_Response, needle: string) -> bool {
	for h in res.headers {
		if strings.contains(h, needle) {
			return true
		}
	}
	return false
}

@(test)
wp91_global_middleware_runs_for_a_static_file :: proc(t: ^testing.T) {
	state: State
	app: web.App
	testing.expect(t, guarded_app(&app, &state), "fixture and app must build")
	defer {web.destroy(&app); drop_fixture()}

	res := web.test_request(&app, .GET, "/assets/app.js")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "console.log(1)")
	testing.expect_value(t, state.middleware_hits, 1)
}

@(test)
wp91_secure_headers_cover_a_static_response :: proc(t: ^testing.T) {
	state: State
	app: web.App
	testing.expect(t, guarded_app(&app, &state), "fixture and app must build")
	defer {web.destroy(&app); drop_fixture()}

	res := web.test_request(&app, .GET, "/assets/app.js")
	testing.expect_value(t, res.status, web.Status.OK)
	// F5, dead: the policy header set travels with the file.
	testing.expect(t, has_header(res, "X-Content-Type-Options"), "nosniff must cover static responses")
	testing.expect(t, has_header(res, "X-Frame-Options"), "frame policy must cover static responses")
}

@(test)
wp91_an_auth_refusal_blocks_a_static_file :: proc(t: ^testing.T) {
	state: State
	state.deny = true
	app: web.App
	testing.expect(t, guarded_app(&app, &state), "fixture and app must build")
	defer {web.destroy(&app); drop_fixture()}

	res := web.test_request(&app, .GET, "/assets/app.js")
	// F6, dead: an application relying on static bypassing auth was relying
	// on the vulnerability (the spec's compatibility note, verbatim).
	testing.expect_value(t, res.status, web.Status.Unauthorized)
	testing.expect(t, !strings.contains(res.body, "console.log"), "the refused file's bytes must not leak")
	testing.expect_value(t, state.middleware_hits, 1)
}

@(test)
wp91_refusal_semantics_and_routing_boundaries_are_unchanged :: proc(t: ^testing.T) {
	state: State
	app: web.App
	testing.expect(t, guarded_app(&app, &state), "fixture and app must build")
	defer {web.destroy(&app); drop_fixture()}

	// Traversal is still the mount's own 404, indistinguishable from absence.
	res := web.test_request(&app, .GET, "/assets/../secret")
	testing.expect_value(t, res.status, web.Status.Not_Found)
	// A POST under the mount is still the router's business.
	res = web.test_request(&app, .POST, "/assets/app.js")
	testing.expect(t, res.status == web.Status.Not_Found || res.status == web.Status.Method_Not_Allowed, "non-GET keeps its routing answer")
	// The prefix boundary holds.
	res = web.test_request(&app, .GET, "/assetsx")
	testing.expect_value(t, res.status, web.Status.Not_Found)
	// An ordinary route still works behind the same gate.
	res = web.test_request(&app, .GET, "/ping")
	testing.expect_value(t, res.status, web.Status.OK)
}
