// C-04 — response size, arena reclamation and process RSS high-water.
//
// THE TWO PERIMETERS this suite was created to answer
// (`planning/production-readiness-closure.md` §4):
//
//	2. Unbounded response size and its arena impact — ADR-045 now bounds it
//	3. Memory after large responses — attribution corrected; long soak owed
//
// Both were open because nobody had a number. The original interpretation of
// this suite said a growing `virtual.Arena` kept all of its blocks after
// `free_all`. That is false for the pinned toolchain: it deallocates every
// growing block except the initial 1 MiB reservation and resets usage to zero.
// The direct arena test below gates that semantic, while the socket phase
// measures the different quantity an operator sees: process RSS high-water.
//
// THE MEASUREMENT is deliberately two-phase, because a single RSS reading
// cannot tell retention from a leak:
//
//	phase 1  N keep-alive connections, one BIG response each   -> RSS high-water
//	phase 2  the same connections, many SMALL requests each    -> RSS stability
//
// RSS cannot identify a live owner. Growth during phase 2 would reveal
// accumulation under this workload, but a stable RSS is not proof that every
// allocator has returned pages to the kernel.
package test_c04_response_size

import "core:fmt"
import virtual "core:mem/virtual"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

CANDIDATE_PORTS :: [?]int{55031, 55357, 55625, 55901}

// Big enough to dwarf the noise of a test process's own allocation, small
// enough that N of them fit comfortably on a development box.
BIG_BYTES :: 4 * 1024 * 1024
SMALL_BYTES :: 512

// The keep-alive connections held across both phases.
CONNS :: 8

// Small requests per connection in phase 2. Enough that accumulating a few
// kilobytes per request would be visible against the phase-1 RSS high-water.
SMALL_ROUNDS :: 200

// The RSS-stability threshold. A correct implementation should grow by
// approximately nothing while serving the small phase; 2 MiB leaves room for
// allocator bookkeeping and test-side buffers.
LEAK_THRESHOLD_BYTES :: 2 * 1024 * 1024

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
	done:   sync.Sema,
}

g_server: ^Server

big_handler :: proc(ctx: ^web.Context) {
	body := make([]u8, BIG_BYTES, context.temp_allocator)
	web.text(ctx, .OK, string(body))
}

small_handler :: proc(ctx: ^web.Context) {
	body := make([]u8, SMALL_BYTES, context.temp_allocator)
	web.text(ctx, .OK, string(body))
}

serve_thread :: proc() {
	s := g_server
	sync.post(&s.ready)
	web.serve(&s.app, s.port)
	sync.post(&s.done)
}

start_server :: proc(s: ^Server) -> bool {
	g_server = s
	for candidate in CANDIDATE_PORTS {
		s.app = web.app()
		l := web.DEFAULT_LIMITS
		l.max_drain_time = i64(2 * time.Second)
		web.limits(&s.app, l)
		web.get(&s.app, "/big", big_handler)
		web.get(&s.app, "/small", small_handler)
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

// rss_bytes reads this process's resident set from /proc/self/statm.
//
// RSS AND NOT AN ALLOCATOR COUNTER, on purpose. The server runs in this same
// process, and what an operator sizes a cgroup against is resident memory, not
// a number the framework reports about itself. It is also the reading that
// cannot be faked by an accounting bug — the WP2 two-instance trap, applied to
// memory.
rss_bytes :: proc() -> int {
	data, read_err := os.read_entire_file_from_path("/proc/self/statm", context.temp_allocator)
	if read_err != nil {
		return 0
	}
	fields := strings.fields(string(data), context.temp_allocator)
	if len(fields) < 2 {
		return 0
	}
	pages, _ := strconv.parse_int(fields[1])
	// 4 KiB on every platform this project gates (production-service-bom.md §6).
	PAGE_SIZE :: 4096
	return pages * PAGE_SIZE
}

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

// read_exactly_one_response drains a whole response, using Content-Length to
// know when to stop — a keep-alive client MUST read its response fully or the
// next request would be answered into a socket the server still owns bytes on.
read_one_response :: proc(sock: net.TCP_Socket, scratch: []u8) -> bool {
	total, header_end, content_length := 0, -1, -1
	for {
		n, err := net.recv_tcp(sock, scratch[total:])
		if err != nil || n <= 0 {
			return false
		}
		total += n
		if header_end < 0 {
			idx := strings.index(string(scratch[:total]), "\r\n\r\n")
			if idx >= 0 {
				header_end = idx + 4
				head := strings.to_lower(string(scratch[:idx]), context.temp_allocator)
				ci := strings.index(head, "content-length:")
				if ci >= 0 {
					rest := head[ci + len("content-length:"):]
					line_end := strings.index(rest, "\r\n")
					if line_end < 0 {
						line_end = len(rest)
					}
					content_length, _ = strconv.parse_int(strings.trim_space(rest[:line_end]))
				}
			}
		}
		if header_end >= 0 && content_length >= 0 && total >= header_end + content_length {
			return true
		}
		if total >= len(scratch) {
			return false
		}
	}
}

@(test)
c04_rss_high_water_stabilizes_across_small_keepalive_responses :: proc(t: ^testing.T) {
	server: Server
	if !start_server(&server) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	// One scratch buffer, reused — and TOUCHED BEFORE THE BASELINE IS TAKEN.
	// RSS counts resident pages, not reservations, so an untouched buffer would
	// become resident during phase 1 and be counted as server retention. Writing
	// it first moves the client's own 4 MiB into the baseline where it belongs.
	// (The first version of this suite did not, and reported ~4 MiB of the
	// client's memory as the framework's.)
	scratch := make([]u8, BIG_BYTES + 64 * 1024)
	defer delete(scratch)
	for i in 0 ..< len(scratch) {
		scratch[i] = u8(i)
	}

	socks: [CONNS]net.TCP_Socket
	live: [CONNS]bool
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = server.port}
	for i in 0 ..< CONNS {
		sock, err := net.dial_tcp(ep)
		live[i] = err == nil
		if live[i] {
			socks[i] = sock
			_ = net.set_option(sock, .Receive_Timeout, 5 * time.Second)
		}
	}

	baseline := rss_bytes()

	// --- phase 1: one BIG response per connection -> RSS high-water ----------
	big_req := "GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n"
	served_big := 0
	for i in 0 ..< CONNS {
		if !live[i] {
			continue
		}
		if send_all(socks[i], big_req) && read_one_response(socks[i], scratch) {
			served_big += 1
		}
	}
	after_big := rss_bytes()

	// --- phase 2: many SMALL responses on the SAME connections -> the leak ---
	small_req := "GET /small HTTP/1.1\r\nHost: localhost\r\n\r\n"
	served_small := 0
	for _ in 0 ..< SMALL_ROUNDS {
		for i in 0 ..< CONNS {
			if !live[i] {
				continue
			}
			if send_all(socks[i], small_req) && read_one_response(socks[i], scratch) {
				served_small += 1
			}
		}
	}
	after_small := rss_bytes()

	for i in 0 ..< CONNS {
		if live[i] {
			net.close(socks[i])
		}
	}
	time.sleep(300 * time.Millisecond)
	after_close := rss_bytes()

	web.stop(&server.app)
	returned := sync.sema_wait_with_timeout(&server.done, 10 * time.Second)
	if returned {
		thread.join(server.thread)
		thread.destroy(server.thread)
		server.thread = nil
		web.destroy(&server.app)
	}
	g_server = nil

	peak_growth := after_big - baseline
	grew := after_small - after_big
	fmt.printf(
		"[c04] conns=%d big=%d(%d served) small_rounds=%d(%d served)\n",
		CONNS,
		BIG_BYTES,
		served_big,
		SMALL_ROUNDS,
		served_small,
	)
	fmt.printf(
		"[c04] rss baseline=%.1fMiB after_big=%.1fMiB after_small=%.1fMiB after_close=%.1fMiB\n",
		f64(baseline) / 1048576.0,
		f64(after_big) / 1048576.0,
		f64(after_small) / 1048576.0,
		f64(after_close) / 1048576.0,
	)
	fmt.printf(
		"[c04] RSS growth after big = %.1fMiB (%.2f x the %.1fMiB served) | growth over %d small responses = %.2fMiB\n",
		f64(peak_growth) / 1048576.0,
		f64(peak_growth) / f64(served_big * BIG_BYTES) if served_big > 0 else 0,
		f64(served_big * BIG_BYTES) / 1048576.0,
		served_small,
		f64(grew) / 1048576.0,
	)

	testing.expect(t, returned, "the server must shut down after the soak")
	testing.expectf(
		t,
		served_big == CONNS,
		"only %d of %d big responses were served; the RSS figure would be about the client",
		served_big,
		CONNS,
	)
	testing.expectf(
		t,
		served_small == CONNS * SMALL_ROUNDS,
		"only %d of %d small responses were served; the leak figure would be about the client",
		served_small,
		CONNS * SMALL_ROUNDS,
	)
	// THE ASSERTION IS ABOUT PHASE 2 ONLY. The phase-1 RSS delta is reported, not
	// attributed: RSS cannot distinguish live allocations from allocator pages
	// already freed but not returned to the kernel. What must hold is that this
	// workload does not continue accumulating RSS across small requests.
	testing.expectf(
		t,
		grew < LEAK_THRESHOLD_BYTES,
		"RSS grew %.2fMiB while serving %d small responses after the large-response phase; memory is accumulating under this workload (threshold %.1fMiB)",
		f64(grew) / 1048576.0,
		served_small,
		f64(LEAK_THRESHOLD_BYTES) / 1048576.0,
	)
}

// The semantic the old C-04 explanation got wrong. A growing arena does not
// retain its oversize blocks across free_all: only its first reservation
// survives. build/check_c04_controls.sh removes this call in a copied mutant
// and requires the assertions to turn red.
@(test)
c04_growing_arena_free_all_releases_oversize_blocks :: proc(t: ^testing.T) {
	arena: virtual.Arena
	err := virtual.arena_init_growing(&arena)
	testing.expectf(t, err == nil, "arena init failed: %v", err)
	if err != nil {
		return
	}
	defer virtual.arena_destroy(&arena)

	first := arena.curr_block
	_, alloc_err := virtual.arena_alloc(&arena, BIG_BYTES, 16)
	testing.expectf(t, alloc_err == nil, "arena allocation failed: %v", alloc_err)
	if alloc_err != nil {
		return
	}

	before_blocks := 0
	for block := arena.curr_block; block != nil; block = block.prev {
		before_blocks += 1
	}
	testing.expectf(t, before_blocks > 1, "positive control failed: oversize allocation used only %d block", before_blocks)

	virtual.arena_free_all(&arena)

	after_blocks := 0
	for block := arena.curr_block; block != nil; block = block.prev {
		after_blocks += 1
	}
	testing.expectf(
		t,
		after_blocks == 1 && arena.curr_block == first && arena.total_used == 0,
		"arena_free_all retained oversize blocks: blocks=%d used=%d",
		after_blocks,
		arena.total_used,
	)
}
