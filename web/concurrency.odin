// WP70 — the private publication boundary for concurrent serving.
package web
// druse:file application

import "core:sync"

@(private)
app_is_serving :: proc(a: ^App) -> bool {
	return sync.atomic_load(&a.private.serving) != 0
}

@(private)
app_has_dispatched :: proc(a: ^App) -> bool {
	return sync.atomic_load(&a.private.dispatched) != 0
}

// ROUTER AUDIT P5 — READ BEFORE WRITING, so the shared line stays clean.
//
// This ran an unconditional `atomic_store` on EVERY dispatch from EVERY lane.
// The flag is monotonic — it goes 0 -> 1 once per App and never back — so every
// store after the first writes a value that is already there, while dirtying a
// cache line that `mw_poison_intercept`, `static_serve` and the default-response
// paths read on the same requests. With four lanes that is a write-invalidate
// ping-pong at request rate, paid forever to publish a bit that stopped changing
// after the first request.
//
// The load keeps the line in shared state once it is set; the store still runs
// on the (at most one per App) transition, so the published value is unchanged.
@(private)
app_mark_dispatched :: proc(a: ^App) {
	if sync.atomic_load(&a.private.dispatched) == 0 {
		sync.atomic_store(&a.private.dispatched, 1)
	}
}

// app_prepare_serving completes every lazy App-lifetime structure before the
// transport can create a second lane, then publishes the immutable snapshot.
@(private)
app_prepare_serving :: proc(a: ^App) {
	if app_is_serving(a) {
		return
	}
	miss_chain_ensure(a)
	sync.atomic_store(&a.private.serving, 1)
}

// app_claim_serve gives one call ownership of this App's transport lifetime.
//
// The draining checks close both sides of the race with `stop`: one before the
// CAS rejects an App already draining; one after it catches a stop that landed
// between the first check and the claim. A stop after the second check is
// handled by `serve_publish_handle`, which immediately requests stop once the
// transport publishes its handle.
@(private)
app_claim_serve :: proc(a: ^App) -> bool {
	if sync.atomic_load(&a.private.draining) != 0 {
		return false
	}
	if _, claimed := sync.atomic_compare_exchange_strong(&a.private.serve_active, 0, 1); !claimed {
		return false
	}
	if sync.atomic_load(&a.private.draining) != 0 {
		sync.atomic_store(&a.private.serve_active, 0)
		return false
	}
	return true
}

@(private)
app_release_serve :: proc(a: ^App) {
	sync.atomic_store(&a.private.serve_active, 0)
}

// Late configuration must not poison the live snapshot: writing `poisoned`
// while lanes read it would merely replace one race with another. Refuse the
// mutation, report it, and leave the published App byte-identical.
@(private)
app_reject_late_configuration :: proc(a: ^App, loc := #caller_location) {
	framework_report(App, .Use_After_Route, loc)
	framework_observe_app(App, a, .Use_After_Route)
}
