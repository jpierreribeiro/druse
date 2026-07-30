// WP67 negative control: the current 500 is core classification, not a lie in
// `web.test_request`. The same handler and bytes run through memory and a real
// socket and must be byte-identical.
package wp67_transport_control

import "core:log"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"
import transport "druse:web/internal/transport"

Input :: struct {
	age: int `json:"age"`,
}

bind_input :: proc(ctx: ^web.Context) {
	dst: Input
	if !web.body(ctx, &dst) {
		return
	}
	web.no_content(ctx)
}

Log_Filter :: struct {
	inner: log.Logger,
}

filter_log :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	f := (^Log_Filter)(data)
	if level == .Error && strings.contains(text, "druse:") {
		return
	}
	if f.inner.procedure != nil {
		f.inner.procedure(f.inner.data, level, text, options, location)
	}
}

filtered_logger :: proc(f: ^Log_Filter) -> log.Logger {
	f.inner = context.logger
	return log.Logger {
		procedure = filter_log,
		data = rawptr(f),
		lowest_level = .Debug,
		options = context.logger.options,
	}
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
	filter: Log_Filter
	context.logger = filtered_logger(&filter)
	web.post(&s.app, "/input", bind_input)
	sync.post(&s.ready)
	web.serve(&s.app, s.port)
}

dial_with_retry :: proc(port: int) -> (net.TCP_Socket, bool) {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	for _ in 0 ..< 200 {
		sock, err := net.dial_tcp(ep)
		if err == nil {
			return sock, true
		}
		time.sleep(5 * time.Millisecond)
	}
	return {}, false
}

send_wrong_type :: proc(port: int) -> (string, bool) {
	BODY :: `{"age":"old"}`
	sock, ok := dial_with_retry(port)
	if !ok {
		return "", false
	}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 3 * time.Second)

	length := int_to_string(len(BODY))
	defer delete(length)
	req := strings.concatenate(
		{
			"POST /input HTTP/1.1\r\nHost: localhost\r\nContent-Length: ",
			length,
			"\r\nConnection: close\r\n\r\n",
			BODY,
		},
	)
	defer delete(req)
	_, send_err := net.send_tcp(sock, transmute([]u8)req)
	if send_err != nil {
		return "", false
	}

	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	buf: [4096]u8
	for {
		n, recv_err := net.recv_tcp(sock, buf[:])
		if n > 0 {
			strings.write_bytes(&b, buf[:n])
		}
		if n == 0 || recv_err != nil {
			break
		}
	}
	return strings.clone(strings.to_string(b)), true
}

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

response_status :: proc(raw: string) -> int {
	if len(raw) < 12 {
		return 0
	}
	status, ok := strconv.parse_int(raw[9:12], 10)
	return status if ok else 0
}

response_body :: proc(raw: string) -> string {
	i := strings.index(raw, "\r\n\r\n")
	return raw[i + 4:] if i >= 0 else ""
}

@(test)
wp68_client_type_error_is_identical_on_memory_and_socket :: proc(t: ^testing.T) {
	filter: Log_Filter
	context.logger = filtered_logger(&filter)

	memory_app := web.app()
	defer web.destroy(&memory_app)
	web.post(&memory_app, "/input", bind_input)
	memory := web.test_request(&memory_app, .POST, "/input", `{"age":"old"}`)
	testing.expect_value(t, memory.status, web.Status.Bad_Request)

	s: Server
	s.app = web.app()
	s.port = 50767
	g_server = &s
	s.thread = thread.create_and_start(serve_thread)
	sync.wait(&s.ready)

	raw, ok := send_wrong_type(s.port)
	if s.thread != nil {
		transport.request_stop()
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}
	web.destroy(&s.app)
	g_server = nil
	testing.expect(t, ok, "the real socket control must receive a response")
	if !ok {
		return
	}
	defer delete(raw)
	testing.expect_value(t, response_status(raw), int(memory.status))
	testing.expect_value(t, response_body(raw), memory.body)
}
