// WP116 — multishot recv over a provided-buffer ring. One recv SQE stays armed
// and posts a CQE per data arrival (IORING_CQE_F_MORE set while it lives), the
// kernel picking a buffer from the group for each. This is the recv path's CPU
// win: no per-request recv syscall, no per-request buffer setup.
//
// This file provides the SQE preparation; the caller owns the ring (WP115) and
// the completion loop. WP117 wires it into odin-http's scanner; a future nbio
// integration can wrap it in an Operation.

package uring_buf_ring

import "core:sys/linux"

// prep_recv_multishot fills `sqe` as a multishot recv against buffer group
// `bgid`. `addr`/`len` are left zero: with BUFFER_SELECT + RECV_MULTISHOT the
// kernel chooses a buffer from the group per completion, so the SQE names no
// buffer of its own. The op stays armed (posting more CQEs) until it errors, the
// ring is exhausted (ENOBUFS), or it is cancelled; re-arm when a completion
// arrives WITHOUT IORING_CQE_F_MORE.
prep_recv_multishot :: proc "contextless" (sqe: ^linux.IO_Uring_SQE, fd: linux.Fd, bgid: u16, user_data: u64) {
	sqe.opcode = .RECV
	sqe.fd = fd
	sqe.addr = 0
	sqe.len = 0
	sqe.msg_flags = {}
	sqe.flags = {.BUFFER_SELECT}
	sqe.buf_group = bgid
	// IORING_RECV_MULTISHOT lives in the ioprio union (bit 1), not msg_flags.
	sqe.sq_send_recv_flags = {.RECV_MULTISHOT}
	sqe.user_data = user_data
}
