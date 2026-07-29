// WP32b internal contract — automatic HEAD and OPTIONS.
//
// WHY THIS SUITE IS INTERNAL. `web.test_request` takes a `Method`, and `Method`
// has no HEAD and no OPTIONS — which is the whole point of the design: both are
// resolved from the raw token before a `Method` value exists, so the frozen
// six-member enum stays byte-for-byte as the gate pins it. A public-surface
// suite therefore CANNOT send either method, and a test that could would be
// evidence the enum had grown.
//
// So the requests here are driven the way a transport drives them: a
// `transport.Inbound` with the real token, through `driver_run`, exactly as the
// socket and the test facade both do.
package web

import "core:log"
import "core:strings"
import "core:testing"
import "druse:web/internal/transport"

// The `bare()` finalizer's 500 report is an EXPECTED Error-level `druse:` log
// line, and the pinned test runner records Error output as a failure. This
// swallows exactly those and forwards everything else — the WP8 idiom, reused
// rather than reinvented.
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

@(private = "file")
handler :: proc(ctx: ^Context) {
	text(ctx, .OK, "body-bytes")
}

@(private = "file")
run :: proc(a: ^App, token: string, path: string) -> (ctx: Context, body: []u8) {
	driver_run(a, &ctx, transport.Inbound{method = token, path = path})
	return ctx, response_body_view(&ctx)
}

// HEAD is answered as GET with the body suppressed. Status and headers are the
// GET's, byte for byte — the RFC requires the responses to be identical except
// for the body.
@(test)
wp32_head_is_get_without_the_body :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "/thing", handler)

	get_ctx, get_body := run(&a, "GET", "/thing")
	head_ctx, head_body := run(&a, "HEAD", "/thing")

	testing.expect_value(t, get_ctx.private.response.status, Status.OK)
	testing.expect_value(t, head_ctx.private.response.status, Status.OK)
	testing.expect(t, len(get_body) > 0, "the GET must carry a body")
	testing.expect_value(t, len(head_body), 0)

	// The headers are not stripped with the body: a HEAD must advertise the
	// same representation a GET would have sent.
	testing.expect_value(
		t,
		len(head_ctx.private.response.headers),
		len(get_ctx.private.response.headers),
	)

	driver_cleanup(&get_ctx)
	driver_cleanup(&head_ctx)
}

// The handler is never told. It ran and committed a body; the suppression
// happened on the way out, which is what keeps every responder covered by one
// rule instead of each learning about HEAD.
@(test)
wp32_the_response_still_owns_its_body :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "/thing", handler)

	ctx, view := run(&a, "HEAD", "/thing")
	testing.expect_value(t, len(view), 0)
	// The committed body is intact underneath the view — blanking it would
	// leak an allocation the Response owns and `response_destroy` must free.
	testing.expect(t, len(ctx.private.response.body) > 0, "the response keeps its body")
	driver_cleanup(&ctx)
}

// A HEAD to a path with no route gets what a GET would have got.
@(test)
wp32_head_misses_like_a_get :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "/thing", handler)

	ctx, body := run(&a, "HEAD", "/absent")
	testing.expect_value(t, ctx.private.response.status, Status.Not_Found)
	testing.expect_value(t, len(body), 0)
	driver_cleanup(&ctx)
}

// OPTIONS answers 204 with the Allow the 405 would have produced — the same
// machinery, not a second one.
@(test)
wp32_options_answers_204_with_the_same_allow_as_a_405 :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "/thing", handler)
	post(&a, "/thing", handler)

	options_ctx, options_body := run(&a, "OPTIONS", "/thing")
	testing.expect_value(t, options_ctx.private.response.status, Status.No_Content)
	testing.expect_value(t, len(options_body), 0)

	// A DELETE to the same path is a 405 and carries the ratified Allow value.
	// The two must be byte-identical, or a second Allow machine has appeared.
	miss_ctx, _ := run(&a, "DELETE", "/thing")
	testing.expect_value(t, miss_ctx.private.response.status, Status.Method_Not_Allowed)

	options_allow := header_value(&options_ctx, "Allow")
	miss_allow := header_value(&miss_ctx, "Allow")
	testing.expect(t, len(options_allow) > 0, "OPTIONS must carry an Allow header")
	testing.expect_value(t, options_allow, miss_allow)

	driver_cleanup(&options_ctx)
	driver_cleanup(&miss_ctx)
}

// A path that does not exist does not acquire an options list.
@(test)
wp32_options_on_an_unknown_path_is_a_miss :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "/thing", handler)

	ctx, _ := run(&a, "OPTIONS", "/absent")
	testing.expect_value(t, ctx.private.response.status, Status.Not_Found)
	driver_cleanup(&ctx)
}

// NO 501. An unrecognised method keeps its 405 with the exact Allow, which
// tells a client what it CAN do where 501 only says the server will not.
@(test)
wp32_an_unknown_method_is_still_405_and_never_501 :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	get(&a, "/thing", handler)

	ctx, _ := run(&a, "BREW", "/thing")
	testing.expect_value(t, ctx.private.response.status, Status.Method_Not_Allowed)
	testing.expect(t, len(header_value(&ctx, "Allow")) > 0, "the 405 must still advertise Allow")
	driver_cleanup(&ctx)
}

// `bare()` installs no miss policy, and automatic OPTIONS IS miss policy.
@(test)
wp32_bare_installs_no_automatic_options :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	a := bare()
	defer destroy(&a)
	get(&a, "/thing", handler)

	ctx, _ := run(&a, "OPTIONS", "/thing")
	// `bare()` commits nothing of its own, so the driver's last-gasp finalizer
	// answers — never a 204 this App never promised.
	testing.expect(
		t,
		ctx.private.response.status != Status.No_Content,
		"bare() must not answer OPTIONS automatically",
	)
	driver_cleanup(&ctx)
}

@(private = "file")
header_value :: proc(ctx: ^Context, name: string) -> string {
	for pair in ctx.private.response.headers {
		if pair.name == name {
			return pair.value
		}
	}
	return ""
}
