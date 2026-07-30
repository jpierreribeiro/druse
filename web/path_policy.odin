package web
// druse:file application

// WP31b — the path policy: REJECT, do not transform.
//
// The decision is `planning/phase-3-spec.md` §1, accepted by the owner on
// 2026-07-20. Druse normalises nothing, and rejects the paths where the
// absence of normalisation would be dangerous.
//
// WHY REJECT RATHER THAN NORMALISE. Path normalisation is where
// directory-traversal and route-confusion bugs live, and every normalisation
// rule is an opportunity for two components to disagree about what a path
// means — usually a proxy you do not control. Normalising maximises the number
// of ways this framework's view of a path can differ from the proxy's, and each
// difference is a potential authorization bypass: the request the proxy
// authorised is not the request the framework routed.
//
// WHY NOT STAY SILENT EITHER. Doing nothing is safe in the sense that nothing
// is transformed — `/users/../admin` matches no pattern and becomes a 404. But
// the disagreement stays INVISIBLE. The proxy sees `/admin`, applies `/admin`'s
// policy, forwards `/users/../admin`, and a 404 comes back. A 404 is not a
// diagnosis. Rejecting makes it loud, once, at the boundary, before any route
// or middleware can act on an ambiguous path — the same fail-closed shape as
// ADR-019's ordering guard.
//
// IT IS NOT A FRAMEWORK FAILURE. Like a 404, a rejected path is a normal
// outcome of a client's request and emits no `Framework_Event`. Phase 2 already
// pins the analogous distinction for the 404.

// PATH_REJECT_MESSAGE is the one message every rejection carries.
//
// It names the class and not the offending bytes. Echoing the path back would
// reflect attacker-controlled input into a response body, and the four rules
// are documented — a caller that needs to know which one fired can read them.
@(private)
PATH_REJECT_MESSAGE :: "path is ambiguous and was rejected without normalisation"

// path_rejected reports whether a request path must be answered 400 before it
// reaches route matching.
//
// The four rules, exhaustive. Anything not listed passes through byte-exact and
// undecoded, exactly as Phase 1 ships it:
//
//	R1  a segment equal to "." or ".."
//	R2  an INTERIOR empty segment (`//`)
//	R3  a percent-encoded slash, `%2F` or `%2f`
//	R4  a percent-encoded NUL, `%00`
//
// THE TRAILING SLASH IS NOT AN INTERIOR EMPTY SEGMENT. This is the trap the
// spec calls out at length, because the obvious implementation of R2 falls into
// it: `/users/` ends with an empty segment, and rejecting that would break every
// application that registered `/users/` — a legal, distinct Phase-1 pattern.
// `/users` and `/users/` remain two different paths, matched literally, neither
// normalised into the other.
//
// It allocates nothing and makes a single pass over bytes the router is about
// to walk anyway.
@(private)
path_rejected :: proc(path: string) -> bool {
	if len(path) == 0 {
		return false
	}

	// R3 and R4 — a percent-encoded slash or NUL anywhere. These are the two
	// encodings that change a path's STRUCTURE, which is why they are rejected
	// while ordinary percent-encoding is neither decoded nor refused.
	for i := 0; i + 2 < len(path); i += 1 {
		if path[i] != '%' {
			continue
		}
		hi := path[i + 1]
		lo := path[i + 2]
		if hi == '2' && (lo == 'F' || lo == 'f') {
			return true
		}
		if hi == '0' && lo == '0' {
			return true
		}
	}

	// R1 and R2 — walked segment by segment, with the trailing slash exempt
	// from R2 by construction: the final segment is only checked for R1.
	cursor := 1
	if len(path) == 0 || path[0] != '/' {
		// A path without a leading slash is not this policy's business; the
		// dispatcher already refuses to match it.
		return false
	}
	for {
		segment, ok := segment_next(path, &cursor)
		if !ok {
			return false
		}

		// R1 — a dot segment, at any depth including the last.
		if segment == "." || segment == ".." {
			return true
		}

		// R2 — an empty segment that is NOT the final one. `cursor` has already
		// advanced past this segment's separator, so `cursor <= len(path)`
		// means another segment follows and this empty one is interior.
		if len(segment) == 0 && cursor <= len(path) {
			return true
		}
	}
}
