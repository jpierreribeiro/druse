package web

import "core:sort"
import "core:sync"
import "core:testing"
import "core:thread"
import transport "druse:web/internal/transport"

WP70_THREADS :: 8
WP70_IDS_PER_THREAD :: 512
WP70_DISPATCHES_PER_THREAD :: 128

Wp70_Work :: struct {
	a:        ^App,
	start:    ^sync.Sema,
	values:   []u64,
	failures: ^int,
}

wp70_hex_value :: proc(s: string) -> u64 {
	value: u64
	for c in s {
		value <<= 4
		value |= u64(c - '0') if c <= '9' else u64(c - 'a' + 10)
	}
	return value
}

wp70_ok :: proc(ctx: ^Context) {
	text(ctx, .OK, "ok")
}

wp70_worker :: proc(w: ^Wp70_Work) {
	sync.sema_wait(w.start)
	for &value in w.values {
		buf: [REQUEST_ID_MAX]u8
		n := request_id_generate(buf[:])
		value = wp70_hex_value(string(buf[n - 16:n]))
	}

	for i in 0 ..< WP70_DISPATCHES_PER_THREAD {
		ctx: Context
		path := "/ok" if i % 2 == 0 else "/missing"
		driver_run(w.a, &ctx, transport.Inbound{method = "GET", path = path})
		expected := Status.OK if i % 2 == 0 else Status.Not_Found
		if ctx.private.response.status != expected || !ctx.private.response.committed {
			_ = sync.atomic_add(w.failures, 1)
		}
		driver_cleanup(&ctx)
	}
}

@(test)
wp70_the_published_app_and_request_ids_survive_contention :: proc(t: ^testing.T) {
	a := app()
	defer destroy(&a)
	use(&a, request_id)
	get(&a, "/ok", wp70_ok)
	app_prepare_serving(&a)
	testing.expect(t, a.private.miss_built, "miss chain must exist before lanes start")
	testing.expect(t, app_is_serving(&a), "snapshot publication must be observable")

	before := len(a.private.routes)
	previous_logger := context.logger
	context.logger = {}
	get(&a, "/late", wp70_ok)
	context.logger = previous_logger
	testing.expect(t, len(a.private.routes) == before, "late registration must not mutate the snapshot")

	values: [WP70_THREADS * WP70_IDS_PER_THREAD]u64
	works: [WP70_THREADS]Wp70_Work
	threads: [WP70_THREADS]^thread.Thread
	start: sync.Sema
	failures: int
	for i in 0 ..< WP70_THREADS {
		works[i] = Wp70_Work{
			a        = &a,
			start    = &start,
			values   = values[i * WP70_IDS_PER_THREAD:(i + 1) * WP70_IDS_PER_THREAD],
			failures = &failures,
		}
		threads[i] = thread.create_and_start_with_poly_data(&works[i], wp70_worker)
	}
	sync.sema_post(&start, WP70_THREADS)
	for worker in threads {
		thread.join(worker)
		thread.destroy(worker)
	}

	testing.expect(t, sync.atomic_load(&failures) == 0, "route/miss dispatch must stay exact under contention")
	sort.quick_sort(values[:])
	for i in 1 ..< len(values) {
		testing.expect(t, values[i] != values[i - 1], "generated request IDs must be unique")
	}
}
