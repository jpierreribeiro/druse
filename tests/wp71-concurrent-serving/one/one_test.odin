package wp71_one

import "core:testing"
import "core:time"
import lab "druse:tests/support/web_blocking_lab"

@(test)
one_is_an_explicit_single_handler_compatibility_mode :: proc(t: ^testing.T) {
	s: lab.Server
	blocked, health: lab.Call
	defer {
		lab.Stop(&s)
		lab.Join_Call(&blocked)
		lab.Join_Call(&health)
	}
	testing.expect(t, lab.Start(&s, 51072, 1), "one-handler server must start")
	lab.Start_Call(&blocked, s.port, "/block")
	testing.expect(t, lab.Wait_Entered(&s))
	lab.Start_Call(&health, s.port, "/health")
	testing.expect(t, !lab.Wait_Call(&health, lab.Observation_Window), "one blocked Handler must expose the compatibility boundary")
	lab.Release(&s, 1)
	testing.expect(t, lab.Wait_Call(&blocked, 2 * time.Second))
	testing.expect(t, lab.Wait_Call(&health, 2 * time.Second), "health must recover after the Handler returns")
}
