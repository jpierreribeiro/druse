// WP123 / ADR-018 — TWO SERVERS IN ONE PROCESS, EACH ANSWERING FOR ITSELF.
//
// This is the suite the work package exists to turn green. Everything else in
// WP123 is mechanism; the claim is the one this file states four ways:
//
//	Two `web.serve` calls in one process, on different ports, serving
//	different routes, each reporting and each draining independently.
//
// WHY IT IS BUILT ON `web_blocking_lab` AND NOT ON `blocking_lab`. The other lab
// looks like the better host — it already runs several servers in one process —
// and that is exactly what disqualifies it: it bypasses `web.serve` and drives
// the vendored transport directly. Every assertion below would pass there with
// the single process-wide slot fully intact, because the slot is on the path
// `web.serve` takes and the path that lab does not. Green for the wrong reason
// is the failure mode `docs/diagnosability.md` rule 4 forbids, and it is the
// easiest one to walk into here. `web_blocking_lab` drives `web.serve` and holds
// no package variable of its own; it is already per-instance.
//
// FOUR ASSERTIONS, one per thing the old single slot conflated. The slot held
// THREE pointers — the backend server, the stream registry and the upload
// admission — and each of the three is a separate way for one server to answer
// for another. A suite that proved only the first would leave two thirds of the
// defect uncovered while reading as complete.
//
//	1. the send counters diverge         (the `server` pointer)
//	2. a stop drains one and not the other (the `server` pointer, liveness side)
//	3. a stream token names ITS server    (the `streams` pointer)
//	4. one server's stop does not close another's upload admission (`admission`)
//
// NO `-define:ODIN_TEST_THREADS=1`, and that is a property of the suite rather
// than of the runner. Running the tests in parallel is the observable difference
// this work package bought; serialized, the suite would prove nothing about the
// runner it is supposed to unblock. The tests are safe in parallel because each
// binds its own ports and stops only its own Apps — which is the claim.
//
// PORTS. The repository has no port allocator: fifteen suites keep disjoint
// `CANDIDATE_PORTS` lists by hand, on a grid documented as such. The two lists
// below are disjoint FROM EACH OTHER as well as from every other suite, per the
// warning in `tests/c03-fault-campaign/harness.odin`: a retry by one server must
// not land on the other's list, or the suite would occasionally prove that one
// server is one server.
package test_wp123_two_servers

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import lab "druse:tests/support/web_blocking_lab"
import web "druse:web"

// Disjoint from each other and from every other suite's grid (53200-53399 is
// otherwise unbound), AND disjoint per test: the runner is parallel here on
// purpose, so two tests sharing a candidate list would have one of them start on
// the other's server. `lab.Start` now refuses that rather than reporting it as a
// start, but a suite that relies on the refusal is a suite whose tests race for
// ports; giving each test its own row removes the race instead of surviving it.
PORTS_A := [?][3]int {
	{53211, 53213, 53215},
	{53221, 53223, 53225},
	{53231, 53233, 53235},
	{53241, 53243, 53245},
}
PORTS_B := [?][3]int {
	{53311, 53313, 53315},
	{53321, 53323, 53325},
	{53331, 53333, 53335},
	{53341, 53343, 53345},
}

// One row per test, so the four can run concurrently.
ROW_COUNTERS :: 0
ROW_STOP :: 1
ROW_STREAM :: 2
ROW_UPLOAD :: 3

// What a drain is given before it is called stuck. Generous rather than tight:
// the point of the assertion is "it finished at all, and the other one did not",
// never a latency measurement.
STOP_DEADLINE :: 5 * time.Second

@(private)
start_on_any :: proc(s: ^lab.Server, ports: [3]int) -> bool {
	for port in ports {
		if lab.Start(s, port, 4) {
			return true
		}
	}
	return false
}

// --- 1. the send counters diverge -------------------------------------------
//
// The sharpest assertion here is not that each count is right; it is that the
// two counts DIFFER. Under one process-wide slot both reads resolve to the same
// backend server, so `web.stats(&a.app)` and `web.stats(&b.app)` return
// byte-identical structs — plausible numbers, one of them about the wrong
// server, with nothing anywhere to say so.
@(test)
wp123_each_server_counts_only_its_own_responses :: proc(t: ^testing.T) {
	ROW :: ROW_COUNTERS
	a, b: lab.Server
	if !start_on_any(&a, PORTS_A[ROW]) {
		testing.expect(t, false, "no candidate port produced a working server A")
		return
	}
	defer lab.Stop(&a)
	if !start_on_any(&b, PORTS_B[ROW]) {
		testing.expect(t, false, "no candidate port produced a working server B")
		return
	}
	defer lab.Stop(&b)

	// Deliberately different volumes, so a shared counter cannot coincide with
	// either server's own total.
	N :: 7
	M :: 3
	for _ in 0 ..< N {
		status, _, ok := lab.Request(a.port, "/health")
		testing.expect(t, ok && status == 200, "server A must answer its own port")
	}
	for _ in 0 ..< M {
		status, _, ok := lab.Request(b.port, "/health")
		testing.expect(t, ok && status == 200, "server B must answer its own port")
	}
	// Let the send completions land before reading the counters.
	time.sleep(150 * time.Millisecond)

	sa := web.stats(&a.app)
	sb := web.stats(&b.app)
	fmt.printf(
		"[wp123] A(:%d) responses_sent=%d bytes=%d | B(:%d) responses_sent=%d bytes=%d\n",
		a.port,
		sa.responses_sent,
		sa.response_bytes,
		b.port,
		sb.responses_sent,
		sb.response_bytes,
	)

	// `Start` probes `/health` until it answers, so each server served one more
	// response than this test asked for. The bound is therefore `>=`, not `==` —
	// pinning the exact number would make this a test of the lab's startup probe.
	testing.expectf(
		t,
		sa.responses_sent >= N + 1,
		"server A served %d requests and reports responses_sent=%d",
		N + 1,
		sa.responses_sent,
	)
	testing.expectf(
		t,
		sb.responses_sent >= M + 1,
		"server B served %d requests and reports responses_sent=%d",
		M + 1,
		sb.responses_sent,
	)
	// THE DISCRIMINATOR. One shared slot makes these identical.
	testing.expectf(
		t,
		sa.responses_sent != sb.responses_sent,
		"both servers report the SAME responses_sent (%d): the counters resolve to one shared server, not to the App each was asked about",
		sa.responses_sent,
	)
	// And neither is the process total, which is what a shared counter would be.
	testing.expectf(
		t,
		sa.responses_sent < (N + 1) + (M + 1),
		"server A reports %d, at or above the whole process's %d responses: it is counting server B's traffic too",
		sa.responses_sent,
		(N + 1) + (M + 1),
	)
	testing.expectf(
		t,
		sb.responses_sent < (N + 1) + (M + 1),
		"server B reports %d, at or above the whole process's %d responses: it is counting server A's traffic too",
		sb.responses_sent,
		(N + 1) + (M + 1),
	)
}

// --- 2. a stop drains one and leaves the other serving -----------------------
//
// Waited on with a DEADLINE and never with `thread.join`: `join` cannot time
// out, so a suite built on it can only hang when the thing it tests hangs (the
// WP58 harness rule). Here that matters twice over, because the failure this
// asserts against is precisely a `stop` that drained the wrong server — leaving
// the one it was called on blocked in `serve` forever.
@(test)
wp123_stopping_one_server_leaves_the_other_serving :: proc(t: ^testing.T) {
	ROW :: ROW_STOP
	a, b: lab.Server
	if !start_on_any(&a, PORTS_A[ROW]) {
		testing.expect(t, false, "no candidate port produced a working server A")
		return
	}
	if !start_on_any(&b, PORTS_B[ROW]) {
		testing.expect(t, false, "no candidate port produced a working server B")
		lab.Stop(&a)
		return
	}

	// Stop A only.
	lab.Stop_Async(&a)
	testing.expect(
		t,
		lab.Wait_Stopped(&a, STOP_DEADLINE),
		"web.stop(&a.app) must drain server A: its serve did not return within the deadline, which is what a stop aimed at the wrong server looks like from here",
	)
	lab.Reap(&a)

	// B is untouched.
	status, _, ok := lab.Request(b.port, "/health")
	testing.expectf(
		t,
		ok && status == 200,
		"server B stopped answering when server A was stopped (ok=%v status=%d)",
		ok,
		status,
	)

	sb := web.stats(&b.app)
	testing.expect(
		t,
		sb.responses_sent > 0,
		"server B's counters went to zero when server A stopped: its registry entry was retired by the other server's drain",
	)

	lab.Stop_Async(&b)
	testing.expect(t, lab.Wait_Stopped(&b, STOP_DEADLINE), "server B must drain too")
	lab.Reap(&b)
}

// --- 3. a stream token names ITS server --------------------------------------
//
// `web.stream_send` takes neither a Context nor an App. It is the one public
// surface that reaches the transport from any thread with nothing in hand but a
// value the application is holding — so before WP123 it resolved through the
// process-wide slot, and in a two-server process a send on server A's stream
// went looking in server B's registry and came back `Closed`. The token now
// carries its server, in the `@(private)` half of `Stream` that the frozen
// manifest does not pin.
@(test)
wp123_a_stream_token_sends_to_the_server_that_opened_it :: proc(t: ^testing.T) {
	ROW :: ROW_STREAM
	a, b: lab.Server
	if !start_on_any(&a, PORTS_A[ROW]) {
		testing.expect(t, false, "no candidate port produced a working server A")
		return
	}
	defer lab.Stop(&a)
	// B starts SECOND on purpose: the old single slot was last-writer-wins, so a
	// server started after the stream's owner is what made the send fail.
	if !start_on_any(&b, PORTS_B[ROW]) {
		testing.expect(t, false, "no candidate port produced a working server B")
		return
	}
	defer lab.Stop(&b)

	sock, dialled := lab.Open_Idle(a.port)
	if !dialled {
		testing.expect(t, false, "the stream client must connect to server A")
		return
	}
	defer net.close(sock)
	request := "GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n"
	if _, err := net.send_tcp(sock, transmute([]u8)string(request)); err != nil {
		testing.expect(t, false, "the stream request must be sent")
		return
	}

	s, opened := lab.Stream(&a)
	testing.expect(t, opened, "server A's handler must open a detached stream")
	if !opened {
		return
	}

	testing.expect(
		t,
		web.stream_live(s),
		"the stream is not live while server A is running: the token resolved against another server's registry",
	)
	sent := web.stream_send(s, transmute([]u8)string("tick"))
	testing.expectf(
		t,
		sent == .Sent,
		"stream_send on server A's token returned %v: a token opened on A must reach A's registry while B is also running",
		sent,
	)

	web.stream_close(s)
	testing.expect(t, !web.stream_live(s), "a closed stream is not live")
}

// --- 4. one server's stop does not close another's upload admission ----------
//
// The third pointer, and the one a suite is most likely to leave uncovered. The
// old slot took the upload admission ONLY from a server that enabled uploads, so
// a second server without uploads did not overwrite it — it inherited it. A stop
// aimed at that second server then drained the FIRST server's spooler, and every
// large body after it was answered 413 by a server nobody had stopped.
@(test)
wp123_stopping_a_server_does_not_drain_another_servers_uploads :: proc(t: ^testing.T) {
	ROW :: ROW_UPLOAD
	dir := "/tmp/druse-wp123-uploads"
	if !os.exists(dir) {
		if err := os.make_directory(dir); err != nil && !os.exists(dir) {
			testing.expect(t, false, "the spool directory must exist")
			return
		}
	}

	a, b: lab.Server
	started := false
	for port in PORTS_A[ROW] {
		if lab.Start_With_Upload(&a, port, dir) {
			started = true
			break
		}
	}
	if !started {
		testing.expect(t, false, "no candidate port produced a working upload server A")
		return
	}
	defer lab.Stop(&a)
	if !start_on_any(&b, PORTS_B[ROW]) {
		testing.expect(t, false, "no candidate port produced a working server B")
		return
	}

	// A body over server A's 1 KiB `max_body`, so the spooler — not the buffered
	// path — is what answers.
	body := strings.repeat("x", 4096, context.temp_allocator)
	spool_request := strings.concatenate(
		{
			"POST /spool HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n",
			body,
		},
		context.temp_allocator,
	)

	before, raw_before, ok_before := lab.Raw_Request(a.port, spool_request)
	defer delete(raw_before)
	testing.expectf(
		t,
		ok_before && before == 201,
		"positive control: server A must spool a 4 KiB body before anything is stopped (ok=%v status=%d)",
		ok_before,
		before,
	)

	// Stop B — a server that never enabled uploads at all.
	lab.Stop_Async(&b)
	testing.expect(t, lab.Wait_Stopped(&b, STOP_DEADLINE), "server B must drain")
	lab.Reap(&b)

	after, raw_after, ok_after := lab.Raw_Request(a.port, spool_request)
	defer delete(raw_after)
	testing.expectf(
		t,
		ok_after && after == 201,
		"server A answered %d (ok=%v) after server B was stopped: B's drain closed A's upload admission, which A never asked for",
		after,
		ok_after,
	)
}
