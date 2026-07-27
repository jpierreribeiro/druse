package http

// URUQUIM PATCH 23 (WP7.5-C1) — BRIDGE. Streaming inbound body.
//
// The upstream `body` (body.odin) materializes the WHOLE request body before it
// calls back: a Content-Length body is one `scan_num_bytes` token the size of
// the declared length, and a chunked body is accumulated into a `strings.Builder`.
// That is correct for the buffered path (the handler wants the whole body at
// once, capped by `max_body`), and it is left byte-for-byte untouched.
//
// `body_stream` is the OTHER shape the large-body opt-in needs: deliver the body
// to a consumer one bounded window at a time, so a body of any size costs one
// window of memory rather than its length. It pairs with the scanner's
// `stream_compact` reclamation (scanner.odin, same patch) and with the ingest
// spool consumer (`web/internal/ingest`). The consumer is synchronous and
// non-blocking (it writes each window straight to disk), so backpressure is
// expressed inline: the sink returns `.Continue` or `.Stop`, and a `.Stop`
// (an early refusal, a quota breach, a drain) halts the read — the next socket
// recv is simply never armed. This is the read-side twin of WP90b's outbound
// pump (VENDOR.md patch 22), and BRIDGE for the same reason: it goes away with
// the vendored server when `core:net/http` lands.
//
// Every framing guard the buffered path earned is re-applied here: the F3
// negative chunk-size reject, the WP9-D2 plain-decimal / F10 19-digit
// Content-Length guards, and the WP9-D3 "a chunk must be CRLF-terminated"
// reject. A malformed body fails closed with a typed outcome, never a hang or
// an abort.

import "core:bufio"
import "core:strconv"
import "core:strings"

// One window of buffer. 64 KiB matches the ingest in-memory prefix bound
// (`ingest.DEFAULT_MEMORY_PREFIX`); the caller may pass a smaller one.
DEFAULT_STREAM_WINDOW :: 64 * 1024

// What the consumer tells the reader after each window.
Body_Sink_Result :: enum u8 {
	Continue, // keep reading
	Stop,     // stop reading now; the consumer has recorded its own terminal reason
}

// How a streamed body read ended.
Stream_Outcome :: enum u8 {
	Complete, // the whole body was delivered
	Stopped,  // the consumer returned .Stop (its terminal reason is its own)
	Failed,   // a framing / transport error; `err` carries it
}

Body_Chunk_Proc :: #type proc(user_data: rawptr, chunk: []u8) -> Body_Sink_Result
Body_Stream_Done :: #type proc(user_data: rawptr, outcome: Stream_Outcome, err: Body_Error)

@(private = "file")
Stream_State :: struct {
	req:               ^Request,
	max_length:        int,
	window:            int,
	segment_remaining: int, // bytes still wanted from the current segment (CL total, or one chunk)
	delivered:         int, // bytes handed to the sink so far (drives `max_length` on chunked)
	user_data:         rawptr,
	on_chunk:          Body_Chunk_Proc,
	on_done:           Body_Stream_Done,
}

/*
Streams the request's body to `on_chunk` one bounded window at a time, then
calls `on_done` exactly once with the outcome.

`max_length` caps the total body (a Content-Length over it is refused before any
byte is read; a chunked body over it is refused mid-stream), mirroring the
buffered path's `max_body`. `window` bounds both the delivered chunk size and
the scanner buffer. Do not call this — or `body` — more than once per request.
*/
body_stream :: proc(
	req: ^Request,
	max_length: int = -1,
	window: int = DEFAULT_STREAM_WINDOW,
	user_data: rawptr,
	on_chunk: Body_Chunk_Proc,
	on_done: Body_Stream_Done,
) {
	assert(req._body_ok == nil, "you can only call body once per request")

	s := new(Stream_State, context.temp_allocator)
	s.req = req
	s.max_length = max_length
	s.window = window if window > 0 else DEFAULT_STREAM_WINDOW
	s.user_data = user_data
	s.on_chunk = on_chunk
	s.on_done = on_done

	enc, ok := headers_get_unsafe(req.headers, "transfer-encoding")
	if ok && strings.has_suffix(enc, "chunked") {
		_stream_chunked(s)
	} else {
		_stream_length(s)
	}
}

// The windowed split: yield whatever bytes are available, capped by what is
// still wanted from the current segment and by the window. Unlike
// `scan_num_bytes` it never waits for the whole segment, which is what keeps
// memory bounded.
@(private = "file")
scan_stream_window :: proc(split_data: rawptr, data: []byte, at_eof: bool) -> (advance: int, token: []byte, err: bufio.Scanner_Error, final_token: bool) {
	s := (^Stream_State)(split_data)
	if s.segment_remaining <= 0 || len(data) == 0 {
		return 0, nil, nil, false
	}
	take := len(data)
	if take > s.segment_remaining {take = s.segment_remaining}
	if take > s.window {take = s.window}
	return take, data[:take], nil, false
}

// --- Content-Length ---------------------------------------------------------

@(private = "file")
_stream_length :: proc(s: ^Stream_State) {
	req := s.req
	req._body_ok = false

	len_h, ok := headers_get_unsafe(req.headers, "content-length")
	if !ok {
		// No Content-Length and not chunked: no body to read (mirrors PATCH 7).
		req._body_ok = true
		s.on_done(s.user_data, .Complete, nil)
		return
	}

	// PATCH 9 (WP9 D2): a whole non-negative decimal only.
	if !_is_plain_decimal(len_h) {
		s.on_done(s.user_data, .Failed, .Bad_Read_Count)
		return
	}
	// PATCH 16 (F10): refuse >= 2^64 (more than 19 significant digits) before the
	// parse can wrap.
	{
		sig := 0
		leading := true
		for ch in len_h {
			if leading && ch == '0' {continue}
			leading = false
			sig += 1
		}
		if sig > 19 {
			s.on_done(s.user_data, .Failed, .Bad_Read_Count)
			return
		}
	}

	ilen, lenok := strconv.parse_int(len_h, 10)
	if !lenok || ilen < 0 {
		s.on_done(s.user_data, .Failed, .Bad_Read_Count)
		return
	}
	if s.max_length > -1 && ilen > s.max_length {
		s.on_done(s.user_data, .Failed, .Too_Long)
		return
	}
	if ilen == 0 {
		req._body_ok = true
		s.on_done(s.user_data, .Complete, nil)
		return
	}

	s.segment_remaining = ilen
	req._body_ok = true
	_stream_length_arm(s)
}

@(private = "file")
_stream_length_arm :: proc(s: ^Stream_State) {
	s.req._scanner.stream_compact = true
	s.req._scanner.max_token_size = s.window
	s.req._scanner.split = scan_stream_window
	s.req._scanner.split_data = s
	scanner_scan(s.req._scanner, s, _on_stream_length)
}

@(private = "file")
_on_stream_length :: proc(user_data: rawptr, token: string, err: bufio.Scanner_Error) {
	s := (^Stream_State)(user_data)
	if err != nil {
		s.on_done(s.user_data, .Failed, err)
		return
	}
	if len(token) > 0 {
		s.segment_remaining -= len(token)
		if s.on_chunk(s.user_data, transmute([]u8)token) == .Stop {
			s.on_done(s.user_data, .Stopped, nil)
			return
		}
	}
	if s.segment_remaining <= 0 {
		s.on_done(s.user_data, .Complete, nil)
		return
	}
	_stream_length_arm(s)
}

// --- chunked ----------------------------------------------------------------

@(private = "file")
_stream_chunked :: proc(s: ^Stream_State) {
	s.req._body_ok = false
	s.req._scanner.stream_compact = true
	s.req._scanner.split = scan_lines
	scanner_scan(s.req._scanner, s, _on_chunk_size)
}

@(private = "file")
_on_chunk_size :: proc(user_data: rawptr, size_line: string, err: bufio.Scanner_Error) {
	s := (^Stream_State)(user_data)
	size_line := size_line
	if err != nil {
		s.on_done(s.user_data, .Failed, err)
		return
	}

	// Discard chunk extensions.
	if semi := strings.index_byte(size_line, ';'); semi > -1 {
		size_line = size_line[:semi]
	}

	// PATCH 14 (F3): a chunk size is unsigned hex; reject a negative/overflowed
	// parse the same way a malformed line is rejected, so a hostile size can
	// never reach the scanner's `n >= 0` assertion.
	// PATCH 33 (HTTP audit F1) — see `_is_plain_hex`: the streaming path carried
	// the same leniency as the buffered one and needs the same strictness, or the
	// two disagree with each other as well as with a front-end proxy.
	size, ok := strconv.parse_int(string(size_line), 16)
	if !_is_plain_hex(string(size_line)) || !ok || size < 0 {
		s.on_done(s.user_data, .Failed, .Bad_Read_Count)
		return
	}

	if size == 0 {
		// Last chunk: skip the trailer section, then done.
		s.req._scanner.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
		s.req._scanner.split = scan_lines
		scanner_scan(s.req._scanner, s, _on_chunk_trailer)
		return
	}

	if s.max_length > -1 && s.delivered + size > s.max_length {
		s.on_done(s.user_data, .Failed, .Too_Long)
		return
	}

	s.segment_remaining = size
	_stream_chunk_arm(s)
}

@(private = "file")
_stream_chunk_arm :: proc(s: ^Stream_State) {
	s.req._scanner.max_token_size = s.window
	s.req._scanner.split = scan_stream_window
	s.req._scanner.split_data = s
	scanner_scan(s.req._scanner, s, _on_chunk_data)
}

@(private = "file")
_on_chunk_data :: proc(user_data: rawptr, token: string, err: bufio.Scanner_Error) {
	s := (^Stream_State)(user_data)
	if err != nil {
		s.on_done(s.user_data, .Failed, err)
		return
	}
	if len(token) > 0 {
		s.segment_remaining -= len(token)
		s.delivered += len(token)
		if s.on_chunk(s.user_data, transmute([]u8)token) == .Stop {
			s.on_done(s.user_data, .Stopped, nil)
			return
		}
	}
	if s.segment_remaining > 0 {
		_stream_chunk_arm(s)
		return
	}
	// Chunk data done; the chunk must be terminated by CRLF.
	s.req._scanner.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
	s.req._scanner.split = scan_lines
	scanner_scan(s.req._scanner, s, _on_chunk_crlf)
}

@(private = "file")
_on_chunk_crlf :: proc(user_data: rawptr, token: string, err: bufio.Scanner_Error) {
	s := (^Stream_State)(user_data)
	if err != nil {
		s.on_done(s.user_data, .Failed, err)
		return
	}
	// PATCH (WP9 D3): a chunk not terminated by CRLF is malformed input, not a
	// programming error — reject it instead of asserting.
	if len(token) != 0 {
		s.on_done(s.user_data, .Failed, .Unknown)
		return
	}
	s.req._scanner.split = scan_lines
	scanner_scan(s.req._scanner, s, _on_chunk_size)
}

@(private = "file")
_on_chunk_trailer :: proc(user_data: rawptr, line: string, err: bufio.Scanner_Error) {
	s := (^Stream_State)(user_data)
	// End of trailer section (blank line or EOF): the streamed body is complete.
	// The streaming consumer does not merge trailer fields (it owns a spooled
	// body, not the header map), so — unlike the buffered path — nothing here
	// mutates the frozen headers, and the PATCH 15 readonly-assert cannot fire.
	if err != nil || len(line) == 0 {
		s.req._body_ok = true
		s.on_done(s.user_data, .Complete, nil)
		return
	}
	scanner_scan(s.req._scanner, s, _on_chunk_trailer)
}

// Test-support (PATCH 23): the scan buffer's current capacity, so the streaming
// corpus can PROVE the boundedness claim — a body of any size must cost one
// window of buffer, not its length. Without the `stream_compact` reclamation
// this would grow to the whole body; the corpus asserts it does not.
scan_buffer_cap :: proc(req: ^Request) -> int {
	return len(req._scanner.buf)
}
