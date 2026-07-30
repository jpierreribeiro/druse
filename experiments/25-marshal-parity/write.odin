package main

// The scalar writers the prototype marshaller needs, each reproducing a
// `core:io` procedure byte-for-byte while writing into a `strings.Builder`
// instead of through the `io.Writer` vtable.
//
// TWO ESCAPE MODES, and the asymmetry is core's, not ours. A string VALUE is
// written with `for_json = true`; an object KEY is written with the default
// `for_json = false`, because `opt_write_key` calls
// `io.write_quoted_string(w, name)` and passes nothing. The two disagree for
// every byte below 0x20 that is not one of `\b \f \n \r \t`, and for every rune
// above the BMP. Reproduced here so the difference is measurable rather than
// accidental — see the header of marshal.odin for what it costs.

import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

@(rodata)
HEX := [16]byte{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

// druse_write_quoted_string is `io.write_quoted_string(w, s, '"', nil, for_json)`
// with an ASCII fast path: scan to the first byte that needs an escape, copy the
// run in one move, and pay the slow path only from there.
druse_write_quoted_string :: proc(b: ^strings.Builder, s: string, for_json: bool) {
	strings.write_byte(b, '"')

	start, i := 0, 0
	for i < len(s) {
		c := s[i]
		if c >= 0x20 && c < 0x7f && c != '"' && c != '\\' {
			i += 1
			continue
		}
		if start < i {
			strings.write_string(b, s[start:i])
		}

		if c < utf8.RUNE_SELF {
			druse_write_escaped_rune(b, rune(c), for_json)
			i += 1
		} else {
			r, width := utf8.decode_rune_in_string(s[i:])
			if width == 1 && r == utf8.RUNE_ERROR {
				strings.write_string(b, `\x`)
				strings.write_byte(b, HEX[c >> 4])
				strings.write_byte(b, HEX[c & 0xf])
			} else {
				druse_write_escaped_rune(b, r, for_json)
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

druse_write_escaped_rune_for_json :: proc(b: ^strings.Builder, r: rune) {
	druse_write_escaped_rune(b, r, true)
}

// druse_write_escaped_rune is `io.write_escaped_rune(w, r, '"', false, nil, for_json)`.
druse_write_escaped_rune :: proc(b: ^strings.Builder, r: rune, for_json: bool) {
	if r == '"' || r == '\\' {
		strings.write_byte(b, '\\')
		strings.write_byte(b, byte(r))
		return
	}

	// core's `is_printable`: 0x20..0x7E, and 0xA1..0xFF except the soft hyphen.
	if druse_is_printable(r) {
		buf, width := utf8.encode_rune(r)
		strings.write_bytes(b, buf[:width])
		return
	}

	if r < 32 && for_json {
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
			strings.write_byte(b, HEX[(r >> 4) & 0xf])
			strings.write_byte(b, HEX[r & 0xf])
		}
		return
	}

	// The `for_json = false` arm, and the tail every non-printable rune above
	// 31 reaches in both modes.
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
		strings.write_byte(b, HEX[byte(c) >> 4])
		strings.write_byte(b, HEX[byte(c) & 0xf])
		return
	}
	if c > utf8.MAX_RUNE {
		c = 0xfffd
	}
	if c < 0x10000 {
		druse_write_u16_escape(b, u16(c))
		return
	}
	if for_json {
		d := c - 0x10000
		druse_write_u16_escape(b, u16(0xd800 + (d >> 10)))
		druse_write_u16_escape(b, u16(0xdc00 + (d & 0x3ff)))
	} else {
		strings.write_string(b, `\U`)
		for shift := uint(28); ; shift -= 4 {
			strings.write_byte(b, HEX[(u32(c) >> shift) & 0xf])
			if shift == 0 {
				break
			}
		}
	}
}

druse_is_printable :: proc(r: rune) -> bool {
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

druse_write_u16_escape :: proc(b: ^strings.Builder, v: u16) {
	strings.write_string(b, `\u`)
	strings.write_byte(b, HEX[(v >> 12) & 0xf])
	strings.write_byte(b, HEX[(v >> 8) & 0xf])
	strings.write_byte(b, HEX[(v >> 4) & 0xf])
	strings.write_byte(b, HEX[v & 0xf])
}

// druse_write_float is `io.write_f16/f32/f64`, whose precision and bit size are
// derived from the ORIGINAL width — 4/16 for f16, 8/32 for f32, 16/64 for f64.
// That is where `1.5` becomes `1.5000000000000000`: sixteen decimals is a
// formatting choice of this code path, not a precision requirement, and it is
// the reason a Druse `/json/medium` document is 960 bytes larger than its peers'.
druse_write_float :: proc(b: ^strings.Builder, val: f64, precision: int, bit_size: int) {
	buf: [386]byte
	str := strconv.write_float(buf[1:], val, 'f', precision, bit_size)
	s := buf[:len(str) + 1]
	if s[1] == '+' || s[1] == '-' {
		s = s[1:]
	} else {
		s[0] = '+'
	}
	if s[0] == '+' {
		s = s[1:]
	}
	strings.write_bytes(b, s)
}
