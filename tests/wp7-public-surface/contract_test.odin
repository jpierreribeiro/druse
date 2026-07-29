// WP7 public-surface contract, from OUTSIDE the package.
//
// This package is an EXTERNAL consumer of `druse:web`. It exercises
// `web.body` through the ratified public surface only, and adds NO public
// symbol — every test uses the same 34 symbols that existed before WP7.
//
// WHAT THIS SUITE DELIBERATELY DOES NOT DO: bind a NON-EMPTY body from an
// external Context. `web.body` decodes into a request-lifetime arena, and the
// arena teardown (`request_arena_destroy`) is package-private — it is the
// response DRIVER's job, exactly like the WP6 response teardown. An external
// consumer that built a `web.Context` by hand and bound a non-empty body would
// have no way to release the arena, so doing it here would leak under the test
// runner's memory tracking. That is not a defect: in real use the driver
// (today `web.test_request`, tomorrow the WP8 adapter) owns request teardown,
// and applications never hand-build a Context. Successful binding, malformed
// input, JSON5 rejection, the 4 MiB cap, ownership and the single-consumer
// state machine are therefore pinned INTERNALLY, in tests/wp7-internal/, where
// the teardown is callable. What remains observable here is the public
// signature, the empty-body path (which allocates no arena), and a body handler
// driven end-to-end through the framework's own driver.
package wp7_public_surface

import "core:encoding/json"
import "core:testing"
import web "druse:web"

Create_User :: struct {
	name:  string   `json:"name"`,
	email: string   `json:"email"`,
	roles: []string `json:"roles"`,
}

// ---------------------------------------------------------------------------
// 1. The canonical destination-filling signature is unchanged.
// ---------------------------------------------------------------------------

@(test)
wp7_signature_is_the_canonical_destination_filling_shape :: proc(t: ^testing.T) {
	// The compile-time check is the assignment: it fails to compile if the
	// signature ever drifts from `body(ctx, &dst) -> bool`. Calling it on an
	// empty body (which returns false and allocates no arena) proves the
	// assigned instantiation is real and callable — and leaks nothing.
	sig: proc(ctx: ^web.Context, dst: ^Create_User) -> bool = web.body
	ctx: web.Context
	dst: Create_User
	testing.expect(t, !sig(&ctx, &dst))
}

// ---------------------------------------------------------------------------
// 2. The empty-body path is observable and allocation-free.
// ---------------------------------------------------------------------------

@(test)
wp7_empty_body_reports_failure :: proc(t: ^testing.T) {
	ctx: web.Context
	// No body set: this is the one failure an external Context can drive without
	// initializing the arena, so it needs no teardown.
	input: Create_User
	testing.expect(t, !web.body(&ctx, &input), "an empty body must not bind")
}

// ---------------------------------------------------------------------------
// 3. A body handler driven end to end through the framework's own driver.
//
//    Called WITHOUT a body — the three-argument form — so binding here takes
//    the empty-body 400 path, and the driver runs the full response AND arena
//    teardown, proving that a request routed to a body handler tears down
//    cleanly under memory tracking.
//
//    WP14 later added an optional `body` parameter, so the success path IS now
//    reachable in memory; it is covered by tests/wp14-public-surface. This test
//    deliberately keeps exercising the empty-body path, which is unchanged.
// ---------------------------------------------------------------------------

wp7_handler_hits: int

create_user_handler :: proc(ctx: ^web.Context) {
	wp7_handler_hits += 1
	input: Create_User
	if !web.body(ctx, &input) {
		return
	}
	// The canonical shape. Reachable in memory since WP14 added the optional
	// body parameter; exercised by tests/wp14-public-surface.
	web.created(ctx, input)
}

@(test)
wp7_body_handler_via_test_request_produces_invalid_json :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/users", create_user_handler)

	before := wp7_handler_hits
	res := web.test_request(&a, .POST, "/users")

	testing.expect_value(t, wp7_handler_hits - before, 1)

	// The empty body is invalid JSON: the extractor committed the envelope
	// itself, so the handler simply returned.
	testing.expect_value(t, res.status, web.Status.Bad_Request)

	value, err := json.parse_string(res.body, json.Specification.JSON, false, context.allocator)
	testing.expect_value(t, err, json.Error.None)
	defer json.destroy_value(value, context.allocator)
	root := value.(json.Object) or_else nil
	inner := root["error"].(json.Object) or_else nil
	testing.expect(t, inner != nil)
	testing.expect_value(t, string(inner["code"].(json.String) or_else ""), "invalid_json")
	testing.expect_value(
		t,
		string(inner["message"].(json.String) or_else ""),
		"Request body must be valid JSON",
	)
}

// ---------------------------------------------------------------------------
// 4. The exact frozen shapes of `web.test_request` and `web.serve`, pinned as
//    procedure values so a signature drift is a COMPILE error here rather than
//    a snapshot diff somewhere else.
//
//    `test_request` carries the optional `body` and `query` parameters added by
//    the WP14 freeze amendments (planning/phase-1-freeze.md, Amendments 1 and
//    2). Their defaults are what keep every three-argument call site compiling
//    and behaving exactly as Phase 1 froze it.
// ---------------------------------------------------------------------------

@(test)
wp7_test_request_signature_is_pinned :: proc(t: ^testing.T) {
	// AMENDED IN WP19: `headers` joined the signature as the third fully
	// visible default parameter (freeze Amendment 6).
	sig: proc(a: ^web.App, method: web.Method, path: string, body: string, query: string, headers: []string) -> web.Recorded_Response = web.test_request
	serve_sig: proc(a: ^web.App, port: int) = web.serve
	a := web.app()
	defer web.destroy(&a)
	// Called through the pinned procedure VALUE, which is why the body is passed
	// explicitly: a procedure TYPE carries no default values in Odin, so
	// `sig` requires all four arguments even though `web.test_request` itself
	// defaults the last one. That is a useful property here — the pin exercises
	// the complete signature rather than the convenient call shape.
	res := sig(&a, .GET, "/nope", "", "", nil)
	testing.expect_value(t, res.status, web.Status.Not_Found)
	testing.expect(t, serve_sig != nil)
}
