package wp69_saturation

import "core:testing"
import "core:time"
import lab "druse:tests/support/blocking_lab"

@(test)
full_lane_saturation_is_the_explicit_boundary :: proc(t: ^testing.T) {
	s: lab.Server
	blocked: [4]lab.Call
	health: lab.Call
	defer {
		lab.Stop(&s)
		for &call in blocked {lab.Join_Call(&call)}
		lab.Join_Call(&health)
	}
	testing.expect(t, lab.Start(&s, 50971, 4))
	for &call in blocked {
		lab.Start_Call(&call, s.port, "/block")
		testing.expect(t, lab.Wait_Entered(&s))
	}
	lab.Start_Call(&health, s.port, "/health")
	testing.expect(t, !lab.Wait_Call(&health, lab.Observation_Window), "full saturation must be visible")
	lab.Release(&s, len(blocked))
	for &call in blocked {testing.expect(t, lab.Wait_Call(&call, 2 * time.Second))}
	testing.expect(t, lab.Wait_Call(&health, 2 * time.Second), "health must recover after release")
}
