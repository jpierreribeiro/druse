// NEGATIVE COMPILE PROBE — MUST FAIL TO COMPILE.
//
// RE-AIMED BY WP49, NOT DELETED, and the distinction matters: a negative probe
// that is removed is a guarantee that quietly disappeared. This one enforced
// "`Recorded_Response` has no `headers` field at all" (D-14.3, Phase 1). WP49
// DECIDED that question — an application must be able to assert the headers it
// asked for without a socket — so the field exists now.
//
// What is still forbidden is the shape nobody decided: `headers` is a
// `[]string` of wire-form `"Name: value"` lines, NOT a slice of pairs and NOT a
// map. A pair type would export `Header_Pair` onto the public surface; a map
// would export a lookup contract and an allocation. Both are surface this
// project has refused since Phase 1, and neither becomes acceptable because a
// neighbouring field was ratified.
//
// So the probe now asserts the shape rather than the absence: reading a `.name`
// off an entry must fail, because an entry is a string.
//
// Expected diagnostic: cannot index/select '.name' on a value of type 'string'
package wp3_probe_recorded_headers

import web "druse:web"

probe :: proc(res: web.Recorded_Response) {
	// `headers` exists (WP49) — but its entries are STRINGS, not pairs.
	_ = res.headers[0].name
}
