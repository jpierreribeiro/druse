// WP36 — CONFIGURABLE LIMITS: `Limits`, `DEFAULT_LIMITS`, `limits`.
//
// THREE SYMBOLS, and the ledger moves 47 → 50. This is the least reversible
// change in Phase 3 and the file says so at the top: a public struct is a
// promise per FIELD. Once an application writes `max_body`, removing or
// renaming that field breaks its build, and tightening a DEFAULT breaks its
// traffic without breaking its build — which is worse. Adding a field later is
// cheap. That asymmetry is the entire argument for the size of this struct.
//
// THE SHAPE IS `core:net`'s. An options struct plus a package default
// CONSTANT — `DEFAULT_TCP_OPTIONS` is the precedent — and not a builder, not a
// setter per field, not a general system specification. The vendored backend's
// own `Default_Server_Opts` is a mutable package VARIABLE, and that is the
// counter-example rather than the model: a global anyone can assign is a
// setting whose value depends on who ran last.
//
// WHY IT ATTACHES TO THE APP AND NOT TO `serve`. `test_request` never calls
// `serve`, and R-10 is the property both transports exist to keep. If the body
// cap lived on `serve`, an in-memory test would answer 200 where a socket
// answers 413 — on exactly the boundary a test suite is supposed to prove. The
// limits therefore travel with the application, and `serve` DERIVES the
// backend's options from them.
//
// AMENDED BY WP46 (2026-07-21): THE REQUEST DEADLINE NOW EXISTS.
//
// WP36 shipped this struct with three byte budgets and no time budget, and said
// why: the vendored server had no deadline to configure, and a field that
// silently did nothing would have been a lie with a version number on it. That
// was true and it was a hole — WP41's fault laboratory then DEMONSTRATED it,
// holding a connection open indefinitely with one trickling client.
//
// `max_request_time` closes it. ADR-031 fixed the requirement; ADR-033 left the
// mechanism to this package; and the mechanism turned out to be a single
// vendored patch — a periodic sweep beside the server's existing date tick —
// governed by WP51's policy, which is why that package moved ahead of this one.
//
// STILL NOT HERE, and stated so nobody infers it: a WRITE deadline, and any
// bound on a slow HANDLER. The first is a smaller version of the same patch and
// is deliberately not bundled with a security fix; the second is not a deadline
// the framework should own, because a slow handler is the application's own
// time and killing its connection turns a slow page into a broken one.
package web
// uruquim:file application

// Limits is the application's byte budget for one request.
//
// It bounds URUQUIM'S OWN per-request working memory. It does NOT bound the
// server: connections, accept backlog, the number of inbound headers and total
// process memory are the transport's and the operating system's, and no
// document may say otherwise because this type exists.
//
// EVERY FIELD IS A PROMISE. There are eight, and each is here because something
// downstream already enforces it — not because a tuning surface felt
// incomplete. A field with no enforcement behind it would be a knob that lies.
Limits :: struct {
	// The largest request body `web.body` will decode, in bytes. Exactly this
	// many is allowed; a strictly larger body is answered 413 and never reaches
	// the arena or the parser. Enforced on the SHARED request path, so the
	// in-memory transport and the socket agree by construction (R-10).
	max_body:         int,

	// The largest request line — the first line, carrying the method, target
	// and version. RFC 7230 §3.1.1 recommends supporting at least 8000 octets
	// and specifies no maximum; the backend enforces this one.
	max_request_line: int,

	// The largest header block, in bytes. Same status as the request line: a
	// practical limit the spec declines to set, enforced by the backend.
	max_headers:      int,

	// WP46 / ADR-031 — how long ONE request may take to ARRIVE, from its first
	// byte to its last, in nanoseconds. Zero means no deadline.
	//
	// A REQUEST deadline, not an idle timeout, and the difference is the whole
	// defence: an idle timer is reset by every byte, so a client trickling one
	// byte per second resets it forever. This bounds the total time a request
	// may take to arrive, which is what makes slowloris finite.
	//
	// IT DOES NOT BOUND A HANDLER. A slow handler is the application's own
	// time, and killing its connection would turn a slow page into a broken
	// one. The clock starts when a request begins arriving and stops when it
	// has arrived.
	//
	// The type is `i64` nanoseconds rather than `time.Duration` for a measured
	// reason: `package web` may not import `core:time` (FINDING-B — an
	// application would link a clock because the framework configures one), and
	// `time.Duration` is that package's type. The transport converts at the
	// boundary, where a clock is already linked.
	max_request_time: i64,

	// WP90 / ADR-039 — how long ONE response may take to SEND, from the moment
	// the completed response is handed to the transport until the transport
	// reports it sent, in nanoseconds. Zero means no deadline, which is what
	// shipped before this field existed.
	//
	// THE MIRROR OF `max_request_time`: that field bounds a client that sends
	// slowly; this one bounds a client that READS slowly. Without it, a client
	// that stops reading parks the response — and the connection, and its
	// buffers — for as long as the client chooses.
	//
	// A CONNECTION PAST THIS DEADLINE IS ABORTED, NOT CLOSED GRACEFULLY: the
	// transport discards the undelivered tail and resets the connection. A
	// graceful close would first flush kernel-buffered bytes to the slow
	// reader at the client's own pace, which can hide the close for minutes —
	// a deadline that bounds nothing observable is decoration. The client
	// sees a reset mid-body, which is the honest signal for "you were too
	// slow"; a deadline generous enough for legitimate slow links is the
	// application's judgement, which is why the default is off.
	//
	// `i64` nanoseconds rather than `time.Duration` for the measured FINDING-B
	// reason recorded on `max_request_time`.
	max_write_time:   i64,

	// C-04 / ADR-045 — the largest response body the framework will BUILD, in
	// bytes. Zero means no limit, which is what shipped before this field
	// existed and follows the `max_write_time`/`max_idle_time` convention: a
	// framework-chosen number would refuse responses applications legitimately
	// serve today.
	//
	// THE MIRROR OF `max_body` ON THE WRITE SIDE. `max_body` caps what a client
	// may SEND; this caps what a handler may BUILD. It exists because response
	// size was the one framework-owned resource with no bound at all (C-04
	// amber cell #1): responses are buffered whole (ADR-014) and a connection
	// retains ~1× the largest response it ever served (measured, F-C04-1), so
	// the worst case is `max_connections × largest response` — 1024× at the
	// defaults, bounded by nothing.
	//
	// A BREACH IS A 500, NOT A TRUNCATION. Exactly this many bytes is allowed;
	// a strictly larger committed body is replaced — before it is copied to the
	// transport — with the standardized `internal_error` 500 and reported as
	// `Framework_Error.Response_Too_Large`, so an observer sees it with a route
	// and a status. This converts an out-of-memory that kills every in-flight
	// request on the process into one typed failure, the same argument ADR-039
	// made for the write deadline. Enforced on the SHARED response path, so the
	// in-memory transport and the socket agree by construction (R-10); it counts
	// the body the framework BUILT, so a HEAD whose body is suppressed on the
	// wire is still measured by what it allocated.
	//
	// DELEGATION REMAINS THE OTHER HALF. This limit bounds ONE response; total
	// process memory across `max_connections` is still sized by a cgroup, per
	// the C-04 rule in `planning/closure-response-size-and-memory.md`. The limit
	// is the per-response guard; the cgroup is the aggregate one.
	max_response_bytes: int,

	// WP90 / ADR-039 — how long a keep-alive connection may sit IDLE between
	// requests before the server closes it, in nanoseconds. Zero means no
	// timeout, which is what shipped before this field existed.
	//
	// NOT A REQUEST DEADLINE AND NOT A DEFENCE: closing an idle connection is
	// keep-alive economy — reclaiming slots from clients that went away
	// without saying so — and the close is graceful (an idle connection has
	// nothing buffered to discard). The clock starts when a response
	// completes and stops the moment the next request's bytes arrive;
	// `max_request_time` then owns that request's arrival as before.
	//
	// Same `i64` nanoseconds convention, same FINDING-B reason.
	max_idle_time:    i64,

	// WP47 — the maximum number of concurrent connections the server will hold.
	// Zero means unbounded, which is what shipped before this field existed.
	//
	// WITHOUT IT, connections are bounded only by the operating system's
	// file-descriptor limit — and reaching that limit is not a graceful
	// degradation. It is an `accept` failing for a reason the server did not
	// choose, at a moment it did not choose. **A server that refuses a
	// connection is degraded and honest; one that accepts everything until the
	// kernel stops it has a failure mode that is an accident.**
	max_connections:  int,

	// WP47 / WP40 — connection slots held back from ADMISSION so that a
	// shutdown always has room to work in.
	//
	// **Admission is refused at or below `max_connections - reserved_conns`,
	// never at zero**, and that inequality is the whole reservation rule: the
	// fatal failure is not running out of capacity, it is running out and
	// having none left to shut down with. A server that is full and cannot
	// drain is a process an operator must kill.
	//
	// Ignored when `max_connections` is zero — there is nothing to reserve from
	// an unbounded pool.
	reserved_conns:   int,

	// WP59 — how long a graceful shutdown may take, in nanoseconds, measured
	// from the moment `web.stop` is observed. Zero means no deadline, which is
	// what shipped before this field existed.
	//
	// **Phase 4 withdrew this field rather than ship one that bounded nothing,
	// and the withdrawal was correct.** The attempt then bounded the drain loop
	// and left two waits behind it; WP58 measured the result of having neither —
	// with eight idle keep-alive connections the drain never ended, and letting
	// those connections complete crashed the process on a freed pointer. This
	// field ships now because the mechanism underneath it cancels the operation
	// instead of waiting around it.
	//
	// WHAT IT BOUNDS: the drain loop, the forced close of connections still
	// serving a request when it expires, and the final wait for outstanding
	// close operations. All three, because bounding one of them is what failed.
	//
	// WHAT IT DOES NOT BOUND, stated here because a deadline that is quietly
	// conditional is worse than none: **a handler that blocks.** Each Handler is
	// synchronous and cannot be preempted; a stuck foreign call holds its lane
	// beyond this deadline. Other lanes retain progress, while the supervisor's
	// `TimeoutStopSec` remains the outer process bound.
	//
	// `i64` nanoseconds rather than `time.Duration` for the same measured reason
	// as `max_request_time`: `package web` may not import `core:time`
	// (FINDING-B). The transport converts at the boundary.
	max_drain_time:   i64,

	// WP71 — the maximum number of Handlers that may execute concurrently.
	// Zero selects the transport-neutral automatic policy; one is the explicit
	// compatibility mode for applications with deliberately single-threaded
	// state. Values above 256 are refused before the listener opens.
	//
	// This names application capacity, never backend threads or event loops. The
	// current adapter implements one synchronous Handler lane per unit; a future
	// adapter may use another mechanism but must preserve the same bound.
	max_handlers:     int,

	// AUDIT J3/J4 — the largest number of JSON values and object keys a request
	// body may contain. Zero means no limit.
	//
	// THE MEASURED HOLE THIS CLOSES, and it is one hole with two faces. Both
	// numbers below are from bodies INSIDE the 4 MiB `max_body`, on this
	// project's own toolchain and host:
	//
	//	`[{},{},…]`, 1,398,101 empty objects, decoded into a 288-byte DTO:
	//	  RSS peak +588 MB for one request — 147x the body. Sampled at 1 ms
	//	  during the request, because the arena resets at request end and a
	//	  before/after delta reports 52 MB, understating the peak 11-fold.
	//
	//	one object of 322,000 distinct keys: 1.70 s, 1.99 s, 2.08 s across
	//	  three runs. Handlers are synchronous on their lane, so that is a
	//	  lane held for two seconds by one client, with `max_handlers`
	//	  defaulting to the core count.
	//
	// `max_body` is doing its job in both cases — the body really is 4 MiB. It
	// is simply the wrong dimension: what the cost scales with is the number of
	// STRUCTURES, and no byte cap can express that. Neither shape is malformed,
	// so nothing else on the request path has grounds to refuse it.
	//
	// WHY NODE COUNT AND NOT DEPTH OR KEY COUNT. Nesting depth is already
	// bounded (`JSON_NEST_DEPTH_MAX`, against stack exhaustion) and is a
	// different failure. A key-count cap was the backlog's proposal, and the
	// measurement is what ruled it out: the J3 shape has 1.4M values and ZERO
	// keys, so a key cap would not see it at all. Counting values and keys
	// together is the one quantity both measured costs are linear in — memory at
	// ~150 bytes per value for the preflight tree, CPU at ~6 us per key.
	//
	// COUNTED EXACTLY, in the allocation-free pre-scan that already walks the
	// body for depth, so this costs no additional pass and refuses BEFORE the
	// parser allocates anything. The count is derived from structural
	// punctuation outside strings:
	//
	//	values = commas + non-empty containers + 1
	//	keys   = colons
	//
	// which is exact rather than an estimate: every value except the root is a
	// child of exactly one container, and a container with n children carries
	// n-1 commas. Empty containers are detected and excluded, which matters
	// because the J3 shape is 1.4M of them and treating them as non-empty would
	// double-count the very body this bounds.
	//
	// A BREACH IS A 413. The status is about size and the body is oversized —
	// along a dimension the client can act on, which is why the envelope reports
	// the effective node limit as a number rather than saying "too complex".
	//
	// THE DEFAULT IS ON, unlike the deadline fields, and that asymmetry is
	// deliberate. Those default off because a framework-chosen duration would
	// break real slow clients. This one has no such tension: 100,000 nodes is
	// two to three orders of magnitude above ordinary API traffic while cutting
	// the measured worst cases to ~15 MB and ~0.3 s. An application doing bulk
	// imports raises it on purpose, having decided what its lanes can afford.
	max_json_nodes:   int,
}

// DEFAULT_LIMITS is what every application gets without asking.
//
// The values are the SHIPPED ones, not new opinions: 4 MiB is the body cap
// Phase 1 fixed and the capacity ledger has recorded since, and 8000 is the
// vendored backend's own default for both text limits. This constant therefore
// changes nothing for an application that never mentions it — which is the
// property that makes shipping it safe.
//
// It is a CONSTANT. Assigning to it is a compile error, so a library cannot
// change another library's defaults, and two applications in one process cannot
// disagree about what "default" means.
DEFAULT_LIMITS :: Limits {
	max_body         = BODY_LIMIT,
	max_request_line = REQUEST_LINE_LIMIT,
	max_headers      = HEADER_BLOCK_LIMIT,
	max_request_time = REQUEST_TIME_LIMIT,
	// ADR-039: both timeout fields default OFF. Turning either on is an
	// application decision about its slowest legitimate client, not a number
	// the framework can guess — and a default that resets real slow readers
	// would be a behaviour change for every shipped application.
	max_write_time   = 0,
	// C-04: default OFF, like the two deadline fields above and for the same
	// reason — a framework-chosen ceiling would refuse responses applications
	// serve today. Set it to convert an OOM into a typed 500.
	max_response_bytes = 0,
	max_idle_time    = 0,
	max_connections  = CONNECTION_LIMIT,
	reserved_conns   = RESERVED_CONNECTION_LIMIT,
	max_drain_time   = DRAIN_TIME_LIMIT,
	max_handlers     = 0,
	// J3/J4: default ON, and the reasoning for the asymmetry with the fields
	// above is on the field itself. The measured worst cases are 588 MB and
	// 2.08 s for a single in-limit request; this bounds both without coming
	// near ordinary traffic.
	max_json_nodes   = JSON_NODE_LIMIT,
}

// The public setting is bounded even when explicit. The automatic policy is
// resolved by the adapter to [4, 32], based on available processor cores.
@(private)
MAX_HANDLER_CONCURRENCY :: 256

// DRAIN_TIME_LIMIT is ten seconds, in nanoseconds.
//
// THE NUMBER IS JUDGEMENT AND IS RECORDED AS SUCH (the C-5 honesty rule). No
// specification sets a shutdown deadline. Ten seconds is chosen against the one
// number that actually constrains it: systemd's `TimeoutStopSec` defaults to
// 90 seconds, and Kubernetes' termination grace period to 30. A drain deadline
// is only useful if it expires BEFORE the supervisor's kill — otherwise the
// kill is the real deadline and this field is decoration — so it is set well
// inside the tighter of the two.
//
// IT IS A DEFAULT, NOT A RECOMMENDATION. An operator whose handlers legitimately
// run longer should raise it, and one running behind a proxy with a short
// timeout should lower it. What matters is that the default bounds shutdown
// rather than leaving it open, because the previous default was "forever" and
// nobody chose that either.
@(private)
DRAIN_TIME_LIMIT :: i64(10 * 1_000_000_000)

// REQUEST_LINE_LIMIT and HEADER_BLOCK_LIMIT are the vendored backend's own
// defaults, restated here so `DEFAULT_LIMITS` does not silently inherit a
// number from a package the public surface must never name (G-06).
@(private)
REQUEST_LINE_LIMIT :: 8000

@(private)
HEADER_BLOCK_LIMIT :: 8000

// REQUEST_TIME_LIMIT is thirty seconds, in nanoseconds.
//
// THE NUMBER IS JUDGEMENT AND IS RECORDED AS SUCH (the C-5 honesty rule): no
// specification sets it, and the sources that discuss slowloris name the
// technique and no figure. Thirty seconds is chosen to be far longer than any
// legitimate client needs to send a request over a working network — a large
// upload is bounded by `max_body`, not by this — and far shorter than the
// "forever" that shipped before WP46.
//
// It is the first default in this framework that CHANGES BEHAVIOUR for an
// application that never mentions limits: a connection that would previously
// have been held open indefinitely is now closed. That is the point, it is a
// security fix rather than a tuning knob, and the capacity ledger records it.
@(private)
REQUEST_TIME_LIMIT :: i64(30 * 1_000_000_000)

// CONNECTION_LIMIT and RESERVED_CONNECTION_LIMIT are the admission budget.
//
// JUDGEMENT, RECORDED AS SUCH. 1024 sits comfortably below a typical default
// file-descriptor limit — and the process needs descriptors for more than
// sockets — so the framework's own refusal arrives BEFORE the kernel's. That
// ordering is the entire point of having a limit rather than inheriting one.
//
// 16 reserved is small on purpose: enough for a drain to close what is open and
// write final responses, large enough not to be a rounding error. It is a slot
// count, not a rate.
@(private)
CONNECTION_LIMIT :: 1024

@(private)
RESERVED_CONNECTION_LIMIT :: 16

// JSON_NODE_LIMIT is the default ceiling on JSON values plus object keys in a
// request body (audit J3/J4).
//
// 100,000 is chosen from the two measurements, not from taste. The preflight
// tree costs ~150 bytes per value (211 MB measured for 1,398,101 values) and a
// key costs ~6 us (1.70-2.08 s measured for 322,000). At this ceiling the worst
// case a single request can reach is therefore roughly:
//
//	memory  100,000 x 150 B  ~= 15 MB, against 588 MB measured unbounded
//	CPU     100,000 x 6 us   ~= 0.3 s, against 2.08 s measured unbounded
//
// The upper bound on ordinary traffic is what makes it safe to default ON: a
// REST payload is tens of values, a page of results a few thousand. Something
// has to be deliberately bulk-importing to see this number, and that
// application raises it having decided what its lanes can afford.
@(private)
JSON_NODE_LIMIT :: 100_000



// LIMITS_MIN_BODY, LIMITS_MIN_TEXT are the floors validation enforces.
//
// They are ONE, not a taste. A zero or negative budget is not a strict
// configuration, it is an application that answers 413 to every request with a
// body — and an operator who typed `Limits{max_body = 1024}` deserves that
// value, while one who left a field at its zero value has almost certainly
// forgotten it. The struct has no "unset" state to distinguish those, so the
// zero value is refused rather than guessed at.
@(private)
LIMITS_MIN_BODY :: 1

@(private)
LIMITS_MIN_TEXT :: 1

// limits sets the application's byte budget.
//
// Call it BEFORE the first request; after that the application is rejected
// fail-closed. Registration order relative to routes and middleware does not
// matter — a limit protects every route equally, so there is no ordering
// hazard of the kind ADR-019 exists for.
//
// THE CONCURRENCY DECISION, recorded here because this is where the snapshot is
// taken. Limits are read on the request path, so a change during serving would
// be a data race and, worse, a request-dependent one: two clients could get two
// different answers to the same body. Rather than make that impossible by
// construction — which would mean a second immutable App type — this REJECTS
// it, through the mechanism ADR-019 and ADR-023 already use. The snapshot model
// therefore SITS BESIDE those guards and does not replace them: `use()` after
// the first dispatch is still refused for its own reason, and this refusal adds
// a second offence rather than subsuming the first. Nothing shipped becomes
// weaker.
//
// A forbidden zero/negative field is rejected the same way. It allocates
// nothing and stores the value by copy.
limits :: proc(a: ^App, l: Limits) {
	if app_is_serving(a) {
		app_reject_late_configuration(a)
		return
	}
	if a.private.poisoned {
		// Already rejected and already reported; the first diagnosis stands.
		return
	}
	if app_has_dispatched(a) {
		limits_poison(a, FRAMEWORK_MESSAGE_LIMITS_AFTER_DISPATCH)
		return
	}
	// `max_request_time` is validated as NON-NEGATIVE rather than positive,
	// because zero has a meaning here that the byte budgets do not have: no
	// deadline. An operator who wants the old behaviour must be able to ask for
	// it explicitly — and asking explicitly is exactly the difference between a
	// deliberate choice and a forgotten field.
	// Negative is refused everywhere; zero means "unbounded" for the admission
	// fields, as it does for the deadline.
	if l.max_connections < 0 || l.reserved_conns < 0 ||
	   l.max_handlers < 0 || l.max_handlers > MAX_HANDLER_CONCURRENCY {
		limits_poison(a, FRAMEWORK_MESSAGE_LIMITS_INVALID)
		return
	}
	// A reservation that swallows its own budget would refuse EVERY connection
	// while looking like a configuration. Caught at BOOT, where an operator is
	// watching, rather than at 3 a.m. as a server that accepts nothing.
	if l.max_connections > 0 && l.reserved_conns >= l.max_connections {
		limits_poison(a, FRAMEWORK_MESSAGE_LIMITS_RESERVATION)
		return
	}
	if l.max_request_time < 0 {
		limits_poison(a, FRAMEWORK_MESSAGE_LIMITS_INVALID)
		return
	}
	// Same rule as `max_request_time`: zero is a meaningful choice (no
	// deadline), negative is a mistake.
	if l.max_drain_time < 0 {
		limits_poison(a, FRAMEWORK_MESSAGE_LIMITS_INVALID)
		return
	}
	// WP90 / ADR-039 — the write and idle deadlines follow the identical
	// zero-means-off, negative-is-a-mistake convention.
	if l.max_write_time < 0 || l.max_idle_time < 0 {
		limits_poison(a, FRAMEWORK_MESSAGE_LIMITS_INVALID)
		return
	}
	// C-04 — the response-size budget follows the same convention: zero means
	// no limit (a meaningful choice), negative is a mistake.
	if l.max_response_bytes < 0 {
		limits_poison(a, FRAMEWORK_MESSAGE_LIMITS_INVALID)
		return
	}
	// J3/J4 — same convention again: zero means no limit, negative is a mistake.
	// There is no minimum above zero, deliberately. A very small positive value
	// refuses almost every body, which is a strange configuration but a
	// COHERENT one — the same latitude `max_response_bytes` gets. What is
	// refused is the incoherent value.
	if l.max_json_nodes < 0 {
		limits_poison(a, FRAMEWORK_MESSAGE_LIMITS_INVALID)
		return
	}
	if l.max_body < LIMITS_MIN_BODY ||
	   l.max_request_line < LIMITS_MIN_TEXT ||
	   l.max_headers < LIMITS_MIN_TEXT {
		limits_poison(a, FRAMEWORK_MESSAGE_LIMITS_INVALID)
		return
	}

	a.private.limits = l
}

// limits_poison rejects the application with a static diagnostic, reusing the
// WP17/WP18 mechanism rather than inventing a second one.
@(private)
limits_poison :: proc(a: ^App, message: string, loc := #caller_location) {
	a.private.poisoned = true

	logger := context.logger
	if logger.procedure == nil {
		return
	}
	logger.procedure(logger.data, .Error, message, logger.options, loc)
}
