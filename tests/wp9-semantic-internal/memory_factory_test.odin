// WP9 — SEMANTIC CONFORMANCE, in-memory factory.
//
// This file declares `package web` and is compiled in a THROWAWAY package
// against the real `web/` sources, exactly like WP2-WP8. It is here, and not in
// an external package, for one reason: the in-memory factory must drive the
// SAME private pipeline the real transport drives (`driver_run` /
// `driver_cleanup`). Running the shared matrix through the identical driver is
// what makes semantic parity structural rather than a claim — a divergence can
// then only come from the transport itself, which is the whole point of R-10.
//
// The matching real-socket factory lives in `tests/wp9-semantic/`, outside the
// package, and runs the SAME matrix from `tests/support/transport_conformance`.
#+private
package web

import "core:log"
import "core:strings"
import "core:testing"
import tc "druse:tests/support/transport_conformance"
import transport "druse:web/internal/transport"

// ---------------------------------------------------------------------------
// The fixture application. It is duplicated, deliberately and minimally, in the
// external socket suite: the two packages cannot share Odin code (one is
// `package web`), but they register byte-identical routes and the shared matrix
// asserts identical results, so a drift between them fails immediately.
// ---------------------------------------------------------------------------

@(private = "file")
User_Id :: struct {
	id: int `json:"id"`,
}

@(private = "file")
Search_Result :: struct {
	q:     string `json:"q"`,
	limit: int    `json:"limit"`,
}

@(private = "file")
Echo :: struct {
	name: string `json:"name"`,
}

@(private = "file")
First_Wins :: struct {
	first: bool `json:"first"`,
}

@(private = "file")
mem_ping :: proc(ctx: ^Context) {
	text(ctx, .OK, "pong")
}

@(private = "file")
mem_user :: proc(ctx: ^Context) {
	id, found := path_int(ctx, "id")
	if !found {
		return
	}
	ok(ctx, User_Id{id = id})
}

@(private = "file")
mem_search :: proc(ctx: ^Context) {
	q, _ := query(ctx, "q")
	limit, found := query_int_or(ctx, "limit", 20)
	if !found {
		return
	}
	ok(ctx, Search_Result{q = q, limit = limit})
}

@(private = "file")
mem_create :: proc(ctx: ^Context) {
	input: Echo
	if !body(ctx, &input) {
		return
	}
	created(ctx, input)
}

@(private = "file")
mem_no_content :: proc(ctx: ^Context) {
	no_content(ctx)
}

@(private = "file")
mem_silent :: proc(ctx: ^Context) {
	// Responds with nothing on purpose (WP8 D5).
}

@(private = "file")
mem_twice :: proc(ctx: ^Context) {
	ok(ctx, First_Wins{first = true})
	// Everything after the first commit is a no-op (ADR-008).
	text(ctx, .Internal_Server_Error, "second")
	no_content(ctx)
}

@(private = "file")
mem_register :: proc(a: ^App) {
	get(a, "/ping", mem_ping)
	get(a, "/users/:id", mem_user)
	get(a, "/search", mem_search)
	post(a, "/users", mem_create)
	put(a, "/users/:id", mem_no_content)
	patch(a, "/users/:id", mem_no_content)
	delete(a, "/users/:id", mem_no_content)
	get(a, "/silent", mem_silent)
	get(a, "/twice", mem_twice)
}

// ---------------------------------------------------------------------------
// The factory.
//
// `exchange` builds the neutral inbound and runs `driver_run` + `driver_cleanup`
// — the very procedures `web.serve` uses. It binds no socket and parses no
// request line: the in-memory transport is never taught to imitate TCP (D1).
// ---------------------------------------------------------------------------

@(private = "file")
Memory_State :: struct {
	app:      App,
	status:   int,
	body:     string,
	headers:  [dynamic]tc.Header,
}

@(private = "file")
memory_start :: proc(user: rawptr) -> bool {
	state := (^Memory_State)(user)
	state.app = app()
	mem_register(&state.app)
	return true
}

@(private = "file")
memory_exchange :: proc(user: rawptr, req: tc.Exchange_Request) -> tc.Exchange_Response {
	state := (^Memory_State)(user)

	inbound := transport.Inbound {
		method  = req.method,
		path    = req.path,
		query   = req.query,
		headers = transport_headers(req.headers),
		body    = req.body,
	}

	ctx: Context
	driver_run(&state.app, &ctx, inbound)

	// Copy the response out BEFORE teardown, exactly as a real driver must.
	res := &ctx.private.response
	clear(&state.headers)
	for pair in res.headers {
		append(
			&state.headers,
			tc.Header {
				name = strings.clone(pair.name, context.temp_allocator),
				value = strings.clone(pair.value, context.temp_allocator),
			},
		)
	}
	status := int(res.status)
	body_copy := strings.clone(string(res.body), context.temp_allocator)

	driver_cleanup(&ctx)

	return tc.Exchange_Response {
		status = status,
		body = body_copy,
		headers = state.headers[:],
		ok = true,
	}
}

// transport_headers converts the harness's neutral headers into the transport's
// neutral headers. Two identical-looking types, deliberately: the harness is
// test-only and must not depend on the private transport package's shape.
@(private = "file")
transport_headers :: proc(headers: []tc.Header) -> []transport.Header {
	if len(headers) == 0 {
		return nil
	}
	out := make([]transport.Header, len(headers), context.temp_allocator)
	for header, i in headers {
		out[i] = transport.Header{name = header.name, value = header.value}
	}
	return out
}

@(private = "file")
memory_stop :: proc(user: rawptr) {}

@(private = "file")
memory_destroy :: proc(user: rawptr) {
	state := (^Memory_State)(user)
	delete_dynamic_array(state.headers)
	destroy(&state.app)
}

@(test)
wp9_semantic_matrix_on_the_memory_transport :: proc(t: ^testing.T) {
	filter: Wp9_Log_Filter
	context.logger = wp9_swallow(&filter)

	state: Memory_State
	state.headers = make([dynamic]tc.Header)

	factory := tc.Transport_Factory {
		name     = "memory",
		user     = rawptr(&state),
		start    = memory_start,
		exchange = memory_exchange,
		stop     = memory_stop,
		destroy  = memory_destroy,
	}
	tc.transport_contract_test(t, factory)
}

// ---------------------------------------------------------------------------
// A logger filter: some scenarios deliberately provoke the framework's own
// Error diagnostic (a silent handler becomes a logged 500), and `odin test`
// counts any Error record as a failure.
// ---------------------------------------------------------------------------

@(private = "file")
Wp9_Log_Filter :: struct {
	inner: log.Logger,
}

@(private = "file")
wp9_filter_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	filter := (^Wp9_Log_Filter)(data)
	if level == .Error && strings.contains(text, "druse:") {
		return
	}
	if filter.inner.procedure != nil {
		filter.inner.procedure(filter.inner.data, level, text, options, location)
	}
}

@(private = "file")
wp9_swallow :: proc(filter: ^Wp9_Log_Filter) -> log.Logger {
	filter.inner = context.logger
	return log.Logger {
		procedure = wp9_filter_proc,
		data = rawptr(filter),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}
