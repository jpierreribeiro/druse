// WP7 — REQUEST-LIFETIME ARENA AND THE BODY-CONSUMPTION STATE.
//
// Nothing in this file is public. It is the private machinery behind
// `web.body`: the request-lifetime allocator that owns decoded nested data
// (ADR-006), and the single-consumer state that ADR-012 (option A) rests on.
//
// WHY THIS LIVES IN `web/` AND NOT `web/internal/memory/`. The plan proposed a
// subpackage. In Odin a subdirectory is a SEPARATE PACKAGE, and this code must
// reach `Context_Internal` and the private typed report — so a subpackage would
// have to import `druse:web`, the back-edge WP3 ratified as a compile cycle
// (probe C5), or expose an importable auxiliary surface. That is the exact
// refutation WP4 recorded for the dispatcher, so the machinery is a top-level
// package-private file and `build/check_public_api.sh` permits this one extra
// name (WP7 D1).
package web
// druse:file application

import "core:mem"

// BODY_LIMIT is the fixed maximum request-body size Phase 1 accepts, in bytes.
//
// It is a constant, not configuration: a per-application limit is a Phase-3
// feature, and inventing a knob here would freeze a public policy WP7 has no
// mandate for. Exactly `BODY_LIMIT` bytes is allowed; only a strictly larger
// body is rejected (WP7 D3), so the comparison is `>` and never `>=`.
@(private)
BODY_LIMIT :: 4 * 1024 * 1024

// Body_State is the single-consumer capability (ADR-012 A).
//
// `.Fresh` is the zero value, so a freshly-constructed Context begins with the
// body capability available and no arena. The FIRST `web.body` call moves it to
// `.Consumed` before it checks the limit or runs the parser, so even a first
// attempt that fails spends the capability — a second call can then never parse
// again.
@(private)
Body_State :: enum {
	Fresh,
	Consumed,
}

// request_arena_init lazily initializes the request arena.
//
// It is called ONLY from `web.body`, and only after the body has been shown to
// be non-empty and within `BODY_LIMIT` — an empty or over-limit body never
// reaches here, so it never allocates (WP7 D3/D4). The block allocator is
// `context.allocator`, captured at first use.
//
// It is idempotent on `arena_active`: a second call is a no-op, which matters
// because the state machine forbids a second parse but the guard here is
// defence in depth.
@(private)
request_arena_init :: proc(ctx: ^Context) {
	if ctx.private.arena_active {
		return
	}
	mem.dynamic_arena_init(&ctx.private.request_arena)
	ctx.private.arena_active = true
}

// request_arena_allocator returns the allocator that owns decoded body data.
//
// The returned allocator aliases `ctx.private.request_arena`, so it is valid
// exactly as long as the Context is and until `request_arena_destroy` runs.
@(private)
request_arena_allocator :: proc(ctx: ^Context) -> mem.Allocator {
	return mem.dynamic_arena_allocator(&ctx.private.request_arena)
}

// request_arena_destroy frees the whole request arena exactly once and returns
// the Context's arena state to its inert zero.
//
// WHO CALLS IT. The response DRIVER, after it has captured or written the
// Response — never the handler and never `web.body`. Today the only driver is
// `web.test_request`, which calls this after the recorder has copied the
// response; the WP8 transport adapter must do the same. There is deliberately NO
// public cleanup symbol, exactly as with the WP6 response teardown: request
// lifetime is framework business.
//
// A partial parse may have left allocations in the arena; they are all released
// together here (WP7 D4). It is IDEMPOTENT: `arena_active` gates the work, so a
// second call frees nothing, and `dynamic_arena_destroy` has already zeroed the
// arena.
@(private)
request_arena_destroy :: proc(ctx: ^Context) {
	if !ctx.private.arena_active {
		return
	}
	mem.dynamic_arena_destroy(&ctx.private.request_arena)
	ctx.private.arena_active = false
}
