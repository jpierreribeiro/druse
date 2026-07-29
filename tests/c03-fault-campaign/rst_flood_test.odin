// C-03 — the RST-flood liveness wedge, reproduced.
//
// THE INHERITED FINDING. `docs/reports/2026-07-23-security-f001-f002.md` closed
// F-002 (a use-after-free through a deferred dispatch) and recorded, as
// explicitly out of scope, a remaining defect:
//
//	"Under a SUSTAINED RST flood the server stops accepting (all threads alive,
//	 listen backlog fills, no crash) — a liveness wedge in the vendored
//	 lane/accept machinery."
//
// The Closure owns it (production-readiness-closure.md §4), and owning it means
// MEASURING it before fixing it. A wedge described in prose has one mechanism
// in the reader's head and possibly another in the process; this suite decides
// which, by driving the flood and probing liveness at the same time.
//
// THE TWO CANDIDATE MECHANISMS, both visible from the C-01 inventory, and they
// call for opposite fixes:
//
//	(a) THE ADMISSION SLOT IS HELD FOR 500 ms AFTER THE PEER IS GONE.
//	    `connection_close` shuts the send side, arms `Conn_Close_Delay` (500 ms,
//	    "so the client can fully receive the response" — RFC 7230 6.6), and only
//	    then closes; `active_connections` is decremented in
//	    `connection_teardown`, at the END of that chain. So a connection whose
//	    peer has ALREADY sent RST — where there is nobody left to be polite to —
//	    still occupies one of `max_connections - reserved_conns` slots for half
//	    a second. A flood only has to open connections faster than
//	    budget / 500 ms to make every subsequent client hit the admission
//	    refusal. The server is then alive, accepting, and refusing everyone.
//
//	(b) THE ACCEPT RE-ARM IS DELAYED BY 10 ms PER TRANSIENT FAILURE.
//	    An RST that arrives before `accept` returns produces `ECONNABORTED`.
//	    Patch 21 tolerates it by re-arming after `DRUSE_ACCEPT_RETRY_DELAY`
//	    (10 ms). Under a sustained flood most accepts can fail this way, so each
//	    lane spends 10 ms not accepting per failure — an accept rate of roughly
//	    100/s/lane, and the listen backlog fills behind it.
//
// (a) predicts refusals with a healthy accept rate; (b) predicts connect
// timeouts with a filling backlog. They are distinguishable by what the probe
// sees, which is why the probe records the FAILURE KIND and not just a count.
//
// METHOD. Real sockets, a bounded flood, and a probe that runs THROUGHOUT and
// again AFTER — because a wedge that recovers the moment the flood stops is a
// capacity effect, and one that persists is a wedge. Numbers are printed
// whatever the verdict: the measurement is the deliverable even when it passes.
package test_c03_fault_campaign

import "core:fmt"
import "core:net"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

// The flood's own constants. The harness (Server, start_server, dial,
// set_linger, stop_server) lives in `harness.odin`, shared with the other
// cells.

// A SMALL admission budget on purpose. The wedge is a ratio — flood rate
// against budget over the close delay — so shrinking the budget reaches it with
// a flood a test machine can produce without becoming a load generator. With
// 64 - 4 = 60 slots and a 500 ms close delay, mechanism (a) predicts saturation
// above roughly 120 connections per second; the measured flood ran three
// hundred times faster than that.
FLOOD_MAX_CONNECTIONS :: 64
FLOOD_RESERVED_CONNS :: 4

// How long the flood runs, and how many threads produce it.
FLOOD_WINDOW :: 3 * time.Second
FLOOD_THREADS :: 4

// The probe's own patience. Short: a probe that waits a second cannot tell a
// wedge from a slow server, and the question here is liveness, not latency.
PROBE_TIMEOUT :: 400 * time.Millisecond
PROBE_INTERVAL :: 50 * time.Millisecond

flood_limits :: proc() -> web.Limits {
	l := base_limits()
	l.max_connections = FLOOD_MAX_CONNECTIONS
	l.reserved_conns = FLOOD_RESERVED_CONNS
	return l
}

// ---------------------------------------------------------------------------
// The flood
// ---------------------------------------------------------------------------

Flood :: struct {
	port:    int,
	stop:    bool,
	opened:  int,
	refused: int,
}

g_flood: ^Flood

// One flood worker: connect, arm SO_LINGER {1, 0}, close. `close` on a linger-
// zero socket sends RST instead of FIN, which is the shape the F-002 report
// used and the shape a hostile client is cheapest to write.
flood_thread :: proc() {
	f := g_flood
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = f.port}
	for !sync.atomic_load(&f.stop) {
		sock, err := net.dial_tcp(ep)
		if err != nil {
			sync.atomic_add(&f.refused, 1)
			continue
		}
		sync.atomic_add(&f.opened, 1)
		_ = set_linger(sock, Linger_Value{1, 0})
		net.close(sock)
	}
}

// ---------------------------------------------------------------------------
// The probe — a healthy client, and it records HOW it failed
// ---------------------------------------------------------------------------

Probe_Result :: enum {
	Ok,
	Connect_Failed, // backlog full / listener not accepting  -> mechanism (b)
	Refused_After_Connect, // admitted then closed with no reply -> mechanism (a)
	Read_Failed,
}

probe_once :: proc(port: int) -> Probe_Result {
	ep := net.Endpoint{address = net.IP4_Address{127, 0, 0, 1}, port = port}
	sock, err := net.dial_tcp(ep)
	if err != nil {
		return .Connect_Failed
	}
	defer net.close(sock)
	_ = net.set_option(sock, .Receive_Timeout, PROBE_TIMEOUT)
	_ = net.set_option(sock, .Send_Timeout, PROBE_TIMEOUT)

	request := "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	buf := transmute([]u8)request
	sent := 0
	for sent < len(buf) {
		n, serr := net.send_tcp(sock, buf[sent:])
		if serr != nil || n <= 0 {
			return .Refused_After_Connect
		}
		sent += n
	}

	reply: [256]u8
	n, rerr := net.recv_tcp(sock, reply[:])
	if rerr != nil {
		return .Read_Failed
	}
	if n == 0 {
		// Admitted and then closed with nothing written: the admission refusal.
		return .Refused_After_Connect
	}
	head := string(reply[:n])
	if len(head) >= 12 && head[9:12] == "200" {
		return .Ok
	}
	return .Read_Failed
}

Probe_Tally :: struct {
	ok:      int,
	connect: int,
	refused: int,
	read:    int,
}

tally_add :: proc(tally: ^Probe_Tally, r: Probe_Result) {
	switch r {
	case .Ok:
		tally.ok += 1
	case .Connect_Failed:
		tally.connect += 1
	case .Refused_After_Connect:
		tally.refused += 1
	case .Read_Failed:
		tally.read += 1
	}
}

tally_total :: proc(tally: Probe_Tally) -> int {
	return tally.ok + tally.connect + tally.refused + tally.read
}

probe_for :: proc(port: int, window: time.Duration) -> Probe_Tally {
	tally: Probe_Tally
	deadline := time.time_add(time.now(), window)
	for time.since(deadline) < 0 {
		tally_add(&tally, probe_once(port))
		time.sleep(PROBE_INTERVAL)
	}
	return tally
}

// ---------------------------------------------------------------------------
// The measurement
// ---------------------------------------------------------------------------

@(test)
c03_a_healthy_client_survives_an_rst_flood :: proc(t: ^testing.T) {
	server: Server
	if !start_server(&server, flood_limits()) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}

	// The positive control runs FIRST. Without it, a server that never served
	// would produce the same verdict as the wedge, and the finding would be
	// about the suite.
	before := probe_for(server.port, 500 * time.Millisecond)
	fmt.printf(
		"[c03] before flood   ok=%d/%d connect_fail=%d refused=%d read_fail=%d\n",
		before.ok,
		tally_total(before),
		before.connect,
		before.refused,
		before.read,
	)

	flood := Flood {
		port = server.port,
	}
	g_flood = &flood
	threads: [FLOOD_THREADS]^thread.Thread
	for i in 0 ..< FLOOD_THREADS {
		threads[i] = thread.create_and_start(flood_thread)
	}

	during := probe_for(server.port, FLOOD_WINDOW)

	sync.atomic_store(&flood.stop, true)
	for i in 0 ..< FLOOD_THREADS {
		thread.join(threads[i])
		thread.destroy(threads[i])
	}
	g_flood = nil

	opened := sync.atomic_load(&flood.opened)
	rate := f64(opened) / time.duration_seconds(FLOOD_WINDOW)
	fmt.printf(
		"[c03] during flood   ok=%d/%d connect_fail=%d refused=%d read_fail=%d  (flood opened %d conns, ~%.0f/s)\n",
		during.ok,
		tally_total(during),
		during.connect,
		during.refused,
		during.read,
		opened,
		rate,
	)

	// Recovery is the difference between a capacity effect and a wedge.
	time.sleep(1500 * time.Millisecond)
	after := probe_for(server.port, 1 * time.Second)
	fmt.printf(
		"[c03] after flood    ok=%d/%d connect_fail=%d refused=%d read_fail=%d\n",
		after.ok,
		tally_total(after),
		after.connect,
		after.refused,
		after.read,
	)

	returned := stop_server(&server)

	testing.expect(t, returned, "the server must still shut down after an RST flood")
	testing.expectf(
		t,
		before.ok == tally_total(before),
		"the positive control failed: %d of %d probes succeeded with no flood running",
		before.ok,
		tally_total(before),
	)
	testing.expectf(
		t,
		after.ok == tally_total(after),
		"the server did not recover after the flood stopped: %d of %d probes succeeded — this is a WEDGE, not a capacity effect",
		after.ok,
		tally_total(after),
	)
	// The liveness claim. A framework may refuse work under load — that is the
	// admission bound doing its job — but a client sending one request per
	// 50 ms against a 60-slot budget is not the load. Half is a deliberately
	// generous floor: the claim is that the server keeps serving, not that it
	// is unaffected.
	testing.expectf(
		t,
		during.ok * 2 >= tally_total(during),
		"a healthy client was served %d of %d times during the flood (connect_fail=%d refused=%d read_fail=%d): the RST flood wedges liveness",
		during.ok,
		tally_total(during),
		during.connect,
		during.refused,
		during.read,
	)
}
