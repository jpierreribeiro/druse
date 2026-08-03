// WP9 — THE RAW-WIRE CORPUS.
//
// Backend-agnostic DATA: exact bytes to send, and what a safe HTTP/1 adapter is
// allowed to do with them. It imports no backend, so a future adapter (or the
// eventual `core:net/http`) can be held to the same corpus without touching it.
//
// It runs ONLY against real adapters. The in-memory transport has no TCP parser
// and cannot prove framing safety, so pointing this corpus at it would produce
// meaningless green.
//
// THE SAFETY SHAPE. For every ambiguous or malformed case the assertion is not
// "some particular status" but the three properties that actually prevent
// request smuggling and connection desynchronization:
//
//	handler_runs      — did application code see a partial/ambiguous request?
//	connection_closes — is the connection retired rather than reused?
//	smuggled_runs     — did trailing bytes become a SECOND request?
//
// A case is safe when a malformed request runs no handler, closes the
// connection, and never lets following bytes execute. The exact status is
// allowed to vary (400, 417, or a bare close), because a protocol error before
// a framework-owned request exists may legitimately be answered by the adapter
// or by closing (WP9 D6).
package transport_conformance

// Wire_Outcome is what the corpus permits for one case.
Wire_Outcome :: enum {
	// A complete, valid exchange: the handler runs and answers.
	Ok,
	// The request is rejected. A status response is allowed but not required;
	// an immediate close is equally acceptable (WP9 D6).
	Rejected,
	// The request is rejected AND the status is mandatory. Security F-005:
	// a bare close is exactly the defect, so `Rejected` cannot express this
	// case — it permits the very outcome under test.
	Rejected_With_Status,
}

// Wire_Case is one raw-wire scenario.
//
// `bytes` is sent verbatim. `allowed_status` lists the status codes a compliant
// adapter may answer with; an empty list means "any status, or none at all"
// (a bare close). `expect_second_request` is the smuggling probe: when a case
// appends bytes that LOOK like a follow-up request, this says whether that
// follow-up is permitted to execute.
Wire_Case :: struct {
	name:                  string,
	bytes:                 string,
	outcome:               Wire_Outcome,
	allowed_status:        []int,
	handler_must_run:      bool,
	connection_must_close: bool,
	// True only for the legitimate keep-alive case: a second request on the
	// same connection is expected to be served.
	expect_second_request: bool,
	// True when the case appends bytes that a vulnerable adapter might execute
	// as a smuggled request. It must NEVER run.
	has_smuggled_request:  bool,
	notes:                 string,
}

// The fixture routes the wire suite serves are `GET /ping` (200 "pong") and
// `POST /echo` (binds a JSON body, 201). `/smuggled` is registered so that a
// smuggled request WOULD be observable if the adapter executed it — which is
// exactly what must not happen.

// Package-level for the same reason as the semantic table: a slice of a local
// array literal would dangle once the accessor returned.
@(private)
corpus_storage := []Wire_Case{
		// --- 1-4: legitimate traffic ---------------------------------------
		{
			name = "valid GET",
			bytes = "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
			outcome = .Ok,
			allowed_status = {200},
			handler_must_run = true,
			connection_must_close = true,
		},
		{
			name = "keep-alive serves two PIPELINED requests",
			bytes = "GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n" +
			"GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
			outcome = .Ok,
			allowed_status = {200},
			handler_must_run = true,
			connection_must_close = true,
			expect_second_request = true,
			// RENAMED BY WP52, and the rename is the finding. This case sends
			// both requests in ONE write, so the second one's bytes are already
			// buffered when the first is served. **It passed for the whole life
			// of the project while sequential keep-alive was broken** (WP45: a
			// GET with no Content-Length reported its body read as FAILED, and
			// the connection was retired after every response).
			//
			// A case that says "keep-alive works" and only exercises the
			// pipelined path is a case whose name is broader than its evidence.
			//
			// **A SEQUENTIAL CASE WAS TRIED HERE AND WITHDRAWN.** This harness
			// is single-exchange by construction — it writes once and reads
			// until the stream goes quiet — and a case added on top of that did
			// NOT go red when WP45's fix was reverted. A corpus case that
			// passes either way is worse than no case, because it reads as
			// coverage. Sequential keep-alive is tested in `tests/wp41-fault`
			// instead, which owns a connection across time; this corpus owns
			// BYTES. The instruments differ and the split is now explicit
			// (WP52).
			notes = "pipelined; the second request is already buffered",
		},
		{
			// WP52 — RESPONSE framing, the axis this corpus did not cover.
			//
			// Every case before this one is about a request the server must
			// refuse. None asked whether the server's own RESPONSE is framed
			// correctly — and a 204 that carries a body, or a Content-Length
			// that disagrees with the bytes sent, desynchronizes a persistent
			// connection exactly as a malformed request does. The direction is
			// reversed; the failure is the same.
			name = "204 carries no body and no Content-Length",
			bytes = "DELETE /nobody HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
			outcome = .Ok,
			allowed_status = {204},
			handler_must_run = true,
			connection_must_close = true,
			notes = "RFC 9110 6.4.1: a 204 has no body; a framing header here would desynchronize a reused connection",
		},
		{
			name = "Connection: close closes after the response",
			bytes = "GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
			outcome = .Ok,
			allowed_status = {200},
			handler_must_run = true,
			connection_must_close = true,
		},
		{
			name = "valid Content-Length body",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n" +
			"Content-Length: 16\r\nConnection: close\r\n\r\n" + `{"name":"grace"}`,
			outcome = .Ok,
			allowed_status = {201},
			handler_must_run = true,
			connection_must_close = true,
		},

		// --- 5-10: ambiguous or invalid Content-Length ----------------------
		{
			name = "CL+TE is rejected (smuggling vector)",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 6\r\n" +
			"Transfer-Encoding: chunked\r\n\r\n" + "0\r\n\r\n" +
			"GET /smuggled HTTP/1.1\r\nHost: localhost\r\n\r\n",
			outcome = .Rejected,
			allowed_status = {400},
			connection_must_close = true,
			has_smuggled_request = true,
			notes = "RFC 9112 6.1: CL+TE must be treated as an unrecoverable error.",
		},
		{
			name = "duplicate identical Content-Length is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n" +
			"Content-Length: 2\r\nConnection: close\r\n\r\n" + "{}",
			outcome = .Rejected,
			allowed_status = {400},
			connection_must_close = true,
			notes = "WP9 D2 is deliberately stricter than RFC-minimum: refuse, do not normalize.",
		},
		{
			name = "duplicate differing Content-Length is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n" +
			"Content-Length: 40\r\nConnection: close\r\n\r\n" + "{}",
			outcome = .Rejected,
			allowed_status = {400},
			connection_must_close = true,
		},
		{
			name = "comma-list Content-Length is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2, 2\r\n" +
			"Connection: close\r\n\r\n" + "{}",
			outcome = .Rejected,
			allowed_status = {400},
			connection_must_close = true,
		},
		{
			name = "negative Content-Length is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n" +
			"Connection: close\r\n\r\n",
			outcome = .Rejected,
			allowed_status = {400},
			connection_must_close = true,
		},
		{
			name = "signed and overflowing Content-Length is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\n" +
			"Content-Length: +99999999999999999999\r\nConnection: close\r\n\r\n",
			outcome = .Rejected,
			allowed_status = {400},
			connection_must_close = true,
		},

		// --- 11-17: chunked -------------------------------------------------
		{
			name = "valid chunked body",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n" +
			"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n" +
			"10\r\n" + `{"name":"grace"}` + "\r\n0\r\n\r\n",
			outcome = .Ok,
			allowed_status = {201},
			handler_must_run = true,
			connection_must_close = true,
		},
		{
			name = "non-hex chunk size is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"zz\r\n{}\r\n0\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
		},
		{
			name = "negative chunk size is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"-1\r\n{}\r\n0\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
			notes = "Patch 14 (F3): `strconv.parse_int` accepts `-1`; an unguarded " +
			"negative size tripped `scanner.odin`'s `n >= 0` assertion and killed " +
			"the process. It must be refused like any malformed size.",
		},
		{
			name = "chunked body with a trailer field is accepted",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n" +
			"Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n" +
			"10\r\n" + `{"name":"grace"}` + "\r\n0\r\nX-Trace: 1\r\n\r\n",
			outcome = .Ok,
			allowed_status = {201},
			handler_must_run = true,
			connection_must_close = true,
			notes = "Patch 15 (F2): a trailer field is legal HTTP/1.1 but is parsed " +
			"after the header map is frozen; the unpatched decoder tripped " +
			"`assert(!h.readonly)` and killed the process on the first trailer line.",
		},
		{
			name = "truncated chunk is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"20\r\n{}\r\n",
			outcome = .Rejected,
			connection_must_close = true,
			notes = "declares 0x20 bytes then ends: the handler must not see a partial body.",
		},
		{
			name = "chunk without CRLF is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"2\r\n{}0\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
		},
		{
			name = "missing zero terminator is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"2\r\n{}\r\n",
			outcome = .Rejected,
			connection_must_close = true,
		},
		{
			name = "unsupported Transfer-Encoding is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: gzip\r\n" +
			"Connection: close\r\n\r\n" + "{}",
			outcome = .Rejected,
			allowed_status = {400},
			connection_must_close = true,
		},
		{
			name = "chunked that is not the final coding is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\n" +
			"Transfer-Encoding: chunked, gzip\r\nConnection: close\r\n\r\n" + "0\r\n\r\n",
			outcome = .Rejected,
			allowed_status = {400},
			connection_must_close = true,
		},

		// --- H3: the transfer-coding TOKEN, not a suffix --------------------
		//
		// All three framing sites used to ask `has_suffix(enc, "chunked")`,
		// which is true of far more than the chunked coding. Both rejected
		// cases below returned 201 against this backend before PATCH 37 —
		// verified by reverting the predicate and re-running this corpus.
		//
		// The body is DELIBERATELY a valid `/echo` payload, Content-Type and
		// all. A malformed body would make these cases pass for the wrong
		// reason: the request would be refused at content negotiation or at
		// JSON decode whether or not the framing check works, and the control
		// would not fail. The first draft of these cases did exactly that.
		{
			name = "an unregistered coding ending in 'chunked' is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n" +
			"Transfer-Encoding: xchunked\r\nConnection: close\r\n\r\n" +
			"10\r\n" + `{"name":"grace"}` + "\r\n0\r\n\r\n",
			outcome = .Rejected,
			allowed_status = {400},
			connection_must_close = true,
			notes = "RFC 9112 6.1: a transfer-coding the server does not understand must not be read as chunked. " +
			"`xchunked` is not `chunked`, and a hop that agrees disagrees about where the body ends.",
		},
		{
			name = "chunked applied twice is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n" +
			"Transfer-Encoding: chunked, chunked\r\nConnection: close\r\n\r\n" +
			"10\r\n" + `{"name":"grace"}` + "\r\n0\r\n\r\n",
			outcome = .Rejected,
			allowed_status = {400},
			connection_must_close = true,
			notes = "RFC 9112 6.1: chunked must not be applied more than once. Two Transfer-Encoding " +
			"headers comma-merge into exactly this value, so this is also the duplicate-header case.",
		},
		{
			name = "the chunked coding is matched case-insensitively",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n" +
			"Transfer-Encoding: CHUNKED\r\nConnection: close\r\n\r\n" +
			"10\r\n" + `{"name":"grace"}` + "\r\n0\r\n\r\n",
			outcome = .Ok,
			allowed_status = {201},
			handler_must_run = true,
			connection_must_close = true,
			notes = "Transfer-coding names are case-insensitive (RFC 9112 6.1). The old suffix test refused " +
			"this, which was wrong in the other direction; the token compare accepts it.",
		},

		// --- 18-21: truncation and malformed syntax -------------------------
		{
			name = "truncated fixed body is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 40\r\n\r\n" + "{}",
			outcome = .Rejected,
			connection_must_close = true,
			notes = "connection ends before the declared length: no handler, no second request.",
		},
		{
			name = "whitespace before the header colon is rejected",
			// THE SPACED HEADER IS NOT `Host`, AND THAT IS THE WHOLE CASE.
			//
			// This sent "Host : localhost". With the space-before-colon rule
			// removed, the name parses as "Host " — which no longer matches
			// "host", so the request is refused for having NO HOST HEADER, a
			// different rule entirely. The case passed with the guard and
			// without it: measured, removing the rule left this at 400 while
			// `X-Spaced : 1` went from 400 to 200 with the handler running.
			// A test whose name is broader than its evidence (finding S2, the
			// same shape as wp63's multipart case).
			bytes = "GET /ping HTTP/1.1\r\nHost: localhost\r\n" +
			"X-Spaced : 1\r\nConnection: close\r\n\r\n",
			outcome = .Rejected,
			allowed_status = {400},
			connection_must_close = true,
		},
		{
			name = "obs-fold header continuation is rejected",
			bytes = "GET /ping HTTP/1.1\r\nHost: localhost\r\nX-Fold: a\r\n b\r\n" +
			"Connection: close\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
		},
		{
			name = "tab obs-fold header continuation is rejected",
			bytes = "GET /ping HTTP/1.1\r\nHost: localhost\r\nX-Fold: a\r\n\tb\r\n" +
			"Connection: close\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
			notes = "Patch 18 (F14): obs-fold is CRLF then a space OR a tab; the " +
			"tab form must be refused like the space form, or a proxy that " +
			"unfolds it and this server diverge on the header set.",
		},
		{
			name = "overflowing Content-Length is rejected, its bytes never a second request",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n" +
			"Content-Length: 18446744073709551616\r\nConnection: close\r\n\r\n" +
			`{}` + "GET /smuggled HTTP/1.1\r\nHost: localhost\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
			has_smuggled_request = true,
			notes = "Patch 16 (F10): 2^64 wraps to 0 under strconv.parse_int, so an " +
			"unguarded server would read no body and parse the trailing bytes as " +
			"a second request. The oversized length must be refused.",
		},
		{
			name = "invalid request line is rejected",
			bytes = "GET/ping HTTP/1.1\r\nHost: localhost\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
		},

		// --- 22-23: unread body and smuggling -------------------------------
		{
			name = "unread body does not desynchronize a following request",
			bytes = "POST /ping HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n" + "{}" +
			"GET /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
			outcome = .Ok,
			handler_must_run = true,
			connection_must_close = true,
			expect_second_request = true,
			notes = "the handler never calls web.body; the adapter still consumed it, so the " +
			"next request parses cleanly rather than starting mid-body.",
		},
		{
			name = "over-limit body is 413 and its bytes are never a second request",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4194305\r\n\r\n",
			outcome = .Rejected,
			allowed_status = {413},
			connection_must_close = true,
			has_smuggled_request = true,
			notes = "declares over 4 MiB; rejected during the read, handler never runs.",
		},

		// --- 24-25: Expect and unknown methods ------------------------------
		{
			name = "Expect: 100-continue is honored — body read, handler runs (C6)",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n" +
			"Content-Length: 16\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n" +
			`{"name":"grace"}`,
			outcome = .Ok,
			allowed_status = {201},
			handler_must_run = true,
			connection_must_close = true,
			notes = "C6 (F8-7): RFC 9110 §10.1.1 lets a server omit the interim 100 and " +
			"read the body. 100-continue is IGNORED, the body is read, the handler runs. " +
			"No interim response is emitted.",
		},
		{
			name = "an unknown Expect is still refused with 417",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n" +
			"Expect: 200-ok\r\n\r\n",
			outcome = .Rejected,
			allowed_status = {417},
			connection_must_close = true,
			notes = "C6: only 100-continue is honored; any other expectation the server " +
			"cannot meet is a 417 (RFC 9110 §10.1.1), refused and closed before a body is read.",
		},
		{
			name = "valid unknown method reaches the core, not a backend 501",
			bytes = "PROPFIND /ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
			outcome = .Ok,
			allowed_status = {405},
			handler_must_run = false,
			connection_must_close = true,
			notes = "WP9 D7: the core's 404/405 policy decides, so 405 with Allow — never 501.",
		},

		// --- HTTP audit F1/F2: framing strictness the corpus did not cover ---
		//
		// These four are smuggling DIFFERENTIALS rather than malformed-input
		// crashes: each is a byte sequence a strict front-end reads one way and
		// a lenient backend reads another. The corpus already covered CL and TE
		// disagreement; line termination and chunk-size spelling were the gaps.
		{
			name = "bare LF line termination is rejected",
			bytes = "GET /ping HTTP/1.1\nHost: localhost\nConnection: close\n\n",
			outcome = .Rejected,
			connection_must_close = true,
			notes = "HTTP audit F2: `bufio.scan_lines` terminated on a bare LF, so a " +
			"proxy that frames strictly on CRLF and this backend could disagree about " +
			"where a header — and therefore a request — ends.",
		},
		{
			name = "a lone CR inside a header value is rejected",
			bytes = "GET /ping HTTP/1.1\r\nHost: localhost\r\nX-Test: a\rb\r\nConnection: close\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
			notes = "HTTP audit F2: a CR not followed by LF cannot be laundered into a " +
			"field value; it is refused rather than normalised away.",
		},
		{
			name = "chunk size with a leading plus is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"+2\r\n{}\r\n0\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
			notes = "HTTP audit F1: RFC 9112 §7.1 chunk-size is 1*HEXDIG. Odin's " +
			"`strconv.parse_int` accepts a leading `+`, so this parsed as size 2 here " +
			"while a strict proxy rejects the line — a Transfer-Encoding desync.",
		},
		{
			name = "chunk size with a digit separator is rejected",
			bytes = "POST /echo HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"1_0\r\n0123456789abcdef\r\n0\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
			notes = "HTTP audit F1: `_` is an Odin numeric separator, not a hex digit. " +
			"`1_0` parsed as 16 here and is malformed to a strict front-end.",
		},

		// --- audit H1: control bytes in a field line ------------------------
		//
		// The lone-CR case above is the neighbour of these three, and the gap it
		// left is the point: CR was refused because CR is the splitting byte,
		// while every other byte RFC 9110 §5.5 excludes from a field value was
		// stored verbatim and answered 200. All three of these were MEASURED at
		// 200 before vendor patch 38.
		//
		// `/ping` on purpose, not `/echo`: `/echo` answers 400 for a body that
		// is not JSON whether or not the field line was refused, so a case
		// drafted against it would pass with the fix reverted. That mistake was
		// made once in this corpus already (audit H3).
		{
			name = "a NUL inside a header value is rejected",
			bytes = "GET /ping HTTP/1.1\r\nHost: localhost\r\nX-Test: a\x00b\r\nConnection: close\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
			notes = "audit H1: RFC 9110 §5.5 makes rejecting or replacing a NUL in a " +
			"field value a MUST — \"invalid and dangerous, due to the varying ways that " +
			"implementations might parse and interpret those characters\".",
		},
		{
			name = "a C0 control inside a header value is rejected",
			bytes = "GET /ping HTTP/1.1\r\nHost: localhost\r\nX-Test: a\x01b\r\nConnection: close\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
			notes = "audit H1: field-value is `*( SP / HTAB / VCHAR / obs-text )`, so 0x01 " +
			"is not field content at all. This one was not merely stored — an application " +
			"echoing the value put the 0x01 back on the wire byte-for-byte.",
		},
		{
			name = "a control byte inside a header NAME is rejected",
			bytes = "GET /ping HTTP/1.1\r\nHost: localhost\r\nX-\x01Test: v\r\nConnection: close\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
			notes = "audit H1: a field name is a `token` (RFC 9110 §5.6.2), which excludes " +
			"controls. `sanitize_key` escapes only LF, so such a name was lowercased and " +
			"stored as-is.",
		},
		// --- audit H2: absolute-form authority vs the Host field ------------
		//
		// RFC 9112 §3.2.2 makes the target's authority authoritative and the Host
		// field ignorable. Measured before vendor patch 39: a target naming
		// `evil.example` with `Host: good.example` was served 200, and the
		// application was handed "good.example" — the half the RFC discards.
		{
			name = "absolute-form whose authority AGREES with Host is served",
			bytes = "GET http://localhost/ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
			outcome = .Ok,
			allowed_status = {200},
			handler_must_run = true,
			connection_must_close = true,
			notes = "audit H2: the accepting half. Without it the rejection case below " +
			"would pass just as well against a server that refused absolute-form outright, " +
			"which is not what was fixed.",
		},
		{
			name = "absolute-form whose authority DISAGREES with Host is rejected",
			bytes = "GET http://evil.example/ping HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
			outcome = .Rejected,
			connection_must_close = true,
			notes = "audit H2: one request carrying two identities. A front proxy routing " +
			"or caching on the target's authority and an application tenanting on Host are " +
			"then serving different requests — refused rather than repaired, the same " +
			"disposition as CL+TE.",
		},
		{
			name = "OPTIONS * is still answered, not read as an authority",
			bytes = "OPTIONS * HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
			outcome = .Ok,
			allowed_status = {200},
			connection_must_close = true,
			notes = "audit H2's TRAP, and the reason this case exists: `url_parse` finds no " +
			"`/` in `*` and files the whole target as the host, so an authority check keyed " +
			"only on \"host is non-empty\" answers 400 to the legal server-capabilities " +
			"ping. No handler runs — the backend answers it directly.",
		},
		{
			name = "a horizontal tab inside a header value is still accepted",
			bytes = "GET /ping HTTP/1.1\r\nHost: localhost\r\nX-Test: a\tb\r\nConnection: close\r\n\r\n",
			outcome = .Ok,
			allowed_status = {200},
			handler_must_run = true,
			connection_must_close = true,
			notes = "audit H1's boundary, and the reason it is here: HTAB is legal OWS " +
			"inside a field value. A control-byte rule that swept it up would refuse " +
			"conforming traffic, and nothing else in this corpus would have noticed.",
		},
		// --- security F-005: an oversized header block ANSWERS ---------------
		//
		// Two requests that both exceed `limit_headers` used to get two
		// different protocol outcomes, decided by how the bytes happened to be
		// split across lines. A block made of complete lines tripped the budget
		// check and answered 431; a SINGLE line larger than the budget reached
		// the scanner's `.Too_Long` first and the connection was closed with no
		// response and no log. Measured at limit_headers=8000: 8,032 bytes ->
		// 431, 8,532 bytes -> silence.
		//
		// The outcome here is `Rejected_With_Status` and not `Rejected` for a
		// precise reason: `Rejected` permits a bare close (WP9 D6), which is the
		// defect itself. A corpus case that allowed it would have been green
		// against the vulnerable server.
		{
			name = "a single header line larger than the budget answers 431",
			bytes = "GET /ping HTTP/1.1\r\nHost: localhost\r\nX-Big: " +
			OVERSIZED_HEADER_VALUE + "\r\nConnection: close\r\n\r\n",
			outcome = .Rejected_With_Status,
			allowed_status = {431},
			connection_must_close = true,
			notes = "security F-005. The value alone is over the 8,000-byte header budget, " +
			"so the scanner reaches .Too_Long before any complete line exists and the " +
			"budget check below it never runs. A silent close here is indistinguishable " +
			"from a network fault to the client and produces no log line for an operator.",
		},
		{
			name = "a header block of many lines over the budget also answers 431",
			bytes = "GET /ping HTTP/1.1\r\nHost: localhost\r\n" + MANY_HEADER_LINES +
			"Connection: close\r\n\r\n",
			outcome = .Rejected_With_Status,
			allowed_status = {431},
			connection_must_close = true,
			notes = "the PAIR of the case above, and the reason both are here: this shape " +
			"already answered 431 before F-005 was fixed. Keeping only the single-line case " +
			"would leave nothing to catch a fix that repaired one path by breaking the other.",
		},
}

// A single header value larger than the 8,000-byte header budget. Built rather
// than typed so the size is stated once and cannot drift from the comment.
@(private)
OVERSIZED_HEADER_VALUE :: #load("oversized-header-value.txt", string)

// The same excess, split across many complete lines: each one parses, and the
// running budget is what refuses them.
@(private)
MANY_HEADER_LINES :: #load("many-header-lines.txt", string)

wire_corpus :: proc() -> []Wire_Case {
	return corpus_storage
}
