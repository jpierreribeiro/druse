// R1-WP03 — real Caddy/Druse interop fixture.
//
// It deliberately logs only fixed lifecycle markers and aggregate counters.
// Request bodies, forwarded headers, cookies and credentials never reach a log.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import web "druse:web"

app: web.App
marker_dir: string
unexpected_after_drain: int

Stream_Job :: struct {
	stream: web.Stream,
}

stream_job: Stream_Job
stream_thread: ^thread.Thread

env_string :: proc(key, fallback: string) -> string {
	value, found := os.lookup_env(key, context.temp_allocator)
	return found ? value : fallback
}

env_int :: proc(key: string, fallback: int) -> int {
	value := env_string(key, "")
	parsed, ok := strconv.parse_int(value, 10)
	return ok ? parsed : fallback
}

mark :: proc(name: string) {
	if len(marker_dir) == 0 {
		return
	}
	path := fmt.tprintf("%s/%s", marker_dir, name)
	_ = os.write_entire_file(path, transmute([]u8)string("1\n"))
}

on_signal :: proc "c" (_: posix.Signal) {
	context = runtime.default_context()
	web.stop(&app)
}

ok_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

ready_handler :: proc(ctx: ^web.Context) {
	if web.is_draining(&app) {
		web.text(ctx, .Service_Unavailable, "draining")
		return
	}
	web.text(ctx, .OK, "ready")
}

whoami_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, web.client_ip(ctx))
}

Body_Input :: struct {
	data: string,
}

body_handler :: proc(ctx: ^web.Context) {
	body: Body_Input
	if !web.body(ctx, &body) {
		return
	}
	web.text(ctx, .OK, fmt.tprintf("%d", len(body.data)))
}

headers_handler :: proc(ctx: ^web.Context) {
	_ = web.set_header(ctx, "Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
	_ = web.set_header(ctx, "Set-Cookie", "pilot=1; Secure; HttpOnly; SameSite=Strict")
	web.text(ctx, .OK, "headers")
}

slow_handler :: proc(ctx: ^web.Context) {
	time.sleep(800 * time.Millisecond)
	web.text(ctx, .OK, "late")
}

stream_producer :: proc(job: ^Stream_Job) {
	for i in 1 ..= 10 {
		time.sleep(200 * time.Millisecond)
		frame := fmt.tprintf("data: event-%d\n\n", i)
		if web.stream_send(job.stream, transmute([]u8)frame) != .Sent {
			break
		}
	}
	web.stream_close(job.stream)
}

stream_handler :: proc(ctx: ^web.Context) {
	// The handler owns admission only. Sending happens after it returns: a
	// synchronous handler that sleeps and sends cannot let the transport driver
	// progress, and is not the supported detached-stream shape.
	if stream_thread != nil {
		thread.join(stream_thread)
		thread.destroy(stream_thread)
		stream_thread = nil
	}
	stream, accepted := web.stream(ctx, "text/event-stream")
	if !accepted {
		web.text(ctx, .Service_Unavailable, "stream-refused")
		return
	}
	stream_job.stream = stream
	stream_thread = thread.create_and_start_with_poly_data(&stream_job, stream_producer)
}

drain_watch_handler :: proc(ctx: ^web.Context) {
	mark("drain-watch-entered")
	for !web.is_draining(&app) {
		time.sleep(time.Millisecond)
	}
	mark("draining-observed")
	time.sleep(500 * time.Millisecond)
	web.text(ctx, .OK, "drained")
}

unexpected_handler :: proc(ctx: ^web.Context) {
	if web.is_draining(&app) {
		sync.atomic_add(&unexpected_after_drain, 1)
	}
	web.text(ctx, .OK, "unexpected")
}

main :: proc() {
	port := env_int("DRUSE_PORT", 22131)
	marker_dir = env_string("DRUSE_MARKER_DIR", "")

	// The environment strings are cloned because trust_proxies retains them for
	// the App lifetime. Empty entries are omitted and therefore fail closed.
	trusted_1 := strings.clone(env_string("DRUSE_TRUST_PROXY_1", "198.18.0.1"))
	defer delete(trusted_1)
	trusted_2_value := env_string("DRUSE_TRUST_PROXY_2", "")
	trusted_2 := len(trusted_2_value) > 0 ? strings.clone(trusted_2_value) : ""
	defer if len(trusted_2) > 0 {delete(trusted_2)}

	app = web.app()
	defer web.destroy(&app)
	limits := web.DEFAULT_LIMITS
	limits.max_body = 2 * 1024 * 1024
	limits.max_headers = 8 * 1024
	limits.max_request_time = i64(env_int("DRUSE_REQUEST_TIMEOUT_MS", 3000)) * i64(time.Millisecond)
	limits.max_write_time = 5 * i64(time.Second)
	limits.max_idle_time = 5 * i64(time.Second)
	limits.max_drain_time = i64(2 * time.Second)
	limits.max_connections = env_int("DRUSE_MAX_CONNECTIONS", 64)
	limits.reserved_conns = env_int("DRUSE_RESERVED_CONNECTIONS", 4)
	limits.max_handlers = 4
	web.limits(&app, limits)

	if len(trusted_2) > 0 {
		web.trust_proxies(&app, []string{trusted_1, trusted_2})
	} else {
		web.trust_proxies(&app, []string{trusted_1})
	}
	web.use(&app, web.request_id)
	web.use(&app, web.secure_headers)
	web.get(&app, "/health", ok_handler)
	web.get(&app, "/ready", ready_handler)
	web.get(&app, "/ok", ok_handler)
	web.get(&app, "/whoami", whoami_handler)
	web.post(&app, "/body", body_handler)
	web.post(&app, "/proxy-limit", body_handler)
	web.get(&app, "/headers", headers_handler)
	web.get(&app, "/proxy-timeout", slow_handler)
	web.get(&app, "/stream", stream_handler)
	web.get(&app, "/buffered-stream", stream_handler)
	web.get(&app, "/drain-watch", drain_watch_handler)
	web.get(&app, "/unexpected", unexpected_handler)

	posix.signal(.SIGTERM, on_signal)
	posix.signal(.SIGINT, on_signal)
	web.serve(&app, port)
	if stream_thread != nil {
		thread.join(stream_thread)
		thread.destroy(stream_thread)
		stream_thread = nil
	}

	if len(marker_dir) > 0 {
		final_path := fmt.tprintf("%s/final-counts.txt", marker_dir)
		final := fmt.tprintf("unexpected_after_drain=%d\n", sync.atomic_load(&unexpected_after_drain))
		_ = os.write_entire_file(final_path, transmute([]u8)final)
	}
}
