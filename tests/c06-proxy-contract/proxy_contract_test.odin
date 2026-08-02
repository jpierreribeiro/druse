// C-06 — the reverse-proxy contract, as a TESTED topology.
//
// THE POINT. `docs/operations.md` tells operators to run Druse behind a
// reverse proxy, and the readiness matrix (C-02) delegates TLS to it by
// decision. A delegation is an "acceptable operational limitation" **only if
// the topology is mandatory, documented AND TESTED** — that is the
// classification rule in `planning/production-readiness-closure.md` §3, in those
// words. Until this suite existed, the topology was mandatory and documented,
// and its requirements were asserted rather than demonstrated.
//
// THE PROXY IS A FIXTURE IN THIS FILE, and that is a deliberate choice with a
// stated cost. No `nginx`, `caddy` or `haproxy` binary exists on the gate
// machine, and adding one would make the gate depend on a package nobody pinned.
// A ~150-line relay written here instead is:
//
//   + runnable everywhere the gate runs, forever, with no external dependency;
//   + able to switch the ONE behaviour the contract turns on — response
//     buffering — which an installed proxy would need a config file to do;
//   - NOT evidence about nginx. It proves Druse behaves correctly under the
//     contract; it cannot prove that any particular proxy implements it.
//
// This fixture still cannot make a product claim. R1-WP03 has now executed the
// separate pinned Caddy round recorded in
// `planning/closure-proxy-contract.md` and
// `evidence/2026-08-02-r1-real-proxy/`. Keeping both instruments is the
// point: the fast fixture guards Druse behavior on every gate; the Docker
// campaign proves one reviewed real topology.
//
// THE TWO CONTRACT CLAUSES THIS SUITE PROVES, each with a control arm:
//
//   1. RESPONSE BUFFERING MUST BE OFF. This is the clause operators most often
//      leave at its default, and the default is ON in nginx. With buffering on,
//      a proxy reads the upstream response to completion before forwarding a
//      byte — so a DETACHED STREAM, which by construction does not complete,
//      reaches the client NEVER. The suite measures time-to-first-chunk with
//      buffering off and with it on, and the second arm is the demonstration
//      that the requirement is mandatory rather than advisory.
//
//   2. THE CLIENT ADDRESS SURVIVES THE HOP, and only when trusted. The proxy
//      sets `X-Forwarded-For`; `web.client_ip` must report it when the peer is
//      trusted via `web.trust_proxies` and must report the SOCKET peer when it
//      is not. The negative arm is the security half: an untrusted peer that
//      sends the header must not be believed.
//
// NOT PROVEN HERE, and therefore never inferred from this fixture: product
// pooling, duplicated limit precedence, TLS/H2 and readiness-aware shutdown.
// The R1-WP03 real Caddy campaign owns those claims. The keep-alive property
// itself remains independently proven at the wire level by `wp41-fault`
// `phase_keep_alive_serves_two_requests_on_one_connection`.
package test_c06_proxy_contract

import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

UPSTREAM_PORTS :: [?]int{55041, 55367, 55635, 55911}
PROXY_PORT :: 55941

// How long a stream chunk takes to appear. Long enough that "arrived promptly"
// and "arrived only at the end" are not the same measurement.
STREAM_TICK :: 150 * time.Millisecond

// THE STREAM MUST OUTLAST THE PATIENCE, and getting this wrong the first time is
// worth recording. The buffering clause rests on a stream that does NOT complete
// inside the observation window: that is what makes a buffering proxy withhold
// it forever rather than merely late. The first version emitted four chunks —
// 600 ms of stream against 1500 ms of patience — so the stream completed, the
// buffering proxy dutifully forwarded the whole thing at 601 ms, and the arm
// proved nothing. `STREAM_CHUNKS * STREAM_TICK` must stay comfortably ABOVE
// `BUFFERED_PATIENCE`; the gate checks that inequality rather than the numbers.
STREAM_CHUNKS :: 20 // 3.0 s of stream

// The buffering arm's patience: the test gives up rather than waiting for a
// stream that will not complete — and giving up IS the result.
BUFFERED_PATIENCE :: 1200 * time.Millisecond

// ---------------------------------------------------------------------------
// The upstream: an ordinary Druse server.
// ---------------------------------------------------------------------------

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
	done:   sync.Sema,
}

g_server: ^Server

echo_ip_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, web.client_ip(ctx))
}

// A detached stream that emits a chunk every STREAM_TICK and never completes
// within the test's window. This is the shape `proxy_buffering on` destroys.
stream_handler :: proc(ctx: ^web.Context) {
	s, opened := web.stream(ctx, "text/plain")
	if !opened {
		web.text(ctx, .Internal_Server_Error, "no stream")
		return
	}
	thread.create_and_start_with_poly_data(s, stream_pump)
}

stream_pump :: proc(s: web.Stream) {
	for i in 0 ..< STREAM_CHUNKS {
		time.sleep(STREAM_TICK)
		if web.stream_send(s, transmute([]u8)string("tick\n")) == .Closed {
			return
		}
	}
	web.stream_close(s)
}

serve_thread :: proc() {
	s := g_server
	sync.post(&s.ready)
	web.serve(&s.app, s.port)
	sync.post(&s.done)
}

start_upstream :: proc(s: ^Server, trusted: bool) -> bool {
	g_server = s
	for candidate in UPSTREAM_PORTS {
		s.app = web.app()
		l := web.DEFAULT_LIMITS
		l.max_drain_time = i64(3 * time.Second)
		web.limits(&s.app, l)
		if trusted {
			// The proxy runs on loopback, so loopback is the trusted hop. An
			// operator's list is their proxy's address; the rule is identical.
			web.trust_proxies(&s.app, []string{"127.0.0.1"})
		}
		web.get(&s.app, "/whoami", echo_ip_handler)
		web.get(&s.app, "/events", stream_handler)
		s.port = candidate
		s.thread = thread.create_and_start(serve_thread)
		sync.wait(&s.ready)
		if wait_until_accepting(candidate) {
			return true
		}
		web.stop(&s.app)
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
		web.destroy(&s.app)
	}
	return false
}

wait_until_accepting :: proc(port: int) -> bool {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	for _ in 0 ..< 200 {
		sock, err := net.dial_tcp(ep)
		if err == nil {
			net.close(sock)
			return true
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

stop_upstream :: proc(s: ^Server) -> bool {
	if s.thread == nil {
		g_server = nil
		return true
	}
	web.stop(&s.app)
	returned := sync.sema_wait_with_timeout(&s.done, 15 * time.Second)
	if returned {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
		web.destroy(&s.app)
	}
	g_server = nil
	return returned
}

// ---------------------------------------------------------------------------
// The proxy fixture.
// ---------------------------------------------------------------------------

Proxy :: struct {
	listen_port:   int,
	upstream_port: int,
	// The one contract switch. `false` = forward each read immediately (the
	// required configuration); `true` = read the upstream response to completion
	// first (nginx's default, and the misconfiguration this suite exists to
	// demonstrate).
	buffered:      bool,
	stop:          bool,
	ready:         sync.Sema,
	thread:        ^thread.Thread,
}

g_proxy: ^Proxy

proxy_thread :: proc() {
	p := g_proxy
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = p.listen_port}
	listener, lerr := net.listen_tcp(ep)
	if lerr != nil {
		sync.post(&p.ready)
		return
	}
	sync.post(&p.ready)
	for !sync.atomic_load(&p.stop) {
		client, _, aerr := net.accept_tcp(listener)
		if aerr != nil {
			break
		}
		proxy_one(p, client)
		net.close(client)
	}
	net.close(listener)
}

// proxy_one relays a SINGLE client connection: read the request, add
// X-Forwarded-For, forward upstream, relay the response back either as it
// arrives or only once complete.
proxy_one :: proc(p: ^Proxy, client: net.TCP_Socket) {
	up_ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = p.upstream_port}
	upstream, derr := net.dial_tcp(up_ep)
	if derr != nil {
		return
	}
	defer net.close(upstream)
	_ = net.set_option(client, .Receive_Timeout, 2 * time.Second)
	_ = net.set_option(upstream, .Receive_Timeout, 2 * time.Second)

	req: [8192]u8
	n, rerr := net.recv_tcp(client, req[:])
	if rerr != nil || n <= 0 {
		return
	}
	head := string(req[:n])
	// Insert X-Forwarded-For after the request line, exactly as a proxy does.
	// The value is the literal loopback address the client came from; a real
	// proxy formats the peer the same way.
	idx := strings.index(head, "\r\n")
	if idx < 0 {
		return
	}
	rewritten := strings.concatenate(
		{head[:idx + 2], "X-Forwarded-For: 203.0.113.7\r\n", head[idx + 2:]},
		context.temp_allocator,
	)
	out := transmute([]u8)rewritten
	sent := 0
	for sent < len(out) {
		w, werr := net.send_tcp(upstream, out[sent:])
		if werr != nil || w <= 0 {
			return
		}
		sent += w
	}

	if p.buffered {
		// BUFFERED: accumulate the whole upstream response before writing a
		// byte to the client. For a detached stream this never completes, which
		// is the demonstration.
		acc: [dynamic]u8
		defer delete(acc)
		for {
			chunk: [4096]u8
			c, cerr := net.recv_tcp(upstream, chunk[:])
			if cerr != nil || c <= 0 {
				break
			}
			append(&acc, ..chunk[:c])
		}
		if len(acc) > 0 {
			_, _ = net.send_tcp(client, acc[:])
		}
		return
	}

	// UNBUFFERED: forward every read immediately — the required configuration.
	for {
		chunk: [4096]u8
		c, cerr := net.recv_tcp(upstream, chunk[:])
		if cerr != nil || c <= 0 {
			break
		}
		w, werr := net.send_tcp(client, chunk[:c])
		if werr != nil || w <= 0 {
			break
		}
	}
}

start_proxy :: proc(p: ^Proxy, upstream_port: int, buffered: bool) {
	p^ = Proxy {
		listen_port   = PROXY_PORT,
		upstream_port = upstream_port,
		buffered      = buffered,
	}
	g_proxy = p
	p.thread = thread.create_and_start(proxy_thread)
	sync.wait(&p.ready)
	time.sleep(50 * time.Millisecond)
}

stop_proxy :: proc(p: ^Proxy) {
	sync.atomic_store(&p.stop, true)
	// Unblock the accept.
	if sock, err := net.dial_tcp(
		net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = p.listen_port},
	); err == nil {
		net.close(sock)
	}
	thread.join(p.thread)
	thread.destroy(p.thread)
	p.thread = nil
	g_proxy = nil
}

// ---------------------------------------------------------------------------
// Client helpers
// ---------------------------------------------------------------------------

send_all :: proc(sock: net.TCP_Socket, data: string) -> bool {
	buf := transmute([]u8)data
	sent := 0
	for sent < len(buf) {
		n, err := net.send_tcp(sock, buf[sent:])
		if err != nil || n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

get_body :: proc(port: int, path: string, patience := 2 * time.Second) -> (string, bool) {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	sock, err := net.dial_tcp(ep)
	if err != nil {
		return "", false
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, patience)
	req := fmt.tprintf("GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", path)
	if !send_all(sock, req) {
		return "", false
	}
	acc: [dynamic]u8
	defer delete(acc)
	for {
		chunk: [4096]u8
		n, rerr := net.recv_tcp(sock, chunk[:])
		if rerr != nil || n <= 0 {
			break
		}
		append(&acc, ..chunk[:n])
	}
	text := strings.clone(string(acc[:]), context.temp_allocator)
	idx := strings.index(text, "\r\n\r\n")
	if idx < 0 {
		return "", false
	}
	return text[idx + 4:], true
}

// time_to_first_body_byte connects, sends, and returns how long until the FIRST
// byte after the header block arrives — the measurement the buffering clause
// turns on.
time_to_first_body_byte :: proc(
	port: int,
	path: string,
	patience: time.Duration,
) -> (
	elapsed: time.Duration,
	got: bool,
) {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	sock, err := net.dial_tcp(ep)
	if err != nil {
		return 0, false
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, patience)
	req := fmt.tprintf("GET %s HTTP/1.1\r\nHost: localhost\r\n\r\n", path)
	started := time.now()
	if !send_all(sock, req) {
		return 0, false
	}
	acc: [dynamic]u8
	defer delete(acc)
	for time.since(started) < patience {
		chunk: [4096]u8
		n, rerr := net.recv_tcp(sock, chunk[:])
		if rerr != nil || n <= 0 {
			break
		}
		append(&acc, ..chunk[:n])
		text := string(acc[:])
		if idx := strings.index(text, "\r\n\r\n"); idx >= 0 && len(text) > idx + 4 {
			return time.since(started), true
		}
	}
	return time.since(started), false
}

// ---------------------------------------------------------------------------
// Clause 1 — response buffering must be OFF.
// ---------------------------------------------------------------------------

@(test)
c06_a_buffering_proxy_withholds_a_stream_and_an_unbuffered_one_does_not :: proc(t: ^testing.T) {
	server: Server
	if !start_upstream(&server, true) {
		testing.expect(t, false, "no candidate port produced a working upstream")
		return
	}

	// CONTROL ARM: direct, no proxy. Without this a wrong number below would be
	// about the server rather than about the topology.
	direct, direct_ok := time_to_first_body_byte(server.port, "/events", BUFFERED_PATIENCE)
	fmt.printf("[c06] direct        first chunk after %v (got=%v)\n", direct, direct_ok)

	// ARM A: proxied, buffering OFF — the required configuration.
	proxy_a: Proxy
	start_proxy(&proxy_a, server.port, false)
	unbuffered, unbuffered_ok := time_to_first_body_byte(PROXY_PORT, "/events", BUFFERED_PATIENCE)
	stop_proxy(&proxy_a)
	fmt.printf("[c06] buffering off first chunk after %v (got=%v)\n", unbuffered, unbuffered_ok)

	// ARM B: proxied, buffering ON — nginx's DEFAULT, and the misconfiguration.
	proxy_b: Proxy
	start_proxy(&proxy_b, server.port, true)
	buffered, buffered_ok := time_to_first_body_byte(PROXY_PORT, "/events", BUFFERED_PATIENCE)
	stop_proxy(&proxy_b)
	fmt.printf("[c06] buffering ON  first chunk after %v (got=%v)\n", buffered, buffered_ok)

	returned := stop_upstream(&server)

	testing.expect(t, returned, "the upstream must shut down")
	testing.expect(
		t,
		direct_ok,
		"control arm: a stream must reach a DIRECT client, or the proxy arms measure nothing",
	)
	testing.expect(
		t,
		unbuffered_ok,
		"with proxy buffering OFF a stream chunk must reach the client — this is the required topology and it must work",
	)
	// THE CLAUSE. With buffering on, the proxy waits for a response that does not
	// complete, so no chunk arrives inside the window. This is why
	// `proxy_buffering off` is MANDATORY rather than advisable.
	testing.expectf(
		t,
		!buffered_ok,
		"with proxy buffering ON a stream chunk arrived after %v; the demonstration that buffering must be off has stopped demonstrating anything (is the stream completing inside the window?)",
		buffered,
	)
}

// ---------------------------------------------------------------------------
// Clause 2 — the client address survives the hop, and only when trusted.
// ---------------------------------------------------------------------------

@(test)
c06_the_forwarded_client_address_is_believed_only_from_a_trusted_hop :: proc(t: ^testing.T) {
	// TRUSTED arm.
	trusted: Server
	if !start_upstream(&trusted, true) {
		testing.expect(t, false, "no candidate port produced a working upstream")
		return
	}
	proxy: Proxy
	start_proxy(&proxy, trusted.port, false)
	via_proxy, via_ok := get_body(PROXY_PORT, "/whoami")
	stop_proxy(&proxy)
	direct_body, direct_ok := get_body(trusted.port, "/whoami")
	returned_trusted := stop_upstream(&trusted)

	fmt.printf("[c06] trusted:   via proxy=%q direct=%q\n", via_proxy, direct_body)

	// UNTRUSTED arm: same proxy, same header, no `trust_proxies`.
	untrusted: Server
	if !start_upstream(&untrusted, false) {
		testing.expect(t, false, "no candidate port produced a working upstream (untrusted arm)")
		return
	}
	proxy2: Proxy
	start_proxy(&proxy2, untrusted.port, false)
	via_untrusted, via_untrusted_ok := get_body(PROXY_PORT, "/whoami")
	stop_proxy(&proxy2)
	returned_untrusted := stop_upstream(&untrusted)

	fmt.printf("[c06] untrusted: via proxy=%q\n", via_untrusted)

	testing.expect(t, returned_trusted && returned_untrusted, "both upstreams must shut down")
	testing.expect(t, via_ok && direct_ok && via_untrusted_ok, "every arm must produce a body")

	// Trusted: the forwarded address is believed.
	testing.expectf(
		t,
		via_proxy == "203.0.113.7",
		"a trusted proxy's X-Forwarded-For must be reported by web.client_ip, got %q",
		via_proxy,
	)
	// Direct: no header, so the socket peer.
	testing.expectf(
		t,
		direct_body == "127.0.0.1",
		"a direct client must be reported as its socket peer, got %q",
		direct_body,
	)
	// UNTRUSTED — the security half. The identical header from an untrusted peer
	// must NOT be believed, or any client could name its own address in an audit
	// log or a rate limiter.
	testing.expectf(
		t,
		via_untrusted == "127.0.0.1",
		"an UNTRUSTED peer's X-Forwarded-For must be ignored in favour of the socket peer, got %q",
		via_untrusted,
	)
}
