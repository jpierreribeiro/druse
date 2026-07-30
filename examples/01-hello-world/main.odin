// Druse example 01 — Hello World.
//
// The smallest complete Druse program: one route, one response, one server.
//
// Build and run it from the repository root:
//
//	odin run examples/01-hello-world -collection:druse=.
//
// Then, in another terminal:
//
//	curl http://localhost:8080/ping
//	pong
//
// Press Ctrl+C to stop the server.
package main

import web "druse:web"

main :: proc() {
	// `app()` creates the application with the Phase-1 defaults: a standardized
	// 404 for an unknown path, and a 405 with an `Allow` header when the path
	// exists under a different method.
	app := web.app()

	// `destroy` releases everything the application owns. Call it exactly once,
	// on the value `app()` returned — `defer` is the canonical way.
	defer web.destroy(&app)

	// Register one route. The handler runs when a GET arrives at /ping.
	web.get(&app, "/ping", ping)

	// `serve` binds the port and blocks while the server runs.
	// Everything after this line runs only after the server stops.
	web.serve(&app, 8080)
}

// A handler receives the request context and returns nothing. It answers by
// calling one of the response helpers.
ping :: proc(ctx: ^web.Context) {
	// `text` sends a plain-text body with the status you choose.
	// It sets `Content-Type: text/plain; charset=utf-8` for you.
	web.text(ctx, .OK, "pong")
}
