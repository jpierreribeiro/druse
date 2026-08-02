// R1-WP06 — supervised deployment/crash/rollback fixture.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:sys/posix"
import "core:thread"
import "core:time"
import web "druse:web"

RELEASE_ID :: #config(R1_PILOT_RELEASE, "unconfigured")

app: web.App
stream_thread: ^thread.Thread
stream_job: Stream_Job

Stream_Job :: struct {
	stream: web.Stream,
}

env_int :: proc(key: string, fallback: int) -> int {
	value, found := os.lookup_env(key, context.temp_allocator)
	if !found {
		return fallback
	}
	parsed, ok := strconv.parse_int(value, 10)
	return ok ? parsed : fallback
}

env_string :: proc(key, fallback: string) -> string {
	value, found := os.lookup_env(key, context.temp_allocator)
	return found ? value : fallback
}

on_signal :: proc "c" (_: posix.Signal) {
	context = runtime.default_context()
	web.stop(&app)
}

health :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "healthy")
}

ready :: proc(ctx: ^web.Context) {
	if web.is_draining(&app) {
		web.text(ctx, .Service_Unavailable, "draining")
		return
	}
	web.text(ctx, .OK, "ready")
}

sentinel :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, fmt.tprintf("release=%s sentinel=r1-integrity-v1", RELEASE_ID))
}

whoami :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, web.client_ip(ctx))
}

work :: proc(ctx: ^web.Context) {
	time.sleep(10 * time.Millisecond)
	web.text(ctx, .OK, fmt.tprintf("release=%s work=ok", RELEASE_ID))
}

crash :: proc(_: ^web.Context) {
	assert(false, "R1-WP06 deliberate Handler fault")
}

upload :: proc(ctx: ^web.Context) {
	_, ok := web.upload(ctx)
	if !ok {
		web.bad_request(ctx, "spooled upload required")
		return
	}
	web.text(ctx, .Created, fmt.tprintf("release=%s upload=accepted", RELEASE_ID))
}

stream_producer :: proc(job: ^Stream_Job) {
	for i in 1 ..= 10 {
		time.sleep(50 * time.Millisecond)
		frame := fmt.tprintf("data: event-%d\n\n", i)
		if web.stream_send(job.stream, transmute([]u8)frame) != .Sent {
			break
		}
	}
	web.stream_close(job.stream)
}

stream :: proc(ctx: ^web.Context) {
	if stream_thread != nil {
		thread.join(stream_thread)
		thread.destroy(stream_thread)
		stream_thread = nil
	}
	s, ok := web.stream(ctx, "text/event-stream")
	if !ok {
		web.text(ctx, .Service_Unavailable, "stream-refused")
		return
	}
	stream_job.stream = s
	stream_thread = thread.create_and_start_with_poly_data(&stream_job, stream_producer)
}

main :: proc() {
	port := env_int("DRUSE_PORT", 22141)
	spool_dir := env_string("DRUSE_SPOOL_DIR", "/tmp")

	app = web.app()
	defer web.destroy(&app)
	limits := web.DEFAULT_LIMITS
	limits.max_connections = env_int("DRUSE_MAX_CONNECTIONS", 1024)
	limits.reserved_conns = env_int("DRUSE_RESERVED_CONNECTIONS", 16)
	limits.max_handlers = env_int("DRUSE_MAX_HANDLERS", 8)
	limits.max_response_bytes = env_int("DRUSE_MAX_RESPONSE_BYTES", 8 * 1024 * 1024)
	limits.max_drain_time = i64(env_int("DRUSE_MAX_DRAIN_TIME_SEC", 10)) * i64(time.Second)
	limits.max_write_time = i64(env_int("DRUSE_MAX_WRITE_TIME_SEC", 5)) * i64(time.Second)
	limits.max_idle_time = 5 * i64(time.Second)
	web.limits(&app, limits)
	web.enable_upload(&app, web.Upload_Config {
		dir = spool_dir,
		per_upload_quota = i64(env_int("DRUSE_UPLOAD_QUOTA_BYTES", 8 * 1024 * 1024)),
		process_quota = i64(env_int("DRUSE_UPLOAD_PROCESS_QUOTA_BYTES", 32 * 1024 * 1024)),
		max_concurrent = env_int("DRUSE_MAX_CONCURRENT_SPOOLS", 7),
	})
	web.trust_proxies(&app, []string{"127.0.0.1"})
	web.use(&app, web.request_id)
	web.use(&app, web.secure_headers)
	web.get(&app, "/health", health)
	web.get(&app, "/ready", ready)
	web.get(&app, "/pilot/sentinel", sentinel)
	web.get(&app, "/pilot/whoami", whoami)
	web.get(&app, "/pilot/work", work)
	web.get(&app, "/pilot/crash", crash)
	web.get(&app, "/pilot/stream", stream)
	web.post(&app, "/pilot/upload", upload)

	posix.signal(.SIGTERM, on_signal)
	posix.signal(.SIGINT, on_signal)
	fmt.printf("event=serve-start release=%s port=%d\n", RELEASE_ID, port)
	web.serve(&app, port)
	if stream_thread != nil {
		thread.join(stream_thread)
		thread.destroy(stream_thread)
		stream_thread = nil
	}
	fmt.printf("event=serve-return release=%s\n", RELEASE_ID)
}
