// WP41 — THE DETERMINISTIC TRANSPORT FAULT LABORATORY.
//
// P-T5, deferred here by name from the Phase-3 plan. This package is the
// INSTRUMENT; `tests/wp41-fault/` is the suite that drives it. The split is the
// WP9 arrangement and it exists for the same reason: the fault menu is
// backend-agnostic DATA, so a future transport can be held to the same menu
// without touching the driver.
//
// WHAT A "FAULT" IS HERE. Every fault in this menu is something a CLIENT can do
// to a server over a real socket, plus two the test process can do to itself
// (request a shutdown mid-flight, register a conflicting route). That boundary
// is deliberate: a lab that reaches inside the server to break it is testing a
// mock, and the whole point is to find out how the REAL server behaves.
//
// DETERMINISM IS THE PRODUCT, and it is what separates this from "run some
// weird requests and see". The seed selects the faults, their parameters and
// their order; the run records a TRAIL; and the success criterion — fixed
// before this file was written — is that the same seed replays the same trail.
// Without that, a failure found at 3 a.m. cannot be handed to anyone.
//
// WHAT THIS PACKAGE MAY NOT DO, because it is machinery and the guardrails
// apply to machinery too (the WP3 rule): it imports no `druse:web`, declares
// no `any` and no state bag, and owns no global. The suite passes it a `^Lab`.
package fault_lab

import "core:fmt"
import "core:net"
import "core:strings"
import "core:time"

// Fault is the closed menu. It is an enum rather than a list of procedures for
// the reason `Framework_Error` is one: a reviewer must be able to enumerate it,
// and a seed must be able to select from it by index.
//
// The menu is the Phase-4 plan's, item for item, plus the boot-time entry E-4
// added after WP30 shipped registration-conflict poisoning.
Fault :: enum {
	// The request arrives in pieces, with the split at a hostile offset —
	// mid-header-name, mid-value, or between CR and LF.
	Fragmented_Request,
	// The client writes its request one byte at a time with a delay between
	// them. This is slowloris in miniature, and today nothing stops it.
	Slow_Writer,
	// The client sends a complete request and then does not read the response.
	Slow_Reader,
	// The client closes the connection with the request half-sent.
	Close_Mid_Request,
	// The client sends exactly N bytes of a well-formed request and stops
	// WITHOUT closing — the socket stays open and idle.
	Truncate_And_Hold,
	// The client sends a complete request and closes immediately, without
	// waiting for the response.
	Close_Before_Response,
	// Many sequential connections on one server, to exercise whatever slot
	// reuse the transport has. WP35 found no reuse; this is how a later phase
	// would notice reuse appearing.
	Sequential_Reuse,
	// A shutdown is requested while a request is in flight. This is §1.3's
	// obligations 1-4 made reachable.
	Shutdown_Mid_Request,
}

// FAULT_COUNT lets the seeded selector index the menu without importing
// reflection. `len(Fault)` would do it, and this spelling keeps the intent
// obvious at the call site.
FAULT_COUNT :: len(Fault)

// Outcome is what the lab OBSERVED, not what it hoped for. Every member is a
// thing that actually happens over a socket; there is deliberately no `Error`
// member, because "something went wrong" is not an observation.
Outcome :: enum {
	// The server answered, and the status line parsed.
	Responded,
	// The server closed without answering.
	Closed_Without_Response,
	// The connection stayed open with nothing written, until the lab's own
	// patience ran out. THIS IS THE ONE THAT MATTERS: it is what a missing
	// read deadline looks like from the outside.
	Held_Open_Until_Lab_Gave_Up,
	// The lab could not connect at all.
	Connect_Refused,
}

// Event is one line of the trail. It is a VALUE with no pointers: the trail is
// compared between runs, so anything address-shaped in it would make two
// identical runs differ.
Event :: struct {
	fault:   Fault,
	// The seeded parameter this step used — a byte offset, a chunk count, a
	// delay in milliseconds. Recorded because "fragmented at 7" and
	// "fragmented at 40" are different tests and a trail that cannot tell them
	// apart cannot be replayed.
	param:   int,
	outcome: Outcome,
	// The status the server sent, or 0. Not the body: a trail that carried
	// response bodies would be a trail nobody reads.
	status:  int,
}

// TRAIL_MAX bounds the trail, and the bound is the point rather than a
// limitation. A lab that can allocate without limit under fault injection is a
// lab that can run the machine out of memory while looking for a bug about
// running out of memory.
TRAIL_MAX :: 256

// Lab holds one run. The suite owns it; this package owns nothing.
Lab :: struct {
	// The seed, kept so a failing run can print the one number needed to
	// reproduce it.
	seed:      u64,
	// The PRNG state. A tiny xorshift rather than `core:math/rand`, on purpose:
	// this must produce the same sequence on any build of any toolchain, and a
	// standard-library generator is free to change its algorithm between
	// versions. Reproducibility that depends on someone else's release notes is
	// not reproducibility.
	state:     u64,
	trail:     [TRAIL_MAX]Event,
	trail_len: int,
	// How long the lab waits before calling a silent connection "held open".
	// It is a property of the LAB, not of the server, and it is recorded in the
	// suite's assertions so nobody reads it as a framework timeout.
	patience:  time.Duration,
}

// lab_init seeds the run. A seed of zero is replaced, because xorshift is stuck
// at zero — a silently constant "random" sequence is the worst possible failure
// for a tool whose product is determinism.
lab_init :: proc(l: ^Lab, seed: u64, patience := 400 * time.Millisecond) {
	l.seed = seed
	l.state = seed if seed != 0 else 0x9E3779B97F4A7C15
	l.trail_len = 0
	l.patience = patience
}

// next_u64 is xorshift64*. Fixed here, in the repository, for the reason
// `lab_init` gives.
@(private)
next_u64 :: proc(l: ^Lab) -> u64 {
	x := l.state
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	l.state = x
	return x * 0x2545F4914F6CDD1D
}

// next_int returns a value in [0, n). `n <= 0` yields 0 rather than dividing by
// zero: a lab that crashes on its own parameters teaches nothing.
next_int :: proc(l: ^Lab, n: int) -> int {
	if n <= 0 {
		return 0
	}
	return int(next_u64(l) % u64(n))
}

// next_fault selects from the closed menu.
next_fault :: proc(l: ^Lab) -> Fault {
	return Fault(next_int(l, FAULT_COUNT))
}

// record appends one event. It DROPS silently past the bound and says so
// through `trail_full`, rather than growing: see TRAIL_MAX.
record :: proc(l: ^Lab, fault: Fault, param: int, outcome: Outcome, status: int) {
	if l.trail_len >= TRAIL_MAX {
		return
	}
	l.trail[l.trail_len] = Event {
		fault   = fault,
		param   = param,
		outcome = outcome,
		status  = status,
	}
	l.trail_len += 1
}

trail_full :: proc(l: ^Lab) -> bool {
	return l.trail_len >= TRAIL_MAX
}

// trails_equal is the determinism check itself. Two runs of one seed must
// produce identical trails, and "identical" means every field of every event —
// not the length, and not a summary.
trails_equal :: proc(a: ^Lab, b: ^Lab) -> bool {
	if a.trail_len != b.trail_len {
		return false
	}
	for i in 0 ..< a.trail_len {
		x := a.trail[i]
		y := b.trail[i]
		if x.fault != y.fault || x.param != y.param {
			return false
		}
		if x.outcome != y.outcome || x.status != y.status {
			return false
		}
	}
	return true
}

// ---------------------------------------------------------------------------
// The socket side.
//
// Everything below drives a REAL connection. There is no mock, and there is no
// hook into the server: the lab is a hostile client and nothing more, which is
// what makes its findings about the shipped transport rather than about a
// double.
// ---------------------------------------------------------------------------

// GET_PING is the well-formed request the faults deform. Keeping one canonical
// request means a difference in outcome is attributable to the fault rather
// than to the request.
GET_PING :: "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"

// GET_PING_KEEPALIVE is the same request WITHOUT `Connection: close`, so the
// server is expected to keep the connection for a second request.
//
// WP45 needs it because every existing corpus case sends `close`: the suites
// prove that a BAD request retires a connection, and nothing proved that a GOOD
// one preserves it. A server that closed after every response would pass the
// entire existing suite while making keep-alive a lie.
GET_PING_KEEPALIVE :: "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n"

// A deliberately malformed request: two `Content-Length` headers. WP9's patch 4
// rejects it, and WP45 asks the question WP9 did not — whether the client
// actually RECEIVES the rejection before the connection goes away.
BAD_DOUBLE_LENGTH :: "POST /ping HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"

// dial connects, or reports that it could not. The lab treats a refused
// connection as an OUTCOME rather than an error, because during
// `Shutdown_Mid_Request` a refusal is the correct behaviour.
dial :: proc(port: int, patience := 400 * time.Millisecond) -> (sock: net.TCP_Socket, ok: bool) {
	endpoint := net.Endpoint {
		address = net.IP4_Address{127, 0, 0, 1},
		port    = port,
	}
	s, err := net.dial_tcp(endpoint)
	if err != nil {
		return {}, false
	}

	// THE RECEIVE TIMEOUT IS NOT A CONVENIENCE, and leaving it out cost a hung
	// suite before it was added. `net.recv_tcp` BLOCKS. A patience loop around a
	// blocking read never re-evaluates its own deadline: the first read parks
	// forever and the loop body never runs again.
	//
	// The irony is the finding itself. This lab exists to prove the server
	// holds a silent connection open indefinitely — and without this option the
	// LAB hangs on exactly that behaviour, which is the same defect wearing the
	// client's clothes. A timeout that is only ever set on one side of a
	// connection is a timeout somebody is relying on the other side to have.
	if net.set_option(s, .Receive_Timeout, patience) != nil {
		net.close(s)
		return {}, false
	}
	return s, true
}

// read_status waits up to the lab's patience for a status line.
//
// THE RETURN VALUE IS AN OBSERVATION, and the distinction it draws is the whole
// reason this procedure is careful: a server that CLOSES without answering is
// behaving badly but bounded, while a server that HOLDS THE CONNECTION OPEN
// forever is the unbounded case a read deadline exists to prevent. Collapsing
// them into "no response" would erase exactly the finding this lab was built to
// produce.
read_status :: proc(l: ^Lab, sock: net.TCP_Socket) -> (outcome: Outcome, status: int) {
	buf: [512]u8
	deadline := time.now()
	total := 0

	for time.duration_milliseconds(time.since(deadline)) < time.duration_milliseconds(l.patience) {
		n, err := net.recv_tcp(sock, buf[total:])
		if err != nil {
			// TWO DIFFERENT THINGS ARRIVE HERE and collapsing them would erase
			// the finding this lab was built to produce.
			//
			// A TIMEOUT means the socket is still open and the server has said
			// nothing — the unbounded case. A reset or refusal means the server
			// closed — bad, but bounded. `dial` sets a receive timeout, so the
			// former is reachable at all; without distinguishing them, a server
			// that hangs and a server that hangs up would read identically.
			if is_timeout(err) {
				if total == 0 {
					return .Held_Open_Until_Lab_Gave_Up, 0
				}
				break
			}
			return .Closed_Without_Response if total == 0 else .Responded, parse_status(string(buf[:total]))
		}
		if n == 0 {
			// Orderly close.
			if total == 0 {
				return .Closed_Without_Response, 0
			}
			break
		}
		total += n
		if total >= len(buf) {
			break
		}
		if strings.contains(string(buf[:total]), "\r\n") {
			break
		}
	}

	if total == 0 {
		return .Held_Open_Until_Lab_Gave_Up, 0
	}
	return .Responded, parse_status(string(buf[:total]))
}

// is_timeout separates "nothing arrived in time" from "the connection broke".
//
// Odin surfaces the platform's `EAGAIN`/`EWOULDBLOCK` for an expired receive
// timeout, and the spelling differs per platform, so this matches on the
// enumerant NAME rather than on a numeric value — a lab that only worked on
// Linux would be a lab whose findings nobody else can reproduce.
@(private)
is_timeout :: proc(err: net.Network_Error) -> bool {
	text := fmt.tprintf("%v", err)
	return strings.contains(text, "Timeout") ||
		strings.contains(text, "Would_Block") ||
		strings.contains(text, "WOULD_BLOCK") ||
		strings.contains(text, "EAGAIN") ||
		strings.contains(text, "Again")
}

// read_status_again reads a SECOND response from the same socket.
//
// It exists because `read_status` stops at the first CRLF, which leaves the
// rest of the first response in the socket buffer. For a keep-alive test the
// question is whether a second request is answered at all, so this drains
// whatever is pending and then reads until it sees another status line.
read_status_again :: proc(l: ^Lab, sock: net.TCP_Socket) -> (outcome: Outcome, status: int) {
	buf: [1024]u8
	total := 0
	deadline := time.now()

	for time.duration_milliseconds(time.since(deadline)) < time.duration_milliseconds(l.patience) {
		n, err := net.recv_tcp(sock, buf[total:])
		if err != nil {
			if is_timeout(err) {
				break
			}
			return .Closed_Without_Response if total == 0 else .Responded, parse_status(string(buf[:total]))
		}
		if n == 0 {
			break
		}
		total += n
		if total >= len(buf) {
			break
		}
	}

	if total == 0 {
		return .Held_Open_Until_Lab_Gave_Up, 0
	}
	// The buffer holds the tail of the first response and all of the second.
	// The LAST status line in it is the one this call is about.
	text := string(buf[:total])
	last := -1
	for i := 0; i + 8 < len(text); i += 1 {
		if text[i:i + 5] == "HTTP/" {
			last = i
		}
	}
	if last < 0 {
		return .Responded, 0
	}
	return .Responded, parse_status(text[last:])
}

// parse_status reads the three digits of `HTTP/1.1 NNN`. It returns 0 for
// anything it does not recognise rather than guessing.
@(private)
parse_status :: proc(head: string) -> int {
	space := strings.index_byte(head, ' ')
	if space < 0 || space + 4 > len(head) {
		return 0
	}
	value := 0
	for i in space + 1 ..< space + 4 {
		c := head[i]
		if c < '0' || c > '9' {
			return 0
		}
		value = value * 10 + int(c - '0')
	}
	return value
}

// send_all writes the whole slice, or reports failure. A partial write treated
// as success is how a "the server did not answer" finding gets manufactured by
// the client.
@(private)
send_all :: proc(sock: net.TCP_Socket, data: []u8) -> bool {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(sock, data[sent:])
		if err != nil || n <= 0 {
			return false
		}
		sent += n
	}
	return true
}

// send_fragmented writes the request in `chunks` pieces, pausing between them.
// The split offsets come from the seed, so a run that finds a bug at a
// particular boundary can be replayed at that boundary.
send_fragmented :: proc(sock: net.TCP_Socket, request: string, chunks: int, gap: time.Duration) -> bool {
	data := transmute([]u8)request
	if chunks <= 1 {
		return send_all(sock, data)
	}
	size := len(data) / chunks
	if size < 1 {
		size = 1
	}
	offset := 0
	for offset < len(data) {
		end := offset + size
		if end > len(data) {
			end = len(data)
		}
		if !send_all(sock, data[offset:end]) {
			return false
		}
		offset = end
		if offset < len(data) {
			time.sleep(gap)
		}
	}
	return true
}

// send_trickle writes one byte at a time. This is the slowloris shape, and on a
// server with no read deadline it holds a connection open for as long as the
// client cares to continue.
send_trickle :: proc(sock: net.TCP_Socket, request: string, gap: time.Duration, limit: int) -> bool {
	data := transmute([]u8)request
	stop := limit if limit > 0 && limit < len(data) else len(data)
	for i in 0 ..< stop {
		if !send_all(sock, data[i:i + 1]) {
			return false
		}
		time.sleep(gap)
	}
	return true
}

// send_prefix writes the first `n` bytes and stops, leaving the socket OPEN.
// The difference from `Close_Mid_Request` is the whole point: one tells the
// server the client is gone, the other tells it nothing at all.
send_prefix :: proc(sock: net.TCP_Socket, request: string, n: int) -> bool {
	data := transmute([]u8)request
	stop := n
	if stop > len(data) {
		stop = len(data)
	}
	if stop <= 0 {
		return true
	}
	return send_all(sock, data[:stop])
}
