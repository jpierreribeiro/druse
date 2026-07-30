// WP60 internal contract — the CORS preflight.
//
// WHY THIS SUITE IS INTERNAL, and it is the WP32b reason unchanged: a preflight
// is an OPTIONS request, `web.test_request` takes a `Method`, and `Method` has
// no OPTIONS member. Both HEAD and OPTIONS are resolved from the raw token
// before a `Method` value exists, which is what keeps the frozen six-member
// enum byte-for-byte as the gate pins it. A public suite that could send a
// preflight would be evidence the enum had grown.
//
// So the requests here are driven the way a transport drives them: a
// `transport.Inbound` with the real token, through `driver_run`.
//
// THE ONE CASE THAT DECIDES THE DESIGN is `wp60_an_options_without_the_request_method_is_not_a_preflight`.
// An ordinary OPTIONS — the kind a client sends to ask what a route supports —
// must still get WP32a's `Allow`, and must not be swallowed by CORS. What
// separates the two is a single header, and a framework that treated every
// OPTIONS as a preflight would silently break a capability it already shipped.
package web

import "core:log"
import "core:strings"
import "core:testing"
import "druse:web/internal/transport"

APP_ORIGIN :: "https://app.example.com"

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

// Set by the handler, so a test can prove a preflight did NOT run one.
@(private = "file")
handler_ran: bool

@(private = "file")
ok_handler :: proc(ctx: ^Context) {
	handler_ran = true
	text(ctx, .OK, "pong")
}

@(private = "file")
run :: proc(a: ^App, token: string, path: string, headers: []transport.Header) -> Context {
	ctx: Context
	driver_run(a, &ctx, transport.Inbound{method = token, path = path, headers = headers})
	return ctx
}

@(private = "file")
header_value :: proc(ctx: ^Context, name: string) -> (string, bool) {
	for pair in ctx.private.response.headers {
		if ascii_fold_equal(pair.name, name) {
			return pair.value, true
		}
	}
	return "", false
}

// The preflight: 204, the echoed origin, the methods, and `Vary`.
@(test)
wp60_a_preflight_is_answered_without_running_a_handler :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	cors(&a, Cors_Options{origins = {APP_ORIGIN}, headers = "Content-Type", max_age = 600})
	get(&a, "/thing", ok_handler)

	handler_ran = false
	req := [?]transport.Header {
		{name = "Origin", value = APP_ORIGIN},
		{name = "Access-Control-Request-Method", value = "POST"},
	}
	ctx := run(&a, "OPTIONS", "/thing", req[:])

	testing.expect_value(t, ctx.private.response.status, Status.No_Content)
	testing.expect(
		t,
		!handler_ran,
		"a preflight must be answered before any handler runs: the browser is asking for permission, not for the resource",
	)

	origin, has_origin := header_value(&ctx, "Access-Control-Allow-Origin")
	testing.expect(t, has_origin, "a preflight must carry the allowed origin")
	testing.expect_value(t, origin, APP_ORIGIN)

	methods, has_methods := header_value(&ctx, "Access-Control-Allow-Methods")
	testing.expect(t, has_methods, "a preflight must say which methods are allowed")
	testing.expect_value(t, methods, CORS_DEFAULT_METHODS)

	allowed_headers, has_headers := header_value(&ctx, "Access-Control-Allow-Headers")
	testing.expect(t, has_headers, "a configured header list must be announced")
	testing.expect_value(t, allowed_headers, "Content-Type")

	max_age, has_max_age := header_value(&ctx, "Access-Control-Max-Age")
	testing.expect(t, has_max_age, "a configured max_age must be announced")
	testing.expect_value(t, max_age, "600")

	vary, has_vary := header_value(&ctx, "Vary")
	testing.expect(t, has_vary, "a preflight must carry Vary")
	testing.expect_value(t, vary, "Origin")

	response_destroy(&ctx.private.response)
}

// **THE CASE THAT SEPARATES THE TWO FEATURES.** An OPTIONS without
// `Access-Control-Request-Method` is not a preflight — it is the ordinary
// "what does this route support?" that WP32a already answers. CORS must not
// swallow it.
@(test)
wp60_an_options_without_the_request_method_is_not_a_preflight :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	cors(&a, Cors_Options{origins = {APP_ORIGIN}})
	get(&a, "/thing", ok_handler)

	req := [?]transport.Header{{name = "Origin", value = APP_ORIGIN}}
	ctx := run(&a, "OPTIONS", "/thing", req[:])

	allow, has_allow := header_value(&ctx, "Allow")
	testing.expect(
		t,
		has_allow,
		"an ordinary OPTIONS must still receive WP32a's Allow; a framework that treated every OPTIONS as a preflight would break a shipped capability",
	)
	testing.expect(t, len(allow) > 0, "the Allow header must name the route's methods")

	_, has_methods := header_value(&ctx, "Access-Control-Allow-Methods")
	testing.expect(
		t,
		!has_methods,
		"an ordinary OPTIONS is not a preflight and must not be answered as one",
	)

	response_destroy(&ctx.private.response)
}

// A preflight from an origin that is NOT listed gets no CORS headers, and is
// not treated as a preflight at all — so it falls through to the ordinary
// OPTIONS answer. The browser then refuses the real request, which is correct.
@(test)
wp60_a_preflight_from_an_unlisted_origin_is_not_honoured :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	cors(&a, Cors_Options{origins = {APP_ORIGIN}})
	get(&a, "/thing", ok_handler)

	req := [?]transport.Header {
		{name = "Origin", value = "https://evil.example.com"},
		{name = "Access-Control-Request-Method", value = "POST"},
	}
	ctx := run(&a, "OPTIONS", "/thing", req[:])

	_, has_origin := header_value(&ctx, "Access-Control-Allow-Origin")
	testing.expect(
		t,
		!has_origin,
		"an unlisted origin must not be told it is allowed, not even in a preflight",
	)

	response_destroy(&ctx.private.response)
}

// `max_age = 0` omits the header rather than sending zero, which would tell the
// browser not to cache at all — a different instruction from "use your default".
@(test)
wp60_a_zero_max_age_is_omitted :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	cors(&a, Cors_Options{origins = {APP_ORIGIN}})
	get(&a, "/thing", ok_handler)

	req := [?]transport.Header {
		{name = "Origin", value = APP_ORIGIN},
		{name = "Access-Control-Request-Method", value = "GET"},
	}
	ctx := run(&a, "OPTIONS", "/thing", req[:])

	_, has_max_age := header_value(&ctx, "Access-Control-Max-Age")
	testing.expect(
		t,
		!has_max_age,
		"a zero max_age must be omitted: sending 0 forbids caching, which is not what 'unset' means",
	)

	response_destroy(&ctx.private.response)
}

// The rendered `max_age` is request-local storage, so a large value must render
// correctly rather than overflowing the buffer it is written into backwards.
@(test)
wp60_a_large_max_age_renders :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	cors(&a, Cors_Options{origins = {APP_ORIGIN}, max_age = 86400})
	get(&a, "/thing", ok_handler)

	req := [?]transport.Header {
		{name = "Origin", value = APP_ORIGIN},
		{name = "Access-Control-Request-Method", value = "GET"},
	}
	ctx := run(&a, "OPTIONS", "/thing", req[:])

	max_age, has_max_age := header_value(&ctx, "Access-Control-Max-Age")
	testing.expect(t, has_max_age, "max_age must be announced")
	testing.expect_value(t, max_age, "86400")

	response_destroy(&ctx.private.response)
}

// A poisoned CORS policy must reject the application, observed here as the
// registration flag rather than through a request.
@(test)
wp60_an_unsafe_policy_poisons_the_app :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	a := app()
	defer destroy(&a)
	cors(&a, Cors_Options{origins = {"*"}, credentials = true})

	testing.expect(
		t,
		a.private.poisoned,
		"a wildcard origin with credentials must poison the application at registration",
	)
}
