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
// shows up here as a hit on a route nobody addressed. The counters are printed
// on shutdown so the comparison can read them: a non-zero count is the finding
// that the corpus alone cannot produce, because a single hop has nothing to
// disagree with.
//
// TWO counters, since R2-WP06 measured that one was not enough. `smuggled` is
// every hit; `smuggled_via_proxy` is the subset that arrived carrying the
// proxy's own forwarding headers, which means the proxy MEANT to send it — a
// pipelined request, not a smuggled one. Only `smuggled - smuggled_via_proxy`
// is a desync between the two hops. See `smuggled_handler` for the measurement
// that forced the split.
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
smuggled_via_proxy: int
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

// A hit here means a hop delivered a request to a route nobody addressed —
// through ONE hop. Through a proxy the count alone is not the finding, and
// R2-WP06 measured why: replaying the CL+TE case through the pinned Caddy hits
// this route, and the recorded upstream bytes show the proxy sent
// `GET /smuggled` as its own forwarded request, complete with `Via: 1.1 Caddy`
// and `X-Forwarded-For`. Caddy dropped the ambiguous Content-Length, framed the
// first request by Transfer-Encoding, and read the trailing bytes as a PIPELINED
// second request — which is the RFC 9112 §6.1 reading and not a desync.
//
// So the counter is split. A request smuggled past a proxy arrives INSIDE the
// first request's framing and therefore cannot carry that proxy's own
// forwarding headers; a pipelined one is re-emitted by the proxy and does. The
// distinction is the difference between a vulnerability and a hop doing its job,
// and counting them together made a green result and a red one look identical.
smuggled_handler :: proc(ctx: ^web.Context) {
	smuggled_hits += 1
	_, via := web.header(ctx, "Via")
	_, xff := web.header(ctx, "X-Forwarded-For")
	if via || xff {
		smuggled_via_proxy += 1
		log.warnf(
			"/smuggled reached (hit %d) CARRYING PROXY HEADERS — the proxy forwarded it as its own request (pipelining), not a desync",
			smuggled_hits,
		)
	} else {
		log.errorf(
			"SMUGGLED REQUEST EXECUTED (hit %d) with NO proxy forwarding headers — a hop delivered a request nobody addressed",
			smuggled_hits,
		)
	}
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
	// DELETE, not GET. `tests/wp9-wire` registers `web.delete(&s.app, "/nobody")`
	// and the corpus sends `DELETE /nobody`; this fixture had it as a GET, so the
	// 204-framing case answered 405 on both legs and proved nothing. The routes
	// are this fixture's contract with the corpus, and a method is part of a
	// route — the same class of defect as serving the wrong paths, which is what
	// invalidated the first run of this comparison entirely.
	web.delete(&app, "/nobody", nobody_handler)
	web.get(&app, "/smuggled", smuggled_handler)
	web.post(&app, "/smuggled", smuggled_handler)

	posix.signal(.SIGTERM, on_signal)
	posix.signal(.SIGINT, on_signal)

	web.serve(&app, port)

	// The counters are the result. Printed on the way out so the comparison can
	// read them without an admin endpoint, which would itself be a route the
	// corpus does not know about.
	fmt.printfln(
		"wire_origin_counters ping=%d echo=%d nobody=%d smuggled=%d smuggled_via_proxy=%d",
		ping_hits, echo_hits, nobody_hits, smuggled_hits, smuggled_via_proxy,
	)
}
