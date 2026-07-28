// M8 — the boot sweep, and the line it must not cross.
package test_m8_spool_sweep

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "core:net"
import web "uruquim:web"

DIR :: "/tmp/claude-0/-home-user-uruquim/a126bd91-c3ae-5861-b9ca-da99771764f8/scratchpad/m8dir-repo"

write :: proc(name: string, body: string) {
	_ = os.write_entire_file(strings.concatenate({DIR, "/", name}, context.temp_allocator), transmute([]u8)body)
}

exists :: proc(name: string) -> bool {
	_, err := os.read_entire_file_from_path(strings.concatenate({DIR, "/", name}, context.temp_allocator), context.temp_allocator)
	return err == nil
}

PORT :: 56111

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
	ready:  sync.Sema,
	done:   sync.Sema,
}

g: ^Server

ok_handler :: proc(ctx: ^web.Context) {web.text(ctx, .OK, "ok")}

serve_thread :: proc() {
	s := g
	sync.post(&s.ready)
	web.serve(&s.app, s.port)
	sync.post(&s.done)
}

@(test)
m8_boot_sweep_removes_orphans_and_nothing_else :: proc(t: ^testing.T) {
	os.make_directory(DIR)
	// Two orphans from an imagined crash, and two files that are NOT ours.
	write("uruquim-spool-deadbeef", "partial upload")
	write("uruquim-spool-cafe1234", "another partial")
	write("application-data.json", "the application put this here")
	write("notes.txt", "so is this")

	// THE SWEEP RUNS AT SERVE, not at `enable_upload`. That is the right
	// moment and the reason this test starts a server: `enable_upload` only
	// records the configuration, and the directory is not this instance's to
	// clean until it actually begins serving.
	s: Server
	g = &s
	s.app = web.app()
	s.port = PORT
	web.enable_upload(&s.app, web.Upload_Config{dir = DIR, per_upload_quota = 1 << 20, process_quota = 1 << 22, max_concurrent = 2})
	web.get(&s.app, "/ok", ok_handler)
	s.thread = thread.create_and_start(serve_thread)
	sync.wait(&s.ready)
	time.sleep(300 * time.Millisecond)

	fmt.printf("\n[m8] after the server started:\n")
	for n in ([?]string{"uruquim-spool-deadbeef", "uruquim-spool-cafe1234", "application-data.json", "notes.txt"}) {
		fmt.printf("[m8]   %-26s exists=%v\n", n, exists(n))
	}

	testing.expect(t, !exists("uruquim-spool-deadbeef"), "an orphaned spool must be swept at boot")
	testing.expect(t, !exists("uruquim-spool-cafe1234"), "every orphaned spool, not just the first")
	testing.expect(
		t,
		exists("application-data.json"),
		"THE LINE THIS MUST NOT CROSS: a file the application put in the directory is not the framework's to delete",
	)
	testing.expect(t, exists("notes.txt"), "nor is anything else without the prefix")

	web.stop(&s.app)
	_ = sync.sema_wait_with_timeout(&s.done, 15 * time.Second)
	thread.join(s.thread)
	thread.destroy(s.thread)
	web.destroy(&s.app)
}
