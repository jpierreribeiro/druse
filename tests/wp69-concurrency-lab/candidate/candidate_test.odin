package wp69_candidate

import "core:testing"
import "core:time"
import lab "druse:tests/support/blocking_lab"

@(test)
four_lanes_keep_health_live_with_three_blocked_handlers :: proc(t: ^testing.T) {
	s: lab.Server
	blocked: [3]lab.Call
	health: lab.Call
	defer {
		lab.Stop(&s)
		for &call in blocked {lab.Join_Call(&call)}
		lab.Join_Call(&health)
	}
	testing.expect(t, lab.Start(&s, 50970, 4), "four-lane server must start")

	_, baseline, baseline_ok := lab.Request(s.port, "/health")
	testing.expect(t, baseline_ok && baseline < lab.Baseline_Ceiling, "baseline must be interpretable")
	for &call in blocked {
		lab.Start_Call(&call, s.port, "/block")
		testing.expect(t, lab.Wait_Entered(&s), "each blocked call must occupy a lane")
	}
	lab.Start_Call(&health, s.port, "/health")
	testing.expect(t, lab.Wait_Call(&health, lab.Observation_Window), "health must finish before release")
	testing.expect(t, health.ok && health.status == 200)

	lab.Release(&s, len(blocked))
	for &call in blocked {testing.expect(t, lab.Wait_Call(&call, 2 * time.Second))}
}
