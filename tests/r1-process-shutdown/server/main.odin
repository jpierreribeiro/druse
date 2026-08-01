// R1-WP01 — real-process shutdown fixture.
//
// This is deliberately an executable, not an Odin test package. The shell
// drill builds it, delivers real POSIX signals, observes real sockets and reads
// the child exit status. No handler logs request-derived data; the marker files
// contain fixed lifecycle names only.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/posix"
import "core:thread"
import "core:time"
import web "druse:web"

app_a: web.App
marker_dir: string

Secondary_Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
}

secondary: Secondary_Server

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
	path := fmt.tprintf("%s/%s", marker_dir, name)
	_ = os.write_entire_file(path, transmute([]u8)string("1\n"))
}

// The signal handler is intentionally tiny. A C-ABI handler receives no Odin
// context, so it installs the default stack context and performs only the
// atomic/wake path in web.stop. The R1 control rejects allocation, logging and
// mutex vocabulary in this body.
on_signal :: proc "c" (_: posix.Signal) {
	context = runtime.default_context()
	web.stop(&app_a)
}

health :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

ready :: proc(ctx: ^web.Context) {
	if web.is_draining(&app_a) {
		web.text(ctx, .Service_Unavailable, "draining")
		return
	}
	web.text(ctx, .OK, "ready")
}

watch_drain :: proc(ctx: ^web.Context) {
	mark("watch-entered")
	for !web.is_draining(&app_a) {
		time.sleep(time.Millisecond)
	}
	mark("watch-observed-draining")
	web.text(ctx, .Service_Unavailable, "draining")
}

short_work :: proc(ctx: ^web.Context) {
	mark("short-entered")
	time.sleep(400 * time.Millisecond)
	web.text(ctx, .OK, "short-complete")
}

blocked_work :: proc(ctx: ^web.Context) {
	mark("blocked-entered")
	for {
		time.sleep(time.Second)
	}
}

large_response :: proc(ctx: ^web.Context) {
	data := make([]u8, 8 * 1024 * 1024, context.allocator)
	for &b in data {
		b = 'x'
	}
	mark("large-committed")
	web.bytes(ctx, .OK, "application/octet-stream", data)
}

open_stream :: proc(ctx: ^web.Context) {
	_, ok := web.stream(ctx, "text/plain")
	if !ok {
		web.text(ctx, .Service_Unavailable, "stream-refused")
		return
	}
	mark("stream-opened")
	// The token is intentionally not closed: shutdown owns its termination.
}

upload_complete :: proc(ctx: ^web.Context) {
	_, ok := web.upload(ctx)
	if ok {
		mark("upload-handler-entered")
		web.text(ctx, .Created, "uploaded")
		return
	}
	web.text(ctx, .OK, "buffered")
}

stop_b :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "stopping-b")
	web.stop(&secondary.app)
}

serve_b :: proc(server: ^Secondary_Server) {
	web.serve(&server.app, server.port)
}

main :: proc() {
	marker_dir = env_string("R1_MARKER_DIR", "/tmp")
	mode := env_string("R1_MODE", "single")
	port_a := env_int("R1_PORT", 54111)
	port_b := env_int("R1_PORT_B", 54112)
	spool_dir := env_string("R1_SPOOL_DIR", "/tmp")

	app_a = web.app()
	defer web.destroy(&app_a)
	limits := web.DEFAULT_LIMITS
	limits.max_drain_time = i64(500 * time.Millisecond)
	limits.max_write_time = i64(200 * time.Millisecond)
	limits.max_request_time = i64(10 * time.Second)
	limits.max_handlers = 4
	limits.max_body = 4096
	web.limits(&app_a, limits)
	web.enable_upload(&app_a, web.Upload_Config {
		dir = spool_dir,
		per_upload_quota = 2 * 1024 * 1024,
		process_quota = 4 * 1024 * 1024,
		max_concurrent = 2,
	})

	web.get(&app_a, "/health", health)
	web.get(&app_a, "/ready", ready)
	web.get(&app_a, "/watch", watch_drain)
	web.get(&app_a, "/short", short_work)
	web.get(&app_a, "/blocked", blocked_work)
	web.get(&app_a, "/large", large_response)
	web.get(&app_a, "/stream", open_stream)
	web.post(&app_a, "/upload", upload_complete)

	posix.signal(.SIGTERM, on_signal)
	posix.signal(.SIGINT, on_signal)

	if mode == "two" {
		secondary.port = port_b
		secondary.app = web.app()
		web.get(&secondary.app, "/health", health)
		web.get(&secondary.app, "/stop", stop_b)
		secondary.thread = thread.create_and_start_with_poly_data(&secondary, serve_b)
	}

	web.serve(&app_a, port_a)
	mark("serve-a-returned")
	if secondary.thread != nil {
		thread.join(secondary.thread)
		thread.destroy(secondary.thread)
		mark("serve-b-returned")
		web.destroy(&secondary.app)
	}
}
