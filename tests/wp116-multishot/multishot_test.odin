// WP116 — proves multishot recv: ONE recv SQE, armed once, delivers MANY messages
// (a CQE each, each selecting a buffer from our ring), with IORING_CQE_F_MORE set
// while it stays armed. This is what eliminates the per-request recv syscall.
package test_wp116

import "core:testing"
import "core:sys/linux"
import uring "core:sys/linux/uring"
import br "uruquim:vendor/uring_buf_ring"

@(test)
multishot_recv_one_sqe_many_cqes :: proc(t: ^testing.T) {
	ring: uring.Ring
	params := uring.DEFAULT_PARAMS
	if err := uring.init(&ring, &params, 16); err != nil {
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
	BGID :: 7
	storage: [NBUF][BUFSZ]u8

	buf_ring: br.Ring
	if err := br.setup(&buf_ring, ring.fd, BGID, NBUF); err != nil {
		testing.fail_now(t, "buf_ring setup failed")
	}
	defer br.release(&buf_ring)
	for i in 0 ..< NBUF {
		br.add(&buf_ring, storage[i][:], u16(i), u16(i))
	}
	br.advance(&buf_ring, NBUF)

	// ONE multishot recv SQE, armed once.
	sqe, ok := uring.get_sqe(&ring)
	testing.expect(t, ok, "get_sqe")
	br.prep_recv_multishot(sqe, pair[0], BGID, 99)
	if _, err := uring.submit(&ring, 0); err != nil {
		testing.fail_now(t, "submit failed")
	}

	msgs := [?]string{"one", "two", "three"}
	got_more_count := 0
	for want, idx in msgs {
		if _, err := linux.write(pair[1], transmute([]u8)want); err != nil {
			testing.fail_now(t, "write failed")
		}
		cqes: [4]linux.IO_Uring_CQE
		n, cerr := uring.copy_cqes(&ring, cqes[:], 1)
		if cerr != nil || n < 1 {
			testing.fail_now(t, "copy_cqes failed")
		}
		cqe := cqes[0]
		testing.expect_value(t, cqe.user_data, u64(99)) // same SQE every time
		testing.expect_value(t, cqe.res, i32(len(want)))
		testing.expect(t, br.has_buffer(cqe.flags), "kernel selected a provided buffer")
		bid := br.buffer_id(cqe.flags)
		testing.expect(t, int(bid) < NBUF, "buffer id in range")
		testing.expect_value(t, string(storage[bid][:len(want)]), want)
		// Recycle the buffer so the ring never starves across the three arrivals.
		br.recycle(&buf_ring, storage[bid][:], bid)
		if br.has_more(cqe.flags) {
			got_more_count += 1
		}
		_ = idx
	}

	// The op stayed armed across the first arrivals (F_MORE): a single SQE served
	// all three messages — the defining multishot property.
	testing.expect(t, got_more_count >= len(msgs) - 1, "multishot stayed armed (F_MORE) across arrivals")
}
