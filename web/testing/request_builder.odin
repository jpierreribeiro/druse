// WP3 — IN-MEMORY TEST TRANSPORT MACHINERY (package `testing`).
//
// This package is the machinery behind `web.test_request`. It is UNSUPPORTED
// INTERNALS by contract (planning/public-api-guardrails.md G-11): it is not a second public API, it
// is not documented for direct import, and applications call `web.test_request`,
// never `testing.*`.
//
// It is NEUTRAL: it names no `web` type. That is what keeps the dependency
// one-way — `web` imports `web/testing`, never the reverse (the back-edge is a
// compile cycle, ratified as probe C5). It imports only `core:` packages and
// never `core:testing`; the machinery ships in application binaries exactly like
// `web/`, so it must not drag the test runner in.
package web_testing
// druse:file test-machinery

// Request is the neutral, in-memory inbound request the facade hands to the
// transport. `method` is the on-the-wire method TOKEN (e.g. "GET"); `path` is
// the request path. Both are VIEWS, valid only for the duration of the
// synchronous `web.test_request` call — the machinery copies nothing here, and
// the facade converts them into a framework `Request`/`Context` immediately.
//
// There is deliberately no `web.Method` and no `web.Request` in this struct:
// naming either would require importing `druse:web` and would close the cycle.
Request :: struct {
	method: string,
	path:   string,
}

// build_request constructs the neutral inbound request for one exchange. It
// allocates nothing and retains nothing: the returned views alias the caller's
// strings for the synchronous call only.
build_request :: proc(method: string, path: string) -> Request {
	return Request{method = method, path = path}
}
