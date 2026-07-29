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
// uruquim:file application

import transport "uruquim:web/internal/transport"

// refused_connections reports how many connections this process has refused for
// admission (WP47's `Limits.max_connections`) since the server started.
//
// Zero when no server is running, and zero when nothing has been refused —
// those two are deliberately not distinguished, because a caller that needs to
// tell them apart is asking whether a server is running, which is a different
// question this framework does not answer (WP44: there is no readable state).
//
// It carries no request-derived byte, which is what places it inside the
// redaction policy's permitted set (§3.1) rather than at its edge.
//
// It allocates nothing and reads one integer.
refused_connections :: proc() -> int {
	return transport.refused_connections()
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
// while meaning something other than its name. Handled by replacing the failed
// counter, not by reviving it.
//
// WHY A STRUCT OF INTEGERS AND NOT A METRICS API. The same reason as
// `refused_connections`: a framework that exports a metrics abstraction has
// chosen a vendor for its users. Eight running totals an application reads and
// hands to whatever it already runs is the smallest thing that discharges the
// obligation. **Redaction holds by construction**: every field is an integer,
// so no request-derived byte can reach an observer through it — the gate pins
// that no field is a string.
//
// Each field is a running total for the life of the server (a scraper
// differences it), and all are zero when no server is running — the same rule
// as `refused_connections`, and for the same reason (WP44: no readable state).
Server_Stats :: struct {
	// Admission — identical to `refused_connections()`, included so one read
	// answers the whole write-and-refuse picture.
	refused_connections:   int,
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
}

// stats returns the running server's write-side counters, or the zero value
// when no server is running. It allocates nothing and reads nine integers under
// one lock, so the snapshot is coherent.
stats :: proc() -> Server_Stats {
	s := transport.server_stats()
	return Server_Stats {
		refused_connections   = s.refused_connections,
		responses_sent        = s.responses_sent,
		response_bytes        = s.response_bytes,
		send_errors           = s.send_errors,
		write_deadline_aborts = s.write_deadline_aborts,
		handler_dwell_ns      = s.handler_dwell_ns,
		stream_refused_full   = s.stream_refused_full,
		stream_refused_budget = s.stream_refused_budget,
		stream_aborted_slow   = s.stream_aborted_slow,
	}
}
