// WP50 public-surface contract — the observable drop policy.
//
// ONE SYMBOL. It exists because §3.5 of the redaction policy DEMANDS it, not
// because a counter felt useful: any component that can discard work must count
// what it discarded, because **a metric that silently stops being emitted reads
// as "nothing happened"**.
//
// WP47 gave the framework the ability to refuse a connection. Until this symbol
// existed that discard was invisible — a server under admission pressure looked,
// from outside, exactly like a server nobody was talking to.
package test_wp50_public

import "core:testing"
import web "druse:web"

// Pinned by assignment. Note the shape: ONE argument — the App whose server is
// being asked about (WP123/ADR-018) — and an integer result. It is a COUNT, not
// a metrics abstraction, and a framework that exported one of those would have
// chosen a vendor for its users.
//
// The App argument is load-bearing rather than decorative: without it the answer
// came from a process-wide slot, so in a two-server process both callers were
// told about whichever server started last, and neither could tell.
@(test)
wp50_the_signature_is_pinned :: proc(t: ^testing.T) {
	pinned: proc(a: ^web.App) -> int = web.refused_connections
	testing.expect(t, pinned != nil, "refused_connections must have its ratified shape")
}

// With this App running no server it is zero rather than an error, and zero is
// also what "nothing was refused" reads as. **The two are deliberately not
// distinguished**, because a caller that needs to tell them apart is asking
// whether a server is running — a question WP44 decided this framework does not
// answer.
@(test)
wp50_with_no_server_the_count_is_zero :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	testing.expect_value(t, web.refused_connections(&a), 0)
}

// It carries no request-derived byte, which is what places it INSIDE the
// redaction policy's permitted set rather than at its edge. An integer cannot
// leak a path, a header or a body — and that is the property that let this ship
// as observability at all.
@(test)
wp50_the_count_is_an_integer_and_nothing_else :: proc(t: ^testing.T) {
	a := web.app()
	defer web.destroy(&a)
	value := web.refused_connections(&a)
	testing.expect(t, value >= 0, "a running total is never negative")
}
