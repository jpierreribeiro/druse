// WP17 socket contract — the fail-closed guard on the REAL transport.
//
// ADR-019 property (a) requires the guard to live on the dispatch path so both
// transports behave identically; the approved diagnostic additionally promises
// that `web.serve` REFUSES TO START on a poisoned application. The in-memory
// half (every request answers 500) is asserted by tests/wp17-internal and
// tests/wp17-public-surface; this suite asserts the socket half: `serve` on a
// mis-ordered application returns without binding, and nothing ever accepts on
// the port.
//
// The suite deliberately never sleeps its way to readiness: `serve` returning
// is observed through an atomic flag with a bounded poll, and the "nothing is
// listening" claim is a direct dial that must fail. If the guard were missing,
// `serve` would bind and block, the flag would never set, and the bounded poll
// fails the test (build/check.sh additionally wraps the suite in an external
// timeout, the WP8/WP9 socket-suite rule).
package wp17_socket

import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

// The poison report and the serve refusal are EXPECTED Error-level `druse:`
// log lines; the pinned test runner records Error output as a failure, so the
// test swallows exactly those and forwards everything else (the WP8 idiom).
@(private = "file")
Quiet :: struct {
	inner: log.Logger,
}

@(private = "file")
quiet_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Quiet)(data)
	if level == .Error && strings.contains(text, "druse:") {
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

@(private = "file")
quiet_logger :: proc(record: ^Quiet) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = quiet_logger_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

// A port set disjoint from the WP8/WP9 candidates, so parallel suites cannot
// collide.
@(private = "file")
WP17_CANDIDATE_PORTS :: [?]int{51431, 52117, 52963}

@(private = "file")
Refusal_Fixture :: struct {
	app:      web.App,
	port:     int,
	returned: bool, // written by the serve thread, read by the test
}

@(private = "file")
g_refusal: ^Refusal_Fixture

@(private = "file")
secret_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "TOP-SECRET-USERS")
}

@(private = "file")
auth_noop :: proc(ctx: ^web.Context) {
	web.next(ctx)
}

@(private = "file")
refusal_serve_thread :: proc() {
	f := g_refusal
	web.serve(&f.app, f.port)
	sync.atomic_store(&f.returned, true)
}

@(test)
wp17_serve_refuses_to_start_on_a_poisoned_app :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	fixture: Refusal_Fixture
	fixture.app = web.app()
	fixture.port = WP17_CANDIDATE_PORTS[0]
	g_refusal = &fixture
	defer web.destroy(&fixture.app)

	// The WP12 D-12.5 mis-ordered program: a route first, `use` second.
	web.get(&fixture.app, "/admin/users", secret_handler)
	web.use(&fixture.app, auth_noop)

	worker := thread.create_and_start(refusal_serve_thread)
	defer thread.destroy(worker)

	// `serve` must return promptly WITHOUT binding. Bounded poll: 5 seconds is
	// three orders of magnitude above an immediate return, and a guard that
	// takes longer than that has bound a socket and blocked.
	returned := false
	for _ in 0 ..< 1000 {
		if sync.atomic_load(&fixture.returned) {
			returned = true
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	testing.expect(
		t,
		returned,
		"web.serve must refuse to start on a poisoned application (ADR-019); it is still running",
	)
	if returned {
		thread.join(worker)
	}

	// And nothing accepts on the port: the protected route is unreachable over
	// the real transport, exactly as it is unreachable in memory.
	ep := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = fixture.port,
	}
	sock, err := net.dial_tcp(ep)
	if err == nil {
		net.close(sock)
	}
	testing.expect(
		t,
		err != nil,
		"no listener may exist on the port; the poisoned app must never accept a connection",
	)
}
