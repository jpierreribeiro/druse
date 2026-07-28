// WP-6.5.3 — `is_draining`, the one readable bit of the lifecycle.
//
// A pure in-memory test: `stop` sets the drain bit even with no server running
// (the transport request is a no-op then, but the framework's own bit still
// flips), so the readiness contract can be proved without a socket. The socket
// side of shutdown is the rest of this package.
//
// "THE TRANSPORT REQUEST IS A NO-OP THEN" IS TRUE ONLY OF THIS PROCESS WHEN NO
// SERVER IS RUNNING — AND UNDER THE PARALLEL RUNNER ONE IS.
//
// `web.stop` sets its App's drain bit and then calls
// `transport.request_stop()`, which shuts down the process-global server
// without consulting the App it was handed. So the two `stop` calls below are
// a no-op only while this test has the process to itself. Run in parallel with
// `wp58_drain_anatomy`, they shut down the server that test is measuring, and
// its eight keep-alive dials find nothing: "expected held to be 8, got 0",
// measured 3 times in 15 runs on a 4-vCPU host, 0 in 15 once serialized.
//
// This package therefore runs with `-define:ODIN_TEST_THREADS=1`, pinned in
// build/check.sh and asserted in build/check_test.sh. It is the same
// one-server-per-process rule tests/c03-fault-campaign carries — and the same
// defect that campaign first mistook for an environment problem.
package wp58_drain

import "core:testing"
import web "uruquim:web"

@(test)
wp65_is_draining_is_false_until_stop :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)

	// Before stop: a fresh application is ready, not draining.
	testing.expect(t, !web.is_draining(&app), "a fresh app must not report draining")

	web.stop(&app)

	// After stop: draining, so a readiness handler answers not-ready.
	testing.expect(t, web.is_draining(&app), "after stop the app must report draining")

	// Idempotent: a second stop does not change the answer, and never flips back.
	web.stop(&app)
	testing.expect(t, web.is_draining(&app), "draining must never return to false")
}
