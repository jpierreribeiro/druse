// WP49 public-surface contract — secure response headers, and D-14.3 decided.
//
// ONE APPLICATION SYMBOL (`secure_headers`) plus a FIELD on `Recorded_Response`.
//
// **THIS SUITE COULD NOT HAVE BEEN WRITTEN BEFORE THIS WORK PACKAGE**, and that
// is the argument that decided D-14.3. Phase 2 kept `Recorded_Response` at
// `status` and `body`, so an assertion about a response header had to be an
// INTERNAL `package web` test. Tolerable while the only header in question was
// one the framework set for itself; not tolerable for a feature whose entire
// purpose is letting an application assert its own security posture.
//
// An application that cannot observe the headers it asked for has to test
// through a socket — which is the thing `test_request` exists to avoid.
package test_wp49_public

import "core:strings"
import "core:testing"
import web "druse:web"

@(private = "file")
ok_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

@(private = "file")
has_header :: proc(res: web.Recorded_Response, line: string) -> bool {
	for h in res.headers {
		if strings.equal_fold(h, line) {
			return true
		}
	}
	return false
}

// The signature is pinned by assignment; `secure_headers` is an ordinary
// `Handler`, which is what makes it registerable with `use` and composable with
// every other middleware.
@(test)
wp49_the_signature_is_pinned :: proc(t: ^testing.T) {
	pinned: web.Handler = web.secure_headers
	testing.expect(t, pinned != nil, "secure_headers must be an ordinary Handler")
}

// The three headers, on an ordinary 200.
@(test)
wp49_the_three_headers_are_set :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.use(&app, web.secure_headers)
	web.get(&app, "/ping", ok_handler)

	res := web.test_request(&app, .GET, "/ping")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(t, has_header(res, "X-Content-Type-Options: nosniff"), "nosniff must be set")
	testing.expect(t, has_header(res, "X-Frame-Options: DENY"), "framing must be refused")
	testing.expect(t, has_header(res, "Referrer-Policy: no-referrer"), "the referrer must not leak")
}

// **THE CASE THE DESIGN EXISTS FOR.** The headers must be on the automatic 404
// too — a response the middleware chain produces but the handler never sees.
//
// This is why `secure_headers` sets a FLAG the response builder reads rather
// than stamping the response as the chain unwinds.
@(test)
wp49_the_headers_are_on_a_404 :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.use(&app, web.secure_headers)
	web.get(&app, "/ping", ok_handler)

	res := web.test_request(&app, .GET, "/absent")
	testing.expect_value(t, res.status, web.Status.Not_Found)
	testing.expect(t, has_header(res, "X-Content-Type-Options: nosniff"), "a 404 is still a response an attacker reads")
}

// And on a 405, which carries `Allow` and `Content-Type` already — so this is
// also the test that the six-header capacity is real rather than arithmetic on
// paper.
@(test)
wp49_the_headers_coexist_with_allow_on_a_405 :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.use(&app, web.secure_headers)
	web.get(&app, "/ping", ok_handler)

	res := web.test_request(&app, .POST, "/ping")
	testing.expect_value(t, res.status, web.Status.Method_Not_Allowed)
	testing.expect(t, has_header(res, "X-Frame-Options: DENY"), "the security headers survive beside Allow")

	allow_present := false
	for h in res.headers {
		if strings.has_prefix(h, "Allow:") {
			allow_present = true
		}
	}
	testing.expect(t, allow_present, "Allow must still be present; the capacity is 2 + 1 + 3, not a trade")
}

// THE NEGATIVE CONTROL, and it is the one that matters: an application that
// does NOT register the middleware must not get the headers. Without it, a
// framework that set them unconditionally would pass every test above — and
// would have taken away an application's ability to choose its own policy.
@(test)
wp49_without_the_middleware_there_are_no_security_headers :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", ok_handler)

	res := web.test_request(&app, .GET, "/ping")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(
		t,
		!has_header(res, "X-Frame-Options: DENY"),
		"a header the framework sets without being asked is a header an application cannot remove",
	)
}

// ---------------------------------------------------------------------------
// D-14.3 — the field itself
// ---------------------------------------------------------------------------

// `Recorded_Response.headers` is present, carries wire-form lines, and is not
// empty for an ordinary response. This is the decision, asserted.
@(test)
wp49_recorded_response_exposes_header_lines :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", ok_handler)

	res := web.test_request(&app, .GET, "/ping")
	testing.expect(t, len(res.headers) > 0, "an ordinary response carries at least Content-Type")

	found := false
	for h in res.headers {
		testing.expect(t, strings.contains(h, ": "), "each entry is a wire-form 'Name: value' line")
		if strings.has_prefix(h, "content-type:") || strings.has_prefix(h, "Content-Type:") {
			found = true
		}
	}
	testing.expect(t, found, "Content-Type must be visible through the recorded headers")
}

// The lifetime rule, asserted rather than only documented: the slice belongs to
// the recorder and is replaced by the NEXT request, exactly as `body` is.
@(test)
wp49_recorded_headers_belong_to_the_last_request :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.use(&app, web.secure_headers)
	web.get(&app, "/ping", ok_handler)

	first := web.test_request(&app, .GET, "/ping")
	testing.expect(t, has_header(first, "X-Frame-Options: DENY"), "the first response carries them")

	second := web.test_request(&app, .GET, "/absent")
	testing.expect_value(t, second.status, web.Status.Not_Found)
	testing.expect(t, has_header(second, "X-Frame-Options: DENY"), "so does the second")
}
