package wp71_validation

import "core:testing"
import web "druse:web"

@(private)
ok :: proc(ctx: ^web.Context) {web.no_content(ctx)}

@(test)
max_handlers_is_a_bounded_field_on_limits :: proc(t: ^testing.T) {
	valid := web.DEFAULT_LIMITS
	testing.expect_value(t, valid.max_handlers, 0)
	valid.max_handlers = 1
	a := web.app()
	defer web.destroy(&a)
	web.limits(&a, valid)
	web.get(&a, "/", ok)
	testing.expect_value(t, web.test_request(&a, .GET, "/").status, web.Status.No_Content)

	invalid_values := [?]int{-1, 257}
	for invalid in invalid_values {
		bad := web.app()
		budget := web.DEFAULT_LIMITS
		budget.max_handlers = invalid
		previous_logger := context.logger
		context.logger = {}
		web.limits(&bad, budget)
		context.logger = previous_logger
		web.get(&bad, "/", ok)
		res := web.test_request(&bad, .GET, "/")
		testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
		web.destroy(&bad)
	}
}
