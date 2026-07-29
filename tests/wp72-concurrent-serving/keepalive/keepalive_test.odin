package wp72_keepalive

import "core:net"
import "core:fmt"
import "core:testing"
import "core:time"
import lab "druse:tests/support/web_blocking_lab"
import web "druse:web"

CONNECTIONS :: 3_000

@(test)
three_thousand_idle_keepalives_drain_without_use_after_free :: proc(t: ^testing.T) {
	s: lab.Server
	sockets: [CONNECTIONS]net.TCP_Socket
	opened := 0
	stopped := false
	defer {
		for i in 0 ..< opened {net.close(sockets[i])}
		if !stopped {lab.Stop(&s)}
	}

	limits := web.DEFAULT_LIMITS
	limits.max_handlers = 4
	limits.max_connections = 4_096
	limits.reserved_conns = 16
	limits.max_request_time = 0
	limits.max_drain_time = i64(3 * time.Second)
	testing.expect(t, lab.Start_With_Limits(&s, 51077, limits))

	for i in 0 ..< CONNECTIONS {
		sock, ok := lab.Open_Keepalive(s.port)
		if !ok {
			testing.expectf(t, false, "keep-alive %d of %d failed to become idle", i + 1, CONNECTIONS)
			break
		}
		sockets[opened] = sock
		opened += 1
	}
	testing.expect_value(t, opened, CONNECTIONS)
	if opened != CONNECTIONS {return}

	started := time.now()
	lab.Stop(&s)
	stopped = true
	elapsed := time.since(started)
	fmt.printf("[wp72] keepalive=%d drain=%v deadline=%v\n", opened, elapsed, time.Duration(limits.max_drain_time))
	testing.expectf(
		t,
		elapsed <= time.Duration(limits.max_drain_time) + 250 * time.Millisecond,
		"3,000 idle keep-alives must drain inside max_drain_time + 250 ms; got %v",
		elapsed,
	)
}
