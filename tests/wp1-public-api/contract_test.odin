// WP1 compile contract for the Phase-1 public API skeleton.
//
// This package is an EXTERNAL consumer of `druse:web`. It therefore proves
// two things at once: that every Phase-1 symbol exists with the exact public
// name and signature, and that each one is actually exported.
//
// It proves NOTHING about behavior. WP1 delivers a compiling skeleton, not a
// functional server: every `web` procedure called below is an inert stub. The
// contract is satisfied by compilation on the pinned toolchain, so the
// reference procedures are never executed.
package wp1_public_api

import "core:testing"
import web "druse:web"

// Payload/DTO types belong to the application, never to the framework.
User :: struct {
	id:   int    `json:"id"`,
	name: string `json:"name"`,
}

Create_User :: struct {
	name: string `json:"name"`,
}

// --- extractors: both canonical shapes, by exact name ---

extractor_contract :: proc(ctx: ^web.Context) {
	// Shape 1 — value-producing: (value, ok). No `#optional_ok`, so the
	// compiler forces `ok` to be captured.
	id, id_ok := web.path_int(ctx, "id")
	if !id_ok {
		return
	}

	page, page_ok := web.query_int(ctx, "page")
	if !page_ok {
		return
	}

	limit, limit_ok := web.query_int_or(ctx, "limit", 20)
	if !limit_ok {
		return
	}

	// Plain lookups: no automatic error response.
	name := web.path(ctx, "name")
	search, search_found := web.query(ctx, "search")

	// Shape 2 — destination-filling: fills caller-owned storage, returns bool.
	input: Create_User
	if !web.body(ctx, &input) {
		return
	}

	_ = id
	_ = page
	_ = limit
	_ = name
	_ = search
	_ = search_found
	_ = input
}

// --- responders: by exact name, with Phase-1 by-value payloads ---

responder_contract :: proc(ctx: ^web.Context) {
	payload := User{id = 1, name = "Jean"}

	web.ok(ctx, payload)
	web.created(ctx, payload)
	web.no_content(ctx)
	web.json(ctx, .Accepted, payload)
	web.text(ctx, .OK, "pong")

	web.bad_request(ctx, "invalid input")
	web.unauthorized(ctx, "authentication required")
	web.forbidden(ctx, "insufficient permission")
	web.not_found(ctx, "user")
	web.internal_error(ctx)
}

// --- handler shape: exactly `proc(ctx: ^web.Context)`, returning nothing ---

get_user :: proc(ctx: ^web.Context) {
	extractor_contract(ctx)
	responder_contract(ctx)
}

create_user :: proc(ctx: ^web.Context) {
	input: Create_User
	if !web.body(ctx, &input) {
		return
	}

	web.created(ctx, User{id = 1, name = input.name})
}

// --- application, routing and serving: by exact name ---

application_contract :: proc() {
	// `App` is named explicitly so the contract fails if it stops being
	// exported. `app()` returns by value; the caller-owned value is destroyed
	// exactly once.
	a: web.App = web.app()
	defer web.destroy(&a)

	// The canonical handler type is assignable from a plain procedure.
	handler: web.Handler = get_user

	web.get(&a, "/users/:id", handler)
	web.post(&a, "/users", create_user)
	web.put(&a, "/users/:id", get_user)
	web.patch(&a, "/users/:id", get_user)
	web.delete(&a, "/users/:id", get_user)

	web.serve(&a, 8080)
}

// `bare()` is the advanced no-defaults constructor; same ownership contract.
bare_application_contract :: proc() {
	b: web.App = web.bare()
	defer web.destroy(&b)

	web.get(&b, "/health", get_user)
	web.serve(&b, 8081)
}

@(test)
wp1_public_api_surface_compiles :: proc(t: ^testing.T) {
	// Referencing the contract procedures without calling them: WP1 has no
	// behavior to exercise, and the stubs must never be mistaken for a server.
	application: proc() = application_contract
	bare_application: proc() = bare_application_contract

	testing.expect(
		t,
		application != nil && bare_application != nil,
		"WP1 public API compile contract must compile and link on the pinned toolchain",
	)
}
