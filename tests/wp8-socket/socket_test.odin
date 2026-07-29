// WP8 real-socket contract — the one end-to-end suite that proves `web.serve`
// binds a real port and answers real HTTP.
//
// It is a SEPARATE package (not `package web`): it drives the public `web.serve`
// exactly as an application would, and reaches into `web/internal/transport`
// only for the private `request_stop` — the test-only stop that avoids sending
// SIGINT to the test runner. It uses `core:net` purely as a dumb client; it is
// NOT a full HTTP parser (that corpus is WP9).
//
// SYNCHRONIZATION is by connection-retry, not a fixed sleep: the client dials in
// a bounded loop until the listener accepts. Cleanup (stop + join) runs even
// after an assertion fails, so a red test never leaks a thread or a socket.
//
// build/check.sh runs this under an EXTERNAL timeout and on a small set of
// candidate ports to avoid collision.
package wp8_socket

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"
import transport "druse:web/internal/transport"

// A small set of loopback ports to try, to dodge a busy one.
@(private = "file")
WP8_CANDIDATE_PORTS :: [?]int{47821, 48713, 49277, 50159}

@(private = "file")
Server_Fixture :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
}

@(private = "file")
g_fixture: ^Server_Fixture

ping_hits: int

ping_handler :: proc(ctx: ^web.Context) {
	ping_hits += 1
	web.text(ctx, .OK, "pong")
}

Echo :: struct {
	name: string `json:"name"`,
}

echo_hits: int
echo_seen_name: string

echo_handler :: proc(ctx: ^web.Context) {
	echo_hits += 1
	input: Echo
	if !web.body(ctx, &input) {
		return
	}
	echo_seen_name = input.name
	web.ok(ctx, input)
}

big_hits: int

big_handler :: proc(ctx: ^web.Context) {
	// If the adapter enforced the cap correctly, an over-limit request never
	// reaches this handler.
	big_hits += 1
	web.no_content(ctx)
}

@(private = "file")
serve_thread :: proc() {
	f := g_fixture
	web.get(&f.app, "/ping", ping_handler)
	web.post(&f.app, "/echo", echo_handler)
	web.post(&f.app, "/big", big_handler)
	sync.post(&f.ready)
	web.serve(&f.app, f.port)
}

// dial_with_retry connects to loopback, retrying briefly so readiness does not
// depend on a fixed sleep. Returns ok=false if the port never accepts.
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

// send_request sends `raw` and returns the response as an OWNED string the
// caller must delete. It reads until the peer closes (we always send
// Connection: close).
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

@(test)
wp8_real_server_serves_and_stops :: proc(t: ^testing.T) {
	fixture: Server_Fixture
	fixture.app = web.app()
	g_fixture = &fixture

	// Try candidate ports until one binds and answers.
	served := false
	for candidate in WP8_CANDIDATE_PORTS {
		fixture.port = candidate
		fixture.thread = thread.create_and_start(serve_thread)
		sync.wait(&fixture.ready)

		res, ok := send_request(candidate, "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
		if ok && strings.contains(res, "200") {
			// This port works: run the assertions here and stop.
			testing.expect(t, strings.contains(res, "pong"), "GET /ping must return the pong body")
			testing.expect(
				t,
				strings.contains(res, "text/plain; charset=utf-8"),
				"GET /ping must carry the text Content-Type",
			)
			testing.expect_value(t, ping_hits, 1)
			delete(res)

			// POST JSON: WP7 must receive and decode the body over the real wire.
			body := `{"name":"grace"}`
			length := int_to_string(len(body))
			defer delete(length)
			post := strings.concatenate(
				{
					"POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: ",
					length,
					"\r\nConnection: close\r\n\r\n",
					body,
				},
			)
			defer delete(post)
			echo_res, echo_ok := send_request(candidate, post)
			testing.expect(t, echo_ok, "POST /echo must get a response")
			if echo_ok {
				testing.expect(t, strings.contains(echo_res, "grace"), "the decoded body must echo back")
				delete(echo_res)
			}
			testing.expect_value(t, echo_seen_name, "grace")

			// Over-limit body: 413, exact envelope, handler NOT run.
			//
			// The cap is enforced on the declared Content-Length before the body
			// is read, so the request DECLARES an oversized length without sending
			// the megabytes — which is both the real over-limit case and what lets
			// the client receive the 413 rather than reset on a rejected send.
			big_length := int_to_string(4 * 1024 * 1024 + 1)
			defer delete(big_length)
			big := strings.concatenate(
				{
					"POST /big HTTP/1.1\r\nHost: localhost\r\nContent-Length: ",
					big_length,
					"\r\nConnection: close\r\n\r\n",
				},
			)
			defer delete(big)
			big_res, big_ok := send_request(candidate, big)
			testing.expect(t, big_ok, "the over-limit POST must get a response")
			if big_ok {
				testing.expect(t, strings.contains(big_res, "413"), "an over-limit body must be 413")
				testing.expect(
					t,
					strings.contains(big_res, `"code":"body_too_large"`),
					"the 413 must carry the WP7 body_too_large envelope",
				)
				delete(big_res)
			}
			testing.expect_value(t, big_hits, 0)

			served = true
		} else if ok {
			delete(res)
		}

		// Stop this server (whether or not it was the working one) and join.
		transport.request_stop()
		thread.join(fixture.thread)
		thread.destroy(fixture.thread)
		fixture.thread = nil

		if served {
			// The port must stop accepting after the stop.
			_, still_up := dial_with_retry_short(candidate)
			testing.expect(t, !still_up, "the port must stop accepting after request_stop")
			break
		}
	}

	web.destroy(&fixture.app)
	g_fixture = nil

	testing.expect(t, served, "no candidate port produced a working server")
}

// dial_with_retry_short is a fast, small-retry dial used to confirm the port is
// DOWN after stop — it must not hang.
@(private = "file")
dial_with_retry_short :: proc(port: int) -> (sock: net.TCP_Socket, ok: bool) {
	ep := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	s, err := net.dial_tcp(ep)
	if err == nil {
		return s, true
	}
	return {}, false
}

@(private = "file")
int_to_string :: proc(n: int) -> string {
	buf: [24]u8
	i := len(buf)
	v := n
	if v == 0 {
		return strings.clone("0")
	}
	for v > 0 {
		i -= 1
		buf[i] = u8('0' + v % 10)
		v /= 10
	}
	return strings.clone(string(buf[i:]))
}
