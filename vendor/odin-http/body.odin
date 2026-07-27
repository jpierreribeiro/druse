package http

import "core:bufio"
import "core:io"
import "core:log"
import "core:net"
import "core:strconv"
import "core:strings"

Body :: string

Body_Callback :: #type proc(user_data: rawptr, body: Body, err: Body_Error)

Body_Error :: bufio.Scanner_Error

/*
Retrieves the request's body.

If the request has the chunked Transfer-Encoding header set, the chunks are all read and returned.
Otherwise, the Content-Length header is used to determine what to read and return it.

`max_length` can be used to set a maximum amount of bytes we try to read, once it goes over this,
an error is returned.

Do not call this more than once.

**Tip** If an error is returned, easily respond with an appropriate error code like this, `http.respond(res, http.body_error_status(err))`.
*/
body :: proc(req: ^Request, max_length: int = -1, user_data: rawptr, cb: Body_Callback) {
	assert(req._body_ok == nil, "you can only call body once per request")

	enc_header, ok := headers_get_unsafe(req.headers, "transfer-encoding")
	if ok && strings.has_suffix(enc_header, "chunked") {
		_body_chunked(req, max_length, user_data, cb)
	} else {
		_body_length(req, max_length, user_data, cb)
	}
}

/*
Parses a URL encoded body, aka bodies with the 'Content-Type: application/x-www-form-urlencoded'.

Key&value pairs are percent decoded and put in a map.
*/
body_url_encoded :: proc(plain: Body, allocator := context.temp_allocator) -> (res: map[string]string, ok: bool) {

	insert :: proc(m: ^map[string]string, plain: string, keys: int, vals: int, end: int, allocator := context.temp_allocator) -> bool {
		has_value := vals != -1
		key_end   := vals - 1 if has_value else end
		key       := plain[keys:key_end]
		val       := plain[vals:end] if has_value else ""

		// PERF: this could be a hot spot and I don't like that we allocate the decoded key and value here.
		keye := (net.percent_decode(key, allocator) or_return) if strings.index_byte(key, '%') > -1 else key
		vale := (net.percent_decode(val, allocator) or_return) if has_value && strings.index_byte(val, '%') > -1 else val

		m[keye] = vale
		return true
	}

	count := 1
	for b in plain {
		if b == '&' { count += 1 }
	}

	queries := make(map[string]string, count, allocator)

	keys := 0
	vals := -1
	for b, i in plain {
		switch b {
		case '=':
			vals = i + 1
		case '&':
			insert(&queries, plain, keys, vals, i) or_return
			keys = i + 1
			vals = -1
		}
	}

	insert(&queries, plain, keys, vals, len(plain)) or_return

	return queries, true
}

// Returns an appropriate status code for the given body error.
body_error_status :: proc(e: Body_Error) -> Status {
	switch t in e {
	case bufio.Scanner_Extra_Error:
		switch t {
		case .Too_Long:                            return .Payload_Too_Large
		case .Too_Short, .Bad_Read_Count:          return .Bad_Request
		case .Negative_Advance, .Advanced_Too_Far: return .Internal_Server_Error
		case .None:                                return .OK
		case:
			return .Internal_Server_Error
		}
	case io.Error:
		switch t {
		case .EOF, .Unknown, .No_Progress, .Unexpected_EOF:
			return .Bad_Request
		case .Empty, .Short_Write, .Buffer_Full, .Short_Buffer,
		     .Invalid_Write, .Negative_Read, .Invalid_Whence, .Invalid_Offset,
		     .Invalid_Unread, .Negative_Write, .Negative_Count,
		     .Permission_Denied, .No_Size, .Closed:
			return .Internal_Server_Error
		case .None:
			return .OK
		case:
			return .Internal_Server_Error
		}
	case: unreachable()
	}
}


// "Decodes" a request body based on the content length header.
// Meant for internal usage, you should use `http.request_body`.
_body_length :: proc(req: ^Request, max_length: int = -1, user_data: rawptr, cb: Body_Callback) {
	req._body_ok = false

	len, ok := headers_get_unsafe(req.headers, "content-length")
	if !ok {
		// URUQUIM PATCH 7 (WP45) — NO BODY IS NOT A FAILED BODY.
		//
		// `_body_ok` is set to `false` at the top of this procedure and means
		// "the body read was attempted and failed"; `response_must_close` reads
		// it that way and retires the connection. But a request with no
		// `Content-Length` has no body to read, and returning here without
		// setting it left `false` standing on a SUCCESS path.
		//
		// The consequence, measured before this patch: **every GET closed its
		// connection.** No `Connection: close` was advertised, so a client had
		// no way to know — it simply paid a TCP handshake per request while
		// HTTP/1.1 promised persistence. Two sequential requests on one socket:
		// the first answered, the second met an orderly close.
		//
		// Setting it here says what actually happened: there was nothing to
		// read, and reading nothing succeeded.
		req._body_ok = true
		cb(user_data, "", nil)
		return
	}

	// URUQUIM PATCH (WP9 D2): the length must be a WHOLE non-negative decimal.
	// `strconv.parse_int` accepts a leading '-' and stops at the first
	// non-digit, so `-1` parsed as -1 and reached `max_token_size`, tripping the
	// scanner's `n >= 0` assertion and KILLING THE SERVER — a remote denial of
	// service from one header. A comma list ("2, 2") likewise parsed as 2 and
	// silently accepted an ambiguous framing. See VENDOR.md.
	if !_is_plain_decimal(len) {
		cb(user_data, "", .Bad_Read_Count)
		return
	}

	// URUQUIM PATCH 16 (F10) — `_is_plain_decimal` permits an arbitrarily long
	// digit string, and `strconv.parse_int` wraps on overflow: a value >= 2^64
	// wraps to a small positive, so the server would read fewer bytes than
	// declared and treat the remainder as a second request (a smuggling/desync
	// primitive behind a proxy that frames by the true length). The [2^63, 2^64)
	// range wraps negative and is caught by `ilen < 0` below; the >= 2^64 range
	// is exactly the strings with more than 19 significant digits. No legitimate
	// body approaches 10^19 bytes, so refuse them before the wrap can matter.
	{
		sig := 0
		leading := true
		for ch in len {
			if leading && ch == '0' {
				continue
			}
			leading = false
			sig += 1
		}
		if sig > 19 {
			cb(user_data, "", .Bad_Read_Count)
			return
		}
	}

	ilen, lenok := strconv.parse_int(len, 10)
	if !lenok || ilen < 0 {
		cb(user_data, "", .Bad_Read_Count)
		return
	}

	if max_length > -1 && ilen > max_length {
		cb(user_data, "", .Too_Long)
		return
	}

	if ilen == 0 {
		req._body_ok = true
		cb(user_data, "", nil)
		return
	}

	req._scanner.max_token_size = ilen

	req._scanner.split          = scan_num_bytes
	req._scanner.split_data     = rawptr(uintptr(ilen))

	req._body_ok = true
	scanner_scan(req._scanner, user_data, cb)
}

/*
"Decodes" a chunked transfer encoded request body.
Meant for internal usage, you should use `http.request_body`.

PERF: this could be made non-allocating by writing over the part of the body that contains the
metadata with the rest of the body, and then returning a slice of that, but it is some effort and
I don't think this functionality of HTTP is used that much anyway.

RFC 7230 4.1.3 pseudo-code:

length := 0
read chunk-size, chunk-ext (if any), and CRLF
while (chunk-size > 0) {
   read chunk-data and CRLF
   append chunk-data to decoded-body
   length := length + chunk-size
   read chunk-size, chunk-ext (if any), and CRLF
}
read trailer field
while (trailer field is not empty) {
   if (trailer field is allowed to be sent in a trailer) {
   	append trailer field to existing header fields
   }
   read trailer-field
}
Content-Length := length
Remove "chunked" from Transfer-Encoding
Remove Trailer from existing header fields
*/
_body_chunked :: proc(req: ^Request, max_length: int = -1, user_data: rawptr, cb: Body_Callback) {
	req._body_ok = false

	on_scan :: proc(s: rawptr, size_line: string, err: bufio.Scanner_Error) {
		s := cast(^Chunked_State)s
		size_line := size_line

		if err != nil {
			s.cb(s.user_data, "", err)
			return
		}

		// If there is a semicolon, discard everything after it,
		// that would be chunk extensions which we currently have no interest in.
		if semi := strings.index_byte(size_line, ';'); semi > -1 {
			size_line = size_line[:semi]
		}

		// URUQUIM PATCH 14 (F3) — a chunk-size line is unsigned hex, but
		// `strconv.parse_int` accepts a leading `-` and silently wraps values
		// that overflow i64, both yielding a negative `size`. A negative size
		// is stored as the scanner's `max_token_size`/`split_data` and reaches
		// `scan_num_bytes`, where `int(uintptr(split_data))` is negative and
		// `assert(n >= 0)` aborts the whole process (with asserts off it is an
		// out-of-bounds slice). This is the same remote-DoS class the
		// Content-Length path already guards with `_is_plain_decimal`; the
		// chunked path was missed. Reject any non-positive parse the same way a
		// malformed size line is rejected.
		// PATCH 33 (HTTP audit F1) — hex digits only, checked BEFORE the parse,
		// so `+a` and `1_0` are refused here instead of being read as 10 and 16.
		size, ok := strconv.parse_int(string(size_line), 16)
		if !_is_plain_hex(string(size_line)) || !ok || size < 0 {
			log.infof("Encountered an invalid chunk size when decoding a chunked body: %q", string(size_line))
			s.cb(s.user_data, "", .Bad_Read_Count)
			return
		}

		// start scanning trailer headers.
		if size == 0 {
			scanner_scan(s.req._scanner, s, on_scan_trailer)
			return
		}

		if s.max_length > -1 && strings.builder_len(s.buf) + size > s.max_length {
			s.cb(s.user_data, "", .Too_Long)
			return
		}

		s.req._scanner.max_token_size = size

		s.req._scanner.split          = scan_num_bytes
		s.req._scanner.split_data     = rawptr(uintptr(size))

		scanner_scan(s.req._scanner, s, on_scan_chunk)
	}

	on_scan_chunk :: proc(s: rawptr, token: string, err: bufio.Scanner_Error) {
		s := cast(^Chunked_State)s

		if err != nil {
			s.cb(s.user_data, "", err)
			return
		}

		s.req._scanner.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE
		s.req._scanner.split          = scan_lines

		strings.write_string(&s.buf, token)

		on_scan_empty_line :: proc(s: rawptr, token: string, err: bufio.Scanner_Error) {
			s := cast(^Chunked_State)s

			if err != nil {
				s.cb(s.user_data, "", err)
				return
			}
			// URUQUIM PATCH (WP9 D3): a chunk that is not terminated by CRLF is
			// MALFORMED INPUT, not a programming error. Upstream asserted here,
			// so a hand-written chunked body without the trailing CRLF killed
			// the server — a second remote denial of service. It is now
			// rejected like any other malformed chunk. See VENDOR.md.
			if len(token) != 0 {
				s.cb(s.user_data, "", .Unknown)
				return
			}

			scanner_scan(s.req._scanner, s, on_scan)
		}

		scanner_scan(s.req._scanner, s, on_scan_empty_line)
	}

	on_scan_trailer :: proc(s: rawptr, line: string, err: bufio.Scanner_Error) {
		s := cast(^Chunked_State)s

		// Headers are done, success.
		if err != nil || len(line) == 0 {
			headers_delete_unsafe(&s.req.headers, "trailer")

			te_header := headers_get_unsafe(s.req.headers, "transfer-encoding")
			new_te_header := strings.trim_suffix(te_header, "chunked")

			s.req.headers.readonly = false
			headers_set_unsafe(&s.req.headers, "transfer-encoding", new_te_header)
			s.req.headers.readonly = true

			s.req._body_ok = true
			s.cb(s.user_data, strings.to_string(s.buf), nil)
			return
		}

		// URUQUIM PATCH 15 (F2) — the server freezes the request headers
		// (`headers.readonly = true`) before dispatch, but a chunked body's
		// trailer section is parsed AFTER that freeze, and parsing a trailer
		// field mutates the header map: `header_parse` reaches
		// `assert(!h.readonly)` and aborts the whole process on the first
		// non-empty trailer line — which is legal HTTP/1.1 any client may send.
		// The empty-line branch above already clears `readonly` around its own
		// mutation; do the same around trailer-field parsing, which is the
		// decoder's own bookkeeping, not the handler mutation the freeze exists
		// to forbid.
		s.req.headers.readonly = false
		key, ok := header_parse(&s.req.headers, string(line))
		if !ok {
			s.req.headers.readonly = true
			log.infof("Invalid header when decoding chunked body: %q", string(line))
			s.cb(s.user_data, "", .Unknown)
			return
		}

		// A recipient MUST ignore (or consider as an error) any fields that are forbidden to be sent in a trailer.
		if !header_allowed_trailer(key) {
			log.infof("Invalid trailer header received, discarding it: %q", key)
			headers_delete(&s.req.headers, key)
		}
		s.req.headers.readonly = true

		scanner_scan(s.req._scanner, s, on_scan_trailer)
	}

	Chunked_State :: struct {
		req:        ^Request,
		max_length: int,
		user_data:  rawptr,
		cb:         Body_Callback,

		buf:        strings.Builder,
	}

	s := new(Chunked_State, context.temp_allocator)

	s.buf.buf.allocator = context.temp_allocator

	s.req        = req
	s.max_length = max_length
	s.user_data  = user_data
	s.cb         = cb

	s.req._scanner.split = scan_lines
	scanner_scan(s.req._scanner, s, on_scan)
}

// URUQUIM PATCH (WP9 D2): a Content-Length must be one or more ASCII digits and
// nothing else — no sign, no whitespace, no comma list, no trailing text. See
// VENDOR.md.
@(private)
_is_plain_decimal :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// URUQUIM PATCH 34 (HTTP audit F1) — the chunk-size counterpart of
// `_is_plain_decimal`, and it exists for the same reason on the other framing
// axis. RFC 9112 §7.1 defines chunk-size as 1*HEXDIG, but both chunked paths
// passed the line straight to `strconv.parse_int(.., 16)` and only rejected a
// NEGATIVE result. Odin's numeric parsing accepts a leading `+` and ignores `_`
// digit separators, so `+a` and `1_0` parsed to valid positive sizes here while
// an RFC-strict front-end rejects them as malformed. That disagreement about
// where a chunk ends is a Transfer-Encoding desync — the request-smuggling
// primitive the Content-Length path was already hardened against. Hex digits
// only; nothing else, in either case.
@(private)
_is_plain_hex :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') {
			continue
		}
		return false
	}
	return true
}
