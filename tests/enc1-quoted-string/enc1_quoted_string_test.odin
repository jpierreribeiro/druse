// ENC1 — THE DIFFERENTIAL PROOF that Druse's quoted-string writer and
// `core:io`'s produce THE SAME BYTES.
//
// This file declares `package web` but does NOT live in `web/`:
// `json_write_quoted_string` and its three helpers are package-private, and
// `build/check.sh` assembles the usual THROWAWAY package from the real `web/`
// sources plus this file (the WP2-WP19 arrangement).
//
// WHAT THIS SUITE IS FOR, and why it is not a sample of interesting cases. The
// writer in `web/json_encode_string.odin` exists to make the encode path
// faster, and it is worth having ONLY if it is indistinguishable on the wire
// from what shipped before it. A hand-picked corpus proves that for the cases
// the author thought of, which is precisely the set of cases a bug is not in.
// So the corpus here is EXHAUSTIVE where exhaustion is possible:
//
//	every rune in the Unicode range          U+0000 .. U+10FFFF   (1,114,112)
//	every single byte, as a one-byte string  0x00 .. 0xFF                256
//	every two-byte sequence                  0x0000 .. 0xFFFF         65,536
//
// The second and third are not redundant with the first: they are the only way
// to reach INVALID UTF-8 — a lone continuation byte, a truncated multi-byte
// sequence, an over-long form — which `core:io` renders as `\xHH`, a sequence
// that is not valid JSON and that Druse must therefore reproduce exactly rather
// than repair. A writer that quietly fixed those bytes would change the wire.
//
// The oracle is the live `core:io` procedure, called with the exact arguments
// `core:encoding/json`'s marshaller uses — `quote = '"'`, `for_json = true`.
// This suite therefore keeps testing the right thing when the pinned toolchain
// moves: if a toolchain bump changes core's escaping, this goes red on the
// first byte that differs, which is the signal to look, not a silent drift.
#+private
package web

import "core:io"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

// Differ carries the two builders across a whole exhaustive sweep. They are
// created once and RESET per case: a million allocate/destroy pairs would make
// this suite's cost its own reason to delete it.
@(private = "file")
Differ :: struct {
	ours:   strings.Builder,
	theirs: strings.Builder,
}

@(private = "file")
differ_make :: proc() -> Differ {
	return Differ{ours = strings.builder_make(), theirs = strings.builder_make()}
}

@(private = "file")
differ_destroy :: proc(d: ^Differ) {
	strings.builder_destroy(&d.ours)
	strings.builder_destroy(&d.theirs)
}

// agree runs both writers over `s` and reports whether the bytes match. It
// returns the two renderings so the caller can put them in the failure message
// — "they differ" without the bytes is a bug report nobody can act on.
@(private = "file")
agree :: proc(d: ^Differ, s: string) -> (ours: string, theirs: string, ok: bool) {
	strings.builder_reset(&d.ours)
	strings.builder_reset(&d.theirs)

	// Druse writes straight into the Builder; the oracle is the live `core:io`
	// procedure over a writer backed by the SAME kind of Builder, so the only
	// thing the comparison can be sensitive to is the bytes.
	json_write_quoted_string(&d.ours, s)
	if _, err := io.write_quoted_string(strings.to_writer(&d.theirs), s, '"', nil, true);
	   err != nil {
		return "", "", false
	}

	ours = strings.to_string(d.ours)
	theirs = strings.to_string(d.theirs)
	return ours, theirs, ours == theirs
}

// ---------------------------------------------------------------------------
// The exhaustive sweeps
// ---------------------------------------------------------------------------

// Every rune in the Unicode range, each as a one-rune string.
//
// Surrogates (U+D800..U+DFFF) are NOT skipped. `utf8.encode_rune` renders them
// as something, both writers receive the same bytes, and whatever core does
// with those bytes is what Druse must do. Excluding them would be excluding the
// input most likely to expose a disagreement.
@(test)
enc1_every_rune_agrees :: proc(t: ^testing.T) {
	d := differ_make()
	defer differ_destroy(&d)

	failures := 0
	for r := rune(0); r <= utf8.MAX_RUNE; r += 1 {
		buf, width := utf8.encode_rune(r)
		ours, theirs, ok := agree(&d, string(buf[:width]))
		if !ok {
			failures += 1
			if failures <= 8 {
				testing.expectf(
					t,
					false,
					"rune U+%04X: druse wrote %q, core:io wrote %q",
					int(r),
					ours,
					theirs,
				)
			}
		}
	}
	testing.expectf(t, failures == 0, "%d runes rendered differently", failures)
}

// Every single byte, as a one-byte string. This is where the invalid-UTF-8
// `\xHH` path lives: 0x80..0xBF are lone continuation bytes and 0xC0..0xFF are
// truncated leaders, none of which the rune sweep above can produce.
@(test)
enc1_every_single_byte_agrees :: proc(t: ^testing.T) {
	d := differ_make()
	defer differ_destroy(&d)

	for b := 0; b < 256; b += 1 {
		one := [1]byte{byte(b)}
		ours, theirs, ok := agree(&d, string(one[:]))
		testing.expectf(
			t,
			ok,
			"byte 0x%02X: druse wrote %q, core:io wrote %q",
			b,
			ours,
			theirs,
		)
	}
}

// Every two-byte sequence. Covers a valid two-byte rune, a truncated
// three-byte leader, an over-long encoding, and a continuation byte following
// anything at all.
@(test)
enc1_every_two_byte_sequence_agrees :: proc(t: ^testing.T) {
	d := differ_make()
	defer differ_destroy(&d)

	failures := 0
	for hi := 0; hi < 256; hi += 1 {
		for lo := 0; lo < 256; lo += 1 {
			pair := [2]byte{byte(hi), byte(lo)}
			ours, theirs, ok := agree(&d, string(pair[:]))
			if !ok {
				failures += 1
				if failures <= 8 {
					testing.expectf(
						t,
						false,
						"bytes %02X %02X: druse wrote %q, core:io wrote %q",
						hi,
						lo,
						ours,
						theirs,
					)
				}
			}
		}
	}
	testing.expectf(t, failures == 0, "%d two-byte sequences rendered differently", failures)
}

// ---------------------------------------------------------------------------
// The shapes the fast path is actually about
// ---------------------------------------------------------------------------

// The fast path's whole job is finding the boundary between a copyable run and
// a byte that must be escaped. These cases put that boundary everywhere it can
// be: absent, at index 0, in the middle, at the last byte, and repeated with no
// copyable run between.
@(test)
enc1_run_boundaries_agree :: proc(t: ^testing.T) {
	d := differ_make()
	defer differ_destroy(&d)

	cases := []string {
		"",
		"a",
		"plain ascii with no escapes at all",
		`"`,
		`\`,
		`"leading quote`,
		`trailing quote"`,
		`mid"dle`,
		`""""`,
		"\\\\\\\\",
		"\n",
		"line\nbreak",
		"tab\tand\ttab",
		"\x00",
		"nul\x00inside",
		"\x1b[31mansi\x1b[0m",
		"\x7f",
		"del\x7fmid",
		"bell\a vertical\v escape\x1b",
		"café",           // U+00E9, a Latin-1 printable: written raw
		"na­ive",    // U+00AD soft hyphen: NOT printable, escaped
		" ",   // the unprintable end of Latin-1
		"日本語",           // above U+00FF: escaped, one \uXXXX each
		"emoji 😀 here",   // above the BMP: a surrogate pair
		"�",         // a correctly encoded replacement char, width 3
		"\xff",           // an invalid byte: \xHH
		"valid\xffmixed", // an invalid byte between copyable runs
		"a\xc3",          // a truncated two-byte leader at the end
		"long ascii run that must be copied in one move, then an escape: \" and more after it",
	}

	for s in cases {
		ours, theirs, ok := agree(&d, s)
		testing.expectf(t, ok, "%q: druse wrote %q, core:io wrote %q", s, ours, theirs)
	}
}

// A string long enough that the fast path's bulk copy is the whole cost, with
// one escape at the very end so the flush-then-escape-then-reopen sequence runs
// on a large run rather than a toy one.
@(test)
enc1_large_run_agrees :: proc(t: ^testing.T) {
	d := differ_make()
	defer differ_destroy(&d)

	big := strings.builder_make()
	defer strings.builder_destroy(&big)
	for i := 0; i < 8192; i += 1 {
		strings.write_byte(&big, byte('a' + (i % 26)))
	}
	strings.write_string(&big, "\"tail\n")

	ours, theirs, ok := agree(&d, strings.to_string(big))
	testing.expect(t, ok, "an 8 KiB run with a trailing escape rendered differently")
	testing.expect(t, len(ours) > 8192, "the rendering is implausibly short")
}
