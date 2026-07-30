package wp69_repeatability

import "core:testing"
import lab "druse:tests/support/blocking_lab"

@(test)
startup_and_teardown_are_repeatable :: proc(t: ^testing.T) {
	for cycle in 0 ..< 5 {
		s: lab.Server
		testing.expect(t, lab.Start(&s, 50973 + cycle, 4))
		status, _, ok := lab.Request(s.port, "/health")
		testing.expect(t, ok && status == 200)
		lab.Stop(&s)
	}
}
