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
// WHY IT WRITES TO A `strings.Builder` AND NOT AN `io.Writer`. The first version
// of this file took an `io.Writer`, and the gate rejected it: that signature
// added `core:io` to `web`'s direct-import set, which is a frozen manifest
// (`build/phase1-direct-dependencies.txt`), and it kept the very indirection the
// fast path exists to remove. `strings.write_byte`, `write_bytes` and
// `write_string` append straight to the Builder's backing array — they return an
// `int`, cannot fail, and dispatch through nothing. The one Builder procedure
// that does reach `io` is `strings.write_rune`, so this file encodes runes with
// `utf8.encode_rune` and writes the bytes instead. Net effect: one new direct
// dependency (`core:unicode/utf8`, Amendment 40) rather than three, and a
// shorter path than the version that was measured at 5.5x-7.7x.
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
// differential test in `tests/enc1-quoted-string` proves the equivalence over
// every rune in the Unicode range and every possible byte, and it is the reason
// this file may be trusted.
//
// ONE DECODER, NOT TWO. `core:unicode/utf8` does the decoding here rather than a
// hand-rolled scanner, for the same reason `web/json_decode.odin` refuses to
// implement a second JSON grammar: two decoders that can disagree about the same
// bytes is a defect waiting for an input nobody thought of. The fast path skips
// the decoder for ASCII; it does not replace it.
//
// SCOPE. This is the primitive only. Routing the marshaller's four string sites
// through it requires Druse to own the marshal walk, because
// `core:encoding/json` calls `io.write_quoted_string` directly and offers no
// hook — that is the next work package, and it is the one that also unlocks
// float rendering (~6.8%, and the reason `/json/medium` is not comparable).
package web
// druse:file application

import "core:strings"
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

// json_write_quoted_string writes a string VALUE, matching
// `io.write_quoted_string(w, s, '"', nil, for_json = true)`.
@(private)
json_write_quoted_string :: proc(b: ^strings.Builder, s: string) {
	json_write_quoted(b, s, for_json = true)
}

// json_write_quoted_key writes an OBJECT KEY, matching
// `io.write_quoted_string(w, name)` — the call `opt_write_key` makes, whose
// `for_json` argument defaults to FALSE.
//
// THE ASYMMETRY IS THE STDLIB'S, AND IT IS REPRODUCED ON PURPOSE. The same
// U+0007 comes out `` in a value and `\a` in a key, and `\a` is not a
// JSON escape (RFC 8259 §7 admits only `" \ / b f n r t uXXXX`). Worse,
// `encoding_json.is_valid` — the validator the response path uses as its last
// line of defence — does not apply escape rules inside keys, so it passes such
// a body. Measured, not inferred: `experiments/25-marshal-parity` records
// `{"k\ax":"vy"}` as what the stdlib emits and `is_valid` answering true.
//
// Reproducing it keeps this file a faster way to emit the SAME bytes. Whether
// Druse should diverge is a wire-behaviour question with its own evidence and
// its own ADR, and it must not ride along inside a performance change.
@(private)
json_write_quoted_key :: proc(b: ^strings.Builder, s: string) {
	json_write_quoted(b, s, for_json = false)
}

// json_write_escaped_rune_value writes one rune the way a string VALUE would
// spell it, without the surrounding quotes. The stdlib's `Type_Info_Rune` arm
// calls `io.write_escaped_rune(w, r, '"', for_json = true)` between two quote
// bytes, and this is that call.
@(private)
json_write_escaped_rune_value :: proc(b: ^strings.Builder, r: rune) {
	json_write_escaped_rune(b, r, for_json = true)
}

// json_write_quoted is the shared implementation.
//
// The loop holds one invariant: `s[start:i]` is a run of bytes that need no
// escaping and may be copied verbatim. Every exit from the fast path flushes
// that run before doing anything else, and re-opens it after.
@(private)
json_write_quoted :: proc(b: ^strings.Builder, s: string, for_json: bool) {
	strings.write_byte(b, '"')

	start, i := 0, 0
	for i < len(s) {
		c := s[i]

		// The fast path. A byte is copied verbatim exactly when core would have
		// written it unchanged: printable ASCII (0x20..0x7E) that is neither the
		// quote nor the backslash. 0x7F is excluded because core does not
		// consider it printable and escapes it as ``.
		if c >= 0x20 && c < 0x7f && c != '"' && c != '\\' {
			i += 1
			continue
		}

		if start < i {
			strings.write_string(b, s[start:i])
		}

		if c < utf8.RUNE_SELF {
			json_write_escaped_rune(b, rune(c), for_json)
			i += 1
		} else {
			r, width := utf8.decode_rune_in_string(s[i:])

			// An invalid UTF-8 byte. core emits `\xHH` here, which is NOT valid
			// JSON; it is reproduced because equivalence is the contract. The
			// `width == 1` guard is what distinguishes a decode failure from a
			// correctly encoded U+FFFD, which decodes with width 3 and is
			// escaped as `�` below.
			if width == 1 && r == utf8.RUNE_ERROR {
				strings.write_string(b, `\x`)
				strings.write_byte(b, JSON_HEX_DIGITS[c >> 4])
				strings.write_byte(b, JSON_HEX_DIGITS[c & 0xf])
			} else {
				json_write_escaped_rune(b, r, for_json)
			}
			i += width
		}

		start = i
	}

	if start < len(s) {
		strings.write_string(b, s[start:])
	}

	strings.write_byte(b, '"')
}

// json_write_escaped_rune is `io.write_escaped_rune(w, r, '"', false, nil, for_json)`.
//
// The two modes diverge in exactly two places, and both are on the wire:
//
//	byte < 0x20 that is not \b \f \n \r \t   value: `\u00XX`   key: `\a` `\v` `\e` or `\xHH`
//	rune above the BMP                       value: surrogate pair   key: `\UXXXXXXXX`
@(private)
json_write_escaped_rune :: proc(b: ^strings.Builder, r: rune, for_json: bool) {
	if r == '"' || r == '\\' {
		strings.write_byte(b, '\\')
		strings.write_byte(b, byte(r))
		return
	}

	// core's `is_printable` admits 0x20..0x7E and U+00A1..U+00FF except the
	// soft hyphen (U+00AD), and writes those raw. Everything else is escaped.
	if json_rune_is_printable(r) {
		buf, width := utf8.encode_rune(r)
		strings.write_bytes(b, buf[:width])
		return
	}

	if r < 32 && for_json {
		// The five controls core spells short in JSON mode. `\a`, `\v` and
		// `\e` are NOT here — in JSON mode core reaches them through this
		// arm's default and writes `\u000X`. Spelling them short would be a
		// silent wire change.
		switch r {
		case '\b':
			strings.write_string(b, `\b`)
		case '\f':
			strings.write_string(b, `\f`)
		case '\n':
			strings.write_string(b, `\n`)
		case '\r':
			strings.write_string(b, `\r`)
		case '\t':
			strings.write_string(b, `\t`)
		case:
			strings.write_string(b, `\u00`)
			strings.write_byte(b, JSON_HEX_DIGITS[(r >> 4) & 0xf])
			strings.write_byte(b, JSON_HEX_DIGITS[r & 0xf])
		}
		return
	}

	// The non-JSON arm, and the tail every non-printable rune at or above 32
	// reaches in BOTH modes.
	switch r {
	case '\a':
		strings.write_string(b, `\a`)
		return
	case '\b':
		strings.write_string(b, `\b`)
		return
	case '\e':
		strings.write_string(b, `\e`)
		return
	case '\f':
		strings.write_string(b, `\f`)
		return
	case '\n':
		strings.write_string(b, `\n`)
		return
	case '\r':
		strings.write_string(b, `\r`)
		return
	case '\t':
		strings.write_string(b, `\t`)
		return
	case '\v':
		strings.write_string(b, `\v`)
		return
	}

	c := r
	if c < ' ' {
		strings.write_string(b, `\x`)
		strings.write_byte(b, JSON_HEX_DIGITS[byte(c) >> 4])
		strings.write_byte(b, JSON_HEX_DIGITS[byte(c) & 0xf])
		return
	}
	if c > utf8.MAX_RUNE {
		c = 0xfffd
	}
	if c < 0x10000 {
		json_write_u16_escape(b, u16(c))
		return
	}

	if for_json {
		// Above the BMP, JSON mode writes the UTF-16 surrogate pair. The split
		// is the standard formula, written out rather than imported: one frozen
		// dependency for six lines of arithmetic is not a trade worth making.
		d := c - 0x10000
		json_write_u16_escape(b, u16(0xd800 + (d >> 10)))
		json_write_u16_escape(b, u16(0xdc00 + (d & 0x3ff)))
		return
	}

	strings.write_string(b, `\U`)
	for shift := uint(28); ; shift -= 4 {
		strings.write_byte(b, JSON_HEX_DIGITS[(u32(c) >> shift) & 0xf])
		if shift == 0 {
			break
		}
	}
}

// json_rune_is_printable is core's `is_printable`, which decides which runes go
// on the wire raw.
@(private)
json_rune_is_printable :: proc(r: rune) -> bool {
	if r <= 0xff {
		switch r {
		case 0x20 ..= 0x7e:
			return true
		case 0xa1 ..= 0xff:
			return r != 0xad
		}
	}
	return false
}

// json_write_u16_escape writes `\uXXXX`, most significant nibble first.
@(private)
json_write_u16_escape :: proc(b: ^strings.Builder, v: u16) {
	strings.write_string(b, `\u`)
	strings.write_byte(b, JSON_HEX_DIGITS[(v >> 12) & 0xf])
	strings.write_byte(b, JSON_HEX_DIGITS[(v >> 8) & 0xf])
	strings.write_byte(b, JSON_HEX_DIGITS[(v >> 4) & 0xf])
	strings.write_byte(b, JSON_HEX_DIGITS[v & 0xf])
}
