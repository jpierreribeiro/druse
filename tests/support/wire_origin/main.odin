// The raw-wire corpus's origin, as a STANDALONE BINARY.
//
// WHY THIS EXISTS. `tests/wp9-wire` builds these routes inside an `odin test`
// process, which is right for the suite and useless for R2-WP06: that work
// package asks to "repetir smuggling/framing pelo proxy real para detectar
// divergência de parser", and a proxy needs something to proxy TO.
//
// The first attempt at that comparison used `tests/r1-real-proxy/server` and the
// run was INVALID — that origin serves `/health`, `/ok`, `/body`, and the corpus
// targets `/ping`, `/echo` and `/smuggled`. Every case that should have reached
// a handler answered 404 on both legs, so nothing involving a handler could be
// read. The routes are the fixture's contract, not a detail.
//
// The routes and their status codes are copied from the suite deliberately, and
// the corpus states them in its own header: `GET /ping` answers 200 "pong",
// `POST /echo` binds a JSON body and answers 201, `/smuggled` exists so that a
// smuggled request WOULD be observable, and `/nobody` answers 204 so response
// framing can be asserted rather than only request rejection.
//
// `/smuggled` IS THE INSTRUMENT. A request that crosses a proxy as two requests
// shows up here as a hit on a route nobody addressed. The counter is printed on
// shutdown so the comparison can read it: a non-zero count is the finding that
// the corpus alone cannot produce, because a single hop has nothing to disagree
// with.
package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:sys/posix"
import web "druse:web"

app: web.App

ping_hits: int
echo_hits: int
smuggled_hits: int
nobody_hits: int

Echo :: struct {
	name: string `json:"name"`,
}

on_signal :: proc "c" (_: posix.Signal) {
	context = runtime.default_context()
	web.stop(&app)
}

ping_handler :: proc(ctx: ^web.Context) {
	ping_hits += 1
	web.text(ctx, .OK, "pong")
}

echo_handler :: proc(ctx: ^web.Context) {
	echo_hits += 1
	input: Echo
	if !web.body(ctx, &input) {
		return
	}
	web.created(ctx, input)
}

nobody_handler :: proc(ctx: ^web.Context) {
	nobody_hits += 1
	web.no_content(ctx)
}

// Must stay at zero. A hit here means a hop executed a request nobody sent.
smuggled_handler :: proc(ctx: ^web.Context) {
	smuggled_hits += 1
	log.errorf("SMUGGLED REQUEST EXECUTED (hit %d) — a hop delivered a request nobody addressed", smuggled_hits)
	web.text(ctx, .OK, "smuggled")
}

main :: proc() {
	context.logger = log.create_console_logger(
		lowest = .Info,
		opt = {.Level, .Short_File_Path, .Line, .Procedure},
	)
	defer log.destroy_console_logger(context.logger)

	port := 18301
	if len(os.args) > 1 {
		if v, ok := strconv.parse_int(os.args[1], 10); ok {port = v}
	}

	app = web.app()
	defer web.destroy(&app)

	web.get(&app, "/ping", ping_handler)
	web.post(&app, "/ping", ping_handler)
	web.post(&app, "/echo", echo_handler)
	web.get(&app, "/nobody", nobody_handler)
	web.get(&app, "/smuggled", smuggled_handler)
	web.post(&app, "/smuggled", smuggled_handler)

	posix.signal(.SIGTERM, on_signal)
	posix.signal(.SIGINT, on_signal)

	web.serve(&app, port)

	// The counters are the result. Printed on the way out so the comparison can
	// read them without an admin endpoint, which would itself be a route the
	// corpus does not know about.
	fmt.printfln(
		"wire_origin_counters ping=%d echo=%d nobody=%d smuggled=%d",
		ping_hits, echo_hits, nobody_hits, smuggled_hits,
	)
}
