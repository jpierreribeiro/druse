package main

// ROUTES — the URL shape, in one readable place.
//
// Keeping this out of `main` means a reader answering "what does this service
// expose?" opens one small file, and a reader answering "what does it own?"
// opens another.

import web "uruquim:web"

register_routes :: proc(app: ^web.App) {
	web.post(app, "/links", create_handler)
	web.get(app, "/links/:slug", read_handler)
	web.get(app, "/go/:slug", visit_handler)
}
