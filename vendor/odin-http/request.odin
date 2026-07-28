package http

import "core:net"
import "core:strings"

Request :: struct {
	// If in a handler, this is always there and never None.
	// TODO: we should not expose this as a maybe to package users.
	line:       Maybe(Requestline),

	// Is true if the request is actually a HEAD request,
	// line.method will be .Get if Server_Opts.redirect_head_to_get is set.
	is_head:    bool,

	headers:    Headers,
	url:        URL,
	client:     net.Endpoint,

	// Route params/captures.
	url_params: []string,

	// Internal usage only.
	_scanner:   ^Scanner,
	_body_ok:   Maybe(bool),
}

request_init :: proc(r: ^Request, allocator := context.allocator) {
	headers_init(&r.headers, allocator)
}

// TODO: call it headers_sanitize because it modifies the headers.

// Validates the headers of a request, from the pov of the server.
headers_validate_for_server :: proc(headers: ^Headers) -> bool {
	// RFC 7230 5.4: A server MUST respond with a 400 (Bad Request) status code to any
	// HTTP/1.1 request message that lacks a Host header field.
	if !headers_has_unsafe(headers^, "host") {
		return false
	}

	return headers_validate(headers)
}

// URUQUIM PATCH 37 (audit H3) — the ONE predicate that decides whether a
// message is chunked-framed, shared by `headers_validate`, `body` and
// `body_stream` so the three cannot disagree about the framing of the same
// request.
//
// THE DEFECT IT REPLACES. All three asked `strings.has_suffix(enc, "chunked")`.
// That is true for far more than the chunked coding:
//
//   Transfer-Encoding: xchunked          -> accepted, framed as chunked (200)
//   Transfer-Encoding: chunked, chunked  -> accepted, framed as chunked (200)
//
// both measured on a socket against this backend. `xchunked` is the sharp one:
// it is not a registered transfer-coding, and RFC 9112 6.1 says a server that
// does not understand a transfer-coding must reject the message. A front proxy
// that treats `xchunked` as unknown while this server reads it as chunked is
// two hops disagreeing about where the body ends, which is request smuggling.
// `chunked, chunked` is refused by the same clause: chunked must not be applied
// more than once.
//
// THE RULE, per RFC 9112 6.1:
//   - the coding list is comma-separated, each element trimmed of OWS;
//   - names are case-insensitive, so `CHUNKED` is chunked (the old suffix test
//     rejected it, which was wrong in the other direction);
//   - `chunked` must be the FINAL coding, and must appear exactly once.
//
// `false` means "refuse this message" (400), which is the pre-existing
// contract: a REQUEST carrying any Transfer-Encoding must end in chunked, or
// its body length cannot be determined. An unrecognized coding therefore does
// not fall back to Content-Length framing — falling back would leave the
// chunked bytes in the buffer to be read as a pipelined request, which is the
// same smuggling disagreement by another route.
//
// Note what is deliberately NOT changed: a preceding coding such as
// `gzip, chunked` is still ACCEPTED and its payload handed to the application
// still encoded, because decoding transfer-codings is a separate feature and
// refusing them here would be a behaviour change beyond this defect.
transfer_encoding_chunked_final :: proc(enc: string) -> bool {
	token_is_chunked :: proc(t: string) -> bool {
		name := "chunked"
		if len(t) != len(name) {
			return false
		}
		for i in 0 ..< len(t) {
			c := t[i]
			if 'A' <= c && c <= 'Z' {
				c += 32 // ASCII fold: transfer-coding names are case-insensitive
			}
			if c != name[i] {
				return false
			}
		}
		return true
	}

	count := 0
	last_is_chunked := false
	rest := enc
	for {
		comma := strings.index_byte(rest, ',')
		token := rest if comma < 0 else rest[:comma]
		token = strings.trim_space(token)
		// An empty element (`chunked,` or `a,,b`) is malformed framing metadata;
		// refuse rather than guess which side meant what.
		if len(token) == 0 {
			return false
		}
		last_is_chunked = token_is_chunked(token)
		if last_is_chunked {
			count += 1
		}
		if comma < 0 {
			break
		}
		rest = rest[comma + 1:]
	}
	// Exactly once, and last. `count > 1` catches `chunked, chunked`, which a
	// duplicated header also produces now that repeats are comma-merged.
	return count == 1 && last_is_chunked
}

// Validates the headers, use `headers_validate_for_server` if these are request headers
// that should be validated from the server side.
headers_validate :: proc(headers: ^Headers) -> bool {
	// RFC 7230 3.3.3: If a Transfer-Encoding header field
	// is present in a request and the chunked transfer coding is not
	// the final encoding, the message body length cannot be determined
	// reliably; the server MUST respond with the 400 (Bad Request)
	// status code and then close the connection.
	if enc_header, ok := headers_get_unsafe(headers^, "transfer-encoding"); ok {
		transfer_encoding_chunked_final(enc_header) or_return
	}

	// RFC 7230 3.3.3: If a message is received with both a Transfer-Encoding and a
	// Content-Length header field, the Transfer-Encoding overrides the
	// Content-Length.  Such a message might indicate an attempt to
	// perform request smuggling (Section 9.5) or response splitting
	// (Section 9.4) and ought to be handled as an error.
	// URUQUIM PATCH (WP9 D2): CL+TE is REJECTED, not repaired. Deleting the
	// Content-Length and proceeding leaves the two ends of a proxy chain
	// disagreeing about where the body stops, which is precisely the request
	// smuggling vector RFC 9112 6.1 calls an unrecoverable error. See VENDOR.md.
	if headers_has_unsafe(headers^, "transfer-encoding") && headers_has_unsafe(headers^, "content-length") {
		return false
	}

	return true
}
