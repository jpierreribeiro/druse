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

// Pinned by assignment. Note the shape: no arguments and an integer result —
// it is a COUNT, not a metrics abstraction, and a framework that exported one
// of those would have chosen a vendor for its users.
@(test)
wp50_the_signature_is_pinned :: proc(t: ^testing.T) {
	pinned: proc() -> int = web.refused_connections
	testing.expect(t, pinned != nil, "refused_connections must have its ratified shape")
}

// With no server running it is zero rather than an error, and zero is also what
// "nothing was refused" reads as. **The two are deliberately not
// distinguished**, because a caller that needs to tell them apart is asking
// whether a server is running — a question WP44 decided this framework does not
// answer.
@(test)
wp50_with_no_server_the_count_is_zero :: proc(t: ^testing.T) {
	testing.expect_value(t, web.refused_connections(), 0)
}

// It carries no request-derived byte, which is what places it INSIDE the
// redaction policy's permitted set rather than at its edge. An integer cannot
// leak a path, a header or a body — and that is the property that let this ship
// as observability at all.
@(test)
wp50_the_count_is_an_integer_and_nothing_else :: proc(t: ^testing.T) {
	value := web.refused_connections()
	testing.expect(t, value >= 0, "a running total is never negative")
}
