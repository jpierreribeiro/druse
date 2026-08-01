// WP21 real-socket contract — the fault-behaviour guarantee OVER THE WIRE.
//
// The Phase-2 Test Gate item is explicit that the guarantee must hold "under
// BOTH `web.serve` and `web.test_request`". WP8 proved the in-memory half and
// opened a real socket, but never drove a FAULTING request across it: the
// socket suite only ever asked for responses a handler produced. This suite
// closes that gap, because the gate item is worth exactly as much as its
// weaker transport.
//
// It asserts three things a socket can show and memory cannot:
//
//   1. an uncommitted response becomes a real `HTTP/1.1 500` status line with
//      the standardized envelope as its body — a zero status has no wire
//      representation at all, so this is where a missing guarantee would show
//      up as a malformed or empty reply;
//   2. the bytes are IDENTICAL to what `web.test_request` returns for the same
//      request — R-10, on the one property most worth keeping identical;
//   3. a second fault on a fresh connection is answered identically, and a
//      healthy request between them is unaffected. A server that faults once
//      and then degrades is the failure mode this excludes.
//
// The serve thread is given an EXPLICIT context carrying a quiet logger: the
// framework emits one Error-level `druse:` diagnostic per finalized fault,
// and the test runner treats an Error line as a failure. Non-framework lines
// are still forwarded, so a genuine failure can still be reported.
//
// build/check.sh runs this under an EXTERNAL timeout like every socket suite: a
// `serve` that blocked instead of answering would hang, and a hang is a
// FAILURE, never a stalled gate.
package wp21_socket

import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"
import transport "druse:web/internal/transport"

// A port set disjoint from the WP8/WP9/WP17/WP20 candidates.
@(private = "file")
WP21_CANDIDATE_PORTS :: [?]int{55231, 55787, 56209, 56743}

@(private = "file")
WP21_INTERNAL_ENVELOPE ::
	`{"error":{"code":"internal_error","message":"Internal server error"}}`

@(private = "file")
Quiet :: struct {
	inner: log.Logger,
}

@(private = "file")
quiet_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Quiet)(data)
	if level == .Error && strings.contains(text, "druse:") {
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

@(private = "file")
quiet_logger :: proc(record: ^Quiet) -> log.Logger {
	record.inner = context.logger
	// `.Info`, not `.Debug`: the bootstrap transport logs every connection
	// open and close at Debug, and a gate whose output is thousands of vendor
	// lines is a gate nobody reads. Errors — including `testing.expect`'s own
	// failure reports — still come through.
	return log.Logger {
		procedure = quiet_logger_proc,
		data = rawptr(record),
		lowest_level = .Info,
		options = context.logger.options,
	}
}

@(private = "file")
Server_Fixture :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
}

@(private = "file")
g_fixture: ^Server_Fixture

// The faulting handler: it runs, and it commits nothing. Over a socket there is
// no zero status to fall back on, so the driver guarantee is the only thing
// standing between this and a client that gets no answer at all.
silent_handler :: proc(ctx: ^web.Context) {
}

healthy_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

@(private = "file")
serve_thread :: proc() {
	f := g_fixture
	web.get(&f.app, "/silent", silent_handler)
	web.get(&f.app, "/healthy", healthy_handler)
	sync.post(&f.ready)
	web.serve(&f.app, f.port)
}

@(private = "file")
dial_with_retry :: proc(port: int) -> (sock: net.TCP_Socket, ok: bool) {
	ep := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	for _ in 0 ..< 200 {
		s, err := net.dial_tcp(ep)
		if err == nil {
			return s, true
		}
		time.sleep(5 * time.Millisecond)
	}
	return {}, false
}

// send_request returns the whole response as an OWNED string the caller must
// delete. It reads until the peer closes; every request sends Connection: close.
@(private = "file")
send_request :: proc(port: int, raw: string) -> (response: string, ok: bool) {
	sock, dialed := dial_with_retry(port)
	if !dialed {
		return "", false
	}
	defer net.close(sock)

	_, serr := net.send_tcp(sock, transmute([]u8)raw)
	if serr != nil {
		return "", false
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	buf: [4096]u8
	for {
		n, rerr := net.recv_tcp(sock, buf[:])
		if n > 0 {
			strings.write_bytes(&b, buf[:n])
		}
		if n == 0 || rerr != nil {
			break
		}
	}
	return strings.clone(strings.to_string(b)), true
}

@(private = "file")
get_request :: proc(path: string) -> string {
	return strings.concatenate(
		{"GET ", path, " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"},
	)
}

// response_body returns the view after the blank line separating headers from
// body. A response with no terminator yields "" — which every assertion below
// then rejects, rather than silently passing on a truncated reply.
@(private = "file")
response_body :: proc(raw: string) -> string {
	idx := strings.index(raw, "\r\n\r\n")
	if idx < 0 {
		return ""
	}
	return raw[idx + 4:]
}

@(test)
wp21_a_faulting_handler_answers_the_standard_500_over_a_real_socket :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	fixture: Server_Fixture
	fixture.app = web.app()
	g_fixture = &fixture

	served := false
	for candidate in WP21_CANDIDATE_PORTS {
		fixture.port = candidate
		// The serve thread gets THIS context, so the framework's own
		// diagnostics are captured on the thread that emits them.
		fixture.thread = thread.create_and_start(serve_thread, context)
		sync.wait(&fixture.ready)

		probe_req := get_request("/healthy")
		probe, probe_ok := send_request(candidate, probe_req)
		delete(probe_req)

		if probe_ok && strings.contains(probe, "200") {
			delete(probe)

			// 1. The fault, over the wire.
			fault_req := get_request("/silent")
			defer delete(fault_req)

			first, first_ok := send_request(candidate, fault_req)
			testing.expect(t, first_ok, "the faulting request must get a response")
			if first_ok {
				testing.expect(
					t,
					strings.has_prefix(first, "HTTP/1.1 500"),
					"a handler that commits no response must answer 500 on the wire",
				)
				testing.expect_value(t, response_body(first), WP21_INTERNAL_ENVELOPE)
				// Redaction, on the transport that actually reaches a client.
				testing.expect(
					t,
					!strings.contains(response_body(first), "silent"),
					"the 500 body must carry no fault detail",
				)
			}

			// 2. A healthy request in between is unaffected.
			between_req := get_request("/healthy")
			defer delete(between_req)
			between, between_ok := send_request(candidate, between_req)
			testing.expect(t, between_ok, "the healthy request must get a response")
			if between_ok {
				testing.expect(t, strings.has_prefix(between, "HTTP/1.1 200"), "a healthy route still answers 200")
				testing.expect_value(t, response_body(between), "pong")
				delete(between)
			}

			// 3. The second fault is answered identically, byte for byte.
			second, second_ok := send_request(candidate, fault_req)
			testing.expect(t, second_ok, "the second faulting request must get a response")
			if first_ok && second_ok {
				testing.expect_value(t, response_body(second), response_body(first))
				testing.expect(
					t,
					strings.has_prefix(second, "HTTP/1.1 500"),
					"a second fault behaves exactly like the first",
				)
			}

			// 4. R-10: the in-memory driver returns the SAME bytes. The socket
			//    app is busy on its thread, so parity is asserted against an
			//    identically-registered app driven in memory.
			memory := web.app()
			defer web.destroy(&memory)
			web.get(&memory, "/silent", silent_handler)
			recorded := web.test_request(&memory, .GET, "/silent")
			testing.expect_value(t, int(recorded.status), 500)
			if first_ok {
				testing.expect_value(t, recorded.body, response_body(first))
			}

			if first_ok {
				delete(first)
			}
			if second_ok {
				delete(second)
			}
			served = true
		} else if probe_ok {
			delete(probe)
		}

		transport.request_stop(transport.server_current())
		thread.join(fixture.thread)
		thread.destroy(fixture.thread)
		fixture.thread = nil

		if served {
			break
		}
	}

	web.destroy(&fixture.app)
	g_fixture = nil

	testing.expect(t, served, "no candidate port produced a working server")
}
