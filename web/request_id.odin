// WP23 — THE `request_id` MIDDLEWARE and its trust policy (ADR-027, option A).
//
// THIS FILE IS A SECURITY BOUNDARY. The inbound `X-Request-Id` is
// attacker-controlled, and the whole design is about what the framework refuses
// to do with it. ADR-027 settled every question below; none of it is invented
// here.
//
// THE POLICY, in one paragraph. A client-supplied ID is honoured ONLY if it
// matches the charset `[A-Za-z0-9._-]` and the length bound 1..64. Anything
// else — too long, empty, a space, a semicolon, a control byte, non-ASCII, and
// above all CR or LF — causes the value to be DISCARDED and a fresh ID
// generated. Discarded means discarded: the rejected bytes are never echoed to
// the client, never written to the overlay, never logged, and never reachable
// by a handler. There is no sanitising and no repair, because a "repaired"
// attacker value is still an attacker value, and half of it appearing in an
// operator's logs is the outcome this rule exists to prevent.
//
// WHY THE CHARSET IS THE SECURITY MECHANISM. The concrete attack is CR/LF
// header injection: an ID carrying `\r\n` would forge additional response
// headers on the way out. Excluding those bytes from the accepted set makes the
// attack impossible BY CONSTRUCTION rather than by a sanitising pass that must
// be remembered at every write site. The tests still send `\r\n` explicitly,
// because a construction argument is a claim until something asserts it.
//
// HOW A HANDLER READS IT. Through `web.header(ctx, "X-Request-Id")` and nothing
// else. The middleware writes the effective ID into the private overlay that
// WP19's `header` already consults — "the effective request header" — so there
// is exactly ONE public name for reading a request header (G-01). ADR-027
// weighed the honest alternative (a second symbol, `request_id_value`) and
// closed it; the cost of the overlay is that `header` can answer with a byte
// sequence that never arrived on the wire, which is why WP19 documents the word
// "effective" rather than leaving it to be discovered.
//
// THE ID IS NOT UNGUESSABLE, and that is documented rather than hedged. It is a
// correlation handle, not a secret and not a capability: never use it for
// authentication, authorization, or anything an attacker benefits from
// predicting. Generation is a per-process seed combined with a monotonic
// counter — enough to be unique, deliberately not enough to be unpredictable.
// `core:crypto` is not imported, both because a request ID must not be mistaken
// for a secret and because WP6 measured what an import costs every application.
package web
// druse:file application

import "core:sync"

// REQUEST_ID_HEADER is the exact header name, on the request and the response.
// Not `X-Request-ID`, not `x-request-id`: one spelling, so a log pipeline
// grepping for it never half-matches. Inbound lookup is case-insensitive
// anyway — `header` folds ASCII per RFC 9110.
@(private)
REQUEST_ID_HEADER :: "X-Request-Id"

// REQUEST_ID_MAX is the ratified upper length bound (ADR-027) and therefore
// also the exact size of the request-local storage: an accepted client value
// can be 64 bytes, and nothing the framework generates is longer.
@(private)
REQUEST_ID_MAX :: 64

// request_id assigns every request an ID, honours a well-formed client value,
// and puts the result on the response.
//
// It is OPT-IN — `web.use(&app, web.request_id)` — subject to the ordinary
// ADR-019 rule that every `use` precedes the first route. Register it FIRST if
// you also use `web.logger`, so that every later middleware runs with the ID
// already assigned.
//
// WHAT IT DOES, in order:
//
//  1. reads the inbound `X-Request-Id`;
//  2. accepts it only if it matches `[A-Za-z0-9._-]` and length 1..64;
//  3. otherwise generates one, discarding the client's value entirely;
//  4. copies the effective ID into request-local storage and publishes it in
//     the overlay, BEFORE `next`, so every downstream middleware and the
//     handler read the same value through `web.header`;
//  5. lets the response carry it — the header is attached where response
//     headers are built, so a 404, a 405 and the standardized 500 all have it.
//
// The ID is a correlation handle and NOT a secret: it is not unguessable, and
// it must never be used for authentication.
//
// It allocates nothing: one fixed 64-byte buffer that already lives on the
// Context.
request_id :: proc(ctx: ^Context) {
	inbound, found := header(ctx, REQUEST_ID_HEADER)

	n := 0
	if found && request_id_acceptable(inbound) {
		n = copy(ctx.private.request_id_buffer[:], inbound)
	} else {
		// Every rejection lands here, and the client's bytes go no further.
		// There is deliberately no diagnostic: logging a rejected value would
		// put attacker-controlled text in the operator's log, which is one of
		// the two things this policy exists to prevent.
		n = request_id_generate(ctx.private.request_id_buffer[:])
	}

	ctx.private.request_id_value = string(ctx.private.request_id_buffer[:n])
	ctx.private.request_id_set = true

	// Publish BEFORE `next`: the handler and every later middleware must read
	// the effective ID, not the arrived one. The overlay is consulted by
	// `header` ahead of the transport's headers, so this REPLACES a client
	// value the framework rejected rather than shadowing it ambiguously.
	ctx.private.overlay = Header_Pair {
		name  = REQUEST_ID_HEADER,
		value = ctx.private.request_id_value,
	}
	ctx.private.overlay_set = true

	next(ctx)
}

// request_id_acceptable is the trust boundary, expressed as a total function.
//
// `[A-Za-z0-9._-]`, length 1..64 — ADR-027's exact rule. Everything outside is
// rejected, with no special case and no repair. CR, LF, NUL, SP, DEL and every
// other control byte fall out of the charset automatically rather than being
// enumerated, which is what makes this safe against the bytes nobody thought to
// list.
@(private)
request_id_acceptable :: proc(value: string) -> bool {
	if len(value) == 0 || len(value) > REQUEST_ID_MAX {
		return false
	}
	for i in 0 ..< len(value) {
		c := value[i]
		switch {
		case c >= 'A' && c <= 'Z':
		case c >= 'a' && c <= 'z':
		case c >= '0' && c <= '9':
		case c == '.' || c == '_' || c == '-':
		case:
			return false
		}
	}
	return true
}

// REQUEST_ID_HEX is the alphabet the generator emits. Lower-case only, so one
// ID has exactly one spelling.
@(private)
REQUEST_ID_HEX :: "0123456789abcdef"

// request_id_seed is the per-process half of a generated ID, and
// request_id_counter is the per-request half.
//
// THE SEED COMES FROM ADDRESS-SPACE LAYOUT, and it imports nothing to get it.
// Two independent ASLR sources are mixed: the address of the counter (a
// package global, so its address moves with the image base) and the address of
// a stack local (which moves with the stack base). Both differ per process on
// any platform with ASLR enabled.
//
// WHY NOT SOMETHING BETTER. A cycle counter would need `base:intrinsics` and a
// clock would need `core:time`; either would grow `web`'s direct-dependency
// set, which `build/phase1-direct-dependencies.txt` pins at five imports on
// purpose. Neither is worth it for a value that is explicitly NOT a secret. The
// project's own rule applies: do not add a dependency for a property nobody
// asked for.
//
// THIS IS NOT A CSPRNG AND IS NOT DOCUMENTED AS ONE. With ASLR disabled, two
// processes on identical hardware can produce the same seed. That is acceptable
// only because the ID is a correlation handle and never a secret; if it ever
// needed to be unpredictable, this code would have to be REPLACED, not
// supplemented with more mixing.
@(private)
request_id_seed: u64

// WP70: both seed publication and counter allocation are atomic. The value is
// still only a correlation handle, but concurrent handlers must never receive
// the same handle.
@(private)
request_id_counter: u64

// request_id_generate writes a fresh ID into `dst` and returns its length.
//
// The form is `<16 hex of seed>-<16 hex of counter>`: 33 bytes, inside the
// 64-byte bound, and made only of the ratified charset — the framework holds
// itself to the rule it imposes on clients, and a test asserts exactly that by
// feeding every generated ID back through `request_id_acceptable`.
//
// UNIQUENESS comes from the COUNTER, not from the seed: the counter is
// incremented atomically and never repeats within a process, so two requests
// cannot collide even if the seed were degenerate. The seed only keeps IDs from
// two different processes from overlapping.
//
// Allocation-free and bounded.
@(private)
request_id_generate :: proc(dst: []u8) -> int {
	seed := sync.atomic_load(&request_id_seed)
	if seed == 0 {
		// Two ASLR sources: a global's address (image base) and a stack local's
		// (stack base). Racy only in the sense that two threads could both seed
		// it — either seed is equally valid, and the counter is what carries
		// uniqueness.
		anchor: u8
		seed := u64(uintptr(&request_id_counter))
		seed ~= u64(uintptr(&anchor)) << 17
		if seed == 0 {
			// Keep the sentinel meaningful: 0 means "not yet seeded".
			seed = 1
		}
		_, won := sync.atomic_compare_exchange_strong(&request_id_seed, 0, seed)
		if !won {
			seed = sync.atomic_load(&request_id_seed)
		}
	}

	counter := sync.atomic_add(&request_id_counter, 1) + 1

	n := request_id_write_hex(dst, seed)
	dst[n] = '-'
	n += 1
	n += request_id_write_hex(dst[n:], counter)
	return n
}

// request_id_write_hex writes `value` as exactly 16 lower-case hex digits,
// most significant first. Fixed width on purpose: a variable-width encoding
// would make two IDs of different lengths sort in an order that does not match
// their generation order.
@(private)
request_id_write_hex :: proc(dst: []u8, value: u64) -> int {
	hex := REQUEST_ID_HEX
	v := value
	for i in 0 ..< 16 {
		dst[15 - i] = hex[v & 0xF]
		v >>= 4
	}
	return 16
}
