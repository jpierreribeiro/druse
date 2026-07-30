// Druse example 09 — Graceful shutdown.
//
// A production server must stop WITHOUT dropping the requests already in flight
// — every rolling deploy sends it a signal and expects the in-flight work to
// finish. The framework installs no signal handler for you (that would fight
// your process manager); it gives you `web.stop`, which is safe to call from a
// signal handler, and `web.is_draining`, which a readiness probe reads.
//
// Build and run it from the repository root:
//
//	odin run examples/09-graceful-shutdown -collection:druse=.
//
// Then send it a signal (or press Ctrl+C):
//
//	curl http://localhost:8080/ready   # 200 while serving
//	kill -TERM <pid>                   # begins the graceful drain
//	curl http://localhost:8080/ready   # 503 while draining
//
// On the signal, in-flight requests finish and the server drains within
// `Limits.max_drain_time`; `web.serve` then returns and `main` ends.
package main

import "base:runtime"
import "core:sys/posix"
import web "druse:web"

// The App lives for the whole process, so it is a package global — a signal
// handler receives only the signal number and cannot be handed the App any
// other way. This is the one place an example reaches for a global, and it is
// the honest shape: the server IS the process.
app: web.App

// The signal handler does the least possible: ask the server to stop. `web.stop`
// is async-signal-safe (an atomic flag plus an event-loop wake-up), so calling
// it here is allowed where almost nothing else — no allocation, no logging —
// would be.
on_signal :: proc "c" (_: posix.Signal) {
	// A C-ABI handler carries no Odin context; give it the default one. This is
	// a stack value with no allocation, so `web.stop` — an atomic store plus an
	// event-loop wake-up — stays async-signal-safe.
	context = runtime.default_context()
	web.stop(&app)
}

main :: proc() {
	app = web.app()
	defer web.destroy(&app)

	// Liveness: the process is up. It answers 200 as long as it can run a
	// handler at all — a supervisor uses this to decide whether to RESTART.
	web.get(&app, "/health", proc(ctx: ^web.Context) {
		web.text(ctx, .OK, "ok")
	})

	// Readiness: should the load balancer still route new traffic here? It
	// answers 503 the instant a drain begins, so the proxy stops sending
	// requests the server is about to refuse. This is what `is_draining` is for.
	web.get(&app, "/ready", proc(ctx: ^web.Context) {
		// The handler reads the App through the same package global the signal
		// handler uses: with one server per process, the App is the process.
		if web.is_draining(&app) {
			web.text(ctx, web.Status(503), "draining")
			return
		}
		web.text(ctx, .OK, "ready")
	})

	// Install the handlers AFTER the routes: registration is closed once
	// serving begins, and the handler only touches `web.stop`, which is valid
	// at any time.
	posix.signal(.SIGTERM, on_signal)
	posix.signal(.SIGINT, on_signal)

	// Blocks until a signal triggers `web.stop` and the drain completes.
	web.serve(&app, 8080)
}
