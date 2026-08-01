// Druse example 10 — Config from the environment, health and readiness.
//
// A twelve-factor service reads its configuration from the ENVIRONMENT, not
// from code, and exposes two distinct operational signals: liveness (is the
// process up?) and readiness (should traffic be routed here?). Druse's core
// does neither for you — configuration is your `main`'s job, and the two probes
// are ordinary handlers — but it gives you the pieces: `web.limits` takes the
// values you loaded, `web.is_draining` tells a readiness handler when a
// shutdown has begun, and `web.stats` reports what this server actually sent.
// (Signal wiring is the same shape as example 09.)
//
// EVERY ONE OF THOSE TAKES THE APP, and that is worth noticing rather than
// skipping past. A process may run more than one server — an application
// listener beside an admin or metrics listener is the ordinary case — and each
// of these questions has a different answer for each of them. Passing the App
// is what makes `/metrics` on this port report THIS port's traffic.
//
// Build and run it from the repository root:
//
//	PORT=9000 MAX_HANDLERS=16 odin run examples/10-config-and-health -collection:druse=.
//
// Then:
//
//	curl http://localhost:9000/health   # 200 while the process runs
//	curl http://localhost:9000/ready    # 200 while serving, 503 once draining
//	curl http://localhost:9000/metrics  # this server's write-side counters
package main

import "base:runtime"
import "core:os"
import "core:strconv"
import "core:sys/posix"
import web "druse:web"

app: web.App

on_signal :: proc "c" (_: posix.Signal) {
	context = runtime.default_context()
	web.stop(&app)
}

// env_int reads an environment variable as an int, falling back to `fallback`
// when it is unset or not a number. Configuration is explicit and total: an
// unreadable value never silently becomes zero.
env_int :: proc(key: string, fallback: int) -> int {
	value, found := os.lookup_env(key, context.temp_allocator)
	if !found {
		return fallback
	}
	parsed, ok := strconv.parse_int(value, 10)
	if !ok {
		return fallback
	}
	return parsed
}

main :: proc() {
	app = web.app()
	defer web.destroy(&app)

	// Configuration from the environment, with the framework's own defaults as
	// the fallback. Nothing here is Druse-specific — it is ordinary code that
	// hands resolved integers to `web.limits`.
	budget := web.DEFAULT_LIMITS
	budget.max_body        = env_int("MAX_BODY", budget.max_body)
	budget.max_connections = env_int("MAX_CONNECTIONS", budget.max_connections)
	budget.max_handlers    = env_int("MAX_HANDLERS", budget.max_handlers)
	web.limits(&app, budget)

	// Liveness: the process is up and can run a handler. A supervisor uses this
	// to decide whether to RESTART.
	web.get(&app, "/health", proc(ctx: ^web.Context) {
		web.ok(ctx, "ok")
	})

	// Readiness: should the load balancer route new traffic here? It flips to
	// not-ready the instant a drain begins, so the proxy stops sending requests
	// the server is about to refuse.
	web.get(&app, "/ready", proc(ctx: ^web.Context) {
		if web.is_draining(&app) {
			web.text(ctx, web.Status(503), "draining")
			return
		}
		web.text(ctx, .OK, "ready")
	})

	// The write-side counters, as ten integers your existing scraper differences.
	// They are this App's server's own: `web.stats` reads the server THIS App
	// started, so a second listener in the same process reports separately rather
	// than both reporting whichever one happened to start last.
	//
	// Every field is an integer, which is what keeps this inside the redaction
	// policy's permitted set — no request-derived byte can reach a scraper here.
	web.get(&app, "/metrics", proc(ctx: ^web.Context) {
		web.ok(ctx, web.stats(&app))
	})

	posix.signal(.SIGTERM, on_signal)
	posix.signal(.SIGINT, on_signal)

	port := env_int("PORT", 8080)
	web.serve(&app, port)
}
