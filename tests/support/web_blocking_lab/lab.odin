// Real-socket synchronous-Handler liveness instrument for WP71/WP72.
package web_blocking_lab

import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import web "druse:web"

Observation_Window :: 250 * time.Millisecond
Baseline_Ceiling :: 25 * time.Millisecond

State :: struct {
	entered: sync.Sema,
	release: sync.Sema,
	middleware_hits: int,
	// WP123 — the detached stream `/stream` opened, and the signal that it is
	// available. The test drives the send side itself, from its own thread,
	// which is the whole point: `web.stream_send` takes neither a Context nor
	// an App, so before WP123 it had no way to say which server it meant.
	stream:       web.Stream,
	stream_open:  bool,
	stream_ready: sync.Sema,
}

Server :: struct {
	state:  State,
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	// WP123 — posted after `web.serve` RETURNS, so a stop can be waited on with
	// a DEADLINE. `thread.join` cannot time out, so a suite built on it can only
	// hang when the thing it tests hangs (the WP58 harness rule, restated in
	// tests/c03-fault-campaign/harness.odin).
	done:   sync.Sema,
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
handler :: proc(ctx: ^web.Context) {
	state, state_ok := web.state(ctx, State)
	if !state_ok {
		web.internal_error(ctx)
		return
	}
	if ctx.request.path == "/block" {
		sync.sema_post(&state.entered)
		sync.sema_wait(&state.release)
	}
	if ctx.request.path == "/upload" {
		title, title_ok := web.form_field(ctx, "title")
		file, file_ok := web.form_file(ctx, "doc")
		if title_ok && title == "a report" && file_ok && file.filename == "notes.txt" && string(file.bytes) == "hello file" {
			web.text(ctx, .OK, "upload")
			return
		}
		web.bad_request(ctx, "invalid upload")
		return
	}
	web.text(ctx, .OK, "ok")
}

@(private)
count_middleware :: proc(ctx: ^web.Context) {
	state, state_ok := web.state(ctx, State)
	if !state_ok {
		web.internal_error(ctx)
		return
	}
	_ = sync.atomic_add(&state.middleware_hits, 1)
	web.next(ctx)
}

@(private)
server_thread :: proc(s: ^Server) {
	web.serve(&s.app, s.port)
	sync.sema_post(&s.done)
}

// stream_handler opens a detached response and PUBLISHES the token, then
// returns — which is the contract: after a successful open the response
// outlives the Context and later code sends on the token from any thread.
@(private)
stream_handler :: proc(ctx: ^web.Context) {
	state, state_ok := web.state(ctx, State)
	if !state_ok {
		web.internal_error(ctx)
		return
	}
	s, ok := web.stream(ctx, "text/plain")
	if !ok {
		web.text(ctx, .Internal_Server_Error, "no-stream")
		return
	}
	state.stream = s
	state.stream_open = true
	sync.sema_post(&state.stream_ready)
}

@(private)
start :: proc(s: ^Server, port: int, limits: web.Limits, features: bool, static_dir: string) -> bool {
	s^ = {}
	s.port = port
	s.app = web.app_with_state(&s.state)
	if features {
		web.cors(&s.app, web.Cors_Options {
			origins = {"https://app.example.com"},
			methods = "GET, POST",
			headers = "Content-Type",
			max_age = 600,
		})
		web.use(&s.app, web.request_id)
		web.use(&s.app, count_middleware)
		web.static(&s.app, "/assets", static_dir, web.Static_Options{})
	}
	web.get(&s.app, "/health", handler)
	web.get(&s.app, "/block", handler)
	web.get(&s.app, "/stream", stream_handler)
	if features {
		web.post(&s.app, "/upload", handler)
	}
	web.limits(&s.app, limits)
	s.thread = thread.create_and_start_with_poly_data(s, server_thread)
	return await_ready(s, port)
}

// await_ready waits for THIS instance's server to answer, and — the part that is
// not obvious — reports false when the bind failed instead of when nothing
// answers.
//
// WHY THAT DISTINCTION IS LOAD-BEARING (WP123). The probe below asks the PORT,
// not the server: if another server in this process already holds it,
// `web.serve` returns `Serve_Listen_Failed` at once and the probe then gets a
// perfectly good 200 from the incumbent. `start` used to return true on that,
// so a caller believed it owned a server it had never started — and every
// subsequent assertion measured somebody else's traffic, stopped somebody
// else's server, and read as green while doing it. Measured while writing
// `tests/wp123-two-servers`: four parallel tests all "started" on one port,
// one server answered for all four, and the counters were individually
// plausible throughout.
//
// A `serve` that RETURNED before the server was ever ready did not bind. That is
// the signal, it is unambiguous, and it arrives on `done` before the probe can
// be fooled.
@(private)
await_ready :: proc(s: ^Server, port: int) -> bool {
	for _ in 0 ..< 200 {
		if sync.sema_wait_with_timeout(&s.done, 2 * time.Millisecond) {
			abandon(s)
			return false
		}
		status, _, ok := Request(port, "/health")
		if ok && status == 200 {
			return true
		}
	}
	abandon(s)
	return false
}

// abandon releases a server that never became ready. Without it a failed start
// leaks the thread and the App, and the next `Start` on the same value would
// zero a `Server` whose thread is still running against it.
@(private)
abandon :: proc(s: ^Server) {
	web.stop(&s.app)
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}
	web.destroy(&s.app)
}

Start :: proc(s: ^Server, port: int, max_handlers: int) -> bool {
	limits := web.DEFAULT_LIMITS
	limits.max_handlers = max_handlers
	return start(s, port, limits, false, "")
}

Start_With_Admission :: proc(
	s: ^Server,
	port, max_handlers, max_connections, reserved_conns: int,
) -> bool {
	limits := web.DEFAULT_LIMITS
	limits.max_handlers = max_handlers
	limits.max_connections = max_connections
	limits.reserved_conns = reserved_conns
	limits.max_request_time = 0
	return start(s, port, limits, false, "")
}

Start_With_Limits :: proc(s: ^Server, port: int, limits: web.Limits) -> bool {
	return start(s, port, limits, false, "")
}

// Start_With_Upload enables spooled large-body ingestion on this instance only.
// `dir` must be this instance's OWN directory: `enable_upload` sweeps leftover
// spools out of it at boot, so two servers sharing one delete each other's live
// files (audit M8).
Start_With_Upload :: proc(s: ^Server, port: int, dir: string) -> bool {
	limits := web.DEFAULT_LIMITS
	limits.max_body = 1024
	s^ = {}
	s.port = port
	s.app = web.app_with_state(&s.state)
	web.enable_upload(
		&s.app,
		web.Upload_Config{dir = dir, per_upload_quota = 8 * 1024 * 1024, max_concurrent = 4},
	)
	web.get(&s.app, "/health", handler)
	web.get(&s.app, "/block", handler)
	web.get(&s.app, "/stream", stream_handler)
	web.post(&s.app, "/spool", upload_handler)
	web.limits(&s.app, limits)
	s.thread = thread.create_and_start_with_poly_data(s, server_thread)
	return await_ready(s, port)
}

// upload_handler reports whether THIS request's body was spooled. It is the
// observable difference between a server whose admission is open and one whose
// admission has been drained: a drained admission refuses the spool, so a body
// over `max_body` is answered 413 instead of 201.
@(private)
upload_handler :: proc(ctx: ^web.Context) {
	up, ok := web.upload(ctx)
	if !ok {
		web.text(ctx, .OK, "buffered")
		return
	}
	_ = up
	web.text(ctx, .Created, "spooled")
}

// Stream returns the token `/stream` published, once it is available.
Stream :: proc(s: ^Server, timeout := 3 * time.Second) -> (web.Stream, bool) {
	if !sync.sema_wait_with_timeout(&s.state.stream_ready, timeout) {
		return {}, false
	}
	return s.state.stream, s.state.stream_open
}

Start_With_Features :: proc(s: ^Server, port: int, limits: web.Limits, static_dir: string) -> bool {
	if !os.exists(static_dir) {
		return false
	}
	return start(s, port, limits, true, static_dir)
}

Middleware_Hits :: proc(s: ^Server) -> int {
	return sync.atomic_load(&s.state.middleware_hits)
}

Stop :: proc(s: ^Server) {
	sync.sema_post(&s.state.release, 64)
	web.stop(&s.app)
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}
	web.destroy(&s.app)
}

// Stop_Async asks THIS server to drain and returns at once. It does not join —
// see `Server.done`. Pair it with `Wait_Stopped` and then `Reap`.
Stop_Async :: proc(s: ^Server) {
	sync.sema_post(&s.state.release, 64)
	web.stop(&s.app)
}

// Wait_Stopped waits, WITH A DEADLINE, for this server's `web.serve` to return.
Wait_Stopped :: proc(s: ^Server, timeout := 5 * time.Second) -> bool {
	return sync.sema_wait_with_timeout(&s.done, timeout)
}

// Reap releases the thread and the App, after `Wait_Stopped` reported the drain
// finished. Separate from `Stop_Async` so a test can assert on a stopped server
// before its storage goes away.
Reap :: proc(s: ^Server) {
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}
	web.destroy(&s.app)
}

Wait_Entered :: proc(s: ^Server, timeout := 2 * time.Second) -> bool {
	return sync.sema_wait_with_timeout(&s.state.entered, timeout)
}

Release :: proc(s: ^Server, count: int) {
	if count > 0 {
		sync.sema_post(&s.state.release, count)
	}
}

@(private)
parse_status :: proc(raw: string) -> int {
	if len(raw) < 12 {return 0}
	value, ok := strconv.parse_int(raw[9:12], 10)
	return value if ok else 0
}

Request :: proc(port: int, path: string) -> (status: int, elapsed: time.Duration, ok: bool) {
	started := time.now()
	endpoint := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	sock: net.TCP_Socket
	connected := false
	for _ in 0 ..< 100 {
		err: net.Network_Error
		sock, err = net.dial_tcp(endpoint)
		if err == nil {
			connected = true
			break
		}
		time.sleep(2 * time.Millisecond)
	}
	if !connected {return 0, time.since(started), false}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 3 * time.Second)

	request, err := strings.concatenate({"GET ", path, " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"})
	if err != nil {return 0, time.since(started), false}
	defer delete(request)
	if _, send_err := net.send_tcp(sock, transmute([]u8)request); send_err != nil {
		return 0, time.since(started), false
	}

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	buffer: [4096]u8
	for {
		n, recv_err := net.recv_tcp(sock, buffer[:])
		if n > 0 {strings.write_bytes(&builder, buffer[:n])}
		if n == 0 || recv_err != nil {break}
	}
	status = parse_status(strings.to_string(builder))
	return status, time.since(started), status != 0
}

Open_Idle :: proc(port: int) -> (net.TCP_Socket, bool) {
	endpoint := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	for _ in 0 ..< 100 {
		sock, err := net.dial_tcp(endpoint)
		if err == nil {
			return sock, true
		}
		time.sleep(2 * time.Millisecond)
	}
	return {}, false
}

Raw_Request :: proc(port: int, request: string) -> (status: int, raw: string, ok: bool) {
	endpoint := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	sock, connected := net.dial_tcp(endpoint)
	if connected != nil {
		return 0, "", false
	}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 3 * time.Second)
	if _, err := net.send_tcp(sock, transmute([]u8)request); err != nil {
		return 0, "", false
	}
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	buffer: [4096]u8
	for {
		n, err := net.recv_tcp(sock, buffer[:])
		if n > 0 {strings.write_bytes(&builder, buffer[:n])}
		if n == 0 || err != nil {break}
	}
	view := strings.to_string(builder)
	status = parse_status(view)
	copy := strings.clone(view)
	return status, copy, status != 0
}

Open_Keepalive :: proc(port: int) -> (net.TCP_Socket, bool) {
	sock, ok := Open_Idle(port)
	if !ok {return {}, false}
	net.set_option(sock, .Receive_Timeout, 2 * time.Second)
	request := "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n"
	if _, err := net.send_tcp(sock, transmute([]u8)string(request)); err != nil {
		net.close(sock)
		return {}, false
	}
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	buffer: [1024]u8
	for {
		n, err := net.recv_tcp(sock, buffer[:])
		if n > 0 {strings.write_bytes(&builder, buffer[:n])}
		view := strings.to_string(builder)
		if strings.contains(view, "\r\n\r\nok") {
			return sock, true
		}
		if n == 0 || err != nil {
			net.close(sock)
			return {}, false
		}
	}
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
