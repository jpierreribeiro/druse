package handler_errors

import json "core:encoding/json"
import "core:testing"

Status :: enum int {
	OK             = 200,
	Bad_Request    = 400,
	Unauthorized   = 401,
	Not_Found      = 404,
	Internal_Error = 500,
}

Service_Error :: enum {
	None,
	User_Not_Found,
	Database_Failure,
}

Handler_Error_Kind :: enum {
	None,
	HTTP,
	Domain,
	Internal,
	Marshal,
}

Handler_Error :: struct {
	kind:    Handler_Error_Kind,
	status:  Status,
	service: Service_Error,
	message: string,
}

Response :: struct {
	status:       Status,
	body:         string,
	committed:    bool,
	commit_count: int,
}

Prepared_Response :: struct {
	status: Status,
	body:   string,
}

Outcome_Kind :: enum {
	Response,
	Error,
	Already_Responded,
}

Handler_Outcome :: struct {
	kind:     Outcome_Kind,
	response: Prepared_Response,
	err:      Handler_Error,
}

Context :: struct {
	response:   Response,
	log_count:  int,
	last_log:   string,
	json_calls: int,
	auth_ok:    bool,
	path_ok:    bool,
	final_a:    Handler_A,
	final_b:    Handler_B,
	final_c:    Handler_C,
}

Handler_A :: proc(ctx: ^Context)
Handler_B :: proc(ctx: ^Context) -> Handler_Error
Handler_C :: proc(ctx: ^Context) -> Handler_Outcome

Next_A :: proc(ctx: ^Context)
Next_B :: proc(ctx: ^Context) -> Handler_Error
Next_C :: proc(ctx: ^Context) -> Handler_Outcome

Middleware_A :: proc(ctx: ^Context, next: Next_A)
Middleware_B :: proc(ctx: ^Context, next: Next_B) -> Handler_Error
Middleware_C :: proc(ctx: ^Context, next: Next_C) -> Handler_Outcome

User :: struct {
	id:   int    `json:"id"`,
	name: string `json:"name"`,
}

bad_payload :: proc() {}

commit :: proc(ctx: ^Context, status: Status, body: string) {
	if ctx.response.committed {
		return
	}
	ctx.response.status = status
	ctx.response.body = body
	ctx.response.committed = true
	ctx.response.commit_count += 1
}

server_log :: proc(ctx: ^Context, message: string) {
	ctx.log_count += 1
	ctx.last_log = message
}

http_error :: proc(status: Status, message: string) -> Handler_Error {
	return {kind = .HTTP, status = status, message = message}
}

domain_error :: proc(err: Service_Error) -> Handler_Error {
	return {kind = .Domain, service = err}
}

internal_error :: proc(message: string) -> Handler_Error {
	return {kind = .Internal, message = message}
}

marshal_error :: proc() -> Handler_Error {
	return {kind = .Marshal, message = "json marshal failed"}
}

handle_error :: proc(ctx: ^Context, err: Handler_Error) {
	switch err.kind {
	case .None:
		return
	case .HTTP:
		commit(ctx, err.status, "http_error")
	case .Domain:
		switch err.service {
		case .User_Not_Found:
			commit(ctx, .Not_Found, "user_not_found")
		case .Database_Failure:
			server_log(ctx, "database failure")
			commit(ctx, .Internal_Error, "internal_error")
		case .None:
			return
		}
	case .Internal:
		server_log(ctx, err.message)
		commit(ctx, .Internal_Error, "internal_error")
	case .Marshal:
		server_log(ctx, err.message)
		commit(ctx, .Internal_Error, "internal_error")
	}
}

path_int :: proc(ctx: ^Context) -> (int, bool) {
	if !ctx.path_ok {
		commit(ctx, .Bad_Request, "invalid_path_parameter")
		return 0, false
	}
	return 42, true
}

// Model A: current Druse shape. Helpers respond, and a central typed helper
// formats/logs application failures without changing Handler.
json_a :: proc(ctx: ^Context, status: Status, value: $T) {
	ctx.json_calls += 1
	data, err := json.marshal(value, {}, context.temp_allocator)
	if err != nil {
		handle_error(ctx, marshal_error())
		return
	}
	commit(ctx, status, string(data))
}

ok_a :: proc(ctx: ^Context, value: $T) {
	json_a(ctx, .OK, value)
}

handler_a_success :: proc(ctx: ^Context) {
	ok_a(ctx, User{id = 7, name = "Ada"})
}

handler_a_domain :: proc(ctx: ^Context) {
	handle_error(ctx, domain_error(.User_Not_Found))
}

handler_a_unknown :: proc(ctx: ^Context) {
	handle_error(ctx, internal_error("unexpected service failure"))
}

handler_a_marshal :: proc(ctx: ^Context) {
	json_a(ctx, .OK, bad_payload)
}

handler_a_post_commit_error :: proc(ctx: ^Context) {
	ok_a(ctx, User{id = 1, name = "committed"})
	handle_error(ctx, internal_error("late failure"))
}

handler_a_extractor :: proc(ctx: ^Context) {
	_, ok := path_int(ctx)
	if !ok {
		return
	}
	ok_a(ctx, User{id = 42, name = "path"})
}

next_a :: proc(ctx: ^Context) {
	ctx.final_a(ctx)
}

auth_a :: proc(ctx: ^Context, next: Next_A) {
	if !ctx.auth_ok {
		commit(ctx, .Unauthorized, "authentication_required")
		return
	}
	next(ctx)
}

dispatch_a :: proc(ctx: ^Context, mw: Middleware_A, handler: Handler_A) {
	ctx.final_a = handler
	mw(ctx, next_a)
}

// Model B: an Echo-like typed error channel. JSON helpers return a typed
// failure and the dispatcher owns centralized formatting/logging.
json_b :: proc(ctx: ^Context, status: Status, value: $T) -> Handler_Error {
	ctx.json_calls += 1
	data, err := json.marshal(value, {}, context.temp_allocator)
	if err != nil {
		return marshal_error()
	}
	commit(ctx, status, string(data))
	return {}
}

ok_b :: proc(ctx: ^Context, value: $T) -> Handler_Error {
	return json_b(ctx, .OK, value)
}

handler_b_success :: proc(ctx: ^Context) -> Handler_Error {
	return ok_b(ctx, User{id = 7, name = "Ada"})
}

handler_b_domain :: proc(ctx: ^Context) -> Handler_Error {
	return domain_error(.User_Not_Found)
}

handler_b_unknown :: proc(ctx: ^Context) -> Handler_Error {
	return internal_error("unexpected service failure")
}

handler_b_marshal :: proc(ctx: ^Context) -> Handler_Error {
	return json_b(ctx, .OK, bad_payload)
}

handler_b_post_commit_error :: proc(ctx: ^Context) -> Handler_Error {
	_ = ok_b(ctx, User{id = 1, name = "committed"})
	return internal_error("late failure")
}

handler_b_extractor :: proc(ctx: ^Context) -> (err: Handler_Error) {
	_, ok := path_int(ctx)
	if !ok {
		return
	}
	return ok_b(ctx, User{id = 42, name = "path"})
}

next_b :: proc(ctx: ^Context) -> Handler_Error {
	return ctx.final_b(ctx)
}

auth_b :: proc(ctx: ^Context, next: Next_B) -> Handler_Error {
	if !ctx.auth_ok {
		return http_error(.Unauthorized, "authentication required")
	}
	return next(ctx)
}

dispatch_b :: proc(ctx: ^Context, mw: Middleware_B, handler: Handler_B) {
	ctx.final_b = handler
	err := mw(ctx, next_b)
	handle_error(ctx, err)
}

// Model C: handlers return an explicit response-or-error outcome. Nothing is
// committed until dispatch, except the existing self-responding extractor.
response_outcome :: proc(status: Status, body: string) -> Handler_Outcome {
	return {kind = .Response, response = {status = status, body = body}}
}

error_outcome :: proc(err: Handler_Error) -> Handler_Outcome {
	return {kind = .Error, err = err}
}

already_responded :: proc() -> Handler_Outcome {
	return {kind = .Already_Responded}
}

json_c :: proc(ctx: ^Context, status: Status, value: $T) -> Handler_Outcome {
	ctx.json_calls += 1
	data, err := json.marshal(value, {}, context.temp_allocator)
	if err != nil {
		return error_outcome(marshal_error())
	}
	return response_outcome(status, string(data))
}

ok_c :: proc(ctx: ^Context, value: $T) -> Handler_Outcome {
	return json_c(ctx, .OK, value)
}

handler_c_success :: proc(ctx: ^Context) -> Handler_Outcome {
	return ok_c(ctx, User{id = 7, name = "Ada"})
}

handler_c_domain :: proc(ctx: ^Context) -> Handler_Outcome {
	return error_outcome(domain_error(.User_Not_Found))
}

handler_c_unknown :: proc(ctx: ^Context) -> Handler_Outcome {
	return error_outcome(internal_error("unexpected service failure"))
}

handler_c_marshal :: proc(ctx: ^Context) -> Handler_Outcome {
	return json_c(ctx, .OK, bad_payload)
}

handler_c_post_commit_error :: proc(ctx: ^Context) -> Handler_Outcome {
	commit(ctx, .OK, "already committed")
	return error_outcome(internal_error("late failure"))
}

handler_c_extractor :: proc(ctx: ^Context) -> Handler_Outcome {
	_, ok := path_int(ctx)
	if !ok {
		return already_responded()
	}
	return ok_c(ctx, User{id = 42, name = "path"})
}

next_c :: proc(ctx: ^Context) -> Handler_Outcome {
	return ctx.final_c(ctx)
}

auth_c :: proc(ctx: ^Context, next: Next_C) -> Handler_Outcome {
	if !ctx.auth_ok {
		return error_outcome(http_error(.Unauthorized, "authentication required"))
	}
	return next(ctx)
}

dispatch_outcome :: proc(ctx: ^Context, outcome: Handler_Outcome) {
	switch outcome.kind {
	case .Response:
		commit(ctx, outcome.response.status, outcome.response.body)
	case .Error:
		handle_error(ctx, outcome.err)
	case .Already_Responded:
		return
	}
}

dispatch_c :: proc(ctx: ^Context, mw: Middleware_C, handler: Handler_C) {
	ctx.final_c = handler
	dispatch_outcome(ctx, mw(ctx, next_c))
}

expect_response :: proc(t: ^testing.T, ctx: ^Context, status: Status, commits: int) {
	testing.expect(t, ctx.response.status == status)
	testing.expect(t, ctx.response.commit_count == commits)
	testing.expect(t, ctx.response.committed == (commits == 1))
}

@(test)
model_a_contract :: proc(t: ^testing.T) {
	ctx := Context{auth_ok = true, path_ok = true}
	dispatch_a(&ctx, auth_a, handler_a_success)
	expect_response(t, &ctx, .OK, 1)

	domain := Context{auth_ok = true}
	dispatch_a(&domain, auth_a, handler_a_domain)
	expect_response(t, &domain, .Not_Found, 1)

	unknown := Context{auth_ok = true}
	dispatch_a(&unknown, auth_a, handler_a_unknown)
	expect_response(t, &unknown, .Internal_Error, 1)
	testing.expect(t, unknown.log_count == 1)

	marshal := Context{auth_ok = true}
	dispatch_a(&marshal, auth_a, handler_a_marshal)
	expect_response(t, &marshal, .Internal_Error, 1)
	testing.expect(t, marshal.log_count == 1)

	late := Context{auth_ok = true}
	dispatch_a(&late, auth_a, handler_a_post_commit_error)
	expect_response(t, &late, .OK, 1)
	testing.expect(t, late.log_count == 1)

	extracted := Context{auth_ok = true, path_ok = false}
	dispatch_a(&extracted, auth_a, handler_a_extractor)
	expect_response(t, &extracted, .Bad_Request, 1)

	denied := Context{auth_ok = false}
	dispatch_a(&denied, auth_a, handler_a_success)
	expect_response(t, &denied, .Unauthorized, 1)
}

@(test)
model_b_contract :: proc(t: ^testing.T) {
	ctx := Context{auth_ok = true, path_ok = true}
	dispatch_b(&ctx, auth_b, handler_b_success)
	expect_response(t, &ctx, .OK, 1)

	domain := Context{auth_ok = true}
	dispatch_b(&domain, auth_b, handler_b_domain)
	expect_response(t, &domain, .Not_Found, 1)

	unknown := Context{auth_ok = true}
	dispatch_b(&unknown, auth_b, handler_b_unknown)
	expect_response(t, &unknown, .Internal_Error, 1)
	testing.expect(t, unknown.log_count == 1)

	marshal := Context{auth_ok = true}
	dispatch_b(&marshal, auth_b, handler_b_marshal)
	expect_response(t, &marshal, .Internal_Error, 1)
	testing.expect(t, marshal.log_count == 1)

	late := Context{auth_ok = true}
	dispatch_b(&late, auth_b, handler_b_post_commit_error)
	expect_response(t, &late, .OK, 1)
	testing.expect(t, late.log_count == 1)

	extracted := Context{auth_ok = true, path_ok = false}
	dispatch_b(&extracted, auth_b, handler_b_extractor)
	expect_response(t, &extracted, .Bad_Request, 1)

	denied := Context{auth_ok = false}
	dispatch_b(&denied, auth_b, handler_b_success)
	expect_response(t, &denied, .Unauthorized, 1)
}

@(test)
model_c_contract :: proc(t: ^testing.T) {
	ctx := Context{auth_ok = true, path_ok = true}
	dispatch_c(&ctx, auth_c, handler_c_success)
	expect_response(t, &ctx, .OK, 1)

	domain := Context{auth_ok = true}
	dispatch_c(&domain, auth_c, handler_c_domain)
	expect_response(t, &domain, .Not_Found, 1)

	unknown := Context{auth_ok = true}
	dispatch_c(&unknown, auth_c, handler_c_unknown)
	expect_response(t, &unknown, .Internal_Error, 1)
	testing.expect(t, unknown.log_count == 1)

	marshal := Context{auth_ok = true}
	dispatch_c(&marshal, auth_c, handler_c_marshal)
	expect_response(t, &marshal, .Internal_Error, 1)
	testing.expect(t, marshal.log_count == 1)

	late := Context{auth_ok = true}
	dispatch_c(&late, auth_c, handler_c_post_commit_error)
	expect_response(t, &late, .OK, 1)
	testing.expect(t, late.log_count == 1)

	extracted := Context{auth_ok = true, path_ok = false}
	dispatch_c(&extracted, auth_c, handler_c_extractor)
	expect_response(t, &extracted, .Bad_Request, 1)

	denied := Context{auth_ok = false}
	dispatch_c(&denied, auth_c, handler_c_success)
	expect_response(t, &denied, .Unauthorized, 1)
}

@(test)
helper_equivalence :: proc(t: ^testing.T) {
	a_ok, a_json: Context
	ok_a(&a_ok, User{id = 1, name = "same"})
	json_a(&a_json, .OK, User{id = 1, name = "same"})
	testing.expect(t, a_ok.response == a_json.response)
	testing.expect(t, a_ok.json_calls == 1 && a_json.json_calls == 1)

	b_ok, b_json: Context
	b_ok_err := ok_b(&b_ok, User{id = 1, name = "same"})
	b_json_err := json_b(&b_json, .OK, User{id = 1, name = "same"})
	testing.expect(t, b_ok.response == b_json.response)
	testing.expect(t, b_ok_err == b_json_err)
	testing.expect(t, b_ok.json_calls == 1 && b_json.json_calls == 1)

	c_ok, c_json: Context
	c_ok_result := ok_c(&c_ok, User{id = 1, name = "same"})
	c_json_result := json_c(&c_json, .OK, User{id = 1, name = "same"})
	testing.expect(t, c_ok_result == c_json_result)
	testing.expect(t, c_ok.json_calls == 1 && c_json.json_calls == 1)
}
