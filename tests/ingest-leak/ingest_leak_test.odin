// Ingest audit F1/F2/F3 — ADMISSION SLOTS MUST SURVIVE ABNORMAL ENDINGS.
//
// The upload subsystem reserves a bounded slot (`ingest.admit`) before reading a
// byte and releases it through `ingest.cancel`. Three paths used to reach
// neither `on_upload_done` nor `driver_cleanup`, so the slot was never returned:
//
//   F1  the connection dies mid-body (deadline sweep, shutdown force-close, or a
//       client that simply goes away) — `connection_close`/`connection_abort`
//       call `nbio.remove` on the pending recv, so the chunk callback never
//       fires again and nothing else owned the spool;
//   F2  `ingest.begin` fails to open the spool file — the spool never learns
//       which admission it belongs to, so `cancel` cannot find the slot;
//   F3  the lane refuses dispatch with 503 — `driver_cleanup`, the only caller
//       of `upload_cancel`, runs only after `cfg.dispatch`, which that path
//       returns before.
//
// Every one of them is PERMANENT: after `max_concurrent` occurrences the
// subsystem answers 503 to every upload for the life of the process. F1 is the
// one ordinary traffic reaches — with the default 30 s `max_request_time`, any
// client slower than that is enough, which is a 1 GiB body under ~35 MB/s.
//
// This lives in its own package because `web.serve` binds a process-global
// server slot (R-20): a second server started by the parallel test runner would
// have one test's `web.stop` tear down another's.
//
// THE CONTROL that makes this a test rather than a demonstration: delete the
// `conn.on_teardown = upload_conn_torn_down` registration in `start_upload` and
// the final upload answers 503 instead of 201.
package test_ingest_leak

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

MAX_BODY :: 4 * 1024
QUOTA :: 32 * 1024
SPOOLED :: 16 * 1024 // > MAX_BODY, < QUOTA — takes the spool path
PORT :: 41_985

// One slot, so a single leak closes the subsystem, and several abandonments, so
// a fix that only sometimes releases still fails.
SLOTS :: 1
ABANDONS :: 3

// The deadline that produces the leak. A client that merely CLOSES its socket is
// not enough: the FIN completes the pending recv, `body_stream` reports
// `.Failed`, and `on_upload_done` cleans up correctly — that path was never
// broken. The leak needs the recv to be REMOVED without completing, which is
// what `connection_abort` does when the sweep fires. So the client here goes
// quiet and stays connected, and the server's own read deadline aborts it.
REQUEST_DEADLINE :: i64(700 * 1_000_000) // 700 ms in nanoseconds


// --- application ------------------------------------------------------------

upload_handler :: proc(ctx: ^web.Context) {
	up, ok := web.upload(ctx)
	if !ok {
		web.text(ctx, .OK, "buffered")
		return
	}
	web.text(ctx, .Created, fmt.tprintf("size=%d", up.size))
}

Server :: struct {
	app:    web.App,
	port:   int,
	thread: ^thread.Thread,
}

serve_thread :: proc(s: ^Server) {web.serve(&s.app, s.port)}

start :: proc(s: ^Server, port: int, spool_dir: string) -> bool {
	s.port = port
	s.app = web.app()
	l := web.DEFAULT_LIMITS
	l.max_body = MAX_BODY
	l.max_request_time = REQUEST_DEADLINE
	web.limits(&s.app, l)
	web.enable_upload(
		&s.app,
		web.Upload_Config{dir = spool_dir, per_upload_quota = QUOTA, max_concurrent = SLOTS},
	)
	web.post(&s.app, "/upload", upload_handler)
	s.thread = thread.create_and_start_with_poly_data(s, serve_thread)
	for _ in 0 ..< 300 {
		sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port})
		if err == nil {net.close(sock); return true}
		time.sleep(2 * time.Millisecond)
	}
	return false
}

stop :: proc(s: ^Server) {
	web.stop(&s.app)
	if s.thread != nil {thread.join(s.thread); thread.destroy(s.thread); s.thread = nil}
	web.destroy(&s.app)
}

// --- client -----------------------------------------------------------------

send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	off := 0
	for off < len(data) {
		n, err := net.send_tcp(sock, data[off:])
		if err != nil || n <= 0 {return false}
		off += n
	}
	return true
}

dial :: proc(port: int) -> (net.TCP_Socket, bool) {
	endpoint := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	for _ in 0 ..< 100 {
		s, err := net.dial_tcp(endpoint)
		if err == nil {return s, true}
		time.sleep(2 * time.Millisecond)
	}
	return {}, false
}

body_of :: proc(n: int) -> []u8 {
	b := make([]u8, n)
	for i in 0 ..< n {b[i] = u8(i % 251)}
	return b
}

// post sends a complete upload and returns its status.
post :: proc(port: int, body: []u8) -> (status: int, ok: bool) {
	sock, connected := dial(port)
	if !connected {return 0, false}
	defer net.close(sock)
	net.set_option(sock, .Receive_Timeout, 5 * time.Second)
	net.set_option(sock, .Send_Timeout, 5 * time.Second)

	head := strings.concatenate(
		{
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ",
			fmt.tprintf("%d", len(body)),
			"\r\nConnection: close\r\n\r\n",
		},
		context.temp_allocator,
	)
	if !send_all(sock, transmute([]u8)head) {return 0, false}
	if !send_all(sock, body) {return 0, false}

	acc := strings.builder_make(context.temp_allocator)
	buf: [4096]u8
	for {
		n, e := net.recv_tcp(sock, buf[:])
		if n > 0 {strings.write_bytes(&acc, buf[:n])}
		if n == 0 || e != nil {break}
	}
	raw := strings.to_string(acc)
	if len(raw) < 12 {return 0, false}
	status, _ = strconv.parse_int(raw[9:12], 10)
	return status, true
}

// stall announces a large body, sends only a prefix, then GOES QUIET while
// staying connected until the server's read deadline aborts the connection.
// `connection_abort` calls `nbio.remove` on the pending recv, so the chunk
// callback never fires again and no upload-owned code runs on this connection
// after this point — which is precisely the state that used to strand the
// admission slot and leave the partial spool file on disk.
stall :: proc(port: int, announced, prefix: int) -> bool {
	sock, connected := dial(port)
	if !connected {return false}
	net.set_option(sock, .Send_Timeout, 5 * time.Second)
	defer net.close(sock)

	head := strings.concatenate(
		{
			"POST /upload HTTP/1.1\r\nHost: x\r\nContent-Length: ",
			fmt.tprintf("%d", announced),
			"\r\n\r\n",
		},
		context.temp_allocator,
	)
	if !send_all(sock, transmute([]u8)head) {
		return false
	}
	part := body_of(prefix)
	defer delete(part)
	_ = send_all(sock, part)

	// Outlast the server's read deadline without sending the rest.
	time.sleep(time.Duration(REQUEST_DEADLINE) + 500 * time.Millisecond)
	return true
}

// --- test -------------------------------------------------------------------

@(test)
upload_admission_survives_abandoned_bodies :: proc(t: ^testing.T) {
	cache := strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.cache"}, context.temp_allocator)
	os.make_directory(cache)
	spool := strings.concatenate({cache, "/uru-ingest-leak"}, context.temp_allocator)
	os.make_directory(spool)

	srv: Server
	if !start(&srv, PORT, spool) {
		testing.fail_now(t, "server did not start")
	}
	defer stop(&srv)

	// Baseline: the endpoint works before any abandonment, so a later failure
	// cannot be blamed on the fixture.
	{
		body := body_of(SPOOLED)
		defer delete(body)
		status, ok := post(PORT, body)
		testing.expectf(t, ok && status == 201, "baseline upload: ok=%v status=%v", ok, status)
	}

	for i in 0 ..< ABANDONS {
		testing.expectf(t, stall(PORT, SPOOLED, 512), "stall %d could not be issued", i)
		// Let the lane finish the abort and its teardown before the next attempt,
		// so this measures leaked slots and not momentary concurrency.
		time.sleep(150 * time.Millisecond)
	}

	// THE ASSERTION. With slots leaked, admission is exhausted and `start_upload`
	// refuses this with 503. With them released, it spools and dispatches exactly
	// as the baseline did.
	//
	// POLLED, NOT SLEPT, and the distinction is the whole point of the test.
	// The 150 ms above is a guess about how long a teardown takes on an idle
	// machine; under the full gate it is sometimes not enough, and this suite
	// then reported "admission slots leaked" for a teardown that had merely not
	// finished yet — the exact confusion between a leak and momentary
	// concurrency that the sleep exists to avoid. It failed that way in the
	// 2026-07-30 pre-push gate while passing six consecutive standalone runs.
	//
	// A LEAK NEVER RECOVERS. That is what makes the retry sound rather than a
	// way of wishing a red test green: if a slot is genuinely lost, no amount of
	// waiting returns it, so a 201 inside the window proves the release
	// happened and a 503 across the whole window proves it did not. The bound
	// is generous because it costs nothing when the release is prompt — the
	// loop exits on the first success.
	{
		body := body_of(SPOOLED)
		defer delete(body)

		status: int
		ok: bool
		for attempt in 0 ..< 40 {
			status, ok = post(PORT, body)
			if ok && status == 201 {
				break
			}
			time.sleep(100 * time.Millisecond)
		}

		testing.expectf(
			t,
			ok && status == 201,
			"upload after %d abandoned bodies: ok=%v status=%v after 4s of retries (503 that never clears means admission slots leaked; a leak does not recover)",
			ABANDONS,
			ok,
			status,
		)
	}
}

// --- F2: `ingest.begin` cannot open the spool file --------------------------
//
// The package header has named F2 since it was written, and until now only F1
// had a test. R2-WP06 reviewed the indirect pins against the R2 threat model and
// this was one of two rows whose evidence was an argument rather than a run:
// `planning/security-backlog-reconciliation.md` records F-007 as "pinned by
// construction, argued above rather than asserted. A test would need a spool
// directory made unwritable mid-run."
//
// It needs exactly that, and nothing more. `begin` reserves nothing itself — the
// caller has already spent a slot on `admit` — and on an `os.open` failure the
// spool never learns which admission it belongs to, so `cancel` cannot find the
// slot. Before the fix (marker "ingest audit F2") a directory that was briefly
// unwritable retired `max_concurrent` slots PERMANENTLY: every later upload
// answered 503 for the life of the process, long after the disk condition
// cleared. That is the shape being tested — not the failure, the RECOVERY.
//
// UNPRIVILEGED ONLY. Root ignores DAC, so `chmod 0500` does not stop root from
// writing and the test would prove nothing while reporting green. It refuses to
// run as root rather than passing vacuously — the same reason
// `build/check_r1_resource_controls.sh` must not run as root.
F2_PORT :: 41_986
F2_ATTEMPTS :: SLOTS + 2

@(test)
upload_admission_survives_an_unopenable_spool :: proc(t: ^testing.T) {
	if posix.getuid() == 0 {
		testing.fail_now(
			t,
			"this test must run unprivileged: root ignores DAC, so an unwritable spool directory would still be writable and the test would pass without testing anything",
		)
	}

	cache := strings.concatenate({os.get_env("HOME", context.temp_allocator), "/.cache"}, context.temp_allocator)
	os.make_directory(cache)
	spool := strings.concatenate({cache, "/uru-ingest-f2"}, context.temp_allocator)
	os.make_directory(spool)
	spool_c := strings.clone_to_cstring(spool, context.temp_allocator)
	// Restore the mode whatever happens, or a red run leaves a directory the
	// next run cannot use and the failure looks like a different defect.
	defer posix.chmod(spool_c, {.IRUSR, .IWUSR, .IXUSR})

	srv: Server
	if !start(&srv, F2_PORT, spool) {
		testing.fail_now(t, "server did not start")
	}
	defer stop(&srv)

	// Baseline, so a later failure cannot be blamed on the fixture.
	{
		body := body_of(SPOOLED)
		defer delete(body)
		status, ok := post(F2_PORT, body)
		testing.expectf(t, ok && status == 201, "baseline upload: ok=%v status=%v", ok, status)
	}

	// Readable and executable, NOT writable: `os.open` with O_CREATE fails.
	if posix.chmod(spool_c, {.IRUSR, .IXUSR}) != .OK {
		testing.fail_now(t, "could not make the spool directory unwritable")
	}

	// Every one of these must fail to spool. The status is deliberately not
	// asserted to a single value: what the client sees when the disk refuses is
	// an operational choice this test has no business freezing. What it does
	// assert is that none of them SUCCEEDS, because a 201 here would mean the
	// unwritable directory never took effect and the rest proves nothing.
	for i in 0 ..< F2_ATTEMPTS {
		body := body_of(SPOOLED)
		status, ok := post(F2_PORT, body)
		delete(body)
		testing.expectf(
			t,
			!(ok && status == 201),
			"upload %d succeeded against an unwritable spool directory; the fixture did not take effect, so nothing after this is evidence (status=%v)",
			i,
			status,
		)
	}

	if posix.chmod(spool_c, {.IRUSR, .IWUSR, .IXUSR}) != .OK {
		testing.fail_now(t, "could not restore the spool directory")
	}

	// THE ASSERTION. With the slot released on the open failure, the subsystem
	// works again the moment the directory does. With it retired, this answers
	// 503 forever.
	//
	// Polled for the same reason the F1 test polls, and the same argument makes
	// it sound rather than wishful: a leaked slot NEVER comes back, so a 201
	// inside the window proves the release happened and a 503 across the whole
	// window proves it did not.
	{
		body := body_of(SPOOLED)
		defer delete(body)
		status: int
		ok: bool
		for _ in 0 ..< 40 {
			status, ok = post(F2_PORT, body)
			if ok && status == 201 {
				break
			}
			time.sleep(100 * time.Millisecond)
		}
		testing.expectf(
			t,
			ok && status == 201,
			"upload after %d unopenable spools: ok=%v status=%v after 4s of retries (a 503 that never clears means `begin` kept the slot it never used)",
			F2_ATTEMPTS,
			ok,
			status,
		)
	}
}
