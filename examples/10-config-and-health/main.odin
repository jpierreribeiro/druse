// Druse example 10 — Config from the environment, health and readiness.
//
// A twelve-factor service reads its configuration from the ENVIRONMENT, not
// from code, and exposes two distinct operational signals: liveness (is the
// process up?) and readiness (should traffic be routed here?). Druse's core
// does neither for you — configuration is your `main`'s job, and the two probes
// are ordinary handlers — but it gives you the pieces: `web.limits` takes the
// values you loaded, `web.is_draining` tells a readiness handler when a
// shutdown has begun, and `web.stats` reports what this server actually sent.
// (Signal wiring is the same shape as example 09.)
//
// EVERY ONE OF THOSE TAKES THE APP, and that is worth noticing rather than
// skipping past. A process may run more than one server — an application
// listener beside an admin or metrics listener is the ordinary case — and each
// of these questions has a different answer for each of them. Passing the App
// is what makes `/metrics` on this port report THIS port's traffic.
//
// Build and run it from the repository root:
//
//	PORT=9000 MAX_HANDLERS=16 odin run examples/10-config-and-health -collection:druse=.
//
// Then:
//
//	curl http://localhost:9000/health   # 200 while the process runs
//	curl http://localhost:9000/ready    # 200 while serving, 503 once draining
//	curl http://localhost:9000/metrics  # this server's counters, over HTTP
//
// AND THE PART THAT IS NOT A ROUTE (R2-WP03 / ADR-050). Set `METRICS_SNAPSHOT`
// and the process also writes its counters to a file from a thread that owns no
// Handler lane:
//
//	METRICS_SNAPSHOT=/dev/shm/druse.snapshot PORT=9000 odin run ... -collection:druse=.
//	ops/monitoring/sample-metrics.sh /dev/shm/druse.snapshot 1
//
// `/metrics` above is the thing you reach for and the thing that stops
// answering first: it is an ordinary route on the same lanes as the load. The
// snapshot is what an alert should be built on, and the reason is not
// performance — it is that a failed HTTP scrape cannot tell you whether the
// application saturated or the network dropped it, and an absent snapshot can
// only mean the application.
package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"
import web "druse:web"

app: web.App

on_signal :: proc "c" (_: posix.Signal) {
	context = runtime.default_context()
	web.stop(&app)
}

// env_int reads an environment variable as an int, falling back to `fallback`
// when it is unset or not a number. Configuration is explicit and total: an
// unreadable value never silently becomes zero.
env_int :: proc(key: string, fallback: int) -> int {
	value, found := os.lookup_env(key, context.temp_allocator)
	if !found {
		return fallback
	}
	parsed, ok := strconv.parse_int(value, 10)
	if !ok {
		return fallback
	}
	return parsed
}

main :: proc() {
	app = web.app()
	defer web.destroy(&app)

	// Configuration from the environment, with the framework's own defaults as
	// the fallback. Nothing here is Druse-specific — it is ordinary code that
	// hands resolved integers to `web.limits`.
	budget := web.DEFAULT_LIMITS
	budget.max_body        = env_int("MAX_BODY", budget.max_body)
	budget.max_connections = env_int("MAX_CONNECTIONS", budget.max_connections)
	budget.max_handlers    = env_int("MAX_HANDLERS", budget.max_handlers)
	web.limits(&app, budget)

	// Liveness: the process is up and can run a handler. A supervisor uses this
	// to decide whether to RESTART.
	web.get(&app, "/health", proc(ctx: ^web.Context) {
		web.ok(ctx, "ok")
	})

	// Readiness: should the load balancer route new traffic here? It flips to
	// not-ready the instant a drain begins, so the proxy stops sending requests
	// the server is about to refuse.
	web.get(&app, "/ready", proc(ctx: ^web.Context) {
		if web.is_draining(&app) {
			web.text(ctx, web.Status(503), "draining")
			return
		}
		web.text(ctx, .OK, "ready")
	})

	// The counters as JSON, for a human with curl and for a scraper that is not
	// under pressure. They are this App's server's own: `web.stats` reads the
	// server THIS App started, so a second listener in the same process reports
	// separately rather than both reporting whichever one happened to start last.
	//
	// Every field is an integer, which is what keeps this inside the redaction
	// policy's permitted set — no request-derived byte can reach a scraper here.
	//
	// READ THE NEXT COMMENT BEFORE MAKING THIS YOUR MONITORING PATH. This route
	// runs on the same Handler lanes as your traffic, and under saturation it is
	// the first thing to stop answering.
	web.get(&app, "/metrics", proc(ctx: ^web.Context) {
		web.ok(ctx, web.stats(&app))
	})

	posix.signal(.SIGTERM, on_signal)
	posix.signal(.SIGINT, on_signal)

	// R2-WP03 / ADR-050 — THE EXPORTER, and why a route was not enough.
	//
	// `/metrics` above competes with the traffic it describes. Measured under
	// full lane occupancy, a route like it answered 0 of 120 scrapes, and every
	// one of those failures was an HTTP error — a class producible both by an
	// application that stopped answering and by a network that dropped the
	// exchange. So a scrape that fails tells an operator nothing about which of
	// the two happened, exactly when knowing would matter.
	//
	// This thread owns no Handler lane. `web.stats` allocates nothing, takes no
	// lock and reads atomics, so calling it from here spends none of the resource
	// under measurement — and there is no network between the file it writes and
	// whatever reads it, so an absent sample can only mean the application.
	//
	// Format and the reader's side: `ops/monitoring/snapshot-format.md`.
	// A sampler that consumes it: `ops/monitoring/sample-metrics.sh`.
	if path, found := os.lookup_env("METRICS_SNAPSHOT", context.allocator); found {
		snapshot_path = path
		exporter = thread.create_and_start(export_loop)
	}
	defer if exporter != nil {
		// The exporter stops on drain, so it is already finishing by the time
		// `serve` returns. Joining keeps the final snapshot — the one carrying
		// `draining 1` — from racing process exit.
		thread.join(exporter)
		thread.destroy(exporter)
	}

	port := env_int("PORT", 8080)
	web.serve(&app, port)
}

// ---------------------------------------------------------------------------
// The exporter. Ordinary application code — the framework ships no metrics
// abstraction, on purpose, because a framework that exports one has chosen a
// vendor for its users.
// ---------------------------------------------------------------------------

exporter: ^thread.Thread
snapshot_path: string

EXPORT_PERIOD :: 1 * time.Second

// export_loop writes a snapshot every period, and one final snapshot once the
// drain begins.
//
// THE FINAL SNAPSHOT IS THE POINT OF THE DRAIN CHECK. A drain shorter than the
// export period would otherwise never appear in any sample, and a deploy that
// leaves no trace on the timeline is a deploy nobody can correlate an incident
// against afterwards.
export_loop :: proc() {
	for {
		draining := web.is_draining(&app)
		write_snapshot(draining)
		if draining {
			return
		}
		time.sleep(EXPORT_PERIOD)
	}
}

// write_snapshot renders one record and moves it into place.
//
// TEMP-THEN-RENAME. `rename` is atomic within a filesystem, so a reader sees the
// previous complete record or the new one, never half of either. Writing in
// place would let a reader observe a truncated record — and, worse, a PLAUSIBLE
// truncated record. The trailing `end` is what lets the reader prove it has a
// whole one rather than assume it.
write_snapshot :: proc(draining: bool) {
	s := web.stats(&app)
	// DO NOT OVERWRITE A REAL RECORD WITH ZEROES. `web.stats` returns the zero
	// value once the App is no longer running a server, and the final drain
	// write can land exactly there: `serve` returns, this thread wakes, and
	// every counter reads 0. Publishing that is publishing a counter RESET,
	// which operators are told to read as a restart. A running server always has
	// at least one lane, so `handler_capacity == 0` is the cheap test.
	//
	// Leaving the previous record alone is honest: it ages into `stale`, then
	// `no_process` once the pid is gone.
	if s.handler_capacity == 0 {
		return
	}
	b: strings.Builder
	strings.builder_init(&b)
	defer strings.builder_destroy(&b)
	fmt.sbprintfln(&b, "druse_snapshot 1")
	fmt.sbprintfln(&b, "pid %d", os.get_pid())
	fmt.sbprintfln(&b, "unix_ns %d", time.now()._nsec)
	fmt.sbprintfln(&b, "draining %d", 1 if draining else 0)
	fmt.sbprintfln(&b, "refused_connections %d", s.refused_connections)
	fmt.sbprintfln(&b, "saturation_refusals %d", s.saturation_refusals)
	fmt.sbprintfln(&b, "responses_sent %d", s.responses_sent)
	fmt.sbprintfln(&b, "response_bytes %d", s.response_bytes)
	fmt.sbprintfln(&b, "send_errors %d", s.send_errors)
	fmt.sbprintfln(&b, "write_deadline_aborts %d", s.write_deadline_aborts)
	fmt.sbprintfln(&b, "handler_dwell_ns %d", s.handler_dwell_ns)
	fmt.sbprintfln(&b, "stream_refused_full %d", s.stream_refused_full)
	fmt.sbprintfln(&b, "stream_refused_budget %d", s.stream_refused_budget)
	fmt.sbprintfln(&b, "stream_aborted_slow %d", s.stream_aborted_slow)
	fmt.sbprintfln(&b, "active_connections %d", s.active_connections)
	fmt.sbprintfln(&b, "handlers_active %d", s.handlers_active)
	fmt.sbprintfln(&b, "handler_capacity %d", s.handler_capacity)
	fmt.sbprintfln(&b, "connection_capacity %d", s.connection_capacity)
	fmt.sbprintfln(&b, "end")

	tmp := strings.concatenate({snapshot_path, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, transmute([]u8)strings.to_string(b)) != nil {
		return
	}
	// A failed rename leaves the PREVIOUS snapshot in place, which then ages
	// past max_age and is reported as `stale`. The failure is visible either
	// way; it is never a fresh-looking record with old numbers in it.
	_ = os.rename(tmp, snapshot_path)
}
