package wp71_admission

import "core:net"
import "core:testing"
import "core:time"
import lab "druse:tests/support/web_blocking_lab"

@(test)
connection_budget_is_server_wide_not_multiplied_by_handler_lanes :: proc(t: ^testing.T) {
	s: lab.Server
	held: [4]net.TCP_Socket
	held_count := 0
	defer {
		for i in 0 ..< held_count {net.close(held[i])}
		lab.Stop(&s)
	}

	testing.expect(t, lab.Start_With_Admission(&s, 51075, 4, 6, 2))
	// Startup readiness uses one short-lived connection; wait past the backend's
	// staged close so only the four sockets below occupy the global budget.
	time.sleep(600 * time.Millisecond)
	for _ in 0 ..< len(held) {
		sock, ok := lab.Open_Idle(s.port)
		testing.expect(t, ok)
		if !ok {return}
		held[held_count] = sock
		held_count += 1
		time.sleep(20 * time.Millisecond)
	}

	status, _, served := lab.Request(s.port, "/health")
	testing.expect(t, !served && status == 0, "the fifth connection must be refused while two slots remain reserved")
}
