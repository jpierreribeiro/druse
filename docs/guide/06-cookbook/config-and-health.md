# Config, health and readiness

A twelve-factor service reads configuration from the **environment**, and
exposes two distinct signals: liveness (is the process up?) and readiness
(should traffic be routed here?).

Druse does neither for you — configuration is your `main`'s job and the probes
are ordinary handlers — but it gives you the pieces. `examples/10-config-and-health`,
complete.

## Server

<!-- druse:begin examples/10-config-and-health/main.odin -->
```odin
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
	// the fallback. Nothing here is Uruquim-specific — it is ordinary code that
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

	posix.signal(.SIGTERM, on_signal)
	posix.signal(.SIGINT, on_signal)

	port := env_int("PORT", 8080)
	web.serve(&app, port)
}
```
<!-- druse:end -->

## Run

```text
PORT=9000 MAX_HANDLERS=16 odin run examples/10-config-and-health -collection:druse=.
```

## Client

```text
curl http://localhost:9000/health   # 200 while the process runs
curl http://localhost:9000/ready    # 200 while serving, 503 once draining
```

## What to notice

**Liveness and readiness are different questions.** Liveness answers "is this
process alive" — a supervisor kills it when this fails. Readiness answers
"should I send traffic here" — a load balancer stops routing when this fails.

Wiring one probe to both is the mistake. During drain, readiness must fail and
liveness must not, or your supervisor kills the process mid-drain.

**Liveness must not touch the database.** A slow query would make every replica
restart at once, turning a database problem into an outage.

**Configuration is read before anything is opened.** A bad value exits before a
port is bound. See [`../04-rules/configuration.md`](../04-rules/configuration.md),
and use `crystals:config` for a loader that reports every bad variable at once
rather than the first.

## Next

[`../03-subjects/limits-and-shutdown.md`](../03-subjects/limits-and-shutdown.md)
— what bounds the server, and what is off by default.
