// WP49 — SECURE RESPONSE HEADERS: `secure_headers`.
//
// ONE SYMBOL, an opt-in `Handler`, following the `logger` and `request_id`
// precedent exactly: a middleware, not a default, because a header the
// framework sets without being asked is a header an application cannot remove.
//
// WHAT IT SETS, AND WHY EXACTLY THESE THREE. The selection rule is harsh on
// purpose: **a header is here only if it has one correct value that needs no
// configuration and cannot break an ordinary application.** Everything with a
// policy in it is left out, because a security header with a wrong policy is
// worse than none — it produces a broken page that looks like a framework bug.
//
//	X-Content-Type-Options: nosniff
//	    Stops a browser guessing a content type against what the response
//	    declared. MIME-sniffing turns a user-uploaded text file into script.
//	    One value exists; there is nothing to configure and nothing it breaks.
//
//	X-Frame-Options: DENY
//	    Refuses framing, which is clickjacking's whole mechanism. DENY rather
//	    than SAMEORIGIN because an application that frames itself knows it and
//	    can say so; one that does not should not discover this by being framed.
//
//	Referrer-Policy: no-referrer
//	    Stops the full URL — path, query, and whatever identifiers are in them
//	    — from being sent to every third-party host the page reaches. The
//	    default in most browsers still leaks the origin.
//
// WHAT IS DELIBERATELY ABSENT, each for a stated reason rather than an
// oversight:
//
//	Content-Security-Policy — the most valuable header here and the one that
//	    is pure policy. A CSP that is not written for the application breaks
//	    it, and one loose enough not to break anything protects nothing. It
//	    needs an argument, so it needs an API, so it is not this package.
//
//	Strict-Transport-Security — meaningful only over TLS, which Druse
//	    deliberately does not terminate (ADR: reverse-proxy termination is the
//	    supported deployment). The proxy that holds the certificate is the
//	    thing that should assert HSTS; a framework behind it asserting HSTS on
//	    a cleartext hop is asserting something it cannot know.
//
//	Cookie attributes — Druse sets no cookies and has no cookie API, so
//	    there is nothing to secure. `Secure`/`HttpOnly`/`SameSite` arrive with
//	    a cookie API or not at all, and inventing one to have somewhere to put
//	    them would be the accretion this project refuses.
package web
// druse:file application

@(private)
SECURE_CONTENT_TYPE_OPTIONS_NAME :: "X-Content-Type-Options"
@(private)
SECURE_CONTENT_TYPE_OPTIONS :: "nosniff"

@(private)
SECURE_FRAME_OPTIONS_NAME :: "X-Frame-Options"
@(private)
SECURE_FRAME_OPTIONS :: "DENY"

@(private)
SECURE_REFERRER_POLICY_NAME :: "Referrer-Policy"
@(private)
SECURE_REFERRER_POLICY :: "no-referrer"

// secure_headers adds the three unconditional security headers to every
// response this application produces.
//
// Register it like any other middleware, BEFORE the first route:
//
//	web.use(&app, web.secure_headers)
//
// IT APPLIES TO EVERY RESPONSE, including the automatic 404, the 405, an
// extractor's 400 and the driver's 500. That is the reason it works by setting
// a flag the response builder reads rather than by stamping the response as the
// chain unwinds: WP22 measured that the driver finalizes a missing response
// AFTER the chain has unwound, so a stamping middleware would miss the 500 —
// and a 500 is exactly the response an attacker is most likely to be looking
// at.
//
// It allocates nothing and sets one boolean. The header names and values are
// compile-time constants, so the cost is three pointer pairs in storage the
// Context already carries.
secure_headers :: proc(ctx: ^Context) {
	ctx.private.secure_headers = true
	next(ctx)
}
