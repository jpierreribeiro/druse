// WP22 — THE `logger` MIDDLEWARE: one line per request, through
// `context.logger`, out of a fixed buffer.
//
// THE CONSTRAINT THAT DESIGNED THIS FILE. WP6 measured that importing
// `core:log` adds ~37 KiB to EVERY application, because Odin links an imported
// package whether or not anything references it. A logging middleware that
// imported a logging package would therefore charge the 37 KiB to applications
// that never log. So this file imports NOTHING: it writes through
// `context.logger` — the logger the application already has — composes its line
// into a fixed buffer, and encodes its one integer by hand. `core:fmt` is
// excluded for the same measured reason, and the escaper below is the WP5
// precedent applied at a smaller scale.
//
// THE LINE, and every field of it is a decision with a test:
//
//	druse: GET /orders/:id 200      a routed request
//	druse: GET - 404                a miss: no pattern exists, so none is shown
//	druse: GET /silent -            nothing was committed while we watched
//
// ROUTE, NEVER PATH. The field is the REGISTERED PATTERN, the same
// low-cardinality identity §6.2 imposes on `Framework_Event`, and for the same
// two reasons: the raw path is attacker-chosen text, and unbounded cardinality
// breaks whatever consumes the log. On a miss there is no pattern, so the field
// is `-`. It never falls back to the path — the traffic most worth logging is
// exactly the traffic whose path you least want to echo.
//
// NOTHING ELSE FROM THE REQUEST. No query, no header name, no header value, no
// body byte, no captured parameter value. The whole variable surface of this
// line is one App-owned pattern, and even that is escaped.
//
// IT RUNS POST-`next`. That is what makes the status a READING rather than a
// prediction, and it is the concrete case ADR-022 B1 was accepted for. The
// consequence is stated rather than hidden: the driver's 500 finalization for a
// handler that committed nothing happens AFTER dispatch returns — after this
// middleware's frame is gone — so such a request logs `-`, and the framework
// reports that failure through the WP20 observer, which is the channel that
// does see it.
//
// OWNERSHIP, and why audit R-9 does not apply here. R-9's hazard is a
// request-local scratch buffer ALIASED by the committed response: six
// hand-written guards are all that stop a later write from rewriting bytes a
// committed response still points at. This file does not create a seventh
// guard, and it does not create a seventh aliasable buffer either — it composes
// into a STACK buffer that no response can ever reference, the
// `mw_poison_use_after_route` precedent, and hands the string to
// `context.logger` synchronously. What it DOES do is consult the commit guard
// before believing response state, through the single helper `logger_status`
// below, because reading an uncommitted `Response`'s zero `Status` and printing
// it as an outcome would be the framework inventing a number it never sent.
package web
// druse:file application

// logger writes one line per request to `context.logger`, at `.Info` level,
// after the rest of the chain has run.
//
// It is OPT-IN and there is no default-on logging:
//
//	web.use(&app, web.logger)
//
// Registering it is subject to the ordinary ADR-019 rule — every `use` comes
// before the first route. It observes misses as well as routed requests
// (ADR-023), so a 404 and a 405 are logged too.
//
// WHAT IT LOGS: the method, the registered route pattern (`-` on a miss), and
// the committed status (`-` if the chain committed nothing). WHAT IT NEVER
// LOGS: the raw path, the query string, any header, any body byte, or any
// captured path-parameter value. That list is a contract, not a current
// behaviour — `tests/wp22-public-surface` asserts the exact bytes of the line.
//
// COST: no allocation, no import, and one fixed-size stack buffer per logged
// request. An application that never names `web.logger` links ZERO logger
// symbols — measured with `nm` against a positive control by
// `build/check_wp22_controls.sh` control 7. The plan asked for a stronger
// claim, "the binary is byte-identical to the baseline"; that one is not
// testable on the pinned toolchain, which does not build reproducibly (five
// builds of an IDENTICAL tree produced five distinct binaries — the vendored
// `nbio`'s polymorphic instantiations carry run-varying mangled names). The
// symbol count is stable and is what is asserted.
//
// A line longer than the buffer is TRUNCATED and says so — see
// `LOGGER_TRUNCATED`.
logger :: proc(ctx: ^Context) {
	next(ctx)

	handle := context.logger
	if handle.procedure == nil {
		// No logger installed: there is nothing to write to, and inventing a
		// sink would be a policy this middleware has no business choosing.
		return
	}

	buf: [LOGGER_LINE_MAX]u8
	n := logger_compose(ctx, buf[:])
	handle.procedure(handle.data, .Info, string(buf[:n]), handle.options, #location(logger))
}

// ---------------------------------------------------------------------------
// The line's shape, as constants the tests can name.
// ---------------------------------------------------------------------------

// LOGGER_PREFIX marks the line as framework output, exactly like the six
// diagnostics. It is what lets an application's own logger route or filter
// framework lines without parsing them.
@(private)
LOGGER_PREFIX :: "druse: "

// LOGGER_ABSENT is the field value for something the framework cannot supply:
// the route on a miss, the status when nothing was committed. It is one byte
// that can never be confused with a pattern (every pattern starts with `/`) or
// with a status (every status is three digits).
@(private)
LOGGER_ABSENT :: "-"

// LOGGER_METHOD_MAX is the longest token `method_token` returns (`DELETE`).
@(private)
LOGGER_METHOD_MAX :: 6

// LOGGER_STATUS_MAX bounds the status field: every member of `Status` is a
// three-digit code, and the absent form is shorter.
@(private)
LOGGER_STATUS_MAX :: 3

// LOGGER_ROUTE_MAX bounds the ESCAPED route field — the only variable-length
// part of the line. 128 bytes is generous for a route pattern (the longest in
// any example here is under 30) and it is what keeps the whole line inside a
// cache-line-friendly stack buffer.
@(private)
LOGGER_ROUTE_MAX :: 128

// LOGGER_TRUNCATED is the mark a cut route field ends with.
//
// IT IS THE POINT OF THE FIXED BUFFER, not a detail of it. A bounded resource
// states what it does when full, and the two silent alternatives are both
// dishonest: growing the buffer would defeat the fixed buffer and re-import the
// per-request allocation it exists to avoid, and dropping the line would make
// the logger quietly lie about traffic it saw. So the line is cut, and it says
// so, and the status still comes after the mark — a truncated pattern never
// costs the reader the outcome of the request.
@(private)
LOGGER_TRUNCATED :: "...[truncated]"

// LOGGER_LINE_MAX is the exact worst case, derived rather than guessed:
// prefix + method + ' ' + route + ' ' + status.
@(private)
LOGGER_LINE_MAX ::
	len(LOGGER_PREFIX) + LOGGER_METHOD_MAX + 1 + LOGGER_ROUTE_MAX + 1 + LOGGER_STATUS_MAX

// The truncation mark must fit inside the field it marks, or a pattern long
// enough to need the mark could not carry it.
#assert(len(LOGGER_TRUNCATED) < LOGGER_ROUTE_MAX)

// ---------------------------------------------------------------------------
// Composition.
// ---------------------------------------------------------------------------

// logger_compose writes the whole line into `dst` and returns its length.
//
// `dst` is always `LOGGER_LINE_MAX` bytes and every field below is
// individually bounded, so no write here can overrun — the bound is structural,
// not a runtime check that could be forgotten.
@(private)
logger_compose :: proc(ctx: ^Context, dst: []u8) -> int {
	n := copy(dst, LOGGER_PREFIX)

	// Method. `.UNKNOWN` has an empty wire token (the request model gives an
	// unrecognised method no public meaning rather than rejecting it), and an
	// empty field would silently shift the line's columns, so it prints as
	// absent like any other thing the framework cannot name.
	token := method_token(ctx.request.method)
	if len(token) == 0 {
		token = LOGGER_ABSENT
	}
	n += copy(dst[n:], token)

	dst[n] = ' '
	n += 1
	n += logger_write_route(dst[n:], ctx.private.route)

	dst[n] = ' '
	n += 1
	status, committed := logger_status(ctx)
	if committed {
		n += mw_write_int(dst[n:], int(status))
	} else {
		n += copy(dst[n:], LOGGER_ABSENT)
	}

	return n
}

// logger_status is the SINGLE place this file reads response state, and it
// consults the commit guard first (audit R-9's discipline: ask the guard, do
// not read the storage and hope).
//
// An uncommitted `Response` holds the zero `Status`. Reporting that as an
// outcome would be the framework announcing a response it never sent, so the
// caller is told there is nothing to report and prints `-` instead.
@(private)
logger_status :: proc(ctx: ^Context) -> (status: Status, committed: bool) {
	if !ctx.private.response.committed {
		return {}, false
	}
	return ctx.private.response.status, true
}

// logger_write_route writes the escaped route field into `dst`, bounded by
// `LOGGER_ROUTE_MAX`, and returns the byte count written.
//
// The pattern is App-owned application text, so it is escaped: a pattern
// carrying CR/LF would otherwise forge additional log records, which is the
// log-injection half of the OWASP logging guidance. On a miss there is no
// pattern and the field is `-`.
@(private)
logger_write_route :: proc(dst: []u8, pattern: string) -> int {
	if len(pattern) == 0 {
		return copy(dst, LOGGER_ABSENT)
	}

	// Measure first, then decide. Knowing the escaped total up front is what
	// lets an ordinary pattern through UNMARKED while a long one is cut at a
	// unit boundary with room reserved for the mark — the same two-pass shape
	// the WP5 envelope escaper uses.
	total := 0
	for i in 0 ..< len(pattern) {
		total += logger_escaped_width(pattern[i])
	}

	budget := LOGGER_ROUTE_MAX
	truncating := total > budget
	if truncating {
		budget -= len(LOGGER_TRUNCATED)
	}

	n := 0
	for i in 0 ..< len(pattern) {
		width := logger_escaped_width(pattern[i])
		// Stop on a unit BOUNDARY rather than emitting a partial escape: a cut
		// inside a `\x09` would leave bytes no reader can interpret, and for a
		// two-byte unit it would leave a dangling backslash that re-opens the
		// injection this escaper closes.
		if n + width > budget {
			break
		}
		n += logger_write_escaped(dst[n:], pattern[i])
	}

	if truncating {
		n += copy(dst[n:], LOGGER_TRUNCATED)
	}
	return n
}

// logger_escaped_width is how many bytes one source byte occupies once escaped.
// It and `logger_write_escaped` must agree exactly — the truncation cut is
// computed from this function and performed by that one.
@(private)
logger_escaped_width :: proc(b: u8) -> int {
	switch b {
	case '\r', '\n', '\\':
		return 2
	}
	if b < 0x20 || b == 0x7F {
		return 4
	}
	return 1
}

// logger_write_escaped writes one escaped byte and returns its width.
//
// `\\` is escaped along with CR and LF so the encoding is UNAMBIGUOUS: without
// it, a pattern containing the two literal characters `\` and `r` would read
// back as an escaped carriage return, and a reader could not tell a forged
// record from a real one.
@(private)
logger_write_escaped :: proc(dst: []u8, b: u8) -> int {
	switch b {
	case '\r':
		dst[0] = '\\'
		dst[1] = 'r'
		return 2
	case '\n':
		dst[0] = '\\'
		dst[1] = 'n'
		return 2
	case '\\':
		dst[0] = '\\'
		dst[1] = '\\'
		return 2
	}
	if b < 0x20 || b == 0x7F {
		// Bound to a local: a string CONSTANT cannot be indexed by a runtime
		// value on this toolchain, and the compiler says so explicitly.
		hex := LOGGER_HEX
		dst[0] = '\\'
		dst[1] = 'x'
		dst[2] = hex[b >> 4]
		dst[3] = hex[b & 0x0F]
		return 4
	}
	dst[0] = b
	return 1
}

// LOGGER_HEX is lower-case on purpose: `\x09`, never `\x09` in one place and
// `\x0A` in another. One spelling is what makes a log greppable.
@(private)
LOGGER_HEX :: "0123456789abcdef"
