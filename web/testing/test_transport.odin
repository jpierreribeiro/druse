// WP3 — TEST TRANSPORT: the in-memory transport an App owns for
// `web.test_request`.
//
// It is the machinery's "transport" object: it carries neutral requests in and
// records neutral responses out, with NO socket, port, or network syscall
// anywhere on its path (the package imports no networking package; the gate
// forbids it). It is created lazily on the first request — the zero value holds
// no allocation — and released by `web.destroy`.
//
// The dispatch step that turns a request into a response is performed by the
// FACADE, between building the request and capturing the response. It is not a
// stored callback or a frozen ABI: ADR-009 keeps the internal boundary
// conceptual and unfrozen, and doing the dispatch in the facade is exactly what
// lets this package stay neutral (it never has to name a `web` type).
package web_testing
// druse:file test-machinery

import "core:mem"

// Test_Transport is the App-owned in-memory transport state. `served` counts the
// exchanges recorded so far; `recorder` owns the response copies. Both are zero
// in an unused App, so `web.app()`/`web.bare()` allocate nothing.
Test_Transport :: struct {
	recorder: Recorder,
	served:   int,
}

// capture records one exchange's neutral response into transport-owned storage
// and returns the status verbatim plus a view over the owned body copy, valid
// until `destroy`. The explicit `allocator` is used for every owned copy.
capture :: proc(
	t: ^Test_Transport,
	allocator: mem.Allocator,
	status: int,
	body: []u8,
	headers: []Header,
) -> (int, string) {
	status_out, body_out := recorder_capture(&t.recorder, allocator, status, body, headers)
	t.served += 1
	return status_out, body_out
}

// destroy releases everything the transport owns, exactly once, and returns it
// to its zero state. It is a no-op for a transport that never recorded an
// exchange, and a second call is a safe no-op.
// WP49 — the last response's header lines, in `"Name: value"` wire form.
//
// A THIRD BRIDGE EXPORT, and the bridge is locked and exact in both directions
// (`check_public_api.sh`), so this is a deliberate widening rather than a
// convenience: the facade cannot reach into the recorder, and the machinery
// must not name a `web` type. Strings are the only vocabulary both sides
// already share.
last_headers :: proc(t: ^Test_Transport) -> []string {
	return recorder_last_lines(&t.recorder)
}

destroy :: proc(t: ^Test_Transport) {
	recorder_destroy(&t.recorder)
	t.served = 0
}
