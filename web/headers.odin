// WP2 — REQUEST HEADER VIEW. NO LOOKUP, NO NORMALIZATION, NO RESPONSE HEADERS.
//
// This file declares the header view carried by `Request`. Phase 1 ships NO
// header lookup: `web.header` and `web.bearer_token` are Phase 2 and must not
// be approximated here. Header normalization is transport-conformance work
// (WP9); response headers belong to the renderer (WP6).
package web
// druse:file application

// Header_View is the framework-owned view of the request headers.
//
// It is ENCAPSULATED BY CONTRACT, not opaque. Odin offers no opacity: this
// type is a public struct with a public field, and its contents stay reachable
// through that field. `Header_View_Internal` and `Header_Pair` cannot be NAMED
// outside the package, which is a different and weaker property than
// inaccessibility (ADR-008, "Scope of the guarantee"). Reaching into the
// internal slot compiles; it is simply not a supported path, and nothing in
// the framework promises the representation will stay as it is.
//
// The internal slot exists precisely so the representation stays unpromised.
// Announcing `pairs: []Header_Pair` as a public field would freeze the
// pair-array layout into the public API — the layout this wrapper exists to
// keep private — and would export `Header_Pair` with it.
//
// LIFETIME: every name and value is a view over transport-owned storage, valid
// only during the request. Copy explicitly to persist (planning/public-api-guardrails.md G-05).
Header_View :: struct {
	private: Header_View_Internal,
}

// Header_View_Internal is package-private: application code cannot NAME this
// type. It is encapsulated BY CONTRACT, not by the compiler — Odin has no
// per-field privacy, and fields stay reachable through a public field. Do not
// rely on this for safety guarantees (ADR-008, "Scope of the guarantee").
//
// Phase 1 stores an ordered array of pairs and nothing else: there is no index,
// no map and no normalization table, because Phase 1 performs no lookup.
@(private)
Header_View_Internal :: struct {
	pairs: []Header_Pair,
}

// Header_Pair is package-private: it is NOT part of the public API, and no
// public procedure accepts or returns it. Both fields are views over
// transport-owned storage for the duration of one request.
@(private)
Header_Pair :: struct {
	name:  string,
	value: string,
}

// header_view_from_pairs wraps caller-supplied pairs in a Header_View.
//
// Package-internal: a transport adapter (WP8) builds the pair array over its
// own request buffer and hands it in. This procedure ALLOCATES NOTHING and
// COPIES NOTHING: the returned view aliases `pairs`, and `pairs` itself
// aliases the caller's buffer. Ownership stays with the caller, and the view
// is invalidated the moment that storage is reused.
@(private)
header_view_from_pairs :: proc(pairs: []Header_Pair) -> Header_View {
	return Header_View{private = Header_View_Internal{pairs = pairs}}
}
