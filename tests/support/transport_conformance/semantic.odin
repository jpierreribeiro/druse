// WP9 — THE SHARED SEMANTIC MATRIX.
//
// One matrix, two factories. Every scenario below is executed by BOTH the
// in-memory transport and the real HTTP server, and both must produce the same
// logical result. That is the whole answer to R-10: if the test transport ever
// "lies" — diverges from a real socket — a scenario here fails on exactly one
// factory and names the divergence.
//
// What this matrix does NOT do is byte-level framing. The in-memory transport
// has no TCP parser, so asking it about `Content-Length` or chunking would be
// theatre. Framing safety is proven only against real adapters, by the raw-wire
// corpus in `corpus.odin`.
//
// `transport_contract_test` is the entry point the architecture spec names:
//
//	transport_contract_test :: proc(t: ^testing.T, factory: Transport_Factory)
package transport_conformance

import "core:encoding/json"
import "core:strings"
import "core:testing"

// Scenario_Result is the logical outcome a scenario expects, independent of
// transport. Only the fields a scenario actually cares about are checked.
Scenario :: struct {
	name:            string,
	request:         Exchange_Request,
	expect_status:   int,
	expect_body:     string,
	expect_body_has: string,
	expect_code:     string, // an error-envelope `code`, when the body is an envelope
	expect_headers:  []Header,
	expect_handler_runs: int,
}

// transport_contract_test runs the whole semantic matrix through one factory.
//
// The caller registers the fixture routes (they are identical for both
// factories — see the suites in tests/wp9-semantic/), then calls this.
transport_contract_test :: proc(t: ^testing.T, factory: Transport_Factory) {
	if !factory.start(factory.user) {
		testing.expectf(t, false, "[%s] transport did not start", factory.name)
		return
	}
	defer factory.destroy(factory.user)
	defer factory.stop(factory.user)

	for scenario in semantic_scenarios() {
		run_scenario(t, factory, scenario)
	}
}

@(private)
run_scenario :: proc(t: ^testing.T, factory: Transport_Factory, s: Scenario) {
	// Give every scenario a fresh temp budget. The factories build the request,
	// the response and the parsed headers in `context.temp_allocator`, and the
	// default temp allocator is a RING: left to accumulate across 20 scenarios
	// it wraps, and an earlier scenario's still-referenced headers quietly
	// become garbage. That produced an intermittent, ~1-in-3 "header allow not
	// found" on the real transport — a test-harness defect, not a framework one,
	// and exactly the kind of flake that teaches people to re-run until green.
	// Nothing from a previous scenario is needed here, so reclaiming up front is
	// both safe and sufficient.
	free_all(context.temp_allocator)

	res := factory.exchange(factory.user, s.request)
	if !res.ok {
		testing.expectf(t, false, "[%s] %s: no response", factory.name, s.name)
		return
	}

	testing.expectf(
		t,
		res.status == s.expect_status,
		"[%s] %s: expected status %d, got %d",
		factory.name,
		s.name,
		s.expect_status,
		res.status,
	)

	if s.expect_body != "" {
		testing.expectf(
			t,
			res.body == s.expect_body,
			"[%s] %s: expected body %q, got %q",
			factory.name,
			s.name,
			s.expect_body,
			res.body,
		)
	}

	if s.expect_body_has != "" {
		testing.expectf(
			t,
			strings.contains(res.body, s.expect_body_has),
			"[%s] %s: body %q does not contain %q",
			factory.name,
			s.name,
			res.body,
			s.expect_body_has,
		)
	}

	if s.expect_code != "" {
		code, ok := envelope_code(res.body)
		testing.expectf(
			t,
			ok && code == s.expect_code,
			"[%s] %s: expected envelope code %q, got %q",
			factory.name,
			s.name,
			s.expect_code,
			code,
		)
	}

	for want in s.expect_headers {
		got, found := header_value(res.headers, want.name)
		testing.expectf(
			t,
			found && got == want.value,
			"[%s] %s: header %s expected %q, got %q (found=%v)",
			factory.name,
			s.name,
			want.name,
			want.value,
			got,
			found,
		)
	}
}

// envelope_code parses an error envelope and returns its `code`, using the
// official parser in STRICT JSON mode.
envelope_code :: proc(body: string) -> (code: string, ok: bool) {
	value, err := json.parse_string(body, json.Specification.JSON, false, context.allocator)
	if err != nil {
		return "", false
	}
	defer json.destroy_value(value, context.allocator)

	root := value.(json.Object) or_else nil
	if root == nil {
		return "", false
	}
	inner := root["error"].(json.Object) or_else nil
	if inner == nil {
		return "", false
	}
	text := inner["code"].(json.String) or_else ""
	// The parsed value dies with `value`, so hand back a copy the caller owns
	// for the duration of the comparison. Scenarios compare immediately.
	return strings.clone(string(text), context.temp_allocator), true
}

// ---------------------------------------------------------------------------
// The matrix.
//
// The fixture application both factories serve is:
//
//	GET    /ping            -> text "pong"
//	GET    /users/:id       -> path_int(id); 200 JSON {"id":N} or its 400
//	GET    /search          -> query "q" (present) and query_int_or "limit" 20
//	POST   /users           -> body-bound JSON echo (201)
//	PUT    /users/:id       -> 204
//	PATCH  /users/:id       -> 204
//	DELETE /users/:id       -> 204
//	GET    /silent          -> handler that responds with nothing
// ---------------------------------------------------------------------------

// The table is a PACKAGE-LEVEL variable, not a local. A slice of a local array
// literal would dangle the moment the accessor returned — the compound literal
// lives on the stack — which segfaults as soon as a scenario is read.
@(private)
scenarios_storage := []Scenario{
		// --- routing -------------------------------------------------------
		{
			name = "static GET is 200",
			request = {method = "GET", path = "/ping"},
			expect_status = 200,
			expect_body = "pong",
			expect_headers = {{"content-type", "text/plain; charset=utf-8"}},
		},
		{
			name = "valid :param is extracted",
			request = {method = "GET", path = "/users/42"},
			expect_status = 200,
			expect_body = `{"id":42}`,
			expect_headers = {{"content-type", "application/json"}},
		},
		{
			name = "invalid path_int is a 400 envelope",
			request = {method = "GET", path = "/users/banana"},
			expect_status = 400,
			expect_code = "invalid_path_parameter",
		},
		{
			name = "unknown route is 404",
			request = {method = "GET", path = "/nope"},
			expect_status = 404,
			expect_code = "not_found",
		},
		{
			name = "known path under another method is 405 with Allow",
			request = {method = "POST", path = "/ping"},
			expect_status = 405,
			expect_code = "method_not_allowed",
			// AUDIT R8: `/ping` is registered under GET alone, and the server
			// also answers HEAD and OPTIONS on it — so `Allow` names all three.
			// This case runs on BOTH transports from one table, which is the
			// property the matrix exists for: the in-memory transport and the
			// socket must agree byte for byte about this header.
			expect_headers = {{"allow", "GET, HEAD, OPTIONS"}},
		},

		// --- query ---------------------------------------------------------
		{
			name = "query present is read",
			request = {method = "GET", path = "/search", query = "q=odin&limit=5"},
			expect_status = 200,
			expect_body = `{"q":"odin","limit":5}`,
		},
		{
			name = "query absent uses the default",
			request = {method = "GET", path = "/search", query = "q=odin"},
			expect_status = 200,
			expect_body = `{"q":"odin","limit":20}`,
		},
		{
			name = "malformed query is a 400, never the default",
			request = {method = "GET", path = "/search", query = "q=odin&limit=banana"},
			expect_status = 400,
			expect_code = "invalid_query_parameter",
		},

		// --- methods -------------------------------------------------------
		{
			name = "PUT is isolated",
			request = {method = "PUT", path = "/users/1"},
			expect_status = 204,
		},
		{
			name = "PATCH is isolated",
			request = {method = "PATCH", path = "/users/1"},
			expect_status = 204,
		},
		{
			name = "DELETE is isolated",
			request = {method = "DELETE", path = "/users/1"},
			expect_status = 204,
		},
		{
			// WP9 D7: a valid but non-Phase-1 method must reach the CORE as
			// .UNKNOWN and follow the ratified dispatch policy — never a 501
			// invented by the backend.
			name = "unknown method reaches the core and follows 404/405",
			request = {method = "PROPFIND", path = "/ping"},
			expect_status = 405,
			expect_code = "method_not_allowed",
		},
		{
			name = "unknown method on an unknown path is 404",
			request = {method = "PROPFIND", path = "/nope"},
			expect_status = 404,
			expect_code = "not_found",
		},
		{
			// SUPERSEDED BY WP32a, owner decision 2026-07-20
			// (`planning/phase-3-spec.md` §2).
			//
			// This scenario used to assert `405` under the heading "HEAD is not
			// silently converted to GET (WP9 D7)". That expectation was Phase 1's
			// and it has been deliberately reversed, not accidentally broken:
			// C-1 records HEAD as effectively mandatory, and mapping it to
			// `.UNKNOWN` meant health checkers, proxies and monitoring systems
			// got a 405 from every Druse application.
			//
			// HEAD now matches as GET with the body suppressed at commit. The
			// row stays in the conformance matrix because the property is
			// exactly the kind that must hold identically on BOTH transports.
			name = "HEAD is answered as GET",
			request = {method = "HEAD", path = "/ping"},
			expect_status = 200,
		},
		{
			// SUPERSEDED BY WP32a, same decision. Previously "OPTIONS gains no
			// early public behavior", expecting 405.
			//
			// OPTIONS is now answered `204` with the `Allow` header the 405
			// already builds — the same machinery, not a second one. A path
			// matching no route still falls through to the ordinary miss, so a
			// path that does not exist does not acquire an options list.
			name = "OPTIONS is answered from the Allow machinery",
			request = {method = "OPTIONS", path = "/ping"},
			expect_status = 204,
		},

		// --- body ----------------------------------------------------------
		{
			name = "valid JSON body binds",
			request = {
				method = "POST",
				path = "/users",
				headers = {{"content-type", "application/json"}},
				body = transmute([]u8)string(`{"name":"grace"}`),
			},
			expect_status = 201,
			expect_body = `{"name":"grace"}`,
		},
		{
			name = "empty body is invalid JSON for a binding handler",
			request = {method = "POST", path = "/users"},
			expect_status = 400,
			expect_code = "invalid_json",
		},
		{
			name = "malformed JSON body is a 400",
			request = {
				method = "POST",
				path = "/users",
				body = transmute([]u8)string(`{"name":`),
			},
			expect_status = 400,
			expect_code = "invalid_json",
		},

		// --- responses -----------------------------------------------------
		{
			// WP8 D5: a handler that returns without responding is a logged 500
			// in BOTH drivers. HTTP has no zero status.
			name = "handler that does not respond is a 500",
			request = {method = "GET", path = "/silent"},
			expect_status = 500,
			expect_code = "internal_error",
		},
		{
			// ADR-008: the first response wins; the later ones are no-ops.
			name = "double responder keeps the first response",
			request = {method = "GET", path = "/twice"},
			expect_status = 200,
			expect_body = `{"first":true}`,
		},
}

semantic_scenarios :: proc() -> []Scenario {
	return scenarios_storage
}
