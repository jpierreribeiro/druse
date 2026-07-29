# Middleware

Middleware arrived in Phase 2 (WP17): `web.use` registers it, `web.next` runs
the rest of the chain. A middleware is an **ordinary handler** — the frozen
`proc(ctx: ^web.Context)` shape. There is no `Middleware` type, no
configuration object, and no second registration form.

## Ordering is a security boundary — register `use` first

Every `web.use` must come before the first route registration. This is
**enforced, not advised**: `use` after any `get`/`post`/`put`/`patch`/`delete`
— or after the first dispatched request — rejects the whole application
fail-closed. Every request then answers `500`, `web.serve` refuses to start,
and a diagnostic naming the first unprotectable pattern is logged.

The rule exists because the alternative was measured. A prototype allowed this
program, which reads as "my admin routes and my auth middleware" and looks
correct:

<!-- pseudocode: the rejected mis-ordered shape -->
```odin
web.get(&app, "/admin/users", admin_users) // looks protected. WAS NOT.
web.use(&app, require_auth)
web.get(&app, "/admin/keys", admin_keys)   // was protected.
```

`/admin/users` served its response — an authentication bypass with no error,
no warning, and no runtime symptom, produced by moving one line. A rule
enforced only by a paragraph is not enforced, so the framework refuses the
program instead.

The canonical shape:

<!-- fragment: phase2/middleware-use -->
```odin
app := web.app()
defer web.destroy(&app)

web.use(&app, require_auth) // before any route — the order is enforced
web.get(&app, "/admin/users", list_users)

web.serve(&app, 8080)
```

## Writing middleware

Call `web.next(ctx)` to run the rest of the chain — later middleware, then the
route handler. Return **without** calling `next` to short-circuit: nothing
downstream runs, and your response is what the client receives.

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

(`web.bearer_token` rejects a sloppy `Authorization` — wrong scheme, doubled
or trailing whitespace — rather than repairing it, and the token is never
logged: header values are attacker-controlled.)

## Execution order

Middleware run in `use` order and unwind in exactly the reverse order — the
chain is an onion:

```text
use(A); use(B); use(C); get("/x", H)   =>   A > B > C > H < C < B < A
```

Code after `next` runs as your frame resumes, which is what makes timing and
"log the status we actually sent" possible:

<!-- fragment: phase2/middleware-unwind -->
```odin
observe_outcome :: proc(ctx: ^web.Context) {
	web.next(ctx)
	// the request is fully answered here
}
```

Rules you can rely on, each pinned by a test:

- **After `next` returns, the response is committed.** A response attempt from
  unwind code is rejected by the single-commit guard and the first response
  survives byte-identically. Read on the way out; never write.
- **A second `next()` call is a silent no-op.** The handler runs exactly once.
- **`next()` from a route handler is a no-op** — the chain is exhausted.
- **A middleware that neither calls `next` nor responds** leaves the response
  uncommitted; the driver answers the standard `500`, exactly as it does for a
  handler that forgot to respond.

## Misses are observed

App-level middleware run on **every** dispatch, including a `404` (no route)
and a `405` (path known under another method). The automatic envelope and the
`Allow` header are unchanged; your middleware simply sees the request enter
and unwind. Once audit or rate-limit middleware exist, "misses are invisible"
is exactly the hole an attacker probes — so they are not invisible.

`web.bare()` keeps the same observation mechanism with no response policy: on
a miss the chain runs, nothing is committed, and the driver's `500`
finalization applies, as always under `bare()`.

## `web.logger` — the one built-in middleware

`web.logger` writes exactly one line per request to `context.logger`, at
`.Info` level, after the rest of the chain has run. It is **opt-in**:

<!-- fragment: phase2/logger-use -->
```odin
app := web.app()
web.use(&app, web.logger)          // before the first route, like every use
web.get(&app, "/orders/:id", show_order)
```

The line:

```
druse: GET /orders/:id 200       a routed request
druse: GET - 404                 a miss: no pattern exists, so none is shown
druse: GET /silent -             nothing was committed while the logger watched
```

Three fields, and the omissions are the design:

- **the method**, or `-` for a method outside the ratified set;
- **the registered route pattern** — never the raw path. On a miss there is no
  pattern, so the field is `-`, and it does **not** fall back to the path. The
  traffic most worth logging is exactly the traffic whose path you least want
  to echo, and unbounded cardinality breaks whatever consumes the log. This is
  the same rule `Framework_Event` follows;
- **the committed status**, or `-`.

**It never logs the query string, any header name or value, any body byte, or
a captured path-parameter value.** That is a contract, asserted on the exact
bytes of the line in `tests/wp22-public-surface/`, not a description of current
behaviour.

**Misses are logged.** `logger` is an ordinary app-level middleware, so it
observes 404s and 405s through the miss chain. A logger blind to unmatched
traffic is the hole an attacker probes.

### Why the status can be `-`

The line is written **after `next` returns**, which is what makes the status a
reading rather than a guess. The consequence is stated rather than hidden: when
a handler commits nothing, the driver finalizes the standard 500 **after
dispatch returns** — after the chain has unwound past the logger — so the
logger never saw it and prints `-`. Printing `500` there would be the framework
reporting a response it did not watch being sent. That failure reaches
`web.observe` instead, which is the channel that does see it.

### Truncation is announced, not silent

The line is composed in a fixed stack buffer. A route pattern too long for the
field is cut on an escape boundary and marked:

```
druse: GET /aaaa…aaa...[truncated] 200
```

The status still follows the mark, so a truncated pattern never costs you the
outcome of the request. The two silent alternatives are both refused on
purpose: growing the buffer would re-import the per-request allocation the
fixed buffer exists to avoid, and dropping the line would make the logger lie
by omission about traffic it saw.

CR, LF, backslash and control bytes in a pattern are **escaped** (`\r`, `\n`,
`\\`, `\x09`), so a pattern can never forge an extra log record.

### Cost

- **Zero when unused.** An application that never names `web.logger` links
  **zero** logger symbols — proven with `nm` in
  `build/check_wp22_controls.sh`, against a positive control (an application
  that does use it links six). Roughly 2.8 KiB of code when you do use it.
- **No imports.** Not `core:log` (measured at ~37 KiB added to *every*
  application, referenced or not — Odin links an imported package whether or
  not anything uses it), and not `core:fmt`. It writes through the
  `context.logger` your application already has and encodes its one integer by
  hand.
- **No allocation.** One fixed-size stack buffer per logged request.

### What it is not

No levels, no sinks, no sampling, no structured fields, no latency
measurement. Those are Phase-4 observability. A log ring, queue or drop policy
is specifically **not** here: building one now would put an unbounded queue
behind a bounded-buffer claim.

## `web.request_id` — correlation IDs, with a stated trust policy

`web.request_id` gives every request an ID, honours a well-formed one supplied
by a client, and puts the result on the response. Opt-in, like everything here:

<!-- fragment: phase2/request-id-use -->
```odin
app := web.app()
web.use(&app, web.request_id)   // register FIRST, so later middleware see the ID
web.use(&app, web.logger)
web.get(&app, "/orders/:id", show_order)
```

A handler reads it through the ordinary header accessor — there is no second
name for it:

<!-- pseudocode: reading the effective request ID -->
```odin
id, _ := web.header(ctx, "X-Request-Id")
```

### The trust policy (this is a security boundary)

The inbound `X-Request-Id` is **attacker-controlled**. It is honoured **only**
if it matches:

- charset `[A-Za-z0-9._-]`, and
- length 1..64.

Anything else — too long, empty, a space, a semicolon, a control byte,
non-ASCII, and above all **CR or LF** — is **discarded**, and a fresh ID is
generated. Discarded means discarded: the rejected value is never echoed to the
client, never readable by your handler, and **never logged**. There is no
sanitising step, because a repaired attacker value is still an attacker value.

The attack this closes is CR/LF header injection: a value carrying `\r\n`
would forge extra response headers. The charset makes that impossible by
construction.

### The ID is not a secret

It is generated from a per-process seed plus a counter. It is **unique**, and
it is deliberately **not unguessable**. Never use a request ID for
authentication, authorization, or anything an attacker benefits from
predicting. It is a correlation handle for logs and traces, nothing more.

### Where it appears

On **every** response the framework commits — including a `404`, a `405`, and
the standardized `500` for a handler that forgot to respond. That last one is
the point: the response you most need to correlate is the one that went wrong.
The header is emitted exactly once.

Without the middleware, nothing changes: no header is added, and
`web.header(ctx, "X-Request-Id")` returns whatever arrived, unvalidated —
validation is the middleware's job, not the accessor's.

### Cost

No allocation: the ID lives in a fixed 64-byte buffer on the request context.
No new dependency — a cycle counter or a clock would each have added one for a
value that is explicitly not a secret.

## Costs, stated plainly

- Dispatch through a middleware chain allocates **zero** bytes; chains are
  flattened once, at registration.
- The machinery present but unused costs **+2,424 bytes** of binary in a
  default build, **+1,488** with `-o:speed` (measured on the hello-world
  example against the Phase-1 baseline).
- **It is linked whether or not you call `use`**, and that is by design. An
  application that never calls `use` still links eight symbols from the
  middleware machinery — `chain_enter`, `chain_flatten`, `miss_chain_ensure`,
  `miss_terminal`, `mw_destroy`, `mw_miss_prepare`, `mw_poison_intercept` and
  `next` — because dispatch walks a chain for every request and the
  fail-closed ordering guard has to sit on the shared dispatch path, so both
  transports reject an ill-formed application identically. The `+2,424 bytes`
  above IS that cost. (An earlier version of this page also claimed such a
  program "does not even link it", which contradicted the same sentence's own
  figure; the WP25 claim ledger measured it and corrected it.)
- Registering one middleware costs **+8,448 bytes** over a hello-world
  baseline, measured in a debug build. The noise floor of this toolchain is
  ~100 bytes — it does not build reproducibly — so treat smaller deltas as
  "no measurable cost".
- The chain runs by recursion: each middleware holds a stack frame while the
  rest runs (~80 bytes each in a debug build, ~16 with `-o:speed`). The
  practical depth bound is around one hundred thousand on the default stack —
  and **exceeding it is a segfault, not a diagnostic**. A realistic
  application registers fewer than twenty.

## What does not exist

- **No route-level middleware parameters.** The five registration signatures
  are frozen (ADR-025, option B); a route needing its own guard is a
  ONE-ROUTE `Router` mounted at the path — `use` on the router, then the one
  route, then `mount`. Router-level middleware follow every rule on this
  page, nested inside the app's globals (outermost first).
- **No recovery middleware, ever.** Odin has no recoverable panic; a faulting
  handler aborts the process (ADR-020). Run under a supervisor.
- **No request-ID middleware yet.** It is a later Phase-2 work package.
