// M6's premise, provoked rather than waited for.
//
//   "Unchecked on request-hot paths: `copy_response`'s `make`/`clone`,
//    `neutral_headers`, ingest's `strings.concatenate`, `mp_init`. A failed
//    allocation yields a nil slice and an index panic that kills the process."
//
// An allocation failure cannot be observed by hoping for one. This wraps an
// allocator so that the Nth allocation fails, which turns "what happens under
// memory pressure" from a thought experiment into a test.
//
// WHY IT MATTERS HERE RATHER THAN IN GENERAL. Two findings measured earlier in
// this audit make the pressure reachable: J3 peaked at 588 MB of RSS for one
// in-limit request, and M9 measured GB-scale retention across idle keep-alive
// connections. So the question is not whether allocation can fail — it is what
// this framework does on the RESPONSE path when it does, after the handler has
// already produced an answer.
package test_m6_allocation_failure

import "core:mem"
import "core:mem/virtual"
import "core:testing"
import transport "uruquim:web/internal/transport"

// Fails the Nth and every later allocation, delegating the rest.
Failing :: struct {
	backing: mem.Allocator,
	allowed: int,
	seen:    int,
}

failing_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	f := (^Failing)(allocator_data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		f.seen += 1
		if f.seen > f.allowed {
			return nil, .Out_Of_Memory
		}
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, location)
}

failing_allocator :: proc(f: ^Failing) -> mem.Allocator {
	return mem.Allocator{procedure = failing_proc, data = rawptr(f)}
}

// Fails only allocations of `min_size` bytes or more, serving everything
// smaller. A blunt fail-everything allocator cannot tell whether each guard is
// load-bearing: with all allocations failing, a later `clone` check bails
// before an earlier unchecked `make` can be indexed, so removing the `make`
// guard looks harmless when it is not. Real allocators fragment — they refuse a
// large contiguous array while still serving small strings — and that is the
// case that reaches the nil index.
Size_Failing :: struct {
	backing:  mem.Allocator,
	min_size: int,
}

size_failing_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	f := (^Size_Failing)(allocator_data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if size >= f.min_size {
			return nil, .Out_Of_Memory
		}
	}
	return f.backing.procedure(f.backing.data, mode, size, alignment, old_memory, old_size, location)
}

size_failing_allocator :: proc(f: ^Size_Failing) -> mem.Allocator {
	return mem.Allocator{procedure = size_failing_proc, data = rawptr(f)}
}

@(test)
m6_copy_response_survives_allocation_failure :: proc(t: ^testing.T) {
	headers := []transport.Header {
		{name = "content-type", value = "application/json"},
		{name = "x-request-id", value = "0123456789abcdef"},
	}
	body := transmute([]u8)string(`{"ok":true}`)

	// THE RED EVIDENCE, for anyone reading this later. Before the fix, with the
	// budget at 0, this call did not return:
	//
	//	odin_http_adapter.odin(1078:11) Index 0 is out of range 0..<0
	//	Signal caught: Illegal_Instruction
	//
	// Odin's `make` yields a NIL slice on failure rather than raising, and the
	// loop below it indexed that nil. ADR-020 has no recoverable panic, so that
	// was the whole process — every in-flight request on every lane — lost to
	// one failed `make`, on the RESPONSE path, after the handler had already
	// produced an answer.
	// ARENA-BACKED ON PURPOSE, and the reason is a real constraint on the fix.
	// The degradation ABANDONS whatever it had already allocated rather than
	// unwinding it — that is what makes the fallback itself allocation-free.
	// It is safe only because this path's allocator is arena-backed in
	// production (`serve.odin` hands the transport's per-request arena, freed
	// wholesale at request end). Backed by the heap instead, the abandoned
	// header clones would leak, and the memory tracker says so loudly.
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)

	f := Failing{backing = virtual.arena_allocator(&arena), allowed = 0}
	out: transport.Outbound
	transport.copy_response(&out, 200, headers, body, failing_allocator(&f))

	testing.expectf(
		t,
		out.status == 500,
		"an exhausted allocator must degrade to a bare 500, not publish a partial response; got status %d",
		out.status,
	)
	testing.expect(t, len(out.headers) == 0, "no half-built header list may be published")
	testing.expect(t, len(out.body) == 0, "no body may be published beside the fallback status")
	testing.expect(
		t,
		out.suppressed_body_len == 0,
		"the abandoned response's length must not be announced beside an empty 500 — that is a Content-Length that disagrees with the bytes",
	)
}

// The budget is walked so the failure lands at each allocation in turn: the
// header array, then a name clone, then a value clone, then the body clone. A
// fix that guarded only the first `make` would pass the test above and die on
// any of the rest.
@(test)
m6_every_allocation_in_copy_response_is_guarded :: proc(t: ^testing.T) {
	headers := []transport.Header {
		{name = "content-type", value = "application/json"},
		{name = "x-request-id", value = "0123456789abcdef"},
	}
	body := transmute([]u8)string(`{"ok":true}`)

	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)

	for budget in 0 ..< 8 {
		f := Failing{backing = virtual.arena_allocator(&arena), allowed = budget}
		out: transport.Outbound
		transport.copy_response(&out, 200, headers, body, failing_allocator(&f))

		// Either it completed (budget was enough) or it degraded. Never a
		// partial publish, and never a crash — reaching this line at all is
		// most of the assertion.
		if out.status == 200 {
			testing.expectf(
				t,
				len(out.headers) == len(headers) && len(out.body) == len(body),
				"budget %d completed but published a PARTIAL response: %d headers, %d body bytes",
				budget,
				len(out.headers),
				len(out.body),
			)
		} else {
			testing.expectf(
				t,
				out.status == 500 && len(out.headers) == 0 && len(out.body) == 0,
				"budget %d degraded to status %d with %d headers and %d body bytes; the fallback must be a bare 500",
				budget,
				out.status,
				len(out.headers),
				len(out.body),
			)
		}
	}
}

// THE CONTROL FOR THE `make` GUARD SPECIFICALLY.
//
// Written after discovering that removing that guard did NOT turn the tests
// above red: under an allocator that fails everything, the `strings.clone`
// check bails out before the nil header array is ever indexed. That made the
// `make` guard look redundant. It is not — it only looked that way because the
// instrument could not produce the case that needs it.
//
// Here the allocator refuses the header ARRAY (two `Header` structs, well over
// 32 bytes) while happily serving the small name and value clones. That is a
// fragmented heap, and it is the shape that reaches `copied[i]` on a nil slice.
// With the `make` guard removed this test dies with
// "Index 0 is out of range 0..<0"; with it, a clean 500.
@(test)
m6_the_header_array_guard_is_load_bearing :: proc(t: ^testing.T) {
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)

	headers := []transport.Header {
		{name = "ct", value = "json"},
		{name = "id", value = "abc"},
	}

	f := Size_Failing{backing = virtual.arena_allocator(&arena), min_size = 32}
	out: transport.Outbound
	transport.copy_response(&out, 200, headers, transmute([]u8)string("hi"), size_failing_allocator(&f))

	testing.expectf(
		t,
		out.status == 500 && len(out.headers) == 0,
		"a refused header ARRAY with a heap still serving small clones must degrade, not index a nil slice; got status %d with %d headers",
		out.status,
		len(out.headers),
	)
}
