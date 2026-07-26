package http

import "base:runtime"

import "core:bufio"
import "core:bytes"
import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:nbio"
// URUQUIM PATCH 19 (WP90) — for the SO_LINGER abort in `connection_abort`.
// `core:net`'s own `.Linger` option is unusable here: on this pinned
// toolchain it marshals a `timeval` where the kernel expects `struct linger`.
import "core:sys/linux"
import "core:net"
import "core:os"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"

// URUQUIM PATCH 32 (adopted performance path) — one acceptor owns the shared
// listen socket and assigns each connection once to an available lane. The
// previous shared-accept implementation remains available as a build-time
// rollback control.
URUQUIM_DEDICATED_ACCEPT :: #config(URUQUIM_DEDICATED_ACCEPT, true)

Server_Opts :: struct {
	// Whether the server should accept every request that sends a "Expect: 100-continue" header automatically.
	// Defaults to true.
	auto_expect_continue:    bool,
	// When this is true, any HEAD request is automatically redirected to the handler as a GET request.
	// Then, when the response is sent, the body is removed from the response.
	// Defaults to true.
	redirect_head_to_get:    bool,
	// Limit the maximum number of bytes to read for the request line (first line of request containing the URI).
	// The HTTP spec does not specify any limits but in practice it is safer.
	// RFC 7230 3.1.1 says:
	// Various ad hoc limitations on request-line length are found in
	// practice.  It is RECOMMENDED that all HTTP senders and recipients
	// support, at a minimum, request-line lengths of 8000 octets.
	// defaults to 8000.
	limit_request_line:      int,
	// Limit the length of the headers.
	// The HTTP spec does not specify any limits but in practice it is safer.
	// defaults to 8000.
	limit_headers:           int,
	// URUQUIM PATCH 8 (WP47) — bounded admission.
	//
	// The maximum number of concurrent connections the SERVER will hold across
	// all lanes. Zero means unbounded, which is the upstream behaviour and the
	// default here.
	//
	// WHY: without it, concurrent connections are bounded only by the operating
	// system's file-descriptor limit, and reaching that limit is not a graceful
	// degradation — it is an `accept` failing for reasons the server did not
	// choose, at a moment it did not choose, with whatever consequence the rest
	// of the process happens to have.
	//
	// A REFUSAL IS THE POINT. A server that refuses a connection is degraded and
	// honest; one that accepts everything until the kernel stops it is a server
	// whose failure mode is an accident.
	max_connections:         int,
	// URUQUIM PATCH 8 (WP47) — the stop reservation.
	//
	// How many connection slots are held back from ADMISSION so that a drain
	// always has room to work in. Admission is refused at or below
	// `max_connections - reserved_connections`, never at zero.
	//
	// This is WP40's reservation rule, and the rule exists because **the fatal
	// failure is not running out of capacity — it is running out and having none
	// left to shut down with.**
	reserved_connections:    int,
	// URUQUIM PATCH 11 (WP59) — BRIDGE. The absolute drain deadline.
	//
	// How long a graceful shutdown may take, measured from the moment
	// `server_shutdown` is observed. Zero means unbounded, which is the upstream
	// behaviour and the default here.
	//
	// WHY IT IS ABSOLUTE. Phase 4 withdrew an earlier attempt because bounding
	// the drain LOOP left `nbio.run()` waiting behind it — a deadline that
	// bounds one of three waits is a deadline that does not bound shutdown. This
	// one covers all three: the loop ticks at `SHUTDOWN_INTERVAL` instead of
	// blocking, `.Active` connections are force-closed once it expires, and the
	// final drain runs under `run_until` rather than `run`.
	//
	// WHAT IT DOES NOT BOUND, and operations.md says so in these words: a
	// handler that blocks. A synchronous Handler cannot be preempted; its lane
	// cannot finish teardown until it returns. Other lanes may still enforce
	// their deadline. The supervisor's kill is still the outer bound.
	max_drain_time:          time.Duration,
	// URUQUIM PATCH 6 (WP46 / ADR-031) — the request read deadline.
	//
	// How long ONE request may take to arrive, from its first byte to its last.
	// Zero disables it, which is the upstream behaviour and the default here, so
	// this field changes nothing for a caller that does not set it.
	//
	// WHY THIS EXISTS: the upstream read has no deadline at all — `scanner.odin`
	// carries a `TODO: some kinda timeout on this` at the recv site — so a client
	// that opens a connection and sends one byte a minute, or sends a valid
	// prefix and stops, holds the connection open indefinitely. Uruquim's WP41
	// fault laboratory demonstrated both against this server before this patch
	// existed. It is slowloris: one socket, no bandwidth, held forever.
	//
	// WHY A SWEEP AND NOT A TIMER PER CONNECTION: a per-connection timer must be
	// cancelled when the request completes, and a timer that outlives what it
	// was guarding is a use-after-free waiting for a slot to be reused. One
	// periodic sweep per thread has no cancellation problem, no per-connection
	// allocation, and no timer-capacity question — at the cost of granularity,
	// which for a defence measured in seconds is not a cost.
	request_read_timeout:    time.Duration,
	// URUQUIM PATCH 19 (WP90 / ADR-039) — the response write deadline.
	//
	// How long ONE response send may take, from the moment the completed
	// response is handed to the event loop until the backend reports it sent.
	// Zero disables it, the upstream behaviour and the default.
	//
	// WHY THIS EXISTS: a client that stops reading (or reads one byte a
	// minute) parks the response in the send path indefinitely; the connection
	// and its buffers are held for as long as the CLIENT chooses. The same
	// slowloris shape as the read side, pointed at the write side.
	//
	// ENFORCED BY THE SAME SWEEP as the read deadline. A connection past this
	// deadline is ABORTED — closed with SO_LINGER zero so the kernel discards
	// the undelivered tail and sends RST. A graceful close would flush kernel
	// buffers to the slow reader first, making the close invisible for however
	// long megabytes take at the client's chosen pace — the deadline would
	// bound nothing observable. (This is why the Phase-6.5 attempt read as
	// "does not fire": its test watched for EOF that the kernel's buffered
	// bytes delayed past the test window.)
	response_write_timeout:  time.Duration,
	// URUQUIM PATCH 20 (WP90 / ADR-039) — the idle keep-alive timeout.
	//
	// How long a connection may sit BETWEEN requests before the server closes
	// it. Zero disables it (upstream behaviour, default). Distinct from the
	// read deadline: `request_started` is stamped when the server begins
	// waiting for a request, while `idle_since` is cleared the moment request
	// bytes actually arrive — so this bounds only the quiet gap, and closing
	// an idle connection is a normal keep-alive economy measure, not an error.
	idle_timeout:            time.Duration,
	// The thread count to use, defaults to your core count - 1.
	thread_count:            int,

	// // The initial size of the temp_allocator for each connection, defaults to 256KiB and doubles
	// // each time it needs to grow.
	// // NOTE: this value is assigned globally, running multiple servers with a different value will
	// // not work.
	// initial_temp_block_cap:  uint,
	// // The amount of free blocks each thread is allowed to hold on to before deallocating excess.
	// // Defaults to 64.
	// max_free_blocks_queued:  uint,
}

Default_Server_Opts := Server_Opts {
	auto_expect_continue    = true,
	redirect_head_to_get    = true,
	limit_request_line      = 8000,
	limit_headers           = 8000,
	// initial_temp_block_cap  = 256 * mem.Kilobyte,
	// max_free_blocks_queued  = 64,
}

Server_State :: enum {
	Uninitialized,
	Idle,
	Listening,
	Serving,
	Running,
	Closing,
	Cleaning,
	Closed,
}

Server :: struct {
	opts:           Server_Opts,
	tcp_sock:       net.TCP_Socket,
	conn_allocator: mem.Allocator,
	handler:        Handler,

	threads:        []Server_Thread,
	// Dedicated ingress state.  Only the serve thread touches accept/pending;
	// handler lanes merely publish availability and wake this loop.
	accept_loop:     ^nbio.Event_Loop,
	accept:          ^nbio.Operation,
	pending_accept:  Accepted_Connection,
	pending_waiting: bool,
	next_lane:       int,
	accept_failures: int,
	refused_connections: int,
	lanes_ready:     sync.Wait_Group,
	// URUQUIM PATCH 8 (WP47, amended by WP71) — the admission budget is
	// server-wide. A lane-local `len(td.conns)` multiplied the public limit by
	// the number of Handler lanes once concurrent serving shipped.
	active_connections: int,
	// URUQUIM PATCH 12 (WP70) — BRIDGE. Connections refused for admission since
	// this server started. Written by every lane and read by the adapter, so the
	// total is atomic; the lane-local transition counter below needs no sharing.
	refused_total:  int,
	// URUQUIM PATCH 28 (Closure H-3) — BRIDGE. The write-side counters behind
	// `web.Server_Stats`. Server-wide, written by every lane through
	// `sync.atomic_add` and read by the adapter without a request in hand — the
	// same discipline as `refused_total`. Each is a running total for the life of
	// the server (WP50's counter shape: a scraper differences it), carries no
	// request-derived byte, and exists because an operator cannot size or trust a
	// deployment whose only visible number is refused connections. Deletable with
	// the vendored backend when `core:net/http` lands.
	responses_sent:       int, // buffered responses whose send completed without error
	response_bytes:       i64, // bytes handed to the socket for those responses
	send_errors:          int, // buffered-response sends that completed with an error
	write_deadline_aborts:int, // connections aborted by the sweep's write-deadline branch
	// URUQUIM PATCH 31 (item 2 — lane-collision observability) — BRIDGE. How many
	// requests were refused with 503 because their lane was already running a
	// synchronous Handler (`handler_lane_enter` returned false). This is the ONLY
	// visible signal of the framework's first saturation point: C-05 measured that
	// the Handler lane binds first (capacity is `lanes ÷ dwell`), and a 503 on
	// collision can arrive with OTHER lanes idle, so it is invisible in latency and
	// in `refused_total` (which counts connection admission, a different resource).
	// Written by the adapter at the collision site, read without a request in hand —
	// same atomic discipline as the counters above. Deletable with the backend.
	lane_collisions:      int,
	// Once the server starts closing/shutdown this is set to true, all threads will check it
	// and start their thread local shutdown procedure.
	//
	// URUQUIM PATCH 12 (WP70) — BRIDGE. The false-to-true transition also elects
	// the single shutdown owner; repeated callers return before touching lanes.
	closing:        Atomic(bool),
	// URUQUIM PATCH 30 (Closure H-2 follow-up / F-C03-2) — set by a lane that
	// could not acquire its io_uring event loop, so `serve` returns an error
	// instead of the process terminating. See `_server_thread_init`.
	init_failed:    Atomic(bool),
	// Threads will decrement the wait group when they have fully closed/shutdown.
	// The main thread waits on this to clean up global data and return.
	threads_closed: sync.Wait_Group,

	// Updated every second with an updated date, this speeds up the server considerably
	// because it would otherwise need to call time.now() and format the date on each response.
}

Server_Thread :: struct {
	thread:     ^thread.Thread,
	event_loop: ^nbio.Event_Loop,
	conns:      map[net.TCP_Socket]^Connection,
	state:      Server_State,
	// URUQUIM PATCH 12 (WP70) — BRIDGE. Each lane owns the Date buffer it writes
	// and reads; sharing the server-level buffer was a cross-thread data race.
	date:       Server_Date,
	accept:     ^nbio.Operation,
	// URUQUIM PATCH 13 (WP71) — BRIDGE. Synchronous Handler execution owns one
	// lane; its accept stays suspended until application code returns.
	handler_active: bool,
	assigned_connections: int,
	queued_handoffs:      int,

	// URUQUIM PATCH 8 (WP47) — refusals since admission was last available.
	//
	// COUNTED, not logged per event, and the transition is what gets logged:
	// once on entering the exhausted state and once on leaving it. Ten thousand
	// refused connections must not produce ten thousand log lines — that turns
	// a load spike into an I/O storm, which is a denial of service the server
	// performs on itself (WP40 §2.5).
	refused_connections: int,

	// URUQUIM PATCH 21 (WP90 / F9) — consecutive accept failures on this
	// lane. Reset by every successful accept; reaching
	// `URUQUIM_ACCEPT_FAILURE_LIMIT` is still fatal, so a permanently dead
	// listener cannot become a silent outage.
	accept_failures: int,

	// free_temp_blocks:       map[int]queue.Queue(^Block),
	// free_temp_blocks_count: int,
}

@(private)
Accepted_Connection :: struct {
	server:   ^Server,
	socket:   net.TCP_Socket,
	endpoint: net.Endpoint,
	valid:    bool,
}

// URUQUIM PATCH 21 (WP90 / F9) — accept-error tolerance bounds.
@(private)
URUQUIM_ACCEPT_FAILURE_LIMIT :: 128
@(private)
URUQUIM_ACCEPT_RETRY_DELAY :: 10 * time.Millisecond
// A handoff is a `next_tick` callback on the destination lane. A hostile
// connect/RST loop can otherwise enqueue callbacks faster than a lane can
// observe that their sockets are already dead. Established keep-alive
// connections do not consume this bounded queue.
@(private)
URUQUIM_ACCEPT_HANDOFF_LIMIT :: 8

@(private, disabled = ODIN_DISABLE_ASSERT)
assert_has_td :: #force_inline proc(loc := #caller_location) {
	assert(td.state != .Uninitialized, "The thread you are calling from is not a server/handler thread", loc)
}

@(thread_local)
td: ^Server_Thread

Default_Endpoint := net.Endpoint {
	address = net.IP4_Any,
	port    = 8080,
}

listen :: proc(
	s: ^Server,
	endpoint: net.Endpoint = Default_Endpoint,
	opts: Server_Opts = Default_Server_Opts,
) -> (err: net.Network_Error) {
	s.opts = opts
	s.conn_allocator = context.allocator
	// initial_block_cap = int(s.opts.initial_temp_block_cap)
	// max_free_blocks_queued = int(s.opts.max_free_blocks_queued)

	acquire_err := nbio.acquire_thread_event_loop()
	// URUQUIM PATCH 29+30 (Closure H-2 / F-C03-2) — HANDLE the acquire failure
	// gracefully; do not assert on it.
	//
	// WHAT THIS IS. `acquire_thread_event_loop` sets up the thread's `io_uring`
	// rings, which PIN memory against `RLIMIT_MEMLOCK`. On the pinned `nbio` the
	// failure is sticky per thread (`_tls_event_loop.err`), and upstream's
	// `assert(err == nil)` — the "TODO: error handling" it never did — turned a
	// resource failure into a bare assertion the test runner surfaced as a
	// `Segmentation_Fault` at server startup. That is F-C03-2, reproduced under
	// ASan on a host with `ulimit -l` = 8 MiB.
	//
	// PATCH 29 named the cause; PATCH 30 UNWINDS it: `listen` now returns a
	// `net.Listen_Error` (the adapter maps any listen error to a clean
	// `web.serve` failure a supervisor restarts), and logs the actionable
	// remedy. The process no longer terminates on a resource shortfall at
	// startup — the outcome an operator can handle instead of a crash.
	if acquire_err != nil {
		log.errorf(
			"uruquim: could not acquire the io_uring event loop (%v). This is typically RLIMIT_MEMLOCK (ulimit -l) or memory exhaustion — one event loop is set up per Handler lane per server, so raise the locked-memory limit, lower max_handlers, or run fewer concurrent servers. (F-C03-2)",
			acquire_err,
		)
		// Not enough space in internal tables/buffers to create a socket's
		// event loop — the semantic Odin's own listen path uses for this class.
		return net.Listen_Error.Insufficient_Resources
	}

	s.tcp_sock, err = nbio.listen_tcp(endpoint)
	if err != nil {
		nbio.run()
		nbio.release_thread_event_loop()
		server_shutdown(s)
	}
	return
}

serve :: proc(s: ^Server, h: Handler) -> (err: net.Network_Error) {
	if atomic_load(&s.closing) { return }
	s.handler = h

	if s.opts.thread_count == 0 {
		s.opts.thread_count = os.get_processor_core_count()
	}

	thread_count := max(1, s.opts.thread_count)
	sync.wait_group_add(&s.threads_closed, thread_count)
	s.threads = make([]Server_Thread, thread_count, s.conn_allocator)
	when URUQUIM_DEDICATED_ACCEPT {
		sync.wait_group_add(&s.lanes_ready, thread_count)
		for &lane in s.threads {
			lane.thread = thread.create_and_start_with_poly_data2(s, &lane, _server_thread_init, context)
		}
		sync.wait(&s.lanes_ready)
		if !atomic_load(&s.init_failed) {
			_server_accept_loop(s)
		} else {
			// `listen` acquired the caller's event loop for the acceptor.  No
			// accept loop will run after a lane-init failure, so release it here.
			nbio.release_thread_event_loop()
		}
		sync.wait(&s.threads_closed)
	} else {
		for &lane in s.threads[1:] {
			lane.thread = thread.create_and_start_with_poly_data2(s, &lane, _server_thread_init, context)
		}
		_server_thread_init(s, &s.threads[0])
		sync.wait(&s.threads_closed)
	}

	log.debug("server threads are done, shutting down")

	net.shutdown(s.tcp_sock, .Both)
	net.close(s.tcp_sock)
	when URUQUIM_DEDICATED_ACCEPT {
		for t in s.threads { thread.destroy(t.thread) }
	} else {
		for t in s.threads[1:] { thread.destroy(t.thread) }
	}
	delete(s.threads)

	// URUQUIM PATCH 30 (Closure H-2 follow-up / F-C03-2) — a lane that could not
	// acquire its event loop unwound cleanly and flagged this; report it so
	// `web.serve` fails with a supervisor-restartable error instead of the
	// process having terminated.
	if atomic_load(&s.init_failed) {
		return net.Listen_Error.Insufficient_Resources
	}

	return nil
}

listen_and_serve :: proc(
	s: ^Server,
	h: Handler,
	endpoint: net.Endpoint = Default_Endpoint,
	opts: Server_Opts = Default_Server_Opts,
) -> (err: net.Network_Error) {
	listen(s, endpoint, opts) or_return
	return serve(s, h)
}

_server_thread_init :: proc(s: ^Server, ttd: ^Server_Thread) {
	td = ttd

	td.conns = make(map[net.TCP_Socket]^Connection)
	// td.free_temp_blocks = make(map[int]queue.Queue(^Block))

	when URUQUIM_DEDICATED_ACCEPT {
		err := nbio.acquire_thread_event_loop()
		if err != nil {
			log.errorf(
				"uruquim: a Handler lane could not acquire its io_uring event loop (%v). This is typically RLIMIT_MEMLOCK (ulimit -l) or memory exhaustion — raise the locked-memory limit or lower max_handlers. (F-C03-2)",
				err,
			)
			atomic_store(&s.init_failed, true)
			server_shutdown(s)
			delete(td.conns)
			td.state = .Closed
			sync.wait_group_done(&s.lanes_ready)
			sync.wait_group_done(&s.threads_closed)
			return
		}
	} else {
		if td != &s.threads[0] {
			err := nbio.acquire_thread_event_loop()
		// URUQUIM PATCH 29+30 (Closure H-2 / F-C03-2) — the lane-thread twin of
		// the graceful acquire handling in `listen`; same cause
		// (RLIMIT_MEMLOCK / memory). Instead of asserting, this lane UNWINDS: it
		// flags the failure so `serve` returns an error, elects the shutdown so
		// the already-running lanes exit (the wake loop is nil-safe, so peers
		// still racing through init are handled), releases what this init
		// allocated, signals the wait group, and returns WITHOUT ever touching a
		// loop it does not have.
			if err != nil {
			log.errorf(
				"uruquim: a Handler lane could not acquire its io_uring event loop (%v). This is typically RLIMIT_MEMLOCK (ulimit -l) or memory exhaustion — raise the locked-memory limit or lower max_handlers. (F-C03-2)",
				err,
			)
			atomic_store(&s.init_failed, true)
			server_shutdown(s)
			delete(td.conns)
			td.state = .Closed
			sync.wait_group_done(&s.threads_closed)
				return
			}
		}
	}

	td.event_loop = nbio.current_thread_event_loop()

	// WP70: the cached Date buffer is lane-owned. A shared buffer was written
	// once per second by lane zero while every other lane read it, which is a
	// data race even though the bytes usually looked harmless.
	server_date_start(s)

	when URUQUIM_DEDICATED_ACCEPT {
		sync.wait_group_done(&s.lanes_ready)
	} else {
		log.debug("accepting connections")
		td.accept = nbio.accept_poly(s.tcp_sock, s, on_accept)
	}

	log.debug("starting event loop")
	td.state = .Serving
	for {
		if atomic_load(&s.closing) { _server_thread_shutdown(s) }
		if td.state == .Closed { break }
		if td.state == .Cleaning { continue }

		err := nbio.tick()
		if err != nil {
			log.errorf("non-blocking io tick error: %v", err)
			break
		}
	}

	log.debug("event loop end")

	when URUQUIM_DEDICATED_ACCEPT {
		runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	} else {
		if td != &s.threads[0] {
			runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
		}
	}
	sync.wait_group_done(&s.threads_closed)
}


// The time between checks and closes of connections in a graceful shutdown.
@(private)
SHUTDOWN_INTERVAL :: time.Millisecond * 100

// Starts a graceful shutdown.
//
// Some error logs will be generated but all active connections are finished
// before closing them and all connections and threads are freed.
//
// 1. Stops 'server_start' from accepting new connections.
// 2. Close and free non-active connections.
// 3. Repeat 2 every SHUTDOWN_INTERVAL until no more connections are open.
// 4. Close the main socket.
// 5. Signal 'server_start' it can return.
server_shutdown :: proc(s: ^Server) {
	// URUQUIM PATCH 12 (WP70) — BRIDGE. Exactly one caller owns wake-up.
	// Repeated stop calls used to walk
	// `s.threads` while the first drain was freeing it, which is the WP69
	// multi-lane shutdown crash.
	previous, changed := sync.atomic_compare_exchange_strong(&s.closing.raw, false, true)
	_ = previous
	if !changed {
		return
	}
	when URUQUIM_DEDICATED_ACCEPT {
		accept_loop := sync.atomic_load_explicit(&s.accept_loop, .Acquire)
		if accept_loop != nil {
			nbio.wake_up(accept_loop)
		}
	}
	for t in s.threads {
		// URUQUIM PATCH 30 (Closure H-2 follow-up) — a lane that has not yet
		// reached `td.event_loop = current_thread_event_loop()` (still
		// initializing, or one that FAILED to acquire and returned) has a nil
		// loop; waking nil crashes. Skip it: an uninitialized lane will observe
		// `closing` when it reaches its own loop, and a failed lane is already
		// gone. This makes `server_shutdown` safe to call from a lane whose peers
		// are still racing through init — which the init-failure unwind does.
		if t.event_loop != nil {
			nbio.wake_up(t.event_loop)
		}
	}
}

_server_thread_shutdown :: proc(s: ^Server, loc := #caller_location) {
	assert_has_td(loc)

	td.state = .Closing
	defer delete(td.conns)
	// defer {
	// 	blocks: int
	// 	for _, &bucket in td.free_temp_blocks {
	// 		for block in queue.pop_front_safe(&bucket) {
	// 			blocks += 1
	// 			free(block)
	// 		}
	// 		queue.destroy(&bucket)
	// 	}
	// 	delete(td.free_temp_blocks)
	// 	log.infof("had %i temp blocks to spare", blocks)
	// }

	// URUQUIM PATCH 11 (WP59) — BRIDGE. The absolute drain deadline.
	//
	// WP58 measured what this replaces: with eight idle keep-alive connections
	// the drain did not end at all, and releasing the clients' sockets crashed
	// the process instead. Both failures are below, and both are addressed here.
	//
	// THE DEADLINE COVERS THREE WAITS, because bounding one of them is what
	// failed in Phase 4:
	//
	//   1. `nbio.tick()` blocked with no timeout, so the loop could not
	//      re-evaluate anything between events. It now ticks at
	//      `SHUTDOWN_INTERVAL` — the constant defined at the top of this file
	//      that upstream never used, and that its own comment above
	//      `server_shutdown` promised.
	//   2. `.Active` connections were only LOGGED, so `td.conns` never emptied
	//      while a client held one. Past the deadline they are force-closed.
	//   3. `nbio.run()` waited for every outstanding operation. It is now
	//      `run_until`, released by a timeout armed on the same deadline.
	//
	// Zero keeps the upstream behaviour exactly: no deadline, no forced close.
	drain_bounded := s.opts.max_drain_time > 0
	drain_expires := time.time_add(time.now(), s.opts.max_drain_time)
	drain_expired := false

	for {
		past_deadline := drain_bounded && time.since(drain_expires) >= 0

		for sock, conn in td.conns {
			#partial switch conn.state {
			// URUQUIM PATCH 26 (Closure C-03 / F-C03-1) — `.Will_Close` BELONGS
			// HERE, and its absence made `max_drain_time` bound nothing.
			//
			// THE DEFECT. This `#partial switch` named six of the seven
			// `Connection_State` members. The one it omitted, `.Will_Close`, is
			// the state a connection enters the moment the server decides to
			// retire it after the current response — which `response_must_close`
			// does for every request carrying `Connection: close`, for every
			// HTTP/1.0 request, and after a failed body read. An omitted case in
			// a `#partial switch` is silence, not a compile error: such a
			// connection was neither closed nor logged, it simply stayed in
			// `td.conns`. `len(td.conns)` therefore never reached zero and the
			// loop below never broke — FOREVER, past every deadline, because the
			// force-close was reachable only through the `.Active` arm.
			//
			// MEASURED (C-03 cell D8, and it is a one-line reproduction): one
			// client sends `GET /big HTTP/1.1` with `Connection: close`, does not
			// read the 8 MiB response, and `web.stop` never returns — 8 s, 10 s,
			// any bound the test cared to wait. Remove the `Connection: close`
			// header and the identical scenario shuts down in 1.1 s. The write
			// deadline was irrelevant (it fails with the deadline off too) and so
			// was the drain deadline's value (500 ms and 2 s fail alike).
			//
			// WHY IT MATTERS MORE THAN IT LOOKS. `max_drain_time` is documented
			// as the ABSOLUTE bound on shutdown — the comment forty lines above
			// says it covers all three waits, and `docs/operations.md` tells
			// operators to keep it inside their supervisor's `TimeoutStopSec`.
			// This made that promise false for the most ordinary client there
			// is: `curl` on a large download interrupted at the terminal sends
			// exactly this shape. The only remaining exit was the supervisor's
			// SIGKILL, which is the failure mode a drain deadline exists to
			// prevent.
			//
			// `.Will_Close` is treated exactly as `.Active` because it IS an
			// in-flight response: allowed to finish before the deadline, force-
			// closed after it. That is the same trade the `.Active` arm makes.
			case .Active, .Will_Close:
				// PAST THE DEADLINE, "still active" stops being a reason to
				// wait. Before it, this is upstream's behaviour unchanged: an
				// in-flight request is allowed to finish, which is the whole
				// point of a graceful shutdown.
				if past_deadline {
					log.infof("shutdown: deadline expired, closing active connection %i", sock)
					connection_close(conn)
				} else {
					log.infof("shutdown: connection %i still active", sock)
				}
			case .New, .Idle, .Pending:
				log.infof("shutdown: closing connection %i", sock)
				connection_close(conn)
			case .Closing:
				log.debugf("shutdown: connection %i is closing", sock)
			case .Closed:
				log.warn("closed connection in connections map, maybe a race or logic error")
			}
		}

		if len(td.conns) == 0 {
			break
		}

		// A BOUNDED TICK IS WHAT MAKES THE DEADLINE REACHABLE. With
		// `nbio.tick()` the loop parks until an event arrives, and a client that
		// sends nothing produces no events — so the deadline above would only be
		// evaluated when the thing it exists to interrupt happened to stop.
		err := nbio.tick(SHUTDOWN_INTERVAL if drain_bounded else nbio.NO_TIMEOUT)
		fmt.assertf(err == nil, "IO tick error during shutdown: %v")
	}

	td.state = .Cleaning

	when !URUQUIM_DEDICATED_ACCEPT {
		nbio.remove(td.accept)
		td.accept = nil
	}

	// The final drain. Every connection is closed by here, but their close
	// timeouts and `close` operations are still outstanding, and PATCH 10 has
	// cancelled the `recv` that used to outlive them.
	//
	// A BOUNDED TICK LOOP rather than `run` or `run_until`, and the first attempt
	// at this is worth recording because it looked right and was not.
	//
	// `run_until(&flag)` with a timeout operation arming the flag is the obvious
	// shape. It is wrong here: `run_until` loops while `num_waiting() > 0`, and
	// the arming timeout is ITSELF an outstanding operation. A shutdown with no
	// connections at all then waited the full deadline instead of returning
	// immediately — the deadline became a floor rather than a ceiling. Measured,
	// not reasoned: WP58's baseline phase went from 990 ms to the full bound.
	//
	// Ticking directly has neither problem. The loop ends when the work is done,
	// or when the deadline expires, whichever comes first — which is what an
	// absolute deadline is supposed to mean.
	for nbio.num_waiting() > 0 {
		if drain_bounded && time.since(drain_expires) >= 0 {
			drain_expired = true
			log.warn("shutdown: drain deadline expired with operations outstanding")
			break
		}
		err := nbio.tick(SHUTDOWN_INTERVAL if drain_bounded else nbio.NO_TIMEOUT)
		fmt.assertf(err == nil, "IO tick error during shutdown drain: %v")
	}
	_ = drain_expired
	nbio.release_thread_event_loop()

	td.state = .Closed

	log.info("shutdown: done")
}

@(private)
on_interrupt_server: ^Server
@(private)
on_interrupt_context: runtime.Context

// Registers a signal handler to shutdown the server gracefully on interrupt signal.
// Can only be called once in the lifetime of the program because of a hacky interaction with libc.
server_shutdown_on_interrupt :: proc(s: ^Server) {
	on_interrupt_server = s
	on_interrupt_context = context

	libc.signal(
		libc.SIGINT,
		proc "cdecl" (_: i32) {
			context = on_interrupt_context

			// Force close on second signal.
			if td.state == .Closing {
				os.exit(1)
			}

			server_shutdown(on_interrupt_server)
		},
	)
}

// Taken from Go's implementation,
// The maximum amount of bytes we will read (if handler did not)
// in order to get the connection ready for the next request.
@(private)
Max_Post_Handler_Discard_Bytes :: 256 << 10

// How long to wait before actually closing a connection.
// This is to make sure the client can fully receive the response.
@(private)
Conn_Close_Delay :: time.Millisecond * 500

Connection_State :: enum {
	Pending, // Pending a client to attach.
	New, // Got client, waiting to service first request.
	Active, // Servicing request.
	Idle, // Waiting for next request.
	Will_Close, // Closing after the current response is sent.
	Closing, // Going to close, cleaning up.
	Closed, // Fully closed.
}

@(private)
connection_set_state :: proc(c: ^Connection, s: Connection_State) -> bool {
	if s < .Closing && c.state >= .Closing {
		return false
	}

	if s == .Closing && c.state == .Closed {
		return false
	}

	c.state = s
	return true
}

// TODO/PERF: pool the connections, saves having to allocate scanner buf and temp_allocator every time.
Connection :: struct {
	server:         ^Server,
	socket:         net.TCP_Socket,
	state:          Connection_State,
	scanner:        Scanner,
	temp_allocator: virtual.Arena,
	loop:           Loop,
	// URUQUIM PATCH 6 (WP46) — when the current request began arriving, or the
	// zero value between requests.
	//
	// A REQUEST deadline rather than an idle timeout, and the difference is the
	// whole defence: an idle timer is reset by every byte, so a client trickling
	// one byte every second resets it forever. This is stamped once when a
	// request starts and never refreshed, so total time to send a request is
	// what is bounded.
	request_started: time.Time,
	// URUQUIM PATCH 19 (WP90 / ADR-039) — when the current response send was
	// handed to the event loop, or the zero value when no send is in flight.
	// Stamped in `response_send_got_body`, cleared in `on_response_sent` and
	// `clean_request_loop`; the sweep's write branch reads it.
	send_started:    time.Time,
	// URUQUIM PATCH 19 — the outstanding send operation, so closing a
	// connection mid-send can cancel it. The write-side twin of Patch 10's
	// `scanner.pending_recv`: without the cancel, teardown frees the
	// connection while the send completion still points at it.
	pending_send:    ^nbio.Operation,
	// URUQUIM PATCH 19 (WP92 amendment) — a per-connection write deadline
	// that takes precedence over the server-wide one. A DETACHED STREAM must
	// be safe without tuning (phase-7-spec.md §4.1): when the application
	// left `max_write_time` at 0, a stream connection still gets the
	// pre-registered 30 s default, because a client that never reads is the
	// slow-consumer terminal case and "off by default" for buffered
	// responses must not mean "unbounded" for infinite ones.
	write_deadline_override: time.Duration,
	// URUQUIM PATCH 22 (WP92 amendment) — an owner notification fired by
	// `connection_teardown` BEFORE the Connection is freed. The detached-
	// stream adapter installs it so an EXTERNALLY-initiated end — the
	// deadline sweep's abort, a shutdown force-close, a scanner error —
	// releases the stream's registry slot and stops its pump from ever
	// touching the freed Connection. Runs on the owner lane, once.
	on_teardown:      proc(user: rawptr),
	on_teardown_user: rawptr,
	// URUQUIM PATCH 20 (WP90 / ADR-039) — when this connection last became
	// idle between requests, or the zero value while a request or response is
	// in flight. Stamped in `clean_request_loop` on the keep-alive path,
	// cleared when the next request's bytes arrive (`on_rline1`).
	idle_since:      time.Time,
	// URUQUIM PATCH 25 (Closure C-03) — the peer has already gone: the last
	// `recv` reported an orderly FIN (`received == 0`) or a reset
	// (`Connection_Closed`). Set by `scanner_on_read`, read by
	// `connection_close` to skip a politeness delay owed to nobody. See the
	// note there for what it fixes and why it is safe.
	peer_gone:       bool,
}

// Loop/request cycle state.
@(private)
Loop :: struct {
	conn: ^Connection,
	req:  Request,
	res:  Response,
}

@(private)
connection_close :: proc(c: ^Connection, loc := #caller_location) {
	assert_has_td(loc)

	if c.state >= .Closing {
		log.infof("connection %i already closing/closed", c.socket)
		return
	}

	log.debugf("closing connection: %i", c.socket)

	c.state = .Closing

	// URUQUIM PATCH 25 (Closure C-03) — captured BEFORE the cancels below null
	// it, because whether a response was in flight decides how this connection
	// may end.
	had_send_in_flight := c.pending_send != nil

	// URUQUIM PATCH 10 (WP59) — BRIDGE. Cancel the outstanding `recv` before
	// anything below frees the connection it points at.
	//
	// This is a MEMORY-SAFETY fix that happens to also end the drain, and the
	// order matters in both directions:
	//
	//   - Without it, the callback at the bottom of this procedure frees `c`
	//     while the scanner's `recv` is still outstanding. When that `recv` later
	//     completes — which is exactly what a client disconnecting causes —
	//     `scanner_on_read` dereferences `s.connection` and the process dies.
	//     WP58 measured `free(): invalid pointer` doing precisely this.
	//   - Without it, the operation also stays in `num_waiting()`, and the
	//     `nbio.run()` that ends `_server_thread_shutdown` waits on it forever.
	//
	// `nbio.remove` is final and silent: the callback will never run. That is
	// the property this needs — the connection is going away and nothing should
	// be scheduled to touch it again.
	if c.scanner.pending_recv != nil {
		nbio.remove(c.scanner.pending_recv)
		c.scanner.pending_recv = nil
	}

	// URUQUIM PATCH 19 (WP90) — the write-side twin of the cancel above, and
	// the same memory-safety argument: the teardown callback below frees `c`,
	// and an outstanding send completion would then dereference it. WP59
	// measured that failure on the recv side; closing mid-send (which the
	// write deadline now does deliberately) reaches the send side.
	if c.pending_send != nil {
		nbio.remove(c.pending_send)
		c.pending_send = nil
	}

	// URUQUIM PATCH 25 (Closure C-03) — THE LINGER IS A COURTESY, AND A PEER
	// THAT IS ALREADY GONE IS OWED NONE.
	//
	// THE DEFECT IT FIXES. `docs/reports/2026-07-23-security-f001-f002.md`
	// recorded, as out of scope, that "under a SUSTAINED RST flood the server
	// stops accepting (all threads alive, listen backlog fills, no crash)".
	// C-03 reproduced it and the measurement named the mechanism, which is not
	// the accept path at all: a healthy client's `connect` kept succeeding
	// throughout (`connect_fail=0`), and what it met was the ADMISSION
	// REFUSAL — 1 probe served out of 59.
	//
	// The cause is here. `active_connections` is decremented in
	// `connection_teardown`, at the END of this chain, so a connection whose
	// peer has already sent RST still occupies one of
	// `max_connections - reserved_connections` slots for the whole
	// `Conn_Close_Delay`. At 500 ms a flood only has to open connections faster
	// than `budget / 500 ms` — 120/s against the lab's 60 slots — to make every
	// later client meet the refusal. The measured flood ran at ~39,900/s, which
	// is a 300-fold oversubscription of the budget by connections that are
	// waiting out a politeness delay owed to a peer that has gone.
	//
	// WHY SKIPPING IT IS SAFE, and the two conditions are both necessary:
	//
	//   * `peer_gone` means the last `recv` reported an orderly FIN or a reset.
	//     No further byte can arrive, and nothing this server writes can be
	//     read. RFC 7230 6.6's advice — close the read side, pause, then close
	//     — protects a client still draining a response; there is no such
	//     client here.
	//   * `!had_send_in_flight` keeps the courteous path for the case that
	//     actually needs it. If a response was outstanding when this close
	//     began, the connection ends the way it always did.
	//
	// Note that the delay was never what flushed the response: a plain `close`
	// (no SO_LINGER) returns at once and the kernel keeps sending what is
	// buffered. That is why this is a scheduling fix and not a wire change —
	// and why it is deliberately NOT the `connection_abort` path, which sets
	// SO_LINGER {1,0} to DISCARD the tail. Nothing is discarded here.
	if c.peer_gone && !had_send_in_flight {
		nbio.close_poly(c.socket, c, connection_teardown)
		return
	}

	// RFC 7230 6.6.

	// Close read side of the connection, then wait a little bit, allowing the client
	// to process the closing and receive any remaining data.
	net.shutdown(c.socket, net.Shutdown_Manner.Send)

	nbio.timeout_poly(Conn_Close_Delay, c, proc(_: ^nbio.Operation, c: ^Connection) {
		nbio.close_poly(c.socket, c, connection_teardown)
	})
}

// URUQUIM PATCH 19 (WP90) — the final teardown, shared by the graceful close
// above and the deadline abort below so there is exactly one free path.
@(private)
connection_teardown :: proc(_: ^nbio.Operation, c: ^Connection) {
	log.debugf("closed connection: %i", c.socket)

	// URUQUIM PATCH 22 (WP92 amendment) — the owner hears about the end
	// before the memory goes away, whoever initiated it.
	if c.on_teardown != nil {
		c.on_teardown(c.on_teardown_user)
		c.on_teardown = nil
	}

	c.state = .Closed

	// allocator_destroy(&c.temp_allocator)
	virtual.arena_destroy(&c.temp_allocator)

	scanner_destroy(&c.scanner)
	delete_key(&td.conns, c.socket)
	when URUQUIM_DEDICATED_ACCEPT {
		_ = sync.atomic_add(&td.assigned_connections, -1)
	}
	_ = sync.atomic_add(&c.server.active_connections, -1)
	free(c, c.server.conn_allocator)
}

// URUQUIM PATCH 19 (WP90 / ADR-039) — abort a connection whose response send
// exceeded its deadline.
//
// DIFFERENT FROM `connection_close` ON PURPOSE: the graceful path does
// `shutdown(Send)` and a delayed `close`, which FLUSHES kernel-buffered bytes
// to the client first — correct for an orderly end, and exactly wrong for a
// write deadline, where megabytes of buffered response would keep trickling
// to the slow reader at the client's own pace, making the "close" invisible
// for minutes. SO_LINGER {on, 0} makes `close` discard the unsent tail and
// send RST: the deadline is observable the moment it fires, on both sides.
@(private)
connection_abort :: proc(c: ^Connection, loc := #caller_location) {
	assert_has_td(loc)

	if c.state >= .Closing {
		return
	}
	c.state = .Closing

	// Both outstanding operations are cancelled before anything can free `c`
	// — the Patch 10/19 memory-safety rule.
	if c.scanner.pending_recv != nil {
		nbio.remove(c.scanner.pending_recv)
		c.scanner.pending_recv = nil
	}
	if c.pending_send != nil {
		nbio.remove(c.pending_send)
		c.pending_send = nil
	}

	// struct linger { l_onoff = 1, l_linger = 0 } → close() sends RST and
	// discards the send buffer. Raw setsockopt because the pinned
	// `core:net` `.Linger` marshals the wrong struct (a timeval).
	Linger_Value :: struct {
		l_onoff:  i32,
		l_linger: i32,
	}
	lv := Linger_Value{1, 0}
	// SOL_SOCKET = 1, SO_LINGER = 13 on Linux, the only gate-validated
	// platform (production-service-bom.md §6).
	_ = linux.setsockopt_base(linux.Fd(i32(c.socket)), 1, 13, &lv)

	nbio.close_poly(c.socket, c, connection_teardown)
}

// --- Dedicated accept / connection-affinity ingress ------------------------

@(private)
accept_arm :: proc(s: ^Server) {
	if !atomic_load(&s.closing) && s.accept == nil && !s.pending_accept.valid {
		s.accept = nbio.accept_poly(s.tcp_sock, s, on_accept_dedicated)
	}
}

@(private)
accept_choose_lane :: proc(s: ^Server) -> ^Server_Thread {
	n := len(s.threads)
	if n == 0 {
		return nil
	}
	best: ^Server_Thread
	best_load := 0
	for offset in 0 ..< n {
		i := (s.next_lane + offset) % n
		lane := &s.threads[i]
		if lane.event_loop == nil ||
		   sync.atomic_load_explicit(&lane.handler_active, .Acquire) ||
		   sync.atomic_load(&lane.queued_handoffs) >= URUQUIM_ACCEPT_HANDOFF_LIMIT {
			continue
		}
		load := sync.atomic_load(&lane.assigned_connections)
		if best == nil || load < best_load {
			best = lane
			best_load = load
			if load == 0 {
				s.next_lane = (i + 1) % n
				break
			}
		}
	}
	if best != nil && best_load != 0 {
		for i in 0 ..< n {
			if best == &s.threads[i] {
				s.next_lane = (i + 1) % n
				break
			}
		}
	}
	return best
}

@(private)
accept_try_assign_pending :: proc(s: ^Server) -> bool {
	if !s.pending_accept.valid {
		return true
	}
	lane := accept_choose_lane(s)
	if lane == nil {
		sync.atomic_store_explicit(&s.pending_waiting, true, .Release)
		return false
	}
	item := new(Accepted_Connection, s.conn_allocator)
	item^ = s.pending_accept
	s.pending_accept = {}
	sync.atomic_store_explicit(&s.pending_waiting, false, .Release)
	_ = sync.atomic_add(&lane.assigned_connections, 1)
	_ = sync.atomic_add(&lane.queued_handoffs, 1)
	nbio.next_tick_poly(item, on_connection_assigned, lane.event_loop)
	return true
}

@(private)
accept_all_handlers_active :: proc(s: ^Server) -> bool {
	if len(s.threads) == 0 {
		return false
	}
	for &lane in s.threads {
		if !sync.atomic_load_explicit(&lane.handler_active, .Acquire) {
			return false
		}
	}
	return true
}

@(private)
ACCEPT_OVERLOAD_RESPONSE: string : (
	"HTTP/1.1 503 Service Unavailable\r\n" +
	"Content-Length: 0\r\n" +
	"Connection: close\r\n" +
	"Retry-After: 1\r\n\r\n"
)

// The dedicated acceptor cannot run the HTTP adapter when every application
// lane is blocked, but it can still make the existing saturation contract
// observable: a complete, bounded 503 response followed by close.  The
// explicit one-lane compatibility mode deliberately keeps its old wait.
@(private)
accept_refuse_handler_saturation :: proc(s: ^Server) {
	if !s.pending_accept.valid {
		return
	}
	sock := s.pending_accept.socket
	s.pending_accept = {}
	sync.atomic_store_explicit(&s.pending_waiting, false, .Release)
	sent := 0
	data := transmute([]u8)ACCEPT_OVERLOAD_RESPONSE
	for sent < len(data) {
		n, err := net.send_tcp(sock, data[sent:])
		if err != nil || n <= 0 {
			break
		}
		sent += n
	}
	net.close(sock)
	_ = sync.atomic_add(&s.active_connections, -1)
	_ = sync.atomic_add(&s.lane_collisions, 1)
}

@(private)
on_connection_assigned :: proc(_: ^nbio.Operation, item: ^Accepted_Connection) {
	server := item.server
	_ = sync.atomic_add(&td.queued_handoffs, -1)
	if sync.atomic_load_explicit(&server.pending_waiting, .Acquire) {
		accept_loop := sync.atomic_load_explicit(&server.accept_loop, .Acquire)
		if accept_loop != nil {
			nbio.wake_up(accept_loop)
		}
	}
	if atomic_load(&server.closing) {
		net.close(item.socket)
		_ = sync.atomic_add(&td.assigned_connections, -1)
		_ = sync.atomic_add(&server.active_connections, -1)
		free(item, server.conn_allocator)
		return
	}

	c := new(Connection, server.conn_allocator)
	c.state = .New
	c.server = server
	c.socket = item.socket
	c.loop.req.client = item.endpoint
	td.conns[c.socket] = c
	free(item, server.conn_allocator)
	conn_handle_reqs(c)
}

@(private)
on_accept_dedicated :: proc(op: ^nbio.Operation, s: ^Server) {
	s.accept = nil
	if op.accept.err != nil {
		#partial switch op.accept.err {
		case .Insufficient_Resources:
			nbio.timeout_poly(time.Second, s, proc(_: ^nbio.Operation, server: ^Server) {
				accept_arm(server)
			})
			return
		}
		s.accept_failures += 1
		if s.accept_failures >= URUQUIM_ACCEPT_FAILURE_LIMIT {
			fmt.panicf(
				"accept failing persistently (%d consecutive), last error: %v",
				s.accept_failures, op.accept.err,
			)
		}
		nbio.timeout_poly(URUQUIM_ACCEPT_RETRY_DELAY, s, proc(_: ^nbio.Operation, server: ^Server) {
			accept_arm(server)
		})
		return
	}
	s.accept_failures = 0

	active_connections := sync.atomic_add(&s.active_connections, 1) + 1
	if s.opts.max_connections > 0 {
		budget := max(1, s.opts.max_connections - s.opts.reserved_connections)
		if active_connections > budget {
			_ = sync.atomic_add(&s.active_connections, -1)
			s.refused_connections += 1
			_ = sync.atomic_add(&s.refused_total, 1)
			if s.refused_connections == 1 {
				log.warnf(
					"uruquim: admission limit reached (%i of %i slots, %i reserved for shutdown); refusing connections. This is logged ONCE per exhausted period, not per refusal.",
					active_connections - 1,
					s.opts.max_connections,
					s.opts.reserved_connections,
				)
			}
			net.close(op.accept.client)
			accept_arm(s)
			return
		}
		if s.refused_connections > 0 {
			log.infof(
				"uruquim: admission resumed after refusing %i connection(s)",
				s.refused_connections,
			)
			s.refused_connections = 0
		}
	}

	s.pending_accept = Accepted_Connection {
		server   = s,
		socket   = op.accept.client,
		endpoint = op.accept.client_endpoint,
		valid    = true,
	}
	if accept_try_assign_pending(s) {
		accept_arm(s)
	} else if len(s.threads) > 1 && accept_all_handlers_active(s) {
		accept_refuse_handler_saturation(s)
		accept_arm(s)
	}
}

@(private)
_server_accept_loop :: proc(s: ^Server) {
	sync.atomic_store_explicit(&s.accept_loop, nbio.current_thread_event_loop(), .Release)
	accept_arm(s)
	for !atomic_load(&s.closing) {
		if accept_try_assign_pending(s) {
			accept_arm(s)
		}
		err := nbio.tick()
		if err != nil {
			log.errorf("dedicated accept loop error: %v", err)
			server_shutdown(s)
			break
		}
	}
	if s.accept != nil {
		nbio.remove(s.accept)
		s.accept = nil
	}
	if s.pending_accept.valid {
		net.close(s.pending_accept.socket)
		_ = sync.atomic_add(&s.active_connections, -1)
		s.pending_accept = {}
		sync.atomic_store_explicit(&s.pending_waiting, false, .Release)
	}
	// Flush the cancelled accept/retry timers before releasing the loop.
	for nbio.num_waiting() > 0 {
		err := nbio.tick(SHUTDOWN_INTERVAL)
		if err != nil {
			break
		}
	}
	sync.atomic_store_explicit(&s.accept_loop, nil, .Release)
	nbio.release_thread_event_loop()
}

@(private)
on_accept :: proc(op: ^nbio.Operation, server: ^Server) {
	td.accept = nil

	if op.accept.err != nil {
		#partial switch op.accept.err {
		case .Insufficient_Resources:
			log.error("Connection limit reached, trying again in a bit")
			// URUQUIM PATCH 24 (C-01 / F-C01-1) — the same guard the transient
			// branch below carries, and for the same reason. `on_accept`
			// cleared `td.accept` on entry, so within this second the lane can
			// service a request it had already read and `handler_lane_leave`
			// arms a NEW accept. An unguarded re-arm here overwrites that
			// handle: the earlier operation becomes unreachable, survives
			// `nbio.remove(td.accept)` at shutdown, and keeps `num_waiting()`
			// above zero — the WP58/WP59 pending-`recv` hang, on the accept
			// path, reached exactly when fds are exhausted and an operator is
			// restarting the process.
			nbio.timeout_poly(time.Second, server, proc(_: ^nbio.Operation, server: ^Server) {
				if td.accept == nil && !td.handler_active {
					td.accept = nbio.accept_poly(server.tcp_sock, server, on_accept)
				}
			})
			return
		}

		// URUQUIM PATCH 21 (WP90 / F9) — a transient accept failure must not
		// kill the process. `ECONNABORTED` (peer gave up while queued),
		// `EINTR` and load-shed conditions are ordinary weather at accept;
		// upstream's panic turned each into an unauthenticated remote crash.
		// Tolerate by re-arming with a short delay; the failure counter makes
		// a PERSISTENTLY failing listener still fatal — a server that can
		// never accept again but keeps ticking would be a silent outage,
		// which is the dishonest failure mode (WP40 §2.5).
		td.accept_failures += 1
		if td.accept_failures >= URUQUIM_ACCEPT_FAILURE_LIMIT {
			fmt.panicf(
				"accept failing persistently (%d consecutive), last error: %v",
				td.accept_failures, op.accept.err,
			)
		}
		log.errorf("uruquim: transient accept error (%v); re-arming accept", op.accept.err)
		nbio.timeout_poly(URUQUIM_ACCEPT_RETRY_DELAY, server, proc(_: ^nbio.Operation, server: ^Server) {
			if td.accept == nil && !td.handler_active {
				td.accept = nbio.accept_poly(server.tcp_sock, server, on_accept)
			}
		})
		return
	}

	// URUQUIM PATCH 21 — a successful accept proves the listener works;
	// only CONSECUTIVE failures may accumulate toward the fatal limit.
	td.accept_failures = 0

	// Accept next connection unless this lane has entered synchronous
	// application code (Patch 13). A raced completion is installed without
	// opening another admission slot on the blocked lane.
	if !td.handler_active {
		td.accept = nbio.accept_poly(server.tcp_sock, server, on_accept)
	}

	// URUQUIM PATCH 8 (WP47) — BOUNDED ADMISSION, and the inequality is the
	// whole design.
	//
	// The budget compared against is `max_connections - reserved_connections`,
	// not `max_connections`: admission stops while there is still room, so a
	// drain always has slots to work in. Refusing only at zero would mean a
	// server that is full is a server that cannot shut down — which is the
	// failure WP40's reservation rule was written to prevent.
	//
	// The refusal CLOSES the accepted socket immediately rather than queueing
	// it. A queue would be a second, invisible limit with its own exhaustion
	// behaviour, and the client learns the same thing either way: this server
	// is not taking work. The count is not logged per event (WP40 §2.5): ten
	// thousand refusals must not become ten thousand log lines, which is a
	// denial of service the server would be performing on itself.
	active_connections := sync.atomic_add(&server.active_connections, 1) + 1
	if server.opts.max_connections > 0 {
		budget := server.opts.max_connections - server.opts.reserved_connections
		if budget < 1 {
			budget = 1
		}
		if active_connections > budget {
			_ = sync.atomic_add(&server.active_connections, -1)
			td.refused_connections += 1
			// WP50 §3.5 — the DROP POLICY IS OBSERVABLE. A component that can
			// discard work must count what it discarded, because a metric that
			// silently stops being emitted reads as "nothing happened".
			// URUQUIM PATCH 12 (WP70) — BRIDGE. Every lane contributes.
			_ = sync.atomic_add(&server.refused_total, 1)
			if td.refused_connections == 1 {
				log.warnf(
					"uruquim: admission limit reached (%i of %i slots, %i reserved for shutdown); refusing connections. This is logged ONCE per exhausted period, not per refusal.",
					active_connections - 1,
					server.opts.max_connections,
					server.opts.reserved_connections,
				)
			}
			net.close(op.accept.client)
			return
		}
		if td.refused_connections > 0 {
			log.infof(
				"uruquim: admission resumed after refusing %i connection(s)",
				td.refused_connections,
			)
			td.refused_connections = 0
		}
	}

	c := new(Connection, server.conn_allocator)
	c.state = .New
	c.server = server
	c.socket = op.accept.client
	c.loop.req.client = op.accept.client_endpoint

	td.conns[c.socket] = c

	log.debugf("new connection with thread, got %d conns", len(td.conns))
	conn_handle_reqs(c)
}

// URUQUIM PATCH 13 (WP71) — BRIDGE. Keep admission aligned with actual
// synchronous Handler capacity. The adapter brackets only application dispatch,
// so slow network reads and writes remain asynchronous and do not consume this
// capacity unit.
handler_lane_enter :: proc(res: ^Response, loc := #caller_location) -> bool {
	assert_has_td(loc)
	when URUQUIM_DEDICATED_ACCEPT {
		if td.handler_active {
			return false
		}
		sync.atomic_store_explicit(&td.handler_active, true, .Release)
		return true
	} else {
		if td.handler_active {
			return false
		}
		td.handler_active = true
		if td.accept != nil {
			target := td.accept
			td.accept = nil
		// URUQUIM PATCH 28 (perf) — SUSPEND THE ACCEPT WITHOUT SPINNING.
		//
		// The WP71 guarantee still holds: a lane about to run a synchronous
		// handler must not keep a live accept, or the kernel could hand it a new
		// connection that then waits behind the (possibly blocking) handler while
		// another lane is free. So we still cancel the accept — `nbio.remove`
		// submits an async_cancel — and `nbio.tick(0)` PUSHES that cancel to the
		// kernel now, non-blocking (timeout 0 → min_complete 0: it submits and
		// reaps whatever is already done, never waits). After it, the accept is
		// no longer live for the duration of the handler.
		//
		// What we DELETED is Patch 27's spin: `for ... { nbio.tick(1ms) }`,
		// bounded to 250ms/request. That spin was the framework's p99 tail
		// (measured 643ms → 3.4ms without it) and the C-05 wedge (a lane parked
		// in it never observed shutdown). It existed to observe the cancel
		// completion so the operation could be reattached by hand — but `nbio`
		// already recycles a removed operation itself and SUPPRESSES its callback
		// (`maybe_callback` runs only when `removal == nil`), so no hand-reattach
		// is needed and there is no late `on_accept` to corrupt the re-armed
		// accept. The one residue is a connection that wins the cancel race in
		// the sub-microsecond window between `remove` and the kernel acting on
		// it: its socket is accepted but its callback suppressed, so it is
		// dropped and the client reconnects. That window is vanishingly small for
		// keep-alive traffic and the price is one reconnect, not a 250ms stall on
		// every request.
			nbio.remove(target)
			_ = nbio.tick(0)
		}
		return true
	}
}

// Re-arm this lane only after application code returns. If stop won the race,
// shutdown owns admission and the accept remains absent.
handler_lane_leave :: proc(res: ^Response, loc := #caller_location) {
	assert_has_td(loc)
	when URUQUIM_DEDICATED_ACCEPT {
		assert(td.handler_active, "handler lane leave without enter", loc)
		sync.atomic_store_explicit(&td.handler_active, false, .Release)
		server := res._conn.server
		accept_loop := sync.atomic_load_explicit(&server.accept_loop, .Acquire)
		if !atomic_load(&server.closing) &&
		   sync.atomic_load_explicit(&server.pending_waiting, .Acquire) &&
		   accept_loop != nil {
			nbio.wake_up(accept_loop)
		}
		return
	} else {
		assert(td.handler_active, "handler lane leave without enter", loc)
		td.handler_active = false
		server := res._conn.server
		if !atomic_load(&server.closing) && td.accept == nil {
			td.accept = nbio.accept_poly(server.tcp_sock, server, on_accept)
		}
	}
}

@(private)
conn_handle_reqs :: proc(c: ^Connection) {
	// TODO/PERF: not sure why this is allocated on the connections allocator, can't it use the arena?
	scanner_init(&c.scanner, c, c.server.conn_allocator)

	// allocator_init(&c.temp_allocator, c.server.conn_allocator)
	// context.temp_allocator = allocator(&c.temp_allocator)
	err := virtual.arena_init_growing(&c.temp_allocator)
	assert(err == nil)
	context.temp_allocator = virtual.arena_allocator(&c.temp_allocator)

	conn_handle_req(c, context.temp_allocator)
}

@(private)
conn_handle_req :: proc(c: ^Connection, allocator := context.temp_allocator) {
	// URUQUIM PATCH 6 (WP46) — stamp the start of this request's arrival. The
	// sweep in `server_deadline_sweep` reads it; `clean_request_loop` clears it.
	// Do not pay a clock syscall on the default-off path.
	if c.server.opts.request_read_timeout > 0 {
		c.request_started = time.now()
	} else {
		c.request_started = {}
	}

	on_rline1 :: proc(loop: rawptr, token: string, err: bufio.Scanner_Error) {
		l := cast(^Loop)loop

		if !connection_set_state(l.conn, .Active) { return }

		// URUQUIM PATCH 20 (WP90) — bytes arrived: the connection stopped
		// being idle the moment a request line landed, whatever its fate.
		l.conn.idle_since = {}

		if err != nil {
			if err == .EOF {
				log.debugf("client disconnected (EOF)")
			} else {
				log.warnf("request scanner error: %v", err)
			}

			clean_request_loop(l.conn, close = true)
			return
		}

		// In the interest of robustness, a server that is expecting to receive
		// and parse a request-line SHOULD ignore at least one empty line (CRLF)
		// received prior to the request-line.
		if len(token) == 0 {
			log.debug("first request line empty, skipping in interest of robustness")
			scanner_scan(&l.conn.scanner, loop, on_rline2)
			return
		}

		on_rline2(loop, token, err)
	}

	on_rline2 :: proc(loop: rawptr, token: string, err: bufio.Scanner_Error) {
		l := cast(^Loop)loop

		if err != nil {
			log.warnf("request scanning error: %v", err)
			clean_request_loop(l.conn, close = true)
			return
		}

		rline, err := requestline_parse(token, context.temp_allocator)
		switch err {
		case .Method_Not_Implemented:
			log.infof("request-line %q invalid method", token)
			headers_set_close(&l.res.headers)
			l.res.status = .Not_Implemented
			respond(&l.res)
			return
		case .Invalid_Version_Format, .Not_Enough_Fields:
			log.warnf("request-line %q invalid: %s", token, err)
			clean_request_loop(l.conn, close = true)
			return
		case .None:
			l.req.line = rline
		}

		// Might need to support more versions later.
		if rline.version.major != 1 || rline.version.minor > 1 {
			log.infof("request http version not supported %v", rline.version)
			headers_set_close(&l.res.headers)
			l.res.status = .HTTP_Version_Not_Supported
			respond(&l.res)
			return
		}

		l.req.url = url_parse(rline.target.(string))

		l.conn.scanner.max_token_size = l.conn.server.opts.limit_headers
		scanner_scan(&l.conn.scanner, loop, on_header_line)
	}

	on_header_line :: proc(loop: rawptr, token: string, err: bufio.Scanner_Error) {
		l := cast(^Loop)loop

		if err != nil {
			log.warnf("request scanning error: %v", err)
			clean_request_loop(l.conn, close = true)
			return
		}

		// The first empty line denotes the end of the headers section.
		if len(token) == 0 {
			on_headers_end(l)
			return
		}

		if _, ok := header_parse(&l.req.headers, token); !ok {
			log.warnf("header-line %s is invalid", token)
			headers_set_close(&l.res.headers)
			l.res.status = .Bad_Request
			respond(&l.res)
			return
		}

		l.conn.scanner.max_token_size -= len(token)
		if l.conn.scanner.max_token_size <= 0 {
			log.warn("request headers too large")
			headers_set_close(&l.res.headers)
			l.res.status = .Request_Header_Fields_Too_Large
			respond(&l.res)
			return
		}

		scanner_scan(&l.conn.scanner, loop, on_header_line)
	}

	on_headers_end :: proc(l: ^Loop) {
		if !headers_validate_for_server(&l.req.headers) {
			log.warn("request headers are invalid")
			headers_set_close(&l.res.headers)
			l.res.status = .Bad_Request
			respond(&l.res)
			return
		}

		l.req.headers.readonly = true

		l.conn.scanner.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE

		// Automatically respond with a continue status when the client has the Expect: 100-continue header.
		if expect, ok := headers_get_unsafe(l.req.headers, "expect");
		   ok && expect == "100-continue" && l.conn.server.opts.auto_expect_continue {

			l.res.status = .Continue

			respond(&l.res)
			return
		}

		rline := &l.req.line.(Requestline)
		// An options request with the "*" is a no-op/ping request to
		// check for server capabilities and should not be sent to handlers.
		if rline.method == .Options && rline.target.(string) == "*" {
			l.res.status = .OK
			respond(&l.res)
		} else {
			// Give the handler this request as a GET, since the HTTP spec
			// says a HEAD is identical to a GET but just without writing the body,
			// handlers shouldn't have to worry about it.
			is_head := rline.method == .Head
			if is_head && l.conn.server.opts.redirect_head_to_get {
				l.req.is_head = true
				rline.method = .Get
			}

			l.conn.server.handler.handle(&l.conn.server.handler, &l.req, &l.res)
		}
	}

	c.loop.conn = c
	c.loop.res._conn = c
	c.loop.req._scanner = &c.scanner
	request_init(&c.loop.req, allocator)
	response_init(&c.loop.res, allocator)

	c.scanner.max_token_size = c.server.opts.limit_request_line
	scanner_scan(&c.scanner, &c.loop, on_rline1)
}

// A buffer that will contain the date header for the current second.
@(private)
Server_Date :: struct {
	buf_backing: [DATE_LENGTH]byte,
	buf:         bytes.Buffer,
}

@(private)
server_date_start :: proc(s: ^Server) {
	// URUQUIM PATCH 12 (WP70) — BRIDGE. `td.date` is lane-owned.
	td.date.buf.buf = slice.into_dynamic(td.date.buf_backing[:])
	server_date_update(nil, s)

	// URUQUIM PATCH 6 (WP46) — the deadline sweep starts on the same loop and
	// from the same place as the date tick, so there is one answer to "where do
	// this server's periodic timers come from".
	nbio.timeout_poly(URUQUIM_SWEEP_INTERVAL, s, server_deadline_sweep)
}

// URUQUIM PATCH 6 (WP46 / ADR-031) — the request read deadline, enforced.
//
// SWEEP_INTERVAL is the GRANULARITY, not the deadline. A request whose deadline
// is 5s is closed somewhere in [5s, 5s + interval]; that slack is acceptable for
// a defence measured in seconds, and it buys the absence of per-connection
// timers — see the note on `Server_Opts.request_read_timeout`.
@(private)
URUQUIM_SWEEP_INTERVAL :: 250 * time.Millisecond

// server_deadline_sweep closes connections whose current request has taken
// longer than the configured deadline to ARRIVE.
//
// It runs per thread, over that thread's own connection map, so it needs no
// synchronisation — the same property the rest of this server relies on.
//
// It deliberately looks only at connections with a request IN PROGRESS
// (`request_started` non-zero). An idle keep-alive connection is not a slow
// request, and closing one would turn a working feature into a defect.
@(private)
server_deadline_sweep :: proc(_: ^nbio.Operation, s: ^Server) {
	if atomic_load(&s.closing) { return }

	// URUQUIM PATCH 19/20 (WP90 / ADR-039) — the sweep now carries three
	// deadlines: request arrival (Patch 6), response write and idle
	// keep-alive. One connection is judged by at most one branch per pass:
	// a sending connection by the write deadline, an arriving request by the
	// read deadline, a quiet keep-alive by the idle timeout.
	read_t := s.opts.request_read_timeout
	write_t := s.opts.response_write_timeout
	idle_t := s.opts.idle_timeout
	// The loop always runs (WP92): per-connection overrides — the detached
	// stream's safe-without-tuning default — can arm a deadline even when
	// every server-wide value is 0. Each branch self-gates; an all-off
	// server pays one map iteration per 250 ms per lane, which is noise.
	{
		now := time.now()
		for _, conn in td.conns {
			if conn.state >= .Closing {
				continue
			}
			// PATCH 19 (WP92 amendment): a per-connection override — set for
			// detached streams — takes precedence over the server-wide value.
			effective_write := write_t
			if conn.write_deadline_override > 0 {
				effective_write = conn.write_deadline_override
			}
			if effective_write > 0 && conn.send_started != (time.Time{}) &&
			   time.diff(conn.send_started, now) > effective_write {
				log.infof("uruquim: response write deadline exceeded; aborting connection %i", conn.socket)
				// URUQUIM PATCH 28 (Closure H-3) — a write-deadline abort is the
				// one send outcome an operator most needs to see: a slow reader
				// being cut off. Counted here, on the owning lane.
				_ = sync.atomic_add(&s.write_deadline_aborts, 1)
				// Abort, not close: a graceful close would flush kernel
				// buffers to the slow reader first — see `connection_abort`.
				connection_abort(conn)
				continue
			}
			if read_t > 0 && conn.request_started != (time.Time{}) &&
			   conn.send_started == (time.Time{}) &&
			   time.diff(conn.request_started, now) > read_t {
				log.infof("uruquim: request read deadline exceeded; closing connection %i", conn.socket)
				connection_close(conn)
				continue
			}
			if idle_t > 0 && conn.state == .Idle && conn.idle_since != (time.Time{}) &&
			   time.diff(conn.idle_since, now) > idle_t {
				log.infof("uruquim: idle keep-alive timeout exceeded; closing connection %i", conn.socket)
				connection_close(conn)
			}
		}
	}

	// Rescheduled unconditionally, including when the deadline is disabled, so
	// this procedure has exactly one exit shape and enabling the deadline never
	// depends on a timer chain that was never started.
	nbio.timeout_poly(URUQUIM_SWEEP_INTERVAL, s, server_deadline_sweep)
}

// Updates the time and schedules itself for after a second.
@(private)
server_date_update :: proc(_: ^nbio.Operation, s: ^Server) {
	if atomic_load(&s.closing) { return }

	nbio.timeout_poly(time.Second, s, server_date_update)

	// URUQUIM PATCH 12 (WP70) — BRIDGE. Update only this lane's cache.
	bytes.buffer_reset(&td.date.buf)
	date_write(bytes.buffer_to_stream(&td.date.buf), time.now())
}

@(private)
server_date :: proc(s: ^Server) -> string {
	// URUQUIM PATCH 12 (WP70) — BRIDGE. Responses read their lane's cache.
	_ = s
	return string(td.date.buf_backing[:])
}
