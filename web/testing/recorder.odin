// WP3 — RECORDER: owned copies of the captured response, and their cleanup.
//
// The recorder is the reason a `web.Recorded_Response` outlives the request. It
// copies status/body/headers out of the framework's transient storage into
// memory it OWNS, so a returned response never aliases a buffer the next request
// reuses. Everything it allocates is released, exactly once, by `destroy`
// (web/testing/test_transport.odin), which `web.destroy(&app)` calls.
//
// Ownership is explicit and verifiable: the caller supplies the allocator, the
// recorder stores it, and every copy is made with it. `temp_allocator` is never
// used for data a `Recorded_Response` returns.
package web_testing
// druse:file test-machinery

import "core:mem"
import "core:strings"

// Header is a neutral header pair. The facade converts the framework's private
// header representation into a slice of these before handing them to the
// recorder, so the machinery never names a `web` type. Both fields are copied
// into owned storage by `recorder_capture`.
Header :: struct {
	name:  string,
	value: string,
}

// Recorded is one recorded response, with OWNED copies of body and headers.
// Private: no consumer outside this package (not even the facade) names it.
@(private)
Recorded :: struct {
	status:  int,
	body:    string,
	headers: []Header,
	// WP49 — the same headers in wire form, so the facade can return them
	// without naming a machinery type.
	lines:   []string,
}

// Recorder is the App-owned test-support storage. It is LAZY: the zero value is
// inactive and holds no allocation, so an application that never calls
// `test_request` allocates nothing. Private: the facade embeds it inside
// `Test_Transport` but never names it.
@(private)
Recorder :: struct {
	allocator: mem.Allocator,
	records:   [dynamic]Recorded,
	active:    bool,
}

// recorder_ensure performs the lazy first-use initialization. It is a no-op
// after the first call, and it never runs for an unused recorder.
@(private)
recorder_ensure :: proc(r: ^Recorder, allocator: mem.Allocator) {
	if r.active {
		return
	}
	r.allocator = allocator
	r.records = make([dynamic]Recorded, allocator)
	r.active = true
}

// recorder_capture copies status/body/headers into recorder-owned storage and
// returns the status verbatim plus a view over the OWNED body copy. The
// returned string stays valid until `recorder_destroy`. Mutating or reusing the
// source `body`/`headers` after this call does not change what was recorded.
@(private)
recorder_capture :: proc(
	r: ^Recorder,
	allocator: mem.Allocator,
	status: int,
	body: []u8,
	headers: []Header,
) -> (int, string) {
	recorder_ensure(r, allocator)

	body_copy := strings.clone_from_bytes(body, r.allocator)

	headers_copy := make([]Header, len(headers), r.allocator)
	for h, i in headers {
		headers_copy[i] = Header {
			name  = strings.clone(h.name, r.allocator),
			value = strings.clone(h.value, r.allocator),
		}
	}

	// WP49 — the wire-form lines the facade hands back. Built HERE, beside the
	// pairs they come from, so the facade never has to name a `Header` type:
	// the machinery owns the representation and exports strings, which is the
	// one-way dependency this package exists to keep (WP3, probe C5).
	lines_copy := make([]string, len(headers_copy), r.allocator)
	for h, i in headers_copy {
		lines_copy[i] = strings.concatenate({h.name, ": ", h.value}, r.allocator)
	}

	append(
		&r.records,
		Recorded{status = status, body = body_copy, headers = headers_copy, lines = lines_copy},
	)
	return status, body_copy
}

// recorder_last_lines returns the header lines of the most recent record, or
// nil. Views into recorder-owned storage, valid until `recorder_destroy`.
@(private)
recorder_last_lines :: proc(r: ^Recorder) -> []string {
	if !r.active || len(r.records) == 0 {
		return nil
	}
	return r.records[len(r.records) - 1].lines
}

// recorder_destroy releases every recorded copy exactly once and returns the
// recorder to its inactive zero state. It is a no-op for a recorder that was
// never used, and a second call is a safe no-op (no double free).
@(private)
recorder_destroy :: proc(r: ^Recorder) {
	if !r.active {
		return
	}
	for rec in r.records {
		delete(rec.body, r.allocator)
		for h in rec.headers {
			delete(h.name, r.allocator)
			delete(h.value, r.allocator)
		}
		for line in rec.lines {
			delete(line, r.allocator)
		}
		delete(rec.lines, r.allocator)
		delete(rec.headers, r.allocator)
	}
	delete(r.records)
	r.records = nil
	r.active = false
}
