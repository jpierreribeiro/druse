// WP31b public-surface contract — the path policy as a client meets it.
//
// The decision is `planning/phase-3-spec.md` §1: Druse normalises nothing,
// and rejects the paths where the absence of normalisation would be dangerous.
// This suite pins both halves — what is refused, and the much larger set that
// is NOT, because a rejection rule that quietly grew would break applications
// whose paths were legal the day they were written.
package test_wp31_public

import "core:testing"
import web "druse:web"

@(private = "file")
fixture :: proc(a: ^web.App) {
	web.get(a, "/users", handler)
	web.get(a, "/users/", handler)
	web.get(a, "/users/:id", handler)
	web.get(a, "/files/:name", handler)
	web.get(a, "/", handler)
}

@(private = "file")
handler :: proc(ctx: ^web.Context) {
	web.no_content(ctx)
}

// R1 — a dot segment, at any depth. This is the directory-traversal shape, and
// the one whose absence of normalisation a proxy is most likely to disagree
// about.
@(test)
wp31_dot_segments_are_rejected :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	fixture(&app)

	for path in ([]string{"/users/../admin", "/users/./42", "/..", "/.", "/a/b/../c"}) {
		res := web.test_request(&app, .GET, path)
		testing.expectf(t, res.status == .Bad_Request, "%s must be rejected, got %v", path, res.status)
	}
}

// R2 — an INTERIOR empty segment.
@(test)
wp31_interior_empty_segments_are_rejected :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	fixture(&app)

	for path in ([]string{"/users//42", "//users", "/a//b"}) {
		res := web.test_request(&app, .GET, path)
		testing.expectf(t, res.status == .Bad_Request, "%s must be rejected, got %v", path, res.status)
	}
}

// THE TRAP, and the reason it has its own test.
//
// `/users/` ends with an empty segment. An implementation of R2 written as
// "reject any empty segment" would answer 400 here and break every application
// that registered `/users/` — a legal, distinct Phase-1 pattern. `/users` and
// `/users/` stay two different paths, matched literally.
@(test)
wp31_a_trailing_slash_is_not_an_interior_empty_segment :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	fixture(&app)

	with_slash := web.test_request(&app, .GET, "/users/")
	testing.expect_value(t, with_slash.status, web.Status.No_Content)

	without := web.test_request(&app, .GET, "/users")
	testing.expect_value(t, without.status, web.Status.No_Content)

	// The root is a path, not an empty segment.
	root := web.test_request(&app, .GET, "/")
	testing.expect_value(t, root.status, web.Status.No_Content)

	// And a trailing slash on a path that was never registered is still an
	// ordinary miss, not a rejection: the policy did not turn 404s into 400s.
	unregistered := web.test_request(&app, .GET, "/absent/")
	testing.expect_value(t, unregistered.status, web.Status.Not_Found)
}

// R3 and R4 — the two encodings that change a path's STRUCTURE.
@(test)
wp31_structural_encodings_are_rejected :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	fixture(&app)

	for path in ([]string{"/files/a%2Fb", "/files/a%2fb", "/users/%2F", "/files/a%00b"}) {
		res := web.test_request(&app, .GET, path)
		testing.expectf(t, res.status == .Bad_Request, "%s must be rejected, got %v", path, res.status)
	}
}

// THE OTHER HALF, and the more important one. Ordinary percent-encoding is
// NEITHER decoded NOR refused — it is matched byte-exact, exactly as Phase 1
// shipped it. A policy that rejected every `%` would be a normalisation policy
// wearing a rejection policy's clothes.
@(test)
wp31_ordinary_percent_encoding_passes_through :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	fixture(&app)

	// `%41` is "A" once decoded. It is not decoded, so this is simply a
	// parameter whose value is the literal three bytes.
	res := web.test_request(&app, .GET, "/files/%41")
	testing.expect_value(t, res.status, web.Status.No_Content)

	// A dot INSIDE a segment is not a dot SEGMENT. `/files/a.txt` is ordinary.
	dotted := web.test_request(&app, .GET, "/files/a.txt")
	testing.expect_value(t, dotted.status, web.Status.No_Content)

	// Two dots inside a segment are likewise not a dot segment.
	doubled := web.test_request(&app, .GET, "/files/a..b")
	testing.expect_value(t, doubled.status, web.Status.No_Content)
}

// A rejected path is a CLIENT error, not a framework failure: it must not reach
// the observer, exactly as a 404 does not.
@(test)
wp31_a_rejected_path_is_not_a_framework_failure :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	fixture(&app)

	observed = 0
	web.observe(&app, count_event)

	res := web.test_request(&app, .GET, "/users/../admin")
	testing.expect_value(t, res.status, web.Status.Bad_Request)
	testing.expect_value(t, observed, 0)
}

@(private = "file")
observed: int

@(private = "file")
count_event :: proc(event: web.Framework_Event) {
	observed += 1
}
