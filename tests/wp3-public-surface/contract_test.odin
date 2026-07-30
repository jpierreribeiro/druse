// WP3 public-surface contract, from OUTSIDE the package (probe C4).
//
// This package is an EXTERNAL consumer of `druse:web`. It proves that the two
// symbols WP3 adds — `test_request` and `Recorded_Response` — exist with the
// exact ratified names, are actually exported by package `web` (not
// `web/testing`), and compose as the ratified WP3 contract specifies.
//
// It also RUNS `web.test_request`, which is the executable half of probe C4:
// the call completes with no socket, no port, and no network syscall, and its
// result is readable as `res.status` / `res.body`.
//
// WP3's own contract is the in-memory ROUND TRIP and the response LIFETIME: the
// facade returns whatever the internal response holds, and it must NOT fabricate
// a 200 or echo the path. That contract is unchanged by WP4 and is still
// asserted below.
//
// AMENDED IN WP4. WP4 wired dispatch, so `web.app()` now installs the automatic
// 404/405 and an unmatched path is a real routed 404 — the WP4 tests own that.
// The two round-trip tests below therefore use `web.bare()`, which routes but
// installs no automatic response (D4), so the CORE still commits nothing for an
// unmatched path — keeping these tests distinct from the WP4 404 tests.
//
// AMENDED IN WP8. HTTP cannot send a zero status, so the response DRIVER
// finalizes an uncommitted response to a logged 500 (WP8 D5) — in
// `test_request` exactly as in the real transport. The round trip, the
// no-fabricated-200 rule and the response LIFETIME (both readable until
// `destroy`) are what WP3 ratified and are all still asserted; only the
// observed status/body of an uncommitted response changed.
//
// The matching NEGATIVE contract — that `Recorded_Response` has no public
// `headers` field — cannot be written here, since it must fail to compile. It
// lives in `probes/`, driven by build/check.sh.
package wp3_public_surface

import "core:log"
import "core:strings"
import "core:testing"
import web "druse:web"

// Wp3_Log_Filter drops the framework's own Error-level diagnostics (they begin
// with "druse:") and forwards everything else. `odin test` counts any Error
// record as a failure, so a test that deliberately drives a bare() miss — which
// the WP8 driver finalizes to a logged 500 — installs this to keep the runner
// honest without hiding real failures. Declared on the caller's stack, so it
// allocates nothing.
Wp3_Log_Filter :: struct {
	inner: log.Logger,
}

wp3_filter_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	filter := (^Wp3_Log_Filter)(data)
	if level == .Error && strings.contains(text, "druse:") {
		return
	}
	if filter.inner.procedure != nil {
		filter.inner.procedure(filter.inner.data, level, text, options, location)
	}
}

wp3_swallow_framework_log :: proc(filter: ^Wp3_Log_Filter) -> log.Logger {
	filter.inner = context.logger
	return log.Logger {
		procedure = wp3_filter_proc,
		data = rawptr(filter),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

// --- Recorded_Response: exact public field set ---

@(test)
wp3_recorded_response_exposes_status_and_body :: proc(t: ^testing.T) {
	// Named assignment proves each field exists with the ratified name and
	// type, and that there are only these two.
	r: web.Recorded_Response
	r.status = .OK
	r.body = "hi"

	testing.expect_value(t, r.status, web.Status.OK)
	testing.expect_value(t, r.body, "hi")
}

// --- test_request: exists, is exported by `web`, runs without a socket ---

@(test)
wp3_test_request_runs_in_memory_without_routing :: proc(t: ^testing.T) {
	app := web.bare()
	defer web.destroy(&app)

	filter: Wp3_Log_Filter
	context.logger = wp3_swallow_framework_log(&filter)

	res := web.test_request(&app, .GET, "/users/42")

	// No route is registered and `bare()` installs no automatic response, so the
	// core leaves the response uncommitted (NOT a fabricated 200 and NOT the
	// echoed path). AMENDED IN WP8: HTTP cannot send a zero status, so the DRIVER
	// finalizes an uncommitted response to a 500 — the same in `test_request` and
	// the real transport (WP8 D5). `bare()`'s no-policy at the core is unchanged.
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
	testing.expect_value(
		t,
		res.body,
		`{"error":{"code":"internal_error","message":"Internal server error"}}`,
	)
}

// --- two consecutive recorded responses remain readable until destroy ---

@(test)
wp3_two_recorded_responses_survive_until_destroy :: proc(t: ^testing.T) {
	app := web.bare()
	defer web.destroy(&app)

	filter: Wp3_Log_Filter
	context.logger = wp3_swallow_framework_log(&filter)

	first := web.test_request(&app, .GET, "/a")
	second := web.test_request(&app, .POST, "/bb")

	// Both remain readable after the second call — neither aliases a buffer the
	// other reused. AMENDED IN WP8: both bare misses are finalized to a 500 by
	// the driver (WP8 D5); the point of THIS test — that two recorded responses
	// survive independently — is unchanged.
	envelope :: `{"error":{"code":"internal_error","message":"Internal server error"}}`
	testing.expect_value(t, first.body, envelope)
	testing.expect_value(t, second.body, envelope)
	testing.expect_value(t, first.status, web.Status.Internal_Server_Error)
	testing.expect_value(t, second.status, web.Status.Internal_Server_Error)
}

// --- an app that never calls test_request destroys cleanly (lazy state) ---

@(test)
wp3_unused_test_support_is_a_noop_destroy :: proc(t: ^testing.T) {
	// This is the ergonomic proof of the lazy state: constructing and
	// destroying an App that never touches test_request must be inert. The
	// memory-tracking harness (build/check.sh runs `odin test` with tracking)
	// would flag any allocation this path made.
	app := web.app()
	web.destroy(&app)

	bare := web.bare()
	web.destroy(&bare)
}
