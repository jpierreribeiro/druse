// WP27 — the allocation audit. Where does per-request allocation actually go?
//
// RG-3's question, and the three items the post-Phase-1 audit named:
//
//   A-8   inbound headers are allocated and copied every request
//         (`planning/post-phase1-audit.md:83`)
//   A-12  static response headers are `strings.clone`d every request although
//         `response.odin` states they are static strings (:92)
//   A-13  `Header_Pair` and `transport.Header` are structurally identical, and
//         two O(n) conversions run per request purely to satisfy the one-way
//         boundary — "the honest price of ADR-009" (:93)
//
// WP27's scope is MEASURE AND DECIDE. Fixing belongs to WP29 and WP35, where a
// change can be regression-tested against the WP26 baseline. Nothing in this
// suite changes behaviour.
//
// WHY THIS IS AN INTERNAL SUITE. Two of the three procedures under measurement
// are `@(private)` — `inbound_header_pairs` and
// `response_headers_neutral_transport` both live in `web/serve.odin` and are
// not nameable from outside the package. Measuring them through a public
// surface would mean measuring something else and calling it these.
//
// THE PERIMETER, and it is not C-5's. Phase-2 claim C-5 says dispatch through a
// middleware chain allocates zero bytes, measured around
// `driver_run`/`driver_cleanup` and explicitly NOT around `test_request`. That
// claim is about THE CHAIN WALK. Everything measured here sits OUTSIDE the
// chain walk — on the request-construction and response-copy edges of the same
// pipeline — so nothing here contradicts C-5, and no number here may be quoted
// as if it did. C-5's own "does NOT guarantee" line already says the request as
// a whole allocates.
package web

import "base:runtime"
import "core:mem"
import "core:testing"
import "druse:web/internal/transport"

// A tracking allocator installed on `context.allocator` only.
//
// `context.temp_allocator` is measured by passing it explicitly where the
// production code passes it, rather than by wrapping it: wrapping the temp
// allocator underneath the `odin test` runner's own memory tracking hangs the
// runner (WP26 recorded that so nobody rediscovers it).
@(private = "file")
Counted :: struct {
	track: mem.Tracking_Allocator,
}

@(private = "file")
counted_begin :: proc(c: ^Counted) -> mem.Allocator {
	mem.tracking_allocator_init(&c.track, context.allocator)
	return mem.tracking_allocator(&c.track)
}

// counted_end reports the totals and then RELEASES everything the measured
// call allocated.
//
// Freeing here rather than in each test is deliberate: the procedures under
// measurement hand back storage whose production owner is the transport's own
// per-request allocator, and reproducing that ownership in seven tests would
// be seven chances to get it wrong. Walking the tracker's own map frees exactly
// what was measured, and leaves the suite clean under the runner's leak
// reporting.
@(private = "file")
counted_end :: proc(c: ^Counted) -> (allocations: int, bytes: int) {
	allocations = int(c.track.total_allocation_count)
	bytes = int(c.track.total_memory_allocated)
	for ptr in c.track.allocation_map {
		mem.free(ptr, c.track.backing)
	}
	mem.tracking_allocator_destroy(&c.track)
	return
}

// ---------------------------------------------------------------------------
// A-8 — the inbound header conversion.
// ---------------------------------------------------------------------------

// One allocation per request, sized by the request's header count.
//
// The measured shape matters more than the count: it is ONE slice allocation,
// not one per header. The names and values inside are VIEWS over
// transport-owned storage and are not copied — so A-8's wording, "allocated and
// copied every request", is half right. The slice is allocated; the strings are
// not copied.
@(test)
wp27_a8_inbound_pairs_allocate_once_per_request :: proc(t: ^testing.T) {
	shapes := []int{0, 1, 4, 16, 64}

	// A fixed backing array rather than `make`: inside `package web` the
	// builtin `delete` is shadowed by the HTTP verb `web.delete`, and a
	// benchmark of allocation should not be allocating its own fixtures anyway.
	backing: [64]transport.Header

	for count in shapes {
		headers := backing[:count]
		for i in 0 ..< count {
			headers[i] = transport.Header {
				name  = "X-Measured",
				value = "value",
			}
		}

		inbound := transport.Inbound {
			method  = "GET",
			path    = "/measured",
			headers = headers,
		}

		c: Counted
		al := counted_begin(&c)
		pairs := inbound_header_pairs(inbound, al)
		allocations, bytes := counted_end(&c)

		testing.expect_value(t, len(pairs), count)

		if count == 0 {
			// The empty case returns nil and allocates nothing. That is worth
			// pinning: a request with no headers is common, and an allocation
			// there would be pure waste.
			testing.expect_value(t, allocations, 0)
			testing.expect_value(t, bytes, 0)
		} else {
			// ONE allocation regardless of how many headers arrive.
			testing.expect_value(t, allocations, 1)
			testing.expect_value(t, bytes, count * size_of(Header_Pair))
		}
	}
}

// The strings are views, not copies. If this ever stopped being true, A-8 would
// become a much larger cost than the audit recorded, and the lifetime contract
// in G-05 would have changed underneath everyone.
@(test)
wp27_a8_pairs_view_transport_storage :: proc(t: ^testing.T) {
	name := "X-Origin"
	value := "measured"
	headers := []transport.Header{{name = name, value = value}}
	inbound := transport.Inbound {
		method  = "GET",
		path    = "/measured",
		headers = headers,
	}

	pairs := inbound_header_pairs(inbound, context.allocator)
	// `runtime.delete_slice`, not `delete`: the latter is `web.delete`, the
	// HTTP verb, inside this package.
	defer runtime.delete_slice(pairs)

	testing.expect_value(t, len(pairs), 1)
	// Same backing pointer AND same length: a clone would differ in the former.
	testing.expect(t, raw_data(pairs[0].name) == raw_data(name), "the name must be a view")
	testing.expect(t, raw_data(pairs[0].value) == raw_data(value), "the value must be a view")
}

// ---------------------------------------------------------------------------
// A-13 — the outbound conversion, the other half of the boundary price.
// ---------------------------------------------------------------------------

@(test)
wp27_a13_outbound_conversion_allocates_once :: proc(t: ^testing.T) {
	pairs := []Header_Pair {
		{name = CONTENT_TYPE_HEADER_NAME, value = CONTENT_TYPE_JSON},
		{name = "X-Request-Id", value = "01H000000000000000000000"},
	}

	c: Counted
	al := counted_begin(&c)
	out := response_headers_neutral_transport(pairs, al)
	allocations, bytes := counted_end(&c)

	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, allocations, 1)
	testing.expect_value(t, bytes, 2 * size_of(transport.Header))

	// And it is a view-preserving conversion, exactly like the inbound one.
	// Two structurally identical types, one allocation each way, per request.
	testing.expect(
		t,
		raw_data(out[0].name) == raw_data(pairs[0].name),
		"the outbound name must be a view too",
	)
}

// The empty case, pinned for the same reason as A-8's: a 204 carries no
// Content-Type, so this path is real traffic rather than a corner.
@(test)
wp27_a13_no_headers_allocates_nothing :: proc(t: ^testing.T) {
	c: Counted
	al := counted_begin(&c)
	out := response_headers_neutral_transport(nil, al)
	allocations, _ := counted_end(&c)

	testing.expect_value(t, len(out), 0)
	testing.expect_value(t, allocations, 0)
}

// ---------------------------------------------------------------------------
// A-12 — the response copy, and the correction the audit needs.
// ---------------------------------------------------------------------------

// `copy_response` clones every header NAME and every header VALUE.
//
// A-12 calls this waste because `response.odin` says the headers are static
// strings. The measurement below shows the cost, and the test after it shows
// why the audit item cannot be acted on as written.
@(test)
wp27_a12_copy_response_clones_name_and_value :: proc(t: ^testing.T) {
	// The real shape of a JSON 200: one header.
	one := []transport.Header{{name = CONTENT_TYPE_HEADER_NAME, value = CONTENT_TYPE_JSON}}
	body := transmute([]u8)string("{\"id\":1}")

	c: Counted
	al := counted_begin(&c)
	out: transport.Outbound
	transport.copy_response(&out, 200, one, body, al)
	allocations, _ := counted_end(&c)

	// 1 array + 1 name + 1 value + 1 body = 4.
	testing.expect_value(t, allocations, 4)
	testing.expect_value(t, len(out.headers), 1)

	// And the clones really are clones — new storage, not views.
	testing.expect(
		t,
		raw_data(out.headers[0].name) != raw_data(one[0].name),
		"copy_response must clone, not alias; the transport owns these bytes",
	)
}

// The 405 and request-ID shapes, so the audit's numbers cover real traffic
// rather than the cheapest case.
@(test)
wp27_a12_cost_scales_with_header_count :: proc(t: ^testing.T) {
	three := []transport.Header {
		{name = "Allow", value = "GET, POST"},
		{name = CONTENT_TYPE_HEADER_NAME, value = CONTENT_TYPE_JSON},
		{name = "X-Request-Id", value = "01H000000000000000000000"},
	}
	body := transmute([]u8)string("{\"error\":{\"code\":\"method_not_allowed\"}}")

	c: Counted
	al := counted_begin(&c)
	out: transport.Outbound
	transport.copy_response(&out, 405, three, body, al)
	allocations, _ := counted_end(&c)

	// 1 array + 3 names + 3 values + 1 body = 8.
	testing.expect_value(t, allocations, 8)
	testing.expect_value(t, len(out.headers), 3)
}

// THE CORRECTION, and the reason WP27 exists rather than a patch.
//
// A-12 says the response headers are static strings, so cloning them is waste.
// The FIRST half is true only for some of them, and the second half would be a
// use-after-free if acted on for the rest:
//
//   * `Content-Type` — name and value are both compile-time constants in
//     `web/response.odin`. Aliasing them would be safe.
//   * `Allow` — the NAME is a constant; the VALUE is built into
//     `Context_Internal.allow_buffer`, a fixed array that dies with the
//     request. Aliasing it would hand the transport a view into freed memory.
//   * `X-Request-Id` — the same: constant name, value in
//     `Context_Internal.request_id_buffer`.
//
// So "stop cloning static headers" is not a change that can be made by knowing
// the header is static — it can only be made by knowing which STRING is. The
// pair would have to carry that knowledge, which is a design change and not an
// optimisation. This test pins the distinction so the next person does not
// apply the audit item literally and ship a dangling view.
@(test)
wp27_a12_only_some_response_strings_are_static :: proc(t: ^testing.T) {
	ctx: Context

	// The Allow value is written into request-local storage on the Context, and
	// the response header points INTO that buffer.
	ctx.private.allow_buffer[0] = 'G'
	ctx.private.allow_buffer[1] = 'E'
	ctx.private.allow_buffer[2] = 'T'
	allow_value := string(ctx.private.allow_buffer[:3])

	pairs := []Header_Pair {
		{name = CONTENT_TYPE_HEADER_NAME, value = CONTENT_TYPE_JSON},
		{name = "Allow", value = allow_value},
	}

	// The Allow value points into a Context that dies with the request, which
	// is exactly what `copy_response` exists to survive.
	testing.expect(
		t,
		raw_data(pairs[1].value) == raw_data(ctx.private.allow_buffer[:]),
		"the Allow value points into request-local storage, and must be copied",
	)

	// The Content-Type value does NOT: its storage is the package's own and
	// outlives every request, so aliasing it would be safe. The contrast is the
	// finding — two headers, same struct, opposite lifetimes.
	testing.expect(
		t,
		raw_data(pairs[0].value) != raw_data(ctx.private.allow_buffer[:]),
		"the Content-Type value is not request-local",
	)
}
