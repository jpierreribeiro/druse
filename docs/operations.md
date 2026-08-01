# Operating Druse

**Who this is for:** whoever has to deploy this and be woken up by it.

It says what is bounded, what is not, what to monitor, and — the section most
documents leave out — **what this framework does not protect you from.** A
deployment guide that only lists features is a guide that gets someone paged.

---

## 1. The supported topology

**Behind a reverse proxy, under a supervisor.** Both halves are load-bearing.

```
    internet → reverse proxy (TLS) → Druse (HTTP) → your handlers
                                        ↑
                                   supervisor
```

**Why a proxy.** Druse does not terminate TLS and will not: in-process TLS
would import an enormous attack surface into a framework whose value is a small,
frozen, gate-enforced one. The proxy holds the certificate, and it is also the
thing that should assert HSTS — a framework behind it asserting HSTS on a
cleartext hop is asserting something it cannot know.

**IPv6.** `web.serve` binds **dual-stack** (ADR-046): IPv6 `::` when the host has
IPv6 — which on a standard Linux (`net.ipv6.bindv6only` = 0) serves IPv4 clients
on the same socket — falling back to IPv4 Any where IPv6 is disabled. An IPv4
client's `web.client_ip` is the dotted-quad, not the `::ffff:` mapped form, so
`trust_proxies` prefixes match identically either way. A host that sets
`bindv6only = 1` gets IPv6-only on that socket; front it with the proxy this
topology already mandates. (TLS is delegated; IPv6 ingress in that topology is
naturally the proxy's job too — the native dual-stack bind is for a direct
deployment.)

**Restart caveat — the dual-stack socket and a lingering IPv4 bind.** Because the
listener is IPv6 `::` (dual-stack), it overlaps the whole IPv4 space: a `::8080`
bind and an old `0.0.0.0:8080` bind **conflict**. If you restart the process
without the previous instance's listening socket having fully closed — killing
`-9` and immediately re-execing, or running two instances on one port — the new
`web.serve` can fail to bind. This is standard socket behaviour, not a framework
fault (a clean stop, or waiting for the socket to leave the table, avoids it),
but it is sharper for a dual-stack listener than it was for the old IPv4-only
one: the supervisor should let the old process's socket close before starting
the replacement. `systemd` does this correctly by default; a hand-rolled
kill-and-restart loop must not race the port.

**Why a supervisor, and this is not a nicety.** **A faulting handler aborts the
process.** Odin has no recoverable panic (ADR-020), so a nil dereference, a
failed assertion or an out-of-bounds index in your handler ends the program. The
supervisor restarting it *is* the recovery mechanism. There is no other one and
there will not be. **This is also how Gin is deployed in practice** — the
difference is that this document writes the boundary down instead of leaving it
folklore.

**The canonical unit is `ops/deploy/druse.service`** — copy it, edit three
values, `systemctl enable --now`. It encodes the whole mandatory topology in one
place: `Restart=on-failure` (the recovery), `TimeoutStopSec` (the shutdown outer
bound, kept longer than `max_drain_time`), `MemoryMax` (the C-04 cgroup bound),
and — easy to forget and load-bearing — **`LimitMEMLOCK`**, because io_uring pins
memory per Handler lane and a too-low limit makes `serve` fail to acquire its
event loop (F-C03-2). The essentials:

```ini
[Unit]
StartLimitBurst=5      # these two ARE systemd's defaults, written down so you
StartLimitIntervalSec=10s  # know the loop stops; [Unit], not [Service], since v230

[Service]
ExecStart=/usr/local/bin/your-app
Restart=on-failure
RestartSec=1
TimeoutStopSec=30      # > Limits.max_drain_time (10s default), < orchestrator grace
LimitMEMLOCK=64M       # io_uring locked memory, per lane; raise with max_handlers
MemoryMax=1G           # the C-04 aggregate bound — see §"What the framework bounds"
```

**`Restart=on-failure`, not `always`, and the difference matters.** A faulting
handler exits non-zero, so `on-failure` recovers it — including an OOM kill. A
deliberate `systemctl stop` exits cleanly and is left alone, which is what you
want when you are the one stopping it. **And restarting is not infinite:**
systemd gives up after `StartLimitBurst` starts inside `StartLimitIntervalSec`
and parks the unit in `failed`. That backstop applies whether or not you write
it down, so the unit writes it down — a crash-looping binary that has stopped
being restarted is something you want to learn from an alert, not from a
graph of zero traffic. Alert on unit state, not just on the process being up.

### Diagnosing a handler fault

When a fault aborts the process, the thing you want is *which request killed it*.
The core installs **no crash signal handler** and deliberately does not (ADR-047):
a library that hijacks `SIGSEGV` fights the operator's own crash tooling, and a
core dump is both safer and more informative than any breadcrumb the framework
could write from a signal handler. So let systemd capture the core:

```
apt install systemd-coredump      # or your distro's equivalent
coredumpctl gdb druse           # opens the last crash; `bt` shows the stack
```

The faulting handler is on the stack — the request that killed the process,
named precisely, with its call chain — which is more than "method + route" and
does not risk deadlocking inside an async-signal context to get it. Pair it with
the typed observer (`web.observe`) and `web.stats(&app)` for the failures that do
*not* abort (an uncommitted response is a logged 500, a busy lane is a counted
503).

---

## 2. What the framework bounds

Set these explicitly rather than inheriting them, because a default you did not
choose is a default you will not remember under load:

```odin
budget := web.DEFAULT_LIMITS
budget.max_body         = 1 * 1024 * 1024   // 4 MiB default
budget.max_request_time = 10 * 1_000_000_000 // 30 s default, nanoseconds
budget.max_connections  = 512                // 1024 default
budget.max_handlers     = 8                  // 0 = bounded automatic policy
web.limits(&app, budget)
```

| Bound | Default | What happens at the limit |
|---|---|---|
| `max_body` | 4 MiB | `413`, before the parser and before any arena |
| `max_request_line` | 8000 | the backend refuses the request |
| `max_headers` | 8000 | the backend refuses the request |
| `max_request_time` | 30 s | **the connection is closed** — this is the slowloris defence |
| `max_write_time` | `0` = off — but see below | **the connection is reset (RST)** — a graceful close would flush kernel buffers to the slow reader first and hide the deadline; the reset is the observable, honest end (WP90 / ADR-039) |
| `max_idle_time` | `0` = off | the idle keep-alive connection is **closed gracefully**; the clock stops the moment the next request's bytes arrive |
| `max_connections` | 1024 | the connection is **closed at accept**, not queued |
| `reserved_conns` | 16 | slots held back from admission so a shutdown always has room |
| `max_handlers` | `0` = auto | synchronous Handler capacity; auto resolves from CPU count, bounded to 4..32 |
| `max_json_nodes` | 100,000 | `413` with code `body_too_complex`, before the JSON parser allocates — the structural cost bound (audit J3/J4) |

**`max_write_time` at `0` does not mean sends are unbounded.** One of the two
deadlines always covers a response send: with no write deadline configured,
`max_request_time` bounds it instead, and the connection is **aborted** and
counted in `web.stats(&app).write_deadline_aborts`. This is deliberate (audit M4) —
leaving a send unbounded is worse than bounding it with the only number you
gave us. Before M4 the same thing happened by accident and was logged as
`request read deadline exceeded`, about a request that had finished arriving
long before; measured on a 64 MiB body against a client that stopped reading.

Set `max_write_time` explicitly when your sends and your request arrivals
deserve different budgets — a large download to a slow link is a legitimate
long send, and it is bounded by `max_request_time` until you say otherwise. If
both are `0`, sends really are unbounded and a stalled reader parks a
connection slot until it goes away.

**`max_json_nodes` bounds STRUCTURE, which `max_body` cannot see.** Two
well-formed bodies, both inside the 4 MiB body cap, measured on a 4 vCPU host:
a 4 MiB array of 1,398,101 empty objects decoded into a 288-byte DTO peaked at
**588 MB of RSS**; a 4 MiB object of 322,000 keys held one Handler lane for
**1.6-2.1 s**. Neither is malformed, so nothing else had grounds to refuse them,
and the body really is 4 MiB in both cases — bytes are simply not what the
decode costs scale with.

The budget counts JSON values plus object keys, so an N-key object costs
`2N + 1` and an N-element array of scalars costs `N + 1`. At the default the
same two bodies cost **20 MB** and **50 ms**. Ordinary API traffic is two to
three orders of magnitude below the ceiling — a 25,000-key body is still served
— so raise it only if you knowingly accept bulk documents, and raise it having
decided what `max_handlers` lanes of that size cost you. `0` disables it.

**`max_request_time` is a REQUEST deadline, not an idle timeout.** An idle timer
is reset by every byte, so a client trickling one byte per second resets it
forever — which is precisely the attack. This bounds the total time a request
may take to *arrive*.

**It does not bound your handler.** A slow handler is your program's time, and
killing its connection would turn a slow page into a broken one.

### Handler concurrency

Handlers may run concurrently. The default `max_handlers = 0` selects a
bounded automatic capacity: processor count clamped to 4..32. Set it to `1`
for deterministic compatibility with deliberately single-threaded application
state, or to an explicit value up to 256 when capacity planning requires it.

This is **Handler capacity**, not a promise about backend threads. Slow socket
reads and writes remain asynchronous and do not consume a Handler unit. A
blocking database call consumes one unit; health remains live while at least
one unit is free. Full saturation is an explicit boundary, not hidden
preemption.

This is for ordinary blocking dependencies, **not a CPU scheduler**. If your
handlers are CPU-bound, size `max_handlers` deliberately and scale with more
processes rather than raising it.

`App_State` is application-owned. Mutable values shared by Handlers need a
lock, atomics or a thread-safe service; immutable configuration does not.

---

## 3. What the framework does NOT bound — read this section twice

| Not bounded | Who owns it |
|---|---|
| **your handler's own allocations** | you |
| **your response body's size** | you |
| **how long your handler runs** | you |
| the accept **backlog** | the kernel |
| inbound header **count** (the block's bytes are bounded) | the transport |
| total process memory | the OS — set a cgroup limit |
| middleware chain **depth** | you; ~100k frames, and exceeding it is a **segfault, not a diagnostic** |

**Druse bounds its own per-request working memory. It does not bound the
server.** Any sentence that says "bounded" without naming which perimeter is a
sentence this project's gate exists to prevent.

---

## 4. Shutdown, and its sharp edge

```odin
web.stop(&app)   // returns immediately; safe from a signal handler
```

`stop` ends admission and lets in-flight work finish; `web.serve` returns when
the drain completes.

**Wire it to a signal yourself — the core does not.** A rolling deploy sends
`SIGTERM`; nothing drains unless your `main` installs a handler that calls
`web.stop`. The core installs none deliberately: seizing process signals fights
your supervisor. The canonical shape (full program in
`examples/09-graceful-shutdown`):

```odin
app: web.App   // package global: a signal handler gets only the signal

on_signal :: proc "c" (_: posix.Signal) {
	context = runtime.default_context()
	web.stop(&app)   // async-signal-safe: an atomic flag plus a wake-up
}

main :: proc() {
	app = web.app()
	defer web.destroy(&app)
	// ... routes ...
	posix.signal(.SIGTERM, on_signal)
	posix.signal(.SIGINT, on_signal)
	web.serve(&app, 8080)   // returns after the signal drains it
}
```

**Readiness during drain: `web.is_draining(&app)`.** So a load balancer stops
routing to an instance that is shutting down, a readiness endpoint must answer
not-ready the moment the drain begins:

```odin
web.get(&app, "/ready", proc(ctx: ^web.Context) {
	if web.is_draining(&app) {
		web.text(ctx, web.Status(503), "draining")
		return
	}
	web.text(ctx, .OK, "ready")
})
```

`is_draining` is `false` before `stop`, `true` after, and never returns to
`false`. Keep it distinct from liveness (`/health`, which stays 200 as long as
the process can answer at all): liveness tells the supervisor whether to
restart; readiness tells the proxy whether to route.

**`stop` has a deadline: `Limits.max_drain_time`, ten seconds by default.**
When it expires, connections still serving a request are closed rather than
waited for, and `web.serve` returns.

This shipped in WP59 and it is worth knowing what it replaced, because the
history is the reason to trust it. WP44 attempted the same field, measured a
drain that never terminated, and **withdrew it rather than ship a field that did
not bound anything.** WP58 then measured why, and found something worse than a
missing deadline: with idle keep-alive connections the drain never ended, and
letting those connections complete **crashed the process** on a connection the
shutdown path had already freed. Both failures came from one pending read that
nothing could cancel. Cancelling it fixed both.

**What it does not bound, and this has not changed:**

> **⚠ A blocking handler can outlive the drain deadline.** A synchronous
> Handler cannot be preempted; it holds its Handler lane until it returns.
> `max_drain_time` cannot unwind arbitrary user or C code.

**So the advice is narrower than it was, not absent:**

* set `max_request_time` — it bounds how long a stuck *request* survives;
* **keep the supervisor's kill timeout as your outer bound.** `systemd`'s
  `TimeoutStopSec` should be longer than `max_drain_time` and shorter than your
  orchestrator's grace period. The default of ten seconds is chosen to sit
  inside both;
* set `max_drain_time = 0` to get the old unbounded behaviour back, if you would
  rather wait than cut a request off.

**A blocking handler still outlives the drain if it does not return.** Other
lanes can continue and observe stop, but teardown cannot free state still used
by arbitrary application code. The supervisor remains the outer bound.

The R1 process drill exercises this contract with real signals and sockets:

```sh
bash ops/verification/run-shutdown-drill.sh
```

Its S0–S8 arms cover readiness publication, idle keep-alive, short in-flight
work, slow readers, detached streams, upload spools, a non-returning handler,
repeated signals and two independent Apps. S6 deliberately ends with
supervisor-equivalent `SIGKILL`/137; that result proves the limitation instead
of pretending `max_drain_time` can preempt application code.

---

## 5. Multiple servers per process

**More than one server in a process is supported** (WP123 / ADR-018), up to
sixteen concurrent. Every server-wide accessor names the App whose server it is
asking about — `web.stats(&app)`, `web.refused_connections(&app)`,
`web.stop(&app)`, `web.is_draining(&app)` — so two listeners report and drain
separately.

Each concurrent `web.serve` must use a different App. Reusing one App would
give two transport lifetimes only one place to publish their handle, so the
second call is rejected before bind. A failed bind may be retried with the same
App; an App that has entered drain through `web.stop` cannot restart.

**Still scale horizontally for capacity.** One process per server, many
processes, remains the deployment shape: a faulting handler aborts the process,
so servers sharing one share a fate. Two listeners in one process is for a
service that genuinely has two ports — an application port and an admin or
metrics port — not for packing unrelated services together.

*History, because the old advice is still quoted in places.* Two separate things
made this unsupported. Per-request configuration stopped living in a package
global in WP43, which ended the cross-wired dispatch. What remained until WP123
was a single process-wide slot holding "the" running server: the counters, the
stop and every `stream_send` resolved through it, so the second server to start
silently answered for the first — and every number stayed individually
plausible while it did.

---

## 6. What to monitor

```odin
web.refused_connections(&app)   // running total of admission refusals
web.stats(&app).saturation_refusals // acceptor refusals while every Handler lane is active
web.observe(&app, on_framework_error)
web.use(&app, web.logger)
web.use(&app, web.request_id)
```

* **Lane utilization is your saturation signal — `web.stats(&app).handler_dwell_ns`.**
  A synchronous Handler holds its lane and cannot be preempted, and under
  dedicated accept a request arriving at a busy lane queues silently on that
  lane's socket — no 503, no counter, only latency. The old `lane_collisions`
  counter was retired for exactly that reason: it never observed the lane
  saturation its name promised, and the number it did report came from the
  acceptor's own refusals — a different resource under a misleading label.
  `handler_dwell_ns` is the total nanoseconds lanes spent inside handlers, a
  running total you difference over an interval:

  ```
  utilization = Δhandler_dwell_ns / (lanes × Δwall_nanoseconds)
  mean_dwell  = Δhandler_dwell_ns / Δresponses_sent
  ```

  Utilization approaching 1 means the lane pool is saturated; mean dwell says
  whether to raise `max_handlers` or shorten the handler. Do not read a flat
  latency graph as headroom — queueing on a busy lane is invisible there.
  Capacity is `lanes ÷ mean handler dwell`. C-05 also showed that the first
  visible refusal is scheduler-dependent, so do not infer a fixed resource
  ordering from a single 503 or admission refusal.
* **`web.stats(&app).saturation_refusals` counts the acceptor boundary.** It rises
  when every Handler lane is active and a newly accepted socket is closed
  before an HTTP request is parsed. This is deliberately a transport refusal:
  the acceptor must not manufacture a 503 for a request it has never read.
  Request-aware overload paths may still return 503 with `Retry-After`.
* **`observe`** receives a typed event for every framework-detected failure.
  It cannot change the response; it is for exporting to metrics or alerting.
* **Key every metric on `web.route(ctx)`, never on `ctx.request.path`.** The
  path has unbounded cardinality — one time series per user id — and it puts
  user data in a dashboard.

**What the framework will never log:** the path, the query, any header, any body
byte, any parameter. It records the route pattern, the method, the status, the
request ID, a closed error enum and its own counts. Nothing else
(`planning/phase-4-spec.md` §3).

---

## 7. Behind a proxy: the client address

```odin
web.trust_proxies(&app, {"10.", "127.0.0.1"})
ip := web.client_ip(ctx)
```

**`client_ip` returns the connected peer unless that peer is one you named.**
Only then is `X-Forwarded-For` believed.

**Never read `X-Forwarded-For` yourself.** It is a request header — any client
can send one — and a rate limit, audit log or allow-list built on a forged value
is an authorization bypass. If you configure nothing, you get the peer, which
behind a proxy is the proxy: correct, if not what you wanted, and safe.

---

## 8. Security posture

```odin
web.use(&app, web.secure_headers)   // nosniff, DENY, no-referrer
```

**There is no CSP and no HSTS**, deliberately. A CSP not written for your
application breaks it; HSTS belongs to whatever terminates TLS. Set both **at
your proxy**, where they can be written against your actual deployment.

**There is no cookie API**, so there is nothing to secure with `SameSite` — if
you set cookies, you set the headers, and you own their attributes.

---

## 8b. Response streaming and SSE (Phase 7)

Streaming is **opt-in** and adds no concept to ordinary buffered endpoints. A
Handler that never calls `web.stream` links none of the machinery.

**Lifetime and ownership.** `web.stream(ctx, content_type)` detaches a
long-lived response from the request; the Handler then RETURNS. Everything the
detached stream touches must OUTLIVE the Handler — so **stream-lifetime state
lives in `App_State` or an application-owned allocation, never in the request
arena**, which is destroyed the moment the Handler returns (that destruction is
the whole point of detachment). The `web.Stream` token is a stale-safe value: a
copy held past the stream's life targets nothing and its send/close refuse.

```text
Handler: s, ok := web.stream(ctx, "text/event-stream"); store s in App_State; RETURN
worker : web.stream_send(s, bytes)   // from any thread; copies; never blocks
worker : web.stream_close(s)         // graceful: flushes queued output, then ends
```

**Queue sizing and the slow-client policy.** Each stream has a bounded queue
(64 events / 256 KiB by default) and the process a 16 MiB total. `stream_send`
returns `Full` when the queue is full — it never blocks; the application chooses
to retry, drop or coalesce. A client that never reads is disconnected at
`max_write_time` (a detached stream defaults it to 30 s even when the global
setting is off, because an infinite response must not be unbounded). Refusals
and slow-aborts are counted, not logged per event.

**Graceful close.** `web.stream_close` delivers the events already queued before
it, then the terminating chunk — so an application may send a final message and
close immediately without losing it.

**Behind a proxy.** The framework produces chunked output a non-buffering proxy
forwards frame by frame. A BUFFERING proxy is the failure mode to configure
away, not a framework behaviour: on nginx set `proxy_buffering off;` (or send
`X-Accel-Buffering: no`) for the SSE location, disable response buffering, and
raise `proxy_read_timeout` past your heartbeat interval. `Last-Event-ID` crosses
an ordinary proxy unchanged. Send a heartbeat comment (`: ping`) periodically so
idle-timeout proxies keep the connection open.

**SSE and reconnection.** SSE is a Crystal (`crystals:web/sse`) over this
surface, not a core concept. A reconnecting client replays its cursor in
`Last-Event-ID`; the application decides what to resend from it — the core
carries the header, it does not replay events.

**Large uploads.** The buffered path (`web.body`, `form_file`, up to
`max_body`) is unchanged and canonical. A bounded spool substrate for bodies
larger than memory exists internally (fragmentation-correct multipart, generated
`druse-spool-` files at `0600`, per-upload/process quotas, exactly-once
cleanup) but has **no public upload API yet** — see §10. When it ships, temp
files are deleted on every non-persisted path; the operator's only concern is
crash remnants, which carry the `druse-spool-` prefix.

**After first-byte commit**, framework 4xx/5xx responders cannot append a second
envelope, and the adapter that carries this must be replaceable: every streaming
hook in the vendored backend is a numbered `BRIDGE` patch, deletable when
`core:net/http` lands.

## 9. A deployment checklist

1. Reverse proxy in front, terminating TLS, with its own timeouts and body caps.
2. Supervisor with `Restart=on-failure` and a `TimeoutStopSec` you chose.
3. `web.limits` set explicitly, including `max_connections` below your
   file-descriptor limit.
4. `web.trust_proxies` naming your proxy's network — or nothing at all, never a
   guess.
5. `web.secure_headers` on, CSP and HSTS at the proxy.
6. `web.logger` and `web.request_id` on; `web.observe` exporting to wherever you
   alert from.
7. A cgroup memory limit, because the framework does not bound your handlers.
8. Metrics keyed on `web.route`, never on the path.
9. One process per server; scale by adding processes.
10. Load-test **your** handlers. This framework's dispatch is flat from 5 routes
    to 5,000; your database is not.

---

## 10. Known limitations — the canonical list is the readiness matrix

**`planning/closure-readiness-matrix.md` is the single canonical list of what
this core does and does not bound.** It is a gate, not a document: every
framework-owned resource has a row, every row has a limit, a deadline, a
cancellation, a saturation policy, a metric and a shutdown behaviour, and
`build/check_readiness_matrix.sh` fails when a cell goes missing.

This section used to restate that list, and it is worth recording why it stopped.
It had drifted into being **wrong**: it told operators that large-body upload
had "no public API yet" and that "the framework will not spool to disk" — both
false since Phase 7.5 shipped `web.enable_upload`/`web.upload` — and it declared
streaming "out of core by decision" four bullets after saying that response
streaming and SSE cover server push. A list maintained in parallel with ten
others decays into telling you to build a workaround for a problem that was
solved. One list, gate-checked, or none.

What stays here is the part that is **operational rather than enumerative** —
the topology those limitations make mandatory:

* **Run behind a reverse proxy.** TLS is delegated to it by decision, and the
  proxy's own timeouts are a second, independent bound on a slow client. §7 and
  the C-06 contract.
* **Run under a supervisor with `Restart=on-failure` and a kill timeout.** A
  faulting handler aborts the process by construction — Odin has no recoverable
  panic (ADR-020) — and a handler blocked in foreign code cannot be preempted,
  so the supervisor's kill is the outer bound on shutdown. Keep
  `max_drain_time` (default 10 s) well inside `TimeoutStopSec`.
* **Set `max_response_bytes`, then run under a memory cgroup sized by a
  representative concurrent measurement.** `max_response_bytes` (ADR-045,
  default 0 = off) caps ONE response body: a
  handler that builds a larger body gets a standardized 500 before the bytes are
  copied to the wire, converting an out-of-memory that kills every in-flight
  request into one typed `Response_Too_Large` an observer sees. Set it to the
  largest response any handler legitimately builds. It is the write-side mirror
  of `max_body`, but it does not bound arbitrary temporary allocations the
  handler makes before committing that body.

  C-04 corrected an earlier attribution error. A completed 4 MiB response left
  its connection arena with one 1 MiB reservation, only 4,040 bytes committed
  and zero used; the body-sized blocks were released. The process RSS remained
  above baseline anyway, so RSS high-water must not be described as a live
  per-connection body. During construction, however, that same test used about
  25.2 MiB of arena space for a 4 MiB response, and a slow in-flight send retains
  its completed buffer until send completion.

  There is no universal `max_connections × response size` multiplier. Measure a
  concurrent matrix using your body-size distribution, handler allocation
  behaviour, `max_handlers`, `max_connections` and slow-reader policy. Put the
  cgroup above the measured peak plus explicit headroom, then verify the
  over-budget failure. Two strong levers are:
  - **Enable `max_write_time`.** It bounds how long a slow reader may retain an
    in-flight buffered response.
  - **Use `web.stream` for large output.** Streamed chunks leave through the
    registry's bounded ring, so memory scales with the configured window rather
    than total response length. Matrix rows 5, 8 and 12.
* **Enable `max_write_time` and `max_idle_time`**, sized to your slowest
  legitimate client. They ship OFF because a framework-chosen number would reset
  real clients on upgrade; OFF is not a recommendation. Matrix row 5.
* **Size `max_handlers` above your expected concurrency, and treat utilization as
  the sizing signal.** A synchronous handler holds its lane for its whole
  duration. Under dedicated accept, contention does not answer 503 itself: a
  request contending for a busy lane queues silently on that lane's socket.
  Saturation therefore appears as **rising lane utilization**, which you read
  from `web.stats(&app).handler_dwell_ns`: utilization approaching 1 means the lane
  pool is saturated; when **every** lane is blocked the acceptor closes new
  sockets without writing HTTP and increments `saturation_refusals`. Capacity
  is roughly `lanes ÷ mean handler dwell`.
  `max_handlers` controls service capacity; `max_connections` bounds how many
  clients can be admitted or left waiting. Ten repeated C-05 runs observed
  either lane saturation or admission refusal first, so their ordering is not
  an operational invariant. Matrix row 4.
* **Tune the accept backlog** (`somaxconn`) — it is the kernel's, and the only
  place a connection can queue. Matrix row 11.
* **One server per process**, and install your own `SIGTERM`/`SIGINT` handler
  that calls `web.stop` — the core installs none. §2 and §9.

The vendored HTTP backend remains a snapshot of `laytan/odin-http` with local
patches (`planning/vendor-policy.md`), several fixing upstream defects. This is
scheduled to end: Odin's standard library gains an official `core:net/http` in
January 2027, and ADR-033 points at swapping to it. The streaming, drain and
deadline patches are marked `BRIDGE` and are expected to be deleted rather than
ported.
