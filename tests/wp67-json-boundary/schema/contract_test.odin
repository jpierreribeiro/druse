// WP67 RED contract owned for implementation by WP81, not WP68.
//
// The anatomy experiment proved core:encoding/json ignores both the `required`
// JSON option and validation tags. Keeping this in a separate package prevents
// WP68 from smuggling a validation framework into the decoder just to make one
// combined suite green.
package wp67_json_schema

import json "core:encoding/json"
import "core:testing"
import web "druse:web"

Create_User :: struct {
	name: string `json:"name,required"`,
	age:  int    `json:"age" validate:"min=0,max=130"`,
}

create_user :: proc(ctx: ^web.Context) {
	dst: Create_User
	if !web.body(ctx, &dst) {
		return
	}
	web.no_content(ctx)
}

expect_schema_error :: proc(t: ^testing.T, raw, code, field: string, loc := #caller_location) {
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/users", create_user)

	res := web.test_request(&a, .POST, "/users", raw)
	testing.expect_value(t, res.status, web.Status.Bad_Request, loc = loc)
	if len(res.body) == 0 {
		testing.expect(t, false, "schema failure must carry an error envelope", loc = loc)
		return
	}
	value, err := json.parse_string(res.body, .JSON, false, context.allocator)
	testing.expect_value(t, err, json.Error.None, loc = loc)
	if err != .None {
		return
	}
	defer json.destroy_value(value, context.allocator)
	root := value.(json.Object) or_else nil
	inner := root["error"].(json.Object) or_else nil
	testing.expect_value(t, string(inner["code"].(json.String) or_else ""), code, loc = loc)
	testing.expect_value(t, string(inner["field"].(json.String) or_else ""), field, loc = loc)
}

@(test)
wp67_an_explicitly_required_field_may_not_be_absent :: proc(t: ^testing.T) {
	expect_schema_error(t, `{"age":20}`, "missing_field", "name")
}

@(test)
wp67_a_declared_range_failure_is_an_invalid_field :: proc(t: ^testing.T) {
	expect_schema_error(t, `{"name":"Ada","age":200}`, "invalid_field", "age")
}
