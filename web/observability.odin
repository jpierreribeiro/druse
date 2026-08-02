// WP50 — OBSERVABILITY: `refused_connections`.
//
// ONE SYMBOL, and it exists because §3.5 of the redaction policy demands it
// rather than because a counter felt useful:
//
//	**The drop policy is observable.** Any component that can discard records
//	must count what it discarded and expose the count, because a metric that
//	silently stops being emitted is worse than no metric — it reads as
//	"nothing happened".
//
// WP47 gave the framework the ability to refuse a connection. That is a
// discard, and until this symbol existed it was an invisible one: a server
// under admission pressure looked, from outside, exactly like a server nobody
// was talking to.
//
// WHY THIS AND NOT A METRICS API. A framework that exports a metrics
// abstraction has chosen a metrics vendor for its users, and the shape of that
// choice outlives the reasons for it. An integer an application reads and hands
// to whatever it already uses is the smallest thing that discharges the
// obligation. `web.observe` already covers framework FAILURES; this covers the
// one thing that is not a failure and not a request.
//
// WHAT IT IS NOT: a rate, a gauge, a histogram, or a reset. It is a running
// total for the life of the server, which is the shape every counter-scraping
// system already knows how to difference.
package web
// druse:file application

import "core:sync"
import transport "druse:web/internal/transport"

// refused_connections reports how many connections THIS APPLICATION's server has
// refused for admission (WP47's `Limits.max_connections`) since it started.
//
// WP123 / ADR-018 — IT TAKES THE APP, and the argument is the whole correction.
// This used to read a process-wide slot: in a process running two servers it
// answered about whichever one started last, for either caller, with nothing to
// say so. A counter that silently reports another server's traffic is worse than
// no counter — it is the shape of defect §3.5 exists to prevent, arriving
// through the very symbol that discharges §3.5. Naming the App makes the answer
// belong to the question.
//
// Zero when this App is not running a server, and zero when nothing has been
// refused — those two are deliberately not distinguished, because a caller that
// needs to tell them apart is asking whether a server is running, which is a
// different question this framework does not answer (WP44, and `is_draining` is
// the one bit that is exposed).
//
// It carries no request-derived byte, which is what places it inside the
// redaction policy's permitted set (§3.1) rather than at its edge.
//
// It allocates nothing, takes no lock, and reads one integer. Safe from any
// thread.
refused_connections :: proc(a: ^App) -> int {
	return transport.refused_connections(sync.atomic_load(&a.private.server))
}

// Server_Stats is the write-side accounting `web.stats` returns (Closure H-3).
//
// WHY THIS EXISTS, and it is the same argument `refused_connections` made one
// finding at a time: a component that can discard or fail to deliver work must
// expose the count, or the failure reads as "nothing happened". `refused_
// connections` covered admission; this covers the SEND side, which was
// invisible: how many responses left, how many bytes, how many sends failed,
// how many slow readers the write deadline cut off — and the three stream
// counters that were maintained in the registry and reachable from no public
// API, so a slow-consumer abort was counted and then unseeable. Campaign C adds
// `handler_dwell_ns`: the framework's Handler-capacity signal (C-05: lanes ÷
// dwell). The predecessor, `lane_collisions`, was MISNAMED rather than dead: its
// lane-collision increment was unreachable under dedicated accept (WP119), but
// the acceptor's saturation refusal also incremented it, so the number moved
// while meaning something other than its name. `saturation_refusals` now names
// that acceptor resource honestly, while dwell remains the Handler-utilization
// signal.
//
// WHY A STRUCT OF INTEGERS AND NOT A METRICS API. The same reason as
// `refused_connections`: a framework that exports a metrics abstraction has
// chosen a vendor for its users. A struct of integers an application reads and
// hands to whatever it already runs is the smallest thing that discharges the
// obligation. **Redaction holds by construction**: every field is an integer,
// so no request-derived byte can reach an observer through it — the gate pins
// that no field is a string.
//
// TWO KINDS OF FIELD, and the difference is load-bearing. The first ten are
// RUNNING TOTALS for the life of the server, which a scraper differences. The
// last four (R2-WP03) are two LEVELS and the two CEILINGS they are measured
// against, which a scraper reads as they are. All are zero when no server is
// running —
// the same rule as `refused_connections`, and for the same reason (WP44: no
// readable state).
Server_Stats :: struct {
	// Admission — identical to `refused_connections()`, included so one read
	// answers the whole write-and-refuse picture.
	refused_connections:   int,
	// Acceptor-side Handler saturation. This is a TCP refusal before any HTTP
	// request has been parsed, so it must never be described as a 503 response.
	saturation_refusals:   int,
	// Buffered responses.
	responses_sent:        int, // sends that completed without error
	response_bytes:        i64, // bytes reported on-the-wire for those sends
	send_errors:           int, // sends that completed with an error
	write_deadline_aborts: int, // connections the sweep aborted for a stalled write
	// Handler saturation (Campaign C). Capacity is lanes / dwell; the first
	// visible refusal is scheduler-dependent. Under dedicated accept, a request that arrives at a
	// busy lane queues on that lane's socket — no 503, no counter, only latency
	// — so the old `lane_collisions` counter never saw the saturation its name
	// described; what it did count was the acceptor's own refusals, which is a
	// different resource under the wrong label. `handler_dwell_ns` is the observable
	// replacement: total nanoseconds lanes spent inside handlers, as a running
	// total. Differenced over an interval it gives utilization
	// (Δdwell / (lanes × Δwall)) and mean handler dwell (Δdwell / Δresponses) —
	// and rising utilization says raise `max_handlers`, shorten the handler, or
	// move blocking work off the lane.
	handler_dwell_ns:      i64,
	// Detached streams (the WP92 registry counters, previously unreachable).
	stream_refused_full:   int, // a per-stream event/byte cap refused a send
	stream_refused_budget: int, // the process-wide byte budget refused a send
	stream_aborted_slow:   int, // an owner tore a stream down on write error/deadline
	// R2-WP03 / ADR-050 (AUD-P2-009) — OCCUPANCY AND RESOLVED CAPACITY.
	//
	// THESE FOUR ARE NOT RUNNING TOTALS, and mixing them up is the reason this
	// paragraph is longer than they are. Every field above is cumulative and a
	// scraper DIFFERENCES it; these four are two levels and the two ceilings
	// they are measured against, and a scraper must take them AS THEY ARE.
	// Differencing `active_connections` yields the net change in occupancy,
	// which is a number that looks like a rate and is not one.
	//
	// WHY THEY EXIST, AND IT IS SHARPER THAN "GAUGES ARE NICE". Every counter
	// above is written when work COMPLETES: `responses_sent` on send completion,
	// `handler_dwell_ns` after the dispatch returns. **At full lane occupancy
	// nothing completes, so all of them freeze**, and the utilization formula
	// this file documents — `Δdwell / (lanes × Δwall)` — reads ZERO at the exact
	// moment utilization is one. A fully saturated server and an idle server
	// produce the same flat lines. That was measured, not reasoned about:
	// `evidence/2026-08-02-r2-observability-arms/`, finding OBS-001, where four
	// of four lanes were provably inside handlers, 120 of 120 scrapes were
	// refused for saturation, and `handler_dwell_ns` was 0.
	//
	// `handlers_active` against `handler_capacity` is what tells the two apart,
	// and `handler_capacity` has to be reported because it is UNKNOWABLE from
	// outside: `max_handlers = 0` is the documented default and resolves to the
	// host's core count clamped to [4, 32]. An operator with the numerator and
	// no denominator has a ratio they cannot compute.
	//
	// All four already existed inside the process. Nothing could read them.
	active_connections:    int, // connections admitted and not yet closed (a LEVEL)
	handlers_active:       int, // lanes currently inside a handler (a LEVEL)
	handler_capacity:      int, // lanes actually running, after `max_handlers = 0` resolves
	connection_capacity:   int, // the admission ceiling actually enforced; 0 = unbounded
}

// stats returns THIS APPLICATION's server's write-side counters, or the zero
// value when this App is not running one.
//
// WP123 / ADR-018 — it takes the App for the same reason `refused_connections`
// does, and the stakes are higher here because there are ten numbers rather than
// one: a metrics endpoint scraping a two-server process used to export one
// server's send counters under both servers' labels, and the numbers were
// individually plausible the whole time.
//
// It allocates nothing, takes no lock, and reads every field inside one
// registry acquisition, so the snapshot is coherent.
//
// R2-WP03 — IT IS SAFE FROM ANY THREAD, and that property is what closes
// AUD-P2-009 rather than any field added to the struct. A metric that leaves
// the process through a route competes with the traffic it describes; this
// procedure can be called from a thread that owns no lane and answers no
// request, so an application can export its own numbers without spending any of
// the resource under measurement. `docs/reference/observability.md` and
// `docs/operations.md` §6 carry the shape; `examples/10-config-and-health` and
// `ops/soak/soak-server` carry a working exporter.
stats :: proc(a: ^App) -> Server_Stats {
	s := transport.server_stats(sync.atomic_load(&a.private.server))
	return Server_Stats {
		refused_connections   = s.refused_connections,
		saturation_refusals   = s.saturation_refusals,
		responses_sent        = s.responses_sent,
		response_bytes        = s.response_bytes,
		send_errors           = s.send_errors,
		write_deadline_aborts = s.write_deadline_aborts,
		handler_dwell_ns      = s.handler_dwell_ns,
		stream_refused_full   = s.stream_refused_full,
		stream_refused_budget = s.stream_refused_budget,
		stream_aborted_slow   = s.stream_aborted_slow,
		active_connections    = s.active_connections,
		handlers_active       = s.handlers_active,
		handler_capacity      = s.handler_capacity,
		connection_capacity   = s.connection_capacity,
	}
}
