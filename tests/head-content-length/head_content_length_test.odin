// ROUTER AUDIT C4 — A HEAD MUST ANNOUNCE THE LENGTH A GET WOULD HAVE SENT.
//
// The framework serves HEAD by running the GET handler and suppressing the body
// at `response_body_view`, keeping status and headers exactly as the GET
// produced them. But the body was suppressed BEFORE the transport computed
// `content-length`, so every HEAD answered `content-length: 0` — while RFC 9110
// §8.6 says the header, when present, must be the length the equivalent GET
// would have sent.
//
// It is a quiet break: the clients that issue HEAD do it precisely to learn the
// size without transferring the body (`curl -I`, download managers, proxies that
// range-probe), so they are told every resource is empty and every GET path
// keeps working, which is why it survives casual testing.
//
// Raw wire, because this is a claim about bytes on the socket and no in-memory
// harness can see the transport's heading.
package test_head_content_length

import "core:net"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

PORT :: 41_993
BODY :: "hello head"

body_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, BODY)
}

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
}

serve_thread :: proc(s: ^Server) {web.serve(&s.app, s.port)}

start :: proc(s: ^Server, port: int) -> bool {
	s.port = port
	s.app = web.app()
	web.get(&s.app, "/thing", body_handler)
	s.thread = thread.create_and_start_with_poly_data(s, serve_thread)
	for _ in 0 ..< 300 {
		sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port})
		if err == nil {net.close(sock); return true}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

stop :: proc(s: ^Server) {
	web.stop(&s.app)
	if s.thread != nil {thread.join(s.thread); thread.destroy(s.thread); s.thread = nil}
	web.destroy(&s.app)
}

// raw sends one request verbatim and returns everything the server wrote.
raw :: proc(port: int, request: string) -> (string, bool) {
	endpoint := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	sock: net.TCP_Socket
	connected := false
	for _ in 0 ..< 100 {
		s, err := net.dial_tcp(endpoint)
		if err == nil {sock = s; connected = true; break}
		time.sleep(2 * time.Millisecond)
	}
	if !connected {return "", false}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 5 * time.Second)
	net.set_option(sock, .Send_Timeout, 5 * time.Second)

	data := transmute([]u8)request
	off := 0
	for off < len(data) {
		n, err := net.send_tcp(sock, data[off:])
		if err != nil || n <= 0 {return "", false}
		off += n
	}

	acc := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	for {
		n, e := net.recv_tcp(sock, buf[:])
		if n > 0 {strings.write_bytes(&acc, buf[:n])}
		if n == 0 || e != nil {break}
	}
	return strings.to_string(acc), true
}

// content_length_of reads the header out of a raw response.
content_length_of :: proc(response: string) -> (int, bool) {
	lower := strings.to_lower(response, context.temp_allocator)
	i := strings.index(lower, "content-length:")
	if i < 0 {return 0, false}
	rest := response[i + len("content-length:"):]
	end := strings.index(rest, "\r\n")
	if end < 0 {return 0, false}
	return strconv.parse_int(strings.trim_space(rest[:end]), 10)
}

@(test)
audit_head_announces_the_length_a_get_would_send :: proc(t: ^testing.T) {
	srv: Server
	if !start(&srv, PORT) {
		testing.fail_now(t, "server did not start")
	}
	defer stop(&srv)

	get_res, get_ok := raw(PORT, "GET /thing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
	testing.expect(t, get_ok, "GET answered")
	get_len, has_get_len := content_length_of(get_res)
	testing.expect(t, has_get_len, "the GET carries a content-length")
	testing.expect_value(t, get_len, len(BODY))

	head_res, head_ok := raw(PORT, "HEAD /thing HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
	testing.expect(t, head_ok, "HEAD answered")
	head_len, has_head_len := content_length_of(head_res)
	testing.expect(t, has_head_len, "the HEAD carries a content-length")

	// THE ASSERTION. Before the fix this was 0 for any body.
	testing.expectf(
		t,
		head_len == get_len,
		"HEAD must announce the GET's length: got %d, GET sent %d",
		head_len,
		get_len,
	)

	// And it must still send NO body — announcing the length is not sending it.
	head_body_start := strings.index(head_res, "\r\n\r\n")
	testing.expect(t, head_body_start >= 0, "the HEAD response has a header terminator")
	testing.expectf(
		t,
		len(head_res) == head_body_start + 4,
		"HEAD must not send a body, got %d trailing bytes",
		len(head_res) - (head_body_start + 4),
	)
}
