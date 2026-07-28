// WP67 internal RED contract: allocator/decoder failure must fail closed.
#+private
package web

import "core:mem"
import "core:testing"

Wp67_Allocated_Input :: struct {
	name: string   `json:"name"`,
	tags: []string `json:"tags"`,
}

@(test)
wp67_decoder_allocation_failure_must_not_return_success_with_zero_values :: proc(t: ^testing.T) {
	ctx: Context
	defer request_arena_destroy(&ctx)
	ctx.request.body = transmute([]u8)string(`{"name":"a\\nb","tags":["x","y"]}`)
	// The 500 is the expected outcome under test; suppress its expected Error
	// diagnostic so core:testing does not count the log record as a test error.
	//
	// THE SCOPE IS THE POINT, and it used to be wrong. The restore was `defer`red,
	// so the nil logger stayed installed for the REST OF THE TEST — including
	// every assertion below. `testing.expect*` reports a failure by calling
	// `log.errorf` through `context.logger`, so all three assertions were
	// unreportable and this suite could not fail. Measured: a deliberately
	// impossible assertion here passed. Same defect as the one found in
	// `tests/wp9-wire`, in a different shape.
	//
	// The nil ALLOCATOR is restored on the same line for a second reason: a
	// failing `expect_value` formats its message, and formatting under
	// `mem.nil_allocator` is its own way to lose a failure.
	previous_logger := context.logger
	previous_allocator := context.allocator

	// The pinned stdlib currently returns err=nil and zeroes when allocations
	// fail. The framework must detect or avoid that path; a successful bind with
	// empty values is data corruption, not graceful degradation.
	context.logger = {}
	context.allocator = mem.nil_allocator()
	dst: Wp67_Allocated_Input
	ok := body(&ctx, &dst)
	context.logger = previous_logger
	context.allocator = previous_allocator

	testing.expect(t, !ok, "allocation failure must fail the bind")
	testing.expect_value(t, ctx.private.response.status, Status.Internal_Server_Error)
	testing.expect_value(
		t,
		string(ctx.private.response.body),
		`{"error":{"code":"internal_error","message":"Internal server error"}}`,
	)
}
