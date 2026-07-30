// WP48 public-surface contract — trusted proxies and the effective client
// address.
//
// TWO SYMBOLS, ledger 51 → 53: `client_ip` and `trust_proxies`. ADR-013's
// fail-closed arm, implemented.
//
// **THE WHOLE SUITE IS ABOUT ONE ASYMMETRY.** `X-Forwarded-For` is a request
// header, so any client can send one. The things applications do with a client
// address — rate-limit buckets, audit logs, allow-lists, abuse counters — are
// exactly the things an attacker must not be allowed to choose. So the header is
// believed only when the CONNECTED PEER is one the operator named, and the tests
// below spend most of their length on the case where it must be IGNORED.
//
// These run over `test_request`, which has no socket and therefore no peer. That
// is not a limitation here — it is the sharpest possible test of the default:
// **with no peer, nothing is trusted, and a forged header must be ignored.**
// The socket side is covered by `tests/wp41-fault`.
package test_wp48_public

import "core:log"
import "core:strings"
import "core:testing"
import web "druse:web"

@(private = "file")
Quiet :: struct {
	inner: log.Logger,
}

@(private = "file")
quiet_logger_proc :: proc(
	data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	record := (^Quiet)(data)
	if level == .Error && strings.contains(text, "druse:") {
		return
	}
	if record.inner.procedure != nil {
		record.inner.procedure(record.inner.data, level, text, options, location)
	}
}

@(private = "file")
quiet_logger :: proc(record: ^Quiet) -> log.Logger {
	record.inner = context.logger
	return log.Logger {
		procedure = quiet_logger_proc,
		data = rawptr(record),
		lowest_level = .Debug,
		options = context.logger.options,
	}
}

@(private = "file")
seen: string

@(private = "file")
report_ip :: proc(ctx: ^web.Context) {
	seen = web.client_ip(ctx)
	web.text(ctx, .OK, seen)
}

// The signatures are pinned by ASSIGNMENT: a changed parameter or result is a
// build failure in the contract suite rather than a surprise downstream.
@(test)
wp48_the_signatures_are_pinned :: proc(t: ^testing.T) {
	read: proc(ctx: ^web.Context) -> string = web.client_ip
	trust: proc(a: ^web.App, prefixes: []string) = web.trust_proxies
	testing.expect(t, read != nil && trust != nil, "both symbols must have their ratified shapes")
}

// **THE TEST THIS PACKAGE EXISTS FOR.** An application that has trusted nothing
// must ignore `X-Forwarded-For` completely, however convincing it looks.
//
// If this ever goes green with the header's value, every rate limiter and audit
// log built on `client_ip` has been handed to whoever sends the request.
@(test)
wp48_an_untrusted_request_ignores_a_forwarded_header :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ip", report_ip)

	seen = "unset"
	res := web.test_request(
		&app,
		.GET,
		"/ip",
		headers = []string{"X-Forwarded-For: 203.0.113.9"},
	)

	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(
		t,
		seen != "203.0.113.9",
		"a forwarded header must be ignored when no proxy is trusted; believing it hands every attacker a free choice of identity",
	)
}

// The same, with a chain — because a multi-hop value is what a real forgery
// looks like, and a naive implementation that split on commas before checking
// trust would pass the test above and fail this one.
@(test)
wp48_an_untrusted_request_ignores_a_forwarded_chain :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ip", report_ip)

	seen = "unset"
	web.test_request(
		&app,
		.GET,
		"/ip",
		headers = []string{"X-Forwarded-For: 203.0.113.9, 10.0.0.1, 10.0.0.2"},
	)

	testing.expect(t, seen != "203.0.113.9", "the leftmost entry of a chain is still an untrusted claim")
	testing.expect(t, !strings.contains(seen, ","), "client_ip must never return a chain")
}

// Trusting nothing explicitly is legal, and means the same as the default.
// Without this, "trust nothing" would be a state an application could not ask
// for, only inherit.
@(test)
wp48_trusting_an_empty_set_is_legal_and_trusts_nothing :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.trust_proxies(&app, {})
	web.get(&app, "/ip", report_ip)

	seen = "unset"
	res := web.test_request(
		&app,
		.GET,
		"/ip",
		headers = []string{"X-Forwarded-For: 203.0.113.9"},
	)
	testing.expect_value(t, res.status, web.Status.OK)
	testing.expect(t, seen != "203.0.113.9", "an empty trust set trusts nothing")
}

// Registering a trusted set does not, by itself, make a request trusted. The
// PEER must match — and over `test_request` there is no peer, so the header
// stays ignored. This is the case that separates "configured" from "trusted".
@(test)
wp48_configuring_trust_does_not_trust_this_request :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.trust_proxies(&app, {"10.", "192.168."})
	web.get(&app, "/ip", report_ip)

	seen = "unset"
	web.test_request(
		&app,
		.GET,
		"/ip",
		headers = []string{"X-Forwarded-For: 203.0.113.9"},
	)

	testing.expect(
		t,
		seen != "203.0.113.9",
		"trust is decided by the PEER, not by having a configuration; a request from an unmatched peer is untrusted however the App is configured",
	)
}

// ---------------------------------------------------------------------------
// Fail-closed registration
// ---------------------------------------------------------------------------

// AN EMPTY PREFIX MATCHES EVERY PEER. It would trust the whole internet through
// one typo, so it is refused rather than stored.
@(test)
wp48_an_empty_prefix_rejects_the_application :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.trust_proxies(&app, {"10.", ""})
	web.get(&app, "/ip", report_ip)

	res := web.test_request(&app, .GET, "/ip")
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
}

// More prefixes than the framework stores is refused rather than truncated. A
// dropped entry fails in the SAFE direction — that proxy's header is ignored —
// but it leaves the operator's configuration quietly untrue, and a security
// boundary that is quietly untrue is worse than one that refuses to start.
@(test)
wp48_too_many_prefixes_reject_the_application :: proc(t: ^testing.T) {
	quiet: Quiet
	context.logger = quiet_logger(&quiet)

	app := web.app()
	defer web.destroy(&app)
	web.trust_proxies(&app, {"1.", "2.", "3.", "4.", "5.", "6.", "7.", "8.", "9."})
	web.get(&app, "/ip", report_ip)

	res := web.test_request(&app, .GET, "/ip")
	testing.expect_value(t, res.status, web.Status.Internal_Server_Error)
}

// The positive control for the two above: eight prefixes is the bound, not one
// less, and a legal registration must leave the application serving.
@(test)
wp48_the_bound_itself_is_usable :: proc(t: ^testing.T) {
	app := web.app()
	defer web.destroy(&app)
	web.trust_proxies(&app, {"1.", "2.", "3.", "4.", "5.", "6.", "7.", "8."})
	web.get(&app, "/ip", report_ip)

	res := web.test_request(&app, .GET, "/ip")
	testing.expect_value(t, res.status, web.Status.OK)
}
