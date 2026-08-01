package r0_app_serve_lifecycle_socket

import "core:net"
import "core:log"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import lab "druse:tests/support/web_blocking_lab"
import web "druse:web"

R0_PORT_PRIMARY :: 53411
R0_PORT_CONCURRENT :: 53421
R0_PORT_RESTART :: 53431
R0_PORT_BLOCKED :: 53441
R0_PORT_RETRY :: 53451
R0_WAIT :: 3 * time.Second

R0_Serve_Work :: struct {
	app:    ^web.App,
	port:   int,
	done:   sync.Sema,
	thread: ^thread.Thread,
}

R0_Quiet :: struct {
	inner: log.Logger,
}

r0_quiet_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	message: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^R0_Quiet)(data)
	if level == .Error && strings.contains(message, "druse:") {
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, message, options, location)
	}
}

r0_quiet_logger :: proc(record: ^R0_Quiet) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = r0_quiet_logger_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

r0_ok :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

r0_serve_worker :: proc(work: ^R0_Serve_Work) {
	web.serve(work.app, work.port)
	sync.sema_post(&work.done)
}

r0_start :: proc(work: ^R0_Serve_Work, app: ^web.App, port: int) {
	work.app = app
	work.port = port
	work.thread = thread.create_and_start_with_poly_data(work, r0_serve_worker)
}

r0_reap :: proc(work: ^R0_Serve_Work) {
	if work.thread != nil {
		thread.join(work.thread)
		thread.destroy(work.thread)
		work.thread = nil
	}
}

r0_wait_ready :: proc(port: int) -> bool {
	for _ in 0 ..< 200 {
		status, _, ok := lab.Request(port, "/health")
		if ok && status == 200 {
			return true
		}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

@(test)
r0_same_app_has_one_active_server_and_a_bounded_lifecycle :: proc(t: ^testing.T) {
	quiet: R0_Quiet
	previous_logger := context.logger
	context.logger = r0_quiet_logger(&quiet)
	defer context.logger = previous_logger

	a := web.app()
	defer web.destroy(&a)
	web.get(&a, "/health", r0_ok)

	primary: R0_Serve_Work
	r0_start(&primary, &a, R0_PORT_PRIMARY)
	testing.expect(t, r0_wait_ready(R0_PORT_PRIMARY), "the primary server must listen")

	// A second concurrent serve on the same App returns before bind and cannot
	// replace the handle used to stop the primary.
	concurrent: R0_Serve_Work
	r0_start(&concurrent, &a, R0_PORT_CONCURRENT)
	testing.expect(
		t,
		sync.sema_wait_with_timeout(&concurrent.done, R0_WAIT),
		"a concurrent serve on the same App must return before binding",
	)
	_, _, concurrent_bound := lab.Request(R0_PORT_CONCURRENT, "/health")
	testing.expect(t, !concurrent_bound, "the rejected concurrent serve must not bind")
	status, _, primary_ok := lab.Request(R0_PORT_PRIMARY, "/health")
	testing.expect(t, primary_ok && status == 200, "the primary must retain its handle and keep serving")
	r0_reap(&concurrent)

	web.stop(&a)
	testing.expect(t, sync.sema_wait_with_timeout(&primary.done, R0_WAIT), "the primary must drain")
	r0_reap(&primary)

	// Draining is terminal. A restart attempt returns and never binds.
	restart: R0_Serve_Work
	r0_start(&restart, &a, R0_PORT_RESTART)
	testing.expect(t, sync.sema_wait_with_timeout(&restart.done, R0_WAIT), "a draining App must reject restart")
	_, _, restart_bound := lab.Request(R0_PORT_RESTART, "/health")
	testing.expect(t, !restart_bound, "a draining App must not bind a restarted server")
	r0_reap(&restart)

	// Bind failure is not drain: the active claim is released and the same App
	// can retry another port with its already-frozen configuration.
	b := web.app()
	defer web.destroy(&b)
	web.get(&b, "/health", r0_ok)
	blocker, block_err := net.listen_tcp(
		net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = R0_PORT_BLOCKED},
	)
	testing.expect(t, block_err == nil, "the fixture must occupy the blocked port")
	if block_err != nil {
		return
	}
	web.serve(&b, R0_PORT_BLOCKED)
	net.close(blocker)

	retry: R0_Serve_Work
	r0_start(&retry, &b, R0_PORT_RETRY)
	testing.expect(t, r0_wait_ready(R0_PORT_RETRY), "the App must retry after bind failure")
	web.stop(&b)
	testing.expect(t, sync.sema_wait_with_timeout(&retry.done, R0_WAIT), "the retried server must drain")
	r0_reap(&retry)
}
