package main

import "core:os"
import "core:strconv"
import web "druse:web"

ping :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	limits := web.DEFAULT_LIMITS
	if len(os.args) > 1 {
		if n, ok := strconv.parse_int(os.args[1], 10); ok {
			limits.max_handlers = n
		}
	}
	web.limits(&app, limits)
	web.get(&app, "/ping", ping)
	web.serve(&app, 8080)
}
