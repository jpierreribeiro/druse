// WP118 — proves multishot accept: ONE accept SQE, armed once, accepts MANY
// connections (a CQE + new fd each, F_MORE while armed). This is what lets a
// dedicated accept path (WP119) serve every lane without a per-connection
// accept re-arm — and take accept off the handler lanes entirely.
package test_wp118

import "core:testing"
import "core:sys/linux"
import uring "core:sys/linux/uring"
import br "uruquim:vendor/uring_buf_ring"

@(test)
multishot_accept_one_sqe_many_conns :: proc(t: ^testing.T) {
	ring: uring.Ring
	params := uring.DEFAULT_PARAMS
	if err := uring.init(&ring, &params, 16); err != nil {
		testing.fail_now(t, "uring init failed")
	}
	defer uring.destroy(&ring)

	// A listening TCP socket on 127.0.0.1:<ephemeral>.
	lsock, serr := linux.socket(.INET, .STREAM, {}, .TCP)
	if serr != nil {
		testing.fail_now(t, "socket failed")
	}
	defer linux.close(lsock)

	addr := linux.Sock_Addr_In{sin_family = .INET, sin_port = 0, sin_addr = {127, 0, 0, 1}}
	if err := linux.bind(lsock, &addr); err != nil {
		testing.fail_now(t, "bind failed")
	}
	if err := linux.listen(lsock, 16); err != nil {
		testing.fail_now(t, "listen failed")
	}
	// Read back the ephemeral port.
	bound: linux.Sock_Addr_Any
	if err := linux.getsockname(lsock, &bound); err != nil {
		testing.fail_now(t, "getsockname failed")
	}

	// ONE multishot accept SQE, armed once.
	sqe, ok := uring.get_sqe(&ring)
	testing.expect(t, ok, "get_sqe")
	br.prep_accept_multishot(sqe, lsock, 55)
	if _, err := uring.submit(&ring, 0); err != nil {
		testing.fail_now(t, "submit failed")
	}

	NCONN :: 3
	clients: [NCONN]linux.Fd
	got_more := 0
	for i in 0 ..< NCONN {
		// A client connects. The armed multishot accept picks it up.
		c, cerr := linux.socket(.INET, .STREAM, {}, .TCP)
		if cerr != nil {
			testing.fail_now(t, "client socket failed")
		}
		clients[i] = c
		caddr := linux.Sock_Addr_In{sin_family = .INET, sin_port = bound.sin_port, sin_addr = {127, 0, 0, 1}}
		if err := linux.connect(c, &caddr); err != nil {
			testing.fail_now(t, "connect failed")
		}

		cqes: [4]linux.IO_Uring_CQE
		n, qerr := uring.copy_cqes(&ring, cqes[:], 1)
		if qerr != nil || n < 1 {
			testing.fail_now(t, "copy_cqes failed")
		}
		cqe := cqes[0]
		testing.expect_value(t, cqe.user_data, u64(55)) // same SQE every time
		testing.expect(t, cqe.res >= 0, "accepted fd (res >= 0)")
		if cqe.res >= 0 {
			linux.close(linux.Fd(cqe.res)) // close the accepted server-side fd
		}
		if br.has_more(cqe.flags) {
			got_more += 1
		}
	}
	for c in clients {
		linux.close(c)
	}

	// One SQE served all three connections (F_MORE kept it armed) — the defining
	// multishot-accept property that WP119 relies on.
	testing.expect(t, got_more >= NCONN - 1, "multishot accept stayed armed (F_MORE)")
}
