// NEGATIVE COMPILE PROBE — MUST FAIL TO COMPILE.
//
// There is no public `ctx.response`. Applications respond exclusively through
// web.json / web.ok / web.created / web.text / web.no_content and the error
// helpers; the response object and its commit state are framework-internal
// (ADR-008).
//
// Expected diagnostic: 'ctx' of type '^Context' has no field 'response'
package wp2_probe_context_response

import web "druse:web"

probe :: proc(ctx: ^web.Context) {
	ctx.response = {}
}
