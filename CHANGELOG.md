# Changelog

All notable changes to Druse are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning is **not** semantic yet, because **there has been no release**. No
tag exists, and cutting one is an owner decision.

## [Unreleased]

Phase 1 is complete and its public contracts are frozen. What "frozen" means,
symbol by symbol with the evidence behind each, is in
`planning/phase-1-freeze.md`. Phase 2 is frozen (`planning/phase-2-freeze.md`)
and Phase 3 is under way; ledger growth in either is recorded as a numbered
freeze amendment, never as a snapshot refresh.

### Changed

- **`Allow` now names `HEAD` and `OPTIONS`** (audit R8). A route registered only
  for GET emitted `Allow: GET` while — measured on a socket — `HEAD` answered
  200 and `OPTIONS` answered 204. RFC 9110 §10.2.1 defines the field as the
  methods the resource *supports*, so the header described what an application
  had typed rather than what the server does, and a cache, a CORS preflight or a
  monitor choosing HEAD over GET was told a working method was unavailable. Such
  a route now emits `Allow: GET, HEAD, OPTIONS`. `HEAD` appears only where GET is
  registered (HEAD *is* the GET route); `OPTIONS` is unconditional. The frozen
  order becomes `GET, [HEAD,] POST, PUT, PATCH, DELETE, OPTIONS`, still
  registration-independent. **This reverses a recorded decision, and narrowly:**
  the original rejection bundled an alphabetical ordering — still rejected —
  with the listing itself, which was right. No public signature changed;
  `Method` remains the five registrable verbs, and the two are emitted as
  tokens rather than becoming enum members an application could never construct.

- **`Limits.max_json_nodes` bounds JSON structural cost** (audit J3/J4), default
  100,000 values plus object keys, `0` disables. Two well-formed bodies inside
  the 4 MiB `max_body` were measured at **588 MB of RSS** (1,398,101 empty
  objects into a 288-byte DTO) and **1.6–2.1 s of one Handler lane** (322,000
  object keys). `max_body` bounds bytes, and bytes are not what the decode costs
  scale with. At the default those same bodies cost **20 MB** and **50 ms**;
  10,000- and 25,000-key bodies are still served, within noise of unbounded. A
  breach is `413` with code `body_too_complex` — not `body_too_large`, since a
  client retrying by shrinking bytes has misread it. Recorded as Phase-1 freeze
  Amendment 38 and row 14 of the C-02 readiness matrix.

- **Control bytes are refused in a header field line** (audit H1), in both
  directions: a request carrying one is answered 400, and `web.set_header`
  refuses a value containing one. Previously `X-Test: a\x01b` was answered 200
  and an application echoing the value put the byte back on the wire. RFC 9110
  §5.5 defines field content as `SP / HTAB / VCHAR / obs-text`. HTAB and
  obs-text remain legal.

- **An absolute-form request target whose authority disagrees with `Host` is
  refused** (audit H2). `GET http://evil.example/x` with `Host: good.example`
  was answered 200 and the application read `good.example` — the half RFC 9112
  §3.2.2 says to ignore. Refused rather than repaired, matching the CL+TE
  disposition. `OPTIONS *` is exempt.

### Documented

- **Phase 3 is frozen** (WP38): **+6 symbols**, application ledger **44 → 50**
  (union 52), recorded in `planning/phase-3-freeze.md` and enforced by the new
  `build/check_phase3_freeze.sh`. The six are `route` (WP34),
  `app_with_state`/`state` (WP37) and `Limits`/`DEFAULT_LIMITS`/`limits`
  (WP36). **Nine work packages shipped zero public surface between them** —
  the benchmark harness, the allocation audit, the representation shootout, the
  radix index, conflict diagnostics, the path policy, automatic HEAD and
  OPTIONS, multi-parameter routes and the arena decision. At 5,000 routes
  dispatch is about **1.7 µs and flat**: the same at 5 routes as at 5,000.
  **The three ledgers are amended, not appended to.** The claim ledger gains
  C-10 with its own negative control; the lifetime ledger gains the two
  borrowed values Phase 3 introduced, one of which — application state — is the
  single row where the framework is **not** the owner; the capacity ledger's
  "4 MiB, fixed" row becomes three configurable rows.
  **Re-running every mutation suite was not ceremony: it found a control that
  had silently stopped working.** WP18's control 6 removed `mount`'s
  append-result guard and required the fail-closed tests to go red; at this
  commit it stayed green, because WP30's conflict detection now rejects the
  same application for a different reason. The test was strengthened to assert
  *which* failure it caught — and that still was not enough, because `mount`
  has four allocation guards on one path that emit the same diagnostic. The
  append guard is **not independently observable**, which is now recorded
  rather than implied, and the control pins what Amendment 1 actually promised.
  **Two measurements failed honestly and are recorded as failures.** `nm`
  cannot see the new symbols — they inline away and emit nothing *even when
  used*, which the positive control is how anyone knows — so no "costs nothing
  when unused" claim was made for any of them. Binary size cannot resolve the
  question either: the same commit measured twice differs by 4,080 bytes,
  because output size quantises at roughly a 4 KiB page. An earlier draft
  reported a "+4,768 byte cost" before the noise was quantified; that number
  was measurement, not cost, and the freeze records it as an error caught.
  **The usage laboratory was re-run and its instrument preserved.** Phase 2
  kept only the number, so this re-run had to reconstruct the programs — and
  could not reproduce "23" exactly (22 by textual count; the difference is the
  `Router` type, which a program need never name). Both programs and the
  counting rule now live in `experiments/11-usage-lab/`. The guarded CRUD
  service as Phase 3 would write it needs **23 concepts against a ceiling of
  25**: no breach, so the freeze proceeded under the ADR-029 delegation without
  stopping for the owner. `check_wp38_controls.sh` proves the gate would have
  stopped: pushing the lab program past 25 is rejected as a reserved matter.

- **Configurable limits** (Phase 3, WP36): **+3 symbols**, application ledger
  **47 → 50** (union 52), recorded as Amendment 12 of
  `planning/phase-1-freeze.md`. `web.Limits` is the application's byte budget —
  `max_body`, `max_request_line`, `max_headers` — `web.DEFAULT_LIMITS` is the
  package default **constant**, and `web.limits(&app, budget)` sets it. The
  shape is `core:net`'s `DEFAULT_TCP_OPTIONS` precedent, not a builder.
  **The defaults are the values already shipped:** 4 MiB is the cap Phase 1
  fixed, 8000 is the backend's own default for both text budgets. An
  application that never mentions limits behaves exactly as before — the
  property that makes shipping a public options type safe. This is the least
  reversible change in the phase, and the struct is three fields for that
  reason: every field is a promise kept for as long as the type exists, adding
  one later is cheap, and *tightening a default* would break traffic without
  breaking a build.
  **The budget belongs to the App, not to `serve`,** so `web.test_request`
  enforces the same numbers as a socket — a 413 in a test is a 413 in
  production (R-10). `serve` derives the backend's options from it at boot; no
  `Limits` value crosses the transport boundary.
  **`web.limits` after the first request rejects the application** fail-closed:
  the budget is read on the request path, and changing it mid-flight would give
  two clients different answers to the same body. That guard **sits beside**
  ADR-019/ADR-023 rather than replacing them, and a test asserts the older
  `use`-after-dispatch rejection still fires. A `Limits` with a zero field is
  rejected too: there is no unset state, so a forgotten field cannot be told
  from a deliberate one.
  **There are no timeout fields, and that is a finding rather than an
  omission.** The vendored server has no read or write deadline to configure —
  its options carry only the two text limits, and its request read still carries
  an unfinished-work comment asking for a timeout. Real deadlines are surgery
  inside the event loop, not a field, so `Limits` ships without them: adding a
  field later is an amendment, while shipping one that silently does nothing
  would be a lie with a version number on it. **No document claims Druse has
  configurable timeouts.**
  The derivation was **measured**, as the plan required, and the measurement
  does not distinguish the two shapes: a boot-resolved budget and a
  re-derived-per-request one produce **byte-identical** binaries (745,216 B,
  +472 B over the fixed-constant baseline) with zero allocations either way.
  What separates them is branch count — 0 added versus 3 — and the semantics
  behind it: a per-request derivation can discover a contradiction under load,
  which is the failure boot-time validation exists to move to boot. The
  amendment's reasoning is supported on the second ground and is unsupported on
  the first, and it says so.
  The capacity ledger's *"4 MiB, fixed, not configurable until Phase 3"* row is
  amended and two rows added (FINDING-C), and the claim ledger gains **C-10**
  with its own negative control. Freezing this also closed a hole in the freeze
  gate: the signature extractor read procedures, groups and types but **never
  constants**, so an exported constant's value could have changed with the
  frozen inventory unmoved.

- **Typed application state** (Phase 3, WP37): **+2 symbols**, application
  ledger **45 → 47** (union 49), recorded as Amendment 11 of
  `planning/phase-1-freeze.md`. `web.app_with_state(&state)` attaches ONE value
  to an application — a database pool, a config struct, a cache — and
  `web.state(ctx, App_State)` reads it back typed inside any handler or
  middleware. ADR-004 option A, delivered.
  **The call site has no type arguments,** which is what option A was chosen
  for: option B — a parametric `App(S)`/`Context(S)` — would have put a type
  parameter on every handler signature in every program. The declared price is
  a runtime assert instead of a compile error, and it is paid in the open:
  `state` asserts registration and then **exact `typeid` equality** before the
  cast. No subtyping walk, no "close enough" — casting a `^Config` to a
  `^Database` because both are pointers is the defect the `typeid` exists to
  make impossible. A failing assert aborts, which is the documented fault model
  (ADR-020), so you meet it on your first request rather than in production.
  **A nil state rejects the application fail-closed** (AMEND-1), through the
  ADR-019 mechanism rather than a new one. The App stores the **pointer**, so a
  handler mutates your value — and the value must outlive the App;
  `examples/07-app-state` teaches that as layout, both being locals of `main`.
  The `rawptr` is private: neither exported signature carries an untyped
  pointer, which is the narrowing G-03's own comment anticipated by name.
  Enforcing it exposed a hole in the check itself, closed in the same change —
  the exported-declaration scan never read a **multi-line** signature at all,
  so a `rawptr` parameter there would have passed.
  **There is no request-scoped state, and there will not be one** (ADR-028,
  option 1, ACCEPTED). C-6 found that Go's `context.WithValue` and Rust's
  `http::Extensions` exist for type-erased, dynamically-keyed state crossing
  library boundaries — which Druse does not have — so the finding *supports*
  G-03. The consequence is recorded rather than softened: the canonical auth
  pattern's revalidation cost stands until an ADR decides otherwise.

- **Route identity is public** (Phase 3, WP34): **+1 symbol**, application
  ledger **44 → 45** (union 47), recorded as Amendment 10 of
  `planning/phase-1-freeze.md` — the first amendment whose authority is the
  **ADR-029 delegation** rather than a direct owner decision, and it says so in
  those words. `web.route(ctx)` returns the **registered pattern** the request
  matched — `/users/:id`, never `/users/42` — or `""` when nothing matched.
  That distinction is the entire contract and it is a correctness rule, not a
  style one: route identity must be **low-cardinality** (C-2, the OpenTelemetry
  `http.route` convention), so a metric labelled with the path has one time
  series per user id and a log field labelled with the path carries user data
  wherever those logs go. An application that wanted the path already had
  `ctx.request.path`; what it could not obtain was the identity that is safe to
  label with.
  **The redaction rule is a gate assertion, not a convention.**
  `build/check_public_api.sh` §8b pins the accessor's shape, requires its body
  to be exactly `return ctx.private.route`, and requires **every** write to
  that slot to be the matched entry's pattern — because a behavioural test can
  only check the routes someone thought to write, while the assertion checks
  the assignment where the decision is made. It is the sibling of the check
  that keeps `Framework_Event` free of request-derived strings.
  The name is `route` and not `route_pattern` or `matched_route` (G-01): it is
  the same string `Framework_Event.route` carries, read from the same slot, and
  a test asserts they never diverge. A mounted route reports the **composed**
  pattern; a 404 and a 405 report `""`, because no route ran. The result is a
  view over App-owned storage valid until `destroy` — the single value
  reachable from a `^Context` that outlives its request, and the same exception
  the lifetime ledger already recorded for `Framework_Event.route`. **OQ-18 is
  closed.**
- **A duplicate route is no longer a silent one** (Phase 3, WP30): **zero new
  symbols**. WP4 D5 left a duplicate registration undiagnosed — the second
  route was stored, never matched, and nothing said so. Two routes registered
  for the same method and the same path shape now reject the application
  fail-closed: every request answers 500, `web.serve` refuses to start, and the
  diagnostic names the losing route. Decided under the ADR-029 delegation, and
  implemented through the ADR-019 mechanism that already existed rather than a
  second one — `Framework_Error` gains no member, because the enum names
  failures that reach an observer and an observer cannot be alive to see this
  one.
  **Parameter names do not distinguish routes:** `/users/:id` and `/users/:uid`
  are one pattern, and a `web.mount` prefix can compose a collision with a
  route registered directly. Nothing compares pattern text for any of this —
  the WP29 tree walks both spellings to the same node, so the occupied method
  slot *is* the conflict. Registration still returns void and still reports
  through the fail-closed mechanism, never a return value.

- **Phase 2 is frozen** (WP25): **zero new symbols**.
  `planning/phase-2-freeze.md` records the ledger diff (32 + 12 = **44**
  application, 46 union), and adds three ledgers Phase 1 did not have, each
  enforced by the new `build/check_phase2_freeze.sh`. The **claim ledger**
  holds nine strong promises the project already makes, each with its exact
  sentence, scope, implementation, positive test, **negative control**,
  environment, and — the column that does the real work — what it explicitly
  does **not** guarantee; a claim with no negative control does not freeze. The
  **lifetime ledger** promotes WP24's ownership table to frozen evidence. The
  **capacity ledger** states what is fixed, dynamic at registration, bounded
  per request, and — stated plainly — what remains **unbounded or delegated to
  the transport**: concurrent connections, accept backlog, inbound header
  counts and sizes, and read/write timeouts. Druse bounds its own per-request
  working memory; **it does not bound the server**, and no document may claim
  otherwise.
  Freezing the claims found two that did not survive contact: the middleware
  page claimed a program that never calls `use` "does not even link it" (false
  — eight symbols always link, by design, because the fail-closed guard sits on
  the shared dispatch path; the sentence also contradicted its own +2,424-byte
  figure), and the "byte-identical binary" requirement was untestable and had
  already been withdrawn in WP22. The usage laboratory was re-run: an unguarded
  five-route CRUD service still needs exactly **14** concepts, and one adopting
  middleware, routers, auth, logging and request IDs needs **23** — reported as
  a finding, not a footnote.
- **Examples, the canonical auth pattern, and the ownership table** (Phase 2,
  WP24): **zero new symbols**. Three new examples — `04-middleware`,
  `05-route-groups`, `06-authentication` — bring the compiled example set to
  six; all six are part of the compatibility contract and build in the gate.
  `require_auth` and `current_user` are **application code in the example**,
  not framework symbols: the framework supplies `web.bearer_token` and the
  application supplies its own typed gate and typed lookup. The example states
  its cost plainly rather than hiding it — **`current_user` revalidates the
  token on every call**, because a middleware cannot hand a typed value to a
  handler while `Context` is deliberately not an extension bag (G-03). Whether
  a later phase removes that cost is **undecided and not promised**: ADR-004
  reserves `web.state` for application state, not per-request values, and
  research finding C-6 argues against a request-scoped extension mechanism
  altogether. The workaround (call it once, pass the value down) is documented
  with it and does not depend on a future feature.
  A single canonical **ownership table** now answers the same four questions —
  owner, valid until, may it escape, who cleans up — for every value an
  application can touch, replacing the same rule restated across a dozen doc
  comments; the docs gate requires the table, its four columns, and a row for
  each Phase-2 borrowed value. Audit recommendations **R-3** (never copy an
  `App` or `Router` — the `strings.Builder` analogy), **R-4** (the zero-value
  `App` is not usable) and **R-10** (exactly one server per process, no stop
  until Phase 4) are stated and gate-enforced. The pay-for-what-you-use table
  is extended with measured Phase-2 costs, including a stated ~100-byte noise
  floor: `header`/`bearer_token` are free (+152), `request_id` nearly so
  (+456), and the middleware mechanism is the one real cost (+8,448), paid
  only by applications that call `use`.
- **Fault behaviour** (Phase 2, WP21): **zero new symbols** (ADR-020). Two
  different failures are now documented as the two different things they are.
  A handler that returns **without committing a response** is finalized by the
  response driver to the standardized `internal_error` 500 — identically under
  `web.serve` and `web.test_request`, identically under `web.app()` and
  `web.bare()`, in default *and* `-o:speed` builds, repeatably, and carrying no
  detail about the request. A handler that **faults** — panic, failed
  assertion, out-of-bounds index, nil dereference, divide-by-zero — **aborts
  the process**; run Druse under a supervisor.
- **`recovery` will never exist** (ADR-020). Odin has no recoverable panic:
  `context` is an implicit by-value parameter, so `web.app()` cannot install a
  fault hook on its caller's behalf, and `bounds_check_error` is
  `proc "contextless"` and cannot consult a hook even in principle. The earlier
  promise of "recovery middleware, default-on in `web.app()`" was not hard but
  impossible, and it has been withdrawn from `README.md`,
  `docs/quick-start.md` and `docs/canonical-patterns.md` rather than left
  standing as a default that would never be delivered (G-08). The Phase-4
  "last-gasp responder" is a different thing and must never be called recovery.

### Added

- **The `request_id` middleware** (Phase 2, WP23): `web.request_id`, a
  `Handler` value, **opt-in**. Every request gets a correlation ID; a
  client-supplied `X-Request-Id` is honoured **only** if it matches charset
  `[A-Za-z0-9._-]` and length 1..64. Anything else — too long, empty, a space,
  a semicolon, a control byte, non-ASCII, and above all **CR or LF** — is
  **discarded** and replaced with a generated ID: never echoed, never logged,
  never readable by a handler, and never repaired. This closes CR/LF response
  header injection **by construction** rather than by a sanitiser. The
  effective ID is read through the existing `web.header(ctx, "X-Request-Id")`
  — no second symbol, per ADR-027, which closed the `request_id_value`
  contingency — and appears on **every** committed response including a 404, a
  405 and the standardized 500, exactly once. The ID is unique but
  **deliberately not unguessable** (a per-process ASLR-derived seed plus a
  counter) and must never be used for authentication. No allocation and **no
  new dependency**: `web`'s five pinned direct imports are unchanged, because a
  cycle counter or a clock would each have added one for a value that is
  explicitly not a secret. Application ledger 43 → 44 (freeze Amendment 9).
- **The `logger` middleware** (Phase 2, WP22): `web.logger`, a `Handler` value,
  **opt-in** — `web.use(&app, web.logger)`; there is no default-on logging
  (G-08). One `.Info` line per request, written through `context.logger` after
  the chain unwinds, carrying exactly three fields: method, **registered route
  pattern**, and **committed** status. It never logs the raw path, the query
  string, a header name or value, a body byte, or a captured path-parameter
  value — asserted on the exact bytes of the line, not described. A miss logs
  `-` for the route rather than falling back to the path, and a request whose
  chain committed nothing logs `-` for the status rather than reporting a
  response the logger never watched being sent (the driver's 500 finalization
  happens after dispatch returns; that failure reaches `web.observe`, which
  does see it). Misses are logged, so 404s and 405s are visible. The line is
  composed in a fixed stack buffer that no response can alias: a route field
  too long is cut on an escape boundary and **marked** `...[truncated]` — never
  grown silently, never dropped silently — and the status still follows the
  mark. CR, LF, backslash and control bytes are escaped, so a route pattern
  cannot forge a second log record. It imports **nothing**: not `core:log`
  (measured at ~37 KiB added to every application, referenced or not) and not
  `core:fmt`; an application that never names `web.logger` links **zero** logger
  symbols, proven with `nm` against a positive control (an application that does
  use it links six). Byte-identity of the binary is deliberately **not** claimed:
  the pinned toolchain does not build reproducibly, so that property fails for a
  tree compared against itself (plan amendment, 2026-07-20). No levels, sinks, sampling, structured
  fields or latency measurement — those are Phase-4 observability, and a log
  ring or drop policy would put an unbounded queue behind a bounded-buffer
  claim. Application ledger 42 → 43 (freeze Amendment 8).
- **Typed framework-error observer** (Phase 2, WP20): `web.observe`,
  `web.Framework_Event` and the now-public `web.Framework_Error`. One observer
  per application receives a typed event — kind, method, registered route
  pattern, committed status, offending typeid — for every framework-detected
  failure, on both transports, exactly once. The event carries **no message
  and no request path**: route identity is low-cardinality by construction,
  and an observer receives the event by value and nothing else, so it can
  neither respond nor read request bytes. Installing one changes no response.
  Application ledger 39 → 42 (freeze Amendment 7).
- **Request header lookup** (Phase 2, WP19): `web.header` and
  `web.bearer_token`. Pure lookups — `(value, ok)`, no automatic response,
  nothing ever logged, values are request-lifetime views. Names are
  case-insensitive (ASCII folding); duplicates: first occurrence wins; an
  empty value is present. `bearer_token` parses RFC 6750 strictly and returns
  the token verbatim — a sloppy `Authorization` is rejected, never repaired.
  `web.test_request` gains an optional `headers` parameter (`"Name: value"`
  lines), so header-driven code is testable without a socket. Application
  ledger 37 → 39 (freeze Amendments 5–6).
- **Route organisation** (Phase 2, WP18): `web.Router`, `web.router` and
  `web.mount`. A Router accepts the same `use` and the same five registration
  verbs an App does (it embeds an App — no new forms, no mutated signatures),
  and `mount(&app, "/prefix", &r)` attaches every route at prefix + pattern
  verbatim. Chains compose outermost-first: app globals, each enclosing
  router, the handler. Route-level middleware is a one-route Router
  (ADR-025 B). Fail-closed: an invalid prefix, a mis-ordered router, a
  mounted-router write, or a second mount rejects the application with a
  diagnostic. There is no `web.group`, ever (ADR-024). Application ledger
  34 → 37 (freeze Amendment 4).
- **Middleware** (Phase 2, WP17): `web.use` and `web.next` — onion execution
  with exact reverse unwind, total short-circuit, and a monotonic per-request
  cursor (a second `next()` is a no-op; the handler runs exactly once).
  App-level middleware observe automatic `404`/`405` responses, under
  `web.bare()` too. **Ordering is enforced fail-closed**: `use` after any
  registered route — or after the first dispatched request — rejects the
  application (every request answers `500`, `web.serve` refuses to start, and
  the diagnostic names the unprotectable pattern). Chains are flattened at
  registration; dispatch through a five-middleware chain allocates zero bytes.
  Application ledger 32 → 34 (freeze Amendment 3).

- A working bootstrap HTTP server: `web.serve(&app, port)` binds a real port
  behind a private transport boundary.
- Routing with static and `:param` segments, at most one parameter per pattern,
  static routes taking precedence over parametric ones, and per-method
  isolation.
- Automatic `404`, and `405` with an exact `Allow` header.
- Path and query extractors — `path`, `path_int`, `query`, `query_int`,
  `query_int_or` — that commit a standardized `400` on bad input, so handlers
  check a bool and return.
- JSON request body binding via `web.body`, with a fixed 4 MiB cap and a
  request-lifetime arena for decoded data.
- JSON, text and no-content responses, and five error responders.
- A standardized error envelope covering ten Phase-1 codes.
- In-memory testing with `web.test_request`, reaching real routing with no
  socket and no port.
- HTTP/1 conformance work: ambiguous and malformed framing is rejected and the
  connection closed, proven by a raw-wire corpus.
- `LICENSE` (MIT), `SECURITY.md`, `CONTRIBUTING.md` and this changelog.

### Fixed

- Two remotely triggerable crashes and one request-smuggling vector, found by
  the Phase-1 transport conformance work and fixed in the vendored backend
  before any release. The patches are recorded in `vendor/odin-http/VENDOR.md`
  and the corpus that proves them is in `tests/wp9-wire/`.

### Public surface

**32 application symbols + 2 test-support symbols = 34, frozen.** The build
compares the compiler's own exported inventory — every signature, struct field,
enum member and enum backing type — against `build/phase1-public-signatures.txt`,
and the direct import set against `build/phase1-direct-dependencies.txt`.
Changing any of it requires a spec amendment.

Internals stay replaceable: the linear route table, the request arena and the
vendored backend are implementation and may be rewritten as long as the
observable contracts hold.

### Known limitations

Deliberate, documented, and each assigned to a later phase in
`planning/roadmap.md`:

- no middleware, route groups or typed application state;
- no request header lookup;
- no shutdown or stop — `web.serve` blocks until the process is signalled;
- no configurable limits or timeouts;
- only one server per process;
- no TLS, and no trusted-proxy handling;
- no path normalisation, no percent-decoding, no multi-value query access;
- `web.test_request` cannot carry a request body, so body-binding handlers
  cannot be exercised in memory;
- `HEAD` and `OPTIONS` are not supported;
- panics abort the process — Odin has no recoverable panic.

Druse is usable for building and testing a JSON API. It is **not** hardened
for unattended production exposure, and this changelog does not claim otherwise.
