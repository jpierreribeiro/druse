#+private
package http

import "core:mem/virtual"
import "base:intrinsics"

import "core:bufio"
import "core:nbio"
import "core:net"

Scan_Callback :: #type proc(user_data: rawptr, token: string, err: bufio.Scanner_Error)
Split_Proc    :: #type proc(split_data: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool)

// URUQUIM PATCH 34 (HTTP audit F2) — REQUIRE CRLF; REJECT A BARE LF OR CR.
//
// This delegated to `bufio.scan_lines`, which terminates a line on a bare `\n`
// and merely strips an optional trailing `\r`. The request line and every header
// line are split with it, so the server accepted LF-only line endings and header
// values containing a lone `\r`.
//
// That is a request-smuggling differential, and a classic one: RFC 9112 §2.2
// permits a recipient to accept a bare LF as a line terminator but a front-end
// that frames strictly on CRLF — or that forwards the bytes untouched — then
// disagrees with this backend about where a header, and therefore a request,
// ends. An attacker who can get `Foo: a\nEvil: y` past the proxy as one header
// value has it parsed as two headers here. The project's stated posture is to
// reject rather than normalise (`web/path_policy.odin`), and the strict CL/TE
// handling in `body.odin` already follows it; line termination was the gap.
//
// A `\r` NOT followed by `\n` is also refused, so a lone CR inside a field value
// cannot be laundered either. The scanner still needs more data (advance 0) when
// a trailing `\r` might be the first half of a CRLF that has not arrived yet.
scan_lines :: proc(split_data: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool) {
	for i in 0 ..< len(data) {
		switch data[i] {
		case '\n':
			// A bare LF: the preceding byte was not a CR, or we would have taken
			// the CR branch below and consumed the pair there.
			return 0, nil, .Advanced_Too_Far, false
		case '\r':
			if i + 1 >= len(data) {
				if at_eof {
					// A trailing CR with nothing after it can never become CRLF.
					return 0, nil, .Advanced_Too_Far, false
				}
				// The LF may still be in flight; ask for more bytes.
				return 0, nil, nil, false
			}
			if data[i + 1] != '\n' {
				return 0, nil, .Advanced_Too_Far, false
			}
			return i + 2, data[:i], nil, false
		}
	}
	if at_eof && len(data) > 0 {
		// Unterminated final line. The old behaviour returned it as a token;
		// an unterminated request line or header field is malformed, not a
		// message, so it is refused for the same reason as a bare LF.
		return 0, nil, .Advanced_Too_Far, false
	}
	return 0, nil, nil, false
}

scan_num_bytes :: proc(split_data: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool) {
	assert(split_data != nil)
	n := int(uintptr(split_data))
	assert(n >= 0)

	if at_eof && len(data) < n {
		return
	}

	if len(data) < n {
		return
	}

	return n, data[:n], nil, false
}

// A callback based scanner over the connection based on nbio.
Scanner :: struct /* #no_copy */ {
	connection:                   ^Connection,
	split:                        Split_Proc,
	split_data:                   rawptr,
	buf:                          [dynamic]byte,
	max_token_size:               int,
	start:                        int,
	end:                          int,
	token:                        []byte,
	_err:                         bufio.Scanner_Error,
	consecutive_empty_reads:      int,
	max_consecutive_empty_reads:  int,
	successive_empty_token_count: int,
	done:                         bool,
	could_be_too_short:           bool,
	user_data:                    rawptr,
	callback:                     Scan_Callback,

	// URUQUIM PATCH 9 (WP59) — BRIDGE. The outstanding `recv`, kept so it can be
	// cancelled.
	//
	// Upstream discards the `^nbio.Operation` that `recv_poly` returns (see
	// `scanner_read` below, and upstream's own `// TODO: some kinda timeout on
	// this` beside it). Discarding it makes the operation unreachable, and an
	// unreachable operation cannot be cancelled — which is the whole of the
	// shutdown problem:
	//
	//   1. `connection_close` frees the `^Connection` while this `recv` is still
	//      outstanding. When it later completes, `scanner_on_read` dereferences
	//      `s.connection` for its arena and touches freed memory. WP58 measured
	//      it: `free(): invalid pointer`.
	//   2. `nbio.run()` at the end of `_server_thread_shutdown` waits for every
	//      outstanding operation. One orphaned `recv` per idle keep-alive
	//      connection is enough for a drain that never ends.
	//
	// Both are the same missing capability, so both are fixed by keeping the
	// handle. `nbio.remove` needs the pointer and nothing else did.
	//
	// BRIDGE, per `vendor-policy.md` §8: this goes away with the vendored server
	// when `core:net/http` lands.
	pending_recv:                 ^nbio.Operation,

	// URUQUIM PATCH 23 (WP7.5-C1) — BRIDGE. Streaming-body buffer reclamation.
	//
	// Upstream never compacts `buf`: `start` advances as tokens are consumed but
	// the buffer only ever grows (see the `// TODO: write over the part of the
	// buffer already used` at the resize site below). For a header scan or a
	// buffered body that is fine — the whole thing is wanted contiguously. But a
	// STREAMED body read one bounded window at a time would still grow `buf` to
	// the body's full length, defeating the point. When this flag is set the
	// scanner shifts the unconsumed tail down to offset 0 before it would grow,
	// so a body of any size costs one window of buffer. Off by default: the
	// buffered path (`http.body`) is byte-for-byte upstream. Set only by
	// `http.body_stream`; cleared by `scanner_reset`.
	//
	// BRIDGE, per `vendor-policy.md` §8: goes away with the vendored server when
	// `core:net/http` lands.
	stream_compact:               bool,
}

INIT_BUF_SIZE :: 1024
DEFAULT_MAX_CONSECUTIVE_EMPTY_READS :: 128

scanner_init :: proc(s: ^Scanner, c: ^Connection, buf_allocator := context.allocator) {
	s.connection     = c
	s.split          = scan_lines
	s.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
	s.buf.allocator  = buf_allocator
}

scanner_destroy :: proc(s: ^Scanner) {
	delete(s.buf)
}

// URUQUIM PATCH 41 (audit M9) — the read buffer is RETURNED between requests
// once it has grown past what ordinary traffic needs.
//
// `remove_range` moves `len` and never touches the backing allocation, and the
// buffer grows by DOUBLING to hold a request body (`_body_length` sets
// `max_token_size = ilen`). So one large POST left that keep-alive connection
// holding a body-sized buffer for as long as the client kept the socket open,
// and `max_idle_time` defaults to 0, so nothing reaped it.
//
// The first RSS experiment, 16 keep-alive connections left idle after one POST
// each, reported:
//
//	64-byte bodies    +0.01 MB per connection
//	1 MiB bodies      +2.02 MB per connection
//	3 MiB bodies      +6.49 MB per connection
//
// RSS alone could not distinguish live allocations from freed allocator pages,
// so its old post-patch extrapolation was withdrawn. The follow-up counting
// allocator does: four blocked 3 MiB bodies expose four live scanner buffers
// totalling 16,138,240 bytes; after response completion this shrink returns the
// live total exactly to baseline. With `delete(s.buf)` removed, all 16,138,240
// bytes remain live and the permanent M9 control turns red.
//
// THE THRESHOLD IS THE POINT. Shrinking unconditionally would reallocate on
// every request of every connection. `RETAINED_BUF_MAX` is well above the
// request line and header ceilings (8000 each) and above any realistic
// pipelined burst, so ordinary traffic never reaches it and never pays. Only a
// connection that has just carried a large BODY does — and it pays one
// allocation on its next large body, in exchange for not holding megabytes
// idle.
//
// Sized in `len(s.buf)` rather than `cap`, because that is the field the
// growth path doubles and the field `remove_range` leaves standing.
RETAINED_BUF_MAX :: 256 * 1024

scanner_reset :: proc(s: ^Scanner) {
	remove_range(&s.buf, 0, s.start)
	s.end   -= s.start
	s.start  = 0

	// URUQUIM PATCH 41 (audit M9). Only when nothing is pending: `s.end` is the
	// live prefix a pipelined follow-up request may already occupy, and
	// discarding it would drop a request that has arrived.
	if len(s.buf) > RETAINED_BUF_MAX && s.end == 0 {
		// The allocator is captured and restored: `s.buf = nil` zeroes the
		// whole dynamic-array header, and the connection's buffer allocator is
		// NOT `context.allocator` (`scanner_init` takes it as a parameter).
		// Losing it would silently move the next growth onto a different heap.
		buf_allocator := s.buf.allocator
		delete(s.buf)
		s.buf = nil
		s.buf.allocator = buf_allocator
	}

	s.split                        = scan_lines
	s.split_data                   = nil
	s.max_token_size               = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
	s.token                        = nil
	s._err                         = nil
	s.consecutive_empty_reads      = 0
	s.max_consecutive_empty_reads  = DEFAULT_MAX_CONSECUTIVE_EMPTY_READS
	s.successive_empty_token_count = 0
	s.done                         = false
	s.could_be_too_short           = false
	s.user_data                    = nil
	s.callback                     = nil
	// URUQUIM PATCH 23 (WP7.5-C1) — BRIDGE. A reused connection scans the next
	// request's headers on the buffered path; the streaming flag must not leak.
	s.stream_compact               = false
}

scanner_scan :: proc(
	s: ^Scanner,
	user_data: rawptr,
	callback: proc(user_data: rawptr, token: string, err: bufio.Scanner_Error),
) {
	set_err :: proc(s: ^Scanner, err: bufio.Scanner_Error) {
		switch s._err {
		case nil, .EOF:
			s._err = err
		}
	}

	if s.done {
		callback(user_data, "", .EOF)
		return
	}

	// Check if a token is possible with what is available
	// Allow the split procedure to recover if it fails
	if s.start < s.end || s._err != nil {
		advance, token, err, final_token := s.split(s.split_data, s.buf[s.start:s.end], s._err != nil)
		if final_token {
			s.token = token
			s.done = true
			callback(user_data, "", .EOF)
			return
		}
		if err != nil {
			set_err(s, err)
			callback(user_data, "", s._err)
			return
		}

		// Do advance
		if advance < 0 {
			set_err(s, .Negative_Advance)
			callback(user_data, "", s._err)
			return
		}
		if advance > s.end - s.start {
			set_err(s, .Advanced_Too_Far)
			callback(user_data, "", s._err)
			return
		}
		s.start += advance

		s.token = token
		if s.token != nil {
			if s._err == nil || advance > 0 {
				s.successive_empty_token_count = 0
			} else {
				s.successive_empty_token_count += 1

				if s.successive_empty_token_count > s.max_consecutive_empty_reads {
					set_err(s, .No_Progress)
					callback(user_data, "", s._err)
					return
				}
			}

			s.consecutive_empty_reads = 0
			s.callback = nil
			s.user_data = nil
			callback(user_data, string(token), s._err)
			return
		}
	}

	// If an error is hit, no token can be created
	if s._err != nil {
		s.start = 0
		s.end = 0
		callback(user_data, "", s._err)
		return
	}

	could_be_too_short := false

	// URUQUIM PATCH 23 (WP7.5-C1) — BRIDGE. Reclaim the consumed prefix before
	// deciding whether the buffer must grow, so a streamed body of any size costs
	// one window of buffer rather than its full length. Only on the streaming
	// path (`stream_compact`); the buffered path never sets it and is unchanged.
	// The previous token was already handed to — and copied by — the synchronous
	// consumer before this re-arm, so shifting the tail invalidates nothing live.
	if s.stream_compact && s.start > 0 {
		if s.end > s.start {
			copy(s.buf[:], s.buf[s.start:s.end])
		}
		s.end -= s.start
		s.start = 0
	}

	// Resize the buffer if full
	if s.end == len(s.buf) {
		if s.max_token_size <= 0 {
			s.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
		}

		if s.end - s.start >= s.max_token_size {
			set_err(s, .Too_Long)
			callback(user_data, "", s._err)
			return
		}

		// TODO: write over the part of the buffer already used

		// overflow check
		new_size := INIT_BUF_SIZE
		if len(s.buf) > 0 {
			overflowed: bool
			if new_size, overflowed = intrinsics.overflow_mul(len(s.buf), 2); overflowed {
				set_err(s, .Too_Long)
				callback(user_data, "", s._err)
				return
			}
		}

		old_size := len(s.buf)
		resize(&s.buf, new_size)

		could_be_too_short = old_size >= len(s.buf)

	}

	// Read data into the buffer
	s.consecutive_empty_reads += 1
	s.user_data = user_data
	s.callback = callback
	s.could_be_too_short = could_be_too_short

	assert_has_td()
	// URUQUIM PATCH 9 (WP59) — BRIDGE. Keep the handle; see `pending_recv`.
	s.pending_recv = nbio.recv_poly(
		s.connection.socket,
		{s.buf[s.end:len(s.buf)]},
		s,
		scanner_on_read,
	)
}

scanner_on_read :: proc(op: ^nbio.Operation, s: ^Scanner) {
	// URUQUIM PATCH 9 (WP59) — BRIDGE. The operation has fired, so the handle is
	// dead: `nbio.remove` on an operation whose callback has run is itself a use
	// after free, and the library says so. Cleared FIRST, before any early
	// return below can skip it.
	s.pending_recv = nil

	context.temp_allocator = virtual.arena_allocator(&s.connection.temp_allocator)

	defer scanner_scan(s, s.user_data, s.callback)

	if op.recv.err != nil {
		#partial switch op.recv.err.(net.TCP_Recv_Error) {
		case .Connection_Closed, .Invalid_Argument:
			// EBADF (bad file descriptor) happens when OS closes socket.
			// URUQUIM PATCH 25 (Closure C-03) — the peer is gone. Recorded on
			// the connection so `connection_close` can skip a politeness delay
			// owed to nobody; see the long note there.
			s.connection.peer_gone = true
			s._err = .EOF
			return
		}

		s._err = .Unknown
		return
	}

	// When n == 0, connection is closed or buffer is of length 0.
	if op.recv.received == 0 {
		// URUQUIM PATCH 25 (Closure C-03) — an orderly FIN is equally final for
		// the read side; no further byte can arrive.
		s.connection.peer_gone = true
		s._err = .EOF
		return
	}

	if op.recv.received < 0 || len(s.buf) - s.end < op.recv.received {
		s._err = .Bad_Read_Count
		return
	}

	s.end += op.recv.received
	if op.recv.received > 0 {
		s.successive_empty_token_count = 0
		return
	}
}
