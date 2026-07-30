// WP44 — LIFECYCLE: `stop`.
//
// ONE SYMBOL, and the deadline is a `Limits` FIELD rather than a second name.
// The Phase-4 plan gave this package a budget of two concepts (the WP38 usage
// lab measured 23 of 25), and this spends one on the verb and one on a field
// that costs no name at all — the WP46 precedent, for the same reason: a public
// options struct already exists, and a second way to configure a bound would be
// a second answer to one question (G-01).
//
// WHAT `stop` DOES, in the vocabulary the WP39 spec fixed:
//
//	Serving  →  Draining  →  Stopped
//
// Admission ceases immediately; work already in flight is allowed to finish;
// and when `Limits.max_drain_time` passes, whatever is left is closed anyway.
// **"Wait forever" is not a deadline**, and waiting forever is precisely what
// the vendored server did before this package — its drain loop waits on active
// connections with no bound, so one handler that never returns held the process
// open and the only shutdown was a kill.
//
// WHAT IT DELIBERATELY IS NOT. There is no `pause`, no `resume`, and no
// `Draining → Serving`: a client refused during the drain has already gone
// elsewhere, and an operator who asked for a stop meant it.
//
// ONE READABLE BIT, and no more (WP-6.5.3, ADR-040). WP44 refused any readable
// state, on the grounds that a readable state invites a poll loop where a
// supervisor belongs. That reasoning holds for the supervisor's question —
// "should this process be restarted" is the supervisor's, answered by the
// process exiting. It does NOT hold for a different question a real deployment
// must answer: "should the load balancer still route new traffic here." A
// Kubernetes-style readiness probe must flip to not-ready the instant a drain
// begins, or the proxy keeps sending requests the server is about to refuse.
// That probe is not a busy poll — it is the orchestrator's own traffic
// decision, on its own schedule — so `is_draining` exposes exactly one bit for
// it and nothing else: no state enum, no counters, no `Draining → Serving`.
package web
// druse:file application

import "core:sync"
import transport "druse:web/internal/transport"

// stop asks the running server to stop serving.
//
// It returns IMMEDIATELY. `stop` is a request, not a join: the drain happens on
// the server's own event loop, and the call that is blocked in `web.serve`
// returns when the drain completes. **That is the shape a signal handler needs**
// — a stop that blocked could not be called from one — and it is why the
// obvious alternative, making this wait, would make it unusable for the case it
// exists to serve.
//
// SAFE FROM ANOTHER THREAD, and safe to call twice. The backend's shutdown is
// an atomic flag plus an event-loop wake-up, so a second `stop` while the first
// is draining is a no-op rather than a second drain — which is what makes
// "cleanup runs exactly once" true rather than hoped for (spec §1.3 obligation
// 4). Calling it when no server is running is also a no-op.
//
// IT DOES NOT DESTROY THE APP. `stop` ends the server; `destroy` releases the
// application's storage, exactly as it always did, and the two are separate for
// the reason they have always been separate: an App outlives a `serve` call, and
// merging them would make `stop` a teardown you cannot call from a signal
// handler.
stop :: proc(a: ^App) {
	// The App is taken by pointer for symmetry with every other operation and
	// for what it makes possible later — a process may run one server today
	// (R-10), but a `stop` that ignored its App could never become per-server
	// without changing its signature, and a frozen signature cannot change.
	//
	// Publish the drain bit BEFORE asking the transport to stop, so a readiness
	// probe racing the signal can never see "still ready" after the refusal has
	// begun. Atomic store: `stop` is safe from a signal handler.
	sync.atomic_store(&a.private.draining, 1)
	transport.request_stop()
}

// is_draining reports whether `stop` has been requested on this application.
//
// It is the ONE readable bit of the lifecycle (see the file header): a readiness
// handler returns not-ready — a 503, so the load balancer stops routing new
// traffic here — while this is true. It is false before `stop`, true after, and
// never returns to false: an operator who asked for a stop meant it, and a
// process that has begun draining is going away. It reads an atomic and
// allocates nothing; call it from any thread.
is_draining :: proc(a: ^App) -> bool {
	return sync.atomic_load(&a.private.draining) != 0
}
