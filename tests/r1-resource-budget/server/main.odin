// R1-WP02 — real-process resource-budget fixture.
//
// The deploy profile and this executable deliberately share the DRUSE_*
// environment names.  The framework does not parse configuration files: the
// application resolves its environment once and hands the resulting values to
// web.limits, while check-runtime-limits.sh validates those same resolved
// integers before ExecStart.  This is the smallest possible single source of
// truth without adding policy or a configuration parser to package web.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/posix"
import "core:time"
import web "druse:web"

app: web.App
marker_dir: string
response_bytes: int

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

observer :: proc(event: web.Framework_Event) {
	if event.kind == .Serve_Listen_Failed {
		mark("serve-listen-failed")
	}
}

health :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

large :: proc(ctx: ^web.Context) {
	data := make([]u8, response_bytes, context.allocator)
	for &b in data {
		b = 'x'
	}
	mark("large-committed")
	web.bytes(ctx, .OK, "application/octet-stream", data)
}

upload :: proc(ctx: ^web.Context) {
	_, ok := web.upload(ctx)
	if ok {
		web.text(ctx, .Created, "uploaded")
		return
	}
	web.text(ctx, .OK, "buffered")
}

crash :: proc(_: ^web.Context) {
	assert(false, "R1-WP02 deliberate crash-loop drill")
}

main :: proc() {
	port := env_int("DRUSE_PORT", 22121)
	marker_dir = env_string("DRUSE_MARKER_DIR", "")
	spool_dir := env_string("DRUSE_SPOOL_DIR", "/tmp")
	response_bytes = env_int("DRUSE_FIXTURE_RESPONSE_BYTES", 8 * 1024 * 1024)
	if env_int("DRUSE_CRASH_ON_START", 0) == 1 {
		assert(false, "R1-WP02 deliberate startup crash-loop drill")
	}

	app = web.app()
	defer web.destroy(&app)

	limits := web.DEFAULT_LIMITS
	limits.max_connections = env_int("DRUSE_MAX_CONNECTIONS", 1024)
	limits.reserved_conns = env_int("DRUSE_RESERVED_CONNECTIONS", 16)
	limits.max_handlers = env_int("DRUSE_MAX_HANDLERS", 8)
	limits.max_response_bytes = env_int("DRUSE_MAX_RESPONSE_BYTES", 8 * 1024 * 1024)
	limits.max_drain_time = i64(env_int("DRUSE_MAX_DRAIN_TIME_SEC", 10)) * i64(time.Second)
	limits.max_write_time = i64(env_int("DRUSE_MAX_WRITE_TIME_SEC", 5)) * i64(time.Second)
	web.limits(&app, limits)

	web.enable_upload(&app, web.Upload_Config {
		dir = spool_dir,
		per_upload_quota = i64(env_int("DRUSE_UPLOAD_QUOTA_BYTES", 8 * 1024 * 1024)),
		process_quota = i64(env_int("DRUSE_UPLOAD_PROCESS_QUOTA_BYTES", 32 * 1024 * 1024)),
		max_concurrent = env_int("DRUSE_MAX_CONCURRENT_SPOOLS", 7),
	})

	web.observe(&app, observer)
	web.get(&app, "/health", health)
	web.get(&app, "/large", large)
	web.get(&app, "/crash", crash)
	web.post(&app, "/upload", upload)

	posix.signal(.SIGTERM, on_signal)
	posix.signal(.SIGINT, on_signal)
	web.serve(&app, port)
	mark("serve-returned")
}
