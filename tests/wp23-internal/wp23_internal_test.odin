// WP23 internal behavior tests — the RESPONSE header, the overlay slot, the
// validator, and the generator.
//
// This file declares `package web` but does NOT live in `web/`: the committed
// `Response`, the overlay slot, the request-local ID storage and the validator
// are all package-private, and on the pinned toolchain an `@(test)` procedure
// must be compiled as part of the package it tests. `build/check.sh` assembles
// a THROWAWAY package from the real `web/` sources plus this file, exactly as
// it does for WP2-WP22.
//
// WHY THESE TESTS ARE INTERNAL. The most important WP23 contract cannot be
// observed from outside the package at all: `Recorded_Response` deliberately
// exposes only `status` and `body` (G-11), so "the ID is on the response" is a
// claim no public test can check. It is checked here, against the committed
// `Response`, before teardown — the WP17 `Allow` precedent.
package web

import transport "druse:web/internal/transport"
import "core:log"
import "core:strings"
import "core:testing"

// The quiet-logger idiom (WP17-WP22): the driver-500 test provokes a framework
// diagnostic on purpose, and the runner records any Error line as a failure.
// The expected `druse:` Errors are swallowed and EVERYTHING ELSE is forwarded
// — `testing.expect` reports through `context.logger`, so a logger that
// swallowed everything would make its own test unable to fail.
@(private = "file")
Wp23_Quiet :: struct {
	inner: log.Logger,
}

@(private = "file")
wp23_quiet_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Wp23_Quiet)(data)
	if level == .Error && strings.contains(text, "druse:") {
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

// Returns the logger; the caller arms it in the TEST body — assigning
// `context.logger` inside a helper would only change the helper's context.
@(private = "file")
wp23_quiet_logger :: proc(record: ^Wp23_Quiet) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = wp23_quiet_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

// wp23_run drives one request through the SAME private pipeline `serve` and
// `test_request` share, so the caller owns the Context and can inspect the
// committed response — including its request-local ID storage — before
// `driver_cleanup`.
@(private = "file")
wp23_run :: proc(a: ^App, ctx: ^Context, method: Method, path: string, headers: []transport.Header = nil) {
	driver_run(
		a,
		ctx,
		transport.Inbound{method = method_token(method), path = path, headers = headers},
	)
}

@(private = "file")
wp23_ok :: proc(ctx: ^Context) {
	text(ctx, .OK, "ok")
}

// The sink travels through `context.user_ptr`, never a package global: the
// runner executes tests on several threads and a shared global is a race.
@(private = "file")
Wp23_Seen :: struct {
	id:    [128]u8,
	n:     int,
	found: bool,
}

// wp23_capture reads the ID AT HANDLER TIME, which is the only moment that can
// distinguish "the overlay was published before `next`" from "after". Reading
// it once dispatch has returned cannot: by then a late publish looks identical.
@(private = "file")
wp23_capture :: proc(ctx: ^Context) {
	value, ok := header(ctx, REQUEST_ID_HEADER)
	sink := (^Wp23_Seen)(context.user_ptr)
	if sink != nil {
		sink.found = ok
		sink.n = copy(sink.id[:], value)
	}
	text(ctx, .OK, "ok")
}

@(private = "file")
wp23_silent :: proc(ctx: ^Context) {
	// Commits nothing; the driver finalizes the standard 500.
}

// wp23_response_header returns the committed value for `name`, and whether it
// was present at all.
@(private = "file")
wp23_response_header :: proc(ctx: ^Context, name: string) -> (string, bool) {
	for pair in ctx.private.response.headers {
		if pair.name == name {
			return pair.value, true
		}
	}
	return "", false
}

@(private = "file")
wp23_count_header :: proc(ctx: ^Context, name: string) -> int {
	n := 0
	for pair in ctx.private.response.headers {
		if pair.name == name {
			n += 1
		}
	}
	return n
}

// ---------------------------------------------------------------------------
// The response header.
// ---------------------------------------------------------------------------

@(test)
wp23_the_id_is_on_the_response :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	use(&a, request_id)
	get(&a, "/ping", wp23_ok)

	ctx: Context
	defer driver_cleanup(&ctx)
	wp23_run(&a, &ctx, .GET, "/ping")

	value, ok := wp23_response_header(&ctx, REQUEST_ID_HEADER)
	testing.expect(t, ok, "the response must carry the request ID")
	testing.expect(t, len(value) > 0, "and it must not be empty")

	// The response header and what the handler read are the SAME value: one
	// effective ID, not two that happen to agree.
	overlay, found := header(&ctx, REQUEST_ID_HEADER)
	testing.expect(t, found, "the overlay is set")
	testing.expect_value(t, overlay, value)
}

@(test)
wp23_the_header_is_emitted_exactly_once :: proc(t: ^testing.T) {
	// A duplicated `X-Request-Id` is a correlation bug and, on some proxies, a
	// request-smuggling signal. Exactly one.
	a := app()
	defer destroy(&a)
	use(&a, request_id)
	get(&a, "/ping", wp23_ok)

	ctx: Context
	defer driver_cleanup(&ctx)
	wp23_run(
		&a,
		&ctx,
		.GET,
		"/ping",
		[]transport.Header{{name = "X-Request-Id", value = "inbound-value"}},
	)

	testing.expect_value(t, wp23_count_header(&ctx, REQUEST_ID_HEADER), 1)
}

@(test)
wp23_the_id_appears_on_a_404 :: proc(t: ^testing.T) {
	// A miss is exactly the traffic correlation is most needed for. The miss
	// chain runs the middleware (ADR-023), so the ID is present.
	a := app()
	defer destroy(&a)
	use(&a, request_id)
	get(&a, "/ping", wp23_ok)

	ctx: Context
	defer driver_cleanup(&ctx)
	wp23_run(&a, &ctx, .GET, "/nope")

	testing.expect_value(t, ctx.private.response.status, Status.Not_Found)
	value, ok := wp23_response_header(&ctx, REQUEST_ID_HEADER)
	testing.expect(t, ok, "a 404 must carry the request ID")
	testing.expect(t, len(value) > 0, "and it must not be empty")
}

@(test)
wp23_the_id_appears_on_a_405_without_displacing_allow :: proc(t: ^testing.T) {
	// The WP4 contract is that `Allow` comes FIRST and `Content-Type` second,
	// deterministically. The request ID is APPENDED, so it cannot renumber a
	// header an already-merged test pins by index.
	a := app()
	defer destroy(&a)
	use(&a, request_id)
	post(&a, "/only", wp23_ok)

	ctx: Context
	defer driver_cleanup(&ctx)
	wp23_run(&a, &ctx, .GET, "/only")

	testing.expect_value(t, ctx.private.response.status, Status.Method_Not_Allowed)
	testing.expect_value(t, len(ctx.private.response.headers), 3)
	testing.expect_value(t, ctx.private.response.headers[0].name, "Allow")
	testing.expect_value(t, ctx.private.response.headers[0].value, "POST, OPTIONS")
	testing.expect_value(t, ctx.private.response.headers[1].name, "Content-Type")
	testing.expect_value(t, ctx.private.response.headers[2].name, REQUEST_ID_HEADER)
}

@(test)
wp23_the_id_appears_on_the_driver_500 :: proc(t: ^testing.T) {
	// A handler that commits nothing is finalized by the driver AFTER the chain
	// unwinds. The ID still lands, because it is seeded at header-build time
	// from request-local state rather than written by the middleware's own
	// unwind code — which is exactly why this design was chosen over having the
	// middleware stamp the response on the way out.
	quiet: Wp23_Quiet
	context.logger = wp23_quiet_logger(&quiet)

	a := app()
	defer destroy(&a)
	use(&a, request_id)
	get(&a, "/silent", wp23_silent)

	ctx: Context
	defer driver_cleanup(&ctx)
	wp23_run(&a, &ctx, .GET, "/silent")

	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
	_, ok := wp23_response_header(&ctx, REQUEST_ID_HEADER)
	testing.expect(t, ok, "even the standardized 500 carries the correlation ID")
}

@(test)
wp23_without_the_middleware_no_header_is_added :: proc(t: ^testing.T) {
	// Opt-in, asserted on the RESPONSE rather than only on the read path: an
	// application that does not use the middleware emits byte-for-byte what it
	// emitted before this work package existed.
	a := app()
	defer destroy(&a)
	get(&a, "/ping", wp23_ok)

	ctx: Context
	defer driver_cleanup(&ctx)
	wp23_run(
		&a,
		&ctx,
		.GET,
		"/ping",
		[]transport.Header{{name = "X-Request-Id", value = "inbound-value"}},
	)

	_, ok := wp23_response_header(&ctx, REQUEST_ID_HEADER)
	testing.expect(t, !ok, "no middleware, no response header — not even an echo")
	testing.expect_value(t, len(ctx.private.response.headers), 1)
}

@(test)
wp23_bare_adds_no_header_either :: proc(t: ^testing.T) {
	a := bare()
	defer destroy(&a)
	get(&a, "/ping", wp23_ok)

	ctx: Context
	defer driver_cleanup(&ctx)
	wp23_run(&a, &ctx, .GET, "/ping")

	_, ok := wp23_response_header(&ctx, REQUEST_ID_HEADER)
	testing.expect(t, !ok, "`bare()` installs nothing, including this")
}

@(test)
wp23_the_handler_reads_the_effective_id_not_the_arrived_one :: proc(t: ^testing.T) {
	// The overlay is published BEFORE `next`, and this is the test that says so.
	// Publishing it afterwards would leave the handler reading the ARRIVED
	// header — the very value the framework rejected — while the response
	// carried the effective one: two different IDs for one request, and the
	// rejected bytes back in the application's hands.
	sink: Wp23_Seen
	context.user_ptr = &sink

	a := app()
	defer destroy(&a)
	use(&a, request_id)
	get(&a, "/ping", wp23_capture)

	ctx: Context
	defer driver_cleanup(&ctx)
	wp23_run(
		&a,
		&ctx,
		.GET,
		"/ping",
		[]transport.Header{{name = "X-Request-Id", value = "evil\r\nX-Injected: yes"}},
	)

	seen := string(sink.id[:sink.n])
	testing.expect(t, sink.found, "the handler must see an effective ID")
	testing.expect(
		t,
		!strings.contains(seen, "evil") && !strings.contains(seen, "\r"),
		"the handler must never be handed the rejected inbound value",
	)

	// And it is the SAME value the response carries.
	value, ok := wp23_response_header(&ctx, REQUEST_ID_HEADER)
	testing.expect(t, ok, "the response carries it too")
	testing.expect_value(t, seen, value)
}

// ---------------------------------------------------------------------------
// The validator — the security boundary itself.
// ---------------------------------------------------------------------------

@(test)
wp23_the_validator_accepts_exactly_the_ratified_charset :: proc(t: ^testing.T) {
	testing.expect(t, request_id_acceptable("a"), "one character is the lower bound")
	testing.expect(t, request_id_acceptable("abcXYZ019"), "alphanumerics")
	testing.expect(t, request_id_acceptable("a.b_c-d"), "the three ratified punctuation bytes")

	sixty_four: [64]u8
	for i in 0 ..< len(sixty_four) {
		sixty_four[i] = 'x'
	}
	testing.expect(t, request_id_acceptable(string(sixty_four[:])), "64 is the upper bound")

	sixty_five: [65]u8
	for i in 0 ..< len(sixty_five) {
		sixty_five[i] = 'x'
	}
	testing.expect(t, !request_id_acceptable(string(sixty_five[:])), "65 is one too many")

	testing.expect(t, !request_id_acceptable(""), "empty is not a value")
	testing.expect(t, !request_id_acceptable("has space"), "SP is excluded")
	testing.expect(t, !request_id_acceptable("cr\rhere"), "CR is excluded — the injection byte")
	testing.expect(t, !request_id_acceptable("lf\nhere"), "LF is excluded — the injection byte")
	testing.expect(t, !request_id_acceptable("nul\x00here"), "NUL is excluded")
	testing.expect(t, !request_id_acceptable("semi;colon"), "punctuation outside the set")
	testing.expect(t, !request_id_acceptable("sl/ash"), "the path separator is excluded")
	testing.expect(t, !request_id_acceptable("hi\x80there"), "non-ASCII is excluded")
	testing.expect(t, !request_id_acceptable("del\x7Fhere"), "DEL is excluded")
}

@(test)
wp23_a_rejected_value_never_reaches_the_response :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	use(&a, request_id)
	get(&a, "/ping", wp23_ok)

	ctx: Context
	defer driver_cleanup(&ctx)
	wp23_run(
		&a,
		&ctx,
		.GET,
		"/ping",
		[]transport.Header{{name = "X-Request-Id", value = "evil\r\nX-Injected: yes"}},
	)

	value, ok := wp23_response_header(&ctx, REQUEST_ID_HEADER)
	testing.expect(t, ok, "a fresh ID replaced it")
	testing.expect(
		t,
		!strings.contains(value, "\r") && !strings.contains(value, "\n"),
		"no CR/LF may reach a response header value",
	)
	testing.expect(t, !strings.contains(value, "evil"), "the client value is discarded entirely")
}

// ---------------------------------------------------------------------------
// The generator.
// ---------------------------------------------------------------------------

@(test)
wp23_generated_ids_are_acceptable_to_the_validator :: proc(t: ^testing.T) {
	// The framework holds itself to the rule it imposes on clients: whatever it
	// generates must pass its own inbound check.
	buf: [REQUEST_ID_MAX]u8
	seen: [16]string
	store: [16][REQUEST_ID_MAX]u8

	for i in 0 ..< 16 {
		n := request_id_generate(buf[:])
		testing.expect(t, n > 0 && n <= REQUEST_ID_MAX, "a generated ID fits its storage")
		testing.expect(
			t,
			request_id_acceptable(string(buf[:n])),
			"a generated ID satisfies the ratified charset and length",
		)
		copied := copy(store[i][:], buf[:n])
		seen[i] = string(store[i][:copied])
	}

	// Uniqueness across a run: the counter half guarantees it even if the
	// process-start entropy were to repeat.
	for i in 0 ..< 16 {
		for j in i + 1 ..< 16 {
			testing.expect(t, seen[i] != seen[j], "generated IDs do not repeat within a process")
		}
	}
}

@(test)
wp23_the_id_storage_is_request_local_and_fixed :: proc(t: ^testing.T) {
	// The committed response holds a VIEW over this storage and is read after
	// dispatch returns, exactly like `allow_buffer`. It must therefore live on
	// the Context, and it must be a fixed array — an allocation here would sit
	// on a path any unauthenticated client can trigger at will.
	ctx: Context
	testing.expect_value(t, len(ctx.private.request_id_buffer), REQUEST_ID_MAX)
	testing.expect(t, !ctx.private.overlay_set, "a fresh Context carries no overlay")
}
