package wp69_drain

import "core:testing"
import "core:time"
import lab "druse:tests/support/blocking_lab"

@(test)
arbitrary_blocking_code_is_not_preempted_by_drain :: proc(t: ^testing.T) {
	s: lab.Server
	blocked: lab.Call
	defer {
		lab.Stop(&s)
		lab.Join_Call(&blocked)
	}
	testing.expect(t, lab.Start(&s, 50979, 4))
	lab.Start_Call(&blocked, s.port, "/block")
	testing.expect(t, lab.Wait_Entered(&s))
	lab.Request_Stop(&s)
	testing.expect(t, !lab.Wait_Stopped(&s, lab.Observation_Window), "user code is not preemptible")
	lab.Release(&s, 1)
	testing.expect(t, lab.Wait_Stopped(&s, 2 * time.Second), "stop recovers when user code returns")
	lab.Join_Server(&s)
	testing.expect(t, lab.Wait_Call(&blocked, 2 * time.Second))
}
