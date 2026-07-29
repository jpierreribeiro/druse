// The consumer both arms are measured with. Identical in both; only the
// vendored `thread_count` differs, patched by `run.sh` into a copy of the tree.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import web "druse:web"

Reply :: struct {
	ok: bool `json:"ok"`,
	n:  int  `json:"n"`,
}

counter: int

// Deliberately does a little work and touches shared state, because a handler
// that only returns a constant would measure the accept path and nothing else —
// and shared state is precisely what the threaded arm has to be safe with.
work :: proc(ctx: ^web.Context) {
	counter += 1
	web.ok(ctx, Reply{ok = true, n = counter})
}

main :: proc() {
	port := 58080
	if len(os.args) > 1 {
		if v, ok := strconv.parse_int(os.args[1]); ok {
			port = v
		}
	}

	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/work", work)

	fmt.printf("listening %d\n", port)
	web.serve(&app, port)
}
