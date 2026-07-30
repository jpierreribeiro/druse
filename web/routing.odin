// WP4 — ROUTE REGISTRATION: the five public Phase-1 registration procedures.
//
// Each one is a single delegation to the package-private `route_register`
// (web/dispatch_table.odin), so there is exactly one place where a route is
// cloned, classified and stored. Matching and dispatch live in
// web/dispatch_match.odin.
//
// Route groups (`router`, `group`, `mount`) and middleware (`use`, `next`) are
// Phase 2 and are deliberately absent.
package web
// druse:file application

// get registers a handler for GET requests matching `pattern`.
//
// `pattern` is a route pattern such as "/users" or "/users/:id", not a concrete
// request path. It must begin with `/`; `/` itself is a valid pattern; a
// `:param` occupies exactly one whole path segment, and the Phase-1 dispatcher
// supports at most one per pattern. There is no wildcard.
//
// OWNERSHIP: `pattern` is COPIED. The App owns its copy until `destroy`, so the
// caller may reuse or free its own storage immediately after registering.
//
// MATCHING: paths are compared segment by segment, with NO normalization —
// `/users` and `/users/` are different patterns, and percent-encoding and dot
// segments are not decoded. A static route always wins over a parametric one
// that also matches, regardless of which was registered first. Registration
// conflicts are not diagnosed in Phase 1; that, and the normalization policy,
// belong to Phase 3.
get :: proc(a: ^App, pattern: string, handler: Handler) {
	route_register(a, .GET, pattern, handler)
}

// post registers a handler for POST requests matching `pattern`. See `get` for
// the pattern, ownership and matching rules.
post :: proc(a: ^App, pattern: string, handler: Handler) {
	route_register(a, .POST, pattern, handler)
}

// put registers a handler for PUT requests matching `pattern`. See `get`.
put :: proc(a: ^App, pattern: string, handler: Handler) {
	route_register(a, .PUT, pattern, handler)
}

// patch registers a handler for PATCH requests matching `pattern`. See `get`.
patch :: proc(a: ^App, pattern: string, handler: Handler) {
	route_register(a, .PATCH, pattern, handler)
}

// delete registers a handler for DELETE requests matching `pattern`. See `get`.
delete :: proc(a: ^App, pattern: string, handler: Handler) {
	route_register(a, .DELETE, pattern, handler)
}
