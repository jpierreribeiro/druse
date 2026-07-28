// WP19 — REQUEST HEADER LOOKUP: `header` and `bearer_token`.
//
// Both are PURE lookups: they commit no response, log nothing, and allocate
// nothing. That is a deliberate asymmetry with the extractors (`path_int`,
// `query_int`), which commit a 400 on bad input — an absent header is
// routinely NOT an error (an anonymous request, an optional key), so deciding
// what a miss means belongs to the caller. Both return `(value, ok)` and omit
// `#optional_ok` (ADR-002): dropping `ok` is a compile error.
//
// SECURITY. Header values are ATTACKER-CONTROLLED bytes. Nothing here logs,
// and this file must never import `core:log` or `core:fmt` (WP6 measured that
// class of import at ~37 KiB per application). `bearer_token` never trims and
// never normalises the token — normalising comparisons invite secret-handling
// bugs upstream — and its parse is strict precisely so a sloppy client is
// REJECTED rather than quietly repaired.
//
// A-8, resolved. Since WP8 the transport has materialised inbound headers
// into `[]Header_Pair` per request, read by nothing (audit A-8). This work
// package is where that cost becomes purposeful: these two procedures are the
// readers.
package web
// uruquim:file application

// header returns the EFFECTIVE request header named `name`.
//
// "Effective" is a documented, deliberate word (ADR-027): the framework keeps
// a private per-request overlay that `header` consults BEFORE the arrived
// headers. Phase 2's request-ID middleware (WP23) writes the validated or
// regenerated `X-Request-Id` there, so downstream readers observe the value
// the framework decided — never a client value the framework rejected. With
// nothing in the overlay, `header` reads exactly what arrived.
//
// Names are case-insensitive with ASCII folding, per RFC 9110 — `X-Api-Key`,
// `x-api-key` and `X-API-KEY` are one header; non-ASCII bytes compare
// byte-exact.
//
// WHEN THE SAME NAME ARRIVED MORE THAN ONCE, THE VALUES ARE JOINED, in arrival
// order, separated by `", "` — RFC 9110 §5.3's permitted combination, performed
// once at parse time by the transport (`header_parse`). `X-Dup: alpha` followed
// by `X-Dup: beta` reads back as `"alpha, beta"`, and there is exactly one
// entry per name to look up.
//
// This comment previously said the FIRST occurrence wins, "matching the query
// rule (WP5 D4) ... and joining would allocate". Both halves were false: the
// join happens in the transport before `header` is ever called, and it
// allocates (`strings.concatenate`). `web.query` DOES take first-occurrence —
// that rule is real, it just was never this one. Pinned by
// `tests/wp19-header-lookup`.
//
// An empty value is PRESENT: `("", true)`. `ok` reports presence, not
// validity.
//
// LIFETIME: the returned value is a VIEW over transport-owned storage, valid
// only for this request — copy explicitly to persist, and never hand it to
// background work (G-05).
header :: proc(ctx: ^Context, name: string) -> (value: string, ok: bool) {
	if ctx.private.overlay_set && ascii_fold_equal(ctx.private.overlay.name, name) {
		return ctx.private.overlay.value, true
	}
	for pair in ctx.request.headers.private.pairs {
		if ascii_fold_equal(pair.name, name) {
			return pair.value, true
		}
	}
	return "", false
}

// bearer_token returns the bearer token from the `Authorization` header,
// parsed against RFC 6750 STRICTLY:
//
//   - the scheme is `Bearer`, compared case-insensitively (`bearer`, `BEARER`
//     and `Bearer` are all the scheme — RFC 9110 §11.1);
//   - EXACTLY ONE space separates scheme and token;
//   - the token is non-empty;
//   - no whitespace is tolerated anywhere in the token — a trailing space, a
//     doubled separator, or an embedded blank is a rejection, never repaired.
//
// The token is returned VERBATIM: never trimmed, never case-folded, never
// decoded. A `(value, ok)` of `("", false)` means "no usable bearer token";
// the caller decides what that means (typically a 401 from an auth
// middleware — see docs/canonical-patterns.md).
//
// When `Authorization` arrived more than once, the values are joined per the
// `header` rule above, so what this parses is `"<first>, <second>"` — which
// fails the strict grammar below (the token would contain a comma and a
// space). A duplicated `Authorization` is therefore refused, not silently
// resolved to one of the two.
bearer_token :: proc(ctx: ^Context) -> (value: string, ok: bool) {
	raw, found := header(ctx, "Authorization")
	if !found {
		return "", false
	}

	// "Bearer" (6) + the separator + a non-empty token needs at least 8 bytes.
	if len(raw) < 8 {
		return "", false
	}
	if !ascii_fold_equal(raw[:6], "Bearer") {
		return "", false
	}
	if raw[6] != ' ' {
		return "", false
	}

	token := raw[7:]
	for i in 0 ..< len(token) {
		// Rejects SP and HTAB (the "exactly one space, no trailing whitespace"
		// grammar) and every other control byte with them: a token containing
		// CR, LF or NUL is never handed onward.
		if token[i] <= ' ' {
			return "", false
		}
	}
	return token, true
}

// ascii_fold_equal compares two strings with ASCII-only case folding, byte by
// byte, allocation-free. Non-ASCII bytes must match exactly: HTTP field names
// are ASCII, and folding anything wider would be a normalisation decision this
// package does not own.
@(private)
ascii_fold_equal :: proc(a: string, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		ca := a[i]
		cb := b[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 'a' - 'A'
		}
		if cb >= 'A' && cb <= 'Z' {
			cb += 'a' - 'A'
		}
		if ca != cb {
			return false
		}
	}
	return true
}
