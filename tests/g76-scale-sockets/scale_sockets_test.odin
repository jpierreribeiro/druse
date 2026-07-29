// G7-6 wire proof — many CONCURRENT DETACHED STREAMS on REAL sockets.
//
// The registry-level 3,000 is already proven, deliberately, by
// `tests/wp96-scale` (in memory, no sockets). What that suite cannot show is the
// whole path — real client connections, the owner-lane pump, chunked framing on
// the wire, and a bounded drain — at scale. This suite does, up to the public
// cap.
//
// THE PUBLIC CAP IS 1024, AND THAT IS A FINDING. The detached-stream registry
// defaults to `DEFAULT_MAX_STREAMS = 1024` and there is NO public knob to raise
// it (nothing in `web.Limits` or `web.app` sets stream capacity). So a single
// server admits at most ~1024 concurrent streams through the public surface;
// beyond that `web.stream` returns ok=false. A "3,000 real socket" round on ONE
// server therefore needs either a capacity knob that does not exist yet or three
// servers. This suite proves the real-socket path at `SCALE_CONNS` (default 500,
// safely under the cap); the runbook raises it toward the cap on a quiet host.
//
// DESIGN: one broadcaster for N streams. Each handler opens a stream and hands
// its token to a shared slice; a SINGLE background thread sends a few chunks to
// every token and closes them — N streams, one producer, so the thread count is
// N clients plus one, not 2N.
package test_g76_scale_sockets

import "core:fmt"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

SCALE_CONNS :: #config(SCALE_CONNS, 500)
CHUNKS_PER_STREAM :: 3
PORT :: 55951

// --- shared stream bookkeeping ----------------------------------------------

Tokens :: struct {
	mu:    sync.Mutex,
	toks:  [dynamic]web.Stream,
	open:  int,
}

g_tokens: Tokens
g_app: web.App
g_serve_thread: ^thread.Thread

stream_handler :: proc(ctx: ^web.Context) {
	s, ok := web.stream(ctx, "text/plain")
	if !ok {
		// At capacity or no connection: record nothing; the client will see EOF.
		return
	}
	sync.mutex_lock(&g_tokens.mu)
	append(&g_tokens.toks, s)
	g_tokens.open += 1
	sync.mutex_unlock(&g_tokens.mu)
	// The handler RETURNS; the broadcaster drives the wire from here.
}

serve_thread :: proc() {
	web.serve(&g_app, PORT)
}

// The single producer: once streams have accumulated, send chunks to all, then
// close all. Runs until every collected stream is closed.
broadcaster :: proc() {
	msg := transmute([]u8)string("tick\n")
	// WAIT FOR ACCUMULATION. The clients connect over several lanes and do not
	// all arrive at once; sending before they are open would leave late streams
	// with no chunk. Wait until the open count stops climbing (two stable
	// samples) or a ceiling, so the broadcast covers the whole cohort.
	prev := -1
	for _ in 0 ..< 100 {
		time.sleep(50 * time.Millisecond)
		sync.mutex_lock(&g_tokens.mu)
		cur := g_tokens.open
		sync.mutex_unlock(&g_tokens.mu)
		if cur == prev && cur > 0 {
			break
		}
		prev = cur
	}
	for round in 0 ..< CHUNKS_PER_STREAM {
		time.sleep(120 * time.Millisecond)
		sync.mutex_lock(&g_tokens.mu)
		for s in g_tokens.toks {
			for web.stream_send(s, msg) == .Full {
				time.sleep(time.Millisecond)
			}
		}
		sync.mutex_unlock(&g_tokens.mu)
	}
	time.sleep(120 * time.Millisecond)
	sync.mutex_lock(&g_tokens.mu)
	for s in g_tokens.toks {
		web.stream_close(s)
	}
	sync.mutex_unlock(&g_tokens.mu)
}

// --- clients -----------------------------------------------------------------

Client :: struct {
	got_heading: bool,
	got_chunk:   bool,
}

g_clients: []Client
g_next: int

client_thread :: proc() {
	i := sync.atomic_add(&g_next, 1)
	if i >= len(g_clients) {
		return
	}
	c := &g_clients[i]
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = PORT}
	sock, err := net.dial_tcp(ep)
	if err != nil {
		return
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, 8 * time.Second)
	req := transmute([]u8)string("GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n")
	sent := 0
	for sent < len(req) {
		n, serr := net.send_tcp(sock, req[sent:])
		if serr != nil || n <= 0 {
			return
		}
		sent += n
	}
	// Read until we have the header block and at least one chunk body, or EOF.
	buf: [4096]u8
	total := 0
	for total < len(buf) {
		n, rerr := net.recv_tcp(sock, buf[total:])
		if rerr != nil || n <= 0 {
			break
		}
		total += n
		text := string(buf[:total])
		if !c.got_heading {
			for k := 0; k + 3 < total; k += 1 {
				if buf[k] == '\r' && buf[k + 1] == '\n' && buf[k + 2] == '\r' && buf[k + 3] == '\n' {
					c.got_heading = true
					break
				}
			}
		}
		if c.got_heading {
			// "tick" appears in a chunk body once streaming starts.
			for k := 0; k + 3 < total; k += 1 {
				if buf[k] == 't' && buf[k + 1] == 'i' && buf[k + 2] == 'c' && buf[k + 3] == 'k' {
					c.got_chunk = true
					break
				}
			}
		}
		if c.got_chunk {
			break
		}
	}
}

@(test)
g76_many_concurrent_streams_on_real_sockets :: proc(t: ^testing.T) {
	g_app = web.app()
	l := web.DEFAULT_LIMITS
	l.max_connections = SCALE_CONNS + 64
	// Enough Handler lanes that a burst of brief stream-opening handlers is not
	// refused with 503 (the C-05 lane-contention finding). The handlers only
	// open a stream and return, so they free their lane at once; the lanes exist
	// to absorb the arrival burst, not to do work.
	l.max_handlers = 64
	l.max_drain_time = i64(5 * time.Second)
	web.limits(&g_app, l)
	web.get(&g_app, "/events", stream_handler)
	g_serve_thread = thread.create_and_start(serve_thread)

	// Readiness: a plain connect must succeed.
	ready := false
	for _ in 0 ..< 300 {
		if s, e := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = PORT}); e == nil {
			net.close(s)
			ready = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	if !ready {
		testing.expect(t, false, "server did not become ready")
		return
	}

	bc := thread.create_and_start(broadcaster)

	clients := make([]Client, SCALE_CONNS)
	defer delete(clients)
	g_clients = clients
	g_next = 0
	threads := make([]^thread.Thread, SCALE_CONNS)
	defer delete(threads)
	for i in 0 ..< SCALE_CONNS {
		threads[i] = thread.create_and_start(client_thread)
		// A slight stagger spreads the arrival across the lanes instead of one
		// thundering burst, which is closer to how real clients connect and
		// keeps the accept path from momentarily saturating.
		if i % 32 == 31 {
			time.sleep(2 * time.Millisecond)
		}
	}
	for i in 0 ..< SCALE_CONNS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}
	thread.join(bc)
	thread.destroy(bc)

	headings, chunks := 0, 0
	for c in clients {
		if c.got_heading {
			headings += 1
		}
		if c.got_chunk {
			chunks += 1
		}
	}
	fmt.printf(
		"[g76] conns=%d got_heading=%d got_chunk=%d streams_opened=%d\n",
		SCALE_CONNS,
		headings,
		chunks,
		g_tokens.open,
	)

	// Bounded drain: stop must return within the deadline even with many open.
	started := time.now()
	web.stop(&g_app)
	thread.join(g_serve_thread)
	thread.destroy(g_serve_thread)
	drain := time.since(started)
	web.destroy(&g_app)
	fmt.printf("[g76] drain after stop: %v\n", drain)

	sync.mutex_lock(&g_tokens.mu)
	delete(g_tokens.toks)
	sync.mutex_unlock(&g_tokens.mu)

	// THE WIRE-PATH CLAIM, stated to match what is actually being proven and not
	// to fight the framework's own correct behaviour.
	//
	// (1) EVERY OPENED STREAM RECEIVED A CHUNK. This is the real G7-6 proof: the
	//     owner-lane pump, chunked framing and delivery hold for every admitted
	//     stream. A shortfall here is a wire defect.
	testing.expectf(
		t,
		chunks == g_tokens.open && g_tokens.open > 0,
		"%d of %d OPENED streams received a chunk; the wire path drops admitted streams at scale",
		chunks,
		g_tokens.open,
	)
	// (2) ADMISSION HELD FOR A LARGE FRACTION. Some clients are legitimately
	//     refused with 503 under lane contention (the C-05 finding) — that is
	//     admission working, not the wire failing — so this is a floor, not "all".
	testing.expectf(
		t,
		g_tokens.open * 2 >= SCALE_CONNS,
		"only %d of %d clients were admitted to a stream; admission collapsed under the burst",
		g_tokens.open,
		SCALE_CONNS,
	)
	// (3) THE DRAIN IS BOUNDED even with many streams open — force-closed at the
	//     deadline is acceptable; never returning is not.
	testing.expectf(
		t,
		drain <= 7 * time.Second,
		"the drain took %v with %d streams open; shutdown is not bounded at scale",
		drain,
		g_tokens.open,
	)
}
