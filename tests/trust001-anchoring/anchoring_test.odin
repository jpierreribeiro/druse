// TRUST-001 — a trusted-proxy entry must not silently widen.
//
// THE DEFECT. `trust_proxies` matched an unanchored textual prefix, so writing
// `"127.0.0.1"` to name one proxy also trusted `127.0.0.10` through
// `127.0.0.199` — about a hundred and ten addresses nobody named — and there
// was no way to say "this address and only this address".
//
// It also falsified the argument the public doc used to justify textual
// matching over CIDR: *"a wrong prefix can only fail to trust one you did"*. A
// prefix that silently widens is exactly the failure that argument said could
// not happen. A design rationale that the implementation does not satisfy is
// worse than none, because a reader budgets risk against it.
//
// THE RULE UNDER TEST. An entry ending in `.` or `:` is a prefix; anything else
// must match the whole address.
//
// WHY THIS SUITE DRIVES A REAL SOCKET RATHER THAN CALLING THE MATCHER. The
// matcher is private, and a unit test of a private helper proves the helper —
// not the boundary. The property that matters is what `web.client_ip` reports
// to an application, because that is the value an app uses for rate limiting,
// audit logs and authorization. So every case here goes over a socket, through
// the adapter, and reads what a handler would read.
//
// EVERY CASE IS RED ON THE UNANCHORED MATCHER except the two that were already
// correct, and those two are here on purpose: a suite that only proves the fix
// cannot tell a fix from a matcher that trusts nothing.
package trust001_anchoring

import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import web "druse:web"

// ONE PORT ROW PER TEST, not a shared pool. The suite runs with the default
// parallel test runner, and the first edition gave every case the same six
// candidates: a case bound a port, a sibling case connected to it, and read a
// server registered with a DIFFERENT trust entry. The positive control went red
// for a reason that had nothing to do with the matcher.
//
// That is the same defect shape the WP05 harness hit hours earlier — a
// measurement reading the wrong process — and `tests/wp123-two-servers` already
// carries the fix in a comment: giving each test its own row REMOVES the race
// instead of surviving it. Retries would have hidden it.
@(private = "file")
ROWS :: 8
@(private = "file")
PORTS :: [ROWS][3]int {
	{34811, 34871, 34931},
	{34812, 34872, 34932},
	{34813, 34873, 34933},
	{34814, 34874, 34934},
	{34815, 34875, 34935},
	{34816, 34876, 34936},
	{34817, 34877, 34937},
	{34818, 34878, 34938},
}

@(private = "file")
Server :: struct {
	app:     web.App,
	port:    int,
	ready:   sync.Sema,
	thread:  ^thread.Thread,
	running: bool,
}

@(private = "file")
report_client_ip :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, web.client_ip(ctx))
}

// start brings a server up with ONE trust entry, which is the whole point: each
// case names a single entry and asks what it does and does not trust.
@(private = "file")
start :: proc(s: ^Server, entry: string, row: int) -> bool {
	// Odin cannot index a compile-time constant array with a runtime value;
	// copying the row into a local is the suggested form and costs nothing.
	candidates := PORTS
	for port in candidates[row] {
		s.port = port
		s.app = web.app()
		web.get(&s.app, "/whoami", report_client_ip)
		web.trust_proxies(&s.app, []string{entry})
		s.running = true
		s.thread = thread.create_and_start_with_poly_data(s, serve_thread)
		sync.wait(&s.ready)
		// A bound port answers; a busy one does not. Trying the next candidate
		// is how this suite coexists with anything else on the box.
		for _ in 0 ..< 50 {
			if _, ok := raw_get(s.port, ""); ok {
				return true
			}
			time.sleep(40 * time.Millisecond)
		}
		stop(s)
	}
	return false
}

@(private = "file")
stop :: proc(s: ^Server) {
	if !s.running {
		return
	}
	web.stop(&s.app)
	if s.thread != nil {
		thread.join(s.thread)
		thread.destroy(s.thread)
		s.thread = nil
	}
	web.destroy(&s.app)
	s.running = false
}

// THE SERVER POINTER IS PASSED, NEVER SHARED THROUGH A GLOBAL. The first
// edition copied the single-server pattern from `tests/c06-proxy-contract`,
// which parks the server in a package-level `g_server` — safe there, because
// that suite has one. Here six cases run in parallel, and a serve thread read a
// SIBLING's server: two cases finished and four hung for eight minutes.
//
// Third time today that a shared handle let one thing act on another's state —
// after the orphaned soak server on port 8080 and the shared port pool above.
// The fix is the same each time: give each unit its own, do not coordinate.
@(private = "file")
serve_thread :: proc(sv: ^Server) {
	sync.post(&sv.ready)
	web.serve(&sv.app, sv.port)
}

// raw_get returns the body of GET /whoami, optionally carrying an
// X-Forwarded-For, written on the wire exactly as a proxy writes it.
@(private = "file")
raw_get :: proc(port: int, forwarded_for: string) -> (string, bool) {
	endpoint := net.Endpoint {
		address = net.IP4_Loopback,
		port    = port,
	}
	sock, err := net.dial_tcp(endpoint)
	if err != nil {
		return "", false
	}
	defer net.close(sock)

	request: string
	if len(forwarded_for) > 0 {
		request = fmt.tprintf(
			"GET /whoami HTTP/1.1\r\nHost: t\r\nX-Forwarded-For: %s\r\nConnection: close\r\n\r\n",
			forwarded_for,
		)
	} else {
		request = "GET /whoami HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"
	}
	if _, werr := net.send_tcp(sock, transmute([]u8)request); werr != nil {
		return "", false
	}

	buf: [4096]u8
	total := 0
	for total < len(buf) {
		n, rerr := net.recv_tcp(sock, buf[total:])
		if rerr != nil || n == 0 {
			break
		}
		total += n
	}
	text := string(buf[:total])
	idx := strings.index(text, "\r\n\r\n")
	if idx < 0 {
		return "", false
	}
	return strings.clone(text[idx + 4:], context.temp_allocator), true
}

// answers_forwarded reports whether a server registered with `entry` accepted
// the forwarded address — i.e. whether it trusted the loopback peer.
@(private = "file")
answers_forwarded :: proc(t: ^testing.T, entry: string, row: int) -> (trusted: bool, ok: bool) {
	s: Server
	if !start(&s, entry, row) {
		testing.expect(t, false, "no candidate port produced a working server")
		return false, false
	}
	defer stop(&s)

	body, got := raw_get(s.port, "203.0.113.7")
	if !got {
		testing.expect(t, false, "the server did not answer /whoami")
		return false, false
	}
	// Trusted  -> client_ip is the forwarded client.
	// Untrusted-> client_ip is the socket peer, which is loopback.
	return body == "203.0.113.7", true
}

// --- 1. the defect itself -----------------------------------------------------
//
// The peer is 127.0.0.1. An entry of "127.0.0." is a prefix and MUST trust it.
// This is the case that proves the suite can observe trust at all; without it,
// every assertion below is satisfied by a matcher that trusts nothing.
@(test)
trust001_a_prefix_entry_still_trusts_under_it :: proc(t: ^testing.T) {
	trusted, ok := answers_forwarded(t, "127.0.0.", 0)
	if !ok {
		return
	}
	testing.expect(
		t,
		trusted,
		"an entry ending in '.' is a prefix and must trust every address under it; the loopback peer was not trusted, so this suite cannot observe trust and none of its negative cases mean anything",
	)
}

// An exact entry for the peer's own address MUST trust it. The fix must not
// have turned exact matching into no matching.
@(test)
trust001_an_exact_entry_trusts_that_address :: proc(t: ^testing.T) {
	trusted, ok := answers_forwarded(t, "127.0.0.1", 1)
	if !ok {
		return
	}
	testing.expect(
		t,
		trusted,
		"the entry names the peer's exact address and must trust it",
	)
}

// THE DEFECT. The peer is 127.0.0.1. An entry of "127.0.0.19" names a DIFFERENT
// address, and under the unanchored matcher `has_prefix("127.0.0.1", ...)` is
// false — so this direction was never the bug. The bug is the other direction,
// below.
//
// This case pins the half that was always right, so a regression that widens
// only one way is still caught.
@(test)
trust001_a_longer_unrelated_entry_does_not_trust :: proc(t: ^testing.T) {
	trusted, ok := answers_forwarded(t, "127.0.0.199", 2)
	if !ok {
		return
	}
	testing.expect(
		t,
		!trusted,
		"127.0.0.199 is not the peer 127.0.0.1 and must not be trusted",
	)
}

// --- 2. the widening, from the other side ------------------------------------
//
// THIS IS THE CASE THAT WAS RED. The peer is 127.0.0.1, and the entry "127.0.0"
// — a plausible typo, one character short — matched it textually under the old
// rule. It names no address: it is not an address and does not end in a
// separator, so it must trust nothing.
@(test)
trust001_a_truncated_entry_trusts_nothing :: proc(t: ^testing.T) {
	trusted, ok := answers_forwarded(t, "127.0.0", 3)
	if !ok {
		return
	}
	testing.expect(
		t,
		!trusted,
		"'127.0.0' is neither a whole address nor a separator-terminated prefix; under the unanchored matcher it silently trusted 127.0.0.1, which is TRUST-001",
	)
}

// The same shape one level up, because "127.0.0" could be dismissed as
// pathological. "127." IS a legitimate prefix and must trust; "127" is not and
// must not. One character apart, opposite answers, and that is the rule.
@(test)
trust001_the_separator_is_what_makes_a_prefix :: proc(t: ^testing.T) {
	with_dot, ok1 := answers_forwarded(t, "127.", 4)
	if !ok1 {
		return
	}
	testing.expect(t, with_dot, "'127.' is a separator-terminated prefix and must trust 127.0.0.1")

	without_dot, ok2 := answers_forwarded(t, "127", 5)
	if !ok2 {
		return
	}
	testing.expect(
		t,
		!without_dot,
		"'127' has no trailing separator and is not the whole address, so it must trust nothing — the trailing '.' is the entire difference and the rule rests on it",
	)
}

// --- 3. the shared matcher, and the chain walk that also used it ---------------
//
// `trusted_prefix_match` decides trust in TWO places: the connected peer, and
// every hop of the right-to-left `X-Forwarded-For` walk (ADR-037). The widening
// therefore applied to both, and the walk is where it moves a value rather than
// merely blurring a set.
//
// THE WALK'S RULE: scan right to left; the first hop that is NOT a trusted proxy
// is the answer. So over-trusting a hop makes the walk step PAST it, one place
// further left — and left is the direction the client controls.
//
// Peer 127.0.0.1, trusted exactly. Header `"9.9.9.9, 127.0.0.199"`.
//
//	unanchored: "127.0.0.199" matched the entry "127.0.0.1", was skipped as a
//	            trusted proxy, and the walk returned "9.9.9.9"
//	anchored:   "127.0.0.199" is not the entry, the walk stops there
//
// WHAT THIS DOES AND DOES NOT SHOW, because the difference matters. Both values
// here come from the same client, so this case demonstrates the MECHANISM — the
// walk stepping one hop too far — not a completed forgery. Reaching a fully
// forged value additionally requires a proxy that passes `X-Forwarded-For`
// through instead of appending to it, which some do and this suite does not
// model. Claiming more than the fixture proves would be the same kind of
// overclaim the doc's own CIDR argument made.
@(test)
trust001_the_chain_walk_stops_at_a_lookalike_hop :: proc(t: ^testing.T) {
	s: Server
	if !start(&s, "127.0.0.1", 7) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}
	defer stop(&s)

	body, got := raw_get(s.port, "9.9.9.9, 127.0.0.199")
	if !got {
		testing.expect(t, false, "the server did not answer /whoami")
		return
	}
	testing.expectf(
		t,
		body == "127.0.0.199",
		`the walk must stop at the first hop that is not the trusted entry. Got %q: under the unanchored matcher "127.0.0.199" was accepted as the proxy "127.0.0.1" and the walk stepped one hop further left, which is the direction a client controls`,
		body,
	)
}

// --- 4. the untrusted default is unchanged -----------------------------------
//
// An entry that names an unrelated network must leave the header ignored and
// report the socket peer. This is the fail-closed default the public doc
// promises, and the fix must not have disturbed it.
@(test)
trust001_an_unrelated_entry_reports_the_socket_peer :: proc(t: ^testing.T) {
	s: Server
	if !start(&s, "10.", 6) {
		testing.expect(t, false, "no candidate port produced a working server")
		return
	}
	defer stop(&s)

	body, got := raw_get(s.port, "203.0.113.7")
	if !got {
		testing.expect(t, false, "the server did not answer /whoami")
		return
	}
	testing.expectf(
		t,
		body == "127.0.0.1",
		"an untrusted peer's X-Forwarded-For must be ignored and the socket peer reported; got %q",
		body,
	)
	log.infof("untrusted peer reported as %q", body)
}
