// WP3 — PUBLIC TEST-SUPPORT FACADE (package `web`).
//
// This file adds the ONLY two public test-support symbols: `Recorded_Response`
// and `test_request`. They are a SEPARATE ledger (planning/public-api-guardrails.md G-11): public,
// documented, and behavior-tested exactly like the application surface, but
// tracked apart from the frozen 32-symbol application count. Total exported
// after WP3: 34 = 32 application + 2 test-support.
//
// The facade is thin. It converts `App`/`Method` and the captured internal
// `Response` across the boundary to the neutral machinery in `web/testing`,
// which owns the request/response representation and the response copies. The
// machinery never names a `web` type, so `web -> web/testing` stays one-way (the
// back-edge is a compile cycle, ratified as probe C5).
package web
// druse:file test-support

import "core:strings"
import transport "druse:web/internal/transport"
import testing "druse:web/testing"

// Recorded_Response is the read-only result of `web.test_request`.
//
// It exposes exactly two fields in Phase 1:
//
//   - `status`: the response status, COPIED BY VALUE;
//   - `body`:   a string VIEW over a copy owned by the App's test-support state,
//               valid until `web.destroy(&app)`.
//
// There is deliberately NO public `headers`, `committed`, allocator or transport
// field. The recorder copies response headers internally for the future WP4
// tests (405 + `Allow`), but Phase 1 ratifies no public abstraction for reading
// response headers, and adding a field here would freeze one prematurely.
//
// LIFETIME: `body` remains readable, alongside every other response returned by
// the same App, until `web.destroy(&app)` frees the App's test-support state.
// There is no per-response cleanup. Do not retain a `Recorded_Response.body`
// past `destroy`.
Recorded_Response :: struct {
	status: Status,
	body:   string,

	// WP49 — the response headers, as `"Name: value"` lines.
	//
	// **D-14.3 IS DECIDED HERE, AND THIS WORK PACKAGE IS WHY.** Phase 2
	// deliberately kept this type at two fields and recorded the pressure as an
	// open question: an assertion about a response header had to be written as
	// an INTERNAL `package web` test, because the public test transport could
	// not see one. That was tolerable while the only header in question was one
	// the framework set for itself.
	//
	// It stops being tolerable here. `secure_headers` exists so an application
	// can assert its own security posture — and an application that cannot
	// observe the headers it asked for has to test through a socket, which is
	// exactly what `test_request` exists to avoid. **A test-support API that
	// cannot see what the framework sets is a test-support API that pushes
	// people back to the thing it replaced.**
	//
	// LINES RATHER THAN PAIRS, and that is a deliberate refusal of surface: a
	// `Header_Pair` here would export the pair type, and a map would export a
	// lookup contract and an allocation. `"Name: value"` is the wire form, it
	// needs no new type, and `strings.contains` is the whole API. The slice and
	// its strings are owned by the recorder and are valid until the next
	// `test_request` on the same App — the same lifetime `body` already has.
	headers: []string,
}

// test_request drives one in-memory request through dispatch and returns the
// recorded response, WITHOUT binding a socket or port.
//
// WP4 wired routing, so this now returns REAL routed results: a registered
// route's handler runs, an unknown path on `web.app()` produces a 404, and a
// path registered under another method produces a 405. Only `web.destroy` and
// the recorder stand between the caller and the framework's own dispatch.
//
// The framework never fabricates a 200 on a handler's behalf. A handler that
// responds with nothing is finalized by the DRIVER to a logged
// `internal_error`/500 (WP8 D5), exactly as it is over a real socket — HTTP has
// no zero status.
//
// The App's test-support state is created LAZILY here, on the first call, using
// `context.allocator`. An application that never calls `test_request` allocates
// no recorder, runs no initializer, and does not even LINK the recorder
// teardown — this procedure registers it, so eliminating this procedure
// eliminates it too (planning/public-api-guardrails.md G-11). Every copy the
// recorder makes is released by `web.destroy(&app)`.
// The `body` parameter is OPTIONAL and defaults to empty, so every Phase-1 call
// site keeps working unchanged (WP14, ADR-021 as amended).
//
// It is a default parameter rather than a procedure group on purpose. `odin doc`
// renders a group as `name :: proc{member_a, member_b}` — member names only — so
// a group over `@(private)` members would pin this symbol's NAME in the freeze
// snapshot while leaving its parameters free to change. That was measured, and
// `build/check_phase1_freeze.sh` now rejects the construct. A default parameter
// keeps the whole signature inside the frozen record, and it is how `core` adds
// optional behavior everywhere (`allocator := context.allocator`).
//
// The body travels the SAME driver path a socket uses: it is placed on the
// neutral `Inbound` and nothing downstream can tell the two transports apart.
// That is what makes the 4 MiB cap and the JSON errors identical here and on a
// real connection (R-10), rather than a claim this facade makes about itself.
// WP19: `headers` is the THIRD fully visible default parameter, on exactly the
// ADR-021 terms the first two set — the whole callable contract stays inside
// the frozen record, and every earlier call shape compiles unchanged. Each
// element is one header line, `"Name: value"`: split at the FIRST colon, with
// optional whitespace (SP/HTAB) trimmed around the value — the same field
// parsing a socket transport performs, so the in-memory request carries
// exactly what the wire would deliver. Inner colons stay in the value; an
// element with no colon is a name with an empty value (an empty value is a
// PRESENT header). No test-only header type exists and `Header_Pair` stays
// private: strings were chosen over a pair type precisely so the test-support
// ledger stays at 2 (spec §9.3's stated contingency was not needed).
test_request :: proc(
	a: ^App,
	method: Method,
	path: string,
	body: string = "",
	query: string = "",
	headers: []string = nil,
) -> Recorded_Response {
	recorder := &a.private.test_transport

	// Register the teardown on first use. This assignment is the ONLY reference
	// to `testing.destroy` in the whole package, which is precisely the point:
	// an application that never calls `test_request` never mentions the
	// machinery teardown, so the linker drops it along with this procedure
	// (planning/public-api-guardrails.md G-11). `web.destroy` calls through the
	// pointer and does nothing when it is nil.
	a.private.test_teardown = testing.destroy

	// 1. The machinery constructs the neutral inbound request. The header
	//    lines are split into neutral pairs here, in the facade — views over
	//    the caller's strings, alive for this call, exactly like `body`. The
	//    slice is transient (temp allocator); the core's own conversion in
	//    `driver_run` treats it precisely as it treats a socket adapter's.
	req := testing.build_request(method_token(method), path)

	inbound_headers: []transport.Header
	if len(headers) > 0 {
		// A REPEATED NAME IS JOINED, not kept twice — because that is what the
		// socket does. The backend's `header_parse` combines repeats into ONE
		// entry with `", "` (RFC 9110 §5.3) before the core sees them, so a
		// wire request with `X-Dup: alpha` then `X-Dup: beta` reaches `header`
		// as the single value `"alpha, beta"`.
		//
		// This facade used to hand the core one pair per line. `header` returns
		// the first match, so the in-memory driver answered `"alpha"` where the
		// socket answered `"alpha, beta"` — the two drivers disagreed on a
		// documented contract, and `wp19_public_duplicates_first_occurrence_wins`
		// pinned the in-memory answer, which made the divergence look ratified.
		// The parity this procedure claims (R-10) has to include this case.
		merged := make([dynamic]transport.Header, 0, len(headers), context.temp_allocator)
		for line in headers {
			name, value := test_header_split(line)
			found := false
			for &pair in merged {
				// Case-insensitive, like the backend's lowercasing key rule and
				// like `header`'s own ASCII folding.
				if ascii_fold_equal(pair.name, name) {
					pair.value = strings.concatenate(
						{pair.value, ", ", value},
						context.temp_allocator,
					)
					found = true
					break
				}
			}
			if !found {
				append(&merged, transport.Header{name = name, value = value})
			}
		}
		inbound_headers = merged[:]
	}

	// 2-3. WP9 — the SHARED driver pipeline: neutral inbound -> Context ->
	//      dispatch -> finalize a missing response. `serve` runs exactly this
	//      same procedure, which is what makes semantic parity between the
	//      in-memory transport and a real socket structural rather than a
	//      claim (R-10).
	ctx: Context
	driver_run(
		a,
		&ctx,
		transport.Inbound{
			method = req.method,
			path   = req.path,
			// Query is carried SEPARATELY from the path, exactly as the real
			// adapter does it: the transport splits the request target before the
			// core ever sees it, so a `?` inside `path` is not a query string
			// here any more than it would be on a socket.
			query  = query,
			// A view over the caller's string for the duration of this call. The
			// core copies whatever it decides to keep, exactly as it does for a
			// socket, so nothing here outlives the request.
			body    = transmute([]u8)body,
			headers = inbound_headers,
		},
	)

	// 4. The facade hands the internal Response to the recorder as neutral
	//    values. The header conversion is transient (temp allocator); the
	//    recorder makes its own owned copies with context.allocator.
	res := &ctx.private.response
	neutral_headers := response_headers_neutral(res.headers)

	status_int, body := testing.capture(
		recorder,
		context.allocator,
		int(res.status),
		// WP32b: a HEAD response carries the GET's status and headers and no
		// body, on both drivers.
		response_body_view(&ctx),
		neutral_headers,
	)

	// 5. This facade is the response DRIVER, so it tears the request down once
	//    the recorder has copied it (ADR-014). The ORDER matters: the recorder
	//    makes owned copies of status, body and headers above, and only after
	//    that does the response's own allocation become releasable — tearing
	//    down first would hand the recorder a freed buffer to copy. A borrowed
	//    body (a static envelope, or the fixed WP5 buffer) is left alone.
	//    WP9 routes this through the same `driver_cleanup` the real transport
	//    uses, so both drivers release in one ratified order.
	driver_cleanup(&ctx)

	// 6. The facade returns the public shape. `body` is the recorder's own copy,
	//    valid until `web.destroy(&app)`, so it is unaffected by the teardowns
	//    above.
	return Recorded_Response {
		status = Status(status_int),
		body = body,
		// WP49 / D-14.3: the machinery owns the copies; this is a view over
		// them, valid until the next `test_request` on this App.
		headers = testing.last_headers(recorder),
	}
}

// test_header_split parses one `"Name: value"` line: the name is everything
// before the FIRST colon, the value is everything after it with optional
// whitespace (SP/HTAB) trimmed from both ends — RFC 9110 field parsing, which
// is what a socket transport delivers to the core. A line with no colon is a
// name with an empty value. Both results are views over `line`; nothing is
// copied and nothing is allocated.
@(private)
test_header_split :: proc(line: string) -> (name: string, value: string) {
	colon := -1
	for i in 0 ..< len(line) {
		if line[i] == ':' {
			colon = i
			break
		}
	}
	if colon < 0 {
		return line, ""
	}

	name = line[:colon]
	value = line[colon + 1:]
	for len(value) > 0 && (value[0] == ' ' || value[0] == '\t') {
		value = value[1:]
	}
	for len(value) > 0 && (value[len(value) - 1] == ' ' || value[len(value) - 1] == '\t') {
		value = value[:len(value) - 1]
	}
	return name, value
}

// response_headers_neutral converts the framework's private header pairs into
// neutral `testing.Header` values for the recorder. The result is transient
// (temp allocator) and is consumed synchronously by the recorder, which makes
// its own owned copies — this slice never backs a returned `Recorded_Response`.
@(private)
response_headers_neutral :: proc(pairs: []Header_Pair) -> []testing.Header {
	out := make([]testing.Header, len(pairs), context.temp_allocator)
	for pair, i in pairs {
		out[i] = testing.Header{name = pair.name, value = pair.value}
	}
	return out
}
