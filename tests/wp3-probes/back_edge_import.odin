// PROBE C5 FIXTURE — must turn the one-way dependency into a compile cycle.
//
// This file is NOT part of any compiled package on its own. build/check.sh
// copies `web/` and `web/testing/` into a throwaway directory, drops THIS file
// into the copied `web/testing/`, and runs `odin check` on the copied `web`.
// Because `web` imports `web/testing`, adding the back-edge below must make the
// compiler reject the build with `Cyclic importation of 'web_testing'` (the
// machinery's declared package name; the facade's import alias is `testing`).
//
// It is the committed, executable form of WP3 evidence item C5: the
// unidirectional rule `web -> web/testing` is enforced by the language, not
// merely preferred. Keeping the fixture versioned means the guarantee is
// re-proved on every gate run, not cited from an external scratch prototype.
package web_testing

import _ "druse:web"
