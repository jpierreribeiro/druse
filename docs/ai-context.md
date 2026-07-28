# Uruquim API Reference for Coding Agents

Paste this file into your agent's context (Cursor rules, CLAUDE.md, etc.).

**Use only the APIs documented in the Phase-1 sections below. Do not invent
procedures, aliases, or alternative forms. If something is not listed here, it
does not exist.** Anything under *Appendix — future phases* is NOT available and
must never be emitted.

## What works today

Uruquim is a working HTTP framework: `web.serve` binds a port and answers real
requests, routing and extractors work, JSON goes in and out, and every error is
a standardized JSON envelope.

- **Server:** `web.serve(&app, port)` binds dual-stack (IPv6 `::` when the host
  has IPv6, which serves IPv4 clients too; IPv4 Any otherwise) and blocks while
  serving.
- **Routing:** static and `:param` segments; a static route always wins over a
  parametric one, regardless of registration order.
- **Extractors:** path and query values; a fallible one answers `400` itself.
- **Bodies:** JSON decoded into a value you own, capped at **4 MiB** by
  default and configurable with `web.limits`.
- **Responses:** JSON, text, `204`, and five error responders.
- **Automatic errors:** `404` for an unknown path, `405` with an exact `Allow`
  header for a known path under another method — both with a JSON envelope.
- **Middleware:** `web.use` before any route, `web.next` inside; onion order,
  short-circuit, misses observed. Ordering is enforced fail-closed.
- **Route organisation:** `web.router()` builds a detached `Router` with the
  same verbs and `use`; `web.mount(&app, "/prefix", &r)` attaches it. A
  one-route Router is the route-level guard.
- **Request headers:** `web.header` (case-insensitive, first occurrence wins)
  and `web.bearer_token` (strict RFC 6750). Pure lookups — no automatic
  response, nothing logged, values are request-lifetime views.
- **Observability:** `web.observe` registers one observer that receives a
  typed `web.Framework_Event` for every framework-detected failure — kind,
  method, route pattern, status, payload type. Never a message, never a path.
- **Testing:** `web.test_request` runs a request through real routing without a
  socket.
- **HTTP/1 safety:** ambiguous or malformed framing (`CL`+`TE`, duplicate
  `Content-Length`, bad chunking, truncated bodies) is rejected and the
  connection closed.

**Not available yet** — do not emit any of it: graceful shutdown with a
deadline (Phase 4). Request-scoped state is **ONE typed value**, `web.request_state`
(corrective WP C7, the narrow ADR-028 reopening) — a middleware computes a value
and the handler reads it back; `ctx` is still **not** an untyped extension bag and
there is no dynamically-keyed `context.WithValue`-style storage. Panic recovery
does not exist and never will: Odin has no recoverable panic (ADR-020). See the
appendix.

**Fault behaviour — state it accurately, both halves (ADR-020).**

- A handler that returns **without committing a response** is finalized by the
  response driver to the standardized `internal_error` 500 — logged on the
  server, and carrying no detail about the request. This holds identically
  under `web.serve` and `web.test_request`, identically under `web.app()` and
  `web.bare()`, and identically for the second fault and the hundredth.
- A handler that **faults** — panic, failed assertion, out-of-bounds index, nil
  dereference, divide-by-zero — **aborts the process**. The client gets an
  empty reply. Run under a supervisor.
- Never emit `web.recovery`, a `recovery` middleware, or advice to "wrap the
  handler to catch the panic". None of it exists, and none of it can.

**Two ledgers.** The application API is exactly **80** symbols (32 frozen in
Phase 1, plus `use`/`next`, `Router`/`router`/`mount`,
`header`/`bearer_token`, `observe`/`Framework_Event`/`Framework_Error`,
`logger` and `request_id` from Phase 2, and `route`, `app_with_state`,
`state`, `Limits`, `DEFAULT_LIMITS`, `limits`, `stop`, `client_ip` and
`trust_proxies`, `secure_headers`, `refused_connections` from Phases 3-4, `is_draining`,
`cors`/`Cors_Options`, `static`/`Static_Options`, `form_field`/`form_file`/`Uploaded_File`
from Phases 5-6, `stream`/`Stream`/`stream_send`/`Stream_Send`/`stream_close` from
Phase 7, `enable_upload`/`upload`/`upload_persist`/`Upload`/`Upload_Config` from
Phase 7.5, `stats`/`Server_Stats` from the Closure, `set_header`/`bytes` from
corrective WP C2, `query_int_opt` from C3, `stream_live` from C4, and `request_state` from C7).
The test-support API is a separate ledger of exactly **2**. Union: **82**. Do not
fold them together and do not invent a third form.

## Application

```text
App        the application value
app()      create with the Phase-1 defaults (404 + 405)
bare()     create with NO automatic 404/405
destroy()  release; call exactly once, on the value app()/bare() returned
```

<!-- fragment: phase1/app-lifecycle -->
```odin
main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	web.get(&app, "/ping", ping)

	web.serve(&app, 8080)
}
```

`App` is non-copyable by contract: keep the value `app()` returned, pass
`&app` everywhere, and destroy that same value once.

`serve(a: ^App, port: int)` validates the port (1..65535), binds dual-stack
(IPv6 `::` when available — accepting IPv4 clients as well on a standard Linux —
else IPv4 Any) and blocks. An IPv4 client's `web.client_ip` is the dotted-quad,
not the `::ffff:` mapped form, so `trust_proxies` prefixes match identically on
either bind. An invalid port or a bind failure is logged and returns without
serving.

`web.stop(&app)` asks the running server to stop. It **returns immediately** —
it is a request, not a join — so it is safe to call from a signal handler. The
`web.serve` call returns when the drain finishes. Calling it twice, or with no
server running, is a no-op.

**It has a deadline: `Limits.max_drain_time`, ten seconds by default.** When it
expires, connections still serving a request are closed rather than waited for.
Set it to zero for the old unbounded behaviour. Keep the supervisor's kill as
the outer bound — it should be longer than `max_drain_time`.

**A blocking Handler holds one Handler unit and cannot be preempted.** Other
lanes continue while capacity remains, but teardown cannot free state the
blocked Handler still uses. The supervisor's stop timeout remains the outer
bound for permanently stuck application or foreign code.

`web.is_draining(&app) -> bool` reports whether `stop` has been requested. It is
the one readable bit of the lifecycle: a readiness handler returns `503` while
it is true, so a load balancer stops routing new traffic to a draining instance.
It is `false` before `stop`, `true` after, and never returns to `false`. Reads
an atomic; safe from any thread. See `examples/09-graceful-shutdown`.

### Response streaming (opt-in, Phase 7)

```text
stream(ctx, content_type="") -> (Stream, bool)   open a detached response; then RETURN
Stream                            an opaque, stale-safe value token (copyable)
stream_send(s, data) -> Stream_Send   enqueue bounded output from any thread
Stream_Send                       enum {Sent, Full, Closed}
stream_live(s) -> bool            is the stream still open? prune a gone subscriber WITHOUT sending (C4)
stream_close(s)                   end the stream; idempotent
```

`web.stream(ctx)` opens a long-lived response bound to the request's
connection and commits its status/headers (200 plus whatever the chain —
`secure_headers`, `cors`, the request id — added), then the **Handler
returns**. The optional `content_type` sets the one header a stream's protocol
must declare itself — `text/event-stream` for SSE, `application/json` for a
chunked JSON feed; empty (the default) adds none. Later code sends on the token from any thread: `web.stream_send`
copies the bytes into stream-owned storage and never blocks — a full bounded
queue returns `.Full`, and the application decides whether to retry, drop or
coalesce. `web.stream_live(s)` reports whether the stream is still open (C4),
so a subscriber registry can prune a client that has left WITHOUT sending to it;
it is `false` for a closed/stale stream and on the in-memory transport.
`web.stream_close` writes the terminating chunk. `ok` is `false`
when there is no connection to detach (the in-memory `test_request`
transport) or the open-stream cap is reached; the Handler then falls back to
an ordinary buffered response. A Handler that never calls `stream` links none
of the streaming machinery (pay only when used). SSE is a Crystal over this
surface, not a core concept. **Do not** emit `web.stream` on the buffered
path or against `test_request` and expect a socket — it reports `ok=false`
there by design.

### Observability

```text
refused_connections() -> int    connections refused for admission, running total
stats() -> Server_Stats         the write-side counters (Closure H-3)
```

`web.refused_connections()` returns zero when no server is running and zero
when nothing was refused — those are deliberately not distinguished. It carries no request data, which is why it
exists at all: **the framework records the route pattern, the method, the
status, the request ID and its own counts, and never a path, header, body or
parameter.** Key your metrics on `web.route(ctx)`, never on
`ctx.request.path`.

`web.stats()` returns a `Server_Stats` — nine running totals for the send and
saturation sides, which `refused_connections` did not cover: `responses_sent`,
`response_bytes` (on the wire), `send_errors`, `write_deadline_aborts`,
`handler_dwell_ns`, and the three detached-stream counters `stream_refused_full`,
`stream_refused_budget`, `stream_aborted_slow` (previously reachable from no
public API, so a slow-consumer abort was counted and then unseeable). Every
field is an integer, so redaction holds by construction. Zero when no server
runs, like `refused_connections`.

**`handler_dwell_ns` is the framework's first saturation signal** (Campaign C).
It replaced `lane_collisions`, which dedicated accept made misleading rather
than dead — handlers run synchronously on the lane thread, so the
503-on-collision path is unreachable, and the only increments the counter still
received came from the acceptor's saturation refusals while real lane saturation
presented as silent queueing. `handler_dwell_ns` is a running total of
time inside dispatched handlers: difference it over an interval for
utilization (Δdwell / (lanes × Δwall)) and for mean dwell against
`responses_sent`. A rising utilization says: raise `max_handlers`, shorten the
handler, or move blocking work (DB, upstream HTTP) off the lane.

### Security headers

```text
use(&app, web.secure_headers)
```

Opt-in middleware. Sets three headers on **every** response — including the
automatic 404, the 405 and the driver's 500:

```text
X-Content-Type-Options: nosniff
X-Frame-Options: DENY
Referrer-Policy: no-referrer
```

Only headers with **one correct value that needs no configuration** are here.
**There is no CSP and no HSTS**, and none may be invented: a CSP not written for
your application breaks it, and HSTS belongs to whatever terminates TLS, which
this framework does not. Do not emit `web.csp` or `web.hsts` — they do not
exist.

`Recorded_Response.headers` is a `[]string` of `"Name: value"` lines, so a test
can assert what was set without a socket.

### The client address

```text
client_ip(ctx) -> string        the connected peer, or a forwarded address
trust_proxies(&app, prefixes)   which peers may speak for their clients
```

**`web.client_ip(ctx)` returns the CONNECTED PEER** — never a header — unless
that peer matches a prefix registered with `web.trust_proxies`, in which case
`X-Forwarded-For` is walked from the right, trusted hops are discarded, and the
first untrusted address is returned (the peer if every hop is trusted).

**Never read `X-Forwarded-For` yourself.** It is a request header, so any client
can send one, and rate limits, audit logs and allow-lists built on a forged
value are an authorization bypass. Use `web.client_ip`.

<!-- pseudocode: registering trusted proxy prefixes -->
```odin
web.trust_proxies(&app, {"10.", "127.0.0.1"})
```

Entries are address **prefixes** matched textually, not CIDR. Up to eight. An
empty prefix, or more than eight, **rejects the application at boot** — an empty
prefix would match every peer. The result is a request-scoped view: copy it to
keep it.

### Multipart forms

```text
Uploaded_File{field, filename, content_type, bytes}
form_field(ctx, "title")  -> (string, bool)
form_file(ctx, "avatar")  -> (Uploaded_File, bool)
```

Parsed from the body ALREADY IN MEMORY — there is no spool. `file.bytes` is a
view over the request body and does not outlive the request; copy what you keep.
`filename` and `content_type` are the client's claims, never checked and never
used as a path: generate your own storage name.

The readers and `web.body` share ONE single-use capability (ADR-012): whichever
runs first takes it.

**An upload larger than `max_body` (4 MiB default) is refused with 413 before
your handler runs**, and no setting makes a 2 GB upload work — the body is held
whole. Terminate large uploads at a proxy or object store and pass a reference.

A malformed form yields nothing rather than a partial parse, because a missing
field that looks like a blank one is a bug nobody attributes to the parser.

<!-- fragment: phase5/multipart -->
```odin
upload_handler :: proc(ctx: ^web.Context) {
	file, ok := web.form_file(ctx, "avatar")
	if !ok {
		web.bad_request(ctx, "avatar is required")
		return
	}
	// file.bytes is a view over the request body: copy what you keep.
	web.text(ctx, .OK, file.filename)
}
```

### Static files

```text
Static_Options{max_file_size, index}
static(&app, "/assets", "public/assets")     before the first request
```

A mount OWNS its prefix: a request under it is answered from the filesystem or
answered 404, never falling through to a route. That is the reverse-proxy
`location` rule, and it means "why is my route shadowed" never depends on
whether a file happens to exist.

Refused, always, as REJECTIONS rather than repairs: `..`, `%` (the path is never
decoded, so `%2e%2e` would pass a textual check), `\`, NUL, empty interior
segments, a leading `.` on any segment, a trailing `/`, anything that is not a
regular file, and **every symlink whatever it points at**.

Responses are buffered whole (ADR-014), so a file costs its size in memory:
`max_file_size` defaults to 8 MiB and a larger file is answered 404. No
`Last-Modified` (it would link a date formatter into every application), no
ranges, no directory listing. `ETag` and `If-None-Match` work, answering 304.

<!-- fragment: phase5/static -->
```odin
app := web.app()
web.static(&app, "/assets", "public/assets", web.Static_Options{index = "index.html"})
```

### CORS

```text
Cors_Options{origins, methods, headers, credentials, max_age}
cors(&app, o)                      set it; before the first request
```

Configuration, not middleware: the headers must reach the automatic 404, the
405 and the driver's 500 too, and the preflight must be answered before any
handler runs.

The unsafe combinations are refused at REGISTRATION — the application is
poisoned and `serve` refuses to bind — because a CORS mistake is a hole that
works perfectly and quietly: `*` with `credentials`, `*` beside named origins,
and `*` in `headers` with `credentials` (the Fetch standard does not let that
wildcard cover `Authorization`). An empty origin list is refused too.

A listed origin is echoed back with `Vary: Origin`, never the literal `*`. An
unlisted origin is SERVED with no CORS header at all, so the browser refuses to
hand the result to the page — refusing outright would break same-origin browser
POSTs, which also carry an `Origin`.

<!-- fragment: phase5/cors -->
```odin
app := web.app()
web.cors(&app, web.Cors_Options{
	origins     = {"https://app.example.com"},
	headers     = "Content-Type, Authorization",
	credentials = true,
	max_age     = 600,
})
```

### Limits

```text
Limits{max_body, max_request_line, max_headers, max_request_time,
       max_write_time, max_response_bytes, max_idle_time,
       max_connections, reserved_conns, max_drain_time, max_handlers}
DEFAULT_LIMITS   4 MiB, 8000, 8000, 30 s (ns), 0 write (ns), 0 response bytes,
                 0 idle (ns), 1024 conns, 16 reserved, 10 s drain (ns),
                 0 = auto Handlers (4..32)
limits(&app, l)                    set it; before the first request
```

<!-- fragment: phase3/limits -->
```odin
budget := web.DEFAULT_LIMITS
budget.max_body = 64 * 1024
web.limits(&app, budget)
```

**Start from `web.DEFAULT_LIMITS` and change what you mean to change.** A
`Limits` with a zero field is rejected: there is no unset state, so a forgotten
field cannot be told from a deliberate one, and the application is refused
fail-closed rather than run on a guess.

- the budget belongs to the **App**, not to `web.serve`, so `web.test_request`
  enforces the same numbers as a socket — a 413 in a test is a 413 in
  production;
- exactly the limit is accepted; one byte more is `413`;
- `web.limits` **after the first request** rejects the application: the budget
  is read on the request path, and changing it while serving would give two
  clients two different answers to the same body. Order relative to routes does
  not matter;
- `DEFAULT_LIMITS` is a **constant**, so no library can change another's
  defaults;
- **`max_request_time` bounds how long one request may take to ARRIVE**, first
  byte to last, in **nanoseconds** (30 s by default; `0` disables it). It is a
  REQUEST deadline, not an idle timeout — a client trickling one byte per second
  would reset an idle timer forever. It does **not** bound a slow handler: that
  is your program's own time.
- **`max_write_time` bounds how long one response may take to SEND** (WP90 /
  ADR-039), in **nanoseconds**, `0` = off (the default). At the deadline the
  connection is **reset**, not closed gracefully — a graceful close would
  flush kernel buffers to the slow reader first and hide the deadline. The
  field is `max_write_time`; do not emit `web.Limits{write_timeout = ...}` —
  no `write_timeout` field exists.
- **`max_response_bytes` bounds how large one response BODY may be** (ADR-045),
  in **bytes**, `0` = off (the default). It is the write-side mirror of
  `max_body`: `max_body` caps what a client may SEND, this caps what a handler
  may BUILD. A committed body strictly larger than the limit is replaced with
  the standardized **500** before it reaches the wire — never truncated — and
  reported as `Framework_Error.Response_Too_Large`. Responses are buffered whole
  (ADR-014) and retained per connection, so an unbounded one is an
  out-of-memory that kills every in-flight request; the limit converts that into
  one typed 500. It measures the body the framework built, so a HEAD is bounded
  by what it allocated. Stream large output with `web.stream` instead of raising
  it. Enforced on the shared path, so a test and a socket agree (413-for-request,
  500-for-response, both by construction).
- **`max_idle_time` bounds the quiet gap between keep-alive requests**, in
  nanoseconds, `0` = off (the default). The clock stops the moment the next
  request's bytes arrive; the close is graceful.
- **`max_connections` bounds concurrent connections** (1024 by default; `0` is
  unbounded), and **`reserved_conns` holds slots back from admission** (16) so
  a shutdown always has room to work in. Admission is refused **at or below**
  `max_connections - reserved_conns`, never at zero. A `reserved_conns` at least
  as large as `max_connections` is rejected at boot.
- **`max_handlers` bounds concurrent synchronous Handlers.** `0` is the
  bounded automatic policy (CPU count clamped to 4..32), `1` is explicit
  single-Handler compatibility, and 256 is the largest accepted explicit
  value. Full saturation stops Handler progress; it does not preempt user code.
- Handlers may run concurrently. Mutable application state and observer/logger
  sinks are application-owned and must synchronize themselves.

`Limits` bounds Uruquim's own per-request working memory. It does **not** bound
connections, accept backlog or process memory; those belong to the transport and
the operating system.

### Application state

```text
app_with_state(&state) -> App     app() plus ONE typed value; rejects nil
state(ctx, T) -> ^T               that APP-scoped value, typed; asserts before it casts
request_state(ctx, R) -> ^R       ONE typed REQUEST-scoped value (C7); middleware writes, handler reads
```

`web.request_state(ctx, R)` (C7) is the per-request counterpart of `web.state`:
one typed value that lives for the request, so a middleware can hand a handler a
computed result. The first call in a request zeroes it and stamps the type `R`;
every later call asserts the same `R` (a different type aborts — the same
programming error `web.state` catches). Storage is fixed request-local (no
allocation), so a `^R` must not escape the request. Use it for a resolved
identity a `web.use` middleware writes and the handler reads:

```text
Auth :: struct { account_id: i64 }
auth :: proc(ctx: ^web.Context) { web.request_state(ctx, Auth).account_id = 42; web.next(ctx) }
me   :: proc(ctx: ^web.Context) { web.ok(ctx, web.request_state(ctx, Auth)^) }
```

<!-- fragment: phase3/app-state -->
```odin
App_State :: struct {
	greeting: string,
}

main :: proc() {
	state := App_State{greeting = "hi"}
	app := web.app_with_state(&state)
	defer web.destroy(&app)

	web.get(&app, "/config", show_config)
	web.serve(&app, 8080)
}

show_config :: proc(ctx: ^web.Context) {
	s := web.state(ctx, App_State)
	web.ok(ctx, s^)
}
```

**One value, APP-scoped, created before serving** — a database pool, a config
struct, a cache. `web.app_with_state` gives the same defaults as `web.app()`
plus that value; a nil pointer rejects the application fail-closed.

- the App stores the **pointer**, so a handler writing through it mutates your
  value. The value must **outlive the App** — put it in `main`, beside it;
- `web.state(ctx, T)` asserts that state was registered and that `T` is
  **exactly** the registered type, then returns `^T`. A wrong type aborts: it
  is a programming error, not a runtime condition (ADR-020);
- handlers and middleware read it the same way. There is no second name;
- it is **not** per-request storage, and there is none.

## Routing

```text
get(&app, pattern, handler)
post(&app, pattern, handler)
put(&app, pattern, handler)
patch(&app, pattern, handler)
delete(&app, pattern, handler)
```

<!-- fragment: phase1/routing -->
```odin
web.get(&app, "/users/me", current_user)
web.get(&app, "/users/:id", get_user)
web.post(&app, "/users", create_user)
```

Pattern rules:

- patterns begin with `/`; `/` itself is valid;
- `:name` matches exactly one whole segment and never spans a `/`;
- up to eight `:param` segments per pattern (WP33); no wildcards. A pattern
  declaring more is invalid and never matches;
- a static route beats a parametric one by SHAPE, not by registration order;
- methods are isolated: registering GET does not register POST;
- **nothing is normalized.** `/users` and `/users/` are different paths, and
  percent-encoding is neither decoded nor rewritten. WP31b adds REJECTION, not
  transformation: a dot segment, an interior empty segment, a percent-encoded
  slash or a percent-encoded NUL is answered `400` before matching.

Registration conflicts ARE diagnosed (WP30). Two routes registered for the same
method and the same path shape reject the application fail-closed — every
request answers 500 and `web.serve` refuses to start — because the second route
could never have served. Parameter NAMES do not distinguish routes: `/users/:id`
and `/users/:uid` are the same pattern. A pattern this dispatcher cannot
interpret is a separate case and simply never matches.

`web.app()` adds two automatic responses; `web.bare()` adds neither:

```text
unknown path                     -> 404 {"error":{"code":"not_found",...}}
path exists under another method -> 405 + Allow, {"error":{"code":"method_not_allowed",...}}
```

`Allow` lists only the methods registered for that path, always in the order
`GET, POST, PUT, PATCH, DELETE`, comma-and-space separated, with no duplicates.

### Route identity

```text
route(ctx) -> string    the REGISTERED PATTERN, or "" when nothing matched
```

<!-- fragment: phase3/route-identity -->
```odin
by_route :: proc(ctx: ^web.Context) {
	// "/users/:id" — never "/users/42". `record_hit` is YOUR code.
	record_hit(web.route(ctx))
	web.next(ctx)
}
```

`web.route(ctx)` returns the pattern the request matched, so `/users/:id` and
never `/users/42`. Use it — not `ctx.request.path` — to label metrics, logs or
spans: route identity must be **low-cardinality**, and a path-valued label
creates one time series per id and puts user data in a dashboard.

A mounted route reports the composed pattern (`/api/users/:id`). A `404` or a
`405` reports `""`, because no route ran; treat that as the "unmatched" bucket.
The result is a view over App-owned storage and stays valid until `destroy` —
the one value reachable from a `^Context` that outlives its request. It is the
same string `web.Framework_Event.route` carries, by design and by test.

A method outside the `Method` set arrives as `.UNKNOWN` and follows the same
404/405 rules. It never produces a 501.

## Handler

`Handler` is the one and only handler shape. It takes the context and returns
nothing; it answers through a response helper.

<!-- fragment: phase1/readme-taste -->
```odin
get_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}

	web.ok(ctx, User{id = id, name = "Ada"})
}
```

A handler that returns without responding is a programming error: the driver
logs it and sends `500`. HTTP has no zero status.

## Request

`ctx.request` is the only public request surface — a `web.Request` value. There
is no `ctx.response`, no `ctx.params` and no `ctx.route` **field** — route
identity is read with `web.route(ctx)`, below.

<!-- pseudocode: the Request field list -->
```odin
ctx.request.method   // web.Method
ctx.request.path     // string  — view
ctx.request.query    // string  — view, raw and undecoded
ctx.request.headers  // web.Header_View — no lookup in Phase 1
ctx.request.body     // []u8    — view
```

`Method` members are UPPERCASE. The complete set:

```text
.UNKNOWN  .GET  .POST  .PUT  .PATCH  .DELETE
```

Any other token — `"HEAD"`, `"OPTIONS"`, `"PROPFIND"`, or a lowercase `"get"`,
since HTTP methods are case-sensitive — arrives as `.UNKNOWN`.

**Lifetime.** Every request-derived string and slice is a VIEW over storage the
transport owns for the duration of one request. To keep any of it, copy it
explicitly:

<!-- fragment: phase1/copy-to-persist -->
```odin
keep_a_path :: proc(ctx: ^web.Context) -> string {
	name := web.path(ctx, "name")
	return clone_for_later(name)
}
```

Never hand a `^Context` or a request view to background work.

## Extractors

Every extractor that can fail RESPONDS TO THE CLIENT ITSELF and returns
`false`. On failure, just `return` — never write your own error response for an
extractor failure.

There are exactly two shapes:

<!-- fragment: phase1/path-int -->
```odin
// Shape 1 — value-producing: (value, ok)
get_user :: proc(ctx: ^web.Context) {
	id, ok := web.path_int(ctx, "id")
	if !ok {
		return
	}

	web.ok(ctx, User{id = id, name = "Ada"})
}
```

<!-- fragment: phase1/body -->
```odin
// Shape 2 — destination-filling: bool
create_user :: proc(ctx: ^web.Context) {
	input: Create_User
	if !web.body(ctx, &input) {
		return
	}

	web.created(ctx, User{id = 1, name = input.name})
}
```

The full set:

```text
path(ctx, name)            -> string          route matched => present; never responds
path_int(ctx, name)        -> (int, ok)       responds 400 on failure
query(ctx, name)           -> (string, found) never responds
query_int(ctx, name)       -> (int, ok)       responds 400 when absent or malformed
query_int_or(ctx, n, def)  -> (int, ok)       default ONLY when absent
query_int_opt(ctx, name)   -> (int, present, ok)  OPTIONAL typed (C3): absent=present:false,ok:true (no 400); present+valid=both true; malformed=400
body(ctx, &dst)            -> bool            responds 400/413 on failure
```

For an OPTIONAL typed query filter, use `query_int_opt` — not `query_int` (which
400s on absence) nor `query_int_or` (whose `ok` cannot tell absent from present).
Canonical:

```text
if v, present, ok := web.query_int_opt(ctx, "assignee"); !ok { return }  // malformed → 400 committed
else if present { /* apply the filter with v */ }
```

<!-- fragment: phase1/query -->
```odin
search :: proc(ctx: ^web.Context) {
	q, found := web.query(ctx, "q")
	if !found {
		web.bad_request(ctx, "the 'q' parameter is required")
		return
	}

	limit, ok := web.query_int_or(ctx, "limit", 20)
	if !ok {
		return
	}

	web.ok(ctx, User{id = limit, name = q})
}
```

Semantics you must not guess at:

- **Views, not copies.** `path` and `query` return views over the request.
- **The default applies only to ABSENCE.** `?limit=banana` and `?limit=` are
  both `400`, never `20`. Presence is decided by the key.
- **A key with no `=` is present with an empty value.** `?flag` gives
  `("", true)`; an absent key gives `("", false)`.
- **Integers are strict decimal:** an optional `-` then ASCII digits. `+5`,
  `0x10`, `1_000`, `1.5` and surrounding whitespace are rejected.
- **Comparison is exact and case-sensitive**, for path and query names.
- **Nothing is decoded.** `?q=a%20b` yields the literal `a%20b`.
- **`body` is single-use.** Call it at most once per request; a second call
  decodes nothing. After it returns false, `dst` is undefined — discard it.
- **Body decoding is strict.** Malformed or trailing input is `invalid_json`;
  a wrong value type is `invalid_field`; an undeclared key is `unknown_field`.
  The latter two carry a bounded dot-separated `field` path.
- **The body cap is a fixed 4 MiB.** An oversized request is `413` before your
  handler runs, even if the handler never calls `body`.

JSON structs use tags:

<!-- pseudocode: a DTO with json tags -->
```odin
User :: struct {
	id:   int    `json:"id"`,
	name: string `json:"name"`,
}
```

## Responses

<!-- fragment: phase1/responses -->
```odin
respond_examples :: proc(ctx: ^web.Context) {
	web.ok(ctx, User{id = 1, name = "Ada"})
	web.created(ctx, User{id = 2, name = "Grace"})
	web.json(ctx, .Accepted, User{id = 3, name = "Queued"})
	web.text(ctx, .OK, "pong")
	web.no_content(ctx)
}
```

```text
ok(ctx, value)               200 JSON   — exactly json(ctx, .OK, value)
created(ctx, value)          201 JSON   — exactly json(ctx, .Created, value)
json(ctx, status, value)     any status, JSON
text(ctx, status, s)         plain text
bytes(ctx, status, ct, data) any status, caller-chosen Content-Type, raw []u8 body (C2)
no_content(ctx)              204, no body, no Content-Type
```

The status argument has type `Status`, so write an inferred enum member, never
a bare integer. The complete set:

```text
.OK .Created .Accepted .No_Content
.Bad_Request .Unauthorized .Forbidden .Not_Found .Method_Not_Allowed
.Conflict .Payload_Too_Large .Too_Many_Requests
.Internal_Server_Error .Service_Unavailable
```

The last row's `.Conflict` (409), `.Payload_Too_Large` (413), `.Too_Many_Requests`
(429) and `.Service_Unavailable` (503) were added by corrective WP C1 (friction
F8-1): operationally-essential codes three independent applications were forced
to spell as raw-int casts. Prefer the named member over `Status(<int>)`.

`Content-Type` is set for you: `application/json` for JSON and every envelope,
`text/plain; charset=utf-8` for text, the caller's value for `bytes`, none for
`no_content`.

Set your own response headers with **`web.set_header(ctx, name, value) -> bool`**
(corrective WP C2, friction F8-2) — for `Set-Cookie`, `Cache-Control`,
`Content-Disposition`, `Location`, etc. Call it BEFORE the responder; it returns
`false` if the response is already committed, the name is empty or the name/value
carries a control byte (CR/LF/NUL — header injection), the name is framework-owned
(`Content-Type`, `Content-Length`, `Transfer-Encoding`, `Connection`,
`X-Request-Id`), or the per-request budget is exhausted. Application headers are
emitted after every framework header. Serve a file download by pairing
`web.set_header(ctx, "Content-Disposition", …)` with `web.bytes`.

**Payloads are VALUES.** `web.ok(ctx, user)` — never a pointer, and never a
variable whose type is `^User`. A rejected payload is logged on the server and
answered with one complete `500`; no partial body is ever sent.

**The first response wins.** Once a response is committed, later responders are
no-ops. That is what makes "the extractor already answered, just return" safe.

## Errors

<!-- fragment: phase1/errors -->
```odin
deny :: proc(ctx: ^web.Context) {
	web.bad_request(ctx, "email is required")
}
```

```text
bad_request(ctx, message)     400
unauthorized(ctx, message)    401
forbidden(ctx, message)       403
not_found(ctx, resource)      404  message: Resource '<resource>' not found
internal_error(ctx)           500  takes no message on purpose
```

All errors share one envelope:

```json
{"error": {"code": "...", "message": "...", "field": "..."}}
```

`field` is present only for input-specific errors:
`invalid_path_parameter`, `invalid_query_parameter`, `invalid_field`, and
`unknown_field`. For every other code it is **omitted entirely** — never
`null`, never `""`. `docs/errors.md` documents each code.

## Middleware

```text
use(&app, middleware)   register; MUST come before the first route
next(ctx)               run the rest of the chain from inside a middleware
```

A middleware is an ordinary `Handler`. `use` after any route — or after the
first dispatched request — REJECTS the application fail-closed: every request
answers `500` and `web.serve` refuses to start. Register every `use` first.

<!-- fragment: phase2/bearer-auth -->
```odin
require_auth :: proc(ctx: ^web.Context) {
	token, ok := web.bearer_token(ctx)
	if !ok || !token_is_valid(token) {
		web.unauthorized(ctx, "authentication required")
		return
	}
	web.next(ctx)
}
```

Chains run in `use` order and unwind in reverse (`A>B>C>H<C<B<A`). Returning
without calling `next` short-circuits: nothing downstream runs and your
response wins. Code after `next` runs at unwind, when the response is already
committed — read there, never write (a late response attempt is rejected; the
first response survives). A second `next()` is a no-op; the handler runs
exactly once. Middleware also observe automatic `404`/`405` responses.
`docs/middleware.md` has the full contract.

**The one built-in middleware is `web.logger`.** It is opt-in — there is no
default-on logging — and writes one `.Info` line per request through
`context.logger`:

<!-- fragment: phase2/logger-use -->
```odin
web.use(&app, web.logger)      // before the first route, like every use
```

```text
uruquim: GET /orders/:id 200   method, REGISTERED PATTERN, committed status
uruquim: GET - 404             a miss has no pattern: `-`, never the raw path
uruquim: GET /silent -         nothing was committed while the logger watched
```

It never logs the raw path, the query string, a header, a body byte, or a
captured parameter value. A too-long route field is cut and marked
`...[truncated]`, never grown and never silently dropped. Do not tell a user to
configure its level, sink or format: it has none, by design.

**`web.request_id` is the other built-in.** Opt-in, registered FIRST so later
middleware see the ID:

<!-- fragment: phase2/request-id-use -->
```odin
web.use(&app, web.request_id)
web.use(&app, web.logger)
```

A handler reads it through the ordinary accessor — there is no second name:
`web.header(ctx, "X-Request-Id")`. An inbound ID is honoured ONLY if it matches
`[A-Za-z0-9._-]` and length 1..64; anything else (a space, a control byte, and
above all CR/LF) is DISCARDED and replaced — never echoed, never logged. The ID
appears on every committed response including a 404, a 405 and the standardized
500. **It is unique but NOT unguessable: never present it as authentication.**

## Routers

```text
Router                        a detached collection of routes + middleware
router() -> Router            create; allocates nothing
mount(&app, "/prefix", &r)    attach every route at prefix + pattern
```

A `Router` accepts the SAME procedures an `App` does — `use`, the five verbs,
`destroy` — with no new forms. Build it fully (every `use` before its first
route), then mount it; `mount` COPIES, closes the router (later registrations
on it fail closed), and counts as a registration for the app. Destroy the app
AND every router, each exactly once. `web.group` stays unavailable in every
future phase (ADR-024) — a mounted Router is the one canonical grouping.

<!-- fragment: phase2/router-mount -->
```odin
api := web.router()
defer web.destroy(&api)
web.use(&api, require_auth)
web.get(&api, "/users", list_users)

web.mount(&app, "/api", &api)
```

The prefix must begin with `/` and must not end with `/`; the mounted pattern
is prefix + pattern VERBATIM (nothing is normalised, so a router's `"/"`
mounted at `"/api"` serves `"/api/"`, not `"/api"`). Chain order: app globals,
then each enclosing router outermost-first, then the handler. A route needing
its own guard is a ONE-ROUTE Router mounted at the path.

## Request headers

```text
header(ctx, name)  -> (value, ok)   the effective request header
bearer_token(ctx)  -> (value, ok)   strict RFC 6750 Authorization parse
```

Both are PURE lookups: they never commit a response (unlike the extractors —
an absent header is routinely not an error) and never log. `ok` means
presence; an empty value is present. Names are case-insensitive; duplicates:
first occurrence wins. Values are VIEWS valid only for the request — copy to
persist. The token comes back verbatim: never trimmed, never normalised; a
sloppy `Authorization` (two spaces, trailing blank, wrong scheme) is rejected,
not repaired.

<!-- fragment: phase2/bearer-auth -->
```odin
require_auth :: proc(ctx: ^web.Context) {
	token, ok := web.bearer_token(ctx)
	if !ok || !token_is_valid(token) {
		web.unauthorized(ctx, "authentication required")
		return
	}
	web.next(ctx)
}
```

## Observability

```text
observe(&app, observer)   register ONE observer; a later call replaces it
Framework_Event{kind, method, route, status, payload_type}
Framework_Error           closed enum: the framework failure kinds
```

An observer is a plain procedure taking the event **by value**:

<!-- fragment: phase2/observe -->
```odin
report_failure :: proc(event: web.Framework_Event) {
	metrics_increment(event.kind, event.route, event.status)
}
```

It receives the event and **nothing else** — no `ctx`, no body, no headers —
so it cannot respond and cannot read request bytes. `route` is the REGISTERED
PATTERN (`/users/:id`), never the request path, and is `""` when no route
matched; no field carries a message. `status` is what the framework actually
committed; a failure outside a request (`serve` could not bind) carries no
method, route or status.

It fires for framework-detected FAILURES only — a marshal failure, an
undecodable body, a double `web.body`, a handler that committed nothing, an
invalid or unavailable `serve` port, a fail-closed application. A `404` or a
`400` from an extractor is a normal outcome, not a failure, and emits nothing.
Installing an observer changes no response.

## Testing

The test-support ledger is exactly **2** symbols, tracked separately from the
73 application symbols.

```text
test_request(&app, method, path) -> Recorded_Response
Recorded_Response{status, body, headers}
```

<!-- fragment: phase1/test-request -->
```odin
check_ping :: proc() -> bool {
	app := web.app()
	defer web.destroy(&app)
	web.get(&app, "/ping", ping)

	res := web.test_request(&app, .GET, "/ping")
	return res.status == .OK && res.body == "pong"
}
```

It drives the REAL routing and the real response pipeline with no socket, so a
result here matches what a real client gets. `body`, `query` and `headers` are
optional parameters; each `headers` element is one `"Name: value"` line
(`headers = {"Authorization: Bearer tok"}`). `Recorded_Response` exposes
`status` and `body` only — there is no public way to read response headers.

`body` stays valid until `web.destroy(&app)`.

## Full example (copy this shape)

The complete programs live in `examples/`. The smallest one:

<!-- compile: examples/01-hello-world/main.odin -->
```odin
package main

import web "uruquim:web"

main :: proc() {
	app := web.app()
	defer web.destroy(&app)

	web.get(&app, "/ping", ping)

	web.serve(&app, 8080)
}

ping :: proc(ctx: ^web.Context) {
	web.text(ctx, .OK, "pong")
}
```

See `examples/02-json-api` for a CRUD-shaped API and
`examples/03-route-params` for path and query handling.

## Rules

- Never use `or_else` with a statement block — that is not valid Odin. Use
  `(value, ok)` plus `if !ok { return }`, or `if !web.body(ctx, &input) { return }`.
- Every fallible extractor's `ok` MUST be captured and checked; the compiler
  enforces it.
- `web.body` takes a POINTER to your struct and returns `bool`. Call it once.
- JSON payloads are passed BY VALUE. Do not pass `&value` or a pointer-typed
  variable.
- Method members are UPPERCASE: `.GET`, never `.Get`.
- Never configure allocators or transports — `web.app()` and `web.serve`
  handle them.
- Never store request data in maps or `any`; there is no `ctx.user_data`.
- Copy request-derived data explicitly if it must outlive the request.

---

## Appendix — future phases

**Everything below is UNAVAILABLE in Phase 1. Do not emit it.** It is listed
only so an agent recognizes the names and refuses them.

<!-- phase: 4; unavailable -->
```odin
// Phase 4 — unavailable in Phase 1.
web.serve_with(&app, web.Serve_Config{host = "0.0.0.0", port = 8080})
```

Other names reserved for later phases, none of which exist today:
`web.serve_transport`, `web.body_limit`, `web.redirect`. (`web.bytes` and
`web.set_header` DO exist now — added by corrective WP C2; `web.conflict` is
unnecessary since C1 made `.Conflict` a named `Status` member.) Two names will
NEVER exist: `web.recovery` (ADR-020) and `web.group` (ADR-024).

Phase boundaries in one line each:

- **Phase 2** — middleware, route organisation, header lookup, the typed
  error observer, the built-in `logger` and `request_id` (all delivered). No
  panic recovery — Odin has no recoverable panic (ADR-020).
- **Phase 3** — route groups, typed application state and configurable limits
  (the read deadline arrived in Phase 4; the write and idle deadlines in
  Phase 7's WP90).
- **Phase 4** — graceful shutdown with a deadline, security hardening.
