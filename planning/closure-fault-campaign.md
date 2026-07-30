# C-03 — The closed fault-injection campaign

**Status: LIVE (Closure, WP C-03).** Companion to
`planning/production-readiness-closure.md` §2.3. This is the **grid**: a fixed
scenario space, enumerated once, with every cell either pointing at the suite
that already proves it or naming the suite C-03 wrote to fill it.

---

## 0. What "closed" means, and why it is the point

Druse has found faults one at a time, and each time the finding was real: the
orphaned `recv` (WP58), the negative chunk size (patch 14), the multi-lane
shutdown crash (WP70), the use-after-free through a deferred dispatch (F-002),
the write deadline. Every one was discovered by *encountering* it.

A campaign is the opposite method. The axes below are not a list of bugs
anyone suspects; they are the **complete space of things that can go wrong at
each boundary** — what a client may send, what an application may do, what a
client may do with the response, and what a shutdown may land on top of. Filling
the grid does not prove there are no defects. It proves something weaker and far
more useful: **the space has been enumerated, so a future finding is a new cell,
not a new category.**

The campaign's other job is to stop the same measurement being written twice.
Where a green suite already drives a cell, C-03 **cites** it by test name rather
than re-measuring it: a second copy of a test is a second thing to keep true.

---

## 1. The grid

`✅` covered by an existing suite (named) · `🆕` filled by C-03 ·
`📕` declared: not testable in-process, and the reason is the answer ·
`🌐` external: belongs to the mandatory topology (C-06)

### A. Input — what a client can send

| # | Scenario | Proven by |
|---|---|---|
| A1 | Connect and send nothing, hold the socket | ✅ `wp41-fault` `phase_deadline_ends_a_held_connection` |
| A2 | One byte per second (slowloris) | ✅ `wp41-fault` `phase_deadline_bounds_a_trickling_client`, fault `Slow_Writer` |
| A3 | Truncated request line, socket held open | ✅ `wp41-fault` fault `Truncate_And_Hold`; `c01-async-ops` P2 |
| A4 | Truncated header block | ✅ `wp41-fault` `Truncate_And_Hold` at header offsets |
| A5 | Truncated fixed-length body | ✅ `wp9-wire` "truncated fixed body is rejected" |
| A6 | Truncated / malformed chunked body | ✅ `wp9-wire`; vendored patch 14 (negative chunk size was a remote process kill) |
| A7 | Ambiguous framing (CL+TE, duplicate CL) | ✅ `wp9-wire`; vendored patches WP9 D2 |
| A8 | Request fragmented at hostile offsets (mid-header, between CR and LF) | ✅ `wp41-fault` fault `Fragmented_Request` |
| A9 | Close with the request half-sent | ✅ `wp41-fault` fault `Close_Mid_Request` |
| A10 | **Sustained RST flood** | 🆕 `c03-fault-campaign` `c03_a_healthy_client_survives_an_rst_flood` — the inherited F-002 follow-up |

### B. Execution — what the application can do

| # | Scenario | Proven by |
|---|---|---|
| B1 | Handler blocks | ✅ `wp71`/`wp72-concurrent-serving`; `tests/support/blocking_lab` |
| B2 | Handler returns without responding | ✅ standardized 500 — `wp6-public-surface`, `docs/errors.md` |
| B3 | Handler responds, then faults | 📕 the process aborts, by construction. Odin has no recoverable panic (ADR-020) and Druse declines to fake one; a test that proved it would abort the runner. The supervisor is the answer, and C-06 tests that topology. |
| B4 | Every Handler lane busy when a request arrives | 🆕 `c03-fault-campaign` `c03_a_contended_lane_refuses_with_503_and_stays_alive` — the F-002 fix, under test rather than under an ad-hoc validation |
| B5 | Slow dependency inside the handler | ✅ `tests/support/web_blocking_lab` |
| B6 | Client disconnects while the handler runs | 🆕 `c03-fault-campaign` `c03_a_disconnect_during_the_handler_does_not_outlive_the_request` |

### C. Output — what the client does with the response

| # | Scenario | Proven by |
|---|---|---|
| C1 | Client never reads | ✅ `wp90-deadlines` `wp90_a_stalled_write_is_aborted_at_the_deadline` |
| C2 | Client reads slowly | ✅ `wp91-stream-security` `wp91_a_slow_consumer_receives_every_byte_exactly_once`; `wp92-backpressure` |
| C3 | Client reads part, then stops | ✅ `wp41-fault` fault `Slow_Reader`; `c01-async-ops` P3 |
| C4 | Response larger than the socket buffer pair | ✅ `wp90-deadlines` (8 MiB); `c01-async-ops` P3 |
| C5 | Error during `send` (peer gone mid-write) | 🆕 `c03-fault-campaign` `c03_a_send_error_retires_the_connection_without_a_second_write` |
| C6 | Keep-alive after a healthy response | ✅ `wp41-fault` `phase_keep_alive_serves_two_requests_on_one_connection` |
| C7 | Close before the response arrives | ✅ `wp41-fault` fault `Close_Before_Response` |

### D. Lifecycle — shutdown against every state

| # | Scenario | Proven by |
|---|---|---|
| D1 | Stop with no connections (the floor) | ✅ `wp58-drain` baseline; `c01-async-ops` P1 (**991 ms**, and C-01 named the mechanism) |
| D2 | Stop with idle keep-alive connections | ✅ `wp58-drain` idle phase (8 conns, 987 ms) |
| D3 | Stop with a `recv` holding a partial token | ✅ `c01-async-ops` P2 |
| D4 | Stop with a connection held `.Active` | ✅ `wp58-drain` `phase_obligation_3_stop_returns_with_a_connection_held_active` |
| D5 | Stop with a `send` in flight to a dead reader | ✅ `c01-async-ops` P3 (**1.544 s** = drain deadline + close delay; the write deadline played no part — F-C01-2) |
| D6 | Stop with detached streams open | ✅ `wp95-drain` `wp95_open_streams_terminate_within_the_drain_deadline` |
| D7 | Stop after a write-deadline abort | ✅ `c01-async-ops` P4 |
| D8 | A deadline and the shutdown expiring together | 🆕 `c03-fault-campaign` `c03_a_deadline_expiring_with_the_drain_does_not_double_close` |
| D9 | A second `stop` | ✅ `wp41-fault` `phase_stop_is_idempotent_and_stops_admission` |
| D10 | Stop after a FAILED listen (port occupied) | 🆕 `c03-fault-campaign` `c03_a_stop_after_a_failed_bind_returns` — probed during C-01, made permanent here |
| D11 | Supervisor kill after the drain deadline | 🌐 external — the mandatory topology, C-06 |

**Cells: 34. Covered by existing suites: 25. Filled by C-03: 6. Declared: 1.
External: 1. Unanswered: 0.**

---

## 2. The RST-flood wedge — the inherited finding

`docs/reports/2026-07-23-security-f001-f002.md` closed F-002 and recorded, as
out of scope, that *"under a SUSTAINED RST flood the server stops accepting (all
threads alive, listen backlog fills, no crash)."* The Closure owns it, and
owning it starts with measuring it rather than reasoning about it.

**Two candidate mechanisms, from the C-01 inventory, wanting opposite fixes:**

- **(a) The admission slot outlives the peer by 500 ms.** `connection_close`
  shuts down the send side, arms `Conn_Close_Delay` (500 ms, RFC 7230 6.6
  politeness so a client can finish reading a response), then closes; and
  `active_connections` is decremented in `connection_teardown`, at the *end* of
  that chain. A connection whose peer has already sent RST — where there is
  nobody left to be polite to — still holds one of
  `max_connections - reserved_conns` slots for half a second. A flood only needs
  to open connections faster than `budget / 500 ms` to make every subsequent
  client meet the admission refusal. The server is then alive, accepting, and
  refusing everyone.
- **(b) The accept re-arm is delayed 10 ms per transient failure.** An RST that
  lands before `accept` returns gives `ECONNABORTED`. Patch 21 tolerates it by
  re-arming after `DRUSE_ACCEPT_RETRY_DELAY` (10 ms), so each lane spends
  10 ms not accepting per failure — roughly 100 accepts/s/lane — and the listen
  backlog fills behind it.

They are **distinguishable by what a healthy client sees**, which is why the
probe in `tests/c03-fault-campaign/rst_flood_test.odin` records the failure
*kind*: (a) predicts connect-succeeds-then-closed-with-no-reply; (b) predicts
connect itself failing while the backlog is full.

### The measurement — and the verdict

<!-- c03-rst-verdict:start -->
Four flood threads against a 64-slot server (60 admissible), a healthy client
probing every 50 ms throughout, on the development box:

| Tree | before flood | **during flood** | after flood | flood rate |
|---|---|---|---|---|
| pristine `origin/main` (dbbd522) | 10/10 | **1 / 59** — `connect_fail=0`, `refused=32`, `read_fail=26` | 20/20 | ~37,800 conn/s |
| with vendored patch 25 | 10/10 | **56 / 56** | 20/20 | ~1,350 conn/s |

**The mechanism is (a), and (b) is ruled out by the data.** `connect_fail = 0`
across the whole flood: the listener never stopped accepting, and the backlog
never filled. What a healthy client met was the **admission refusal** —
connect succeeded, then the server closed with nothing written.

So the F-002 report's wording was close but not exact, and the difference is
the fix. The server does not "stop accepting"; it **stops admitting**, because
`active_connections` is decremented in `connection_teardown` at the *end* of the
close chain, and `Conn_Close_Delay` sits in the middle of that chain. Every
RST'd connection therefore holds one of `max_connections - reserved_connections`
slots for 500 ms. The budget is exhausted at `budget / 500 ms` — 120 conn/s
against 60 slots — and the measured flood ran three hundred times faster than
that.

**The fix** (vendored patch 25) skips the linger for a connection whose peer has
already gone, and only when no response send was in flight. The delay is RFC
7230 6.6 courtesy to a client still draining a response, and a peer that sent
RST or FIN is not one. It was never what flushed the response either: a plain
`close` returns at once and the kernel keeps sending what is buffered — which is
why this is a scheduling change, not a wire change, and why it is deliberately
not the `connection_abort` path, whose SO_LINGER {1,0} exists to *discard* the
tail.

**Read the flood rate honestly.** It fell from ~37,800/s to ~1,350/s *because of
the fix*, not despite it: refusing a connection is nearly free, so the unpatched
server could churn the flood fast while serving nobody. The patched server does
the real work of accepting, reading, and tearing down each connection, which
throttles the flood — and serves every healthy client while doing it. Degrading
in throughput rather than refusing everyone is the intended shape.

Stability: 100% probe success across four runs, including one at twelve flood
threads (which produced a *lower* rate, ~1,170/s — contention, not headroom
loss). The suite is RED on pristine `origin/main` and green here, which is the
evidence that it tests something.
<!-- c03-rst-verdict:end -->

---

## 2b. F-C03-1 — `max_drain_time` bounded nothing for a `Connection: close` client

**CLASSIFICATION: production-blocking absence.** *Fixed in-phase (vendored patch
26). Pre-existing: reproduces identically on `origin/main` (dbbd522).*

Cell D8 was written to check that two teardown paths racing for one connection —
the sweep's abort and the drain's close — do not double-free. It found something
else, which is the ordinary way a grid earns its cost.

**The defect.** `_server_thread_shutdown`'s drain loop switches on
`conn.state` with a `#partial switch` naming six of the seven
`Connection_State` members. The omitted one is **`.Will_Close`** — the state a
connection enters the moment the server decides to retire it after the current
response. `response_must_close` sets it for **every request carrying
`Connection: close`**, every HTTP/1.0 request, and every failed body read.

An omitted case in a `#partial switch` is silence, not a compile error. Such a
connection was neither closed nor logged; it stayed in `td.conns`, so
`len(td.conns)` never reached zero and **the loop never broke — past every
deadline**, because the force-close was reachable only through the `.Active`
arm.

**The measurement**, and it is a one-line reproduction:

| Request | `max_write_time` | `max_drain_time` | `web.stop` returns |
|---|---|---|---|
| `GET /big` **with** `Connection: close`, client never reads | 500 ms | 500 ms | **never** (8 s, 10 s — any bound the test waited) |
| same | **off (0)** | 500 ms | **never** |
| same | 500 ms | **2 s** | **never** |
| `GET /big` **without** `Connection: close`, client never reads | 500 ms | 500 ms | **1.107 s** |
| with `Connection: close`, **after patch 26** | 500 ms | 500 ms | **1.132 s** |

The write deadline is irrelevant (it hangs with the deadline off) and so is the
drain deadline's value (500 ms and 2 s hang alike). The single variable is the
header.

**Why it is worse than it looks.** `max_drain_time` is documented as the
*absolute* bound on shutdown — the vendored comment says it covers all three
waits, and `docs/operations.md` tells operators to keep it inside their
supervisor's `TimeoutStopSec`. That promise was false for the most ordinary
client there is: `curl` on a large download interrupted at the terminal sends
exactly this shape. The only remaining exit was the supervisor's SIGKILL, which
is the failure mode a drain deadline exists to prevent.

**Why the earlier suites missed it.** They all asked the question with the wrong
header. `wp58-drain` drives `.Idle` and `.Active`; `c01-async-ops` P3 sends
`GET /big HTTP/1.1` with no `Connection: close` and passes in 1.544 s. The state
that was never exercised is the one that was never handled — which is exactly
what a grid is for, and exactly why the campaign enumerates *states* rather than
*scenarios someone thought of*.

**The fix** treats `.Will_Close` exactly as `.Active`: it *is* an in-flight
response — allowed to finish before the deadline, force-closed after it, the
same trade the `.Active` arm already makes.

---

## 2c. F-C03-2 — the real-socket suites crash at a low rate under gate load — RESOLVED (Hardening H-2)

**CLASSIFICATION: defect. Not closed by C-03; DIAGNOSED and FIXED by H-2
(vendored patches 29 + 30). The graceful-unwind fix that was specified as a
follow-up is done and verified — a failed event-loop acquire now makes
`web.serve` fail cleanly instead of terminating the process.**

> **UPDATE (Hardening H-2, 2026-07-24).** The instrument this section asked for —
> an ASan build on a constrained host — reproduced it and named the cause. On a
> VPS with `ulimit -l` = 8 MiB and <1 GiB free, `tests/c05-saturation` under
> `-sanitize:address` aborted with `server.odin:274 runtime assertion:
> acquire_err == nil` at **server startup**, exactly the signature below. The
> mechanism: `nbio.acquire_thread_event_loop()` sets up the thread's `io_uring`
> rings, which **pin memory against `RLIMIT_MEMLOCK`**; one loop is created per
> Handler lane per server, so under a low memlock budget or memory pressure the
> setup fails, and upstream's bare `assert(err == nil)` — the deferred error
> handling it never wrote — turned that resource failure into a startup crash the
> test runner reports as `Segmentation_Fault`. It "looked random" only because
> nothing named its cause; the rate tracks how close the host is to its
> locked-memory limit. **Patch 29** replaces both asserts with a diagnostic that
> names `RLIMIT_MEMLOCK` / memory and the remedy (raise `ulimit -l`, lower
> `max_handlers`, or run fewer concurrent servers). **What remains open** is the
> graceful unwind — returning an error from `web.serve` instead of terminating —
> which is a multi-threaded lifecycle change across the lane workers and the
> wait group, specified in `planning/closure-record-and-verdict.md` rather than
> rushed at the end of the phase.

The original record, kept because its reproduction-rate discipline is the point:

The roadmap handoff records, as standing advice, that *"real-socket suites
(wp41/wp58/wp67/wp8) segfault under shared-machine load; they pass in isolation
— re-run rather than chase."* C-03 observed the same signature twice while
building this campaign, and the campaign's own thesis says that advice is wrong:
**a suite that crashes one run in N has a reproduction rate, and a reproduction
rate is a finding.**

**Observation 1.** The first invocation of `build/check_c01_controls.sh` died
2.5 ms in, before any phase printed, with a leak report showing only route
registration and `thread_unix.odin:_create` — i.e. inside the first
`start_server`. Ten subsequent runs were green with timings identical to the
millisecond.

**Observation 2.** A full `build/check.sh` segfaulted in
`wp90-deadlines` at `wp90_an_active_keepalive_is_not_idle`. That suite then
passed **3/3 on this tree, 3/3 on pristine `origin/main`, and 4/4 under
synthetic concurrent socket load** — fourteen green runs against one crash.

**What is already ruled out.** Not a regression from the Closure's vendored
patches: wp90 is green on pristine `origin/main` and on this tree alike. Not the
port-fallback path: a stop after a failed bind was probed directly and is clean
(now cell D10). Not load alone, at least not the load a `wp58-drain` loop
produces alongside it.

**Why it is not closed here.** The signature — a crash inside server startup,
before the suite's own work begins — points at process-level state rather than
at the request path this campaign enumerates, and chasing it needs an instrument
this WP does not have: an ASan/debug gate build, or a core dump kept from a
failing run. Both are cheap to add and neither is a fault-injection cell.

**The next step, named so it is not lost again:** run the gate's socket suites
under AddressSanitizer and keep the core dumps, exactly as the F-002
investigation did (`/tmp/attacklab/uaf_rst.log` is what turned that report from
a flake into a diagnosis). Until then the standing advice — re-run — is what
operators of this gate should do, but it is a workaround with a ticket, not a
verdict.

---

## 3. What C-03 does not claim

The grid is **complete for the boundaries it names**, not for every fault that
exists. Three exclusions, stated so they are choices rather than oversights:

- **No fuzzing.** The wire corpus (`wp9-wire`) and the seeded fault lab
  (`wp41-fault`, replayable trails) cover structured malformation. A fuzzer
  would be a different instrument with a different cost, and it is
  evidence-gated in the backlog, not silently skipped.
- **No multi-host or network-partition faults.** Everything here is loopback.
  Partition behaviour belongs to the topology (C-06) and to whatever the
  application does with its own dependencies.
- **No adversarial timing at nanosecond resolution.** The races this project has
  actually shipped (WP70's Date buffer, F-002's deferred dispatch) were found by
  reading ownership, which is C-01's instrument, not by winning a race in a
  test.
