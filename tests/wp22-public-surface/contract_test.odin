// WP22 public surface contract — `web.logger`, as an EXTERNAL consumer of
// `druse:web` sees it.
//
// WHAT THIS SUITE IS FOR. `logger` is the first framework component whose
// OUTPUT is the product: everything else is judged by the response it commits,
// and this one is judged by the line it writes. So the line is contract, and
// every property the plan names is asserted here on the exact bytes:
//
//   * one line per request, written after the handler ran (post-`next`, so the
//     status is the one that was actually committed — ADR-022 B1);
//   * a miss is logged too (the ADR-023 miss chain), because a logger that
//     cannot see hostile traffic is the hole an attacker probes;
//   * the route PATTERN, never the raw path — the same low-cardinality identity
//     rule §6.2 imposes on `Framework_Event`;
//   * no query byte, no header byte, no body byte, ever;
//   * opt-in: an application that does not `use` it logs nothing (G-08 forbids
//     inventing a default).
//
// The suite captures `context.logger` rather than reading a file, because
// writing through `context.logger` IS the mechanism (WP6 measured `core:log` at
// ~37 KiB on every application, referenced or not).
package test_wp22_public

import "core:log"
import "core:strings"
import "core:testing"
import web "druse:web"

// ---------------------------------------------------------------------------
// The capture logger.
//
// It COPIES each captured line into its own fixed storage. `text` is a view
// over the emitter's buffer and does not outlive the call — retaining the view
// would read whatever the next request writes there, which is precisely the
// lifetime bug this framework spends its comments on.
//
// Everything that is not ours is FORWARDED to the previous logger. A logger
// that swallows everything stops `testing.expect` from reporting, and the test
// then passes by silence rather than by truth.
// ---------------------------------------------------------------------------

CAPTURE_LINES :: 8
CAPTURE_BYTES :: 512

Capture :: struct {
	inner:    log.Logger,
	count:    int,
	overflow: int,
	lines:    [CAPTURE_LINES][CAPTURE_BYTES]u8,
	lengths:  [CAPTURE_LINES]int,
}

capture_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Capture)(data)

	if strings.has_prefix(text, "druse: ") {
		// Framework output. The Info lines are the logger's product and are
		// recorded; the Error lines are diagnostics a test provoked on purpose,
		// and the runner counts any Error line as a failure, so they are
		// swallowed (the WP17-WP20 quiet-logger idiom).
		if level == .Info {
			if record.count < CAPTURE_LINES {
				n := copy(record.lines[record.count][:], text)
				record.lengths[record.count] = n
				record.count += 1
			} else {
				record.overflow += 1
			}
		}
		return
	}

	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

// capture_logger RETURNS the logger; it does not install it. Assigning
// `context.logger` inside a helper only changes the helper's own context —
// the caller must arm it in the test body.
capture_logger :: proc(record: ^Capture) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = capture_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

captured :: proc(record: ^Capture, i: int) -> string {
	if i < 0 || i >= record.count {
		return ""
	}
	return string(record.lines[i][:record.lengths[i]])
}

// ---------------------------------------------------------------------------
// Handlers.
// ---------------------------------------------------------------------------

ok_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

created_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .Created, "made")
}

silent_handler :: proc(ctx: ^web.Context) {
	// Commits nothing: the DRIVER finalizes the standard 500 after dispatch
	// returns — that is, after the chain has already unwound past the logger.
}

// ---------------------------------------------------------------------------
// One line per request, and it is the committed truth.
// ---------------------------------------------------------------------------

@(test)
wp22_public_logs_one_line_per_request :: proc(t: ^testing.T) {
	cap: Capture
	context.logger = capture_logger(&cap)

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, web.logger)
	web.get(&a, "/ping", ok_handler)

	res := web.test_request(&a, .GET, "/ping")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, cap.count, 1)
	testing.expect_value(t, captured(&cap, 0), "druse: GET /ping 200")
}

@(test)
wp22_public_logs_the_committed_status_not_a_guess :: proc(t: ^testing.T) {
	// The line is written AFTER `next` returns (ADR-022 B1). A logger that
	// wrote before the handler could only guess, and would report 200 for a
	// route that answered 201.
	cap: Capture
	context.logger = capture_logger(&cap)

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, web.logger)
	web.post(&a, "/things", created_handler)

	res := web.test_request(&a, .POST, "/things")

	testing.expect_value(t, res.status, web.Status.Created)
	testing.expect_value(t, cap.count, 1)
	testing.expect_value(t, captured(&cap, 0), "druse: POST /things 201")
}

@(test)
wp22_public_two_requests_log_two_lines :: proc(t: ^testing.T) {
	cap: Capture
	context.logger = capture_logger(&cap)

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, web.logger)
	web.get(&a, "/ping", ok_handler)

	_ = web.test_request(&a, .GET, "/ping")
	_ = web.test_request(&a, .GET, "/ping")

	testing.expect_value(t, cap.count, 2)
	testing.expect_value(t, captured(&cap, 1), "druse: GET /ping 200")
}

// ---------------------------------------------------------------------------
// Misses (ADR-023): the traffic a logger most needs to see.
// ---------------------------------------------------------------------------

@(test)
wp22_public_logs_a_404 :: proc(t: ^testing.T) {
	cap: Capture
	context.logger = capture_logger(&cap)

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, web.logger)
	web.get(&a, "/ping", ok_handler)

	res := web.test_request(&a, .GET, "/admin/secrets")

	testing.expect_value(t, res.status, web.Status.Not_Found)
	testing.expect_value(t, cap.count, 1)

	// No route matched, so there is no pattern. The field is `-`: the framework
	// does not populate an identity it cannot supply, and it will NOT fall back
	// to the raw path — which is exactly the attacker-controlled text a 404 log
	// would otherwise be full of.
	testing.expect_value(t, captured(&cap, 0), "druse: GET - 404")
	testing.expect(
		t,
		!strings.contains(captured(&cap, 0), "secrets"),
		"a miss must never put the requested path in the log",
	)
}

@(test)
wp22_public_logs_a_405 :: proc(t: ^testing.T) {
	cap: Capture
	context.logger = capture_logger(&cap)

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, web.logger)
	web.get(&a, "/ping", ok_handler)

	res := web.test_request(&a, .POST, "/ping")

	testing.expect_value(t, res.status, web.Status.Method_Not_Allowed)
	testing.expect_value(t, cap.count, 1)
	testing.expect_value(t, captured(&cap, 0), "druse: POST - 405")
}

// ---------------------------------------------------------------------------
// Nothing from the request reaches the log.
// ---------------------------------------------------------------------------

@(test)
wp22_public_never_emits_query_header_or_body :: proc(t: ^testing.T) {
	cap: Capture
	context.logger = capture_logger(&cap)

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, web.logger)
	web.post(&a, "/orders/:id", ok_handler)

	res := web.test_request(
		&a,
		.POST,
		"/orders/42",
		body = "{\"card\":\"4111111111111111\"}",
		query = "token=SECRETQUERY&page=2",
		headers = []string{"Authorization: Bearer SECRETBEARER", "X-Api-Key: SECRETHEADER"},
	)

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, cap.count, 1)

	line := captured(&cap, 0)

	// The PATTERN, not the path: low-cardinality identity, and the captured
	// parameter value is request data like any other.
	testing.expect_value(t, line, "druse: POST /orders/:id 200")

	testing.expect(t, !strings.contains(line, "42"), "the captured path parameter must not be logged")
	testing.expect(t, !strings.contains(line, "SECRETQUERY"), "no query byte may be logged")
	testing.expect(t, !strings.contains(line, "token"), "no query byte may be logged")
	testing.expect(t, !strings.contains(line, "SECRETBEARER"), "no header byte may be logged")
	testing.expect(t, !strings.contains(line, "SECRETHEADER"), "no header byte may be logged")
	testing.expect(t, !strings.contains(line, "Authorization"), "no header name may be logged")
	testing.expect(t, !strings.contains(line, "4111"), "no body byte may be logged")
}

@(test)
wp22_public_crlf_in_a_pattern_is_escaped :: proc(t: ^testing.T) {
	// The route pattern is the one variable field in the line, and it is
	// application-supplied text. A pattern carrying CR/LF would otherwise forge
	// extra log records — the log-injection half of the OWASP logging guidance,
	// and the same class of attack WP23 will face on the header.
	cap: Capture
	context.logger = capture_logger(&cap)

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, web.logger)
	web.get(&a, "/a\r\ndruse: GET /forged 200", ok_handler)

	res := web.test_request(&a, .GET, "/a\r\ndruse: GET /forged 200")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, cap.count, 1)

	line := captured(&cap, 0)
	testing.expect(
		t,
		!strings.contains(line, "\r") && !strings.contains(line, "\n"),
		"no raw CR or LF may reach the log line",
	)
	testing.expect(
		t,
		strings.contains(line, "\\r\\n"),
		"CR and LF must appear ESCAPED, so the record stays one record",
	)
}

// ---------------------------------------------------------------------------
// Opt-in, and ordering.
// ---------------------------------------------------------------------------

@(test)
wp22_public_is_opt_in :: proc(t: ^testing.T) {
	// G-08: the framework promises only what it delivers, and it does not
	// invent defaults. An application that never says `use(&a, web.logger)`
	// gets no logging — not a quieter logger, none.
	cap: Capture
	context.logger = capture_logger(&cap)

	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/ping", ok_handler)

	res := web.test_request(&a, .GET, "/ping")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, cap.count, 0)
}

Trace :: struct {
	lines_at_unwind: int,
	ran:             bool,
}

trace_sink: ^Trace

// outer_middleware is registered BEFORE `logger`, so it enters first and
// unwinds LAST (ADR-022: exact reverse order). By the time its post-`next` code
// runs, the logger's line must already exist.
outer_middleware :: proc(ctx: ^web.Context) {
	web.next(ctx)
	if trace_sink != nil {
		trace_sink.ran = true
		trace_sink.lines_at_unwind = (^Capture)(context.logger.data).count
	}
}

@(test)
wp22_public_logs_during_its_own_unwind :: proc(t: ^testing.T) {
	cap: Capture
	context.logger = capture_logger(&cap)
	trace: Trace
	trace_sink = &trace
	defer trace_sink = nil

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, outer_middleware)
	web.use(&a, web.logger)
	web.get(&a, "/ping", ok_handler)

	_ = web.test_request(&a, .GET, "/ping")

	testing.expect(t, trace.ran, "the outer middleware must have unwound")
	testing.expect_value(t, trace.lines_at_unwind, 1)
	testing.expect_value(t, cap.count, 1)
}

// ---------------------------------------------------------------------------
// The uncommitted request — reported honestly rather than invented.
// ---------------------------------------------------------------------------

@(test)
wp22_public_uncommitted_status_is_not_invented :: proc(t: ^testing.T) {
	// A handler that commits nothing: the driver finalizes a 500, but it does
	// so AFTER dispatch returns — after the chain, and so after the logger.
	// The logger reports what was committed when it looked, and says `-` when
	// nothing was. Printing `200`, or `500` it had not seen, would be the
	// framework lying about its own traffic.
	cap: Capture
	context.logger = capture_logger(&cap)

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, web.logger)
	web.get(&a, "/silent", silent_handler)

	res := web.test_request(&a, .GET, "/silent")

	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
	testing.expect_value(t, cap.count, 1)
	testing.expect_value(t, captured(&cap, 0), "druse: GET /silent -")
}

// ---------------------------------------------------------------------------
// Shape and cost.
// ---------------------------------------------------------------------------

@(test)
wp22_public_signature_is_pinned :: proc(t: ^testing.T) {
	// `logger` IS a `Handler` — not a constructor, not a configurable object,
	// not a second handler shape. Pinned as a value, the WP17-WP20 precedent.
	handler_sig: web.Handler = web.logger

	a := web.app()
	defer web.destroy(&a)
	web.use(&a, handler_sig)
	web.get(&a, "/ping", ok_handler)

	cap: Capture
	context.logger = capture_logger(&cap)
	res := web.test_request(&a, .GET, "/ping")

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect_value(t, cap.count, 1)
}

@(test)
wp22_public_logging_app_tears_down_cleanly :: proc(t: ^testing.T) {
	// `odin test` tracks allocations by default. The logger composes into a
	// fixed buffer and hands the string to `context.logger` synchronously: it
	// must own no storage and leak nothing.
	cap: Capture
	context.logger = capture_logger(&cap)

	a := web.app()
	web.use(&a, web.logger)
	web.get(&a, "/ping", ok_handler)
	_ = web.test_request(&a, .GET, "/ping")
	_ = web.test_request(&a, .GET, "/nope")
	web.destroy(&a)

	testing.expect_value(t, cap.count, 2)
}
