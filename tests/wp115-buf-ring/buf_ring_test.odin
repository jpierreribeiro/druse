// WP115 — proves the provided-buffer ring end to end against a real kernel:
// register a buffer group, issue ONE buffer-select recv, write to the socket, and
// confirm the kernel picked a buffer from OUR ring, reported its id in the CQE,
// and delivered the bytes into it. This is the base multishot recv (WP116) builds
// on; if the kernel doesn't select from the ring, nothing above works.
package test_wp115

import "core:testing"
import "core:sys/linux"
import uring "core:sys/linux/uring"
import br "uruquim:vendor/uring_buf_ring"

@(test)
buf_ring_selects_and_delivers :: proc(t: ^testing.T) {
	ring: uring.Ring
	params := uring.DEFAULT_PARAMS
	if err := uring.init(&ring, &params, 8); err != nil {
		testing.fail_now(t, "uring init failed")
	}
	defer uring.destroy(&ring)

	pair: [2]linux.Fd
	if err := linux.socketpair(.UNIX, .STREAM, .HOPOPT, &pair); err != nil {
		testing.fail_now(t, "socketpair failed")
	}
	defer linux.close(pair[0])
	defer linux.close(pair[1])

	NBUF :: 8
	BUFSZ :: 64
	BGID :: 1
	storage: [NBUF][BUFSZ]u8

	buf_ring: br.Ring
	if err := br.setup(&buf_ring, ring.fd, BGID, NBUF); err != nil {
		testing.fail_now(t, "buf_ring setup failed")
	}
	defer br.release(&buf_ring)

	// Stage all NBUF buffers, then publish them in one advance.
	for i in 0 ..< NBUF {
		br.add(&buf_ring, storage[i][:], u16(i), u16(i))
	}
	br.advance(&buf_ring, NBUF)

	// A recv with BUFFER_SELECT: the kernel picks a buffer from group BGID.
	sqe, ok := uring.get_sqe(&ring)
	testing.expect(t, ok, "get_sqe")
	sqe.opcode = .RECV
	sqe.fd = pair[0]
	sqe.len = BUFSZ
	sqe.msg_flags = {}
	sqe.flags = {.BUFFER_SELECT}
	sqe.buf_group = BGID
	sqe.user_data = 42

	if _, err := uring.submit(&ring, 0); err != nil {
		testing.fail_now(t, "submit failed")
	}

	msg := "hello"
	if _, err := linux.write(pair[1], transmute([]u8)msg); err != nil {
		testing.fail_now(t, "write failed")
	}

	cqes: [4]linux.IO_Uring_CQE
	n, cerr := uring.copy_cqes(&ring, cqes[:], 1)
	if cerr != nil || n < 1 {
		testing.fail_now(t, "copy_cqes failed")
	}

	cqe := cqes[0]
	testing.expect_value(t, cqe.user_data, u64(42))
	testing.expect_value(t, cqe.res, i32(5)) // "hello"
	testing.expect(t, br.has_buffer(cqe.flags), "kernel selected a provided buffer (F_BUFFER)")

	bid := br.buffer_id(cqe.flags)
	testing.expect(t, int(bid) < NBUF, "buffer id in range")
	got := string(storage[bid][:5])
	testing.expect_value(t, got, "hello")
}
