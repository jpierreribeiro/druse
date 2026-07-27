// TRANSPORT AUDIT B1 — DOES THE ACCEPTOR EVER PARK WITH A CONNECTION IT NEVER
// PLACES?
//
// The acceptor and the Handler lanes negotiate availability through a two-flag
// (Dekker) handshake: the acceptor publishes "I am about to park" in
// `pending_waiting`, each lane publishes "I became available" by clearing
// `handler_active` / decrementing `queued_handoffs`, and each side then reads
// the other's flag. Before 44bdcda both sides used Release/Acquire, which does
// NOT forbid the store-then-load reordering this pattern turns on. If a lane
// freed its slot inside the window between the acceptor's last scan and its
// `pending_waiting` store, the lane could read a stale `false` (so it did not
// wake anyone) while the acceptor had already read a stale "every lane is full"
// (so it parked). Both miss.
//
// The consequence is not slowness. `nbio.tick()` on the acceptor takes NO
// timeout and the acceptor loop runs no timer of its own, while
// `pending_accept.valid` stays true so `accept_arm` refuses to re-arm. The
// server then accepts NOTHING until some unrelated lane event happens to occur
// — unbounded if traffic pauses.
//
// THE MEASUREMENT. That distinction is what this harness is built around: it
// does not time requests under load, because a slow response under load proves
// nothing. It drives every lane to its handoff cap, then STOPS ALL TRAFFIC and
// lets the server go completely idle, and only then asks a single canary client
// for one trivial request. A canary that times out while the server has no work
// at all is a stall, and nothing else looks like that.
//
// HOW TO USE IT — AND THE ORDER MATTERS:
//
//  1. Revert the fix (see `experiments/23-accept-stall/README.md` for the exact
//     hunks) and run until a canary failure is observed. RECORD HOW LONG THAT
//     TOOK. Until this step has failed, the harness has not been shown to
//     measure anything.
//  2. Restore the fix and run for at least 10x that duration, or 6 h, whichever
//     is longer, expecting zero canary failures.
//  3. If step 1 never fails, say so in those words. The race may be too narrow
//     to hit on this hardware, in which case the fix stands on the memory-model
//     argument alone and this harness bounds nothing. That is a legitimate
//     outcome; reporting only the clean run from step 2 is not.
//
// Deliberately two lanes, not four: the campaign host has four PHYSICAL cores
// (a c5.2xlarge is 4 x 2 hyperthreads), so two lanes leave real cores for the
// wave generator and the canary. A canary that competes with the server for CPU
// produces false positives, which is the one failure mode this must not have.
// Two lanes also make saturation cheaper to reach — the cap is 2 per lane.
package accept_stall

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import web "uruquim:web"

// --- configuration (environment, so the runner script owns the values) ------

Config :: struct {
	port:          int,
	lanes:         int,
	duration:      time.Duration,
	dwell:         time.Duration, // how long a loaded handler occupies its lane
	wave_clients:  int,           // connections per saturation wave
	quiet:         time.Duration, // how long the server is left completely idle
	canary_budget: time.Duration, // a canary slower than this counts as a stall
}

config_from_env :: proc() -> Config {
	c := Config {
		port          = env_int("URUQUIM_STALL_PORT", 42_010),
		lanes         = env_int("URUQUIM_STALL_LANES", 2),
		duration      = time.Duration(env_int("URUQUIM_STALL_MINUTES", 60)) * time.Minute,
		dwell         = time.Duration(env_int("URUQUIM_STALL_DWELL_MS", 40)) * time.Millisecond,
		wave_clients  = env_int("URUQUIM_STALL_WAVE", 8),
		quiet         = time.Duration(env_int("URUQUIM_STALL_QUIET_MS", 300)) * time.Millisecond,
		canary_budget = time.Duration(env_int("URUQUIM_STALL_CANARY_MS", 2000)) * time.Millisecond,
	}
	return c
}

env_int :: proc(name: string, fallback: int) -> int {
	v := os.get_env(name, context.temp_allocator)
	if v == "" {
		return fallback
	}
	n, ok := strconv.parse_int(v, 10)
	if !ok {
		return fallback
	}
	return n
}

// --- application ------------------------------------------------------------

g_dwell: time.Duration

// /load occupies its lane for `dwell`, which is what drives lanes to the cap.
load_handler :: proc(ctx: ^web.Context) {
	time.sleep(g_dwell)
	web.text(ctx, .OK, "loaded")
}

// /ping is the canary's route: it must never be slow, because by the time the
// canary runs there is nothing else on the server.
ping_handler :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
}

serve_thread :: proc(s: ^Server) {web.serve(&s.app, s.port)}

server_start :: proc(s: ^Server, cfg: Config) -> bool {
	s.port = cfg.port
	s.app = web.app()
	l := web.DEFAULT_LIMITS
	l.max_handlers = cfg.lanes
	web.limits(&s.app, l)
	web.get(&s.app, "/load", load_handler)
	web.get(&s.app, "/ping", ping_handler)
	s.thread = thread.create_and_start_with_poly_data(s, serve_thread)
	for _ in 0 ..< 500 {
		sock, err := net.dial_tcp(
			net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = cfg.port},
		)
		if err == nil {net.close(sock); return true}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

server_stop :: proc(s: ^Server) {
	web.stop(&s.app)
	if s.thread != nil {thread.join(s.thread); thread.destroy(s.thread); s.thread = nil}
	web.destroy(&s.app)
}

// --- clients ----------------------------------------------------------------

dial :: proc(port: int, attempts: int = 40) -> (net.TCP_Socket, bool) {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	for _ in 0 ..< attempts {
		s, err := net.dial_tcp(ep)
		if err == nil {return s, true}
		time.sleep(time.Millisecond)
	}
	return {}, false
}

// one_request performs a complete exchange and reports whether a response
// arrived. `budget` bounds the WHOLE thing, connect included: a stalled acceptor
// fails at connect-accept, not at read.
one_request :: proc(port: int, path: string, budget: time.Duration) -> bool {
	sock, ok := dial(port, 5)
	if !ok {
		return false
	}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, budget)
	net.set_option(sock, .Send_Timeout, budget)

	req := strings.concatenate(
		{"GET ", path, " HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"},
		context.temp_allocator,
	)
	data := transmute([]u8)req
	off := 0
	for off < len(data) {
		n, err := net.send_tcp(sock, data[off:])
		if err != nil || n <= 0 {return false}
		off += n
	}

	buf: [1024]u8
	n, rerr := net.recv_tcp(sock, buf[:])
	return rerr == nil && n > 0
}

// Wave_State drives one saturation wave: `wave_clients` connections issued as
// close to simultaneously as threads allow, each asking for the dwelling route,
// so every lane reaches `URUQUIM_ACCEPT_HANDOFF_LIMIT` at the same moment.
Wave_State :: struct {
	cfg:     Config,
	running: bool,
	wg:      sync.Wait_Group,
}

wave_worker :: proc(w: ^Wave_State) {
	// Errors are EXPECTED and ignored here: under saturation some of these are
	// refused with 503 by design. This thread exists to create the condition,
	// not to measure it — only the canary measures.
	_ = one_request(w.cfg.port, "/load", 5 * time.Second)
	sync.wait_group_done(&w.wg)
}

// --- the run ----------------------------------------------------------------

main :: proc() {
	cfg := config_from_env()
	g_dwell = cfg.dwell

	fmt.printfln(
		"[b1] port=%d lanes=%d duration=%v dwell=%v wave=%d quiet=%v canary_budget=%v",
		cfg.port, cfg.lanes, cfg.duration, cfg.dwell, cfg.wave_clients, cfg.quiet,
		cfg.canary_budget,
	)

	srv: Server
	if !server_start(&srv, cfg) {
		fmt.eprintln("[b1] FATAL: server did not start")
		os.exit(2)
	}

	deadline := time.time_add(time.now(), cfg.duration)
	cycles := 0
	canary_failures := 0
	worst_canary: time.Duration

	for time.since(deadline) < 0 {
		cycles += 1

		// 1. Saturate: every lane busy AND its handoff queue at the cap.
		w := Wave_State{cfg = cfg, running = true}
		sync.wait_group_add(&w.wg, cfg.wave_clients)
		threads := make([]^thread.Thread, cfg.wave_clients, context.temp_allocator)
		for i in 0 ..< cfg.wave_clients {
			threads[i] = thread.create_and_start_with_poly_data(&w, wave_worker)
		}
		sync.wait(&w.wg)
		for t in threads {thread.join(t); thread.destroy(t)}

		// 2. Go completely quiet. This is the load-bearing step: the acceptor
		//    must be parked with nothing left to wake it except a new connection.
		time.sleep(cfg.quiet)

		// 3. The canary. On a healthy server this is a sub-millisecond exchange
		//    against an idle process.
		start := time.now()
		ok := one_request(cfg.port, "/ping", cfg.canary_budget)
		elapsed := time.since(start)
		if elapsed > worst_canary {worst_canary = elapsed}

		if !ok || elapsed >= cfg.canary_budget {
			canary_failures += 1
			fmt.printfln(
				"[b1] STALL cycle=%d elapsed=%v ok=%v (server was idle; this is not slowness)",
				cycles, elapsed, ok,
			)
			// Keep going: how OFTEN it stalls is the useful number, and an
			// immediate exit would hide whether it recovers.
		}

		if cycles % 200 == 0 {
			fmt.printfln(
				"[b1] progress cycles=%d stalls=%d worst_canary=%v",
				cycles, canary_failures, worst_canary,
			)
			free_all(context.temp_allocator)
		}
	}

	server_stop(&srv)

	fmt.printfln(
		"[b1] RESULT cycles=%d stalls=%d worst_canary=%v",
		cycles, canary_failures, worst_canary,
	)
	if canary_failures > 0 {
		fmt.printfln("[b1] VERDICT: STALL REPRODUCED (%d times)", canary_failures)
		os.exit(1)
	}
	fmt.println("[b1] VERDICT: no stall observed in this run")
	os.exit(0)
}
