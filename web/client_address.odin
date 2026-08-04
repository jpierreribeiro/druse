// WP48 — TRUSTED PROXIES: `client_ip` and `trust_proxies`.
//
// TWO SYMBOLS, and the pair is the point. ADR-013 accepted the fail-closed arm:
// **the effective address is the connected peer, and forwarding headers are
// ignored until trusted proxies are explicitly configured.** One symbol without
// the other would be either a value you cannot use behind a proxy, or a value
// you cannot trust.
//
// WHY THIS IS A SECURITY DECISION AND NOT AN ERGONOMIC ONE. `X-Forwarded-For`
// is a request header. Any client can send one. A framework that reads it by
// default hands every attacker a free choice of identity — and the things
// applications do with a client address are exactly the things you must not let
// an attacker choose: rate-limit buckets, audit logs, allow-lists, geo rules,
// abuse counters. **Trusting the header by default is not a convenience with a
// caveat; it is an authorization bypass with a default.**
//
// SO THE DEFAULT IS THE PEER, ALWAYS. An application deployed directly sees the
// truth. An application behind a proxy sees the proxy until it says which
// proxies it has, at which point it sees what those proxies report — and only
// then.
package web
// druse:file application

import "core:strings"

// TRUSTED_PROXY_MAX is how many trusted proxy prefixes an application may
// register.
//
// A fixed inline array rather than a dynamic one, for the reason the rest of
// this framework uses fixed arrays: it is request-path state read on every
// request, and a bound that is enforced at registration cannot be exhausted at
// 3 a.m. Eight is well past any real deployment — a topology with more than
// eight distinct proxy networks is one where the boundary is drawn wrong.
//
// WHAT HAPPENS WHEN IT IS FULL, because the capacity ledger does not accept a
// bound without one: registration REJECTS the application fail-closed. It does
// not silently drop the ninth, because a dropped trust entry is a proxy whose
// forwarded address is ignored — which fails in the safe direction but leaves
// the operator's configuration quietly untrue.
@(private)
TRUSTED_PROXY_MAX :: 8

// Trusted_Proxies is the registered set, stored on the App.
@(private)
Trusted_Proxies :: struct {
	// Entries matched textually, not by CIDR arithmetic. An entry ending in
	// `.` or `:` is a prefix; anything else matches the whole address. See
	// `trust_proxies` and `trusted_prefix_match`.
	prefix: [TRUSTED_PROXY_MAX]string,
	count:  int,
}

// trust_proxies declares which peers are allowed to speak for their clients.
//
// Each entry is matched textually against the connected peer's rendered
// address, and the trailing character decides how:
//
//	"10."        a PREFIX -> every address under 10.
//	"192.168."   a PREFIX -> every address under 192.168.
//	"fd00:"      a PREFIX -> every address under fd00:
//	"127.0.0.1"  EXACT    -> that address and nothing else
//	"::1"        EXACT    -> that address and nothing else
//
// **An entry ending in `.` or `:` is a prefix; anything else must match the
// whole address.** The separator is how the author says "everything under
// this", and it cannot land mid-octet.
//
// **This rule replaced an unanchored prefix match (TRUST-001).** Before it,
// `"127.0.0.1"` also trusted `127.0.0.10` through `127.0.0.199`, and there was
// no way to name one address and only it.
//
// **WHY TEXTUAL RATHER THAN CIDR, stated plainly because CIDR is what a
// reviewer expects.** A correct CIDR implementation needs IPv4 and IPv6 parsing,
// mask arithmetic, and the IPv4-mapped-IPv6 edge — and each of those is a place
// to be subtly wrong in a security boundary. This rule needs a comparison and a
// last-byte test.
//
// **What it costs, stated rather than hidden:** boundaries that are not
// byte-aligned cannot be expressed. `10.0.0.0/24` is `"10.0.0."`; `10.0.0.0/25`
// has no spelling. That was equally true of the unanchored version — this
// change removes a widening bug without removing expressiveness — and a
// deployment that genuinely needs a non-aligned mask is evidence for a later
// work package. Adding CIDR then is a strengthening; shipping arithmetic now
// and finding it wrong would be a breach.
//
// **Ordering does not matter and duplicates are harmless**: this is a set
// membership test, not a chain walk.
//
// Registering MORE than `TRUSTED_PROXY_MAX` rejects the application
// fail-closed. Passing an empty slice is legal and means "trust nothing", which
// is also the default.
trust_proxies :: proc(a: ^App, prefixes: []string) {
	if app_is_serving(a) {
		app_reject_late_configuration(a)
		return
	}
	if a.private.poisoned {
		return
	}
	if len(prefixes) > TRUSTED_PROXY_MAX {
		trust_poison(a)
		return
	}

	// The strings are the CALLER's. They are read on the request path, so they
	// must outlive the App — string literals, which is what every real call site
	// passes. Cloning them would put an allocation and a teardown on a path that
	// has neither today, for a case that does not arise.
	a.private.trusted.count = 0
	for prefix in prefixes {
		if len(prefix) == 0 {
			// An empty prefix matches EVERY peer, which would trust the whole
			// internet through a typo. Refused rather than stored.
			trust_poison(a)
			return
		}
		a.private.trusted.prefix[a.private.trusted.count] = prefix
		a.private.trusted.count += 1
	}
}

@(private)
trust_poison :: proc(a: ^App, loc := #caller_location) {
	a.private.poisoned = true

	logger := context.logger
	if logger.procedure == nil {
		return
	}
	logger.procedure(logger.data, .Error, FRAMEWORK_MESSAGE_TRUST_INVALID, logger.options, loc)
}

// client_ip returns the address this request should be attributed to.
//
// **The connected peer**, unless that peer matches a prefix registered with
// `trust_proxies` — in which case `X-Forwarded-For` is walked FROM THE RIGHT,
// trusted hops are discarded, and the first untrusted address is returned. If
// every entry is trusted (or the header is absent or empty) the peer is
// returned, and `""` is never manufactured.
//
// RIGHT-TO-LEFT, and this is the correction ADR-037 records. `X-Forwarded-For`
// grows left to right: each proxy APPENDS the address it saw. The rightmost
// entries are therefore the ones written by infrastructure closest to the
// server, and the leftmost entry is exactly the value a client forges before
// any proxy touches it. Reading leftmost hands an attacker a free choice of
// identity the moment a single proxy is trusted. So resolution walks from the
// right — the same direction the header was written — skipping every hop whose
// address matches a `trust_proxies` prefix (a trusted proxy speaking for the
// hop before it), and stops at the first address that is NOT a trusted proxy.
// That address is the nearest one the trusted chain did not vouch away, which
// is the honest client for a correctly-configured topology.
//
// The trust decision is made on administered network identity (the peer, and
// each hop's rendered address), never on the one field the client owns.
//
// **Returns a VIEW.** Over the peer string or over the request header, both
// request-scoped: copy it to keep it (G-05).
//
// It allocates nothing.
client_ip :: proc(ctx: ^Context) -> string {
	peer := ctx.private.peer

	if !trusted_peer(ctx, peer) {
		return peer
	}

	forwarded, ok := header(ctx, "X-Forwarded-For")
	if !ok || len(forwarded) == 0 {
		// A trusted proxy that forwarded nothing. The peer is the honest
		// answer, and inventing one would be worse than saying what we have.
		return peer
	}

	// Walk the chain from the RIGHT. Each iteration peels the last
	// comma-separated entry, trims it, and asks whether it is a trusted proxy.
	// A trusted entry is a hop the chain vouches for, so we skip it and keep
	// walking left. The first UNTRUSTED entry is the answer: it is the nearest
	// address no trusted proxy claimed to be speaking for. If we exhaust the
	// chain — every entry trusted — the peer is the honest fallback.
	rest := forwarded
	for len(rest) > 0 {
		comma := strings.last_index_byte(rest, ',')
		entry: string
		if comma < 0 {
			entry = rest
			rest = ""
		} else {
			entry = rest[comma + 1:]
			rest = rest[:comma]
		}
		entry = strings.trim_space(entry)
		if len(entry) == 0 {
			// An empty entry (a stray comma, a `", ,"`) carries no address to
			// trust or return. Skip it and keep walking rather than returning
			// the empty string as if it were an identity.
			continue
		}
		if !trusted_prefix_match(ctx, entry) {
			return entry
		}
	}

	// Every hop was a trusted proxy. The peer is the truthful answer.
	return peer
}

// trusted_peer is the membership test for the CONNECTED PEER. Textual, bounded,
// and allocation-free.
@(private)
trusted_peer :: proc(ctx: ^Context, peer: string) -> bool {
	if len(peer) == 0 {
		return false
	}
	return trusted_prefix_match(ctx, peer)
}

// trusted_prefix_match asks whether an address — the peer, or a hop rendered
// into an `X-Forwarded-For` entry — matches any registered trusted-proxy entry.
// It is the shared membership test behind both the peer check and the
// right-to-left chain walk (ADR-037): the SAME rule decides trust everywhere,
// so a proxy trusted as the peer is also trusted as a hop. Textual, bounded,
// and allocation-free.
//
// **THE ANCHORING RULE, and the defect it closes (TRUST-001).** The first
// edition matched an unanchored textual prefix, so `"127.0.0.1"` also trusted
// `127.0.0.10` through `127.0.0.199` — about a hundred and ten addresses nobody
// named. There was no way to write "this address and only this address", which
// is the most natural thing a reader wants from this API.
//
// It also falsified the argument the doc on `trust_proxies` used to justify
// textual matching over CIDR: *"a wrong prefix can only fail to trust one you
// did"*. A prefix that silently widens is exactly the failure that argument
// claimed could not happen.
//
// The rule now: an entry is a PREFIX only if it ends in an address separator —
// `.` for IPv4, `:` for IPv6. Anything else must match the WHOLE address.
//
//	"10."        prefix  -> 10.x.x.x
//	"192.168."   prefix  -> 192.168.x.x
//	"fd00:"      prefix  -> fd00:...
//	"127.0.0.1"  exact   -> 127.0.0.1 and nothing else
//	"::1"        exact   -> ::1 and nothing else
//
// Every example the public doc already carried keeps the meaning a reader would
// assume; only the unanchored widening is gone.
@(private)
trusted_prefix_match :: proc(ctx: ^Context, address: string) -> bool {
	if ctx.private.trusted.count == 0 || len(address) == 0 {
		return false
	}
	for i in 0 ..< ctx.private.trusted.count {
		entry := ctx.private.trusted.prefix[i]
		if len(entry) == 0 {
			continue
		}
		last := entry[len(entry) - 1]
		if last == '.' || last == ':' {
			// An explicit prefix: the trailing separator is the author saying
			// "everything under this", and it cannot land mid-octet.
			if strings.has_prefix(address, entry) {
				return true
			}
		} else if address == entry {
			return true
		}
	}
	return false
}
