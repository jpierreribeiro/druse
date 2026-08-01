// WP87 — the buffered compatibility oracle (GREEN, and it stays green).
//
// G7-10: `web.body`, `form_field`, `form_file` and their request-lifetime
// views remain byte- and behaviour-compatible through every Phase-7 change.
// This suite pins the exact bytes TODAY, before any streaming or spool code
// exists, so a later regression cannot argue about what "compatible" meant.
// `build/check_wp87_controls.sh` requires this suite green while the RED
// lifecycle corpora fail — proving the RED is the sentinel's, not the tree's.
package test_wp87_buffered_oracle

import "core:testing"
import web "druse:web"

BOUNDARY :: "----druse-wp87"

@(private = "file")
CONTENT_TYPE_LINE :: "Content-Type: multipart/form-data; boundary=" + BOUNDARY

@(private = "file")
FORM_BODY :: "--" + BOUNDARY + "\r\n" +
	"Content-Disposition: form-data; name=\"note\"\r\n" +
	"\r\n" +
	"forty-two\r\n" +
	"--" + BOUNDARY + "\r\n" +
	"Content-Disposition: form-data; name=\"blob\"; filename=\"raw.bin\"\r\n" +
	"Content-Type: application/octet-stream\r\n" +
	"\r\n" +
	"\x00\x01\x02binary stays binary\xff\r\n" +
	"--" + BOUNDARY + "--"

@(private = "file")
Payload :: struct {
	name:  string,
	count: int,
}

@(private = "file")
Oracle_State :: struct {
	seen_note:    string,
	seen_file:    web.Uploaded_File,
	seen_file_ok: bool,
	seen_payload: Payload,
	seen_body_ok: bool,
}

@(private = "file")
form_handler :: proc(ctx: ^web.Context) {
	state, ok := web.state(ctx, Oracle_State)
	if !ok {
		web.internal_error(ctx)
		return
	}
	state.seen_note, _ = web.form_field(ctx, "note")
	state.seen_file, state.seen_file_ok = web.form_file(ctx, "blob")
	web.text(ctx, .OK, "ok")
}

@(test)
wp87_oracle_form_file_bytes_are_pinned :: proc(t: ^testing.T) {
	state: Oracle_State
	app := web.app_with_state(&state)
	defer web.destroy(&app)
	web.post(&app, "/u", form_handler)
	headers := [?]string{CONTENT_TYPE_LINE}
	rec := web.test_request(&app, .POST, "/u", body = FORM_BODY, headers = headers[:])
	testing.expect_value(t, rec.status, web.Status.OK)
	testing.expect_value(t, state.seen_note, "forty-two")
	testing.expect(t, state.seen_file_ok, "the file part must be found")
	testing.expect_value(t, state.seen_file.filename, "raw.bin")
	testing.expect_value(t, state.seen_file.content_type, "application/octet-stream")
	testing.expect_value(t, len(state.seen_file.bytes), 23)
	testing.expect_value(t, string(state.seen_file.bytes), "\x00\x01\x02binary stays binary\xff")
}

@(private = "file")
json_handler :: proc(ctx: ^web.Context) {
	state, ok := web.state(ctx, Oracle_State)
	if !ok {
		web.internal_error(ctx)
		return
	}
	state.seen_body_ok = web.body(ctx, &state.seen_payload)
	if !state.seen_body_ok {
		return // web.body has already committed the error response
	}
	web.text(ctx, .OK, "ok")
}

@(test)
wp87_oracle_typed_body_binding_is_pinned :: proc(t: ^testing.T) {
	state: Oracle_State
	app := web.app_with_state(&state)
	defer web.destroy(&app)
	web.post(&app, "/j", json_handler)
	rec := web.test_request(&app, .POST, "/j", body = `{"name":"stream","count":7}`)
	testing.expect_value(t, rec.status, web.Status.OK)
	testing.expect(t, state.seen_body_ok, "a well-formed body binds")
	testing.expect_value(t, state.seen_payload.name, "stream")
	testing.expect_value(t, state.seen_payload.count, 7)
}

@(test)
wp87_oracle_oversized_body_still_refuses_with_413 :: proc(t: ^testing.T) {
	state: Oracle_State
	app := web.app_with_state(&state)
	defer web.destroy(&app)
	web.post(&app, "/j", json_handler)
	budget := web.DEFAULT_LIMITS
	budget.max_body = 16
	web.limits(&app, budget)
	big := `{"name":"far-too-long-for-sixteen-bytes","count":1}`
	rec := web.test_request(&app, .POST, "/j", body = big)
	testing.expect_value(t, rec.status, web.Status(413))
}
