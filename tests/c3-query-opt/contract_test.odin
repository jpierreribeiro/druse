// C3 — corrective WP for friction F8-6: an OPTIONAL typed query parameter reader
// that reports presence distinctly. The ledger's RED test: RED before C3
// (`query_int` 400s on absence; `query_int_or` cannot report presence), GREEN
// after. Driven through the public in-memory transport.
package test_c3_query_opt

import "core:strconv"
import "core:testing"
import web "uruquim:web"

// The handler echoes the three-state outcome as the status so the test can read
// it back: absent -> 204, present+valid -> 200 (+value in body), malformed ->
// the framework's committed 400.
@(private = "file")
filter_handler :: proc(ctx: ^web.Context) {
	v, present, ok := web.query_int_opt(ctx, "assignee")
	if !ok {
		return // malformed: the extractor already committed the 400
	}
	if !present {
		web.no_content(ctx) // 204: no filter
		return
	}
	buf: [8]u8
	web.text(ctx, .OK, strconv.itoa(buf[:], v))
}

@(test)
c3_absent_is_present_false_ok_true :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/tasks", filter_handler)

	res := web.test_request(&a, .GET, "/tasks") // no query at all
	testing.expect_value(t, res.status, web.Status.No_Content) // absent -> no filter, nothing committed by the reader
}

@(test)
c3_present_valid_carries_the_value :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/tasks", filter_handler)

	res := web.test_request(&a, .GET, "/tasks", query = "assignee=42")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, "42")
}

@(test)
c3_present_malformed_is_a_400 :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/tasks", filter_handler)

	// A non-integer value: a mistake the caller should hear about, never silently
	// ignored — the reader commits the standardized 400.
	bad := web.test_request(&a, .GET, "/tasks", query = "assignee=banana")
	testing.expect_value(t, bad.status, web.Status.Bad_Request)

	// An empty value is PRESENT (the key is on the wire) but malformed -> 400 too,
	// not an absence.
	empty := web.test_request(&a, .GET, "/tasks", query = "assignee=")
	testing.expect_value(t, empty.status, web.Status.Bad_Request)
}
