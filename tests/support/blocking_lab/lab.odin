// Deterministic blocking-boundary instrument shared by WP69 tests and report.
// It uses odin-http directly so the experiment can vary its existing lane
// count without adding a speculative Druse public setting before evidence.
package blocking_lab

import "core:net"
import "core:nbio"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import http "druse:vendor/odin-http"

Observation_Window :: 250 * time.Millisecond
Baseline_Ceiling :: 25 * time.Millisecond

Server :: struct {
	backend:     http.Server,
	port:        int,
	lanes:       int,
	thread:      ^thread.Thread,
	ready:       sync.Sema,
	entered:     sync.Sema,
	release:     sync.Sema,
	stopped:     sync.Sema,
	listen_ok:   bool,
	suspend_handlers: bool,
}

Call :: struct {
	port:    int,
	path:    string,
	thread:  ^thread.Thread,
	done:    sync.Sema,
	ok:      bool,
	status:  int,
	elapsed: time.Duration,
}

@(private)
handler :: proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
	s := (^Server)(h.user_data)
	path := req.url.path
	entered_lane := false
	if path == "/block" && s.suspend_handlers {
		entered_lane = http.handler_lane_enter(res)
		assert(entered_lane)
	}
	defer {
		if entered_lane {
			http.handler_lane_leave(res)
		}
	}
	if path == "/block" {
		sync.sema_post(&s.entered)
		sync.sema_wait(&s.release)
	}

	http.headers_set_close(&res.headers)
	res.status = .OK
	if path == "/large" {
		body := make([]u8, 256 * 1024, context.temp_allocator)
		for &byte in body {
			byte = 'x'
		}
		http.body_set(res, transmute(string)body)
	} else {
		http.body_set(res, "ok")
	}
	http.respond(res)
}

@(private)
server_thread :: proc(s: ^Server) {
	defer sync.sema_post(&s.stopped)
	opts := http.Default_Server_Opts
	opts.thread_count = s.lanes
	opts.redirect_head_to_get = false
	opts.auto_expect_continue = false
	opts.max_drain_time = 2 * time.Second

	endpoint := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port = s.port,
	}
	err := http.listen(&s.backend, endpoint, opts)
	s.listen_ok = err == nil
	sync.sema_post(&s.ready)
	if err != nil {
		return
	}

	h: http.Handler
	h.user_data = s
	h.handle = handler
	http.serve(&s.backend, h)
	// odin-http is process-oriented and leaves the caller lane's event loop
	// acquired after serve. The laboratory starts several independent servers
	// in one process, so release it explicitly or the next arm inherits stale
	// pending state and the result becomes order-dependent.
	nbio.release_thread_event_loop()
}

@(private)
start :: proc(s: ^Server, port, lanes: int, suspend_handlers: bool) -> bool {
	// The lab intentionally starts several servers in one process. Odin's
	// address reuse must not carry posted cleanup permits into the next arm.
	s^ = {}
	s.port = port
	s.lanes = lanes
	s.suspend_handlers = suspend_handlers
	s.thread = thread.create_and_start_with_poly_data(s, server_thread)
	if !sync.sema_wait_with_timeout(&s.ready, 2 * time.Second) {
		return false
	}
	if !s.listen_ok {
		return false
	}
	// `listen` precedes `serve`, and the latter arms the per-lane accepts.
	// A completed request is the public readiness barrier; the listening socket
	// alone is not evidence that every server thread has entered its event loop.
	status, _, ok := Request(port, "/health")
	if !ok || status != 200 {
		return false
	}
	time.sleep(25 * time.Millisecond)
	return true
}

Start :: proc(s: ^Server, port, lanes: int) -> bool {
	return start(s, port, lanes, false)
}

// Start_Suspended brackets the blocking application call with the WP71
// admission discipline. It is a white-box control instrument, not a second
// server model: WP71 proves that accepts belong to the dedicated acceptor,
// never to a blocked Handler lane.
Start_Suspended :: proc(s: ^Server, port, lanes: int) -> bool {
	return start(s, port, lanes, true)
}

Suspended_Lane_State :: proc(s: ^Server) -> (active, active_with_lane_accept: int, dedicated_accept_active: bool) {
	for &lane in s.backend.threads {
		if lane.handler_active {
			active += 1
			if lane.accept != nil {
				active_with_lane_accept += 1
			}
		}
	}
	dedicated_accept_active = s.backend.accept != nil
	return
}

Release :: proc(s: ^Server, count: int) {
	if count > 0 {
		sync.sema_post(&s.release, count)
	}
}

Wait_Entered :: proc(s: ^Server, timeout := 2 * time.Second) -> bool {
	return sync.sema_wait_with_timeout(&s.entered, timeout)
}

Stop :: proc(s: ^Server) {
	// Enough permits to prevent a failed assertion from leaving a handler
	// stuck and turning a test failure into a hung process.
	Release(s, max(1, s.lanes + 2))
	Request_Stop(s)
	Join_Server(s)
}

Request_Stop :: proc(s: ^Server) {
	if s.listen_ok {
		http.server_shutdown(&s.backend)
	}
}

Wait_Stopped :: proc(s: ^Server, timeout: time.Duration) -> bool {
	return sync.sema_wait_with_timeout(&s.stopped, timeout)
}

Join_Server :: proc(s: ^Server) {
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}
}

@(private)
dial_with_retry :: proc(port: int) -> (net.TCP_Socket, bool) {
	endpoint := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	for _ in 0 ..< 200 {
		sock, err := net.dial_tcp(endpoint)
		if err == nil {
			return sock, true
		}
		time.sleep(2 * time.Millisecond)
	}
	return {}, false
}

Open_Idle :: proc(port: int) -> (net.TCP_Socket, bool) {
	return dial_with_retry(port)
}

Open_Slow_Reader :: proc(port: int) -> (net.TCP_Socket, bool) {
	sock, ok := dial_with_retry(port)
	if !ok {
		return {}, false
	}
	_, err := net.send_tcp(sock, transmute([]u8)string("GET /health HTTP/1.1\r\nHost: localhost\r\n"))
	if err != nil {
		net.close(sock)
		return {}, false
	}
	return sock, true
}

Open_Slow_Writer :: proc(port: int) -> (net.TCP_Socket, bool) {
	sock, ok := dial_with_retry(port)
	if !ok {
		return {}, false
	}
	// Keep the receiver window deliberately small and do not read the 4 MiB
	// response. The server must retain a pending write without losing progress
	// on unrelated connections.
	net.set_option(sock, .Receive_Buffer_Size, 1024)
	_, err := net.send_tcp(sock, transmute([]u8)string("GET /large HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
	if err != nil {
		net.close(sock)
		return {}, false
	}
	return sock, true
}

@(private)
parse_status :: proc(raw: string) -> int {
	if len(raw) < 12 {
		return 0
	}
	status, ok := strconv.parse_int(raw[9:12], 10)
	return status if ok else 0
}

Request :: proc(port: int, path: string) -> (status: int, elapsed: time.Duration, ok: bool) {
	started := time.now()
	sock, connected := dial_with_retry(port)
	if !connected {
		return 0, time.since(started), false
	}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 3 * time.Second)

	req, make_err := strings.concatenate({"GET ", path, " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"})
	if make_err != nil {
		return 0, time.since(started), false
	}
	defer delete(req)
	if _, err := net.send_tcp(sock, transmute([]u8)req); err != nil {
		return 0, time.since(started), false
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	buffer: [4096]u8
	for {
		n, err := net.recv_tcp(sock, buffer[:])
		if n > 0 {
			strings.write_bytes(&builder, buffer[:n])
		}
		if n == 0 || err != nil {
			break
		}
	}
	raw := strings.to_string(builder)
	status = parse_status(raw)
	return status, time.since(started), status != 0
}

@(private)
call_thread :: proc(c: ^Call) {
	c.status, c.elapsed, c.ok = Request(c.port, c.path)
	sync.sema_post(&c.done)
}

Start_Call :: proc(c: ^Call, port: int, path: string) {
	c^ = {}
	c.port = port
	c.path = path
	c.thread = thread.create_and_start_with_poly_data(c, call_thread)
}

Wait_Call :: proc(c: ^Call, timeout: time.Duration) -> bool {
	return sync.sema_wait_with_timeout(&c.done, timeout)
}

Join_Call :: proc(c: ^Call) {
	if c.thread != nil {
		thread.join(c.thread)
		thread.destroy(c.thread)
		c.thread = nil
	}
}

Connection_Record_Bytes :: size_of(http.Connection)
Lane_Record_Bytes :: size_of(http.Server_Thread)
