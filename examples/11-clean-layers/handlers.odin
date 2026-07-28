package main

// HANDLERS — the only layer that knows HTTP exists.
//
// Each one reads input, calls the service, and maps ONE domain result onto ONE
// status. It contains no rules of its own: everything it could decide, the
// service already decided.

import web "uruquim:web"

create_handler :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)

	input: Create_Link
	if !web.body(ctx, &input) {
		return
	}

	l, result := create_link(&st.store, input.slug, input.target)
	switch result {
	case .Ok:
		web.created(ctx, view_of(l))
	case .Invalid_Slug:
		web.bad_request(ctx, "slug must be 1-32 characters of a-z, 0-9 or -")
	case .Invalid_Target:
		web.bad_request(ctx, "target must be 1-2048 characters")
	case .Slug_Taken:
		web.json(ctx, .Conflict, Error_View{code = "slug_taken", message = "that slug is in use"})
	case .Not_Found:
		web.internal_error(ctx)
	}
}

read_handler :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)
	slug := web.path(ctx, "slug")

	l, result := read_link(&st.store, slug)
	if result != .Ok {
		web.not_found(ctx, "link")
		return
	}
	web.ok(ctx, view_of(l))
}

visit_handler :: proc(ctx: ^web.Context) {
	st := web.state(ctx, App_State)
	slug := web.path(ctx, "slug")

	l, result := visit_link(&st.store, slug)
	if result != .Ok {
		web.not_found(ctx, "link")
		return
	}
	web.set_header(ctx, "Location", l.target)
	web.json(ctx, .Accepted, view_of(l))
}
