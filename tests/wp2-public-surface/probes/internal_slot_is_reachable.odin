// POSITIVE COMPILE PROBE — MUST COMPILE (exit 0).
//
// This probe records an ACCEPTED FACT, not a feature: `Header_View` is
// encapsulated BY CONTRACT, not opaque. Odin's `@(private)` hides a
// declaration's NAME, not the reachability of fields through a public field,
// and per-field privacy is a syntax error. So `r.headers.private.pairs`
// compiles from outside the package even though `Header_Pair` cannot be named.
//
// This is deliberate and ratified (ADR-008, "Scope of the guarantee"). It is
// not a supported path, nothing promises the
// representation will stay as it is, and no framework guarantee rests on it.
// The probe exists so the claim in the documentation stays honest: if this
// ever stopped compiling, the docs would be describing a barrier that Odin
// does not provide.
package wp2_probe_internal_slot

import web "druse:web"

probe :: proc(r: web.Request) -> int {
	return len(r.headers.private.pairs)
}
