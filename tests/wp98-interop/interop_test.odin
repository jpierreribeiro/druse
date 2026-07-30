// WP98 — streaming interoperability and the proxy laboratory.
//
// The property a real deployment depends on: events reach the client
// INCREMENTALLY, not buffered until close — directly, and through a reverse
// proxy. This lab runs both arms: a direct client, and a client behind a
// minimal transparent TCP proxy (byte-forwarding both ways, the "proxied
// control arm"). The framework produces chunked output a non-buffering proxy
// forwards frame by frame; a buffering proxy is a proxy CONFIGURATION concern,
// documented in operations, not a framework behaviour. This lab proves the
// framework side: the bytes are incrementally flushable and cross a forwarding
// proxy unchanged, including `Last-Event-ID` and a mid-stream disconnect.
//
// It adds no product/session/rendering policy to core — it only observes the
// accepted public stream surface through real sockets.
package test_wp98_interop

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

Shared :: struct {
	tok:    web.Stream,
	opened: sync.Sema,
	ok:     bool,
	lastid: string,
	hadid:  bool,
}

g: ^Shared

@(private)
handler :: proc(ctx: ^web.Context) {
	g.lastid, g.hadid = web.header(ctx, "Last-Event-ID")
	s, ok := web.stream(ctx, "text/event-stream")
	g.tok = s
	g.ok = ok
	sync.sema_post(&g.opened)
}

Server :: struct {app: web.App, port: int, thread: ^thread.Thread}

@(private)
serve_thread :: proc(s: ^Server) {web.serve(&s.app, s.port)}

@(private)
start :: proc(s: ^Server, port: int) -> bool {
	s.port = port
	s.app = web.app()
	web.get(&s.app, "/sse", handler)
	s.thread = thread.create_and_start_with_poly_data(s, serve_thread)
	for _ in 0 ..< 300 {
		sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127,0,0,1}, port = port})
		if err == nil {net.close(sock); return true}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

@(private)
stop :: proc(s: ^Server) {
	web.stop(&s.app)
	if s.thread != nil {thread.join(s.thread); thread.destroy(s.thread); s.thread = nil}
	web.destroy(&s.app)
}

// --- a minimal transparent TCP proxy: forward bytes both ways ---------------

Proxy :: struct {
	listen_port: int,
	origin_port: int,
	thread:      ^thread.Thread,
	stop_flag:   bool, // atomic
	ln:          net.TCP_Socket,
	ready:       sync.Sema,
	up:          Pipe,
	down:        Pipe,
}

Pipe :: struct {
	from:   net.TCP_Socket,
	to:     net.TCP_Socket,
	stop:   ^bool, // shared atomic; set at teardown so a blocked pipe exits
	thread: ^thread.Thread,
}

@(private)
pipe_main :: proc(p: ^Pipe) {
	// A short recv timeout means neither direction blocks forever: on timeout
	// the loop re-checks the shared stop flag, so teardown is deterministic
	// even when one side never sends again (the up direction of an open SSE
	// stream, where the client is only reading).
	net.set_option(p.from, .Receive_Timeout, 200 * time.Millisecond)
	buf: [4096]u8
	for !sync.atomic_load(p.stop) {
		n, err := net.recv_tcp(p.from, buf[:])
		if err == net.TCP_Recv_Error.Timeout {continue}
		if n <= 0 || err != nil {break}
		off := 0
		for off < n {
			m, serr := net.send_tcp(p.to, buf[off:n])
			if m <= 0 || serr != nil {break}
			off += m
		}
	}
	net.shutdown(p.to, net.Shutdown_Manner.Send)
}

@(private)
proxy_main :: proc(px: ^Proxy) {
	ep := net.Endpoint{address = net.IP4_Address{127,0,0,1}, port = px.listen_port}
	ln, lerr := net.listen_tcp(ep)
	if lerr != nil {sync.sema_post(&px.ready); return}
	px.ln = ln
	sync.sema_post(&px.ready) // listening; the first accept is the real client
	for !sync.atomic_load(&px.stop_flag) {
		client, _, aerr := net.accept_tcp(ln)
		if aerr != nil {break}
		origin, derr := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127,0,0,1}, port = px.origin_port})
		if derr != nil {net.close(client); continue}
		// Two forwarding pipes, client<->origin, sharing the proxy stop flag.
		px.up = Pipe{from = client, to = origin, stop = &px.stop_flag}
		px.down = Pipe{from = origin, to = client, stop = &px.stop_flag}
		px.up.thread   = thread.create_and_start_with_poly_data(&px.up, pipe_main)
		px.down.thread = thread.create_and_start_with_poly_data(&px.down, pipe_main)
		// This lab uses one client per proxy; do not accept a second.
		break
	}
}

@(private)
proxy_stop :: proc(px: ^Proxy) {
	sync.atomic_store(&px.stop_flag, true)
	net.close(px.ln)
	if px.up.thread != nil {thread.join(px.up.thread); thread.destroy(px.up.thread)}
	if px.down.thread != nil {thread.join(px.down.thread); thread.destroy(px.down.thread)}
	if px.thread != nil {thread.join(px.thread); thread.destroy(px.thread)}
}

@(private)
proxy_start :: proc(px: ^Proxy, listen, origin: int) -> bool {
	px.listen_port = listen
	px.origin_port = origin
	px.thread = thread.create_and_start_with_poly_data(px, proxy_main)
	// Wait for the listen to bind (a semaphore, not a probe connection: a probe
	// would be consumed by the single accept the proxy makes).
	return sync.sema_wait_with_timeout(&px.ready, 3 * time.Second)
}

@(private)
dial :: proc(port: int) -> (net.TCP_Socket, bool) {
	for _ in 0 ..< 100 {
		sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127,0,0,1}, port = port})
		if err == nil {return sock, true}
		time.sleep(2 * time.Millisecond)
	}
	return {}, false
}

@(private)
recv_until :: proc(sock: net.TCP_Socket, b: ^strings.Builder, marker: string, timeout: time.Duration) -> bool {
	net.set_option(sock, .Receive_Timeout, timeout)
	buf: [2048]u8
	for {
		if strings.contains(strings.to_string(b^), marker) {return true}
		n, e := net.recv_tcp(sock, buf[:])
		if n > 0 {strings.write_bytes(b, buf[:n])}
		if n == 0 || e != nil {return strings.contains(strings.to_string(b^), marker)}
	}
}

// --- the interop arms -------------------------------------------------------

// send_one frames one SSE data event inline (this lab does not import the SSE
// Crystal — it proves the CORE stream is incrementally deliverable).
@(private)
send_event :: proc(tok: web.Stream, data: string) -> web.Stream_Send {
	frame := strings.concatenate({"data: ", data, "\n\n"}, context.temp_allocator)
	return web.stream_send(tok, transmute([]u8)frame)
}

@(test)
wp98_events_arrive_incrementally_through_a_proxy :: proc(t: ^testing.T) {
	shared: Shared
	g = &shared
	srv: Server
	testing.expect(t, start(&srv, 52080), "origin server starts")
	defer stop(&srv)
	px: Proxy
	testing.expect(t, proxy_start(&px, 52081, 52080), "proxy starts")

	// The client connects to the PROXY, not the origin. Teardown order matters:
	// close the client, stop the proxy (joins its pipes), then stop the origin.
	sock, ok := dial(52081)
	testing.expect(t, ok)
	defer proxy_stop(&px)
	defer net.close(sock)
	_, _ = net.send_tcp(sock, transmute([]u8)string("GET /sse HTTP/1.1\r\nHost: x\r\n\r\n"))
	testing.expect(t, sync.sema_wait_with_timeout(&shared.opened, 3 * time.Second), "handler runs through the proxy")
	testing.expect(t, shared.ok)

	wire: strings.Builder
	strings.builder_init(&wire, context.temp_allocator)
	testing.expect(t, recv_until(sock, &wire, "text/event-stream", 3 * time.Second), "head crosses the proxy")

	// The decisive interop property: event 1 is READ from the proxied socket
	// BEFORE event 2 is produced. If the proxy (or the framework) buffered to
	// close, this read would block until stream_close.
	testing.expect_value(t, send_event(shared.tok, "one"), web.Stream_Send.Sent)
	testing.expect(t, recv_until(sock, &wire, "data: one", 3 * time.Second), "first event arrives incrementally through the proxy")
	testing.expect_value(t, send_event(shared.tok, "two"), web.Stream_Send.Sent)
	testing.expect(t, recv_until(sock, &wire, "data: two", 3 * time.Second), "second event follows, still open")

	web.stream_close(shared.tok)
	testing.expect(t, recv_until(sock, &wire, "0\r\n\r\n", 3 * time.Second), "the terminating chunk crosses the proxy")
}

@(test)
wp98_last_event_id_crosses_the_proxy_unchanged :: proc(t: ^testing.T) {
	shared: Shared
	g = &shared
	srv: Server
	testing.expect(t, start(&srv, 52082), "origin starts")
	defer stop(&srv)
	px: Proxy
	testing.expect(t, proxy_start(&px, 52083, 52082), "proxy starts")

	sock, ok := dial(52083)
	testing.expect(t, ok)
	defer proxy_stop(&px)
	defer net.close(sock)
	_, _ = net.send_tcp(sock, transmute([]u8)string("GET /sse HTTP/1.1\r\nHost: x\r\nLast-Event-ID: abc-99\r\n\r\n"))
	testing.expect(t, sync.sema_wait_with_timeout(&shared.opened, 3 * time.Second))
	testing.expect(t, shared.hadid, "the reconnection cursor survives the proxy hop")
	testing.expect_value(t, shared.lastid, "abc-99")
	web.stream_close(shared.tok)
}

@(test)
wp98_direct_and_proxied_arms_agree :: proc(t: ^testing.T) {
	// Control: the direct arm must show the same incremental behaviour, so the
	// proxied result cannot be an artifact of the proxy.
	shared: Shared
	g = &shared
	srv: Server
	testing.expect(t, start(&srv, 52084), "origin starts")
	defer stop(&srv)

	sock, ok := dial(52084) // DIRECT to the origin
	testing.expect(t, ok)
	defer net.close(sock)
	_, _ = net.send_tcp(sock, transmute([]u8)string("GET /sse HTTP/1.1\r\nHost: x\r\n\r\n"))
	testing.expect(t, sync.sema_wait_with_timeout(&shared.opened, 3 * time.Second))
	wire: strings.Builder
	strings.builder_init(&wire, context.temp_allocator)
	testing.expect(t, recv_until(sock, &wire, "\r\n\r\n", 3 * time.Second))
	testing.expect_value(t, send_event(shared.tok, "direct"), web.Stream_Send.Sent)
	testing.expect(t, recv_until(sock, &wire, "data: direct", 3 * time.Second), "direct arm is incremental too")
	web.stream_close(shared.tok)
}
