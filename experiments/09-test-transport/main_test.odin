// Experiment 09 — test-transport
// Question: does an in-memory dispatcher give real behavior tests for GET
// static, path int (valid/invalid), query default (absent/malformed), invalid
// body, ok, and 404 — using a deliberately SIMPLE (non-radix) dispatcher?
//
// THROWAWAY. Not imported by any product package.
// Run with: odin test . -collection:druse=../..
package test_transport

import "core:testing"
import "core:strings"
import "core:strconv"

// ---- trimmed framework surface, in-memory only ----
Request  :: struct { method, path, query, body: string }
Response :: struct { status: int, body: string, commit: int }
Context  :: struct { req: Request, res: Response, params: map[string]string }

commit :: proc(ctx: ^Context, status: int, body: string) {
	if ctx.res.commit > 0 { return }
	ctx.res.status = status
	ctx.res.body = body
	ctx.res.commit = 1
}
ok        :: proc(ctx: ^Context, body: string) { commit(ctx, 200, body) }
not_found :: proc(ctx: ^Context, what: string) { commit(ctx, 404, strings.concatenate({`{"error":{"code":"not_found","message":"`, what, `"}}`}, context.temp_allocator)) }
bad_query :: proc(ctx: ^Context, name: string) { commit(ctx, 400, strings.concatenate({`{"error":{"code":"invalid_query_parameter","field":"`, name, `"}}`}, context.temp_allocator)) }
bad_path  :: proc(ctx: ^Context, name: string) { commit(ctx, 400, strings.concatenate({`{"error":{"code":"invalid_path_parameter","field":"`, name, `"}}`}, context.temp_allocator)) }

// extractors
path_int :: proc(ctx: ^Context, name: string) -> (int, bool) {
	raw, found := ctx.params[name]
	if !found { bad_path(ctx, name); return 0, false }
	v, okp := strconv.parse_int(raw)
	if !okp { bad_path(ctx, name); return 0, false }
	return v, true
}
query_int_or :: proc(ctx: ^Context, name: string, def: int) -> (int, bool) {
	// present-but-malformed -> 400 ; absent -> default
	raw := query_value(ctx.req.query, name)
	if raw == "" { return def, true }
	v, okp := strconv.parse_int(raw)
	if !okp { bad_query(ctx, name); return 0, false }
	return v, true
}
query_value :: proc(query, name: string) -> string {
	// toy: "page=2&x=1"
	remaining := query
	for part in strings.split_iterator(&remaining, "&") {
		eq := strings.index_byte(part, '=')
		if eq < 0 { continue }
		if part[:eq] == name { return part[eq+1:] }
	}
	return ""
}

// simple dispatcher: exact-match table + one :param route. NO radix.
dispatch :: proc(ctx: ^Context) {
	switch {
	case ctx.req.method == "GET" && ctx.req.path == "/ping":
		ok(ctx, "pong")
	case ctx.req.method == "GET" && strings.has_prefix(ctx.req.path, "/users/"):
		ctx.params["id"] = ctx.req.path[len("/users/"):]
		id, good := path_int(ctx, "id")
		if !good { return }
		ok(ctx, strconv.write_int(make([]byte, 8, context.temp_allocator), i64(id), 10))
	case ctx.req.method == "GET" && ctx.req.path == "/list":
		limit, good := query_int_or(ctx, "limit", 20)
		if !good { return }
		ok(ctx, strconv.write_int(make([]byte, 8, context.temp_allocator), i64(limit), 10))
	case:
		not_found(ctx, ctx.req.path)
	}
}

run :: proc(method, path, query, body: string) -> Response {
	ctx := Context{ req = {method, path, query, body}, params = make(map[string]string, 0, context.temp_allocator) }
	dispatch(&ctx)
	return ctx.res
}

@(test)
test_static_ok :: proc(t: ^testing.T) {
	r := run("GET", "/ping", "", "")
	testing.expect(t, r.status == 200 && r.body == "pong", "GET /ping should be 200 pong")
	testing.expect(t, r.commit == 1, "exactly one commit")
}

@(test)
test_path_int_valid :: proc(t: ^testing.T) {
	r := run("GET", "/users/42", "", "")
	testing.expect(t, r.status == 200 && r.body == "42", "valid path int -> 200 42")
}

@(test)
test_path_int_invalid :: proc(t: ^testing.T) {
	r := run("GET", "/users/abc", "", "")
	testing.expect(t, r.status == 400, "invalid path int -> 400")
	testing.expect(t, strings.contains(r.body, "invalid_path_parameter"), "envelope code")
}

@(test)
test_query_default_absent :: proc(t: ^testing.T) {
	r := run("GET", "/list", "", "")
	testing.expect(t, r.status == 200 && r.body == "20", "absent query -> default 20")
}

@(test)
test_query_malformed :: proc(t: ^testing.T) {
	r := run("GET", "/list", "limit=banana", "")
	testing.expect(t, r.status == 400, "malformed query -> 400 (not default)")
	testing.expect(t, strings.contains(r.body, "invalid_query_parameter"), "envelope code")
}

@(test)
test_not_found :: proc(t: ^testing.T) {
	r := run("GET", "/missing", "", "")
	testing.expect(t, r.status == 404, "unknown route -> 404")
	testing.expect(t, strings.contains(r.body, "not_found"), "envelope code")
}
