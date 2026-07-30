// WP23 public surface contract — `web.request_id`, as an EXTERNAL consumer of
// `druse:web` sees it.
//
// THIS WORK PACKAGE IS A SECURITY BOUNDARY, and this suite is where the trust
// policy is visible from outside. The inbound `X-Request-Id` is
// ATTACKER-CONTROLLED, and ADR-027 (option A, accepted) decided exactly what
// happens to it:
//
//   * accepted ONLY if it matches charset `[A-Za-z0-9._-]` and length 1..64;
//   * otherwise a fresh ID is generated, and the client's value is DISCARDED —
//     never echoed, never logged, never readable by the handler;
//   * the effective ID is written into the private overlay `web.header`
//     consults, so a handler reads it through the ONE canonical name (G-01);
//   * the ID is NOT unguessable and must never be treated as authentication.
//
// The concrete attack is CR/LF header injection: a value carrying `\r\n` would
// forge additional response headers. The strict charset makes that impossible
// by construction, and this suite tests it anyway — "impossible by
// construction" is a claim until something asserts it.
package test_wp23_public

import "core:strings"
import "core:testing"
import web "druse:web"

// ---------------------------------------------------------------------------
// Handlers that report what the FRAMEWORK decided, through the public read
// path. `web.header` is the only way an application sees a request ID: there
// is no second accessor, by ADR-027.
// ---------------------------------------------------------------------------

Seen :: struct {
	id:    [128]u8,
	n:     int,
	found: bool,
	calls: int,
}

// The sink travels through `context.user_ptr`, NOT a package global (the WP20
// precedent). The runner executes tests on several threads at once, and a
// shared global sink is a data race that shows up as one test reading another
// test's request ID — which is exactly how the first draft of this file failed.
// `context` is per-test and propagates synchronously into the handler.
capture_id :: proc(ctx: ^web.Context) {
	value, ok := web.header(ctx, "X-Request-Id")
	sink := (^Seen)(context.user_ptr)
	if sink != nil {
		sink.calls += 1
		sink.found = ok
		sink.n = copy(sink.id[:], value)
	}
	web.text(ctx, .OK, "ok")
}

seen_id :: proc(sink: ^Seen) -> string {
	if sink == nil {
		return ""
	}
	return string(sink.id[:sink.n])
}

// ---------------------------------------------------------------------------
// Generated when absent.
// ---------------------------------------------------------------------------

@(test)
wp23_public_absent_inbound_is_generated_and_readable :: proc(t: ^testing.T) {
	sink: Seen
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, web.request_id)
	web.get(&a, "/ping", capture_id)

	res := web.test_request(&a, .GET, "/ping")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(t, sink.found, "the handler must be able to read the generated ID")
	testing.expect(t, len(seen_id(&sink)) > 0, "a generated ID is not empty")
	testing.expect(t, len(seen_id(&sink)) <= 64, "a generated ID respects the ratified length bound")

	// The generated form must satisfy the same charset the inbound policy
	// enforces: the framework does not hold itself to a looser rule than it
	// imposes on clients.
	for i in 0 ..< len(seen_id(&sink)) {
		c := seen_id(&sink)[i]
		ok :=
			(c >= 'A' && c <= 'Z') ||
			(c >= 'a' && c <= 'z') ||
			(c >= '0' && c <= '9') ||
			c == '.' ||
			c == '_' ||
			c == '-'
		testing.expect(t, ok, "a generated ID uses only the ratified charset")
	}
}

@(test)
wp23_public_two_requests_get_different_ids :: proc(t: ^testing.T) {
	sink: Seen
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, web.request_id)
	web.get(&a, "/ping", capture_id)

	_ = web.test_request(&a, .GET, "/ping")
	first: [128]u8
	first_n := copy(first[:], seen_id(&sink))

	_ = web.test_request(&a, .GET, "/ping")
	second := seen_id(&sink)

	testing.expect(t, second != string(first[:first_n]), "each request gets its own ID")
}

@(test)
wp23_public_an_id_never_leaks_into_the_next_request :: proc(t: ^testing.T) {
	// Today this holds STRUCTURALLY: `Context` is a fresh stack value per
	// request, so the overlay starts zeroed and there is nothing to leak. The
	// test exists anyway, because Phase 3 plans buffer reuse (P3-10) and Phase
	// 4 plans connection slots — this is the assertion that turns a structural
	// accident into a defended invariant on the day something starts being
	// pooled.
	sink: Seen
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, web.request_id)
	web.get(&a, "/ping", capture_id)

	// A request that supplies a valid ID, then one that supplies none.
	_ = web.test_request(&a, .GET, "/ping", headers = []string{"X-Request-Id: caller-supplied-1"})
	testing.expect_value(t, seen_id(&sink), "caller-supplied-1")

	_ = web.test_request(&a, .GET, "/ping")
	testing.expect(
		t,
		seen_id(&sink) != "caller-supplied-1",
		"the second request must never observe the first request's ID",
	)
	testing.expect(t, len(seen_id(&sink)) > 0, "the second request still gets an ID of its own")
}

// ---------------------------------------------------------------------------
// The trust policy: what a client may and may not influence.
// ---------------------------------------------------------------------------

@(test)
wp23_public_a_valid_inbound_id_is_honoured :: proc(t: ^testing.T) {
	// Honouring a well-formed inbound ID is what makes correlation work behind
	// a gateway that already stamps one.
	sink: Seen
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, web.request_id)
	web.get(&a, "/ping", capture_id)

	_ = web.test_request(
		&a,
		.GET,
		"/ping",
		headers = []string{"X-Request-Id: abc.DEF_123-xyz"},
	)

	testing.expect_value(t, seen_id(&sink), "abc.DEF_123-xyz")
}

@(test)
wp23_public_crlf_is_never_echoed :: proc(t: ^testing.T) {
	// THE ATTACK. A value carrying CR/LF would forge response headers. It is
	// rejected by charset, and the handler must see a framework-generated ID
	// with no trace of the client's bytes.
	sink: Seen
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, web.request_id)
	web.get(&a, "/ping", capture_id)

	_ = web.test_request(
		&a,
		.GET,
		"/ping",
		headers = []string{"X-Request-Id: evil\r\nX-Injected: yes"},
	)

	testing.expect(t, sink.found, "a rejected inbound value is REPLACED, never left absent")
	testing.expect(
		t,
		!strings.contains(seen_id(&sink), "\r") && !strings.contains(seen_id(&sink), "\n"),
		"no CR or LF may survive into the effective ID",
	)
	testing.expect(
		t,
		!strings.contains(seen_id(&sink), "evil") && !strings.contains(seen_id(&sink), "Injected"),
		"an attacker-supplied value must be DISCARDED, not repaired",
	)
}

@(test)
wp23_public_oversized_and_malformed_values_are_replaced :: proc(t: ^testing.T) {
	sink: Seen
	context.user_ptr = &sink

	// 65 characters: one past the ratified bound.
	long: [65]u8
	for i in 0 ..< len(long) {
		long[i] = 'a'
	}
	oversized := strings.concatenate({"X-Request-Id: ", string(long[:])}, context.temp_allocator)

	cases := []string {
		oversized,
		"X-Request-Id: ",                 // empty: length 0 is below the bound
		"X-Request-Id: has space",        // SP is outside the charset
		"X-Request-Id: sémi-ascii",       // non-ASCII
		"X-Request-Id: semi;colon",       // punctuation outside the charset
		"X-Request-Id: tab\there",        // control byte
	}

	for header_line in cases {
		a := web.app()
		defer web.destroy(&a)
		web.use(&a, web.request_id)
		web.get(&a, "/ping", capture_id)

		_ = web.test_request(&a, .GET, "/ping", headers = []string{header_line})

		testing.expect(t, sink.found, "a rejected value is replaced by a generated one")
		testing.expect(
			t,
			len(seen_id(&sink)) > 0 && len(seen_id(&sink)) <= 64,
			"the replacement respects the ratified bound",
		)
		testing.expect(
			t,
			!strings.contains(header_line, seen_id(&sink)),
			"no part of a rejected client value may appear in the effective ID",
		)
	}
}

// ---------------------------------------------------------------------------
// Opt-in, and the shape.
// ---------------------------------------------------------------------------

@(test)
wp23_public_is_opt_in :: proc(t: ^testing.T) {
	// Without the middleware there is no overlay and no ID: `web.header` reads
	// exactly what arrived, which is nothing.
	sink: Seen
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/ping", capture_id)

	res := web.test_request(&a, .GET, "/ping")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(t, !sink.found, "no middleware, no request ID")
}

@(test)
wp23_public_without_the_middleware_an_inbound_id_is_just_a_header :: proc(t: ^testing.T) {
	// `web.header` stays a pure lookup when nothing writes the overlay: the
	// arrived value is returned verbatim, unvalidated, because validation is
	// the MIDDLEWARE's job and not the accessor's.
	sink: Seen
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/ping", capture_id)

	_ = web.test_request(&a, .GET, "/ping", headers = []string{"X-Request-Id: whatever;;"})

	testing.expect(t, sink.found, "the arrived header is still readable")
	testing.expect_value(t, seen_id(&sink), "whatever;;")
}

@(test)
wp23_public_signature_is_pinned :: proc(t: ^testing.T) {
	// `request_id` IS a `Handler` — no constructor, no configuration object,
	// and NO second public name for reading the value (ADR-027 closed the
	// `request_id_value` contingency).
	handler_sig: web.Handler = web.request_id

	sink: Seen
	context.user_ptr = &sink

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, handler_sig)
	web.get(&a, "/ping", capture_id)

	res := web.test_request(&a, .GET, "/ping")
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(t, sink.found, "the pinned value behaves as the middleware")
}

@(test)
wp23_public_request_id_app_tears_down_cleanly :: proc(t: ^testing.T) {
	// `odin test` tracks allocations: the ID lives in fixed request-local
	// storage and must own nothing.
	sink: Seen
	context.user_ptr = &sink

	a := web.app()
	web.use(&a, web.request_id)
	web.get(&a, "/ping", capture_id)
	_ = web.test_request(&a, .GET, "/ping")
	_ = web.test_request(&a, .GET, "/ping", headers = []string{"X-Request-Id: valid-id"})
	_ = web.test_request(&a, .GET, "/nope")
	web.destroy(&a)
}
