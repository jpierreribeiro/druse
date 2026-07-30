// NEGATIVE COMPILE PROBE — MUST FAIL TO COMPILE.
//
// `Header_Pair` is the internal representation of a header. It is not part of
// the public API and must stay unnameable from outside the package, so the
// pair layout never becomes something applications can depend on.
//
// Expected diagnostic: 'Header_Pair' is not exported by 'web'
package wp2_probe_header_pair

import web "druse:web"

probe :: proc() {
	p: web.Header_Pair
	_ = p
}
