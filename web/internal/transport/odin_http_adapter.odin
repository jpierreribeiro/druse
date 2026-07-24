// WP8 — ODIN-HTTP BOOTSTRAP ADAPTER.
//
// This is the ONLY file that imports the vendored backend. It converts a
// backend request into a neutral `Inbound`, enforces the body cap WHILE
// READING, drives the core through the `Dispatch_Proc` callback, and writes the
// neutral `Outbound` back to the wire. It names no `web` type.
//
// EXECUTION (WP8 D6, amended by WP71): a single catch-all handler feeds the
// Uruquim dispatcher — the backend router is NOT used. Handler capacity is
// resolved from the neutral Config below; `redirect_head_to_get = false`, so
// HEAD stays HEAD and the backend never rewrites a method.
package transport

import http "uruquim:vendor/odin-http"
import ingest "uruquim:web/internal/ingest"
import stream "uruquim:web/internal/stream"
import "core:mem"
import "core:net"
import "core:nbio"
import "core:os"
import "core:strconv"
import "core:time"
import "core:slice"
import "core:strings"
import "core:sync"

@(private)
AUTO_HANDLER_CONCURRENCY_MIN :: 4

@(private)
AUTO_HANDLER_CONCURRENCY_MAX :: 32

@(private)
resolve_handler_concurrency :: proc(requested: int) -> int {
	if requested != 0 {
		return requested
	}
	return clamp(
		os.get_processor_core_count(),
		AUTO_HANDLER_CONCURRENCY_MIN,
		AUTO_HANDLER_CONCURRENCY_MAX,
	)
}

// WP43 — PER-SERVER STATE. The config no longer lives in a package global.
//
// WHY THIS MATTERS AND IS NOT TIDYING. `web.serve` used to write its `Config`
// into `g_config`, which the backend's handler read on every request. That is
// fine for exactly one server per process and becomes a silent cross-wire the
// moment there are two: the second `serve` overwrites the first's dispatch
// pointer, and requests to server A run server B's application. Nothing
// diagnoses it, because nothing is wrong from either server's point of view.
//
// The backend's `Handler` already carries a `user_data: rawptr`, so the config
// travels WITH the handler rather than beside it. No vendored change was needed
// — the capability was there and unused.
//
// WHAT IS STILL A GLOBAL, and it is stated rather than hidden: `g_server`, read
// by `request_stop`. That one is a genuinely process-wide question today
// ("stop the running server") and it is WP44 that gives it a proper answer, by
// making a server a thing a caller HOLDS. Removing it here would mean inventing
// half of WP44's public surface in an internal package. WP70 protects its whole
// pointer lifetime while retaining the documented one-server-per-process rule.
@(private)
Server_Global :: struct {
	mutex:  sync.Mutex,
	server: ^http.Server,
	// WP90b — the running server's stream registry, for the same reason the
	// server pointer is here (one server per process; readable without a
	// request in hand). Tests reach it through `stream_registry_current`.
	streams: ^stream.Registry,
	// Phase 7.5-C2 — the running server's large-body ingest admission, here for
	// the same reason: `request_stop` must drain it (refuse new spools) without a
	// request in hand. Nil when upload is not enabled.
	admission: ^ingest.Admission,
}

// The one ratified process-global server lifetime (WP43), now one protected
// record rather than a pointer plus an ungoverned second package global.
@(private)
g_server: Server_Global

// Server_Runtime is the per-server state the handler needs. It lives in
// `serve`'s frame and is reached through the backend handler's `user_data`, so
// its lifetime is exactly the server's — no allocation, no teardown, and no way
// for a second server to overwrite the first's.
@(private)
Server_Runtime :: struct {
	config: Config,
	// WP90b — the detached-stream registry (WP88/WP89 machinery) and the
	// per-slot owner links. Links are indexed by registry slot, allocated
	// once at serve and freed after it: slot reuse is link reuse, and the
	// pump is idempotent over its (registry, token) pair, so a delayed wake
	// against a reused link runs a spurious-but-correct pump instead of
	// dereferencing freed memory.
	streams: stream.Registry,
	links:   []Stream_Link,
	// Phase 7.5-C2 — the large-body ingest admission, alive exactly as long as
	// the server (like `streams`). Zero/uninitialized unless `config.upload_enabled`.
	admission: ingest.Admission,
}

// Stream_Link binds one registry slot to its connection and owner lane.
Stream_Link :: struct {
	runtime:    ^Server_Runtime,
	conn:       ^http.Connection,
	loop:       ^nbio.Event_Loop,
	tok:        stream.Token,
	// exactly one pump may be scheduled at a time (CAS-armed by wakes from
	// any thread, cleared by the pump on the owner lane).
	pump_armed: bool,
	// the committed heading bytes, sent before the first chunk. They live in
	// the connection's request cycle, which for a detached stream ends only
	// at stream_finish/abort — after the heading send completed.
	heading:    []u8,
	committed:  bool,
	terminated: bool,
	// owner-lane scratch for the chunk-size prefix ("%x\r\n").
	prefix:     [18]u8,
}

// Exchange is the per-request state threaded through the async body read. It
// lives in the connection's temp allocator, which the backend owns for the
// duration of the request.
//
// WP43: it now also carries the runtime, because `on_body` is a plain callback
// with no other way to reach it.
@(private)
Exchange :: struct {
	req:         ^http.Request,
	res:         ^http.Response,
	runtime:     ^Server_Runtime,
	inbound:     Inbound,
	// WP90b — set by `stream_open` when this exchange detached its response.
	stream_link: ^Stream_Link,
	// Phase 7.5-C2 — large-body upload spool state, when this request's body was
	// consumed to an owned spool instead of buffered. `spool` lives here in the
	// connection temp arena; `spool_active` gates it; `spool_last` carries the
	// last ingest result so `on_upload_done` can map a mid-body breach to a
	// status. A `^ingest.Spool` into this field crosses to dispatch via
	// `inbound.upload`.
	spool:        ingest.Spool,
	spool_active: bool,
	spool_last:   ingest.Ingest_Result,
}

// serve runs the backend event loop and blocks until the server is stopped.
serve :: proc(cfg: Config) -> Serve_Error {
	// The runtime lives here, in this frame, for exactly as long as the server
	// does. Two concurrent `serve` calls would have two runtimes rather than
	// one shared slot — which is the whole point of WP43.
	runtime := Server_Runtime {
		config = cfg,
	}

	// WP90b — the detached-stream registry, alive exactly as long as the
	// server. Capacities are the phase-7-spec.md §4.1 registered defaults
	// unless the Config narrows them (tests force tiny queues through this).
	if !stream.registry_init(&runtime.streams, cfg.stream_capacity) {
		return .Listen_Failed
	}
	stream_cap := stream.resolve(cfg.stream_capacity)
	links_backing, links_err := make([]Stream_Link, stream_cap.max_streams)
	if links_err != nil {
		stream.registry_destroy(&runtime.streams)
		return .Listen_Failed
	}
	runtime.links = links_backing
	defer {
		stream.registry_destroy(&runtime.streams)
		delete(runtime.links)
	}

	// Phase 7.5-C2 — the large-body ingest admission, initialized once here from
	// the resolved upload config and torn down with the server. `admission_init`
	// requires a designated directory (no silent /tmp), so a bad config fails the
	// listen rather than silently disabling uploads.
	if cfg.upload_enabled {
		if !ingest.admission_init(
			&runtime.admission,
			ingest.Spool_Config {
				dir = cfg.upload_dir,
				per_upload_quota = cfg.upload_per_quota,
				process_quota = cfg.upload_proc_quota,
				max_concurrent = cfg.upload_max_conc,
				memory_prefix_max = cfg.upload_prefix_max,
			},
		) {
			return .Listen_Failed
		}
	}
	// The teardown defer is at FUNCTION scope, not inside the `if` above: an Odin
	// `defer` runs at the end of its enclosing block, so a defer inside the `if`
	// would destroy the admission the instant it was initialized. Destroying an
	// unenabled (zero) admission is a harmless no-op.
	defer ingest.admission_destroy(&runtime.admission)

	s: http.Server
	sync.lock(&g_server.mutex)
	g_server.server = &s
	g_server.streams = &runtime.streams
	if cfg.upload_enabled {
		g_server.admission = &runtime.admission
	}
	sync.unlock(&g_server.mutex)

	opts := http.Default_Server_Opts
	handler_concurrency := resolve_handler_concurrency(cfg.max_handlers)
	opts.thread_count = handler_concurrency
	opts.redirect_head_to_get = false
	// WP36: the caller's resolved text budgets replace the backend's own
	// defaults. `Default_Server_Opts` is a mutable package VARIABLE in the
	// vendored server — assigning to it would change the defaults for anything
	// else in the process — so the copy above is taken first and only the copy
	// is written to.
	opts.limit_request_line = cfg.max_request_line
	opts.limit_headers = cfg.max_headers
	// WP46 / ADR-031: the request read deadline. The conversion to
	// `time.Duration` happens HERE because this is the side of the boundary
	// where a clock is already linked — `package web` may not import one.
	opts.request_read_timeout = time.Duration(cfg.max_request_time)
	// WP90 / ADR-039 — the write deadline and idle timeout cross the boundary
	// as nanoseconds and become Durations here, where a clock is linked.
	opts.response_write_timeout = time.Duration(cfg.max_write_time)
	opts.idle_timeout = time.Duration(cfg.max_idle_time)
	opts.max_connections = cfg.max_connections
	opts.reserved_connections = cfg.reserved_conns
	// WP59 — the drain deadline crosses as nanoseconds and becomes a Duration
	// here, on the side of the boundary where a clock is already linked.
	opts.max_drain_time = time.Duration(cfg.max_drain_time)
	// WP9 D5: Phase 1 implements no interim-response flow. Leaving the backend's
	// automatic continue on made it answer "100 Continue" and then WAIT for a
	// body the client may never send. `Expect` is refused with 417 in
	// `catch_all` instead, and the connection closes.
	opts.auto_expect_continue = false

	endpoint := net.Endpoint {
		address = net.IP4_Address{0, 0, 0, 0},
		port    = cfg.port,
	}

	if err := http.listen(&s, endpoint, opts); err != nil {
		sync.lock(&g_server.mutex)
		g_server.server = nil
		g_server.streams = nil
		g_server.admission = nil
		sync.unlock(&g_server.mutex)
		return .Listen_Failed
	}

	// The listen succeeded: signal readiness (tests synchronize on this instead
	// of a fixed sleep) and start the blocking loop.
	if cfg.on_ready != nil {
		cfg.on_ready(cfg.user)
	}

	// The runtime travels WITH the handler through the backend's own
	// `user_data`, rather than beside it in a package global.
	handler := runtime_handler(&runtime)
	// Closure H-2 follow-up (F-C03-2 / patch 30): a lane that could not acquire
	// its io_uring event loop now unwinds and `serve` returns an error rather
	// than the process terminating. Surface it as a clean serve failure.
	serve_err := http.serve(&s, handler)

	sync.lock(&g_server.mutex)
	g_server.server = nil
	g_server.streams = nil
	g_server.admission = nil
	sync.unlock(&g_server.mutex)
	if serve_err != nil {
		return .Listen_Failed
	}
	return .None
}

// _refused_connections reads the running server's admission-refusal total.
//
// Through `g_server` — the one named global exception (WP43) — because the
// count belongs to the SERVER rather than to any request, and there is no
// request in hand when an operator asks for it.
@(private)
_refused_connections :: proc() -> int {
	sync.lock(&g_server.mutex)
	defer sync.unlock(&g_server.mutex)
	server := g_server.server
	if server == nil {
		return 0
	}
	return sync.atomic_load(&server.refused_total)
}

// _server_stats reads every write-side counter under the one lock, so the eight
// numbers are a coherent snapshot rather than eight independently-timed reads.
// Through `g_server`, like `_refused_connections`, and zero when no server runs.
@(private)
_server_stats :: proc() -> Server_Stats {
	sync.lock(&g_server.mutex)
	defer sync.unlock(&g_server.mutex)
	server := g_server.server
	if server == nil {
		return Server_Stats{}
	}
	out := Server_Stats {
		refused_connections   = sync.atomic_load(&server.refused_total),
		responses_sent        = sync.atomic_load(&server.responses_sent),
		response_bytes        = sync.atomic_load(&server.response_bytes),
		send_errors           = sync.atomic_load(&server.send_errors),
		write_deadline_aborts = sync.atomic_load(&server.write_deadline_aborts),
	}
	if g_server.streams != nil {
		c := stream.counters(g_server.streams)
		out.stream_refused_full = c.refused_stream_full
		out.stream_refused_budget = c.refused_budget_full
		out.stream_aborted_slow = c.aborted_slow
	}
	return out
}

// request_stop asks the running server to stop. Idempotent and thread-safe: the
// backend's shutdown is an atomic flag plus an event-loop wake-up, and calling
// it when no server is running is a no-op.
request_stop :: proc() {
	sync.lock(&g_server.mutex)
	defer sync.unlock(&g_server.mutex)
	// WP95 — signal the detached-stream registry BEFORE the backend drain, so
	// admission stops and every live stream's owner lane is woken to flush
	// its bounded queue and write the terminator. The backend's own
	// `max_drain_time` then force-closes anything still open, and the
	// per-connection teardown hook (WP92) releases those slots — so the
	// stream lifecycle rides the ONE process drain deadline (spec §2), never
	// a second clock. Admission of new large-body spools stops the same way:
	// a drained registry refuses `open`, and a Handler that would start a
	// spool sees the server closing.
	if g_server.streams != nil {
		stream.drain_begin(g_server.streams)
	}
	// Phase 7.5-C2 — stop admitting new large-body spools once drain begins; the
	// in-flight ones are owned by their request and cancelled at teardown or by
	// the backend's own max_drain_time.
	if g_server.admission != nil {
		ingest.admission_drain(g_server.admission)
	}
	server := g_server.server
	if server != nil {
		http.server_shutdown(server)
	}
}

// catch_all is the single backend handler. It starts the capped, buffered body
// read; everything else happens in `on_body` once the body is available.
// runtime_handler builds the backend handler with the runtime attached.
//
// `http.handler` stores a PROCEDURE in `user_data`; this stores the runtime
// instead and calls `catch_all` explicitly, which is the same shape the vendored
// helper uses and the reason no vendored change was needed.
@(private)
runtime_handler :: proc(runtime: ^Server_Runtime) -> http.Handler {
	h: http.Handler
	h.user_data = rawptr(runtime)
	h.handle = proc(h: ^http.Handler, req: ^http.Request, res: ^http.Response) {
		catch_all((^Server_Runtime)(h.user_data), req, res)
	}
	return h
}

@(private)
catch_all :: proc(runtime: ^Server_Runtime, req: ^http.Request, res: ^http.Response) {
	// WP9 D5 — `Expect: 100-continue` is refused before anything is read. This
	// is a PROTOCOL error handled by the adapter rather than by the core (D6):
	// there is no framework-owned request yet, so there is no envelope to write.
	// The handler never runs and the server never waits for a body.
	if expect, ok := http.headers_get_unsafe(req.headers, "expect"); ok && len(expect) > 0 {
		http.headers_set_close(&res.headers)
		res.status = http.Status.Expectation_Failed
		http.respond(res)
		return
	}

	exchange := new(Exchange, context.temp_allocator)
	exchange.req = req
	exchange.res = res
	exchange.runtime = runtime
	exchange.inbound.exchange = rawptr(exchange)

	// Phase 7.5-C2 — opt-in large-body upload. A body whose Content-Length
	// EXCEEDS max_body is consumed to an owned spool instead of answered 413; the
	// only behaviour this changes is that one case. Every other body — one within
	// max_body, or a chunked body of any size — takes the unchanged buffered path
	// below. A malformed Content-Length that slips this loose gate is re-validated
	// and rejected by `body_stream`'s own guards.
	if runtime.config.upload_enabled {
		if clen, ok := http.headers_get_unsafe(req.headers, "content-length"); ok {
			if n, pok := strconv.parse_int(clen, 10); pok && n > runtime.config.max_body {
				start_upload(exchange, n)
				return
			}
		}
	}

	// The backend enforces the cap as it reads: an over-length body never gets
	// buffered, and `on_body` is told with `.Too_Long`.
	http.body(req, runtime.config.max_body, exchange, on_body)
}

// --- Phase 7.5-C2: large-body upload (spool-then-dispatch) ------------------

@(private)
upload_window :: proc(runtime: ^Server_Runtime) -> int {
	if runtime.config.upload_prefix_max > 0 {
		return runtime.config.upload_prefix_max
	}
	return ingest.DEFAULT_MEMORY_PREFIX
}

// start_upload admits and opens a spool BEFORE reading a byte, then streams the
// body into it one bounded window at a time (PATCH 23). Admission or disk
// refusal is answered with a typed status by the adapter — the same
// transport-level shape as the Expect and 413 refusals — with no dispatch.
@(private)
start_upload :: proc(exchange: ^Exchange, content_length: int) {
	runtime := exchange.runtime

	// Reserve a bounded slot, or refuse before reading (§4.2). A drained
	// admission refuses here too, so a stop stops new uploads.
	if ingest.admit(&runtime.admission) != .Ready {
		upload_refuse(exchange, http.Status.Service_Unavailable)
		return
	}
	// Open the 0600 spool file. On failure the admission slot is released the
	// same way the multipart consumer releases it (mp_start_content): the disk
	// path is the rare one and shares that substrate contract.
	if ingest.begin(&runtime.admission, &exchange.spool) != .Ready {
		upload_refuse(exchange, http.Status.Insufficient_Storage)
		return
	}
	exchange.spool_active = true
	exchange.spool_last = .Ready

	// The spool's own per-upload and process quotas bound the body mid-stream, so
	// body_stream needs no separate max_length (-1); the window bounds memory.
	http.body_stream(exchange.req, -1, upload_window(runtime), exchange, on_upload_chunk, on_upload_done)
}

@(private)
on_upload_chunk :: proc(user_data: rawptr, chunk: []u8) -> http.Body_Sink_Result {
	exchange := (^Exchange)(user_data)
	r := ingest.append_chunk(&exchange.spool, chunk)
	exchange.spool_last = r
	return .Continue if r == .Ready else .Stop
}

@(private)
on_upload_done :: proc(user_data: rawptr, outcome: http.Stream_Outcome, err: http.Body_Error) {
	exchange := (^Exchange)(user_data)
	switch outcome {
	case .Complete:
		// The whole body is on the spool; hand the Handler an owned upload.
		ingest.finish(&exchange.spool)
		dispatch_upload(exchange)
	case .Stopped:
		// A mid-body consumer breach (quota/disk). append_chunk already cancelled
		// the spool; map its reason to a status.
		upload_refuse(exchange, upload_status_for(exchange.spool_last))
	case .Failed:
		// A framing/transport error while the spool was still open — clean it up.
		ingest.cancel(&exchange.spool, .Disconnected)
		upload_refuse(exchange, http.Status.Bad_Request)
	}
}

@(private)
upload_status_for :: proc(r: ingest.Ingest_Result) -> http.Status {
	#partial switch r {
	case .Quota_Exceeded:
		return .Payload_Too_Large
	case .Process_Quota_Exceeded:
		return .Service_Unavailable
	case .Disk_Full:
		return .Insufficient_Storage
	case:
		return .Payload_Too_Large
	}
}

// upload_refuse answers a refused/failed upload directly, like the Expect and
// over-limit refusals: a typed status, Connection: close, no dispatch.
@(private)
upload_refuse :: proc(exchange: ^Exchange, status: http.Status) {
	http.headers_set_close(&exchange.res.headers)
	exchange.res.status = status
	http.respond(exchange.res)
}

// dispatch_upload builds the neutral request with the owned spool attached (and
// an empty body — the body lives on disk, not in memory) and dispatches, exactly
// as on_body does for a buffered body.
@(private)
dispatch_upload :: proc(exchange: ^Exchange) {
	req := exchange.req
	rline := req.line.(http.Requestline)
	preserved_exchange := exchange.inbound.exchange
	exchange.inbound = Inbound {
		exchange = preserved_exchange,
		method   = rline.method_raw,
		path     = req.url.path,
		query    = req.url.query,
		headers  = neutral_headers(req, context.temp_allocator),
		peer     = net.address_to_string(req.client.address, context.temp_allocator),
		upload   = rawptr(&exchange.spool),
	}
	dispatch_exchange(exchange)
}

// on_body runs once the body has been read (or rejected for length). It builds
// the neutral request, drives the core, and writes the response.
@(private)
on_body :: proc(user_data: rawptr, body: http.Body, err: http.Body_Error) {
	exchange := (^Exchange)(user_data)
	req := exchange.req
	res := exchange.res

	rline := req.line.(http.Requestline)

	preserved_exchange := exchange.inbound.exchange
	exchange.inbound = Inbound {
		exchange   = preserved_exchange,
		// WP9 D7 — the ORIGINAL token. A valid but non-Phase-1 method
		// (PROPFIND) reaches the core, which maps it to its own `.UNKNOWN` and
		// applies the ratified 404/405 policy. The backend no longer answers
		// 501 on its own.
		method     = rline.method_raw,
		path       = req.url.path,
		query      = req.url.query,
		headers    = neutral_headers(req, context.temp_allocator),
		// WP48: the peer, from the accepted connection rather than from any
		// header. Rendered into the request's own temp allocator, so it lives
		// exactly as long as every other request-scoped view.
		peer       = net.address_to_string(req.client.address, context.temp_allocator),
		over_limit = err == .Too_Long,
	}
	if !exchange.inbound.over_limit {
		exchange.inbound.body = transmute([]u8)string(body)
	}
	dispatch_exchange(exchange)
}

@(private)
dispatch_exchange :: proc(exchange: ^Exchange) {
	res := exchange.res

	// A cancellation must finish before application code blocks this event loop.
	// The lane is either entered here or the request is refused — there is no
	// deferred retry, because everything the dispatch names lives in the
	// connection's temp arena and cannot outlive a client disconnect (F-002).
	if !http.handler_lane_enter(res) {
		// URUQUIM FIX (F-002) — a deferred dispatch can never run safely. The
		// Exchange and everything it names (`req`/`res` into `conn.loop`, the
		// inbound views) live in the connection's temp arena, which
		// `connection_close` frees wholesale when the client disconnects. A
		// `next_tick` retry therefore dereferences freed memory the moment a
		// client drops a contended connection — and even a client that stays
		// connected would have its response state torn down by
		// `clean_request_loop` before the retry fires. Retrying is unsound;
		// refuse the admission instead: answer 503 while the response state
		// is still valid, exactly as a load-shedding proxy would, and let the
		// client retry.
		http.headers_set_close(&res.headers)
		// Closure H-4 — a 503 without `Retry-After` invites an immediate retry,
		// and an immediate retry onto a contended lane pool collides again: the
		// refusal that told the client "not now" said nothing about "when", so
		// "when" becomes "right now", which is exactly the moment the lane is
		// still busy. RFC 7231 §7.1.3 defines the header for precisely this
		// load-shed case. One second is the smallest honest hint — the dwell of
		// a synchronous handler is the thing being waited out, and a client that
		// backs off a whole second is a client that stops adding to the
		// collision it just met. It is a hint, not a contract: `web.stop` and a
		// real overload may both outlast it, and the client is free to apply its
		// own backoff on top.
		http.headers_set(&res.headers, "Retry-After", "1")
		res.status = http.Status.Service_Unavailable
		http.respond(res)
		return
	}

	// The core builds its context, dispatches, copies the response into the
	// connection allocator, and tears down its request-local state — all before
	// returning (WP8 D2/D4).
	out: Outbound
	cfg := exchange.runtime.config
	cfg.dispatch(cfg.user, exchange.inbound, &out, context.temp_allocator)
	http.handler_lane_leave(res)

	// WP90b — a dispatch that opened a detached stream committed to a
	// different wire discipline: status/headers with chunked framing now, body
	// chunks from the owner-lane pump for as long as the stream lives, and no
	// `respond` ever.
	if out.detached && exchange.stream_link != nil {
		link := exchange.stream_link
		res.status = http.Status(out.status)
		for header in out.headers {
			http.headers_set(&res.headers, header.name, header.value)
		}
		link.heading = http.stream_prepare(res)
		stream_pump_run(link)
		return
	}

	write_response(res, out)
	http.respond(res)
}

// --- WP90b: the detached-stream pump ----------------------------------------

// stream_open is called BY DISPATCH-SIDE CODE, during the dispatch call, on
// the connection-owning lane. It binds a registry slot to this exchange's
// connection; the dispatch must then set `out.detached = true` and return
// without a body. Everything after that belongs to the pump.
stream_open :: proc(exchange_handle: rawptr) -> (stream.Token, bool) {
	exchange := (^Exchange)(exchange_handle)
	if exchange == nil || exchange.stream_link != nil {
		return stream.Token{slot = -1}, false
	}
	runtime := exchange.runtime
	conn := exchange.res._conn
	tok, opened := stream.open(
		&runtime.streams,
		u64(uintptr(rawptr(conn))),
		stream_pump_arm,
		nil, // patched below once the link is known
	)
	if opened != .Opened {
		return stream.Token{slot = -1}, false
	}
	link := &runtime.links[tok.slot]
	link^ = Stream_Link {
		runtime = runtime,
		conn    = conn,
		loop    = nbio.current_thread_event_loop(),
		tok     = tok,
	}
	// Re-register the wake with its user pointer now that the link exists.
	// Safe: no producer can hold the token before stream_open returns it.
	stream.rebind_wake(&runtime.streams, tok, stream_pump_arm, rawptr(link))
	// WP92 — an EXTERNALLY-initiated end (deadline sweep abort, shutdown
	// force-close, scanner error) must release the slot and silence the pump
	// before the Connection is freed; the backend fires this on its teardown.
	conn.on_teardown_user = rawptr(link)
	conn.on_teardown = stream_conn_torn_down
	exchange.stream_link = link
	return tok, true
}

// stream_conn_torn_down runs on the owner lane, from the backend's
// connection teardown, exactly once — whoever initiated the end.
@(private)
stream_conn_torn_down :: proc(user: rawptr) {
	link := (^Stream_Link)(user)
	if link == nil || link.terminated {
		return
	}
	link.terminated = true
	stream.note_abort(&link.runtime.streams)
	_ = stream.close(&link.runtime.streams, link.tok)
	_ = stream.retire(&link.runtime.streams, link.tok.slot)
}

// stream_pump_arm may run on ANY thread (it is the registry's per-slot wake).
// CAS guarantees at most one scheduled pump per link; `nbio` queues the
// operation to the owner lane's loop and wakes it (cross-thread `exec`).
@(private)
stream_pump_arm :: proc(user: rawptr) {
	link := (^Stream_Link)(user)
	if link == nil {
		return
	}
	if _, armed := sync.atomic_compare_exchange_strong(&link.pump_armed, false, true); armed {
		nbio.next_tick_poly(link, stream_pump, link.loop)
	}
}

@(private)
stream_pump :: proc(_: ^nbio.Operation, link: ^Stream_Link) {
	sync.atomic_store(&link.pump_armed, false)
	stream_pump_run(link)
}

@(private)
STREAM_CRLF := []u8{'\r', '\n'}
@(private)
STREAM_TERMINATOR := []u8{'0', '\r', '\n', '\r', '\n'}

// stream_pump_run drives one link on its OWNER LANE: heading first, then one
// in-flight chunk at a time (zero-copy out of the slot ring; the event is
// completed — and its bytes released — only after the socket write reports
// done), then the terminator once the stream is closed or the process drains.
@(private)
stream_pump_run :: proc(link: ^Stream_Link) {
	conn := link.conn
	if link.terminated || conn.state >= .Closing {
		return
	}
	if conn.pending_send != nil {
		return // a send is in flight; its completion re-runs the pump
	}
	if !link.committed {
		link.committed = true
		conn.send_started = time.now()
		conn.pending_send = nbio.send_poly(conn.socket, {link.heading}, link, on_stream_heading_sent)
		return
	}
	reg := &link.runtime.streams
	// SLOT-based drain: after a graceful close bumps the generation, the
	// token path would refuse, but the owner must still flush the events that
	// were queued before close — so the pump reads by slot.
	if data, has := stream.owner_next_event(reg, link.tok.slot); has {
		n := len(strconv.write_int(link.prefix[:16], i64(len(data)), 16))
		link.prefix[n] = '\r'
		link.prefix[n + 1] = '\n'
		conn.send_started = time.now()
		conn.pending_send = nbio.send_poly(
			conn.socket,
			{link.prefix[:n + 2], data, STREAM_CRLF},
			link,
			on_stream_chunk_sent,
		)
		return
	}
	// Queue empty. Terminate only when the stream has been closed (its final
	// events now flushed) or the process is draining; otherwise wait for the
	// next wake. This is what makes close GRACEFUL — the terminator follows
	// the last queued event rather than discarding it.
	_, close_requested, live := stream.owner_state(reg, link.tok.slot)
	if !live || close_requested || stream.draining(reg) {
		link.terminated = true
		conn.send_started = time.now()
		conn.pending_send = nbio.send_poly(conn.socket, {STREAM_TERMINATOR}, link, on_stream_terminator_sent)
	}
}

@(private)
on_stream_heading_sent :: proc(op: ^nbio.Operation, link: ^Stream_Link) {
	conn := link.conn
	conn.pending_send = nil
	conn.send_started = {}
	if op.send.err != nil {
		stream_teardown_error(link)
		return
	}
	stream_pump_run(link)
}

@(private)
on_stream_chunk_sent :: proc(op: ^nbio.Operation, link: ^Stream_Link) {
	conn := link.conn
	conn.pending_send = nil
	conn.send_started = {}
	if op.send.err != nil {
		stream_teardown_error(link)
		return
	}
	// The write is on the wire: NOW the event's ring bytes may be released.
	// Slot-based, so it works after a graceful close bumped the generation.
	_ = stream.owner_complete_event(&link.runtime.streams, link.tok.slot)
	stream_pump_run(link)
}

@(private)
on_stream_terminator_sent :: proc(op: ^nbio.Operation, link: ^Stream_Link) {
	conn := link.conn
	conn.pending_send = nil
	conn.send_started = {}
	// Success or failure, the request cycle ends here; a failed terminator
	// still retires the connection (close = true either way). Marking the
	// link terminated FIRST makes the backend's teardown notification a
	// no-op — the slot release below is the only one.
	link.terminated = true
	_ = stream.close(&link.runtime.streams, link.tok) // idempotent; refuses stragglers
	_ = stream.retire(&link.runtime.streams, link.tok.slot)
	if op.send.err != nil {
		http.stream_abort(conn)
		return
	}
	http.stream_finish(conn)
}

// stream_teardown_error: the client disconnected or the write failed
// mid-stream. Refuse producers, release the slot, reset the connection —
// a half-sent chunked body is not something anyone can parse to an end.
@(private)
stream_teardown_error :: proc(link: ^Stream_Link) {
	link.terminated = true
	stream.note_abort(&link.runtime.streams)
	_ = stream.close(&link.runtime.streams, link.tok)
	_ = stream.retire(&link.runtime.streams, link.tok.slot)
	http.stream_abort(link.conn)
}

// neutral_headers copies the backend request headers into neutral pairs. The
// copies live in `allocator` (the connection arena), valid for the exchange.
@(private)
neutral_headers :: proc(req: ^http.Request, allocator: mem.Allocator) -> []Header {
	count := len(req.headers._kv)
	if count == 0 {
		return nil
	}
	out := make([]Header, count, allocator)
	i := 0
	for k, v in req.headers._kv {
		out[i] = Header{name = k, value = v}
		i += 1
	}
	return out
}

// write_response writes the neutral `Outbound` to the backend response. Status
// crosses as its integer, including the private 413. Headers are set before the
// body, because writing the body flushes the status line and headers.
@(private)
write_response :: proc(res: ^http.Response, out: Outbound) {
	res.status = http.Status(out.status)
	for header in out.headers {
		http.headers_set(&res.headers, header.name, header.value)
	}
	http.body_set_bytes(res, out.body)
}

// The core copies its committed response into these before its own teardown, so
// the adapter owns the bytes it sends. Kept next to the adapter because it is
// the adapter's ownership contract, exercised by the boundary tests.
copy_response :: proc(out: ^Outbound, status: int, headers: []Header, body: []u8, allocator: mem.Allocator) {
	out.status = status

	if len(headers) > 0 {
		copied := make([]Header, len(headers), allocator)
		for header, i in headers {
			copied[i] = Header {
				name  = strings.clone(header.name, allocator),
				value = strings.clone(header.value, allocator),
			}
		}
		out.headers = copied
	} else {
		out.headers = nil
	}

	if len(body) > 0 {
		out.body = slice.clone(body, allocator)
	} else {
		out.body = nil
	}
}

// stream_registry_current exposes the running server's stream registry, the
// way `_refused_connections` exposes its admission total: through the one
// ratified global, for callers with no request in hand. Today its only
// consumers are the WP90 tests; the WP91 core wiring reaches the registry
// through the exchange instead.
stream_registry_current :: proc() -> ^stream.Registry {
	sync.lock(&g_server.mutex)
	defer sync.unlock(&g_server.mutex)
	return g_server.streams
}

// --- WP96: the public streaming boundary (plain integers, no stream type) ---
//
// `package web` may not name `internal/stream` (its own ADR-009 boundary), so
// the public API reaches streaming through these three procs that speak only
// in `(slot, generation)` value pairs and a boundary-owned result enum. The
// core wraps them as `web.stream`/`web.stream_send`/`web.stream_close`.

// Push_Result is the boundary's closed send outcome. `web` maps its own
// `Stream_Send` from this; neither exposes a stream or backend type.
Push_Result :: enum {
	Sent,
	Full,
	Closed,
}

// stream_begin opens a detached stream bound to the dispatching request's
// connection and returns its stale-safe identity as plain integers. Called on
// the connection-owning lane, during dispatch.
stream_begin :: proc(exchange: rawptr) -> (slot: i32, generation: u64, ok: bool) {
	tok, opened := stream_open(exchange)
	return tok.slot, tok.generation, opened
}

// stream_push enqueues bounded output from any thread. The registry is reached
// through the one-server-per-process global under its mutex, so a concurrent
// shutdown cannot free it mid-send (serve clears the pointer under the same
// mutex before destroying the registry).
stream_push :: proc(slot: i32, generation: u64, data: []u8) -> Push_Result {
	sync.lock(&g_server.mutex)
	defer sync.unlock(&g_server.mutex)
	reg := g_server.streams
	if reg == nil {
		return .Closed
	}
	switch stream.try_send(reg, stream.Token{slot = slot, generation = generation}, data) {
	case .Sent:
		return .Sent
	case .Full:
		return .Full
	case .Closed, .Stale, .Unimplemented:
		return .Closed
	}
	return .Closed
}

// stream_end closes a detached stream. Idempotent; a stale identity is a
// safe no-op.
stream_end :: proc(slot: i32, generation: u64) {
	sync.lock(&g_server.mutex)
	defer sync.unlock(&g_server.mutex)
	reg := g_server.streams
	if reg == nil {
		return
	}
	_ = stream.close(reg, stream.Token{slot = slot, generation = generation})
}

// stream_live reports whether the token still names an open, sendable stream —
// the boundary wrapper for the public `web.stream_live` (corrective WP C4,
// friction F8-5). No connection or registry means not live.
stream_live :: proc(slot: i32, generation: u64) -> bool {
	sync.lock(&g_server.mutex)
	defer sync.unlock(&g_server.mutex)
	reg := g_server.streams
	if reg == nil {
		return false
	}
	return stream.is_live(reg, stream.Token{slot = slot, generation = generation})
}
