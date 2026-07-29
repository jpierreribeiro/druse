// NEGATIVE PROBE — dropping the `ok` of `web.path_int` must NOT compile.
//
// ADR-002 option B: the value-producing HTTP extractors deliberately omit
// `#optional_ok`, so the pinned compiler rejects a single-result call with
// `Assignment count mismatch`. That diagnostic is the whole enforcement
// mechanism behind the canonical `if !ok { return }` form — without it, a
// handler could silently drop an error the extractor already responded to, and
// keep running as though extraction had succeeded.
//
// `build/check.sh` compiles this file and REQUIRES the failure, matching on the
// exact diagnostic so that an unrelated compile error can never be mistaken for
// proof.
package wp5_probe_discard_path_int

import web "druse:web"

main :: proc() {
	ctx: web.Context

	// EXPECTED: Assignment count mismatch '1' = '2'
	id := web.path_int(&ctx, "id")
	_ = id
}
