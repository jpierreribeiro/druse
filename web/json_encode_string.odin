// WP-ENC1 — THE JSON QUOTED-STRING WRITER, owned by Druse.
//
// WHY THIS FILE EXISTS. `docs/reports/2026-07-30-encode-profile.md` measured the
// encode path for the first time and found that **25.7% of encode self time**
// is spent writing quoted strings — spread across four symbols
// (`io::write_quoted_string`, `io::write_escaped_rune`, `io::write_encoded_rune`
// and `io::write_rune`). That is the largest remaining cost on the response
// path, larger than the second validation pass the type gate removes.
//
// The reason is structural, not incidental. `core:io`'s writer decodes a string
// into runes and pushes them through the `io.Writer` vtable ONE RUNE AT A TIME:
// a 200-byte ASCII field name and value pair costs 200 indirect calls, none of
// which do anything but copy a byte that needed no inspection. The standard fix
// is an ASCII fast path — scan for the first byte that actually requires an
// escape, copy everything before it in a single move, and pay the slow path only
// from there. Go's `encoding/json` does exactly this, and it is why Go's encoder
// is fast on the payloads real applications send.
//
// BYTE-FOR-BYTE EQUIVALENCE IS THE CONTRACT, NOT A GOAL. This procedure is a
// faster way to produce THE SAME BYTES as
// `io.write_quoted_string(w, s, '"', nil, for_json = true)` — the exact call
// `core:encoding/json`'s marshaller makes. It is deliberately NOT an improved
// encoder. Two of core's choices are, on their merits, questionable: every rune
// above U+00FF is escaped as `\uXXXX` even though raw UTF-8 is valid JSON, and
// an invalid UTF-8 byte is emitted as `\xHH`, which is not valid JSON at all.
// Both are reproduced here on purpose. Changing what goes on the wire is a
// separate, visible decision with its own evidence; smuggling it in under a
// performance change would invalidate every byte-count comparison in
// `docs/reports/` — and this project has already published one number that was
// an artifact of two servers emitting different bytes
// (`2026-07-30-open-loop-application-matrix.md`, the withdrawn row). The
// differential test in `tests/wp-enc1-quoted-string` proves the equivalence over
// every rune in the Unicode range and every possible byte, and it is the reason
// this file may be trusted.
//
// SCOPE. This is the primitive only. Routing the marshaller's four string sites
// through it requires Druse to own the marshal walk, because
// `core:encoding/json` calls `io.write_quoted_string` directly and offers no
// hook — that is the next work package, and it is the one that also unlocks
// float rendering (~6.8%, and the reason `/json/medium` is not comparable).
package web
// druse:file application

import "core:io"
import "core:unicode/utf16"
import "core:unicode/utf8"

// The lowercase hex alphabet, matching `core:io`'s `DIGITS_LOWER`. A `é`
// and a `é` are the same character to a parser and DIFFERENT bytes to a
// byte-count comparison, so the case is part of the contract.
//
// This is a `rodata` ARRAY, not a string constant, because a constant cannot be
// indexed by a variable — and `@(rodata)` is what keeps it in the read-only
// section rather than making it writable package state.
@(private, rodata)
JSON_HEX_DIGITS := [16]byte {
	'0', '1', '2', '3', '4', '5', '6', '7',
	'8', '9', 'a', 'b', 'c', 'd', 'e', 'f',
}

// json_write_quoted_string writes `s` as a quoted JSON string, producing bytes
// identical to `io.write_quoted_string(w, s, '"', nil, true)`.
//
// The loop holds one invariant: `s[start:i]` is a run of bytes that need no
// escaping and may be copied verbatim. Every exit from the fast path flushes
// that run before doing anything else, and re-opens it after.
@(private)
json_write_quoted_string :: proc(w: io.Writer, s: string) -> (err: io.Error) {
	io.write_byte(w, '"') or_return

	start, i := 0, 0
	for i < len(s) {
		b := s[i]

		// The fast path. A byte is copied verbatim exactly when core would have
		// written it unchanged: printable ASCII (0x20..0x7E) that is neither the
		// quote nor the backslash. 0x7F is excluded because core does not
		// consider it printable and escapes it as ``.
		if b >= 0x20 && b < 0x7f && b != '"' && b != '\\' {
			i += 1
			continue
		}

		if start < i {
			io.write_string(w, s[start:i]) or_return
		}

		if b < utf8.RUNE_SELF {
			json_write_escaped_ascii(w, b) or_return
			i += 1
		} else {
			r, width := utf8.decode_rune_in_string(s[i:])

			// An invalid UTF-8 byte. core emits `\xHH` here, which is NOT valid
			// JSON; it is reproduced because equivalence is the contract. The
			// `width == 1` guard is what distinguishes a decode failure from a
			// correctly encoded U+FFFD, which decodes with width 3 and is
			// escaped as `�` below.
			if width == 1 && r == utf8.RUNE_ERROR {
				io.write_string(w, `\x`) or_return
				io.write_byte(w, JSON_HEX_DIGITS[b >> 4]) or_return
				io.write_byte(w, JSON_HEX_DIGITS[b & 0xf]) or_return
			} else {
				json_write_escaped_rune(w, r) or_return
			}
			i += width
		}

		start = i
	}

	if start < len(s) {
		io.write_string(w, s[start:]) or_return
	}

	io.write_byte(w, '"') or_return
	return
}

// json_write_escaped_ascii handles the single-byte cases the fast path rejects:
// the quote, the backslash, the C0 controls, and 0x7F.
@(private)
json_write_escaped_ascii :: proc(w: io.Writer, b: byte) -> (err: io.Error) {
	switch b {
	case '"':
		io.write_string(w, `\"`) or_return
		return
	case '\\':
		io.write_string(w, `\\`) or_return
		return

	// The five controls core spells with a short escape when `for_json` is set.
	// `\a`, `\v` and `\e` are NOT in this list — core reaches them through its
	// `r < 32 && for_json` branch, whose default arm writes `\u000X`. Spelling
	// them short here would be a silent wire change.
	case '\b':
		io.write_string(w, `\b`) or_return
		return
	case '\f':
		io.write_string(w, `\f`) or_return
		return
	case '\n':
		io.write_string(w, `\n`) or_return
		return
	case '\r':
		io.write_string(w, `\r`) or_return
		return
	case '\t':
		io.write_string(w, `\t`) or_return
		return
	}

	if b < 0x20 {
		io.write_string(w, `\u00`) or_return
		io.write_byte(w, JSON_HEX_DIGITS[b >> 4]) or_return
		io.write_byte(w, JSON_HEX_DIGITS[b & 0xf]) or_return
		return
	}

	// 0x7F, the only remaining byte the fast path rejects.
	return json_write_u16_escape(w, u16(b))
}

// json_write_escaped_rune handles a decoded rune at or above U+0080.
@(private)
json_write_escaped_rune :: proc(w: io.Writer, r: rune) -> (err: io.Error) {
	// core's `is_printable` admits U+00A1..U+00FF except the soft hyphen
	// (U+00AD) and writes those raw. Everything else above ASCII — including
	// U+0080..U+00A0 and every rune above U+00FF — is escaped.
	if r >= 0xa1 && r <= 0xff && r != 0xad {
		io.write_rune(w, r) or_return
		return
	}

	c := r
	if c > utf8.MAX_RUNE {
		c = 0xfffd
	}

	if c < 0x10000 {
		return json_write_u16_escape(w, u16(c))
	}

	// Above the BMP, core encodes the surrogate pair as two `\uXXXX` escapes
	// when `for_json` is set.
	buf: [2]u16
	utf16.encode(buf[:], []rune{c})
	for unit in buf {
		json_write_u16_escape(w, unit) or_return
	}
	return
}

// json_write_u16_escape writes `\uXXXX`, most significant nibble first.
@(private)
json_write_u16_escape :: proc(w: io.Writer, v: u16) -> (err: io.Error) {
	io.write_string(w, `\u`) or_return
	for shift := uint(12); ; shift -= 4 {
		io.write_byte(w, JSON_HEX_DIGITS[(v >> shift) & 0xf]) or_return
		if shift == 0 {
			break
		}
	}
	return
}
