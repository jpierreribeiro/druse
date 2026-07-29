// WP20 socket contract — `Serve_Listen_Failed` is the one framework failure
// that cannot be provoked in memory: it needs a port that is genuinely already
// taken.
//
// The suite binds a loopback port with `core:net`, then points `web.serve` at
// the same port. The bind fails, `serve` returns without serving, and the
// registered observer must see exactly one `Serve_Listen_Failed` event. This
// is also the second transport for the observer contract: the same emission
// path, driven by a real socket failure rather than an in-memory one.
//
// build/check.sh runs this under an EXTERNAL timeout, like every socket suite:
// a `serve` that blocked instead of returning would hang, and a hang is a
// FAILURE, never a stalled gate.
package wp20_socket

import "core:log"
import "core:net"
import "core:strings"
import "core:testing"
import web "druse:web"

// A port set disjoint from the WP8/WP9/WP17 candidates.
@(private = "file")
WP20_CANDIDATE_PORTS :: [?]int{53717, 54219, 54873}

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

@(private = "file")
Sink :: struct {
	count:     int,
	last_kind: web.Framework_Error,
	last_route: string,
}

@(private = "file")
record_event :: proc(event: web.Framework_Event) {
	sink := (^Sink)(context.user_ptr)
	if sink == nil {
		return
	}
	sink.count += 1
	sink.last_kind = event.kind
	sink.last_route = event.route
}

@(private = "file")
ping :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

@(test)
wp20_listen_failure_is_observed_on_a_real_socket :: proc(t: ^testing.T) {
	sink: Sink
	context.user_ptr = &sink
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	// Take a port first, so the framework's bind is guaranteed to fail.
	occupied := -1
	blocker: net.TCP_Socket
	for candidate in WP20_CANDIDATE_PORTS {
		sock, err := net.listen_tcp(
			net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = candidate},
		)
		if err == nil {
			blocker = sock
			occupied = candidate
			break
		}
	}
	testing.expect(t, occupied > 0, "the test could not occupy any candidate port")
	if occupied <= 0 {
		return
	}
	defer net.close(blocker)

	a := web.app()
	defer web.destroy(&a)
	web.observe(&a, record_event)
	web.get(&a, "/ping", ping)

	// `serve` must fail to bind and RETURN — it never blocks on a port it
	// could not take.
	web.serve(&a, occupied)

	testing.expect_value(t, sink.count, 1)
	testing.expect_value(t, sink.last_kind, web.Framework_Error.Serve_Listen_Failed)
	// A serve-path failure belongs to no request: no route identity.
	testing.expect_value(t, sink.last_route, "")
}
