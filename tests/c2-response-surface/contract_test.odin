// C2 — corrective WP for frictions F8-2 (no public way to set a response header)
// and F8-4 (no buffered binary responder). This is the ledger's RED test: RED
// before C2 (neither `web.set_header` nor `web.bytes` existed), GREEN after.
//
// Driven through the public in-memory transport (`web.test_request`), asserting
// the header appears on the wire and the bytes body arrives with the caller's
// media type — the exact things an application could not do in Phase 1.
package test_c2_response_surface

import "core:strings"
import "core:testing"
import web "uruquim:web"

@(private = "file")
has_header :: proc(res: web.Recorded_Response, line: string) -> bool {
	for h in res.headers {
		if strings.equal_fold(h, line) {
			return true
		}
	}
	return false
}

// --- F8-2: set_header ------------------------------------------------------

@(private = "file")
cookie_handler :: proc(ctx: ^web.Context) {
	ok := web.set_header(ctx, "Set-Cookie", "sid=abc; HttpOnly; SameSite=Lax")
	web.set_header(ctx, "Cache-Control", "no-store")
	if !ok {
		web.text(ctx, .Internal_Server_Error, "set_header refused")
		return
	}
	web.text(ctx, .OK, "ok")
}

@(test)
c2_set_header_rides_on_the_response :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/login", cookie_handler)

	res := web.test_request(&a, .GET, "/login")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(t, has_header(res, "Set-Cookie: sid=abc; HttpOnly; SameSite=Lax"), "the Set-Cookie header rides on the response")
	testing.expect(t, has_header(res, "Cache-Control: no-store"), "a second app header rides too")
}

@(private = "file")
reject_handler :: proc(ctx: ^web.Context) {
	reserved := web.set_header(ctx, "Content-Type", "text/evil")     // framework-owned
	injected := web.set_header(ctx, "X-Bad", "a\r\nInjected: yes")   // value injection
	empty := web.set_header(ctx, "", "x")                            // empty name
	bad_name := web.set_header(ctx, "X Bad", "y")                    // non-token name (space)
	colon_name := web.set_header(ctx, "X:Bad", "y")                  // non-token name (colon)
	crlf_name := web.set_header(ctx, "X\r\nSet-Cookie", "y")         // name injection
	// A legitimate one still works alongside the refusals.
	good := web.set_header(ctx, "X-Ok", "1")
	if reserved || injected || empty || bad_name || colon_name || crlf_name || !good {
		web.text(ctx, .Internal_Server_Error, "validation wrong")
		return
	}
	web.text(ctx, .OK, "ok")
}

@(test)
c2_set_header_refuses_reserved_and_injection :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/r", reject_handler)

	res := web.test_request(&a, .GET, "/r")
	testing.expect_value(t, res.status, web.Status.OK)
	// The reserved/injected/empty ones were refused; only X-Ok is present, and the
	// framework's own Content-Type is intact (not the attacker's "text/evil").
	testing.expect(t, has_header(res, "X-Ok: 1"), "the valid header was accepted")
	testing.expect(t, !has_header(res, "Content-Type: text/evil"), "the reserved-name override was refused")
	testing.expect(t, !has_header(res, "X-Bad: a"), "the CR/LF-injected header was refused")
}

// --- F8-4: bytes -----------------------------------------------------------

PDF :: "%PDF-1.4 fake bytes \x00\x01\x02 binary"

@(private = "file")
pdf_handler :: proc(ctx: ^web.Context) {
	web.set_header(ctx, "Content-Disposition", "attachment; filename=\"report.pdf\"")
	web.bytes(ctx, .OK, "application/pdf", transmute([]u8)string(PDF))
}

@(test)
c2_bytes_sends_typed_binary_body :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/report", pdf_handler)

	res := web.test_request(&a, .GET, "/report")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, res.body, PDF)
	testing.expect(t, has_header(res, "Content-Type: application/pdf"), "the caller's media type is on the wire")
	testing.expect(t, has_header(res, "Content-Disposition: attachment; filename=\"report.pdf\""), "an auth-gated download can set its disposition")
}

@(private = "file")
bad_ct_handler :: proc(ctx: ^web.Context) {
	web.bytes(ctx, .OK, "text/plain\r\nInjected: yes", transmute([]u8)string("x"))
}

@(test)
c2_bytes_rejects_control_content_type :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/bad", bad_ct_handler)

	res := web.test_request(&a, .GET, "/bad")
	// A control-byte content type is a programming error → a logged 500, never a
	// split header on the wire.
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
}
