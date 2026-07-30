# Phase-4 specification — the lifecycle and the capacity ledger

**Status: WP39 and WP40, both SPEC, both ACCEPTED 2026-07-20 under the ADR-029
delegation.** Neither ships a symbol. They are the two instruments every
implementation package is held to, written before any of them starts, for the
reason the Phase-4 plan gives: *a production phase that starts by implementing
has chosen its failure modes by taste.*

| Spec | Work package | Implementation held to it |
|---|---|---|
| §1 Lifecycle state machine | WP39 | WP43, WP44, WP45 |
| §2 Capacity and overload ledger | WP40 | WP46, WP47, and the WP56 freeze |

**Everything below was written against the vendored server as it actually is,
not against a diagram.** Where this document states what the code does today, it
was read at commit `112c49b` before the sentence was written, and §1.2 records
what that reading found — including one gap that changes what WP44 has to build.

---

# §1 — The lifecycle, as data (WP39)

## 1.1 The decision

**A server has exactly one state at a time, and that state is a closed enum —
never a set of booleans.**

```
Configuring  →  Serving  →  Draining  →  Stopped
     │             │            │
     └─────────────┴────────────┴──────────→  Failed
```

Five states, five transitions, and no others. The reasoning is the one that made
`Framework_Error` a closed union rather than a bag: `stopping`, `draining` and
`failed` as three independent booleans admit eight combinations, of which five
are nonsense that no reviewer can enumerate and no test can cover. **A state
machine you cannot enumerate is a state machine you cannot audit**, and shutdown
is precisely where an unauditable state costs a dropped request.

| State | Meaning | Accepts new connections | Serves in-flight work |
|---|---|---|---|
| `Configuring` | Before `serve` binds. Registration is legal here and only here. | no | no |
| `Serving` | Bound and accepting. The normal state. | **yes** | yes |
| `Draining` | Stop requested. Admission has ceased; existing work finishes, under a deadline. | **no** | yes |
| `Stopped` | Socket closed, every connection closed, cleanup ran exactly once. | no | no |
| `Failed` | Reached from any state on an unrecoverable transport error. Terminal. | no | no |

**Transitions are one-way and total.** There is no `Draining → Serving`: a
server that stopped admitting does not resume, because a client refused during
the drain has already gone elsewhere, and an operator who asked for a stop meant
it. There is no `Stopped → Serving`: a new server is a new `serve` call. Both
are refusals rather than omissions, and both are stated here so a later package
cannot add them as a convenience.

**`Configuring` is not a new rule.** It is the Phase-3 decision that
registration after `serve` begins is rejected (WP36), named as a state rather
than restated as a guard. WP44 inherits it and does not reopen it.

## 1.2 What the vendored server already does — read, not assumed

**This is the finding that made writing the spec first worth the delay.** The
vendored server is not a blank slate: it already has a lifecycle, and its exact
shape changes what WP44 has to build.

Read at `vendor/odin-http/server.odin`, commit `112c49b`:

* **It has a `Server_State` enum** with eight members (`Uninitialized, Idle,
  Listening, Serving, Running, Closing, Cleaning, Closed`) and a seven-member
  `Connection_State` (`Pending, New, Active, Idle, Will_Close, Closing,
  Closed`).
* **`server_shutdown` is admission-stop plus a wake-up**: an atomic `closing`
  flag and `nbio.wake_up` per thread. Idempotent and safe from another thread —
  which the Druse adapter's `request_stop` already relies on.
* **The drain is real.** `_server_thread_shutdown` closes every `New`, `Idle`
  and `Pending` connection immediately, leaves `Active` ones alone, and ticks
  the event loop until the connection map is empty.
* **`Will_Close` already exists**, which is close-after-send in the vendored
  server's own vocabulary.
* **`connection_set_state` refuses backward transitions** — a connection at
  `Closing` or beyond cannot move back — the same one-way rule §1.1 states for
  the server.

**And here is the gap, which is the whole reason for reading it:**

> **The drain loop has no deadline. It waits for `Active` connections
> unconditionally — forever.**

One handler that never returns, or one client that never finishes reading, holds
the process open indefinitely. That is exactly what §1.3's third obligation
forbids, and it means **WP44 is not "expose what is already there"**: the
deadline is the part that does not exist.

**Recorded so WP44 does not rediscover it:** the framework's `Draining` maps
onto the vendored `closing` flag plus its drain loop, and the absolute deadline
must be imposed **around** that loop rather than inside it. Whether that ends as
a timer beside it or as a replacement for it is **ADR-033's** question, decided
at WP41 — not this spec's.

## 1.3 The proof obligations that travel to WP44

A lifecycle that is only a diagram proves nothing. These are what WP44 must
demonstrate in the WP41 laboratory, each written as a **failure** so a test can
trip it:

1. **Admission stops first, and observably.** After a stop is requested, a
   connection accepted afterwards is a defect. The positive control is a
   connection accepted *just before* the request, which must still be served —
   without it, a server that accepts nothing would pass.
2. **Close-after-send, never close-mid-send.** A response already being written
   is written completely, then the connection closes. A truncated response
   during a drain is a defect: at the client it is indistinguishable from data
   corruption.
3. **The deadline is ABSOLUTE, and expiry is a decision rather than a hang.**
   When it passes with work still in flight, remaining connections are closed
   and the state reaches `Stopped`. **"Wait forever" is not a deadline**, and it
   is the vendored behaviour today (§1.2). The lab seeds a handler that never
   returns; a `Stopped` that never arrives is the defect.
4. **Cleanup runs exactly once.** Not zero times (a leak), not twice (a
   double-free). The lab requests two stops concurrently and asserts one
   cleanup — the same discipline `web.destroy` already carries.
5. **The §2.4 reservation still holds in `Draining`.** A server that cannot
   allocate the buffer it needs to send `Connection: close` has run out of
   resources at the exact moment it needed one. Easiest obligation to forget,
   hardest to diagnose in production.

## 1.4 What this spec deliberately does NOT decide

* **The public symbols.** WP44 sizes them at spec time under G-09 evidence, from
  a budget of **two concepts** (the WP38 lab measured 23 of 25). Naming them now
  would be the false precision the Phase-4 plan refuses.
* **Where the state lives.** Per-server state is WP43's and depends on ADR-030.
  This spec says a server has one state; not which struct holds it.
* **Whether a `Failed` server is inspectable.** An observer already sees the
  framework error; whether the *state* is readable is a public-surface question
  WP44 owns.
* **Signal handling.** The vendored server offers a SIGINT handler that "can
  only be called once in the lifetime of the program because of a hacky
  interaction with libc" — its own words. Whether Druse exposes any signal
  integration is WP44's; this spec records only that the constraint exists.

---

# §2 — The capacity and overload ledger (WP40)

## 2.1 The decision

**Every resource the server can exhaust gets a row, and a row is not complete
until it answers five questions:** what is the capacity, what happens when it is
full, what diagnostic says so, who releases it, and **how much is reserved so
that stopping remains possible.**

The fifth column is why this is its own work package.

> **The fatal failure is not running out of capacity. It is running out and
> having none left to shut down with.**

A server that cannot accept a connection is degraded and honest. A server that
cannot close its connections, cannot write `Connection: close` and cannot reach
`Stopped` is a process that must be killed — and killing it is exactly what
graceful shutdown existed to avoid. Every reservation below defends §1.3's
obligations against §2's own limits.

## 2.2 What Phase 3 already bounds, restated so the gap is visible

The Phase-2 capacity ledger, as amended through Phase 3, bounds **Druse's own
per-request working memory**: response headers per response, the `Allow` value,
the extractor envelope, the logger line, the request ID, the poison diagnostic,
path parameters per pattern, and — since WP36 — the request body, the request
line and the header block, all three configurable.

**None of that is a server bound.** The ledger says so plainly today: concurrent
connections, accept queue and inbound header *count* are "not bounded by this
framework". These rows are what turn that disclosure into a mechanism.

## 2.3 The rows

Capacities are **shapes, not numbers**. The numbers are WP46's, chosen against
the fault lab and recorded as judgement rather than as citation (the C-5 honesty
rule). What is fixed here is that each row must exist and must answer all five
columns.

| # | Resource | Behaviour when full | Diagnostic | Cleanup owner | Reserved for stop |
|---|---|---|---|---|---|
| R-1 | **Concurrent connections** | Refuse the accept; the listener stays healthy | counted, not per-event logged (§2.5) | the connection's own close path | **yes** (§2.4) |
| R-2 | **Accept queue depth** | Bounded backlog; the OS refuses beyond it | boot-time diagnostic of the configured value | the OS | n/a — not needed to stop |
| R-3 | **Minimum ingress rate per connection** | Below the rate, close the connection | counted | connection close path | n/a |
| R-4 | **Per-connection read deadline** | Close the connection (ADR-031/ADR-033) | counted | the timer's own cancellation | **yes** — a timer slot |
| R-5 | **Per-connection write deadline** | Abandon the write, then close | counted | as R-4 | **yes** |
| R-6 | **Response buffers** | Refuse admission *before* allocating (WP47) | counted | the response's teardown | **yes** — one buffer minimum |
| R-7 | **Timers** | Refuse the operation that needed one | counted | cancellation on connection close | **yes** (§2.4) |
| R-8 | **Inbound header COUNT** | Reject the request; byte size is already bounded | the existing 4xx path | request teardown | n/a |
| R-9 | **The shutdown deadline itself** | Expiry closes remaining connections and reaches `Stopped` | logged once at expiry, with the count abandoned | the drain path | **it IS the reservation** |

**R-9 ties the two halves together.** A deadline is a capacity — a budget of
*time* rather than of memory — and it carries the same obligation as the
others: say what happens when it is exhausted, and never say "wait".

## 2.4 The reservation rule

**Every resource marked "reserved for stop" has a quantity admission control may
never consume.** In one line:

> **Admission is refused while free capacity is at or below the reservation —
> not when it reaches zero.**

The reservation covers what a drain provably needs:

* enough connection slots for what is already open — trivially satisfied, since
  draining allocates no new connections;
* **one response buffer**, so a final response or a `Connection: close` can be
  written;
* **timer slots for the shutdown deadline itself**, which is why R-7 is
  reserved: a deadline that cannot be armed because timers are exhausted is a
  deadline that does not exist, and the failure presents as a hang.

**This is testable and must be tested.** WP41 seeds an artificially small pool,
drives it to full, and requests a stop. A stop that cannot complete under
pressure is the defect; the reservation is what makes it impossible.

## 2.5 Diagnostics under overload — the rule that is easy to get wrong

**A per-event log line under overload is an amplifier, not a diagnostic.** Ten
thousand refused connections must not produce ten thousand log lines: that turns
a load spike into an I/O storm, which is a denial of service the framework
performs on itself.

Therefore:

* **exhaustion is COUNTED**, and the count is observable;
* **a transition is logged** — entering and leaving an exhausted state, once
  each, never the events between;
* **boot-time validation is logged fully**, because it happens once and an
  operator is watching (the "3 a.m." rule WP36 already applies);
* **the drop policy is itself observable** (WP50), because a metric that
  silently stops being emitted is worse than no metric.

## 2.6 What lands where

* **R-1 … R-9 join the capacity ledger at WP56**, with real numbers and
  behaviour-when-full, exactly as WP36's rows did.
* **Every promise a row makes enters the CLAIM ledger with a negative control.**
  A row saying "refuse the accept" with no test that observes a refusal is a
  sentence, not a bound.
* **"Bounded" stays a gated word.** These rows bound the *server*; they do not
  bound a handler's own allocations or a response body the application builds.
  The gate that fails any document claiming the framework as a whole is bounded
  stays exactly as it is.

## 2.7 What this spec deliberately does NOT decide

* **The numbers.** WP46, against the lab, recorded as judgement.
* **The shedding algorithm.** WP47 — deterministic before adaptive.
* **Per-server or per-process limits.** ADR-030's, via WP43.
* **How counts are exported.** WP50's, and it inherits the redaction rule.

---

# §3 — The redaction policy (WP50)

**Status: ACCEPTED 2026-07-21 under the ADR-029 delegation.** The SPEC half of
WP50, landing before its implementation half exactly as the plan required —
because separating redaction from observability invites shipping them in the
wrong order, and the wrong order is the one where data leaves the process first.

## 3.1 The decision

**No request-derived byte reaches a log line, a metric label, a span name or an
observer event.**

Not "no secrets" — **no request-derived byte at all**. The distinction is the
whole policy, and it is what makes it enforceable rather than aspirational:

* a policy that says "do not log secrets" needs a definition of secret, and
  every definition is a list somebody has to keep current against attackers who
  read it too;
* a policy that says "log nothing derived from the request" needs no list. It is
  checkable by reading one line of code, and it fails CLOSED — an engineer who
  wants to add a field has to argue for it rather than merely not think about
  it.

**What may be recorded** is therefore a closed set, and every member is
framework-generated or low-cardinality by construction:

| Recorded | Why it is safe |
|---|---|
| the **route pattern** (`web.route`) | App-owned, written at registration, never request-derived. `/users/:id`, never `/users/42` |
| the **method** | one of a closed six-member enum |
| the **status** | an integer the framework chose |
| the **request ID** | framework-generated, or a client value that passed WP23's charset and length validation |
| a **`Framework_Error`** member | a closed enum |
| a **`typeid`** | a type name, never a value |
| framework **counts** | integers |

**What may never be recorded:** the path, the query string, any header name or
value, any body byte, any extracted parameter, any application value, and any
message text derived from any of those.

## 3.2 Why OWASP's do-not-log list is NOT the mechanism here

The plan named it — tokens, session identifiers, passwords, connection strings,
keys, PII, payment data. **Every item on that list is already excluded by §3.1,
because every item arrives in a request.** Reproducing the list as a set of
checks would be weaker than the rule that already covers it: a list can be
incomplete, and the framework would then be enforcing the list rather than the
property.

**So the list is recorded as motivation and the rule is what is enforced.** That
is the honest relationship between them, and stating it stops a later reader
adding a `is_password_like()` check that gives false comfort.

## 3.3 CR/LF escaping — the second half, and it is not the same problem

Even permitted text can carry a newline. **A log field with a CR or LF in it
forges additional log records**, which turns a reader's evidence into an
attacker's writing surface (OWASP log injection).

The only permitted field that is application text is the **route pattern**, and
it is escaped. Nothing else needs escaping because nothing else is text a person
authored — but the rule is stated as a rule rather than as a coincidence of the
current field set: **any permitted field that is not framework-generated is
escaped, and truncation stops on a unit boundary** so a cut never leaves a
dangling backslash that re-opens the injection.

## 3.4 What was already true, and why that matters

**This spec ratifies a property the framework already had, and records that
rather than claiming new work.** Verified at this commit:

* `Framework_Event` carries no request-derived string except `route`, and
  `build/check_public_api.sh` fails the build if any other field is a `string`;
* `web.route` returns the registered pattern, with the gate asserting that
  **every write** to the slot is `entry.pattern`;
* `web.logger` writes `METHOD pattern status` and escapes the pattern, with a
  derived line bound rather than a guessed one;
* `web.request_id` validates a client-supplied ID against a charset that
  excludes CR and LF, and **discards** rather than sanitises — a repaired
  attacker value is still an attacker value;
* the framework's diagnostics are compile-time constants, so no formatted line
  can carry request bytes.

**The property was preserved deliberately, package by package, before there was
a policy naming it.** §3.5 is what stops that being luck from here on.

## 3.5 The standing rule for every later package

**A new observability field is a spec amendment, not an edit.** Any package that
wants to record something must place it in §3.1's permitted table with a reason,
and the gate enforces the table's shape.

**Metrics and spans key on the route pattern, never the raw path.** This is not
only a redaction rule — a metric keyed on the path has unbounded cardinality and
takes the metrics backend down, which is why C-2 required it independently.

**The drop policy is observable.** Any component that can discard records must
count what it discarded and expose the count, because a metric that silently
stops being emitted is worse than no metric — it reads as "nothing happened".

**A logger may never apply backpressure to a request.** A component that can
slow the serving path has inverted the hierarchy: observation exists to describe
the system, never to become the reason it is slow.
