// WP22 internal behavior tests — the fixed line buffer, the escaper, and the
// truncation contract.
//
// This file declares `package web` but does NOT live in `web/`: the line
// buffer, its bounds, the escaper and the commit-guard helper are all
// package-private, and on the pinned toolchain an `@(test)` procedure must be
// compiled as part of the package it tests. `build/check.sh` assembles a
// THROWAWAY package from the real `web/` sources plus this file, exactly as it
// does for WP2-WP21.
//
// WHY THESE TESTS ARE INTERNAL. Three WP22 contracts cannot be observed from
// outside the package:
//
//   - the BOUND itself: `LOGGER_LINE_MAX` is private, and "the line never
//     exceeds the buffer" is a claim about a number no external test can name;
//   - the escaper's per-byte widths, which are what make the truncation cut
//     land on a unit boundary rather than inside a half-written escape;
//   - the commit guard the status field consults, read from the private
//     `Response` before teardown.
//
// TRUNCATION IS THE POINT OF THIS FILE. A fixed buffer has a boundary, and what
// happens at that boundary is a contract, not an implementation detail. The two
// dishonest options are both excluded by a test here: growing the buffer would
// defeat the fixed buffer and re-import the per-request allocation it exists to
// avoid, and dropping the line without a signal would make the logger quietly
// lie about traffic it saw. The framework truncates, and SAYS SO in the line.
package web

import "core:log"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// Capture (the same copying, forwarding logger the public suite uses; see the
// note there — a swallow-everything logger stops `testing.expect` reporting).
// ---------------------------------------------------------------------------

WP22_LINES :: 8
WP22_BYTES :: 1024

Wp22_Capture :: struct {
	inner:   log.Logger,
	count:   int,
	lines:   [WP22_LINES][WP22_BYTES]u8,
	lengths: [WP22_LINES]int,
}

wp22_capture_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Wp22_Capture)(data)
	if strings.has_prefix(text, "druse: ") {
		if level == .Info && record.count < WP22_LINES {
			n := copy(record.lines[record.count][:], text)
			record.lengths[record.count] = n
			record.count += 1
		}
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

wp22_capture_logger :: proc(record: ^Wp22_Capture) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = wp22_capture_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

wp22_captured :: proc(record: ^Wp22_Capture, i: int) -> string {
	if i < 0 || i >= record.count {
		return ""
	}
	return string(record.lines[i][:record.lengths[i]])
}

wp22_ok :: proc(ctx: ^Context) {
	text(ctx, .OK, "ok")
}

// ---------------------------------------------------------------------------
// The bound.
// ---------------------------------------------------------------------------

@(test)
wp22_line_never_exceeds_the_fixed_buffer :: proc(t: ^testing.T) {
	// A pattern far longer than the whole line budget. It is a legal pattern:
	// `pattern_classify` accepts anything beginning with `/` that names at most
	// one parameter, and WP4 deliberately reports nothing about the rest.
	long: [600]u8
	long[0] = '/'
	for i in 1 ..< len(long) {
		long[i] = 'a'
	}

	cap: Wp22_Capture
	context.logger = wp22_capture_logger(&cap)

	a := app()
	defer destroy(&a)
	use(&a, logger)
	get(&a, string(long[:]), wp22_ok)

	_ = test_request(&a, .GET, string(long[:]))

	testing.expect_value(t, cap.count, 1)
	line := wp22_captured(&cap, 0)
	testing.expect(
		t,
		len(line) <= LOGGER_LINE_MAX,
		"the composed line must never exceed the fixed buffer",
	)
}

@(test)
wp22_truncation_is_announced_in_the_line :: proc(t: ^testing.T) {
	// Never grown silently, never dropped silently: the line SAYS it was cut.
	// This is the assertion that makes the boundary a contract.
	long: [600]u8
	long[0] = '/'
	for i in 1 ..< len(long) {
		long[i] = 'b'
	}

	cap: Wp22_Capture
	context.logger = wp22_capture_logger(&cap)

	a := app()
	defer destroy(&a)
	use(&a, logger)
	get(&a, string(long[:]), wp22_ok)

	_ = test_request(&a, .GET, string(long[:]))

	testing.expect_value(t, cap.count, 1)
	line := wp22_captured(&cap, 0)

	testing.expect(
		t,
		strings.contains(line, LOGGER_TRUNCATED),
		"a truncated route field must carry the truncation mark",
	)

	// The line stays WELL-FORMED: the status is the last field, so a truncated
	// pattern never costs the reader the outcome of the request.
	testing.expect(
		t,
		strings.has_suffix(line, " 200"),
		"truncation must not swallow the status field",
	)
	testing.expect(t, strings.has_prefix(line, "druse: GET "), "the prefix survives truncation")
}

@(test)
wp22_a_pattern_that_fits_is_not_marked :: proc(t: ^testing.T) {
	// The POSITIVE half of the truncation contract: an ordinary pattern must
	// come through whole and unmarked. A logger that marked every line would
	// pass the test above while telling the truth about nothing.
	cap: Wp22_Capture
	context.logger = wp22_capture_logger(&cap)

	a := app()
	defer destroy(&a)
	use(&a, logger)
	get(&a, "/inventory/:sku", wp22_ok)

	_ = test_request(&a, .GET, "/inventory/AB-1234")

	testing.expect_value(t, cap.count, 1)
	testing.expect_value(t, wp22_captured(&cap, 0), "druse: GET /inventory/:sku 200")
	testing.expect(
		t,
		!strings.contains(wp22_captured(&cap, 0), LOGGER_TRUNCATED),
		"a pattern that fits must not be marked as truncated",
	)
}

// ---------------------------------------------------------------------------
// The escaper.
// ---------------------------------------------------------------------------

@(test)
wp22_escape_widths_are_exact :: proc(t: ^testing.T) {
	// The widths the truncation cut relies on. If these drift, the cut can land
	// inside a half-written escape and emit a byte sequence nothing can read.
	testing.expect_value(t, logger_escaped_width('a'), 1)
	testing.expect_value(t, logger_escaped_width('/'), 1)
	testing.expect_value(t, logger_escaped_width(':'), 1)
	testing.expect_value(t, logger_escaped_width('\r'), 2)
	testing.expect_value(t, logger_escaped_width('\n'), 2)
	testing.expect_value(t, logger_escaped_width('\\'), 2)
	testing.expect_value(t, logger_escaped_width(0x00), 4)
	testing.expect_value(t, logger_escaped_width(0x1F), 4)
	testing.expect_value(t, logger_escaped_width(0x7F), 4)
}

@(test)
wp22_control_bytes_are_escaped_in_hex :: proc(t: ^testing.T) {
	cap: Wp22_Capture
	context.logger = wp22_capture_logger(&cap)

	a := app()
	defer destroy(&a)
	use(&a, logger)
	get(&a, "/tab\there", wp22_ok)

	_ = test_request(&a, .GET, "/tab\there")

	testing.expect_value(t, cap.count, 1)
	testing.expect_value(t, wp22_captured(&cap, 0), "druse: GET /tab\\x09here 200")
}

@(test)
wp22_truncation_never_splits_an_escape :: proc(t: ^testing.T) {
	// A pattern made entirely of CR bytes: every unit is two bytes wide, so a
	// cut that ignored unit boundaries would land inside one for at least one
	// budget parity. The escaped field must contain only whole `\r` units.
	crs: [600]u8
	crs[0] = '/'
	for i in 1 ..< len(crs) {
		crs[i] = '\r'
	}

	cap: Wp22_Capture
	context.logger = wp22_capture_logger(&cap)

	a := app()
	defer destroy(&a)
	use(&a, logger)
	get(&a, string(crs[:]), wp22_ok)

	_ = test_request(&a, .GET, string(crs[:]))

	testing.expect_value(t, cap.count, 1)
	line := wp22_captured(&cap, 0)

	testing.expect(t, len(line) <= LOGGER_LINE_MAX, "the bound holds for the widest units too")
	testing.expect(t, !strings.contains(line, "\r"), "no raw CR survives")

	// Every backslash must begin a complete `\r` unit: a dangling trailing
	// backslash is exactly the half-written escape this test exists to exclude.
	body := line[len("druse: GET "):]
	cut := strings.index(body, LOGGER_TRUNCATED)
	testing.expect(t, cut > 0, "this pattern must truncate")
	// Every pattern begins with `/` — that one byte is the leading unit, and
	// everything after it is two-byte `\r` units.
	field := body[:cut]
	testing.expect(t, field[0] == '/', "the pattern's leading slash survives")
	rest := field[1:]
	testing.expect(t, len(rest) % 2 == 0, "the escaped CR field must be whole two-byte units")
	for i := 0; i < len(rest); i += 2 {
		testing.expect(t, rest[i] == '\\' && rest[i + 1] == 'r', "only whole \\r units")
	}
}

// ---------------------------------------------------------------------------
// The commit guard (audit R-9).
// ---------------------------------------------------------------------------

@(test)
wp22_status_field_consults_the_commit_guard :: proc(t: ^testing.T) {
	// The logger reads response state, so it asks the guard whether there IS a
	// response before believing the status field. An uncommitted `Response`
	// holds the zero `Status`, and reporting that number as an outcome would be
	// the framework inventing a value it never sent.
	ctx: Context
	status, committed := logger_status(&ctx)
	testing.expect(t, !committed, "a fresh Context has committed nothing")

	response_commit(&ctx.private.response, .Created, nil, nil)
	status, committed = logger_status(&ctx)
	testing.expect(t, committed, "after a commit the guard reports one")
	testing.expect_value(t, status, Status.Created)
}
