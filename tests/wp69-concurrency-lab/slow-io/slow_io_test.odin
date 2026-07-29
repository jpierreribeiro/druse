package wp69_slow_io

import "core:net"
import "core:testing"
import "core:time"
import lab "druse:tests/support/blocking_lab"

@(test)
idle_partial_and_slow_write_remain_non_blocking_io :: proc(t: ^testing.T) {
	s: lab.Server
	testing.expect(t, lab.Start(&s, 50972, 1))
	defer lab.Stop(&s)

	idle, idle_ok := lab.Open_Idle(s.port)
	defer if idle_ok {net.close(idle)}
	partial, partial_ok := lab.Open_Slow_Reader(s.port)
	defer if partial_ok {net.close(partial)}
	slow_write, write_ok := lab.Open_Slow_Writer(s.port)
	defer if write_ok {net.close(slow_write)}
	testing.expect(t, idle_ok && partial_ok && write_ok)
	time.sleep(50 * time.Millisecond)

	status, elapsed, ok := lab.Request(s.port, "/health")
	testing.expect(t, ok && status == 200)
	testing.expect(t, elapsed < lab.Observation_Window, "pending non-blocking I/O must preserve progress")
}
