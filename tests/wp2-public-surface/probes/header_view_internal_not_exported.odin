// NEGATIVE COMPILE PROBE — MUST FAIL TO COMPILE.
//
// `Header_View_Internal` is the nested slot that keeps `Header_View` free of
// any promise about its representation. Naming it from outside must fail.
//
// Expected diagnostic: 'Header_View_Internal' is not exported by 'web'
package wp2_probe_header_view_internal

import web "druse:web"

probe :: proc() {
	v: web.Header_View_Internal
	_ = v
}
