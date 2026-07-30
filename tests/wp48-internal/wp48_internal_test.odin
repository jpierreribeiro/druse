// WP48 internal contract — `client_ip` walks X-Forwarded-For FROM THE RIGHT
// (ADR-037).
//
// WHY THIS SUITE IS INTERNAL. `web.test_request` drives an in-memory request
// with NO peer, so `trusted_peer` is always false and the header is always
// ignored — the sharpest test of the DEFAULT, and exactly what the public
// wp48 suite asserts. But the correction ADR-037 makes is about the path the
// public suite cannot reach: what `client_ip` returns WHEN the peer IS a
// trusted proxy. That path needs a peer, and the only way to set one without a
// socket is to drive a `transport.Inbound` (which carries `peer`) straight
// through `driver_run`, the same entry point `serve` uses. So this suite is
// internal by necessity, the WP60/WP32b reason unchanged.
//
// THE ASYMMETRY THIS SUITE EXISTS FOR. `X-Forwarded-For` grows left to right;
// each proxy appends the address it saw. The leftmost entry is the one a client
// forges before any proxy touches it. The old implementation returned leftmost
// once a proxy was trusted — handing an attacker a free identity. The new one
// walks from the right, discards trusted hops, and returns the first untrusted
// address. The decisive case is
// `wp48i_a_spoofed_leftmost_is_ignored_behind_a_trusted_proxy`.
//
// The resolved address is read from the RESPONSE BODY of each request, never a
// shared global: the runner is multi-threaded, and a file-scope variable would
// race across the tests below.
package web

import "core:testing"
import "druse:web/internal/transport"

@(private = "file")
report_ip :: proc(ctx: ^Context) {
	text(ctx, .OK, client_ip(ctx))
}

// Drive one inbound with an explicit peer through the shared driver, exactly as
// a socket transport would, and return the address `client_ip` resolved (the
// response body). `peer` is the connected address; `xff` is the raw
// `X-Forwarded-For` value (empty means the header is absent). The caller must
// keep the returned Context alive while reading, then `response_destroy` it.
@(private = "file")
resolve :: proc(a: ^App, peer: string, xff: string, ctx: ^Context) -> string {
	headers: []transport.Header
	if len(xff) > 0 {
		headers = []transport.Header{{name = "X-Forwarded-For", value = xff}}
	}
	driver_run(a, ctx, transport.Inbound{method = "GET", path = "/ip", peer = peer, headers = headers})
	return string(response_body_view(ctx))
}

// THE TEST THIS SUITE EXISTS FOR. Behind a trusted proxy, a client-forged
// leftmost entry must be ignored: the walk starts at the right, skips the
// trusted proxy hop, and returns the first untrusted address — the genuine
// client, not the spoof.
@(test)
wp48i_a_spoofed_leftmost_is_ignored_behind_a_trusted_proxy :: proc(t: ^testing.T) {
	app := app()
	defer destroy(&app)
	trust_proxies(&app, {"10."})
	get(&app, "/ip", report_ip)

	// Chain: forged client, real client, trusted proxy. The peer is the trusted
	// proxy 10.0.0.1. Walking from the right: 10.0.0.1 trusted -> skip;
	// 198.51.100.7 untrusted -> return it.
	ctx: Context
	seen := resolve(&app, "10.0.0.1", "203.0.113.9, 198.51.100.7, 10.0.0.1", &ctx)
	defer response_destroy(&ctx.private.response)

	testing.expect_value(t, seen, "198.51.100.7")
	testing.expect(t, seen != "203.0.113.9", "the forged leftmost entry must never be returned")
}

// A single trusted proxy in front of a direct client: one entry, the peer is
// the proxy, the sole entry is the real client.
@(test)
wp48i_single_trusted_hop_returns_the_client :: proc(t: ^testing.T) {
	app := app()
	defer destroy(&app)
	trust_proxies(&app, {"10."})
	get(&app, "/ip", report_ip)

	ctx: Context
	seen := resolve(&app, "10.0.0.1", "198.51.100.7", &ctx)
	defer response_destroy(&ctx.private.response)

	testing.expect_value(t, seen, "198.51.100.7")
}

// Two trusted proxies in front of the client. Both rightmost hops are trusted
// and discarded; the walk stops at the first untrusted address.
@(test)
wp48i_walks_past_every_trusted_hop :: proc(t: ^testing.T) {
	app := app()
	defer destroy(&app)
	trust_proxies(&app, {"10.", "192.168."})
	get(&app, "/ip", report_ip)

	ctx: Context
	seen := resolve(&app, "10.0.0.1", "198.51.100.7, 192.168.1.9, 10.0.0.2", &ctx)
	defer response_destroy(&ctx.private.response)

	testing.expect_value(t, seen, "198.51.100.7")
}

// Every hop trusted (a misconfiguration or an internal-only chain): there is no
// untrusted address to return, so the honest answer is the peer, never "".
@(test)
wp48i_all_trusted_falls_back_to_the_peer :: proc(t: ^testing.T) {
	app := app()
	defer destroy(&app)
	trust_proxies(&app, {"10."})
	get(&app, "/ip", report_ip)

	ctx: Context
	seen := resolve(&app, "10.0.0.1", "10.0.0.9, 10.0.0.2", &ctx)
	defer response_destroy(&ctx.private.response)

	testing.expect_value(t, seen, "10.0.0.1")
}

// A trusted peer with no forwarded header at all: the peer is the answer.
@(test)
wp48i_trusted_peer_without_a_header_returns_the_peer :: proc(t: ^testing.T) {
	app := app()
	defer destroy(&app)
	trust_proxies(&app, {"10."})
	get(&app, "/ip", report_ip)

	ctx: Context
	seen := resolve(&app, "10.0.0.1", "", &ctx)
	defer response_destroy(&ctx.private.response)

	testing.expect_value(t, seen, "10.0.0.1")
}

// The negative control that separates trust from configuration: an UNTRUSTED
// peer (does not match any prefix) means the header is ignored entirely, and
// the peer itself is returned however convincing the chain looks.
@(test)
wp48i_an_untrusted_peer_ignores_the_header :: proc(t: ^testing.T) {
	app := app()
	defer destroy(&app)
	trust_proxies(&app, {"10."})
	get(&app, "/ip", report_ip)

	ctx: Context
	seen := resolve(&app, "203.0.113.50", "203.0.113.9, 198.51.100.7", &ctx)
	defer response_destroy(&ctx.private.response)

	testing.expect_value(t, seen, "203.0.113.50")
	testing.expect(t, seen != "203.0.113.9", "an untrusted peer must not read the header")
}

// Stray commas and internal whitespace do not derail the walk: empty entries
// are skipped, and each returned entry is trimmed.
@(test)
wp48i_empty_entries_are_skipped :: proc(t: ^testing.T) {
	app := app()
	defer destroy(&app)
	trust_proxies(&app, {"10."})
	get(&app, "/ip", report_ip)

	ctx: Context
	seen := resolve(&app, "10.0.0.1", "198.51.100.7,  , 10.0.0.1", &ctx)
	defer response_destroy(&ctx.private.response)

	testing.expect_value(t, seen, "198.51.100.7")
}
