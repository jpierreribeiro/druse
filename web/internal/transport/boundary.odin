// WP8 — NEUTRAL TRANSPORT BOUNDARY.
//
// This package is the one-way boundary between the framework core and a real
// HTTP backend (ADR-009). It is IMPORTED BY `web` and imports the vendored
// backend; it NEVER imports `web`. It names no `web` type — `App`, `Context`,
// `Request`, `Response`, `Status`, `Handler` are all unknown here. Data crosses
// as the neutral records below, and the core is driven through a callback.
//
// Only the CONCEPTUAL contract is frozen (ADR-009): accept -> dispatch ->
// commit -> stop. The record shapes here are private and may change freely when
// a second adapter lands.
//
// The odin-http adapter implements `serve` and `request_stop` behind these
// types; see `odin_http_adapter.odin`.
package transport

import "core:mem"
// WP90b — the detached-stream capacity record crosses the boundary so tests
// and (later) the core can bound the registry. One-way: stream imports nothing.
import stream "druse:web/internal/stream"

// Header is a neutral name/value pair. Both are views over storage owned by the
// caller for the duration of one exchange.
Header :: struct {
	name:  string,
	value: string,
}

// Inbound is the neutral inbound request handed to the core's dispatch callback.
//
// `method` is the on-the-wire token ("GET", "POST", ...); the core maps it to
// its own method set. `over_limit` is set by the adapter when the request body
// exceeded the maximum it agreed to read, in which case `body` is empty and the
// core produces the 413 envelope WITHOUT running a handler (WP8 D3).
//
// Every field is a VIEW valid only for the duration of the dispatch call.
Inbound :: struct {
	// WP48 — the CONNECTED PEER's address, rendered as a string by the adapter.
	//
	// A string rather than a `net.Address`, for the reason every other field
	// here is neutral: the core may not name a transport type. It is the peer,
	// never a forwarded header — the whole point of ADR-013 is that the two are
	// different values and only one of them is administered.
	peer:       string,
	method:     string,
	path:       string,
	query:      string,
	headers:    []Header,
	body:       []u8,
	over_limit: bool,
	// WP90b — the adapter's opaque per-request handle, so dispatch-side code
	// can open a detached stream bound to THIS connection via `stream_open`.
	// Valid only for the duration of the dispatch call, on the owner lane.
	exchange:   rawptr,
	// Phase 7.5-C2 — an opaque `^ingest.Spool` when this request's large body was
	// consumed to an owned spool (upload opt-in), else nil. The dispatch side
	// (which imports `web/internal/ingest`) casts it and hands the Handler an
	// owned upload; it also owns the spool's request-teardown cleanup. Opaque
	// here for the same reason `exchange` is: the boundary names no owning type.
	upload:     rawptr,
}

// Outbound is the neutral response the core's callback fills. The adapter copies
// it to the backend and sends it; the copies live in the `allocator` the core
// was given, which the adapter owns for the exchange.
//
// `status` is the raw HTTP status integer, including a value the core's public
// enum does not name (the private 413).
Outbound :: struct {
	status:  int,
	headers: []Header,
	body:    []u8,
	// WP90b — set by a dispatch that opened a detached stream via
	// `stream_open`: the adapter commits status/headers with chunked framing
	// and hands the wire to the owner-lane pump instead of writing a body.
	// The private boundary is free to carry this (ADR-009 Amendment 1).
	detached: bool,
	// ROUTER AUDIT C4 — the length the body WOULD have had, for a response whose
	// body was suppressed before it reached here. Only HEAD sets it (the core's
	// `response_body_view` blanks the body but keeps status and headers), and
	// only when that length is non-zero.
	//
	// Without it the adapter computed `content-length` from the empty slice it
	// was handed and answered `content-length: 0` to every HEAD, while RFC 9110
	// §8.6 requires the value a GET for the same resource would have sent. That
	// silently breaks the clients whose whole purpose for issuing HEAD is to
	// learn the size — `curl -I`, download managers, range-probing proxies.
	suppressed_body_len: int,
}

// Dispatch_Proc is how the adapter drives the core. The core builds its context
// from `inbound`, runs dispatch, COPIES the response into `out` using
// `allocator`, and performs its own request teardown before returning. After it
// returns the adapter owns `out` and writes it to the wire.
Dispatch_Proc :: #type proc(user: rawptr, inbound: Inbound, out: ^Outbound, allocator: mem.Allocator)

// Config is what `web.serve` hands the adapter. `on_ready`, when set, is called
// once after the listen succeeds (used by tests to synchronize without a fixed
// sleep).
//
// THE THREE BYTE BUDGETS ARE RESOLVED NUMBERS, and that is the boundary's whole
// contribution to WP36: the core validates a `web.Limits` once, at boot, and
// hands the adapter integers. No `Limits` type crosses this line — the adapter
// would then have to know about a public `web` type, which is the back-edge
// ADR-009 forbids — and nothing on the read path re-derives a budget.
Config :: struct {
	port:             int,
	// The byte cap the adapter enforces while reading the body.
	max_body:         int,
	// The request-line and header-block caps the BACKEND enforces. They are
	// passed through rather than checked here: the adapter's job is to hand the
	// backend its own options, not to reimplement its parser's limits.
	max_request_line: int,
	max_headers:      int,
	// WP46 — the request read deadline in NANOSECONDS. The core may not import
	// `core:time` (FINDING-B), so the neutral boundary carries a plain integer
	// and the adapter converts, on the side of the line where a clock is
	// already linked. Zero disables it.
	max_request_time: i64,
	// WP90 / ADR-039 — the response write deadline and the idle keep-alive
	// timeout, in NANOSECONDS, zero disabled — carried as plain integers for
	// the same FINDING-B reason as `max_request_time`; the adapter converts.
	max_write_time:   i64,
	max_idle_time:    i64,
	// WP47 — bounded admission. Zero is unbounded.
	max_connections:  int,
	reserved_conns:   int,
	// WP59 — the absolute drain deadline in NANOSECONDS, for the same reason
	// `max_request_time` is one: the core may not import `core:time`, so the
	// neutral boundary carries a plain integer and the adapter converts on the
	// side of the line where a clock is already linked. Zero disables it.
	max_drain_time:   i64,
	// WP71 — maximum concurrent synchronous Handler execution. Zero asks the
	// adapter for its documented bounded automatic policy; one is compatibility.
	max_handlers:     int,
	// Phase 7.5-C2 — large-body upload opt-in, as resolved primitives (no ingest
	// type crosses the boundary, exactly as no `Limits` does). When
	// `upload_enabled`, a request body over `max_body` is spooled to `upload_dir`
	// under these §4.2 quotas instead of answered 413, and the dispatch receives
	// an owned spool via `Inbound.upload`. Disabled (the zero value) is the
	// unchanged buffered path. `upload_dir` is required to enable — the core never
	// picks a spool directory.
	upload_enabled:   bool,
	upload_dir:       string,
	upload_per_quota: i64,
	upload_proc_quota:i64,
	upload_max_conc:  int,
	upload_prefix_max:int,
	// WP90b — detached-stream capacities. Zero fields select the
	// phase-7-spec.md §4.1 registered defaults; tests force tiny queues here.
	stream_capacity:  stream.Capacity,
	dispatch:         Dispatch_Proc,
	user:             rawptr,
	on_ready:         proc(user: rawptr),
	// WP123 — how the caller learns WHICH server it just started. Called once
	// with a live handle before the listen, and once with `SERVER_HANDLE_NONE`
	// when `serve` returns, on the same `user` pointer `on_ready` travels on.
	//
	// It exists because every process-wide question this boundary answers —
	// stop, the counters, a stream send — used to resolve against "the" server
	// and now resolves against a named one. The core stores the handle on its
	// App; the boundary never learns that such a thing exists.
	on_server:        proc(user: rawptr, h: Server_Handle),
}

// refused_connections reports how many connections this process refused for
// admission since the server started, or 0 when no server is running.
//
// WP50 §3.5: the drop policy is OBSERVABLE. A component that can discard work
// must count what it discarded — a metric that silently stops being emitted
// reads as "nothing happened", which is worse than no metric.
//
// It is a plain integer and carries no request-derived byte, which is what puts
// it inside §3.1's permitted set.
refused_connections :: proc(h: Server_Handle) -> int {
	return _refused_connections(h)
}

// Server_Stats is the neutral write-side accounting the public `web.Server_Stats`
// is built from (Closure H-3). Every field is a plain integer running total, so
// it carries no request-derived byte — the same §3.1 property that admits
// `refused_connections`. It joins the backend's four send counters (patch 28)
// with the stream registry's three (WP92), so an operator sees buffered writes
// and streamed writes in one read.
Server_Stats :: struct {
	refused_connections:   int,
	saturation_refusals:   int,
	responses_sent:        int,
	response_bytes:        i64,
	send_errors:           int,
	write_deadline_aborts: int,
	// Campaign C: total nanoseconds lanes spent inside dispatched handlers,
	// as a running total. Replaces `lane_collisions`, whose lane-collision
	// increment was unreachable under dedicated accept (handlers run on the
	// lane, so the 503-on-collision path never fires) and which therefore only
	// ever counted the acceptor's saturation refusals — a different resource
	// under a name that promised lane collisions. The operator
	// differences this against wall time per lane for utilization, and
	// against `responses_sent` for mean dwell.
	handler_dwell_ns:      i64,
	stream_refused_full:   int,
	stream_refused_budget: int,
	stream_aborted_slow:   int,
}

// server_stats reads the running server's write-side counters, or the zero
// value when no server is running — the same rule as `refused_connections`.
server_stats :: proc(h: Server_Handle) -> Server_Stats {
	return _server_stats(h)
}

// Serve_Error is the neutral outcome of a serve attempt.
Serve_Error :: enum {
	None,
	Invalid_Port,
	Listen_Failed,
	// WP123 — more than `SERVER_TABLE_CAP` servers were asked to run at once in
	// this process. Named separately from `Listen_Failed` because it is a
	// different fault with a different fix: nothing was wrong with the port, and
	// no socket was touched. The core currently reports both through the frozen
	// `Serve_Listen_Failed` event (see the note at its mapping in `web/serve.odin`).
	Too_Many_Servers,
}

// `serve`, `request_stop` and `copy_response` are implemented in
// `odin_http_adapter.odin`, the one file that names the backend.
