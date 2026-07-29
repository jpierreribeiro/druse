// WP2 — FRAMEWORK REQUEST MODEL. NO TRANSPORT, NO DISPATCH, NO PARSING.
//
// This file declares the public request model: the closed `Method` set and the
// `Request` view struct. It performs no HTTP parsing, binds no socket, and
// decides no status code. A transport adapter (WP8) fills a `Request` in; the
// dispatcher (WP4) decides what a method means for a route.
package web
// druse:file application

// Method is the closed set of HTTP methods Phase 1 gives a public meaning to.
//
// Members are UPPERCASE (`.GET`, never `.Get`): the canonical spelling is
// ratified and documentation, tests and code use the same one.
//
// The set is deliberately minimal. `HEAD` and `OPTIONS` are absent because
// Phase 1 ratifies no public operation and no behavior for them; they enter
// when their contract is specified and tested
// (`knowledge-base/03-development-phases.md`).
//
// UNKNOWN is not an error and not a rejection. HTTP methods are extensible
// and case-sensitive (RFC 9110 §9.1), and the IANA method registry contains
// methods such as PROPFIND, so a token outside this set is a perfectly valid
// HTTP request that Phase 1 simply gives no public meaning to. Converting a
// token to `.UNKNOWN` is the whole behavior: the request model never turns an
// unknown method into a 405 or a 501. Method-dependent HTTP behavior is owned
// by WP4 (dispatch) and WP9; deciding it here would push response policy into
// every transport adapter.
Method :: enum u8 {
	UNKNOWN,
	GET,
	POST,
	PUT,
	PATCH,
	DELETE,
}

// Request is the framework-owned view of one in-flight HTTP request.
//
// LIFETIME (normative, planning/public-api-guardrails.md G-05; `knowledge-base/01-architecture-spec.md`
// §Request/Response ownership): `path`, `query`, `body` and every header name
// and value are VIEWS over storage owned by the transport for the duration of
// a single request. They are not owned by the application and they are not
// stable. When the transport reuses its buffer for the next request, a
// retained view silently starts reading different bytes — it does not fail
// loudly and it does not become nil.
//
// To keep any of it, COPY IT EXPLICITLY with an appropriate allocator
// (`strings.clone`, `slice.clone`). Background work receives owned application
// data, never a `Request`, never a view, and never a `^Context`.
//
// The abstraction is framework-owned even though the storage is not: no
// transport type appears in this struct, which is what keeps a future move to
// the official `core:net/http` package invisible to applications.
Request :: struct {
	method:  Method,
	path:    string,
	query:   string,
	headers: Header_View,
	body:    []u8,
}

// method_from_token converts an on-the-wire method token to `Method`.
//
// Package-internal: a transport adapter calls it while converting a parsed
// request. It is total — every input maps to a member — and it never fails,
// never allocates, and never retains `token`.
//
// Matching is EXACT and case-sensitive, as RFC 9110 §9.1 requires: "get" is
// not "GET" and converts to `.UNKNOWN`. Any token outside the Phase-1 set,
// including "HEAD", "OPTIONS" and registered methods such as "PROPFIND",
// converts to `.UNKNOWN`. An adapter that needs the original token for a later
// phase keeps it in its own internal state; it is not part of the public
// `Request`, and Phase 1 exposes no `method_raw`.
@(private)
method_from_token :: proc(token: string) -> Method {
	switch token {
	case "GET":
		return .GET
	case "POST":
		return .POST
	case "PUT":
		return .PUT
	case "PATCH":
		return .PATCH
	case "DELETE":
		return .DELETE
	}
	return .UNKNOWN
}
