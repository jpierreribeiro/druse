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

// prep_accept_multishot fills `sqe` as a multishot accept on listen socket `fd`.
// One SQE stays armed and posts a CQE per incoming connection (the new fd in
// `cqe.res`, F_MORE set while armed) — no per-connection accept re-arm, and the
// basis for taking accept off the handler lanes entirely (WP119). We pass no
// sockaddr out (addr/off zero): the peer address, when needed, comes from the
// connection later. Re-arm on a completion WITHOUT F_MORE.
prep_accept_multishot :: proc "contextless" (sqe: ^linux.IO_Uring_SQE, fd: linux.Fd, user_data: u64) {
	sqe.opcode = .ACCEPT
	sqe.fd = fd
	sqe.addr = 0 // no sockaddr out
	sqe.off = 0  // no addr_len out
	sqe.sq_accept_flags = {.MULTISHOT}
	sqe.user_data = user_data
}

// AUDIT T6 — MOVED HERE FROM `buf_ring.odin`, WHICH WAS DELETED.
//
// It is a pure CQE-flag predicate with nothing to do with the provided-buffer
// ring it used to live beside, and it is what an accept-multishot consumer
// needs to know whether the SQE is still armed. Keeping it costs two lines;
// losing it would have taken `tests/wp118-accept-multishot` with it, and that
// suite is the evidence for T7 — the multishot change this project actually
// indicated — rather than part of the recv machinery T6 condemned.
// has_more reports whether the parent (multishot) SQE will generate more CQEs
// (IORING_CQE_F_MORE). When false, a multishot op has terminated and must be
// re-armed.
has_more :: proc "contextless" (cqe_flags: linux.IO_Uring_CQE_Flags) -> bool {
	return .MORE in cqe_flags
}
