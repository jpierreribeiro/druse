// C8 — corrective WP for friction F8-9: the public Status enum gains the redirect
// family (301/302/303/307/308), which it did not name at all. This suite is the
// ledger's RED test: RED before C8 (no 3xx member exists), GREEN after.
//
// It runs on the in-memory test transport (web.test_request) — no socket needed —
// and asserts three things a `Status(303)` cast cannot give you:
//
//   1. the members equal their HTTP codes;
//   2. POST/Redirect/GET reaches the wire complete — a 303 WITH its `Location`,
//      which is the whole point: a redirect with no Location sends the client
//      nowhere with a status that says otherwise;
//   3. the status FORMATS AS ITSELF. An unnamed enum value renders as
//      `%!(BAD ENUM VALUE=303)` under `%v`, so before C8 every log line and test
//      failure that printed a redirect's status printed garbage. That is the
//      second half of F8-9 and it is asserted, not assumed.
package test_c8_redirect_statuses

import "core:fmt"
import "core:strings"
import "core:testing"
import web "uruquim:web"

@(test)
c8_named_members_equal_their_http_codes :: proc(t: ^testing.T) {
	// The point of F8-9, as of F8-1: a status is a checked, named value — not a
	// cast that a typo would carry to the wire unnoticed.
	testing.expect_value(t, int(web.Status.Moved_Permanently), 301)
	testing.expect_value(t, int(web.Status.Found), 302)
	testing.expect_value(t, int(web.Status.See_Other), 303)
	testing.expect_value(t, int(web.Status.Temporary_Redirect), 307)
	testing.expect_value(t, int(web.Status.Permanent_Redirect), 308)
}

// The canonical POST/Redirect/GET handler, written with the symbols the public
// surface already has: `set_header` (C2) for the target, `text` for the status.
// The empty body is deliberate — browsers follow the header, and a body on a
// redirect is read by nobody while still costing the bytes.
save_note :: proc(ctx: ^web.Context) {
	if !web.set_header(ctx, "Location", "/notes") {
		web.internal_error(ctx)
		return
	}
	web.text(ctx, .See_Other, "")
}

moved_handler :: proc(ctx: ^web.Context) {
	if !web.set_header(ctx, "Location", "/v2/thing") {
		web.internal_error(ctx)
		return
	}
	web.text(ctx, .Moved_Permanently, "")
}

@(test)
c8_post_redirect_get_reaches_the_wire :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/notes", save_note)

	r := web.test_request(&a, .POST, "/notes")

	testing.expect_value(t, r.status, web.Status.See_Other)
	testing.expect_value(t, int(r.status), 303)

	// A 303 without a Location is not a redirect. The header is half the answer,
	// so the test asserts both halves or it is not testing the pattern.
	found := false
	for line in r.headers {
		if strings.has_prefix(line, "Location: ") {
			found = true
			testing.expect_value(t, line, "Location: /notes")
		}
	}
	testing.expect(t, found, "the 303 carried no Location header")
}

@(test)
c8_permanent_redirect_reaches_the_wire :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/thing", moved_handler)

	r := web.test_request(&a, .GET, "/thing")
	testing.expect_value(t, r.status, web.Status.Moved_Permanently)
	testing.expect_value(t, int(r.status), 301)
}

@(test)
c8_redirect_status_formats_as_itself :: proc(t: ^testing.T) {
	// F8-9's second facet. `Status(303)` prints `%!(BAD ENUM VALUE=303)`, so the
	// diagnostic value of every log line about a redirect was zero. A named member
	// prints its name, and this asserts the property rather than trusting it.
	rendered := fmt.tprintf("%v", web.Status.See_Other)
	testing.expect_value(t, rendered, "See_Other")
	testing.expect(
		t,
		!strings.contains(rendered, "BAD ENUM VALUE"),
		"a redirect status still renders as an unnamed enum value",
	)
}
