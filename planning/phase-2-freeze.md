# Phase 2 — Freeze

**Date:** 2026-07-20. **Toolchain:** the pinned commit in `odin-version.txt`
(`819fdc7`); the gate refuses any other. **Gate:** `build/check.sh` exits 0.

This document is to Phase 2 what `planning/phase-1-freeze.md` is to Phase 1,
plus three ledgers Phase 1 did not have. Phase 1 froze symbols, signatures and
dependencies. It did not freeze the project's own **sentences**, and this
document closes that gap (plan Amendment 1, owner docket D-2).

Everything below is measured on the pinned toolchain, in this repository, at
the commit that carries this file. Where a number could not be measured
honestly, it says so instead of rounding.

---

## 1. The ledger diff

| | Phase 1 froze | Phase 2 adds | Total |
|---|---|---|---|
| application | 32 | +12 | **44** |
| test-support | 2 | 0 | **2** |
| union | 34 | +12 | **46** |

The twelve, each with the work package that ratified it and the amendment that
recorded it:

| Symbol | Kind | WP | Freeze amendment |
|---|---|---|---|
| `use` | proc | 17 | 3 |
| `next` | proc | 17 | 3 |
| `Router` | type | 18 | 4 |
| `router` | proc | 18 | 4 |
| `mount` | proc | 18 | 4 |
| `header` | proc | 19 | 5 |
| `bearer_token` | proc | 19 | 5 |
| `observe` | proc | 20 | 7 |
| `Framework_Event` | type | 20 | 7 |
| `Framework_Error` | type | 20 | 7 |
| `logger` | proc | 22 | 8 |
| `request_id` | proc | 23 | 9 |

`test_request` gained three optional parameters (body, query, headers —
amendments 1, 2, 6) without becoming a second symbol.

**Rejected and staying rejected:** `web.group` (ADR-024 — refused in every
phase, not deferred), `request_id_value` (ADR-027 closed the +2 contingency),
a `Middleware` type (ADR-005 — middleware IS `Handler`), a public `recovery`
(ADR-020 — impossible, not merely unbuilt).

Every symbol's signature is pinned byte-for-byte in
`build/phase1-public-signatures.txt` and checked on every gate run. Every
symbol carries a G-09 evidence row — compile evidence, behaviour evidence,
docs, ownership — in `planning/phase-1-freeze.md` amendments 3-9, and the gate
fails if any row is missing or any citation stops resolving (150 citations
currently resolve).

---

## 2. Claim ledger

One row per **strong promise the project already makes out loud**, in
`README.md`, `docs/` or `CHANGELOG.md`. Scope is deliberately bounded to claims
that already exist — no claim was invented to fill this table.

The column that does the real work is the last one. **A claim with no negative
control does not freeze.**

### C-1 — "ordering is enforced, not documented"

* **Sentence:** "`use` after any registered route — or after the first dispatch
  — REJECTS THE WHOLE APPLICATION fail-closed: every request answers 500 and
  `web.serve` refuses to start."
* **Scope:** `App` and `Router`, both transports, `app()` and `bare()`.
* **Implemented:** `web/middleware.odin` (`mw_poison_use_after_route`,
  `mw_poison_intercept` on the dispatch path).
* **Positive test:** `tests/wp17-public-surface::wp17_mis_ordered_auth_program_does_not_serve_the_protected_route`.
* **Negative control:** `check_wp24_controls.sh` control 2 — builds and RUNS a
  mis-ordered program and fails if it serves the route or answers anything but
  500; `check_wp17_controls.sh` controls for the guard itself.
* **Environment:** in-memory transport and a real socket (`tests/wp17-socket`).
* **Does NOT guarantee:** that a middleware registered correctly is *correct*.
  The framework enforces ORDER, never policy. It also does not protect against
  code that reaches into package internals (ADR-008).

### C-2 — "a faulting handler aborts the process; a handler that forgets to respond gets a standardized 500"

* **Sentence:** "A handler that returns without committing a response is
  finalized by the response driver to the standardized `internal_error` 500 …
  A handler that faults — panic, failed assertion, out-of-bounds index, nil
  dereference, divide-by-zero — aborts the process."
* **Scope:** both transports, `app()` and `bare()`, default **and** `-o:speed`.
* **Implemented:** `web/serve.odin` (`driver_run` finalization); the abort is
  Odin's, not the framework's (ADR-020).
* **Positive test:** `tests/wp21-public-surface` (run twice: default and
  `-o:speed`) and `tests/wp21-socket`.
* **Negative control:** `check_wp21_controls.sh` control 7 — BUILDS AND RUNS
  faulting programs, with a fault-free baseline that must exit 0 first.
  Measured: panic and out-of-bounds both die with signal 4 / status 132.
* **Environment:** Linux x86-64, pinned toolchain, both optimization levels.
* **Does NOT guarantee:** recovery. There is none and there never will be —
  `context` is an implicit by-value parameter, so `web.app()` cannot install a
  fault hook on its caller's behalf. Run under a supervisor.

### C-3 — "nothing from the request reaches a log or a client"

* **Sentence:** the `logger` "never logs the raw path, the query string, a
  header, a body byte, or a captured parameter value"; the standardized 500
  carries "no detail about the request".
* **Scope:** `web.logger`, the six framework diagnostics, `Framework_Event`,
  and every automatic error envelope.
* **Implemented:** `web/logger.odin` (route pattern only), `web/errors.odin`
  (compile-time constant bodies), `web/observer.odin` (no message field).
* **Positive test:** `tests/wp22-public-surface::wp22_public_never_emits_query_header_or_body`
  asserts the exact bytes of the line.
* **Negative control:** `check_wp22_controls.sh` control 1 (raw path as route
  identity → red); `check_wp20_controls.sh` control 6 (a `path: string` field
  on `Framework_Event` → the gate rejects it).
* **Environment:** in-memory transport.
* **Does NOT guarantee:** anything about what YOUR handlers log. The framework
  redacts its own output only.

### C-4 — "a rejected request ID is discarded, never echoed"

* **Sentence:** an inbound `X-Request-Id` outside `[A-Za-z0-9._-]` / length
  1..64 "is DISCARDED and replaced with a generated ID: never echoed, never
  logged, never readable by a handler, and never repaired."
* **Scope:** `web.request_id` only.
* **Implemented:** `web/request_id.odin` (`request_id_acceptable`).
* **Positive test:** `tests/wp23-public-surface::wp23_public_crlf_is_never_echoed`
  and `tests/wp23-internal::wp23_a_rejected_value_never_reaches_the_response`.
* **Negative control:** `check_wp23_controls.sh` controls 1-3 (echo
  unvalidated; widen the charset; drop the length bound) — each must turn a
  test red. Control 7 is the POSITIVE half: an implementation that rejects
  *everything* passes 1-3 while destroying correlation, and must fail.
* **Environment:** in-memory transport.
* **Does NOT guarantee:** unpredictability. The ID is **not unguessable** and
  must never be used for authentication. It also says nothing about
  `X-Forwarded-*` or trusted proxies (Phase 4, ADR-013).

### C-5 — "dispatch through a middleware chain allocates zero bytes"

* **Sentence:** "Dispatch through a middleware chain allocates **zero** bytes;
  chains are flattened once, at registration."
* **Scope:** the CHAIN WALK, measured around the private
  `driver_run`/`driver_cleanup` pipeline — **not** around `test_request`, whose
  recorder copies every response by design.
* **Implemented:** `web/middleware.odin` (`chain_enter` re-slices an
  App-owned pool; index pairs, never stored slices).
* **Positive test:** `tests/wp17-internal` with `mem.Tracking_Allocator`.
* **Negative control:** `check_wp17_controls.sh` — a per-dispatch allocation
  must turn the tracking test red.
* **Environment:** debug build, in-memory transport.
* **Does NOT guarantee:** zero allocation for the REQUEST. A JSON body binds
  into a request arena and a JSON response allocates its body; "zero" here
  names the chain walk and nothing else.

### C-6 — "an application that never names `web.logger` links zero logger symbols"

* **Sentence:** "An application that never names `web.logger` links **zero**
  logger symbols."
* **Scope:** symbols declared in `web/logger.odin`, plus the public
  `web::logger` entry point.
* **Implemented:** dead-code elimination; the file imports nothing.
* **Positive test:** `check_wp22_controls.sh` control 7, `nm` over two real
  consumers — 0 when unreferenced, 6 when used.
* **Negative control:** the POSITIVE control inside control 7 — an application
  that DOES use it must link them, or the pattern matches nothing and the
  zero-assertion is vacuous.
* **Environment:** debug build, Linux x86-64, pinned toolchain.
* **Does NOT guarantee:** a byte-identical binary. See §5 — the toolchain does
  not build reproducibly, so that stronger claim is **untestable** and was
  withdrawn rather than quietly asserted.

### C-7 — "the test-support teardown does not ship in applications that never test"

* **Sentence:** G-11: "a minimal application that never calls `test_request`
  links ZERO `web/testing` teardown symbols."
* **Scope:** `web/testing` teardown symbols.
* **Positive test:** `build/check_g11_teardown.sh` — a never-tests consumer
  links 0 symbols, and a does-test consumer links them (the positive control,
  without which the pattern could match nothing and prove nothing).
* **Negative control:** the same script's mutation — it restores the static
  `destroy → testing.destroy` edge and REQUIRES the teardown symbols to come
  back. Measured before the fix: four symbols and 608 extra bytes.
* **Environment:** debug build, Linux x86-64.
* **Does NOT guarantee:** anything about `-o:speed` link behaviour, which is
  not measured here.

### C-8 — "the response commit guard makes the first response win"

* **Sentence:** "a further response attempt goes through the ordinary
  responders and is rejected by the existing single-commit guard, first
  response surviving byte-identically."
* **Scope:** the SUPPORTED responder paths.
* **Positive test:** `tests/wp17-internal` (byte-identity of the first response
  after a rejected post-`next` attempt).
* **Negative control:** `check_wp17_controls.sh`; `check_wp3_mutations.sh`.
* **Does NOT guarantee:** a security boundary. "The application and the
  framework share one program, and code that deliberately reaches into
  framework internals bypasses it" (ADR-008). This is stated in
  `docs/canonical-patterns.md` and must stay stated.

### C-9 — "middleware observe 404 and 405"

* **Sentence:** "App-level middleware run on **every** dispatch, including a
  404 and a 405."
* **Positive test:** `tests/wp17-internal` (`A><A` around both, envelope and
  `Allow` unchanged); `tests/wp22-public-surface::wp22_public_logs_a_404`;
  `tests/wp23-internal::wp23_the_id_appears_on_a_404`.
* **Negative control:** `check_wp17_controls.sh` — skipping the miss chain must
  turn the 404-observability test red.
* **Does NOT guarantee:** that a miss reaches the WP20 observer. A 404 is a
  normal outcome, not a framework failure, and emits no event —
  `tests/wp20-public-surface::wp20_public_a_404_is_not_a_framework_failure`
  pins that distinction.

### C-10 — "limits are configurable, and both transports enforce the same ones"

* **Sentence:** "`web.limits` sets the application's byte budget;
  `web.test_request` enforces the same numbers as a socket, so a 413 in a test
  is a 413 in production." **Added by WP36.**
* **Scope:** the `App`, both transports, `app()` and `bare()`. The body cap is
  enforced on the shared request path; the request-line and header budgets are
  passed to the backend at boot and enforced by its parser.
* **Implemented:** `web/limits.odin` (validation and the fail-closed guards),
  `web/serve.odin` (the one driver line that copies the budget onto every
  request, and the boot derivation of the backend's options),
  `web/extract.odin` (the comparison).
* **Positive test:**
  `tests/wp36-public-surface::wp36_a_lowered_body_cap_is_enforced_exactly` —
  exactly the limit is accepted, one byte more is 413;
  `::wp36_a_raised_body_cap_admits_what_a_lower_one_refused` proves the number
  is read rather than a smaller constant applied twice.
* **Negative control:** `check_wp36_controls.sh` — the body comparison pinned
  back to the fixed constant must turn the configurable-cap tests red; the
  after-dispatch guard removed must turn the rejection test red; and the driver
  line that copies the budget onto the Context removed must turn the whole
  configurable half red, which is what makes the R-10 claim mean something.
* **Does NOT guarantee:** anything temporal. **There are no timeout fields**,
  because the vendored server has no read or write deadline to configure — see
  Amendment 12. It also does not bound **connections, accept backlog, inbound
  header COUNT or process memory**: those belong to the transport and the
  operating system, and configurable limits do not make the framework
  "bounded".

### C-11 — "a request that never finishes arriving is closed"

* **Sentence:** "`Limits.max_request_time` bounds how long one request may take
  to arrive; a client that stops mid-request, or trickles bytes indefinitely, is
  disconnected when the deadline passes." **Added by WP46.**
* **Scope:** the socket transport. `test_request` has no connection and no
  arrival time, so this claim is deliberately NOT about both transports — the
  first Phase-4 claim that is not, and it says so rather than implying parity it
  does not have.
* **Implemented:** `vendor/odin-http/server.odin` (DRUSE PATCH 6 — a periodic
  per-thread sweep beside the existing date tick), `web/limits.odin`,
  `web/serve.odin` (boot derivation), `web/internal/transport/` (the neutral
  `i64` and its conversion).
* **Positive test:**
  `tests/wp41-fault/fault_test.odin::phase_deadline_ends_a_held_connection` — a
  truncated request is CLOSED once the deadline passes; and
  `::phase_deadline_bounds_a_trickling_client`, which an idle timeout would
  never reach.
* **Negative control:** the SAME laboratory, against a server with **no**
  deadline configured — `phase_truncated_hold` and `phase_trickle` still assert
  the connection is held open. **That is the control: the two behaviours are
  asserted side by side in one suite, so "the deadline works" cannot be
  satisfied by a server that closes everything.** The in-suite positive control
  (a complete request answered 200) runs first for the same reason.
* **Does NOT guarantee:** anything about a slow HANDLER, a write deadline, or
  the in-memory transport. And the granularity is a 250 ms sweep, so a request
  is closed in [deadline, deadline + 250 ms] rather than exactly at it.

### C-12 — "admission is bounded, and a shutdown always has room"

* **Sentence:** "`Limits.max_connections` bounds concurrent connections;
  `reserved_conns` slots are held back from admission, so admission is refused
  at or below `max_connections - reserved_conns` and never at zero." **Added by
  WP47.**
* **Scope:** the socket transport, per serving thread. `test_request` has no
  connections, so this claim is not about both transports and says so.
* **Implemented:** `vendor/odin-http/server.odin` (DRUSE PATCH 8 — the accept
  path and a per-thread refusal counter), `web/limits.odin` (the two fields and
  their boot validation), `web/serve.odin`, `web/internal/transport/`.
* **Positive test:**
  `tests/wp41-fault/fault_test.odin::phase_admission_is_bounded_with_a_reservation`
  — with a budget of 6 and 2 reserved, the fifth connection is refused **while
  two slots are still free**. It proves the GAP, not the ceiling: testing at
  zero would prove the wrong rule.
* **Negative control:**
  `::phase_admission_below_the_limit_is_unaffected`, which runs FIRST — a
  server whose limit is far above the load must serve everything. Without it,
  the positive test would pass against a server that refused every connection.
  And `::phase_a_reservation_larger_than_the_budget_is_rejected` proves the
  boot refusal, since a reservation that swallows its budget would otherwise be
  a server that accepts nothing while looking configured.
* **Does NOT guarantee:** a bound on the accept BACKLOG (the kernel's), on
  inbound header COUNT, or on anything per-process rather than per-thread. Nor
  does it make the framework "bounded" — the gated word still applies.

### Claims examined and NOT frozen

* **"the machinery present but unused costs +2,424 bytes … a program that never
  calls `use` does not even link it"** (`docs/middleware.md`). **The
  parenthetical was FALSE and is corrected by this work package.** Measured:
  an application that never calls `use` links **8** symbols from
  `middleware.odin` — `chain_enter`, `chain_flatten`, `miss_chain_ensure`,
  `miss_terminal`, `mw_destroy`, `mw_miss_prepare`, `mw_poison_intercept` and
  the public `next`. They are reachable from `dispatch` and `destroy`
  unconditionally, which is by DESIGN: ADR-019 requires the fail-closed guard
  to sit on the shared dispatch path so both transports reject identically. The
  sentence also contradicted itself — a cost of +2,424 bytes *is* the machinery
  being linked. Corrected in place; see §5.

---

## 3. Lifetime ledger

The WP24 ownership table, promoted to frozen evidence. It lives in
`docs/canonical-patterns.md` ("Who owns what"), where users read it, and the
docs gate requires the heading, all four questions, and a row for each Phase-2
borrowed value — so a future edit cannot drop a column and leave rows that
answer less than they claim.

| Value | Owner | Valid until | May it escape? | Who cleans up |
|---|---|---|---|---|
| route pattern, incl. `web.route(ctx)` — **WP34** | App | `destroy(&app)` | only as a documented view, and only while the App lives | App |
| `request.path` / `query` / `body` | transport | end of request | no — copy first | transport |
| inbound header name/value | transport | end of request | no — copy first | transport |
| `bearer_token` result | transport | end of request | no — copy first | transport |
| path / query parameter | request storage | end of request | no — copy first | driver |
| decoded JSON body | request arena | end of request | no — copy first | driver |
| effective request ID | Context | end of request | no — copy first | driver |
| `Framework_Event` (except `route`) | the value | unbounded | **yes**, by value | nobody |
| `Framework_Event.route` | App | `destroy(&app)` | only while the App lives | App |
| middleware list and chain pool | App | `destroy(&app)` | no | App |
| `Router` after `mount` | App | `destroy(&app)` | no | App |
| application state, `web.state(ctx, T)` — **WP37** | **the caller** | as long as the caller keeps the value alive | it is the caller's own pointer; the App only borrows it | **the caller** — the framework allocated nothing |
| `Recorded_Response` | recorder | next `test_request` | copy to keep | App teardown |

**One rule:** only `Framework_Event` may escape a request. Everything else is a
view, and a view outlives nothing — with one named exception, twice over: the
**route pattern**, whether it arrives through `web.route(ctx)` or through
`Framework_Event.route`, is App-owned and lives until `destroy`. It outlives the
request and does not outlive the application.

**AMENDED BY PHASE 3 (WP34, WP37), not appended to.** Two rows changed rather
than two rows being added beside the old ones: `route` reaches the pattern the
event already carried, so the exception has a second door and not a second
meaning. **`web.state` is the one row where the framework is not the owner** —
it borrows a pointer, frees nothing, and the value must outlive the App. No
assert can enforce that (the type is still right and the memory still mapped),
so the rule is taught as LAYOUT in `examples/07-app-state`: the state and the
App are both locals of `main`.

**WP33 added no lifetime.** Multi-parameter captures are the same
request-scoped views `web.path` always returned, at a higher count.

**Enforced, not merely written:** the reuse invariant is test-pinned (WP2 — a
path view reading `"/users"` reads `"######"` after buffer reuse while a copy
still reads `"/users"`), and `tests/wp19-internal::wp19_header_value_is_a_view_invalidated_by_buffer_reuse`
does the same for headers.

---

## 4. Capacity ledger

This ledger exists to keep one word honest. **"Bounded" is never claimed for
the framework as a whole**, because connections, queues and header counts
belong to the transport.

### Fixed at compile time

| Thing | Bound | Where |
|---|---|---|
| response headers per response | 3 (`Allow`, `Content-Type`, `X-Request-Id`) | `RESPONSE_HEADER_MAX` |
| `Allow` header value | `ALLOW_VALUE_MAX` | `web/dispatch_table.odin` |
| extractor error envelope | `ERROR_BODY_MAX`, `#assert`-checked | `web/errors.odin` |
| escaped parameter name in an envelope | `ERROR_NAME_ESCAPED_MAX` | `web/errors.odin` |
| logger line | `LOGGER_LINE_MAX` (149), route field 128 | `web/logger.odin` |
| effective request ID | 64 bytes | `web/request_id.odin` |
| poison diagnostic detail | `MW_POISON_DETAIL_MAX` (256) | `web/middleware.odin` |
| request body | **4 MiB by default, configurable** — `web.limits`, `DEFAULT_LIMITS.max_body` — **amended by WP36** | `web/limits.odin`, `web/extract.odin` |
| request line | **8000 bytes by default, configurable** — `Limits.max_request_line` — **added by WP36** | `web/limits.odin`, enforced by the backend |
| header block | **8000 bytes by default, configurable** — `Limits.max_headers` — **added by WP36** | `web/limits.odin`, enforced by the backend |
| path parameters per pattern | `ROUTE_PARAM_MAX` (8) — **added by WP33** | `web/dispatch_table.odin` |

Each of these states what it does when full: the logger **truncates and says
so**; the envelope escaper **stops on a unit boundary**; the body limit
**answers 413** — at whatever number the application configured, exactly that
many bytes being allowed; the request-line and header budgets are **refused by
the backend before the core sees the request**; the poison diagnostic **truncates the pattern, never the
approved sentence**; and a pattern declaring **more** parameters than
`ROUTE_PARAM_MAX` is marked **invalid at registration** — it never matches and
never contributes to an `Allow` value, which is the fail-closed answer WP4
already gave to a two-parameter pattern, moved to a higher bound rather than
removed.

### Dynamic at registration, then frozen

| Thing | Growth | Bound |
|---|---|---|
| route table | one entry per registration | unbounded — application-controlled |
| middleware list | one per `use` | unbounded — application-controlled |
| chain pool | `globals + 1` per registration | unbounded — application-controlled |
| overlay slots | **exactly 1** | fixed (G-03: a slot, never a map) |

Registration happens before serving and is entirely under the application's
control, so "unbounded" here means "as large as your program asks for", not
"attacker-influenced". Registration is also **fail-closed**: a failed
allocation poisons the App rather than silently dropping a route (WP18
Amendment 1).

### Bounded per request

Everything an unauthenticated client can trigger is bounded by one of the
compile-time constants above, or allocates nothing at all. The chain walk
allocates zero (C-5); a 404, a 405, a malformed `?page=x` and a rejected
request ID all allocate zero.

### Unbounded, or delegated — say it plainly

| Thing | Owner | Status |
|---|---|---|
| concurrent connections | the framework | **bounded and configurable — `Limits.max_connections`, default 1024**, with `reserved_conns` (16) held back from admission so a shutdown always has room (WP47, Amendment 15). A connection past the budget is CLOSED, not queued. |
| accept queue / backlog | the OS | still not bounded by this framework — the listen backlog is the kernel's, and the framework's own refusal now arrives before it |
| inbound header COUNT | transport | **not bounded by this framework** — the header BLOCK's byte size is bounded and configurable (`Limits.max_headers`, WP36); the number of headers is not |
| request READ deadline | the framework | **bounded and configurable — `Limits.max_request_time`, default 30 s** (WP46, Amendment 13). One request's total time to ARRIVE; expiry closes the connection. Zero disables it. |
| write deadline, and any bound on a slow HANDLER | — | **still absent, deliberately.** The write deadline is a smaller version of the same patch and was not bundled with a security fix; a slow handler is the application's own time, and killing its connection would turn a slow page into a broken one. |
| middleware chain DEPTH | the application | ~100k on the default stack, and **exceeding it is a segfault, not a diagnostic** |
| response body size | the application | unbounded — you allocate it |
| a handler's own allocations | the application | unbounded |

**Therefore:** Druse bounds **its own per-request working memory**. It does
not bound the server. Any sentence that says "bounded" without naming which
perimeter is a sentence this ledger exists to prevent.

---

## 5. Corrections made by this freeze

Freezing claims means checking them, and two did not survive contact.

1. **`docs/middleware.md` — "a program that never calls `use` does not even
   link it."** False, and self-contradictory in its own sentence. Measured: 8
   symbols always link, because the ADR-019 guard and the miss chain sit on the
   shared dispatch path by design. Corrected to state the measurement.
2. **"byte-identical binary"** (plan WP22). Not false so much as **untestable**:
   five builds of an identical tree produced five distinct binaries, so the
   property fails for a tree compared against itself. Withdrawn in WP22
   Amendment 1 and replaced by the symbol-count claim (C-6). Recorded here so a
   future work package does not reintroduce it.

Both are the same failure mode the reference study predicted — prose has no
compiler, and drifts while every test stays green.

---

## 6. Mutation suite

Every control script re-run at this commit; all pass.

| Suite | Result |
|---|---|
| `check_wp3_mutations.sh` | 5 forbidden states rejected, 4 refactor controls accepted |
| `check_wp16_controls.sh` | 6 controls |
| `check_wp17_controls.sh` | 7 controls |
| `check_wp18_controls.sh` | 6 controls |
| `check_wp19_controls.sh` | 6 controls |
| `check_wp20_controls.sh` | 6 controls |
| `check_wp21_controls.sh` | 7 controls (two BUILD AND RUN faulting programs) |
| `check_wp22_controls.sh` | 7 controls (one `nm` measurement, one positive) |
| `check_wp23_controls.sh` | 7 controls (four are attacks; one positive) |
| `check_wp24_controls.sh` | 6 controls (one builds and runs the D-12.5 hazard) |

Plus the Phase-1 conformance and wire suites inside `build/check.sh`.

**Every Phase-2 suite carries a POSITIVE control**, because the lesson repeats:
an implementation that rejects everything passes every negative probe. WP22
control 6 (marking every line truncated), WP23 control 7 (a valid inbound ID
still honoured, and opt-in preserved) and WP24 control 6 (the docs and examples
must actually exist and build) are those halves.

---

## 7. Usage laboratory, re-run

The plan asked the honest question: *if a five-route CRUD service now needs 25
concepts instead of 14, that is a finding, not a footnote.*

Measured at this commit, both programs written from public documentation and
compiled with the pinned toolchain:

| Program | Concepts | Lines | Compiles |
|---|---|---|---|
| five-route CRUD, unguarded (the Phase-1 shape) | **14** | 48 | yes |
| five-route CRUD + auth + router + logging + request IDs | **23** | 65 | yes |

**The finding, stated as a finding.** Adopting everything Phase 2 shipped takes
a CRUD service from 14 concepts to **23** — `use`, `next`, `router`, `Router`,
`mount`, `bearer_token`, `unauthorized`, `logger`, `request_id`. That is +9,
and it is a real increase in what a reader must hold in their head.

**What makes it acceptable rather than alarming:** the unguarded program is
**still exactly 14**, unchanged from the Phase-1 measurement. Phase 2 costs
nothing you do not ask for — not in concepts, and (C-6, §4) not in binary
either. The growth is opt-in in the strict sense: it appears only in programs
that use the features.

**What it costs a beginner:** a guarded service is now a two-file idea — an app
and a router-building procedure — where before it was one flat `main`. That is
the honest price of route organisation, and the reason `web.group` was refused:
a closure-based group API would have hidden the same nine concepts behind
syntax rather than removing them.

One documentation friction was found by writing the lab program: `web.body`
takes `dst: ^$T`, not a type, and I wrote `web.body(ctx, New_Item)` from
memory. The compiler's message named the problem exactly ("Cannot assign
'New_Item', a type, to a procedure argument"), so the cost was one compile, not
a debugging session — but the docs could show the pointer form more prominently.

---

## 8. What Phase 2 deliberately did NOT do

Recorded so a later reader does not mistake absence for oversight:

* **No panic recovery.** Impossible, not unbuilt (ADR-020).
* **No `web.group`.** Refused in every phase (ADR-024).
* **No structured logging, levels, sinks or sampling.** Phase 4. A log ring or
  drop policy now would have put an unbounded queue behind a bounded-buffer
  claim.
* **No latency measurement in `logger`.** It needs a clock, and a clock needs
  an import every application would pay for.
* **No trusted-proxy handling or `X-Forwarded-*`.** Phase 4 (ADR-013).
* **No typed request-local state, and none is promised.** This is why the
  canonical auth pattern revalidates. It is recorded here as an OPEN QUESTION
  rather than a deferral: ADR-004 reserves `web.state` for application state,
  and research finding C-6 argues a request-scoped extension mechanism solves a
  problem this framework does not have. A later phase must DECIDE it; no
  document may assume it.
* **No stop procedure.** Phase 4; it will add public API.
* **No second handler shape, no `Middleware` type, no context bag.** G-01 and
  G-03.

---

## 9. Freeze conditions

* [x] `build/check.sh` exits 0 on the pinned toolchain.
* [x] 44 application + 2 test-support = 46, byte-identical to the signature
      snapshot.
* [x] Every new symbol carries a G-09 evidence row whose citations resolve.
* [x] Every mutation suite re-run and passing, each with a positive control.
* [x] Every "costs nothing when unused" claim measured with `nm` **and** a
      positive control — or withdrawn (§5).
* [x] Claim ledger: 9 claims, each with a negative control.
* [x] Lifetime ledger: 12 rows, gate-enforced.
* [x] Capacity ledger: fixed / dynamic / per-request / unbounded, with the
      unbounded column filled in honestly.
* [x] Usage laboratory re-run, and the concept growth reported as a finding.

Phase 2 is frozen. Growth from here is a Phase-3 decision, and every symbol
added to this surface carries the same evidence these twelve did.
