// WP19 public surface contract — `header` and `bearer_token` as an EXTERNAL
// consumer of `uruquim:web` sees them, plus the `headers` parameter that makes
// them testable in memory.
//
// The canonical pattern this suite pins is the one the docs teach from today
// on: a bearer-auth middleware guarding routes, driven end-to-end through
// `web.test_request` with a real Authorization header — no socket.
package test_wp19_public

import "core:strings"
import "core:testing"
import web "uruquim:web"

require_auth :: proc(ctx: ^web.Context) {
	token, ok := web.bearer_token(ctx)
	if !ok || token != "s3cret" {
		web.unauthorized(ctx, "authentication required")
		return
	}
	web.next(ctx)
}

whoami :: proc(ctx: ^web.Context) {
	key, ok := web.header(ctx, "x-api-key")
	if !ok {
		web.not_found(ctx, "header")
		return
	}
	web.text(ctx, .OK, key)
}

secret :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "TOP-SECRET")
}

empty_probe :: proc(ctx: ^web.Context) {
	value, ok := web.header(ctx, "x-empty")
	if !ok {
		web.not_found(ctx, "header")
		return
	}
	if value == "" {
		web.text(ctx, .OK, "present-and-empty")
		return
	}
	web.text(ctx, .OK, value)
}

first_wins_probe :: proc(ctx: ^web.Context) {
	value, _ := web.header(ctx, "x-dup")
	web.text(ctx, .OK, value)
}

// ---------------------------------------------------------------------------
// Lookups through the ratified surface.
// ---------------------------------------------------------------------------

@(test)
wp19_public_header_reaches_the_handler_case_insensitively :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/whoami", whoami)

	res := web.test_request(&a, .GET, "/whoami", headers = {"X-API-KEY: k-99"})
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "k-99")

	absent := web.test_request(&a, .GET, "/whoami")
	testing.expect_value(t, absent.status, web.Status.Not_Found)
}

@(test)
wp19_public_empty_value_is_present :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/empty", empty_probe)

	res := web.test_request(&a, .GET, "/empty", headers = {"X-Empty:"})
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "present-and-empty")

	missing := web.test_request(&a, .GET, "/empty")
	testing.expect_value(t, missing.status, web.Status.Not_Found)
}

// THE DEFECT THIS PINS. This case used to be named
// `wp19_public_duplicates_first_occurrence_wins` and asserted `"first"`, which
// is what the in-memory driver did and what the docs promised in four places.
// It is not what a socket does. The backend's `header_parse` combines repeated
// names into one entry with `", "` (RFC 9110 §5.3) before the core sees them,
// so the same request over the wire reaches `header` as `"first, second"` —
// measured on a real socket. The two drivers disagreed on a documented
// contract and this test ratified the wrong one: the failure mode the project
// already recorded for J1 (a fast path and a fallback classifying the same
// input differently) and for S2 (a test whose name is broader than its
// evidence). `test_request` now merges, so both drivers answer alike.
@(test)
wp19_public_duplicates_are_joined_like_the_wire :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/dup", first_wins_probe)

	res := web.test_request(
		&a,
		.GET,
		"/dup",
		headers = {"X-Dup: first", "x-dup: second"},
	)
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "first, second")
}

// The security-relevant consequence of the join, stated as a test rather than
// as a claim in a comment: two `Authorization` headers do NOT resolve to one of
// them. They join into `"Bearer a, Bearer b"`, whose token would contain a
// comma and a space, and the strict RFC 6750 grammar refuses whitespace inside
// the token — so the request is unauthenticated, not authenticated as either
// credential. A framework that silently picked the first (or the last) would be
// making a smuggling decision on the application's behalf.
@(test)
wp19_public_a_duplicated_authorization_is_refused :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.use(&a, require_auth)
	web.get(&a, "/secret", secret)

	// The first credential is the valid one; if first-occurrence-wins were the
	// rule, this would be a 200.
	res := web.test_request(
		&a,
		.GET,
		"/secret",
		headers = {"Authorization: Bearer s3cret", "Authorization: Bearer other"},
	)
	testing.expect_value(t, res.status, web.Status.Unauthorized)
}

// ---------------------------------------------------------------------------
// The canonical bearer-auth pattern, end to end.
// ---------------------------------------------------------------------------

@(test)
wp19_public_bearer_auth_middleware_guards_routes :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.use(&a, require_auth)
	web.get(&a, "/admin", secret)

	no_header := web.test_request(&a, .GET, "/admin")
	testing.expect_value(t, no_header.status, web.Status.Unauthorized)
	testing.expect(t, !strings.contains(no_header.body, "TOP-SECRET"))

	wrong_scheme := web.test_request(
		&a,
		.GET,
		"/admin",
		headers = {"Authorization: Basic s3cret"},
	)
	testing.expect_value(t, wrong_scheme.status, web.Status.Unauthorized)

	sloppy := web.test_request(
		&a,
		.GET,
		"/admin",
		headers = {"Authorization: Bearer  s3cret"},
	)
	testing.expect_value(t, sloppy.status, web.Status.Unauthorized)

	granted := web.test_request(
		&a,
		.GET,
		"/admin",
		headers = {"Authorization: Bearer s3cret"},
	)
	testing.expect_value(t, granted.status, web.Status.OK)
	testing.expect_value(t, granted.body, "TOP-SECRET")

	// The scheme is case-insensitive; the TOKEN is not normalised.
	lower := web.test_request(
		&a,
		.GET,
		"/admin",
		headers = {"authorization: bearer s3cret"},
	)
	testing.expect_value(t, lower.status, web.Status.OK)

	cased_token := web.test_request(
		&a,
		.GET,
		"/admin",
		headers = {"Authorization: Bearer S3CRET"},
	)
	testing.expect_value(t, cased_token.status, web.Status.Unauthorized)
}

// ---------------------------------------------------------------------------
// Shape and lifetime.
// ---------------------------------------------------------------------------

@(test)
wp19_public_signatures_are_pinned :: proc(t: ^testing.T) {
	// Pinned as procedure VALUES (the WP7/WP17/WP18 precedent): a signature
	// change is a compile error here, by design.
	header_sig: proc(ctx: ^web.Context, name: string) -> (value: string, ok: bool) = web.header
	bearer_sig: proc(ctx: ^web.Context) -> (value: string, ok: bool) = web.bearer_token
	test_request_sig: proc(
		a: ^web.App,
		method: web.Method,
		path: string,
		body: string,
		query: string,
		headers: []string,
	) -> web.Recorded_Response = web.test_request

	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/whoami", whoami)

	// Called through the pinned VALUE, so every parameter is explicit — the pin
	// exercises the complete signature, not the convenient call shape.
	res := test_request_sig(&a, .GET, "/whoami", "", "", {"X-Api-Key: pinned"})
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "pinned")
	testing.expect(t, header_sig != nil)
	testing.expect(t, bearer_sig != nil)
}

@(test)
wp19_public_headers_param_defaults_and_teardown :: proc(t: ^testing.T) {
	// Every pre-WP19 call shape still compiles (body/query/headers all
	// defaulted), and an App driven with headers tears down cleanly — the
	// runner's memory tracking fails this test on any leak.
	a := web.app()
	web.get(&a, "/whoami", whoami)

	_ = web.test_request(&a, .GET, "/whoami")
	_ = web.test_request(&a, .GET, "/whoami", body = "")
	_ = web.test_request(&a, .GET, "/whoami", headers = {"X-Api-Key: v"})

	web.destroy(&a)
}
