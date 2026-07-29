// WP67 disposable anatomy probe. Nothing under web/ may import this package.
package json_failure_anatomy

import json "core:encoding/json"
import "core:fmt"
import "core:mem"
import web "druse:web"

Address :: struct {
	number: int `json:"number"`,
}

Input :: struct {
	name:    string  `json:"name,required"`,
	age:     int     `json:"age" validate:"min=0,max=130"`,
	address: Address `json:"address"`,
	tags:    []string `json:"tags"`,
}

Unsupported :: struct {
	callback: proc() `json:"callback"`,
}

bind_input :: proc(ctx: ^web.Context) {
	dst: Input
	if !web.body(ctx, &dst) {
		return
	}
	web.no_content(ctx)
}

bind_unsupported :: proc(ctx: ^web.Context) {
	dst: Unsupported
	if !web.body(ctx, &dst) {
		return
	}
	web.no_content(ctx)
}

print_case :: proc(a: ^web.App, name, path, body: string) {
	res := web.test_request(a, .POST, path, body)
	fmt.printf("%-24s status=%d body=%s\n", name, int(res.status), res.body)
}

print_decoder_error :: proc(name, body: string) {
	dst: Input
	err := json.unmarshal_string(body, &dst, .JSON)
	fmt.printf("decoder %-16s err=%#v\n", name, err)
}

print_allocator_error :: proc() {
	dst: Input
	err := json.unmarshal_string(`{"name":"a\\nb","tags":["x","y"]}`, &dst, .JSON, mem.nil_allocator())
	fmt.printf(
		"decoder %-16s err=%#v name=%q tags=%#v\n",
		"nil allocator",
		err,
		dst.name,
		dst.tags,
	)
}

main :: proc() {
	a := web.app()
	defer web.destroy(&a)
	web.post(&a, "/input", bind_input)
	web.post(&a, "/unsupported", bind_unsupported)

	print_case(&a, "malformed", "/input", `{`)
	print_case(&a, "wrong scalar", "/input", `{"age":"old"}`)
	print_case(&a, "nested mismatch", "/input", `{"address":{"number":"x"}}`)
	print_case(&a, "unknown field", "/input", `{"surprise":true}`)
	print_case(&a, "required absent", "/input", `{"age":20}`)
	print_case(&a, "validation range", "/input", `{"age":200}`)
	print_case(&a, "unsupported dst", "/unsupported", `{"callback":"x"}`)

	print_decoder_error("wrong scalar", `{"age":"old"}`)
	print_decoder_error("nested mismatch", `{"address":{"number":"x"}}`)
	print_decoder_error("unknown field", `{"surprise":true}`)
	print_decoder_error("required absent", `{"age":20}`)
	print_allocator_error()
}
