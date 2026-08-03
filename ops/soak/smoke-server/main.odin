// The host-qualification smoke target (R2-WP02).
//
// WHY THIS IS NOT THE SOAK SERVER. `R2-restricted-production.md` §3 requires a
// smoke of UPLOAD, STREAM and PROXY before any load is offered at a candidate
// host. `ops/soak/soak-server` serves none of the three, and giving it those
// routes would have changed the candidate: `web.enable_upload` moves every body
// over `max_body` off the buffered path, and `/json/medium/decode` posts bodies.
// The campaign's server would then no longer be the program the twelve-hour
// criteria were written about (readiness rule G1 — a candidate is an identity).
//
// So this is a separate, small program, and it is an INSTRUMENT rather than the
// thing under test. It answers one question about the HOST: can this machine
// spool an upload to its disk, hold a streaming response open through the pinned
// reverse proxy, and do both behind TLS. A host that passes `preflight.sh` and
// fails this is not a qualified host — the preflight reads counters and files,
// and none of that proves the three hard paths of the supported profile work
// here.
//
// It exercises exactly the three, and nothing else. Anything more would be a
// second soak server nobody asked for.
package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"
import web "druse:web"

KIB :: 1024
MIB :: 1024 * KIB

// Small on purpose: the smoke has to cross `max_body` with a body it can send
// in one curl, so the spool path is reached in under a second rather than by
// moving a gigabyte across loopback.
MAX_BODY :: 4 * KIB
PER_UPLOAD_QUOTA :: 16 * MIB

STREAM_FRAMES :: 10
STREAM_INTERVAL :: 50 * time.Millisecond

FNV_OFFSET :: 14695981039346656037
FNV_PRIME :: 1099511628211

app: web.App

Stream_Job :: struct {
	stream: web.Stream,
}

// No globals here, and that is a correction rather than a style preference.
//
// The first edition kept ONE `Stream_Job` and one `^Thread` for the whole
// process, joining the previous thread at the top of the next handler — the
// shape `tests/r1-real-proxy/server/main.odin` uses, where exactly one stream is
// ever requested. This smoke asks for two (direct, then through the proxy), and
// with a shared job the second request could overwrite `stream_job.stream` while
// the first producer was still reading it. Measured: ten frames, then SEVEN,
// then ten again.
//
// A non-deterministic fixture cannot qualify anything. Worse, it was failing in
// the direction that looks like a proxy swallowing frames, which is exactly the
// fault the proxy leg exists to detect — an instrument that manufactures its own
// positive. Each request now owns its job; the thread frees it and cleans itself
// up.

on_signal :: proc "c" (_: posix.Signal) {
	context = runtime.default_context()
	web.stop(&app)
}

arg_int :: proc(index, fallback: int) -> int {
	if len(os.args) <= index {
		return fallback
	}
	value, ok := strconv.parse_int(os.args[index], 10)
	return value if ok else fallback
}

fnv1a :: proc(bytes: []u8) -> u64 {
	h := u64(FNV_OFFSET)
	for b in bytes {h = (h ~ u64(b)) * FNV_PRIME}
	return h
}

health :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

ready :: proc(ctx: ^web.Context) {
	if web.is_draining(&app) {
		web.text(ctx, .Service_Unavailable, "draining")
		return
	}
	web.text(ctx, .OK, "ready")
}

// POST /upload — the spool path, read back and CHECKSUMMED.
//
// The size alone would not do. A spool that wrote the right number of bytes in
// the wrong order, or truncated and padded, reports the same length; the smoke
// exists to find a host whose filesystem or quota mangles the body, and only the
// content can say so. The client computes the same FNV-1a over what it sent and
// compares.
upload_handler :: proc(ctx: ^web.Context) {
	up, ok := web.upload(ctx)
	if !ok {
		// Not an error: it means the body arrived within `max_body` and took
		// the buffered path. The smoke sends one of each and asserts both
		// answers, so this branch is a result rather than a fallback.
		web.text(ctx, .OK, "buffered")
		return
	}
	data, err := os.read_entire_file(up.path, context.temp_allocator)
	if err != nil {
		web.text(ctx, .Internal_Server_Error, "spool-unreadable")
		return
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "size=%d sum=%x", up.size, fnv1a(data))
	web.text(ctx, .Created, strings.to_string(b))
}

stream_producer :: proc(job: ^Stream_Job) {
	for i in 1 ..= STREAM_FRAMES {
		time.sleep(STREAM_INTERVAL)
		frame := fmt.tprintf("data: frame-%d\n\n", i)
		result := web.stream_send(job.stream, transmute([]u8)frame)
		if result != .Sent {
			log.errorf("stream_send frame-%d -> %v (STREAM-001 probe)", i, result)
			break
		}
	}
	web.stream_close(job.stream)
	free(job)
}

// GET /stream — the detached-stream shape. A synchronous handler that sleeps and
// sends cannot let the transport driver progress, so admission happens in the
// handler and sending happens after it returns.
stream_handler :: proc(ctx: ^web.Context) {
	stream, accepted := web.stream(ctx, "text/event-stream")
	if !accepted {
		web.text(ctx, .Service_Unavailable, "stream-refused")
		return
	}
	job := new(Stream_Job)
	job.stream = stream
	// `self_cleanup` so the ^Thread is reclaimed when the producer returns: this
	// handler must not join, and nothing else is left holding the handle.
	// `init_context` matters: without it the producer thread runs on the default
	// context, whose logger is nil, and `framework_report` returns early on
	// exactly that condition. A probe whose output is discarded is the defect
	// this file's header is about.
	_ = thread.create_and_start_with_poly_data(
		job,
		stream_producer,
		init_context = context,
		self_cleanup = true,
	)
}

main :: proc() {
	// A logger and an observer, for the reason `soak-server/main.odin` states
	// at length: a diagnostic that reaches no file cannot be part of any
	// verdict, and a smoke that fails silently is worse than no smoke.
	context.logger = log.create_console_logger(
		lowest = .Info,
		opt = {.Level, .Short_File_Path, .Line, .Procedure},
	)
	defer log.destroy_console_logger(context.logger)

	port := arg_int(1, 8081)
	spool_dir := len(os.args) > 2 ? os.args[2] : ""
	if len(spool_dir) == 0 {
		log.error("smoke-server: a spool directory is required as argv[2]; the core never writes to a /tmp nobody chose")
		os.exit(2)
	}

	app = web.app()
	defer web.destroy(&app)

	limits := web.DEFAULT_LIMITS
	limits.max_handlers = 4
	limits.max_body = MAX_BODY
	limits.max_drain_time = i64(10 * time.Second)
	web.limits(&app, limits)
	web.enable_upload(&app, web.Upload_Config{dir = spool_dir, per_upload_quota = PER_UPLOAD_QUOTA})

	web.get(&app, "/health", health)
	web.get(&app, "/ready", ready)
	web.post(&app, "/upload", upload_handler)
	web.get(&app, "/stream", stream_handler)

	posix.signal(.SIGTERM, on_signal)
	posix.signal(.SIGINT, on_signal)

	web.serve(&app, port)
}
