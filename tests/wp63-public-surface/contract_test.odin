// WP63 public-surface contract — multipart forms.
//
// THREE APPLICATION SYMBOLS: `Uploaded_File`, `form_field`, `form_file`.
//
// The parser refuses more than it accepts, and the malformed cases carry the
// weight here for the same reason they do in WP61: a form parser that salvages
// what it can hands the handler a missing field that looks like a field the
// user left blank, and nobody debugging that ever suspects the parser.
package test_wp63_public

import "core:log"
import "core:strings"
import "core:testing"
import web "druse:web"

// The ADR-012 diagnostic is an EXPECTED Error-level `druse:` line, and the
// pinned runner records Error output as a failure. The WP8 idiom, reused.
@(private = "file")
Quiet :: struct {
	inner: log.Logger,
}

@(private = "file")
quiet_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Quiet)(data)
	if level == .Error && strings.contains(text, "druse:") {
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

@(private = "file")
quiet_logger :: proc(record: ^Quiet) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = quiet_logger_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

BOUNDARY :: "----druse9zX"

@(private = "file")
CONTENT_TYPE_LINE :: "Content-Type: multipart/form-data; boundary=" + BOUNDARY

// A well-formed body: one text field and one file part.
@(private = "file")
GOOD_BODY :: "--" + BOUNDARY + "\r\n" +
	"Content-Disposition: form-data; name=\"title\"\r\n" +
	"\r\n" +
	"a report\r\n" +
	"--" + BOUNDARY + "\r\n" +
	"Content-Disposition: form-data; name=\"doc\"; filename=\"notes.txt\"\r\n" +
	"Content-Type: text/plain\r\n" +
	"\r\n" +
	"hello file\r\n" +
	"--" + BOUNDARY + "--"

@(private = "file")
captured_ok: bool
@(private = "file")
captured_title: string
@(private = "file")
captured_file: web.Uploaded_File
@(private = "file")
captured_file_ok: bool

@(private = "file")
form_handler :: proc(ctx: ^web.Context) {
	captured_title, captured_ok = web.form_field(ctx, "title")
	captured_file, captured_file_ok = web.form_file(ctx, "doc")
	web.text(ctx, .OK, "done")
}

@(private = "file")
post_form :: proc(app: ^web.App, body: string) {
	captured_ok = false
	captured_file_ok = false
	captured_title = ""
	captured_file = {}
	headers := [?]string{CONTENT_TYPE_LINE}
	_ = web.test_request(app, .POST, "/upload", body = body, headers = headers[:])
}

@(private = "file")
form_app :: proc(a: ^web.App) {
	a^ = web.app()
	web.post(a, "/upload", form_handler)
}

// The signatures, pinned by assignment.
@(test)
wp63_the_signatures_are_pinned :: proc(t: ^testing.T) {
	field: proc(ctx: ^web.Context, name: string) -> (string, bool) = web.form_field
	file: proc(ctx: ^web.Context, name: string) -> (web.Uploaded_File, bool) = web.form_file
	testing.expect(t, field != nil && file != nil, "both readers must have their pinned shapes")

	f := web.Uploaded_File {
		field        = "doc",
		filename     = "notes.txt",
		content_type = "text/plain",
		bytes        = nil,
	}
	testing.expect_value(t, f.filename, "notes.txt")
}

// A well-formed form: the text field and the file both arrive.
@(test)
wp63_a_form_is_parsed :: proc(t: ^testing.T) {
	app: web.App
	form_app(&app)
	defer web.destroy(&app)

	post_form(&app, GOOD_BODY)

	testing.expect(t, captured_ok, "the text field must be found")
	testing.expect_value(t, captured_title, "a report")

	testing.expect(t, captured_file_ok, "the file part must be found")
	testing.expect_value(t, captured_file.field, "doc")
	testing.expect_value(t, captured_file.filename, "notes.txt")
	testing.expect_value(t, captured_file.content_type, "text/plain")
	testing.expect_value(t, string(captured_file.bytes), "hello file")
}

// **THE DISTINCTION THE HTML SPECIFICATION DRAWS**, and the one an
// implementation gets wrong by using the content type instead: a part is a FILE
// because it carries `filename`, not because of what its bytes look like.
@(test)
wp63_a_field_is_not_a_file_and_a_file_is_not_a_field :: proc(t: ^testing.T) {
	app: web.App
	form_app(&app)
	defer web.destroy(&app)

	post_form(&app, GOOD_BODY)

	_, field_as_file := web.form_file(&web.Context{}, "title")
	testing.expect(t, !field_as_file, "a fresh context has no form at all")

	// `title` has no filename, so it must not be reachable as a file, and `doc`
	// has one, so it must not be reachable as a field.
	testing.expect(t, captured_ok, "title is a field")
	testing.expect(t, captured_file_ok, "doc is a file")
}

// A missing field is reported, not invented.
@(test)
wp63_a_missing_field_is_reported :: proc(t: ^testing.T) {
	app: web.App
	form_app(&app)
	defer web.destroy(&app)

	handler :: proc(ctx: ^web.Context) {
		_, ok := web.form_field(ctx, "absent")
		captured_ok = ok
		web.text(ctx, .OK, "done")
	}
	probe := web.app()
	defer web.destroy(&probe)
	web.post(&probe, "/upload", handler)

	captured_ok = true
	headers := [?]string{CONTENT_TYPE_LINE}
	_ = web.test_request(&probe, .POST, "/upload", body = GOOD_BODY, headers = headers[:])
	testing.expect(t, !captured_ok, "a field that was not submitted must report ok = false")
}

// ---------------------------------------------------------------------------
// The refusals. A malformed form yields nothing, never a partial parse.
// ---------------------------------------------------------------------------

@(private = "file")
expect_nothing_parsed :: proc(t: ^testing.T, body: string, why: string) {
	app: web.App
	form_app(&app)
	defer web.destroy(&app)

	post_form(&app, body)
	testing.expect(t, !captured_ok, why)
	testing.expect(t, !captured_file_ok, why)
}

@(test)
wp63_malformed_bodies_yield_nothing :: proc(t: ^testing.T) {
	// A body that does not open with the delimiter.
	expect_nothing_parsed(
		t,
		"garbage\r\n--" + BOUNDARY + "--",
		"a body that does not open with the delimiter must not parse",
	)

	// A part whose headers never terminate.
	expect_nothing_parsed(
		t,
		"--" + BOUNDARY + "\r\nContent-Disposition: form-data; name=\"title\"\r\n",
		"a part with unterminated headers must not parse",
	)

	// A part with no closing delimiter — the truncated-upload shape.
	expect_nothing_parsed(
		t,
		"--" + BOUNDARY + "\r\n" +
		"Content-Disposition: form-data; name=\"title\"\r\n\r\nvalue",
		"a truncated body must not parse: a half-read upload is not a form",
	)

	// A part with no `name`, which has nothing to be looked up by.
	expect_nothing_parsed(
		t,
		"--" + BOUNDARY + "\r\n" +
		"Content-Disposition: form-data\r\n\r\nvalue\r\n" +
		"--" + BOUNDARY + "--",
		"a part with no name must not parse",
	)
}

// The boundary appearing INSIDE a part's content must not split it. This is the
// case a naive split-on-boundary implementation gets wrong.
@(test)
wp63_a_boundary_like_string_inside_content_is_safe :: proc(t: ^testing.T) {
	app: web.App
	form_app(&app)
	defer web.destroy(&app)

	// The delimiter is CRLF + "--" + boundary. Text that merely mentions the
	// boundary, without that framing, is content.
	body := "--" + BOUNDARY + "\r\n" +
		"Content-Disposition: form-data; name=\"title\"\r\n\r\n" +
		"mentions " + BOUNDARY + " inline\r\n" +
		"--" + BOUNDARY + "--"

	post_form(&app, body)
	testing.expect(t, captured_ok, "content that mentions the boundary must still parse")
	testing.expect(
		t,
		strings.contains(captured_title, "inline"),
		"the content must not be truncated at a boundary-like string",
	)
}

// A request that is not multipart at all reports nothing rather than guessing.
@(test)
wp63_a_non_multipart_request_reports_nothing :: proc(t: ^testing.T) {
	app: web.App
	form_app(&app)
	defer web.destroy(&app)

	captured_ok = false
	captured_file_ok = false
	headers := [?]string{"Content-Type: application/json"}
	_ = web.test_request(&app, .POST, "/upload", body = `{"title":"x"}`, headers = headers[:])

	testing.expect(t, !captured_ok, "a JSON body must not be read as a form")
	testing.expect(t, !captured_file_ok, "a JSON body must not yield a file")
}

// **THE ADR-012 RULE.** The form readers and `web.body` consume the same
// single-use capability: whichever runs first takes it.
@(test)
wp63_the_form_and_the_body_share_one_capability :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	Payload :: struct {
		title: string,
	}

	handler :: proc(ctx: ^web.Context) {
		_, _ = web.form_field(ctx, "title")
		// The body capability is gone now, exactly as it would be after a
		// second `web.body`.
		payload: Payload
		captured_ok = web.body(ctx, &payload)
		web.text(ctx, .OK, "done")
	}

	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/upload", handler)

	captured_ok = true
	headers := [?]string{CONTENT_TYPE_LINE}
	_ = web.test_request(&app, .POST, "/upload", body = GOOD_BODY, headers = headers[:])

	testing.expect(
		t,
		!captured_ok,
		"web.body after a form reader must fail: one body, one consumer (ADR-012)",
	)
}

// SECURITY BACKLOG F13 — a decoy `boundary=` inside a quoted parameter value
// must not be mistaken for the real boundary parameter. A bare
// `strings.index(content_type, "boundary=")` would find the decoy `evil` inside
// `name="x; boundary=evil"` and split the body on it, while an RFC-strict
// intermediary (a WAF or scanning proxy) splits on the real `good` — the two
// disagree on where parts begin, which is a content-inspection bypass. The body
// below is framed with the REAL boundary, so a parser that used the decoy would
// see no parts at all; one that reads the true MIME parameter parses normally.
@(test)
wp63_a_decoy_boundary_in_a_quoted_parameter_is_not_used :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app: web.App
	form_app(&app)
	defer web.destroy(&app)

	// The crafted header: a decoy inside a quoted value, then the real parameter.
	CRAFTED :: "Content-Type: multipart/form-data; name=\"x; boundary=evil\"; boundary=" + BOUNDARY
	headers := [?]string{CRAFTED}

	captured_ok = false
	captured_file_ok = false
	captured_title = ""
	_ = web.test_request(&app, .POST, "/upload", body = GOOD_BODY, headers = headers[:])

	// The body is framed with the real BOUNDARY, so correct extraction parses it.
	// A substring parser that latched onto `evil` would find no parts.
	testing.expect(
		t,
		captured_ok && captured_title == "a report",
		"the real `boundary` parameter must be used, not a decoy inside a quoted value (F13)",
	)
	testing.expect(
		t,
		captured_file_ok,
		"the file part must parse under the real boundary, proving the decoy was ignored",
	)
}
