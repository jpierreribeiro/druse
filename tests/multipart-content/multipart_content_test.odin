// MULTIPART AUDIT F6 — CONTENT THAT CONTAINS `\r\n--` MUST NOT BREAK THE FORM.
//
// `multipart_parse` took the FIRST `\r\n--` after a part's headers and then
// REQUIRED it to be the boundary delimiter, failing the whole form when it was
// not. Those are four ordinary bytes: any binary part can contain them, so a PNG
// or a zip whose bytes happened to include the sequence made `form_field` and
// `form_file` return `ok=false` for every field in the form. The failure is
// content-dependent and therefore intermittent and unreproducible from the
// user's point of view — the worst shape a bug can have.
//
// WHY THIS TEST EXISTS SEPARATELY FROM `wp63_a_boundary_like_string_inside_
// content_is_safe`. That case sends content that MENTIONS the boundary
// (`mentions ----uruquim9zX inline`) but never prefixes it with `\r\n--`, so the
// first `\r\n--` in the body is still the real delimiter and the old parser
// handled it. It passes with and without the fix — it does not cover this
// defect. This one puts the literal four-byte sequence inside the content, which
// is the case that actually failed.
//
// Its own package: the wp63 suite keeps its captured values in package-level
// globals, which the parallel test runner races across tests.
package test_multipart_content

import "core:strings"
import "core:testing"
import web "uruquim:web"

BOUNDARY :: "----uruquimF6"
CONTENT_TYPE_LINE :: "Content-Type: multipart/form-data; boundary=" + BOUNDARY

captured_title: string
captured_ok: bool
captured_file: web.Uploaded_File
captured_file_ok: bool

form_handler :: proc(ctx: ^web.Context) {
	captured_title, captured_ok = web.form_field(ctx, "title")
	captured_file, captured_file_ok = web.form_file(ctx, "doc")
	web.text(ctx, .OK, "done")
}

@(test)
audit_content_containing_a_crlf_dash_dash_sequence_still_parses :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/upload", form_handler)

	// The file part's bytes contain `\r\n--` three times — once followed by text
	// that merely looks boundary-ish, once by a shorter prefix of the real
	// boundary, and once by nothing in particular. None of them is the delimiter.
	decoy := "binary\r\n--notaboundary\r\n--" + BOUNDARY[:8] + "\r\n--\x00\x01\x02tail"

	body := strings.concatenate(
		{
			"--", BOUNDARY, "\r\n",
			"Content-Disposition: form-data; name=\"title\"\r\n\r\n",
			"a report\r\n",
			"--", BOUNDARY, "\r\n",
			"Content-Disposition: form-data; name=\"doc\"; filename=\"x.bin\"\r\n",
			"Content-Type: application/octet-stream\r\n\r\n",
			decoy, "\r\n",
			"--", BOUNDARY, "--",
		},
		context.temp_allocator,
	)

	captured_ok = false
	captured_file_ok = false
	captured_title = ""
	captured_file = {}
	headers := [?]string{CONTENT_TYPE_LINE}
	_ = web.test_request(&app, .POST, "/upload", body = body, headers = headers[:])

	// Both parts must be found. Before the fix the first non-delimiter `\r\n--`
	// inside `decoy` aborted the whole parse and BOTH of these were false.
	testing.expect(t, captured_ok, "the text field must survive a boundary-like sequence in a later part")
	testing.expect_value(t, captured_title, "a report")
	testing.expect(t, captured_file_ok, "the file part must be found")

	// And the file's bytes must be delivered whole, not truncated at the first
	// lookalike — a truncated upload that still reports success is worse than a
	// refused one.
	testing.expect_value(t, len(captured_file.bytes), len(decoy))
	testing.expect(
		t,
		string(captured_file.bytes) == decoy,
		"the file bytes must be byte-identical, not cut at a boundary-like sequence",
	)
}
