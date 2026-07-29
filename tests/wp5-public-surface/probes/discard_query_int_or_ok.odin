// NEGATIVE PROBE — dropping the `ok` of `web.query_int_or` must NOT compile.
//
// This is the probe that matters most of the three. `query_int_or` looks like a
// total function — "give me the value or the default" — which is exactly why a
// caller is tempted to write `limit := web.query_int_or(ctx, "limit", 20)`. It
// is NOT total: the default applies only when the parameter is ABSENT, and a
// present-but-malformed value is a committed 400 with `ok = false`. Dropping
// the bool there would let the handler continue with `limit = 0` after the
// framework had already responded.
package wp5_probe_discard_query_int_or

import web "druse:web"

main :: proc() {
	ctx: web.Context

	// EXPECTED: Assignment count mismatch '1' = '2'
	limit := web.query_int_or(&ctx, "limit", 20)
	_ = limit
}
