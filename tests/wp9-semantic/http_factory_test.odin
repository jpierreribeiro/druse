// WP9 — SEMANTIC CONFORMANCE, real-HTTP factory.
//
// This package is an EXTERNAL consumer of `druse:web`: it registers routes and
// calls `web.serve` exactly as an application would, then drives the SAME shared
// matrix (`tests/support/transport_conformance`) that the in-memory factory runs
// in `tests/wp9-semantic-internal/`.
//
// One matrix, two transports. If the in-memory transport ever diverges from a
// real socket, exactly one of the two suites fails and names the scenario —
// which is the mitigation R-10 asks for.
//
// The client below is deliberately dumb: it writes a request and reads until the
// peer closes. It is not a production HTTP parser and must never become one.
package wp9_semantic

import "core:log"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import tc "druse:tests/support/transport_conformance"
import web "druse:web"
import transport "druse:web/internal/transport"

// ---------------------------------------------------------------------------
// The fixture application — byte-identical routes to the in-memory suite.
// ---------------------------------------------------------------------------

User_Id :: struct {
	id: int `json:"id"`,
}

Search_Result :: struct {
	q:     string `json:"q"`,
	limit: int    `json:"limit"`,
}

Echo :: struct {
	name: string `json:"name"`,
}

First_Wins :: struct {
	first: bool `json:"first"`,
}

ping_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

user_handler :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}
	web.ok(ctx, User_Id{id = id})
}

search_handler :: proc(ctx: ^web.Context) {
	q, _ := web.query(ctx, "q")
	limit, ok := web.query_int_or(ctx, "limit", 20)
	if !ok {
		return
	}
	web.ok(ctx, Search_Result{q = q, limit = limit})
}

create_handler :: proc(ctx: ^web.Context) {
	input: Echo
	if !web.body(ctx, &input) {
		return
	}
	web.created(ctx, input)
}

no_content_handler :: proc(ctx: ^web.Context) {
	web.no_content(ctx)
}

silent_handler :: proc(ctx: ^web.Context) {
	// Responds with nothing on purpose (WP8 D5).
}

twice_handler :: proc(ctx: ^web.Context) {
	web.ok(ctx, First_Wins{first = true})
	web.text(ctx, .Internal_Server_Error, "second")
	web.no_content(ctx)
}

register_fixture :: proc(a: ^web.App) {
	web.get(a, "/ping", ping_handler)
	web.get(a, "/users/:id", user_handler)
	web.get(a, "/search", search_handler)
	web.post(a, "/users", create_handler)
	web.put(a, "/users/:id", no_content_handler)
	web.patch(a, "/users/:id", no_content_handler)
	web.delete(a, "/users/:id", no_content_handler)
	web.get(a, "/silent", silent_handler)
	web.get(a, "/twice", twice_handler)
}

// ---------------------------------------------------------------------------
// The factory.
// ---------------------------------------------------------------------------

CANDIDATE_PORTS :: [?]int{47931, 48837, 49391, 50273}

Http_State :: struct {
	app:     web.App,
	port:    int,
	thread:  ^thread.Thread,
	ready:   sync.Sema,
	started: bool,
}

g_http_state: ^Http_State

http_serve_thread :: proc() {
	state := g_http_state
	sync.post(&state.ready)
	web.serve(&state.app, state.port)
}

http_start :: proc(user: rawptr) -> bool {
	state := (^Http_State)(user)
	g_http_state = state

	for candidate in CANDIDATE_PORTS {
		state.app = web.app()
		register_fixture(&state.app)
		state.port = candidate
		state.thread = thread.create_and_start(http_serve_thread)
		sync.wait(&state.ready)

		// Readiness is a real connection, not a fixed sleep.
		if wait_until_accepting(candidate) {
			state.started = true
			return true
		}

		transport.request_stop()
		thread.join(state.thread)
		thread.destroy(state.thread)
		state.thread = nil
		web.destroy(&state.app)
	}
	return false
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

http_exchange :: proc(user: rawptr, req: tc.Exchange_Request) -> tc.Exchange_Response {
	state := (^Http_State)(user)

	target := req.path
	if req.query != "" {
		target = strings.concatenate({req.path, "?", req.query}, context.temp_allocator)
	}

	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, req.method)
	strings.write_byte(&builder, ' ')
	strings.write_string(&builder, target)
	strings.write_string(&builder, " HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n")
	for header in req.headers {
		strings.write_string(&builder, header.name)
		strings.write_string(&builder, ": ")
		strings.write_string(&builder, header.value)
		strings.write_string(&builder, "\r\n")
	}
	if len(req.body) > 0 {
		strings.write_string(&builder, "Content-Length: ")
		strings.write_int(&builder, len(req.body))
		strings.write_string(&builder, "\r\n")
	}
	strings.write_string(&builder, "\r\n")
	if len(req.body) > 0 {
		strings.write_bytes(&builder, req.body)
	}

	raw := send_and_read(state.port, strings.to_string(builder))
	defer delete(raw)
	return parse_response(raw)
}

http_stop :: proc(user: rawptr) {
	state := (^Http_State)(user)
	if state.thread == nil {
		return
	}
	transport.request_stop()
	thread.join(state.thread)
	thread.destroy(state.thread)
	state.thread = nil
}

http_destroy :: proc(user: rawptr) {
	state := (^Http_State)(user)
	if state.started {
		web.destroy(&state.app)
	}
	g_http_state = nil
}

@(test)
wp9_semantic_matrix_on_the_real_http_transport :: proc(t: ^testing.T) {
	filter: Log_Filter
	context.logger = swallow_framework_log(&filter)

	state: Http_State
	factory := tc.Transport_Factory {
		name     = "odin_http",
		user     = rawptr(&state),
		start    = http_start,
		exchange = http_exchange,
		stop     = http_stop,
		destroy  = http_destroy,
	}
	tc.transport_contract_test(t, factory)
}

// ---------------------------------------------------------------------------
// The dumb client.
// ---------------------------------------------------------------------------

send_and_read :: proc(port: int, payload: string) -> string {
	endpoint := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}

	sock, dial_err := net.dial_tcp(endpoint)
	if dial_err != nil {
		return strings.clone("")
	}
	defer net.close(sock)

	net.set_option(sock, .Receive_Timeout, 3 * time.Second)
	net.send_tcp(sock, transmute([]u8)payload)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	buf: [4096]u8
	for {
		n, err := net.recv_tcp(sock, buf[:])
		if n > 0 {
			strings.write_bytes(&builder, buf[:n])
		}
		if n == 0 || err != nil {
			break
		}
	}
	return strings.clone(strings.to_string(builder))
}

// parse_response reads exactly what the matrix asserts on: the status, the
// headers, and the body. It is not a production parser.
parse_response :: proc(raw: string) -> tc.Exchange_Response {
	res: tc.Exchange_Response
	if len(raw) == 0 {
		return res
	}

	head_end := strings.index(raw, "\r\n\r\n")
	if head_end < 0 {
		return res
	}
	head := raw[:head_end]
	body := raw[head_end + 4:]

	lines := strings.split(head, "\r\n", context.temp_allocator)
	if len(lines) == 0 {
		return res
	}

	status_line := lines[0]
	if len(status_line) >= 12 {
		code, ok := strconv.parse_int(strings.trim_space(status_line[9:12]), 10)
		if ok {
			res.status = code
		}
	}

	headers := make([dynamic]tc.Header, context.temp_allocator)
	for line in lines[1:] {
		colon := strings.index_byte(line, ':')
		if colon <= 0 {
			continue
		}
		// CLONE both. `line` is a view into `raw`, which the caller frees the
		// moment `http_exchange` returns — returning views would hand the
		// assertions freed memory. That was a real use-after-free here: it read
		// correctly most of the time and lost the `Allow` header roughly one run
		// in three, which is exactly how a harness bug disguises itself as a
		// flaky framework.
		append(
			&headers,
			tc.Header {
				name = strings.clone(
					strings.trim_space(line[:colon]),
					context.temp_allocator,
				),
				value = strings.clone(
					strings.trim_space(line[colon + 1:]),
					context.temp_allocator,
				),
			},
		)
	}
	res.headers = headers[:]
	res.body = strings.clone(body, context.temp_allocator)
	res.ok = true
	return res
}

// ---------------------------------------------------------------------------
// A logger filter: some scenarios deliberately provoke the framework's own
// Error diagnostic, and `odin test` counts any Error record as a failure.
// ---------------------------------------------------------------------------

Log_Filter :: struct {
	inner: log.Logger,
}

filter_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	filter := (^Log_Filter)(data)
	if level == .Error && strings.contains(text, "druse:") {
		return
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
