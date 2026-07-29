package wp71_auto

import "core:testing"
import "core:time"
import lab "druse:tests/support/web_blocking_lab"

@(test)
four_handler_capacity_keeps_new_health_connections_off_blocked_lanes :: proc(t: ^testing.T) {
	s: lab.Server
	blocked: [3]lab.Call
	health: [3]lab.Call
	defer {
		lab.Stop(&s)
		for &call in blocked {lab.Join_Call(&call)}
		for &call in health {lab.Join_Call(&call)}
	}
	testing.expect(t, lab.Start(&s, 51071, 4), "four-Handler server must start")

	_, baseline, baseline_ok := lab.Request(s.port, "/health")
	testing.expect(t, baseline_ok && baseline < lab.Baseline_Ceiling, "loopback baseline must be interpretable")
	for i in 0 ..< len(blocked) {
		lab.Start_Call(&blocked[i], s.port, "/block")
		testing.expect(t, lab.Wait_Entered(&s), "each blocker must occupy a distinct Handler unit")
		lab.Start_Call(&health[i], s.port, "/health")
		testing.expect(t, lab.Wait_Call(&health[i], lab.Observation_Window), "health must complete before any blocker is released")
		testing.expect(t, health[i].ok && health[i].status == 200)
	}

	lab.Release(&s, len(blocked))
	for &call in blocked {testing.expect(t, lab.Wait_Call(&call, 2 * time.Second))}
}

@(test)
automatic_capacity_keeps_new_health_connections_off_three_blocked_lanes :: proc(t: ^testing.T) {
	s: lab.Server
	blocked: [3]lab.Call
	defer {
		lab.Stop(&s)
		for &call in blocked {lab.Join_Call(&call)}
	}
	testing.expect(t, lab.Start(&s, 51074, 0), "automatic Handler server must start")

	for i in 0 ..< len(blocked) {
		lab.Start_Call(&blocked[i], s.port, "/block")
		testing.expect(t, lab.Wait_Entered(&s), "automatic capacity must provide at least four Handler units")
	}
	status, elapsed, ok := lab.Request(s.port, "/health")
	testing.expect(t, ok && status == 200)
	testing.expect(t, elapsed < lab.Observation_Window, "automatic capacity must preserve independent health liveness")

	lab.Release(&s, len(blocked))
	for &call in blocked {testing.expect(t, lab.Wait_Call(&call, 2 * time.Second))}
}
