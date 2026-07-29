package wp70_stop

import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

STOP_THREADS :: 16

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
}

Stop_Work :: struct {
	app:   ^web.App,
	start: ^sync.Sema,
}

ok :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "ok")
}

serve_thread :: proc(s: ^Server) {
	web.serve(&s.app, s.port)
}

stop_thread :: proc(w: ^Stop_Work) {
	sync.sema_wait(w.start)
	web.stop(w.app)
}

wait_until_listening :: proc(port: int) -> bool {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	for _ in 0 ..< 200 {
		sock, err := net.dial_tcp(ep)
		if err == nil {
			net.close(sock)
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

@(test)
wp70_concurrent_stop_has_one_server_lifetime :: proc(t: ^testing.T) {
	s := Server{app = web.app(), port = 51070}
	defer web.destroy(&s.app)
	web.get(&s.app, "/ok", ok)
	s.thread = thread.create_and_start_with_poly_data(&s, serve_thread)
	defer if s.thread != nil {
		web.stop(&s.app)
		thread.join(s.thread)
		thread.destroy(s.thread)
	}
	testing.expect(t, wait_until_listening(s.port), "server must become reachable")

	start: sync.Sema
	works: [STOP_THREADS]Stop_Work
	threads: [STOP_THREADS]^thread.Thread
	for i in 0 ..< STOP_THREADS {
		works[i] = Stop_Work{app = &s.app, start = &start}
		threads[i] = thread.create_and_start_with_poly_data(&works[i], stop_thread)
	}
	sync.sema_post(&start, STOP_THREADS)
	for worker in threads {
		thread.join(worker)
		thread.destroy(worker)
	}

	thread.join(s.thread)
	thread.destroy(s.thread)
	s.thread = nil
}
