// Uruquim example 11 — layered layout, in one small service.
//
// A URL shortener. The point is not the shortener; it is that each file answers
// one question, and the dependencies point one way:
//
//	main.odin      composition — creates everything, owns everything
//	routes.odin    the URL shape
//	handlers.odin  HTTP in, HTTP out. The only layer that knows about requests
//	dto.odin       what crosses the wire
//	service.odin   the rules. Takes plain values, returns a domain result
//	store.odin     where it lives. Swappable for a database
//	models.odin    what the thing is. No HTTP, no JSON, no storage
//
// handlers -> service -> store, and never the other way. `service.odin` cannot
// import a request even if somebody wanted it to, because nothing in it names
// one.
//
// This layout is an INDICATION, not a rule. A three-route service does not need
// it. A service that grows past one screen usually does.
//
// Run it from the repository root:
//
//	odin run examples/11-clean-layers -collection:uruquim=.
//
// Try it:
//
//	curl -X POST localhost:8080/links -H 'content-type: application/json' \
//	     -d '{"slug":"odin","target":"https://odin-lang.org"}'
//	curl localhost:8080/links/odin
//	curl -i localhost:8080/go/odin
package main

import web "uruquim:web"

App_State :: struct {
	store: Store,
}

main :: proc() {
	state := App_State{store = store_open()}
	defer store_close(&state.store)

	app := web.app_with_state(&state)
	defer web.destroy(&app)

	web.use(&app, web.request_id)
	web.use(&app, web.logger)

	register_routes(&app)

	web.serve(&app, 8080)
}
