// NEGATIVE PROBE — dropping the `ok` of `web.query_int` must NOT compile.
//
// See `discard_path_int_ok.odin` for the full rationale. `query_int` responds
// with `invalid_query_parameter` on failure, so a dropped `ok` would leave the
// handler running after a 400 was already committed.
package wp5_probe_discard_query_int

import web "druse:web"

main :: proc() {
	ctx: web.Context

	// EXPECTED: Assignment count mismatch '1' = '2'
	page := web.query_int(&ctx, "page")
	_ = page
}
