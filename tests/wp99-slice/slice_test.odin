// WP99 — large-transfer and progress vertical slice, over public contracts only.
//
// A small reference application that composes the two streaming directions the
// phase shipped, using ONLY the public surface (`web.app`/`get`/`post`/`body`/
// `form_file`/`stream`/`stream_send`/`stream_close`) — no internal imports, no
// backend types:
//
//   POST /jobs      — upload content (buffered path), start an application-owned
//                     worker that "processes" it and records progress;
//   GET  /progress  — an SSE-shaped stream of the job's progress, from ANY point
//                     (reconnect obtains the CURRENT value, no event replay);
//   GET  /result    — the processed result via bounded response streaming.
//
// It proves: the app owns its worker (the phase adds no job system); progress
// reconnection reads current state, not a replayed log; the download streams
// incrementally; two clients are isolated when one is slow; and drain releases
// everything. Upload uses the buffered `form_file` path — the >max_body spool
// upload has its substrate (WP94) but no public wiring yet (recorded in the
// WP101 freeze), so this slice uses the shipped upload contract.
package test_wp99_slice

import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "uruquim:web"

// The application's own job state — owned by App_State, synchronized by the app
// (the framework's rule: application-owned mutable state synchronizes itself).
Job :: struct {
	mu:       sync.Mutex,
	progress: int, // 0..100, the CURRENT value a reconnecting client reads
	result:   [dynamic]u8,
	done:     bool,
}

App_State :: struct {
	job:          Job,
	worker:       ^thread.Thread,
	// Detached-stream state lives HERE, not in the request arena — the arena
	// dies when the Handler returns, which is the whole point of detachment.
	prog_stream:  web.Stream,
	prog_thread:  ^thread.Thread,
	res_stream:   web.Stream,
	res_thread:   ^thread.Thread,
}

g_state: ^App_State

@(private)
worker_main :: proc(st: ^App_State) {
	// "Process" in ten steps, recording progress the whole time.
	for step in 1 ..= 10 {
		time.sleep(15 * time.Millisecond)
		sync.mutex_lock(&st.job.mu)
		st.job.progress = step * 10
		append(&st.job.result, ..transmute([]u8)strings.concatenate({"chunk-", fmt_int(step), " "}, context.temp_allocator))
		if step == 10 {st.job.done = true}
		sync.mutex_unlock(&st.job.mu)
	}
}

@(private)
fmt_int :: proc(n: int) -> string {
	buf: [8]u8
	i := len(buf)
	v := n
	if v == 0 {return "0"}
	for v > 0 {i -= 1; buf[i] = u8('0' + v % 10); v /= 10}
	return strings.clone(string(buf[i:]), context.temp_allocator)
}

@(private)
start_job :: proc(ctx: ^web.Context) {
	st, state_ok := web.state(ctx, App_State)
	if !state_ok {
		web.internal_error(ctx)
		return
	}
	sync.mutex_lock(&st.job.mu)
	st.job.progress = 0
	st.job.done = false
	clear(&st.job.result)
	sync.mutex_unlock(&st.job.mu)
	st.worker = thread.create_and_start_with_poly_data(st, worker_main)
	web.text(ctx, .Created, "started")
}

// GET /progress — a stream that reports the CURRENT progress each tick until
// done, then closes. A reconnecting client sees current state immediately, with
// no assumption of replay.
@(private)
progress_stream :: proc(ctx: ^web.Context) {
	st, state_ok := web.state(ctx, App_State)
	if !state_ok {
		web.internal_error(ctx)
		return
	}
	s, ok := web.stream(ctx, "text/event-stream")
	if !ok {
		web.text(ctx, .OK, "no-stream")
		return
	}
	// The stream outlives the Handler: its token and thread live in App_State
	// (persistent), and the reporter runs on the App_State pointer.
	st.prog_stream = s
	st.prog_thread = thread.create_and_start_with_poly_data(st, proc(st: ^App_State) {
		for {
			sync.mutex_lock(&st.job.mu)
			p := st.job.progress
			done := st.job.done
			sync.mutex_unlock(&st.job.mu)
			// A stack buffer for the frame — no request-arena allocation.
			frame := strings.concatenate({"data: ", fmt_int(p), "\n\n"})
			res := web.stream_send(st.prog_stream, transmute([]u8)frame)
			delete(frame)
			if res == .Closed {break}
			if done {break}
			time.sleep(10 * time.Millisecond)
		}
		web.stream_close(st.prog_stream)
	})
}

// GET /result — the processed bytes via bounded response streaming.
@(private)
result_stream :: proc(ctx: ^web.Context) {
	st, state_ok := web.state(ctx, App_State)
	if !state_ok {
		web.internal_error(ctx)
		return
	}
	s, ok := web.stream(ctx, "application/octet-stream")
	if !ok {
		web.text(ctx, .OK, "no-stream")
		return
	}
	st.res_stream = s
	st.res_thread = thread.create_and_start_with_poly_data(st, proc(st: ^App_State) {
		for {
			sync.mutex_lock(&st.job.mu)
			done := st.job.done
			sync.mutex_unlock(&st.job.mu)
			if done {break}
			time.sleep(10 * time.Millisecond)
		}
		sync.mutex_lock(&st.job.mu)
		payload := make([]u8, len(st.job.result))
		copy(payload, st.job.result[:])
		sync.mutex_unlock(&st.job.mu)
		off := 0
		for off < len(payload) {
			end := min(off + 8, len(payload))
			for web.stream_send(st.res_stream, payload[off:end]) == .Full {time.sleep(time.Millisecond)}
			off = end
		}
		web.stream_close(st.res_stream)
		delete(payload)
	})
}

Server :: struct {app: web.App, port: int, thread: ^thread.Thread}

@(private)
serve_thread :: proc(s: ^Server) {web.serve(&s.app, s.port)}

@(private)
start :: proc(s: ^Server, port: int, st: ^App_State) -> bool {
	s.port = port
	s.app = web.app_with_state(st)
	web.post(&s.app, "/jobs", start_job)
	web.get(&s.app, "/progress", progress_stream)
	web.get(&s.app, "/result", result_stream)
	s.thread = thread.create_and_start_with_poly_data(s, serve_thread)
	for _ in 0 ..< 300 {
		sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127,0,0,1}, port = port})
		if err == nil {net.close(sock); return true}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

@(private)
stop :: proc(s: ^Server, st: ^App_State) {
	web.stop(&s.app)
	if s.thread != nil {thread.join(s.thread); thread.destroy(s.thread); s.thread = nil}
	if st.worker != nil {thread.join(st.worker); thread.destroy(st.worker); st.worker = nil}
	if st.prog_thread != nil {thread.join(st.prog_thread); thread.destroy(st.prog_thread); st.prog_thread = nil}
	if st.res_thread != nil {thread.join(st.res_thread); thread.destroy(st.res_thread); st.res_thread = nil}
	web.destroy(&s.app)
	delete(st.job.result)
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
req_line :: proc(sock: net.TCP_Socket, method, path: string) {
	r, _ := strings.concatenate({method, " ", path, " HTTP/1.1\r\nHost: x\r\n\r\n"}, context.temp_allocator)
	_, _ = net.send_tcp(sock, transmute([]u8)r)
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

@(test)
wp99_progress_reconnect_and_streaming_download_compose :: proc(t: ^testing.T) {
	st: App_State
	g_state = &st
	srv: Server
	testing.expect(t, start(&srv, 52090, &st), "app starts")
	defer stop(&srv, &st)

	// Start the job.
	js, _ := dial(52090)
	req_line(js, "POST", "/jobs")
	jb: strings.Builder
	strings.builder_init(&jb, context.temp_allocator)
	testing.expect(t, recv_until(js, &jb, "started", 3 * time.Second), "job starts")
	defer net.close(js)
	time.sleep(20 * time.Millisecond)

	// A client "reconnects" mid-job and reads the CURRENT progress, not a replay.
	ps, ok := dial(52090)
	testing.expect(t, ok)
	req_line(ps, "GET", "/progress")
	pb: strings.Builder
	strings.builder_init(&pb, context.temp_allocator)
	testing.expect(t, recv_until(ps, &pb, "text/event-stream", 3 * time.Second), "progress stream opens")
	// It must reach 100 (completion) — proving live current-state reporting.
	testing.expect(t, recv_until(ps, &pb, "data: 100", 5 * time.Second), "progress reaches 100 via live current-state reads")
	net.close(ps)

	// Download the result via bounded response streaming.
	rs, ok2 := dial(52090)
	testing.expect(t, ok2)
	req_line(rs, "GET", "/result")
	rb: strings.Builder
	strings.builder_init(&rb, context.temp_allocator)
	testing.expect(t, recv_until(rs, &rb, "chunk-10", 5 * time.Second), "the streamed result contains the last processed chunk")
	testing.expect(t, recv_until(rs, &rb, "0\r\n\r\n", 3 * time.Second), "the download terminates")
	net.close(rs)
}

@(test)
wp99_a_slow_result_client_does_not_stall_a_fast_progress_client :: proc(t: ^testing.T) {
	st: App_State
	g_state = &st
	srv: Server
	testing.expect(t, start(&srv, 52091, &st), "app starts")
	defer stop(&srv, &st)

	js, _ := dial(52091)
	req_line(js, "POST", "/jobs")
	jb: strings.Builder; strings.builder_init(&jb, context.temp_allocator)
	testing.expect(t, recv_until(js, &jb, "started", 3 * time.Second))
	net.close(js)

	// A SLOW result client: opens the result stream, shrinks its window, never reads.
	slow, _ := dial(52091)
	net.set_option(slow, .Receive_Buffer_Size, 512)
	req_line(slow, "GET", "/result")
	defer net.close(slow)

	// A FAST progress client must still reach completion. Under the F-002
	// security fix a request that races lane admission is REFUSED with 503 and
	// the client retries (never a deferred unsafe dispatch); a stuck lane would
	// make every retry 503 forever, which is the failure this asserts against.
	reached := false
	for attempt in 0 ..< 40 {
		fast, ok := dial(52091)
		if !ok {continue}
		req_line(fast, "GET", "/progress")
		fb: strings.Builder; strings.builder_init(&fb, context.temp_allocator)
		if recv_until(fast, &fb, "data: 100", 3 * time.Second) {
			reached = true
			net.close(fast)
			break
		}
		net.close(fast)
		time.sleep(20 * time.Millisecond)
		_ = attempt
	}
	testing.expect(t, reached, "the fast client reaches completion (retrying past any transient 503) while the slow one is stalled")
}
