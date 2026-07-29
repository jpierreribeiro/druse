# C-02 — The resource × property matrix

**Status: LIVE GATE (Closure, WP C-02).** This file is the **single canonical
list of what the Uruquim core does and does not bound.** Every other document
points here rather than restating it; `build/check_readiness_matrix.sh` fails
when a row loses a cell, when a `web.Limits` field has no row, or when the
documents that used to keep their own lists start keeping them again.

---

## 0. Why one table instead of eleven lists

The Closure exists because a *recorded* pendency — the write deadline — stopped
being trackable until it resurfaced by accident. The mechanism was not
forgetfulness. It was that the answer to "what does this framework not bound?"
was maintained in eleven places (`docs/operations.md` §10,
`docs/quick-start.md`, `docs/canonical-patterns.md`, seven phase freezes, the
evidence backlog) and each was true about its own scope, so no reader and no
gate could see the union.

**Proof that this is the real failure mode, found while building this table:**
those lists had already drifted into being *wrong*, not merely incomplete.
Before this WP, `docs/operations.md` §10 stated —

- *"Large-body upload has a substrate but no public API yet"* — false since
  Phase 7.5-C2 shipped `web.enable_upload` / `web.upload` / `web.upload_persist`;
- *"Uploads are bounded by `max_body` and held in memory … The framework will
  not spool to disk"* — false for the same reason, and it is the exact opposite
  of what the core now does;
- *"No WebSocket or streaming. Out of core by decision"* — false since Phase 7
  shipped `web.stream`, and **self-contradictory**: four bullets earlier the
  same section says "Response streaming and SSE cover server push."

`docs/quick-start.md` carried two of the same three. A list that says a shipped
feature does not exist is worse than no list: it is a document actively telling
an operator to build a workaround for a problem that was solved. That is what an
enumeration maintained in parallel decays into, and it is why this table is a
gate rather than a document.

**The rule from here:** the *enumeration* lives here. Prose explaining a
*specific* behaviour stays where it is. Phase freezes keep their own
non-deliveries, because a freeze's job is to record what *that phase* did not
deliver — history, not current state.

---

## 1. The matrix

Every framework-owned resource, one row. An empty cell is a visible gap; there
are none — a cell reading "none" is an **answer**, and where the answer is
"none" the classification column says who owns the consequence.

Classification vocabulary (§3 of `production-readiness-closure.md`):
**OK** · **LIMITATION** (acceptable, delegated, with a mandatory topology) ·
**OPEN** (a Closure WP owns it) · **FUTURE** (evidence-gated).

<!-- c02-rows: 14 -->

| # | Resource | Limit | Deadline | Cancellation | Saturation policy | Metric | Shutdown | Class |
|---|---|---|---|---|---|---|---|---|
| 1 | Connection (accepted socket) | `max_connections`, default **1024** | none as a connection; `max_idle_time` bounds the gap between requests, **default OFF** | `connection_close` (shutdown(Send) + 500 ms + close; **immediate when the peer has already gone and no send was in flight** — patch 25) or `connection_abort` (SO_LINGER 0 → RST) | refuse: the accepted socket is closed at once above `max_connections - reserved_conns` (default 1008); never queued. **The slot is released at teardown, so the close path's duration is part of the admission budget** — C-03 §2 | `web.refused_connections()` — **the only public counter in the core** | drained: `.New`/`.Idle`/`.Pending` closed immediately, `.Active` **and `.Will_Close`** force-closed once `max_drain_time` expires (patch 26 / F-C03-1 — `.Will_Close` was omitted, and the drain then never ended) | OK |
| 2 | Listening socket / `accept` | one outstanding accept per lane (WP71); the backlog itself is the kernel's | none — it blocks until a client arrives, by design | `nbio.remove(td.accept)` at shutdown | kernel backlog; `.Insufficient_Resources` re-arms after 1 s (guarded, vendored patch 24 / F-C01-1) | none exposed; consecutive failures are counted per lane and **128 in a row is fatal** rather than a silent outage | cancelled at shutdown | OK |
| 3 | Request read (request line, headers, buffered body) | `max_request_line` **8000**, `max_headers` **8000**, `max_body` **4 MiB** | `max_request_time` **30 s, ON by default** | `nbio.remove(scanner.pending_recv)` | close the connection | none exposed; the resulting status reaches the typed `Framework_Event` observer | cancelled per connection; **the deadline itself stops being enforced once `closing` is set — F-C01-2** | OK |
| 4 | Handler execution (one lane) | `max_handlers`, default 0 = automatic (adapter resolves to [4, 32] by core count; explicit values bounded at 256) | **none — the application's own** | **not preemptible.** Odin has no recoverable panic and no preemption; a handler runs to return | lane contention answers **503 + `Retry-After: 1`** (F-002 fix + H-4); admission for that lane is suspended while it runs. **NO queue and NO work-stealing between lanes** — a 503 is refusal on collision, not on the pool being full, and can arrive with lanes idle. Queueing is deliberately REFUSED: the F-002 use-after-free was exactly a deferred dispatch (`next_tick`), unsound because everything the dispatch names (`req`/`res`, inbound views, the `Exchange`) lives in the connection arena that teardown frees; a queue is safe only after changing that ownership, which is future work. **Measured (C-05): this is the FIRST resource to bind — capacity is `lanes ÷ dwell`; `max_connections` only decides how many clients get to wait** | **`web.stats().lane_collisions`** — the 503-on-busy-lane count (item 2), the sizing signal for the first bound to saturate; previously unexposed | a running handler is not interrupted; `max_drain_time` bounds the *transport*, not the handler. **The supervisor's kill is the outer bound** | LIMITATION — mandatory topology: a supervisor with a kill timeout |
| 5 | Response write (buffered) | `max_response_bytes`, **default 0 = off** (ADR-045); a strictly larger built body is replaced with a 500 before copy-out | `max_write_time`, **default OFF** | `nbio.remove(conn.pending_send)` | the connection and its buffer are retained for as long as the client chooses; RST at the deadline when one is set | **`web.stats()`** — `responses_sent`, `response_bytes`, `send_errors`, `write_deadline_aborts` (Closure H-3) | cancelled at close; **deadline not enforced during drain — F-C01-2** | OK — per-response bound SHIPPED (ADR-045); aggregate still delegated to cgroup (C-04); metric SHIPPED (H-3) |
| 6 | Detached response stream | per-stream event and byte caps + a process-wide byte budget (`web/internal/stream` registry) | `max_write_time` per send, or the pre-registered **30 s** default when unset — a stream is bounded whether tuned or not | `stream.close` + `retire`; an externally-initiated end reaches it through the connection teardown hook | `Full` refusal — the bounded queue refuses, never waits and never drops silently | `refused_stream_full`, `refused_budget_full`, `aborted_slow` — **now reachable through `web.stats()` (Closure H-3)** | `drain_begin` wakes every owner, the terminator follows the last queued event, bounded by `max_drain_time` (WP95) | OK — metric shipped (H-3) |
| 7 | Spool ingest (opt-in large-body upload) | per-upload quota + the configured spool directory; opt-in, default off | the request deadline (`max_request_time`) | `upload_cancel` at driver teardown — exactly once, idempotent | admission refuse; refuses new spools once draining (WP95) | none exposed | admission stops at drain; a spooled file is deleted at teardown unless `upload_persist` moved it | LIMITATION — no metric; the substrate is opt-in |
| 8 | Per-connection arena (`virtual.Arena`, growing) | **none directly** — it grows to the largest request or response the connection has held, so it is bounded by `max_body` on the read side and by nothing on the write side | n/a | n/a — freed wholesale at teardown | process memory. **Measured (C-04): a connection retains ~1.0× the largest response it ever served, persisting at ~0.75× while it serves small ones. Worst case `max_connections × largest response` — 1024× at the defaults** | **none exposed**; retention is measured by `tests/c04-response-size`, not reported by the framework | destroyed in `connection_teardown`; **leaked if the drain deadline expires with the close still outstanding — F-C01-4** | LIMITATION — **delegated to a cgroup, with a measured sizing rule** (C-04); no per-request leak (F-C04-2) |
| 9 | Static file read | `Static_Options.max_file_size`, default **8 MiB**; a larger file is answered 404 | **none** | **none — the read is synchronous** (`os.read_entire_file_from_path`) | it **blocks its handler lane** for the duration of the read, and the file is buffered whole (ADR-014) | none | not interruptible: it is inside the handler, so row 4's answer applies | LIMITATION — sized by `max_file_size`; **FUTURE:** an async read needs the F-C01-6 handles first |
| 10 | Periodic lane timers (Date cache 1 s, deadline sweep 250 ms) | two per lane, fixed | their own period | **none — the handles are dropped**; they self-terminate by not rescheduling once `closing` is set | n/a | none | the final drain waits up to one period for the outstanding timeout — **measured at 991 ms** (C-01 P1) | LIMITATION — bounded by the period, declared in the C-01 inventory |
| 11 | Accept backlog | the kernel's (`listen` backlog, `somaxconn`) | kernel | kernel | SYN drop | external (`ss -lnt` Recv-Q) | the listening socket is closed by `serve` after every lane returns | LIMITATION — **delegated to the kernel**, mandatory topology: tune `somaxconn` |
| 12 | Total process memory | **none** — the core sets no aggregate cap | n/a | n/a | the OOM killer | external | n/a | LIMITATION — **delegated to a cgroup / supervisor**, mandatory and tested by C-06 |
| 13 | TLS termination | n/a | n/a | n/a | n/a | external | n/a | LIMITATION — **delegated to the reverse proxy** by decision; the topology is now **TESTED** (C-06): `proxy_buffering off` proven mandatory (a buffering proxy withholds a stream entirely — nothing in 1.23 s against 150 ms direct) and the forwarded client address proven believed only from a trusted hop |
| 14 | JSON body decode (preflight tree + typed destination) | `max_json_nodes`, default **100,000** JSON values plus object keys | none of its own — `max_request_time` has already stopped, since the body has arrived; the decode runs inside the Handler's lane time | **not cancellable.** The decode is synchronous inside the handler call, so the only bound is the one applied BEFORE it starts — which is why the count is taken in the pre-scan and not from the parser | refused **413** with code `body_too_complex` before the parser allocates, so a refused body costs one pass over its bytes and no tree. Deliberately NOT `body_too_large` (a client retrying by shrinking bytes has misread it) and not `invalid_json` (the body is well-formed). **Measured (J3/J4): this is the resource `max_body` could not see** — two bodies inside the 4 MiB cap cost **588 MB RSS** and **1.6-2.1 s of one lane**; at the default they cost **20 MB** and **50 ms** | none of its own. The cost is visible through `handler_dwell_ns` (lane time) and through the process RSS an operator already watches; a per-decode counter was NOT added because the bound is enforced before the cost is paid, so the interesting number is the refusal, not the decode | nothing outstanding — the decode holds no transport resource and completes or is refused within the handler call that owns it | OK — bounded by default. **The aggregate remains delegated**: 100,000 nodes is ~15 MB of preflight tree, so `max_handlers` lanes decoding maximal bodies is still `max_handlers x ~15 MB`, sized by a cgroup exactly as C-04 records for `max_response_bytes` |

---

## 2. The amber cells, restated as the current limitation list

This is the list every other document points at. Seven entries; each says who
owns it.

1. **A response now has a size limit — `max_response_bytes` (ADR-045), default
   0 = off.** A strictly larger built body is replaced with the standardized 500
   (`Framework_Error.Response_Too_Large`) on the shared path before copy-out, so
   an out-of-memory that would kill every in-flight request becomes one typed
   failure. **Measured (C-04): a connection retains ~1.0× the largest response
   it ever served, and still holds ~0.75× of it after 1,600 subsequent small
   responses — the footprint is per-connection and outlives the request**, so a
   per-response bound is what caps the retention. The AGGREGATE across
   `max_connections` — worst case `max_connections × largest response`, 1024× at
   the defaults — remains *DELEGATED to a memory cgroup*, with the sizing rule in
   `planning/closure-response-size-and-memory.md`. Two guards, two scopes: the
   limit bounds one response, the cgroup bounds the process.
2. **The write and idle deadlines default OFF.** `max_write_time` and
   `max_idle_time` exist and work; they ship disabled because a
   framework-chosen number would reset real slow clients on upgrade. *Enable
   both in production.* Owner: the operator, and `docs/operations.md` says so.
3. **Deadlines are request-scoped, not shutdown-scoped.** Between `web.stop`
   and the drain deadline, the sweep no longer runs; `max_drain_time`
   (default 10 s) is the only bound that survives. Setting it to 0 is valid
   and removes that bound too. *Owner: declared — F-C01-2.* **C-03 found that
   this bound was not merely the only one but, for a `Connection: close`
   client, not a bound at all** — the drain loop ignored `.Will_Close`, so
   `web.stop` never returned. Fixed (patch 26 / F-C03-1) and now gated; the
   entry stands as written because the *scope* limitation is real even with the
   bound restored.
4. **Write-side observability — SHIPPED (Closure H-3).** `web.stats()` returns
   a `Server_Stats` of eight running totals: `responses_sent`, `response_bytes`,
   `send_errors`, `write_deadline_aborts`, and the three stream counters that
   were maintained in the registry and reachable from no public API. An operator
   can now see slow-consumer aborts. The twelve-file ledger amendment that
   deferred it was done under H-3.
5. **Arena retention after large responses** is now measured (entry 1), and
   there is **no per-request leak** — 1,600 small responses on already-grown
   arenas cost negative RSS in all three runs. What remains owed is the
   *hours-long* soak, which only a quiet machine can give; it is recorded
   alongside the 3,000 real-socket SSE round, the project's other undemonstrated
   scale claim. *Owner: C-04, deferred with a named obligation.*
6. **A blocking handler is not preemptible and a faulting one aborts the
   process.** Both are by construction (Odin has no recoverable panic). The
   supervisor is the outer bound. *Owner: the mandatory topology — C-06.*
7. **A static file is read synchronously and buffered whole**, blocking its
   lane. *Owner: `max_file_size`; an async read is FUTURE and blocked on
   F-C01-6.*

Delegated by decision, with a mandatory topology C-06 must prove: **TLS**
(reverse proxy), **total memory** (cgroup), **accept backlog** (kernel),
**restart** (supervisor).

---

## 3. What the gate checks

`build/check_readiness_matrix.sh`:

1. the matrix has all eight columns and the declared number of rows, and **no
   cell is empty** — an unanswered cell is the thing this WP exists to make
   impossible;
2. **every field of `web.Limits` appears in the matrix.** A new limit with no
   row fails the build, which is the structural half of "no framework-owned
   operation without a declared capacity";
3. every public observability procedure appears, so a counter cannot be added
   or removed without the metric column noticing;
4. **the documents that used to keep their own lists point here instead** —
   `docs/operations.md` §10 and `docs/quick-start.md` "Current limitations";
5. **the three drifted claims cannot come back**: no document may again say
   that large-body upload has no public API, that the framework will not spool
   to disk, or that streaming is out of core.

Check 5 is unusual and deliberate. A pointer is only worth something if the
thing it replaced cannot quietly regrow, and these three sentences are the
measured evidence that it does.
