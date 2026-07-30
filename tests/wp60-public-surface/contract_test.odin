// WP60 public-surface contract — CORS, the parts an application can observe.
//
// TWO APPLICATION SYMBOLS: `cors` and `Cors_Options`.
//
// The preflight lives in `tests/wp60-internal/` for the WP32b reason, restated
// because it is easy to mistake for an omission: a preflight is an OPTIONS
// request, `web.test_request` takes a `Method`, and `Method` has no OPTIONS
// member. That is the design working — HEAD and OPTIONS are resolved from the
// raw token before a `Method` value exists, so the frozen six-member enum stays
// exactly as the gate pins it. A public suite that COULD send a preflight would
// be evidence the enum had grown.
//
// What this suite holds is everything else, and the cases are chosen around one
// question: **can an application tell, from outside, whether its policy is the
// policy it wrote?**
package test_wp60_public

import "core:log"
import "core:strings"
import "core:testing"
import web "druse:web"

// The fail-closed diagnostics are EXPECTED Error-level `druse:` log lines,
// and the pinned test runner records Error output as a failure. This swallows
// exactly those and forwards everything else — the WP8 idiom, reused rather
// than reinvented.
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

APP_ORIGIN :: "https://app.example.com"
OTHER_ORIGIN :: "https://evil.example.com"

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

@(private = "file")
has_header_name :: proc(res: web.Recorded_Response, name: string) -> bool {
	for h in res.headers {
		if strings.has_prefix(strings.to_lower(h, context.temp_allocator), name) {
			return true
		}
	}
	return false
}

@(private = "file")
origin_line :: proc(origin: string) -> string {
	return strings.concatenate({"Origin: ", origin}, context.temp_allocator)
}

// The signatures, pinned by assignment.
@(test)
wp60_the_signatures_are_pinned :: proc(t: ^testing.T) {
	pinned: proc(a: ^web.App, o: web.Cors_Options) = web.cors
	testing.expect(t, pinned != nil, "cors must take an App and a Cors_Options")

	o := web.Cors_Options {
		origins     = {APP_ORIGIN},
		methods     = "GET",
		headers     = "Content-Type",
		credentials = true,
		max_age     = 600,
	}
	testing.expect_value(t, len(o.origins), 1)
	testing.expect_value(t, o.credentials, true)
}

// A listed origin gets its own origin echoed, plus `Vary`.
@(test)
wp60_a_listed_origin_is_echoed :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.cors(&app, web.Cors_Options{origins = {APP_ORIGIN}})
	web.get(&app, "/ping", ok_handler)

	headers := [?]string{origin_line(APP_ORIGIN)}
	res := web.test_request(&app, .GET, "/ping", headers = headers[:])

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(
		t,
		has_header(res, "Access-Control-Allow-Origin: " + APP_ORIGIN),
		"a listed origin must be echoed back",
	)
	testing.expect(
		t,
		has_header(res, "Vary: Origin"),
		"Vary: Origin must accompany an echoed origin, or a shared cache will serve one origin's response to another",
	)
}

// **THE CASE THAT MATTERS MOST.** An origin that is not on the list gets the
// response — and no CORS header, so the browser refuses to hand it to the page.
//
// Serving it is deliberate. Refusing outright would break every same-origin
// browser POST, which also carries an `Origin`, and would tell an attacker
// which origins are listed by the difference in status.
@(test)
wp60_an_unlisted_origin_gets_no_headers_but_is_still_served :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.cors(&app, web.Cors_Options{origins = {APP_ORIGIN}})
	web.get(&app, "/ping", ok_handler)

	headers := [?]string{origin_line(OTHER_ORIGIN)}
	res := web.test_request(&app, .GET, "/ping", headers = headers[:])

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(
		t,
		!has_header_name(res, "access-control-allow-origin"),
		"an unlisted origin must receive NO allow-origin header",
	)
}

// A same-origin request — no `Origin` header at all — must not receive CORS
// headers it never asked for.
@(test)
wp60_a_request_without_an_origin_gets_no_cors_headers :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.cors(&app, web.Cors_Options{origins = {APP_ORIGIN}})
	web.get(&app, "/ping", ok_handler)

	res := web.test_request(&app, .GET, "/ping")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(
		t,
		!has_header_name(res, "access-control-allow-origin"),
		"a same-origin request must not be given CORS headers",
	)
}

// **THE REASON THIS IS CONFIGURATION AND NOT MIDDLEWARE.** The headers must be
// on the automatic 404 too. A browser that cannot read the error shows its user
// a blank page instead of the message the application wrote.
@(test)
wp60_the_headers_are_on_the_automatic_404 :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.cors(&app, web.Cors_Options{origins = {APP_ORIGIN}})
	web.get(&app, "/ping", ok_handler)

	headers := [?]string{origin_line(APP_ORIGIN)}
	res := web.test_request(&app, .GET, "/absent", headers = headers[:])

	testing.expect_value(t, res.status, web.Status.Not_Found)
	testing.expect(
		t,
		has_header(res, "Access-Control-Allow-Origin: " + APP_ORIGIN),
		"a 404 must carry the CORS headers, or the browser hides the error from the page",
	)
}

// A wildcard policy still echoes the ARRIVING origin, never the literal `*`.
// Echoing `*` would make every origin's response look identical to a cache.
@(test)
wp60_a_wildcard_echoes_the_arriving_origin :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.cors(&app, web.Cors_Options{origins = {"*"}})
	web.get(&app, "/ping", ok_handler)

	headers := [?]string{origin_line(OTHER_ORIGIN)}
	res := web.test_request(&app, .GET, "/ping", headers = headers[:])

	testing.expect(
		t,
		has_header(res, "Access-Control-Allow-Origin: " + OTHER_ORIGIN),
		"a wildcard policy must echo the arriving origin",
	)
	testing.expect(
		t,
		!has_header(res, "Access-Control-Allow-Origin: *"),
		"the literal wildcard must never be sent, because the response varies by origin",
	)
}

// Credentials are announced only when configured.
@(test)
wp60_credentials_are_announced_only_when_asked_for :: proc(t: ^testing.T) {
	with := web.app()
	defer web.destroy(&with)
	web.cors(&with, web.Cors_Options{origins = {APP_ORIGIN}, credentials = true})
	web.get(&with, "/ping", ok_handler)

	headers := [?]string{origin_line(APP_ORIGIN)}
	res := web.test_request(&with, .GET, "/ping", headers = headers[:])
	testing.expect(
		t,
		has_header(res, "Access-Control-Allow-Credentials: true"),
		"credentials must be announced when configured",
	)

	without := web.app()
	defer web.destroy(&without)
	web.cors(&without, web.Cors_Options{origins = {APP_ORIGIN}})
	web.get(&without, "/ping", ok_handler)

	res2 := web.test_request(&without, .GET, "/ping", headers = headers[:])
	testing.expect(
		t,
		!has_header_name(res2, "access-control-allow-credentials"),
		"credentials must not be announced when not configured",
	)
}

// ---------------------------------------------------------------------------
// The fail-closed cases. Each is a configuration that WORKS — silently and
// wrongly — in frameworks that accept it.
// ---------------------------------------------------------------------------

// A poisoned application answers 500 to everything, which is how these are
// observed from the public surface.
@(private = "file")
is_poisoned :: proc(a: ^web.App) -> bool {
	res := web.test_request(a, .GET, "/ping")
	return res.status == web.Status.Internal_Server_Error
}

// **THE CLASSIC HOLE.** `*` with credentials. No browser honours it, so an
// application configured this way is broken in a way that reads as a framework
// bug — and the obvious "fix" is a real vulnerability.
@(test)
wp60_wildcard_with_credentials_is_refused :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", ok_handler)
	web.cors(&app, web.Cors_Options{origins = {"*"}, credentials = true})

	testing.expect(
		t,
		is_poisoned(&app),
		"a wildcard origin with credentials must be refused at registration",
	)
}

// `*` alongside named origins reads as "these, and also everyone".
@(test)
wp60_wildcard_beside_named_origins_is_refused :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", ok_handler)
	web.cors(&app, web.Cors_Options{origins = {APP_ORIGIN, "*"}})

	testing.expect(t, is_poisoned(&app), "an ambiguous wildcard must be refused")
}

// `*` in the allowed headers does not cover `Authorization` under the Fetch
// standard, so with credentials on it permits less than it appears to.
@(test)
wp60_wildcard_headers_with_credentials_is_refused :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", ok_handler)
	web.cors(&app, web.Cors_Options{origins = {APP_ORIGIN}, headers = "*", credentials = true})

	testing.expect(
		t,
		is_poisoned(&app),
		"a wildcard header list with credentials must be refused: it does not cover Authorization",
	)
}

// An allow-list that allows nothing is an unfinished policy, not a strict one.
@(test)
wp60_an_empty_origin_list_is_refused :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", ok_handler)
	web.cors(&app, web.Cors_Options{origins = {}})

	testing.expect(t, is_poisoned(&app), "an empty origin list must be refused")
}

// A negative cache lifetime is a mistake, and zero already means "omit".
@(test)
wp60_a_negative_max_age_is_refused :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", ok_handler)
	web.cors(&app, web.Cors_Options{origins = {APP_ORIGIN}, max_age = -1})

	testing.expect(t, is_poisoned(&app), "a negative max_age must be refused")
}
