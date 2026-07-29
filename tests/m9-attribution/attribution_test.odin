// M9 — attribute large-request retention instead of inferring it from RSS.
//
// RSS cannot distinguish a live allocation from pages a process allocator has
// already freed but not returned to the kernel. This test wraps the allocator
// the backend captures as `Server.conn_allocator`, blocks four handlers while
// their 3 MiB request bodies are live, and samples the same allocator again
// after the responses have completed and scanner_reset has run.
//
// The blocked phase is the positive control: if the tracker cannot see at
// least the four body-sized scanner buffers while they are deliberately live,
// a later zero would prove nothing. build/check_m9_controls.sh supplies the
// negative control by removing the scanner shrink in a temporary mutation and
// requiring the after-response assertions to fail.
package test_m9_attribution

import "core:fmt"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "uruquim:web"

PORT :: 56191
CONNS :: 4
BODY_BYTES :: 3 * 1024 * 1024
BIG_ALLOCATION :: 256 * 1024

Server :: struct {
	app:       web.App,
	allocator: mem.Allocator,
	thread:    ^thread.Thread,
	ready:     sync.Sema,
	done:      sync.Sema,
	entered:   sync.Sema,
	release:   sync.Sema,
}

Snapshot :: struct {
	current:         i64,
	peak:            i64,
	total_allocated: i64,
	total_freed:     i64,
	live_big_count:  int,
	live_big_bytes:  int,
}

g_server: ^Server

snapshot :: proc(track: ^mem.Tracking_Allocator) -> Snapshot {
	sync.mutex_lock(&track.mutex)
	defer sync.mutex_unlock(&track.mutex)

	result := Snapshot {
		current         = track.current_memory_allocated,
		peak            = track.peak_memory_allocated,
		total_allocated = track.total_memory_allocated,
		total_freed     = track.total_memory_freed,
	}
	for _, entry in track.allocation_map {
		if entry.size >= BIG_ALLOCATION {
			result.live_big_count += 1
			result.live_big_bytes += entry.size
		}
	}
	return result
}

warm_handler :: proc(ctx: ^web.Context) {
	web.no_content(ctx)
}

hold_handler :: proc(ctx: ^web.Context) {
	s := g_server
	sync.sema_post(&s.entered)
	sync.sema_wait(&s.release)
	web.no_content(ctx)
}

serve_thread :: proc() {
	s := g_server
	// thread.create_and_start does not inherit the caller's modified allocator.
	// Install it explicitly before web.serve makes the backend Server and
	// captures context.allocator as its connection allocator.
	ctx := context
	ctx.allocator = s.allocator
	context = ctx
	sync.sema_post(&s.ready)
	web.serve(&s.app, PORT)
	sync.sema_post(&s.done)
}

send_all :: proc(sock: net.TCP_Socket, data: string) -> bool {
	bytes := transmute([]u8)data
	sent := 0
	for sent < len(bytes) {
		n, err := net.send_tcp(sock, bytes[sent:])
		if err != nil || n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

read_response :: proc(sock: net.TCP_Socket, scratch: []u8) -> bool {
	total := 0
	for total < len(scratch) {
		n, err := net.recv_tcp(sock, scratch[total:])
		if err != nil || n <= 0 {
			return false
		}
		total += n
		if strings.index(string(scratch[:total]), "\r\n\r\n") >= 0 {
			return true
		}
	}
	return false
}

dial :: proc() -> (net.TCP_Socket, bool) {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = PORT}
	for _ in 0 ..< 300 {
		sock, err := net.dial_tcp(ep)
		if err == nil {
			_ = net.set_option(sock, .Receive_Timeout, 10 * time.Second)
			return sock, true
		}
		time.sleep(5 * time.Millisecond)
	}
	return {}, false
}

@(test)
m9_scanner_bytes_are_live_during_the_request_and_released_after_it :: proc(t: ^testing.T) {
	outer := context.allocator

	// Fixtures are deliberately outside the tracker. Otherwise the test would
	// count its own 3 MiB body and request builder as framework retention.
	body := make([]u8, BODY_BYTES, outer)
	defer delete(body, outer)
	for i in 0 ..< len(body) {
		body[i] = 'x'
	}
	builder: strings.Builder
	strings.builder_init(&builder, outer)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, "POST /hold HTTP/1.1\r\nHost: localhost\r\nContent-Length: ")
	strings.write_int(&builder, BODY_BYTES)
	strings.write_string(&builder, "\r\n\r\n")
	strings.write_bytes(&builder, body)
	request := strings.to_string(builder)

	scratch := make([]u8, 16 * 1024, outer)
	defer delete(scratch, outer)
	for i in 0 ..< len(scratch) {
		scratch[i] = u8(i)
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, outer, outer)
	defer mem.tracking_allocator_destroy(&track)
	ctx := context
	ctx.allocator = mem.tracking_allocator(&track)
	context = ctx

	server: Server
	g_server = &server
	server.allocator = mem.tracking_allocator(&track)
	server.app = web.app()
	limits := web.DEFAULT_LIMITS
	limits.max_handlers = CONNS
	limits.max_connections = 64
	limits.max_drain_time = i64(3 * time.Second)
	web.limits(&server.app, limits)
	web.get(&server.app, "/warm", warm_handler)
	web.post(&server.app, "/hold", hold_handler)
	server.thread = thread.create_and_start(serve_thread)
	sync.sema_wait(&server.ready)

	probe, listening := dial()
	testing.expect(t, listening, "server did not start")
	if !listening {
		web.stop(&server.app)
		return
	}
	net.close(probe)

	socks: [CONNS]net.TCP_Socket
	live: [CONNS]bool
	for i in 0 ..< CONNS {
		socks[i], live[i] = dial()
		testing.expectf(t, live[i], "connection %d failed", i)
		if live[i] {
			testing.expect(t, send_all(socks[i], "GET /warm HTTP/1.1\r\nHost: localhost\r\n\r\n"), "warm request send failed")
			testing.expect(t, read_response(socks[i], scratch), "warm response read failed")
		}
	}
	time.sleep(100 * time.Millisecond)
	base := snapshot(&track)

	for i in 0 ..< CONNS {
		if live[i] {
			testing.expectf(t, send_all(socks[i], request), "large request %d send failed", i)
		}
	}
	all_entered := true
	for _ in 0 ..< CONNS {
		if !sync.sema_wait_with_timeout(&server.entered, 15 * time.Second) {
			all_entered = false
			break
		}
	}
	testing.expect(t, all_entered, "not every large request reached its blocked handler")

	during := snapshot(&track)
	sync.sema_post(&server.release, CONNS)
	for i in 0 ..< CONNS {
		if live[i] {
			testing.expectf(t, read_response(socks[i], scratch), "large response %d read failed", i)
		}
	}
	time.sleep(300 * time.Millisecond)
	after := snapshot(&track)

	fmt.printf(
		"[m9] base=%d during=%d(delta=%d big=%d/%d) after=%d(delta=%d big=%d/%d) allocated_delta=%d freed_delta=%d\n",
		base.current,
		during.current,
		during.current - base.current,
		during.live_big_count,
		during.live_big_bytes,
		after.current,
		after.current - base.current,
		after.live_big_count,
		after.live_big_bytes,
		after.total_allocated - base.total_allocated,
		after.total_freed - base.total_freed,
	)

	// Positive control: the allocator is demonstrably observing the scanner
	// buffers while they are alive.
	testing.expectf(
		t,
		during.live_big_bytes >= CONNS * BODY_BYTES,
		"positive control failed: blocked bodies exposed only %d live large bytes",
		during.live_big_bytes,
	)
	// Production claim: after response completion/scanner_reset, no body-sized
	// live allocation remains on the connection allocator.
	testing.expectf(
		t,
		after.live_big_bytes < BODY_BYTES,
		"body-sized allocations remain live after scanner_reset: %d bytes",
		after.live_big_bytes,
	)
	testing.expectf(
		t,
		after.current - base.current < BODY_BYTES,
		"live allocator retention still follows one body: delta=%d",
		after.current - base.current,
	)

	for i in 0 ..< CONNS {
		if live[i] {
			net.close(socks[i])
		}
	}
	time.sleep(200 * time.Millisecond)
	web.stop(&server.app)
	returned := sync.sema_wait_with_timeout(&server.done, 10 * time.Second)
	testing.expect(t, returned, "server did not stop")
	if returned {
		thread.join(server.thread)
		thread.destroy(server.thread)
	}
	web.destroy(&server.app)
	g_server = nil
}
