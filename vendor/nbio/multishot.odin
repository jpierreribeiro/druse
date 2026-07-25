package nbio

// WP117 (Phase 9) — multishot recv over a provided-buffer ring, integrated into
// nbio's Operation system. One armed SQE delivers a callback per data arrival,
// the kernel selecting a buffer from a group the CALLER owns (a
// vendor/uring_buf_ring Ring). The op stays alive while F_MORE is set and is
// recycled only when the kernel stops it — so the recv path costs no per-request
// recv syscall and no per-request buffer setup. This is the CPU lever of Phase 9.
//
// The buffer ring is owned by the caller (the odin-http scanner), one per
// connection thread, so the caller controls buffer sizing and recycling. nbio
// only submits the multishot SQE against the group id and reports, per
// completion, which buffer the kernel used and how many bytes it delivered.

// Recv_Multishot is the per-completion result the callback reads. `socket` and
// `bgid` are set at arm time; `buffer_id`/`received`/`more`/`err` are refreshed
// by the backend before each callback. No per-op timeout: a multishot op is
// persistent, and odin-http's read deadline is a periodic sweep (WP46), not a
// per-op link timeout — so none is armed here.
Recv_Multishot :: struct {
	// The socket being received from.
	socket:    Any_Socket,
	// The provided-buffer group id the kernel selects from.
	bgid:      u16,

	// --- refreshed before every callback ---
	// The buffer id the kernel chose for THIS completion (valid when received>0).
	buffer_id: u16,
	// Bytes delivered into that buffer this completion. 0 with no error = peer
	// closed (and the multishot op has ended).
	received:  int,
	// True while the op stays armed (IORING_CQE_F_MORE). When false, the op has
	// terminated (error, ENOBUFS, cancel, or peer close) and nbio has recycled it;
	// the caller must re-arm to keep receiving.
	more:      bool,
	// An error, if one occurred.
	err:       Recv_Error,

	// Implementation specifics, private.
	_impl:     _Recv_Multishot `fmt:"-"`,
}

/*
Arms a multishot recv on `socket` against provided-buffer group `bgid`. `cb` fires
once per data arrival; read `op.recv_multishot` for the buffer id and byte count,
recycle that buffer back to your ring, and when `op.recv_multishot.more` is false
the op has ended (re-arm to continue).

Type-safe user data (`p`) is carried to the callback, mirroring `recv_poly`.
*/
recv_multishot_poly :: #force_inline proc(
	socket: Any_Socket,
	bgid: u16,
	p: $T,
	cb: $C/proc(op: ^Operation, p: T),
	l: ^Event_Loop = nil,
) -> ^Operation where size_of(T) <= size_of(rawptr) * MAX_USER_ARGUMENTS {
	op := prep_recv_multishot(socket, bgid, _poly_cb(C, T), l)
	_put_user_data(op, cb, p)
	exec(op)
	return op
}

// prep_recv_multishot builds (but does not submit) a multishot recv operation.
prep_recv_multishot :: proc(
	socket: Any_Socket,
	bgid: u16,
	cb: Callback,
	l: ^Event_Loop = nil,
) -> ^Operation {
	op := _prep(l, cb, .Recv_Multishot)
	op.recv_multishot = Recv_Multishot {
		socket = socket,
		bgid   = bgid,
	}
	return op
}

// ring_fd returns the io_uring file descriptor backing `l` (current loop if nil),
// as a plain int, so a caller can register a provided-buffer ring against the
// same ring nbio submits multishot recvs on. Linux/io_uring only.
ring_fd :: proc(l: ^Event_Loop = nil) -> int {
	return _ring_fd(l)
}
