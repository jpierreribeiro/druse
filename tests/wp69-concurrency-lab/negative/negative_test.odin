package wp69_negative

import "core:testing"
import "core:time"
import lab "druse:tests/support/blocking_lab"

@(test)
one_lane_is_the_required_negative_control :: proc(t: ^testing.T) {
	s: lab.Server
	blocked: lab.Call
	health: lab.Call
	defer {
		lab.Stop(&s)
		lab.Join_Call(&blocked)
		lab.Join_Call(&health)
	}
	testing.expect(t, lab.Start(&s, 50969, 1))
	_, baseline, ok := lab.Request(s.port, "/health")
	testing.expect(t, ok && baseline < lab.Baseline_Ceiling)
	lab.Start_Call(&blocked, s.port, "/block")
	testing.expect(t, lab.Wait_Entered(&s))
	lab.Start_Call(&health, s.port, "/health")
	testing.expect(t, !lab.Wait_Call(&health, lab.Observation_Window), "one lane must lose progress")
	lab.Release(&s, 1)
	testing.expect(t, lab.Wait_Call(&blocked, 2 * time.Second))
	testing.expect(t, lab.Wait_Call(&health, 2 * time.Second))
}
