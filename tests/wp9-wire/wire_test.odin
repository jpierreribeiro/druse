// WP9 — RAW-WIRE CONFORMANCE. Real adapters only.
//
// This suite sends exact HTTP/1 bytes over a loopback socket and checks the
// three properties that actually prevent request smuggling and connection
// desynchronization:
//
//	the handler must not run on an ambiguous or partial request;
//	the connection must be retired rather than left reusable;
//	trailing bytes must never execute as a second request.
//
// It runs ONLY here, never against the in-memory transport: that transport has
// no TCP parser, so pointing this corpus at it would be meaningless green (D1).
//
// The corpus itself is backend-agnostic DATA in
// `tests/support/transport_conformance/corpus.odin`, so a future adapter can be
// held to it without touching this file.
package wp9_wire

import "base:runtime"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import tc "uruquim:tests/support/transport_conformance"
import web "uruquim:web"
import transport "uruquim:web/internal/transport"

CANDIDATE_PORTS :: [?]int{51137, 51839, 52267, 52753}

// Handler-execution counters. The corpus asserts on these: a rejected request
// must leave them untouched.
ping_hits: int
echo_hits: int
smuggled_hits: int

Echo :: struct {
	name: string `json:"name"`,
}

ping_handler :: proc(ctx: ^web.Context) {
	ping_hits += 1
	web.text(ctx, .OK, "pong")
}

echo_handler :: proc(ctx: ^web.Context) {
	echo_hits += 1
	input: Echo
	if !web.body(ctx, &input) {
		return
	}
	web.created(ctx, input)
}

// `/smuggled` exists so a smuggled request WOULD be observable if the adapter
// executed one. It must stay at zero for the whole suite.
// WP52 — a handler that answers 204, so the corpus can assert RESPONSE framing
// rather than only request rejection.
nobody_hits: int

nobody_handler :: proc(ctx: ^web.Context) {
	nobody_hits += 1
	web.no_content(ctx)
}

smuggled_handler :: proc(ctx: ^web.Context) {
	smuggled_hits += 1
	web.text(ctx, .OK, "smuggled")
}

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
}

g_server: ^Server

serve_thread :: proc() {
	s := g_server
	sync.post(&s.ready)
	web.serve(&s.app, s.port)
}

start_server :: proc(s: ^Server) -> bool {
	g_server = s
	for candidate in CANDIDATE_PORTS {
		s.app = web.app()
		web.get(&s.app, "/ping", ping_handler)
		web.post(&s.app, "/ping", ping_handler)
		web.post(&s.app, "/echo", echo_handler)
		web.get(&s.app, "/smuggled", smuggled_handler)
		web.delete(&s.app, "/nobody", nobody_handler)
		s.port = candidate
		s.thread = thread.create_and_start(serve_thread)
		sync.wait(&s.ready)

		if wait_until_accepting(candidate) {
			return true
		}

		transport.request_stop()
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
		web.destroy(&s.app)
	}
	return false
}

stop_server :: proc(s: ^Server) {
	if s.thread == nil {
		return
	}
	transport.request_stop()
	thread.join(s.thread)
	thread.destroy(s.thread)
	s.thread = nil
	web.destroy(&s.app)
	g_server = nil
}

wait_until_accepting :: proc(port: int) -> bool {
	endpoint := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	for _ in 0 ..< 200 {
		sock, err := net.dial_tcp(endpoint)
		if err == nil {
			net.close(sock)
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

@(test)
wp9_raw_wire_corpus :: proc(t: ^testing.T) {
	filter: Log_Filter
	context.logger = swallow_framework_log(&filter)

	server: Server
	if !start_server(&server) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}
	// Cleanup runs even if an assertion fails: never leak a thread or a socket.
	defer stop_server(&server)

	for wire_case in tc.wire_corpus() {
		run_wire_case(t, server.port, wire_case)
	}

	// AUDIT M9 — runs on the corpus's own server, for the reason recorded on the
	// procedure itself.
	wp9_shrink_does_not_drop_a_pipelined_request(t, server.port)

	// Across the WHOLE corpus, not one smuggled request may have executed.
	testing.expectf(
		t,
		smuggled_hits == 0,
		"a smuggled request executed %d time(s); the adapter desynchronized",
		smuggled_hits,
	)
}

run_wire_case :: proc(t: ^testing.T, port: int, c: tc.Wire_Case) {
	// Per-case progress. It is not decoration: when an adapter CRASHES or hangs
	// on a malformed case, the last line printed names the case that did it —
	// which is how the WP9 RED run identified the negative-Content-Length abort.
	log.infof("wire case: %s", c.name)

	ping_before := ping_hits
	echo_before := echo_hits
	nobody_before := nobody_hits
	smuggled_before := smuggled_hits

	result := tc.wire_send(port, c.bytes)
	defer tc.wire_result_destroy(&result)

	testing.expectf(t, result.dialed, "%s: could not connect", c.name)
	if !result.dialed {
		return
	}

	// A timeout is NEVER an acceptable outcome — a rejected case must be
	// answered or closed, not left hanging.
	testing.expectf(t, !result.timed_out, "%s: the adapter hung instead of answering or closing", c.name)

	// `/nobody` counts too. It was omitted, so the 204 case asserted
	// `handler_must_run` against a counter its handler never touched and failed
	// silently for as long as the logger was discarding failures.
	handler_ran :=
		(ping_hits - ping_before) +
		(echo_hits - echo_before) +
		(nobody_hits - nobody_before) > 0
	smuggled_ran := smuggled_hits - smuggled_before > 0

	testing.expectf(
		t,
		!smuggled_ran,
		"%s: a smuggled request EXECUTED — request smuggling is possible",
		c.name,
	)

	switch c.outcome {
	case .Ok:
		if c.handler_must_run {
			testing.expectf(t, handler_ran, "%s: the handler did not run", c.name)
		}
		if len(result.statuses) > 0 {
			testing.expectf(
				t,
				tc.status_allowed(c.allowed_status, result.statuses[0]),
				"%s: status %d is not allowed",
				c.name,
				result.statuses[0],
			)
		} else {
			testing.expectf(t, false, "%s: expected a response, got none", c.name)
		}
		if c.expect_second_request {
			testing.expectf(
				t,
				len(result.statuses) >= 2,
				"%s: expected a second response on the same connection, got %d",
				c.name,
				len(result.statuses),
			)
		}

	case .Rejected:
		// The handler must NOT have run: no application code may observe an
		// ambiguous or partial request.
		testing.expectf(
			t,
			!handler_ran,
			"%s: the handler RAN on a request that must be rejected",
			c.name,
		)

		// A status is optional (a bare close is acceptable, WP9 D6) but when one
		// is sent it must be an allowed one.
		if len(result.statuses) > 0 {
			testing.expectf(
				t,
				tc.status_allowed(c.allowed_status, result.statuses[0]),
				"%s: rejected with status %d, which is not an allowed outcome",
				c.name,
				result.statuses[0],
			)
			// Exactly one response: a second would mean the adapter kept parsing.
			testing.expectf(
				t,
				len(result.statuses) == 1,
				"%s: %d responses on a rejected request; the connection was reused",
				c.name,
				len(result.statuses),
			)
		}

		if c.connection_must_close {
			testing.expectf(
				t,
				result.saw_eof,
				"%s: the connection stayed open after a framing error",
				c.name,
			)
		}
	}
}

// ---------------------------------------------------------------------------
// A logger filter: rejected requests legitimately produce framework and backend
// diagnostics, and `odin test` counts any Error record as a failure.
// ---------------------------------------------------------------------------

Log_Filter :: struct {
	inner:            log.Logger,
	forwarded_errors: int,
	dropped_errors:   int,
}

// A record the FRAMEWORK or the vendored backend logged about a request. Those
// are the only ones this suite may discard: a rejected request legitimately
// produces them, and `odin test` counts any Error record as a failure.
//
// Anything else — notably `core:testing`'s own `log.errorf` from an assertion —
// is forwarded. Matching on the framework's source tree rather than on the
// suite's own keeps that true when the suite is compiled from somewhere else.
@(private)
from_framework :: proc(file_path: string) -> bool {
	return(
		strings.contains(file_path, "/web/") ||
		strings.contains(file_path, "/vendor/") \
	)
}

filter_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	filter := (^Log_Filter)(data)
	// Swallow the framework's own diagnostics — a rejected request logs them
	// legitimately — but NEVER a record from THIS suite, because that is how
	// `testing.expect*` reports a FAILED ASSERTION (core/testing: expectf calls
	// log.errorf). Filtering on level alone discarded this suite's own failures:
	// a case demanding status 999 passed, and the H3 framing cases passed with
	// the fix reverted. Every corpus case was decorative from the commit that
	// introduced this suite until this line changed.
	// FAIL OPEN. Swallow only what is positively identified as the framework's
	// or the backend's own diagnostic; forward everything else, including
	// anything unrecognized. The asymmetry is deliberate: forwarding a
	// framework record costs a spurious, loud, easily-fixed failure, while
	// swallowing an assertion costs a suite that is green and worthless — which
	// is exactly what happened here.
	//
	// Identify by ORIGIN rather than by the suite's own path. An earlier
	// revision of this fix asked whether the record came from "tests/wp9-wire",
	// which silently reverted to swallowing assertions the moment the suite was
	// built from a copy under a different directory — a meta-audit that runs
	// suites out of a scratch tree caught exactly that.
	if level == .Error && from_framework(location.file_path) {
		filter.dropped_errors += 1
		return
	}
	if level == .Error {
		filter.forwarded_errors += 1
	}
	if filter.inner.procedure != nil {
		filter.inner.procedure(filter.inner.data, level, text, options, location)
	}
}

swallow_framework_log :: proc(filter: ^Log_Filter) -> log.Logger {
	filter.inner = context.logger
	return log.Logger {
		procedure = filter_proc,
		data = rawptr(filter),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

// THE CONTROL for the filter itself: it drives `filter_proc` directly with a
// record from each origin, so a regression is caught by a mechanism the
// regression cannot disable.
@(test)
wp9_the_log_filter_cannot_swallow_an_assertion_failure :: proc(t: ^testing.T) {
	filter: Log_Filter
	sink_hits := 0
	filter.inner = log.Logger {
		procedure = proc(data: rawptr, level: log.Level, text: string, options: log.Options, location := #caller_location) {
			(^int)(data)^ += 1
		},
		data = rawptr(&sink_hits),
		lowest_level = .Debug,
	}

	framework_loc := runtime.Source_Code_Location {
		file_path = "/home/user/uruquim/web/internal/transport/odin_http_adapter.odin",
	}
	filter_proc(&filter, .Error, "backend refused a malformed request", {}, framework_loc)
	testing.expect_value(t, filter.dropped_errors, 1)
	testing.expect_value(t, sink_hits, 0)

	suite_loc := runtime.Source_Code_Location {
		file_path = "/somewhere/else/entirely/wire_test.odin",
	}
	filter_proc(&filter, .Error, "a wire case failed", {}, suite_loc)
	testing.expect_value(t, filter.forwarded_errors, 1)
	testing.expectf(
		t,
		sink_hits == 1,
		"the wire suite's log filter swallowed an assertion failure; every corpus case is then decorative",
	)
}

// AUDIT M9 — THE BUFFER SHRINK MUST NOT EAT A PIPELINED REQUEST.
//
// Vendor patch 41 returns the connection's read buffer between requests once it
// has grown past `RETAINED_BUF_MAX`, because one large POST otherwise left that
// keep-alive connection holding a body-sized buffer for as long as the client
// kept the socket open. The later counting-allocator attribution proves the
// live allocation directly: four blocked 3 MiB bodies hold 16,138,240 bytes,
// and response completion returns the live total exactly to baseline.
//
// THE RISK THE SHRINK CREATES is this test. `s.end` is the live prefix of
// already-arrived bytes, which on a pipelined connection is the NEXT request.
// Discarding the buffer while that is present would drop a request the client
// has already sent and will never resend — a silent hang, not an error. The
// patch guards on `s.end == 0`; this proves the guard is load-bearing by
// sending exactly the shape that would break without it: a body large enough to
// trigger the shrink, with a second request already in flight behind it.
// CALLED FROM `wp9_raw_wire_corpus`, NOT AN `@(test)` OF ITS OWN, and that is
// the correction rather than a style choice.
//
// It WAS a separate test. The gate runs this suite with the default four
// threads (no `-define:ODIN_TEST_THREADS=1`), and this suite keeps ONE server
// behind a process-global `g_server` on fixed ports — the one-server-per-process
// rule the transport documents. A second test starting its own server clobbered
// the corpus's while it was mid-run: green every time on a serial local run,
// and a four-minute timeout with two tests unfinished in the gate.
//
// The gate caught it. Sharing the corpus's server removes the collision without
// changing this suite's concurrency for everything else.
wp9_shrink_does_not_drop_a_pipelined_request :: proc(t: ^testing.T, port: int) {
	// Comfortably over RETAINED_BUF_MAX (256 KiB) so the shrink is reached, and
	// inside the body cap so the request is served rather than refused.
	BODY :: 1024 * 1024
	body := make([]u8, BODY, context.temp_allocator)
	for i in 0 ..< BODY {body[i] = 'x'}

	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	strings.write_string(&b, "POST /ping HTTP/1.1\r\nHost: localhost\r\nContent-Length: ")
	strings.write_int(&b, BODY)
	strings.write_string(&b, "\r\n\r\n")
	strings.write_bytes(&b, body)
	// THE SECOND REQUEST, in the same write. It is sitting in the connection's
	// buffer while the first one is still being handled.
	strings.write_string(&b, "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

	before := ping_hits
	endpoint := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	sock, derr := net.dial_tcp(endpoint)
	testing.expect(t, derr == nil, "must connect")
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 10 * time.Second)

	payload := transmute([]u8)strings.to_string(b)
	sent := 0
	for sent < len(payload) {
		n, serr := net.send_tcp(sock, payload[sent:])
		if serr != nil || n <= 0 {break}
		sent += n
	}
	testing.expect_value(t, sent, len(payload))

	reply: strings.Builder
	strings.builder_init(&reply, context.temp_allocator)
	chunk: [8192]u8
	for {
		n, rerr := net.recv_tcp(sock, chunk[:])
		if n > 0 {strings.write_bytes(&reply, chunk[:n])}
		if n <= 0 || rerr != nil {break}
	}

	testing.expectf(
		t,
		ping_hits - before == 2,
		"BOTH requests must be served: the large POST and the pipelined GET behind it. Handler ran %d time(s). One means the buffer was discarded while the second request was already in it — the client sent bytes the server threw away, and will wait forever for a reply it will never get.",
		ping_hits - before,
	)
	testing.expect(
		t,
		strings.count(strings.to_string(reply), "HTTP/1.1 200") == 2,
		"and both must be answered on the wire",
	)
}
