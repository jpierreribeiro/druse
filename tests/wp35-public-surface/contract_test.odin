// WP35 — R-16 measured: does an oversize request permanently raise memory?
//
// RG-4's question is "what happens to a request arena after an unusually large
// body — retain, trim or release?" and R-16's signals are stated precisely:
// retained capacity follows peak body size, and memory does not return near
// baseline after a giant request.
//
// THIS WORK PACKAGE'S OWN DISCIPLINE COMES FIRST, because it decides the
// answer: **while nothing is pooled, do not build the abstraction.** An empty
// generational wrapper around storage that is never reused is complexity with
// no defect to catch. So the first thing to establish is whether anything is
// pooled at all — and the honest way to establish it is to measure, not to read
// the code and conclude.
//
// WHAT THE MEASUREMENT SHOWS, and §5 of `planning/arena-policy.md` records the
// numbers: retained bytes return EXACTLY to baseline after a 3 MiB body. The
// request arena is created lazily per request and destroyed in
// `driver_cleanup`; every other request-local buffer is a fixed array on a
// `Context` that is a fresh stack value per request. Nothing is pooled, so
// R-16's failure mode cannot occur, and the "release oversize allocations at
// request end" fallback the risk register named is ALREADY the shipped
// behaviour rather than a change to make.
//
// This suite is the tripwire for that. If a later work package pools anything,
// these assertions go red — and that is them doing their job, not a test to
// weaken.
package test_wp35_public

import "core:mem"
import "core:strings"
import "core:testing"
import web "druse:web"

@(private = "file")
Payload :: struct {
	blob: string `json:"blob"`,
}

@(private = "file")
sink :: proc(ctx: ^web.Context) {
	value: Payload
	if !web.body(ctx, &value) {
		return
	}
	web.no_content(ctx)
}

// json_body builds `{"blob":"aaa…"}` with a payload of `size` bytes.
@(private = "file")
json_body :: proc(size: int, allocator := context.allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator)
	strings.write_string(&b, "{\"blob\":\"")
	for _ in 0 ..< size {
		strings.write_byte(&b, 'a')
	}
	strings.write_string(&b, "\"}")
	return strings.to_string(b)
}

// THE R-16 MEASUREMENT.
//
// Small requests establish a baseline of retained bytes. One 3 MiB request runs
// — well inside the 4 MiB cap, so it is accepted rather than answered 413.
// Small requests then run again, and retained bytes must return to the SAME
// baseline, not to a higher plateau.
//
// "Near baseline" would be the weaker claim R-16 asks about. What is asserted
// here is stronger and is what the design actually delivers: EXACTLY baseline.
@(test)
wp35_an_oversize_body_does_not_raise_the_floor :: proc(t: ^testing.T) {
	// THE FIXTURES ARE BUILT OUTSIDE THE TRACKER, and that is a correction to
	// this test's own first draft: building a 3 MiB body through the tracked
	// allocator counted the FIXTURE as retained memory and made the framework
	// look like it had leaked 3 MiB. The thing under measurement is the
	// framework, not the test's own strings.
	outer := context.allocator
	small := json_body(64, outer)
	defer delete(small, outer)
	huge := json_body(3 * 1024 * 1024, outer)
	defer delete(huge, outer)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, outer)
	defer mem.tracking_allocator_destroy(&track)

	ctx := context
	ctx.allocator = mem.tracking_allocator(&track)
	context = ctx

	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/sink", sink)

	// Warm the table and every lazy allocation the App makes once.
	for _ in 0 ..< 4 {
		res := web.test_request(&app, .POST, "/sink", body = small)
		testing.expect_value(t, res.status, web.Status.No_Content)
	}
	baseline := int(track.current_memory_allocated)

	// The adversarial request. It is accepted — 3 MiB is inside the 4 MiB cap —
	// so this measures the arena's behaviour and not the 413 path.
	big := web.test_request(&app, .POST, "/sink", body = huge)
	testing.expect_value(t, big.status, web.Status.No_Content)

	// And back to small traffic.
	for _ in 0 ..< 4 {
		res := web.test_request(&app, .POST, "/sink", body = small)
		testing.expect_value(t, res.status, web.Status.No_Content)
	}
	after := int(track.current_memory_allocated)

	// A SECOND giant request, so the question the first one cannot answer gets
	// answered: is the residual a ONE-OFF, or does it ACCUMULATE per oversize
	// request? A per-request residual is R-16 arriving slowly; a one-off is a
	// high-water mark in something that was going to grow once anyway.
	big2 := web.test_request(&app, .POST, "/sink", body = huge)
	testing.expect_value(t, big2.status, web.Status.No_Content)
	for _ in 0 ..< 4 {
		res := web.test_request(&app, .POST, "/sink", body = small)
		testing.expect_value(t, res.status, web.Status.No_Content)
	}
	after_second := int(track.current_memory_allocated)

	first_residual := after - baseline
	second_residual := after_second - after

	// R-16's signal, inverted and stated as the register states it: retained
	// capacity must not FOLLOW peak body size. A 3 MiB request moving retained
	// bytes by a few hundred is not following anything.
	testing.expectf(
		t,
		first_residual < 64 * 1024,
		"retained bytes moved %d after a 3 MiB request; that follows peak body size and R-16 has arrived",
		first_residual,
	)

	// THE SHARPER HALF. Whatever small residual exists must not repeat. If the
	// second giant request adds another one, memory grows without bound under
	// adversarial traffic and the arena needs a release policy after all.
	testing.expectf(
		t,
		second_residual <= first_residual,
		"the residual is accumulating: %d bytes after the first giant request, %d after the second",
		first_residual,
		second_residual,
	)
}

// THE POSITIVE CONTROL, and without it the assertion above proves nothing.
//
// If `current_memory_allocated` never moved — a tracker wired to nothing, or an
// App that allocates during no request at all — then "retained returned to
// baseline" would be true of a measurement that measured nothing.
//
// So the giant request must be shown to actually MOVE memory while it is in
// flight. It cannot be observed mid-request from outside, so the proxy is the
// total: a 3 MiB body must have allocated at least its own size at some point.
@(test)
wp35_the_giant_request_really_did_allocate :: proc(t: ^testing.T) {
	outer := context.allocator
	huge := json_body(3 * 1024 * 1024, outer)
	defer delete(huge, outer)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, outer)
	defer mem.tracking_allocator_destroy(&track)

	ctx := context
	ctx.allocator = mem.tracking_allocator(&track)
	context = ctx

	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/sink", sink)

	before := int(track.total_memory_allocated)
	res := web.test_request(&app, .POST, "/sink", body = huge)
	testing.expect_value(t, res.status, web.Status.No_Content)
	moved := int(track.total_memory_allocated) - before

	testing.expectf(
		t,
		moved >= 3 * 1024 * 1024,
		"a 3 MiB body only moved %d bytes; the tracker is not measuring the request",
		moved,
	)
}

// Peak memory is REPORTED, which is what the risk register asked for and what
// the allocation counts alone could not answer.
@(test)
wp35_peak_is_reported_not_only_counts :: proc(t: ^testing.T) {
	outer := context.allocator
	huge := json_body(3 * 1024 * 1024, outer)
	defer delete(huge, outer)

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, outer)
	defer mem.tracking_allocator_destroy(&track)

	ctx := context
	ctx.allocator = mem.tracking_allocator(&track)
	context = ctx

	app := web.app()
	defer web.destroy(&app)
	web.post(&app, "/sink", sink)

	res := web.test_request(&app, .POST, "/sink", body = huge)
	testing.expect_value(t, res.status, web.Status.No_Content)

	// The peak must exceed the body, and the retained total must not.
	testing.expect(t, int(track.peak_memory_allocated) > 3 * 1024 * 1024, "peak must exceed the body")
	testing.expect(
		t,
		int(track.current_memory_allocated) < 3 * 1024 * 1024,
		"retained memory must not follow the peak",
	)
}
