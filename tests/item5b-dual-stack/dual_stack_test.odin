// item 5b — DUAL-STACK bind + IPv4-mapped peer unmapping, over a real socket.
//
// The server now binds `::` (IPv6 Any) when IPv6 is available, which on a
// standard Linux (`net.ipv6.bindv6only` = 0) accepts BOTH IPv4 and IPv6
// clients on one socket. This suite proves the two properties that matter:
//
//   1. an IPv4 client reaches the dual-stack listener AND its `web.client_ip`
//      is the dotted-quad `127.0.0.1` — NOT the `::ffff:7f00:1` hex form Odin's
//      address_to_string would otherwise produce, which is what would silently
//      break `trust_proxies` prefix matching on a dual-stack socket;
//   2. an IPv6 client reaches the same listener and its `web.client_ip` is the
//      IPv6 `::1`, unchanged.
//
// Both are RED before item 5b: the server bound `0.0.0.0`, so the IPv6 client
// could not connect at all, and there was no unmapping.
//
// Runs under an external timeout like every socket suite; a `serve` that hung
// would be a failure, not a stalled gate.
package item5b_dual_stack

import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

@(private = "file")
CANDIDATE_PORTS :: [?]int{56811, 57013, 57241, 57487}

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
	return log.Logger {
		procedure    = quiet_logger_proc,
		data         = rawptr(record),
		lowest_level = .Info,
		options      = context.logger.options,
	}
}

@(private = "file")
Fixture :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
}

@(private = "file")
g_fixture: ^Fixture

// The handler echoes the resolved client address as the body, so the test reads
// back exactly what `web.client_ip` produced from the connected peer.
@(private = "file")
whoami :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, web.client_ip(ctx))
}

@(private = "file")
serve_thread :: proc() {
	f := g_fixture
	web.get(&f.app, "/whoami", whoami)
	sync.post(&f.ready)
	web.serve(&f.app, f.port)
}

@(private = "file")
dial_with_retry :: proc(ep: net.Endpoint) -> (sock: net.TCP_Socket, ok: bool) {
	for _ in 0 ..< 200 {
		s, err := net.dial_tcp(ep)
		if err == nil {
			return s, true
		}
		time.sleep(5 * time.Millisecond)
	}
	return {}, false
}

@(private = "file")
request_over :: proc(ep: net.Endpoint) -> (body: string, ok: bool) {
	sock, dialed := dial_with_retry(ep)
	if !dialed {
		return "", false
	}
	defer net.close(sock)

	raw := "GET /whoami HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	if _, serr := net.send_tcp(sock, transmute([]u8)raw); serr != nil {
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
	raw_resp := strings.to_string(b)
	idx := strings.index(raw_resp, "\r\n\r\n")
	if idx < 0 {
		return "", false
	}
	return strings.clone(raw_resp[idx + 4:]), true
}

@(test)
item5b_dual_stack_serves_ipv4_and_ipv6_with_correct_client_ip :: proc(t: ^testing.T) {
	// If this host has no IPv6 at all, the server falls back to IPv4 and the
	// IPv6 arm is not meaningful. The gate machine has IPv6 loopback; guard
	// anyway so the suite is honest on a host that does not.
	probe, probe_err := net.create_socket(.IP6, .TCP)
	has_v6 := probe_err == nil
	if has_v6 {
		net.close(probe)
	}

	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	fixture: Fixture
	fixture.app = web.app()
	g_fixture = &fixture

	served := false
	for candidate in CANDIDATE_PORTS {
		fixture.port = candidate
		fixture.thread = thread.create_and_start(serve_thread, context)
		sync.wait(&fixture.ready)

		// The IPv4 client: the whole point of item 5b's unmapping.
		v4_ep := net.Endpoint {
			address = net.IP4_Address{127, 0, 0, 1},
			port    = candidate,
		}
		v4_body, v4_ok := request_over(v4_ep)
		if !v4_ok {
			// Port busy or bind lost the race; try the next candidate.
			web.stop(&fixture.app)
			thread.join(fixture.thread)
			thread.destroy(fixture.thread)
			fixture.thread = nil
			continue
		}
		defer delete(v4_body)
		served = true

		// PROPERTY 1 — the IPv4 client is served AND its address is the
		// dotted-quad, not the `::ffff:` hex form. This is the unmapping.
		testing.expectf(
			t,
			v4_body == "127.0.0.1",
			"an IPv4 client on the dual-stack listener resolved to %q; expected the unmapped dotted-quad 127.0.0.1 (item 5b — trust_proxies matches this string)",
			v4_body,
		)
		testing.expect(
			t,
			!strings.contains(v4_body, "ffff"),
			"the IPv4 client's address still carries the ::ffff: mapping; render_peer did not unmap it",
		)

		// PROPERTY 2 — an IPv6 client reaches the SAME listener (impossible
		// before item 5b, when the server bound 0.0.0.0).
		if has_v6 {
			v6_ep := net.Endpoint {
				address = net.IP6_Address{0, 0, 0, 0, 0, 0, 0, 1}, // ::1
				port    = candidate,
			}
			v6_body, v6_ok := request_over(v6_ep)
			testing.expect(
				t,
				v6_ok,
				"an IPv6 client (::1) could not reach the dual-stack listener; item 5b's bind did not take effect",
			)
			if v6_ok {
				defer delete(v6_body)
				testing.expectf(
					t,
					v6_body == "::1",
					"the IPv6 client resolved to %q; expected ::1",
					v6_body,
				)
			}
		}

		web.stop(&fixture.app)
		thread.join(fixture.thread)
		thread.destroy(fixture.thread)
		fixture.thread = nil
		web.destroy(&fixture.app)
		break
	}

	testing.expect(t, served, "no candidate port produced a working dual-stack server")
}
