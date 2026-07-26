# C-01 — The async-operation inventory

**Status: LIVE (Closure, WP C-01).** Companion to
`planning/production-readiness-closure.md` §2.1. Amend this file whenever an
`nbio` operation is added, moved or removed; `build/check_c01_controls.sh`
fails if the code grows an operation site this table does not name.

---

## 0. Why this exists, in one paragraph

The old pending `recv` outlived its connection (endless drain + use-after-free)
because the `^nbio.Operation` that `recv_poly` returns was **discarded** — an
unreachable operation cannot be cancelled. The write deadline was missing
because nobody asked, of `send_poly`, "is there a maximum deadline?" Neither
gap needed a clever insight to find; both needed one boring question asked of
every operation. This file is that question asked exhaustively, so the class of
gap cannot survive a second time.

**The ten questions**, asked of every operation the framework starts:

1. Who creates it? 2. Where is the handle stored? 3. Who can cancel it?
4. Can the callback fire after cancellation? 5. Can the callback touch freed
memory? 6. Who cleans up on success? 7. Who cleans up on error? 8. Who cleans
up at shutdown? 9. Is there a maximum deadline? 10. Is there a test
interrupting it in each state?

**Two facts about `nbio` that every answer below depends on** (pinned
toolchain, `core/nbio/nbio.odin`):

- `nbio.remove` is **final and silent**: the callback will never be invoked, no
  error is delivered, and the operation is dead afterwards. It must be called
  **from the owning loop's thread** (it panics otherwise), and calling it on an
  operation whose callback has already run is itself a use-after-free.
- `nbio.num_waiting()` counts every outstanding operation in the loop's pool —
  including timeouts and `next_tick`. **Any operation whose handle was dropped
  therefore extends shutdown**, because `_server_thread_shutdown`'s final drain
  loops while `num_waiting() > 0`.

---

## 1. The inventory

**Twenty-seven operation-creating call sites**, in nine kinds, across
`vendor/odin-http/` and `web/internal/transport/`. The count is machine-checked:

<!-- c01-op-sites: 27 -->

`build/check_c01_controls.sh` counts `nbio.*_poly*(` call sites in the tree and
compares them with the number on the marker line above. The number lives in
this ledger, never in the gate script — a gate rewritten by the change it
judges tests nothing (the same correction C-01 made to the vendor-policy
gate). Adding an operation therefore fails the build until this table grows a
row for it, which is the entire mechanism this file exists to provide.

`⚠` = a finding (numbered in §2), `L` = a declared limitation carried into the
C-02 matrix, `T` = unreachable today with a **named trigger** that would make it
a defect.

| # | Operation | Site | Handle | Q1 create | Q2 stored | Q3 cancel | Q4 post-cancel fire | Q5 freed memory | Q6 success | Q7 error | Q8 shutdown | Q9 deadline | Q10 test |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | `accept` (arm) | `_server_thread_init` | `td.accept` | lane init | `td.accept` | `_server_thread_shutdown` | no (`remove` is final) | no (`Server` outlives lanes) | `on_accept` re-arms | see #4/#5 | `nbio.remove(td.accept)` | none (blocks forever by design) | ✅ every socket suite |
| 2 | `accept` (re-arm after success) | `on_accept` | `td.accept` | owner lane | `td.accept` | same | no | no | re-arm | — | same | none | ✅ wp71/wp72 |
| 3 | `accept` (re-arm after handler) | `handler_lane_leave` | `td.accept` | owner lane | `td.accept` | same | no | no | re-arm | — | same | none | ✅ wp71 |
| 4 | `timeout` 1 s → re-arm `accept` | `on_accept` `.Insufficient_Resources` | **dropped** ⚠ | owner lane | nowhere | nobody | n/a | no | fires once | — | **not cancellable** ⚠ **F-C01-1** | 1 s | ✗ → C-01 test |
| 5 | `timeout` 10 ms → re-arm `accept` | `on_accept` transient (Patch 21) | **dropped** L | owner lane | nowhere | nobody | n/a | no | fires once, guarded re-arm | — | fires within 10 ms | 10 ms | ✅ C-01 test |
| 6 | `recv` | `scanner_scan` | `s.pending_recv` | owner lane | `Scanner.pending_recv` | `connection_close` / `connection_abort` | no | no — cleared **first** in `scanner_on_read` | `scanner_on_read` clears | same | cancelled per connection | **sweep** (`request_read_timeout`) | ✅ wp41, wp90 |
| 7 | `send` (buffered response) | `response_send_got_body` | `conn.pending_send` | owner lane | `Connection.pending_send` | `connection_close` / `connection_abort` | no | no — cleared first in `on_response_sent` | `on_response_sent` | `on_response_sent` → `Will_Close` | cancelled per connection | **sweep** (`response_write_timeout`) | ✅ wp90 |
| 8 | `send` (stream heading / chunk / terminator) | adapter `stream_pump_run` ×3 | `conn.pending_send` | owner lane | `Connection.pending_send` | same | no | no — cleared first in all three completions | `on_stream_*_sent` | `stream_teardown_error` → abort | cancelled per connection | **sweep**, override 30 s default | ✅ wp92, wp95 |
| 9 | `timeout` 500 ms → `close` | `connection_close` | **dropped** L | owner lane | nowhere | nobody | n/a | no — `c` is freed only downstream of it, and `.Closing` makes the arming site single-shot | fires once → `close_poly` | — | **not cancellable**; adds ≤500 ms to drain, and leaks `c` if the drain deadline expires first | 500 ms | ✅ wp58, C-01 test |
| 10 | `close` | close-delay timeout, `connection_abort`, **`connection_close` peer-gone fast path (patch 25)** | **dropped** L | owner lane | nowhere | nobody | n/a | no — `connection_teardown` is the single free path, reached once | frees `c` | frees `c` | outstanding at release if the drain deadline expired | none | ✅ wp58, wp90 |
| 11 | `timeout` 250 ms — deadline sweep | `server_date_start`, self-rescheduling | **dropped** L | lane init | nowhere | nobody | n/a | no (`^Server` outlives lanes) | reschedules | — | **self-terminating**: returns without rescheduling once `s.closing` ⚠ **F-C01-2** | 250 ms | ✅ C-01 test |
| 12 | `timeout` 1 s — Date cache | `server_date_start`, self-rescheduling | **dropped** L | lane init | nowhere | nobody | n/a | no | reschedules | — | self-terminating; adds ≤1 s to drain | 1 s | ✅ C-01 test |
| 13 | `next_tick` — stream pump | `stream_pump_arm` (ANY thread) | **dropped** L | any producer thread | nowhere | nobody | n/a | no — `link.terminated` is checked **before** `link.conn`, and the link address is the registry slot address, so a reused slot yields a spurious-but-correct pump | `stream_pump` clears `pump_armed` | — | runs on the next tick; `web.serve` clears the runtime pointer under the same lock | next tick | ✅ wp92, wp95 |
| 14 | `wake_up` | `server_shutdown` | n/a (eventfd write, not an operation) | stop caller | — | — | — | no — CAS elects one owner | — | — | — | — | ✅ wp41 idempotent-stop |
| 15 | `open` | `respond_file` | **dropped** T | — | nowhere | nobody | n/a | **yes, if ever reached** ⚠ **F-C01-6** | `on_open` chains to `stat` | `respond_with_status` | **not cancellable** | none | n/a — unreachable |
| 16 | `stat` | `respond_file` `on_open` | **dropped** T | — | nowhere | nobody | n/a | **yes, if ever reached** | `on_stat` chains to `read` | `nbio.close` + 404 | **not cancellable** | none | n/a — unreachable |
| 17 | `read` (`all=true`) | `respond_file` `on_stat` | **dropped** T | — | nowhere | nobody | n/a | **yes, if ever reached** | `on_read` → `respond` | `nbio.close` + 500 | **not cancellable** | none | n/a — unreachable |
| 18 | dedicated `accept` (arm) | `accept_arm` | `s.accept` | dedicated acceptor | `Server.accept` | `_server_accept_loop`, on the owning accept loop | no (`remove` is final) | no (`Server` outlives acceptor and lanes) | `on_accept_dedicated` clears, assigns once, then re-arms | bounded retry rows 19/20 | acceptor removes before releasing its loop | none (listener operation by design) | ✅ wp69, wp71, c03 |
| 19 | timeout 1 s → re-arm dedicated `accept` | `on_accept_dedicated` `.Insufficient_Resources` | **dropped** L | acceptor | nowhere | nobody | n/a | no (`Server` outlives accept loop) | guarded `accept_arm` | — | accept loop drains it before release | 1 s | ✅ c01/wp71 startup-shutdown corpus |
| 20 | timeout 10 ms → re-arm dedicated `accept` | `on_accept_dedicated` transient | **dropped** L | acceptor | nowhere | nobody | n/a | no (`Server` outlives accept loop) | guarded `accept_arm` | persistent failures remain fatal | accept loop drains it before release | 10 ms | ✅ c03 accept-failure campaign |
| 21 | `next_tick` — accepted connection handoff | `accept_try_assign_pending` | **dropped** L | acceptor | nowhere; payload is the owned `Accepted_Connection` | nobody (next owner tick) | n/a | no — payload is heap-owned; callback checks `server.closing` before touching lane state | owner lane creates `Connection`, then frees payload | closing branch closes socket, returns both counters, frees payload | every lane loop drains next-tick work before release | next tick | ✅ wp69, wp71, c03 disconnect/drain |

**The census caught its first change the moment it was written.** Closure C-03
added the peer-gone fast close (vendored patch 25), which is a third
`nbio.close_poly` call site, and the full gate failed with *"the tree has 23
nbio operation-creating call sites but the inventory declares 22"* — before the
change could be committed. That is the whole mechanism working on the very next
patch, and it is worth recording rather than quietly editing the number: the
gap this file exists to close is the one where an operation is added and nobody
states its owner, cancellation and deadline. Row 10's answers are unchanged;
the new site shares them, and skips the delay rather than the teardown.

Sites 15–17 are the vendored file-serving chain. They are listed because they
**exist**, not because they run: see **F-C01-6**. The two `nbio.close(handle)`
calls beside them are synchronous descriptor closes, not operations.

Site 3's spin (`handler_lane_enter`) is not an operation but is an unbounded
wait and is inventoried as **F-C01-3** below.

---

## 2. Findings

### F-C01-1 — the `.Insufficient_Resources` accept retry re-arms unguarded → a second, unreachable `accept` → shutdown never ends

**CLASSIFICATION: production-blocking absence.** *(fixed in-phase, see §3)*

`on_accept` clears `td.accept` on entry. On `.Insufficient_Resources` it arms a
one-second timeout whose callback does:

```odin
td.accept = nbio.accept_poly(server.tcp_sock, server, on_accept)   // unguarded
```

The Patch-21 transient branch immediately below it guards the identical
re-arm with `if td.accept == nil && !td.handler_active`. This branch does not.

**The failure.** Within that one second the lane can service a request it had
already read: `handler_lane_enter` (sees `td.accept == nil`, skips the detach
dance) → handler → `handler_lane_leave` arms **accept #2** into `td.accept`.
The timeout then fires and overwrites `td.accept` with **accept #3**. Accept #2
is now unreachable. At shutdown `nbio.remove(td.accept)` kills #3 and leaves #2
outstanding; the final drain loops while `num_waiting() > 0`, and with the
default `max_drain_time == 0` that loop **never terminates** — the exact shape
of the WP58/WP59 pending-`recv` hang, on the accept path.

**Reachability is not theoretical.** `.Insufficient_Resources` is
`EMFILE`/`ENFILE`: file-descriptor exhaustion — precisely the state in which an
operator restarts the process, and therefore precisely when a shutdown that
never returns is worst. A secondary effect: two live `accept`s on one lane
break the WP71 one-accept-per-lane invariant that bounded admission assumes.

### F-C01-2 — deadline enforcement stops the instant shutdown starts

**CLASSIFICATION: acceptable operational limitation — conditional on a
mandatory, documented, tested topology.** Carried to the C-02 matrix.

`server_deadline_sweep` returns early on `atomic_load(&s.closing)`, without
rescheduling. It must: a self-rescheduling timer that never stops would keep
`num_waiting() > 0` forever and the drain could not end. The consequence is
that **`response_write_timeout`, `request_read_timeout` and `idle_timeout`
cease to be enforced the moment `web.stop` is observed.** During a drain the
only remaining bound is `max_drain_time`, which force-closes `.Active`
connections past its deadline.

So a slow-reading client during shutdown is bounded by `max_drain_time` **and
by nothing else**. The public core is safe by default here —
`DEFAULT_LIMITS.max_drain_time` is `DRAIN_TIME_LIMIT` (10 s), not the vendored
backend's zero — so an application that never touches `Limits` gets a bounded
drain. The limitation has two exact edges, and both belong in the matrix rather
than in a reader's head:

- `max_drain_time = 0` is a **valid** configuration (`limits_valid` accepts
  zero as "no deadline", deliberately, the same rule as `max_request_time`).
  Choosing it removes the *only* bound that survives into shutdown, because the
  sweep has already stopped. That is a legitimate choice made knowingly, not a
  default anyone falls into — and it is a choice `docs/operations.md` must
  describe in exactly those terms.
- Between `web.stop` and the drain deadline, a connection may exceed
  `max_write_time`, `max_request_time` or `max_idle_time` without being closed
  for it. The deadlines are request-scoped guarantees, not shutdown-scoped ones.

C-02 records both cells; the C-01 suite proves that the drain deadline — not
the sweep — is what actually ends a drain held by a non-reading client.

### F-C01-3 — `handler_lane_enter` spins without a bound

**CLASSIFICATION: ~~acceptable operational limitation~~ → PRODUCTION-BLOCKING
ABSENCE. Reclassified and fixed by C-05 (vendored patch 27) — see F-C05-1.**

> **THIS ENTRY WAS WRONG, AND THE WAY IT WAS WRONG IS THE MOST INSTRUCTIVE
> THING IN THIS FILE.** C-01 classified the unbounded spin as acceptable on the
> strength of an ARGUMENT — that `io_uring` always delivers a completion for a
> cancelled submission, so the loop must terminate. The argument is plausible,
> it is the kind of thing a careful reader accepts, and **the measurement
> refuted it.** C-05's saturation lab wedges here in **four runs out of six**,
> and the wedge is total: `web.stop` did not return in sixty seconds against a
> three-second `max_drain_time`.
>
> The inventory's ten questions found the operation and asked the right
> question of it — question 9, "is there a maximum deadline?", answered "no".
> What failed was the step after: accepting a reason instead of demanding a
> test. Question 10 exists precisely to stop that, and this cell answered it
> "n/a — it is not an operation". **The lesson for anyone amending this file: a
> cell whose safety rests on reasoning rather than on a test is not answered,
> it is deferred.**

The original entry, kept as written so the correction is legible:

```odin
for target.accept.client == 0 && target.accept.err == nil {
    _ = nbio.tick(time.Millisecond)
}
```

The loop waits for the cancelled `accept`'s completion to be observed, because
`nbio.remove` is asynchronous and starting a blocking handler before that
completion can let a connected client vanish without a callback. It has **no
iteration cap and no deadline**. ~~It terminates because `io_uring` always
delivers a CQE for a cancelled submission (either the accept won, or
`-ECANCELED`), and it ticks the loop itself so it cannot deadlock against its
own completion.~~ It is nonetheless a framework-owned wait with no declared
maximum, so it is named here and in the matrix rather than left implicit.

**What the reasoning missed:** the spin runs on the LANE THREAD. A lane parked
in it never returns to its event loop, never observes `s.closing`, and never
calls `_server_thread_shutdown` — and `serve` waits on `threads_closed` for
every lane. So one lane in here is a process that cannot be stopped, *past*
`max_drain_time`, which bounds the drain and cannot bound a lane that never
reaches the drain. Patch 27 caps the wait at 250 ms and abandons it on expiry
without reattaching the operation record (reattaching a record whose completion
may still arrive would trade a wedge for a use-after-free).

### F-C01-4 — a drain that expires with operations outstanding leaks connections

**CLASSIFICATION: acceptable operational limitation.** Carried to C-02.

When `max_drain_time` expires with `num_waiting() > 0`,
`_server_thread_shutdown` logs, breaks, and calls
`nbio.release_thread_event_loop()`. Any outstanding close-delay timeout (#9) or
`close` (#10) never fires, so `connection_teardown` never runs for those
connections: the `virtual.Arena`, the scanner buffer and the `Connection` are
not freed, and `td.conns` is deleted wholesale. This is **deliberate and
correct** — the alternative is a shutdown deadline that is not a deadline — and
it is safe because the only caller is a process that is ending. It is a
limitation because it is *not* safe for a hypothetical repeated
listen/serve/stop cycle in one process, which `web.serve`'s one-server-per-
process rule already forbids.

### F-C01-5 — `link.loop` / `link.conn` are read by producer threads without synchronisation

**CLASSIFICATION: acceptable operational limitation (declared).** Carried to C-02.

`stream_pump_arm` runs on any producer thread and reads `link.loop` to schedule
the pump. `stream_open` writes `link^` on the owner lane. The registry captures
the wake under the slot mutex but invokes it *outside* the lock, so a retire +
reuse can interleave. It is safe by address aliasing — `link` is
`&runtime.links[slot]`, so a reused slot's pump reads the *new* link's own
`loop` and `conn`, which are consistent with each other — and the pump is
idempotent over its `(registry, token)` pair. The residual is a
pointer-sized unsynchronised read, benign on the gate-validated platform and
recorded rather than hidden.

### F-C01-6 — the vendored file-serving chain is three uncancellable operations away from a use-after-free, and is safe only because nothing calls it

**CLASSIFICATION: future work with a NAMED TRIGGER** — it becomes a defect the
moment `respond_file` is reachable. Gate-enforced.

`vendor/odin-http/responses.odin` carries `respond_file`, an `open` → `stat` →
`read` chain in which **all three handles are discarded** and every callback
dereferences `^Response` — which lives inside `^Connection`. Nothing in
`connection_close` or `connection_abort` cancels them, because they cancel
exactly two named handles, `pending_recv` and `pending_send`. So a client that
disconnects while a file is being read would have its connection torn down, its
arena destroyed and its `Connection` freed, and the `read` completion would then
write `op.read.read` bytes into a freed response buffer. That is the WP58
use-after-free, a third time, on a third path.

**It cannot happen today.** `web.static` — Uruquim's only file-serving surface —
does not use it: `web/static.odin` reads with the synchronous
`os.read_entire_file_from_path` and stats with `os.lstat`. `respond_file` is
reachable from no Uruquim code path.

**Why it is recorded rather than deleted.** The honest options are to delete the
dead chain or to declare it, and declaring it is worth more: the trigger is what
matters, and a future patch that wires `respond_file` in — to stop reading whole
files on the handler lane, say, which is a genuine improvement C-04 will
weigh — must first give those three operations stored, cancellable handles.
`build/check_c01_controls.sh` fails if `web/` ever references `respond_file`,
so the trigger cannot be pulled silently.

**The adjacent cell, for C-02:** because `web.static` reads synchronously,
serving a file **blocks the handler lane for the duration of the read**, and the
file is buffered whole (`max_file_size`, ADR-014). That is a resource with a
limit and no deadline; it is a matrix row, not a finding here.

---

## 3. What C-01 changes in the code

One fix, minimal, matching the shape of the guard that already exists eight
lines below it:

```odin
nbio.timeout_poly(time.Second, server, proc(_: ^nbio.Operation, server: ^Server) {
    if td.accept == nil && !td.handler_active {
        td.accept = nbio.accept_poly(server.tcp_sock, server, on_accept)
    }
})
```

Everything else C-01 found is a **declared** limitation: it moves into the C-02
matrix as a filled cell with a named owner, not as a silent gap.

---

## 3b. What C-01 measured

`tests/c01-async-ops`, on the development box, first run:

| Phase | State interrupted | Result | Elapsed |
|---|---|---|---|
| P1 | none — clean stop | returned | **991 ms** |
| P2 | `recv` holding a partial request line | returned | **871 ms** |
| P3 | `send` in flight, `max_write_time` = 5 s, `max_drain_time` = 1 s | returned | **1.544 s** |
| P4 | connection already aborted by a 300 ms write deadline | returned | **791 ms** |

Three of these numbers say something the inventory could only assert:

- **P1 = 991 ms names a floor nobody had named.** WP58 measured 990 ms for the
  same phase and read it as the cost of stopping. It is not: it is the tail of
  the **Date-cache timeout** (operation #12), a one-second self-rescheduling
  timer whose handle is dropped, so the final drain must wait for it to fire
  before `num_waiting()` can reach zero. A clean stop cannot be faster than
  that, and now the reason is written down instead of rediscovered.
- **P3 = 1.544 s is F-C01-2, executable.** 1 s of drain deadline plus the 500 ms
  `Conn_Close_Delay` (operation #9). The write deadline was configured at five
  seconds and played no part — because the sweep had already stopped enforcing
  when `closing` was set. Had the sweep still run, this phase would have ended
  at ~5 s and the suite would have failed at its 3 s bound. The measurement is
  what turns "the deadlines stop at shutdown" from a claim into a fact.
- **P4 = 791 ms proves the abort path leaves nothing behind.** Below the drain
  deadline, so the aborted connection was fully torn down before the stop — a
  surviving handle would have pushed this to P3's shape.

## 3c. What C-01 hands to C-03

Two things it found and deliberately did not chase, recorded here so the
campaign inherits them rather than rediscovers them:

**(a) One segmentation fault in roughly ten runs of this suite.** The first
invocation of `build/check_c01_controls.sh` died 2.5 ms in — before any phase
printed — with a leak report showing only route registration and
`thread_unix.odin:_create`, i.e. inside the first `start_server`. Ten
subsequent runs (six consecutive, plus four interleaved) were green with
timings identical to the millisecond. This matches the flake class the roadmap
handoff already records for wp41/wp58/wp67/wp8 — "real-socket suites segfault
under shared-machine load; they pass in isolation" — and the standing advice is
to re-run rather than chase. **C-03 should stop taking that advice.** A suite
that crashes one run in ten during startup is a finding with a
reproduction rate, not weather, and the closed campaign is precisely the
instrument for it: the `Lifecycle` axis already lists "shutdown between callback
and cleanup".

**(b) Stop after a FAILED listen is safe — verified, not assumed.** The obvious
hypothesis for (a) was the port-fallback path in the harness: a `serve` whose
bind loses to a squatter, followed by `web.stop`. A direct probe (a foreign
`net.listen_tcp` holding the port, then `serve` + `stop`) returned cleanly in
300 ms. So that path is *not* the crash, and (a) stays open. `wp41-fault`'s
`phase_conflicted_never_binds` covers a poisoned App, not an occupied port;
C-03 should keep the occupied-port case as a permanent cell now that it is
known green.

## 4. The exit claim C-01 supports

> Every `nbio` operation the framework starts has a named creator, a stated
> handle location (including "deliberately dropped, and here is why that is
> safe"), a named canceller or a reason it needs none, a stated maximum
> deadline or a reason it has none, and a test that interrupts it.

`build/check_c01_controls.sh` enforces the *structural* half of that claim: the
set of `nbio` operation sites in the tree must equal the set this table names.
`tests/c01-async-ops/` enforces the behavioural half.
