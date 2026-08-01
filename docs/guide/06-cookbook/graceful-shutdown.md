# Graceful shutdown

A production server needs a bounded, observable drain. Every rolling deploy
sends a signal; admission closes and cooperative in-flight work may finish
before the transport deadline.

Druse installs no signal handler — that would fight your process manager. It
gives you `web.stop`, safe to call from a handler, and `web.is_draining`, which
a readiness probe reads.

This is `examples/09-graceful-shutdown`, complete.

## Server

<!-- druse:begin examples/09-graceful-shutdown/main.odin -->
```odin
package main

import "base:runtime"
import "core:sys/posix"
import web "druse:web"

app: web.App

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
		// handler uses: this process runs one server, and this App is it. A
		// process running two would give each its own `stop` (ADR-018).
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
```
<!-- druse:end -->

## Run

```text
odin run examples/09-graceful-shutdown -collection:druse=.
```

## Client

```text
curl http://localhost:8080/ready   # 200 while serving
kill -TERM <pid>                   # begins the graceful drain
curl http://localhost:8080/ready   # 503 while draining
```

On the signal, the transport drains within `Limits.max_drain_time`.
`web.serve` returns after cooperative handlers release their lanes. A
synchronous handler blocked in arbitrary user or C code cannot be preempted, so
keep the supervisor's `TimeoutStopSec` greater than `max_drain_time`: the
supervisor owns the absolute process deadline.

## What to notice

**The App is a package global here, and that is the honest shape.** A signal
handler receives only the signal number; it cannot be handed the App any other
way. The server *is* the process.

**Readiness reads `is_draining`. Liveness must not.** A draining process is
alive — a liveness probe that fails during drain gets the process killed
mid-drain, which undoes the whole point. Route the readiness probe to your load
balancer and the liveness probe to your supervisor.

**Everything after `web.serve` runs on the way out.** `serve` blocks, then
returns, and your deferred destroys execute. Close the pool after it returns,
never before.

The repository's real-process drill sends POSIX signals, holds sockets in each
shutdown state and checks process exit codes:

```text
bash ops/verification/run-shutdown-drill.sh
```

## Next

[`config-and-health.md`](config-and-health.md) — the same wiring, with
configuration read from the environment.
