package wp71_vendor_suspend

import "core:testing"
import "core:time"
import lab "uruquim:tests/support/blocking_lab"

@(test)
blocked_handler_lane_never_owns_the_dedicated_accept :: proc(t: ^testing.T) {
	s: lab.Server
	blocked: lab.Call
	defer {
		lab.Stop(&s)
		lab.Join_Call(&blocked)
	}

	testing.expect(t, lab.Start_Suspended(&s, 51073, 2))
	lab.Start_Call(&blocked, s.port, "/block")
	testing.expect(t, lab.Wait_Entered(&s))

	active, active_with_accept, dedicated_accept_active := lab.Suspended_Lane_State(&s)
	testing.expect_value(t, active, 1)
	testing.expect_value(t, active_with_accept, 0)
	testing.expect(t, dedicated_accept_active, "the dedicated acceptor must remain armed while another lane is free")

	lab.Release(&s, 1)
	testing.expect(t, lab.Wait_Call(&blocked, 2 * time.Second))
	status, _, ok := lab.Request(s.port, "/health")
	testing.expect(t, ok && status == 200, "dedicated admission must remain healthy after Handler return")
}
