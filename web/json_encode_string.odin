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

// json_write_quoted_string writes `s` as a quoted JSON string, producing bytes
// identical to `io.write_quoted_string(w, s, '"', nil, true)`.
//
// The loop holds one invariant: `s[start:i]` is a run of bytes that need no
// escaping and may be copied verbatim. Every exit from the fast path flushes
// that run before doing anything else, and re-opens it after.
@(private)
json_write_quoted_string :: proc(b: ^strings.Builder, s: string) {
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
			json_write_escaped_ascii(b, c)
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
				json_write_escaped_rune(b, r)
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

// json_write_escaped_ascii handles the single-byte cases the fast path rejects:
// the quote, the backslash, the C0 controls, and 0x7F.
@(private)
json_write_escaped_ascii :: proc(b: ^strings.Builder, c: byte) {
	switch c {
	case '"':
		strings.write_string(b, `\"`)
		return
	case '\\':
		strings.write_string(b, `\\`)
		return

	// The five controls core spells with a short escape when `for_json` is set.
	// `\a`, `\v` and `\e` are NOT in this list — core reaches them through its
	// `r < 32 && for_json` branch, whose default arm writes `\u000X`. Spelling
	// them short here would be a silent wire change.
	case '\b':
		strings.write_string(b, `\b`)
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
	}

	if c < 0x20 {
		strings.write_string(b, `\u00`)
		strings.write_byte(b, JSON_HEX_DIGITS[c >> 4])
		strings.write_byte(b, JSON_HEX_DIGITS[c & 0xf])
		return
	}

	// 0x7F, the only remaining byte the fast path rejects.
	json_write_u16_escape(b, u16(c))
}

// json_write_escaped_rune handles a decoded rune at or above U+0080.
@(private)
json_write_escaped_rune :: proc(b: ^strings.Builder, r: rune) {
	// core's `is_printable` admits U+00A1..U+00FF except the soft hyphen
	// (U+00AD) and writes those raw. Everything else above ASCII — including
	// U+0080..U+00A0 and every rune above U+00FF — is escaped.
	if r >= 0xa1 && r <= 0xff && r != 0xad {
		buf, width := utf8.encode_rune(r)
		strings.write_bytes(b, buf[:width])
		return
	}

	c := r
	if c > utf8.MAX_RUNE {
		c = 0xfffd
	}

	if c < 0x10000 {
		json_write_u16_escape(b, u16(c))
		return
	}

	// Above the BMP, core encodes the surrogate pair as two `\uXXXX` escapes
	// when `for_json` is set. The split is the UTF-16 formula, written out
	// rather than imported: one dependency for six lines of arithmetic is a
	// dependency the freeze manifest would have to carry for ever.
	c -= 0x10000
	json_write_u16_escape(b, u16(0xd800 + (c >> 10)))
	json_write_u16_escape(b, u16(0xdc00 + (c & 0x3ff)))
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
