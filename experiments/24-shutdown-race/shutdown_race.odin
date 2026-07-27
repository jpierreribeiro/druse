// TRANSPORT AUDIT B2 — CAN THE ACCEPTOR ASSIGN INTO A LANE LOOP THAT IS ALREADY
// DESTROYED?
//
// `server_shutdown` wakes the acceptor and every lane concurrently. Before
// 44bdcda, `on_accept_dedicated` never checked `closing`, and nothing ordered
// "the acceptor stopped assigning" against "the lane released its event loop".
// The acceptor places a connection with `nbio.next_tick_poly`, which allocates
// from the LANE's operation pool, enqueues on the LANE's MPSC ring and writes
// the LANE's eventfd — while `release_thread_event_loop` destroys the pool
// arena, frees the ring buffer, closes the eventfd and zeroes the whole
// `Event_Loop`.
//
// An idle lane completes its shutdown in microseconds. So the window is: a
// connection accepted in the same instant as `web.stop()`, on a server with
// nothing else to drain.
//
// THE MEASUREMENT. This cannot be observed by asserting on behaviour — a
// use-after-free usually produces plausible-looking garbage, not a visible
// error. It needs ASan. Build with `-sanitize:address` (the runner script does)
// and let the sanitizer be the oracle: the harness's own output is only the
// iteration count, and ANY ASan report is the finding.
//
// The delay sweep is the whole trick. A fixed delay between "connect" and
// "stop" would either always miss the window or always land after it; sweeping
// across the microsecond range walks the connect across the lane's entire
// teardown, so some iteration lands inside it.
//
// HOW TO USE IT — THE ORDER MATTERS:
//
//  1. Revert the fix (exact hunks in README.md) and run. Expect an ASan report
//     (use-after-free or use-after-poison inside the lane's pool or MPSC
//     buffer) or a hard crash. RECORD THE ITERATION IT TOOK.
//  2. Restore the fix and run at least 50,000 iterations across the sweep with
//     zero ASan reports.
//  3. If step 1 never reports, say so in those words: the race was not
//     reproduced on this hardware and the fix stands on the code argument
//     alone. Do not present step 2 as proof on its own.
//
// REQUIRED HOST STATE: `ulimit -l unlimited`. Each lane's io_uring rings pin
// memory against RLIMIT_MEMLOCK, ASan inflates the footprint, and the stock
// 8 MiB limit reproduces F-C03-2 (a startup assert) instead of the bug under
// test — which would look like a finding and is not one.
//
// Two lanes, not four, and deliberately: an idle lane finishes its shutdown
// fastest, and that is exactly the timing that opens the window.
package shutdown_race

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:sync"
import "core:thread"
import "core:time"
import web "uruquim:web"

Config :: struct {
	iterations: int,
	lanes:      int,
	port_base:  int,
	sweep_ns:   int, // upper bound of the connect-to-stop delay sweep
	sweep_step: int,
}

config_from_env :: proc() -> Config {
	return Config {
		iterations = env_int("URUQUIM_RACE_ITERATIONS", 50_000),
		lanes      = env_int("URUQUIM_RACE_LANES", 2),
		port_base  = env_int("URUQUIM_RACE_PORT_BASE", 42_100),
		sweep_ns   = env_int("URUQUIM_RACE_SWEEP_NS", 400_000), // 400 µs
		sweep_step = env_int("URUQUIM_RACE_SWEEP_STEP_NS", 971), // prime-ish, avoids harmonics
	}
}

env_int :: proc(name: string, fallback: int) -> int {
	v := os.get_env(name, context.temp_allocator)
	if v == "" {return fallback}
	n, ok := strconv.parse_int(v, 10)
	return n if ok else fallback
}

hello :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "hi")
}

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
}

serve_thread :: proc(s: ^Server) {web.serve(&s.app, s.port)}

// Connector fires a connection at the server without waiting for a response:
// the point is to have an accept in flight, not an exchange.
Connector :: struct {
	port:    int,
	delay:   time.Duration,
	started: sync.Wait_Group,
}

connector_thread :: proc(c: ^Connector) {
	sync.wait_group_done(&c.started)
	if c.delay > 0 {
		time.sleep(c.delay)
	}
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = c.port}
	sock, err := net.dial_tcp(ep)
	if err == nil {
		// Send a partial request so the connection is admitted and handed to a
		// lane, then leave immediately. Errors are expected and ignored: the
		// server is being torn down underneath this on purpose.
		_, _ = net.send_tcp(sock, transmute([]u8)string("GET /x HTTP/1.1\r\n"))
		net.close(sock)
	}
}

main :: proc() {
	cfg := config_from_env()
	fmt.printfln(
		"[b2] iterations=%d lanes=%d sweep=0..%dns step=%dns",
		cfg.iterations, cfg.lanes, cfg.sweep_ns, cfg.sweep_step,
	)
	fmt.println("[b2] ASan is the oracle: this program's own output means nothing without it")

	delay_ns := 0
	completed := 0

	for i in 0 ..< cfg.iterations {
		// Rotate ports so a previous iteration's TIME_WAIT cannot refuse the
		// bind and turn a race test into a port-availability test.
		port := cfg.port_base + (i % 200)

		srv := new(Server)
		srv.port = port
		srv.app = web.app()
		l := web.DEFAULT_LIMITS
		l.max_handlers = cfg.lanes
		web.limits(&srv.app, l)
		web.get(&srv.app, "/x", hello)
		srv.thread = thread.create_and_start_with_poly_data(srv, serve_thread)

		// Wait until the listener is actually up, or the connect races the bind
		// instead of the shutdown.
		up := false
		for _ in 0 ..< 400 {
			s, err := net.dial_tcp(
				net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port},
			)
			if err == nil {net.close(s); up = true; break}
			time.sleep(time.Millisecond)
		}
		if !up {
			// Could not bind (usually port churn); skip without counting.
			web.stop(&srv.app)
			thread.join(srv.thread)
			thread.destroy(srv.thread)
			web.destroy(&srv.app)
			free(srv)
			continue
		}

		// Arm a connection that will land `delay_ns` after this point, then stop
		// the server immediately. Sweeping `delay_ns` walks the accept across
		// the lane's whole teardown.
		conn := Connector{port = port, delay = time.Duration(delay_ns)}
		sync.wait_group_add(&conn.started, 1)
		ct := thread.create_and_start_with_poly_data(&conn, connector_thread)
		sync.wait(&conn.started)

		web.stop(&srv.app)

		thread.join(ct)
		thread.destroy(ct)
		thread.join(srv.thread)
		thread.destroy(srv.thread)
		web.destroy(&srv.app)
		free(srv)

		completed += 1
		delay_ns += cfg.sweep_step
		if delay_ns > cfg.sweep_ns {delay_ns = 0}

		if completed % 500 == 0 {
			fmt.printfln("[b2] progress iterations=%d (no ASan report so far)", completed)
			free_all(context.temp_allocator)
		}
	}

	fmt.printfln("[b2] RESULT completed=%d", completed)
	fmt.println("[b2] VERDICT: no ASan report in this run (meaningful ONLY if the control reported)")
}
