// WP8 — CANONICAL SERVER ENTRY POINT, THE DISPATCH BRIDGE, AND THE RESPONSE
// DRIVER FINALIZATION.
//
// `serve` runs the real bootstrap HTTP server behind the private transport
// boundary (`web/internal/transport`). This file is the ONLY place `web`
// imports the transport, and the transport is the only thing that imports the
// backend — the one-way boundary of ADR-009. `serve_with` and `serve_transport`
// are Advanced API and remain absent from Phase 1.
package web
// druse:file application

import "core:mem"
import transport "druse:web/internal/transport"

// serve runs the application's HTTP server on the given port and blocks until
// the server stops.
//
// This is the canonical entry point. Transport selection is resolved inside the
// framework and is never part of the public API, which is what keeps the
// eventual move to the future official `core:net/http` package invisible to
// applications.
//
// It validates the port (1..65535); an invalid port is logged and `serve`
// returns WITHOUT binding. A bind/listen failure is likewise logged and
// returns. On success it listens DUAL-STACK — IPv6 Any (`::`) when the host has
// IPv6, which on a standard Linux accepts IPv4 clients too, falling back to IPv4
// Any where IPv6 is unavailable (item 5b) — and blocks while serving. Full
// graceful-shutdown deadlines are Phase 4; configurable timeouts are Phase 3.
serve :: proc(a: ^App, port: int) {
	// ADR-019: a poisoned application never binds. The dispatch-path guard
	// would answer 500 anyway — it lives there so both transports reject
	// identically — but a server that starts and then 500s everything is a
	// worse operator experience than one that refuses with the diagnostic.
	if a.private.poisoned {
		framework_report(App, .Use_After_Route)
		framework_observe_app(App, a, .Use_After_Route)
		return
	}

	if port < 1 || port > 65535 {
		framework_report(App, .Invalid_Serve_Port)
		framework_observe_app(App, a, .Invalid_Serve_Port)
		return
	}

	// WP70: finish lazy App-lifetime construction before the adapter creates
	// any lane, then publish the App as immutable. Every request sees this same
	// snapshot; late configuration is refused rather than raced.
	app_prepare_serving(a)

	// WP36: the backend's options are DERIVED from the App's limits, once, here
	// at boot. The adapter receives resolved numbers and never sees a `Limits`.
	cfg := transport.Config {
		port             = port,
		max_body         = a.private.limits.max_body,
		max_request_line = a.private.limits.max_request_line,
		max_headers      = a.private.limits.max_headers,
		max_request_time = a.private.limits.max_request_time,
		max_write_time   = a.private.limits.max_write_time,
		max_idle_time    = a.private.limits.max_idle_time,
		max_connections  = a.private.limits.max_connections,
		reserved_conns   = a.private.limits.reserved_conns,
		max_drain_time   = a.private.limits.max_drain_time,
		max_handlers     = a.private.limits.max_handlers,
		dispatch         = serve_dispatch,
		user             = a,
	}
	// Phase 7.5-C2: resolve the App's upload opt-in into transport primitives.
	// max_concurrent defaults to handler-lanes − 1 (§4.2), floor 1, resolved here
	// where the lane count is known; the adapter never sees a `web` config type.
	if a.private.upload_enabled {
		cfg.upload_enabled = true
		cfg.upload_dir = a.private.upload.dir
		cfg.upload_per_quota = a.private.upload.per_upload_quota
		cfg.upload_proc_quota = a.private.upload.process_quota
		cfg.upload_prefix_max = a.private.upload.memory_prefix_max
		cfg.upload_max_conc = a.private.upload.max_concurrent
		if cfg.upload_max_conc <= 0 {
			lanes := a.private.limits.max_handlers
			cfg.upload_max_conc = max(1, lanes - 1)
		}
	}
	if err := transport.serve(cfg); err != .None {
		framework_report(App, .Serve_Listen_Failed)
		framework_observe_app(App, a, .Serve_Listen_Failed)
	}
}

// serve_dispatch is the bridge the transport calls per request. It builds a
// Context from the neutral request, runs the core, copies the response OUT into
// transport-owned storage, and performs request teardown — all before it
// returns (WP8 D2/D4). The transport writes `out` to the wire afterwards.
//
// CLEANUP ORDER (WP8 D4), fixed and total: dispatch/commit -> copy out ->
// response_destroy -> request_arena_destroy. It runs on every path — a routed
// 2xx, an extractor 4xx, the automatic 404/405, the over-limit 413, and the
// driver's 500 — and leaves no request-local view behind.
@(private)
serve_dispatch :: proc(
	user: rawptr,
	inbound: transport.Inbound,
	out: ^transport.Outbound,
	allocator: mem.Allocator,
) {
	a := (^App)(user)

	ctx: Context
	driver_run(a, &ctx, inbound)

	// WP96: a Handler that opened a detached stream committed to a different
	// wire discipline. Hand the adapter the status/headers with `detached`
	// set; it commits them chunked and the owner-lane pump takes the wire.
	// The body view is deliberately empty — a stream has no buffered body.
	if ctx.private.stream_detached {
		out.detached = true
		transport.copy_response(
			out,
			int(ctx.private.response.status),
			response_headers_neutral_transport(ctx.private.response.headers, allocator),
			nil,
			allocator,
		)
		driver_cleanup(&ctx)
		return
	}

	// Copy the committed response into transport-owned storage BEFORE tearing
	// down the request, so the adapter never holds a view into freed memory.
	transport.copy_response(
		out,
		int(ctx.private.response.status),
		response_headers_neutral_transport(ctx.private.response.headers, allocator),
		response_body_view(&ctx),
		allocator,
	)
	// ROUTER AUDIT C4 — a HEAD keeps every header the GET produced, so it must
	// keep the GET's `content-length` too. The body view above is empty by
	// design; carry the real length across the boundary so the adapter announces
	// it rather than computing 0 from the suppressed slice.
	if ctx.private.implicit == .Head {
		out.suppressed_body_len = len(ctx.private.response.body)
	}

	driver_cleanup(&ctx)
}

// driver_run is the ONE request pipeline every response driver shares
// (WP9). It fills `ctx` from a neutral inbound request, dispatches, and
// guarantees a committed response:
//
//	neutral inbound -> Context -> dispatch -> finalize a missing response
//
// It deliberately stops BEFORE the response is copied out and before teardown,
// because those two steps differ by driver: the real transport copies into
// transport-owned storage, while `test_request` hands the response to the
// recorder. Both then call `driver_cleanup`.
//
// Extracting it is what makes "the test transport cannot lie" structural rather
// than aspirational (R-10): the in-memory and socket drivers now run the same
// code from inbound to committed response, so a semantic divergence can only
// come from the transport itself.
@(private)
driver_run :: proc(a: ^App, ctx: ^Context, inbound: transport.Inbound) {
	// WP20: the request carries the App's observer for its whole lifetime, set
	// before anything can fail. Both drivers call this one procedure, which is
	// what makes "observed identically on both transports" structural rather
	// than a claim (R-10).
	ctx.private.observer = a.private.observer

	// WP96: the transport's per-request handle travels the same way, so
	// `web.stream` can detach a response bound to this connection. Nil on the
	// in-memory transport, which has no connection to detach.
	ctx.private.stream_exchange = inbound.exchange

	// Phase 7.5-C2: the owned upload spool (an `^ingest.Spool`) travels the same
	// way, so `web.upload` can hand the Handler its body-on-disk. Nil unless the
	// adapter spooled a >max_body body; nil on the in-memory transport.
	ctx.private.upload = inbound.upload

	// WP37: the typed state travels the same way, and for the same reason —
	// one copy on the shared pipeline, so both transports behave identically
	// (R-10) and the Context still holds no `^App`.
	ctx.private.state = a.private.state
	ctx.private.state_type = a.private.state_type

	// WP36: the byte budget travels the same way, which is what makes
	// `test_request` and the socket agree about 413 by construction (R-10)
	// rather than by two implementations happening to hold the same number.
	ctx.private.limits = a.private.limits

	// WP48: the trusted set travels the same way. The peer itself comes from
	// the inbound request below, because it is per-connection rather than
	// per-application.
	ctx.private.trusted = a.private.trusted

	// WP60: the cross-origin policy travels the same way, so `test_request` and
	// the socket agree about CORS by construction (R-10).
	ctx.private.cors = a.private.cors

	if inbound.over_limit {
		// The adapter rejected the body for length BEFORE the handler. The core
		// authors the WP7 413 envelope; the handler never runs (WP8 D3).
		error_commit_body_too_large(ctx, ctx.private.limits.max_body)
		return
	}

	// WP32b: HEAD and OPTIONS are resolved from the RAW TOKEN, before a
	// `Method` value exists, which is what lets the frozen six-member enum stay
	// untouched. HEAD becomes GET for every downstream purpose.
	resolved_method, implicit := implicit_from_token(inbound.method)
	ctx.private.implicit = implicit

	ctx.private.peer = inbound.peer

	ctx.request = Request {
		method  = resolved_method,
		path    = inbound.path,
		query   = inbound.query,
		headers = header_view_from_pairs(inbound_header_pairs(inbound, context.temp_allocator)),
		body    = inbound.body,
	}
	// WP60: resolve the origin BEFORE dispatch, because a preflight must be
	// answered without running a handler — and because the headers have to be
	// on the Context before any response, including a 404 or a 500, is built.
	cors_resolve(ctx)
	if ctx.private.cors_preflight {
		cors_commit_preflight(ctx)
		driver_finalize(ctx)
		return
	}

	// WP91 (F5/F6): static serving moved INTO `dispatch`, where a mount still
	// owns its prefix ahead of the router but the response runs the ordinary
	// middleware chain — files get `secure_headers` and auth like handlers.

	dispatch(a, ctx)
	// C-04 / ADR-045: a committed response larger than `max_response_bytes` is
	// replaced with the standardized 500 here, on the shared path before the
	// driver copies it out, so both transports agree (R-10). A no-op when the
	// limit is off (the default).
	error_enforce_response_size(ctx)
	driver_finalize(ctx)
}

// driver_cleanup releases the request-local state, in the fixed order WP8 D4
// ratified: the response first, then the request arena. Every driver calls it
// AFTER it has captured or written the response.
@(private)
driver_cleanup :: proc(ctx: ^Context) {
	// Phase 7.5-C2: the owned upload's automatic cleanup (§4.2), through the
	// transport boundary (the core does not name the ingest type). It deletes the
	// spooled file exactly once and is a no-op if the Handler already transferred
	// ownership with `web.upload_persist` or the body was never spooled (nil).
	transport.upload_cancel(ctx.private.upload)
	response_destroy(&ctx.private.response)
	request_arena_destroy(ctx)
}

// inbound_header_pairs converts the neutral request headers into the core's
// Header_Pair view, in the caller's allocator. The pairs are views over the
// same transport-owned storage as `inbound`, valid only for this dispatch.
@(private)
inbound_header_pairs :: proc(inbound: transport.Inbound, allocator: mem.Allocator) -> []Header_Pair {
	if len(inbound.headers) == 0 {
		return nil
	}
	pairs := make([]Header_Pair, len(inbound.headers), allocator)
	for header, i in inbound.headers {
		pairs[i] = Header_Pair{name = header.name, value = header.value}
	}
	return pairs
}

// response_headers_neutral_transport converts the committed response's private
// header pairs into neutral transport headers for `copy_response`, which then
// makes its own owned copies. This intermediate slice is transient.
@(private)
response_headers_neutral_transport :: proc(
	pairs: []Header_Pair,
	allocator: mem.Allocator,
) -> []transport.Header {
	if len(pairs) == 0 {
		return nil
	}
	out := make([]transport.Header, len(pairs), allocator)
	for pair, i in pairs {
		out[i] = transport.Header{name = pair.name, value = pair.value}
	}
	return out
}

// driver_finalize guarantees a response driver never emits a zero status
// (WP8 D5).
//
// A dispatch can return with NOTHING committed: a handler that forgot to
// respond, or `bare()`'s deliberate no-policy on an unmatched route. HTTP has
// no zero status, so the DRIVER — `serve` and `test_request`, never a handler —
// turns that into a logged `internal_error`/500. This is a validity guarantee
// of the driver, not middleware and not an automatic route response: the core
// still installs no 404/405 under `bare()`.
@(private)
driver_finalize :: proc(ctx: ^Context) {
	if ctx.private.response.committed {
		return
	}
	framework_report(App, .No_Response_Committed)
	error_commit_static(ctx, .Internal_Server_Error, ERROR_BODY_INTERNAL)
	framework_observe_request(App, ctx, .No_Response_Committed)
}
