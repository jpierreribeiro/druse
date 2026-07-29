# Druse — Odin fit audit

**Verdict: `ODIN_NATIVE_WITH_FRICTION`.**

Audited at `a7d2e9e` (Phase 1 frozen, WP11 merged), toolchain
`dev-2026-07-nightly:819fdc7`. Baseline gate green: `PASS=10 FAIL=0 SKIP=0`,
ledgers 32 + 2 = 34. No production file was changed by this audit; every
prototype was built in `/tmp` and discarded.

---

## 1. Summary for the owner

The question was whether Druse is genuinely an Odin framework or a Go/Rust/JS
framework wearing Odin syntax. **It is genuinely Odin.** The evidence is not
stylistic impression — it is that the shapes Druse chose are the same shapes
Odin's own standard library chose, verified against the pinned compiler's
`core/` sources.

The clearest example is the one that looked most like a flaw. `App` is
copyable by the language but must not be copied. I reproduced the failure: copy
the app, destroy both, and the program segfaults, with no compiler warning. That
sounds damning until you run the same experiment on `core:strings.Builder` —
Odin's own standard library type — which **segfaults identically**. Druse did
not invent a hazard; it inherited the ownership model Odin actually has. A
framework that tried to "fix" this would be the un-Odin one.

What genuinely rubs:

* You cannot unit-test a JSON body handler without a socket. `test_request`
  takes only a method and a path, so any handler calling `web.body` always sees
  `invalid_json` in tests. This is the one friction that will bite real users.
* The project's supporting apparatus has grown to the same size as the project.
  The gate is 3,319 lines against 3,273 lines of framework code, `context.odin`
  is 5.3 comment lines per code line, and about a third of the gate pins
  implementation *text* — exact parameter names, exact declaration lines, exact
  file sets — so honest refactors fail it.
* Several comments still describe shipped features as unbuilt stubs. The header
  of `web/extract.odin` says body binding "is still the WP7 stub"; `web.body` is
  implemented 285 lines below it in the same file.
* Running two servers is silently wrong: the transport keeps package-level
  globals, so a second `serve` re-points dispatch at the second app's routes
  while the first server is still answering.
* There is **no LICENSE file**. A public repository without one is "all rights
  reserved" by default, which blocks adoption regardless of code quality.

**No P0 was found** — no memory-corruption or security defect in the shipped
surface. None of the above requires changing a frozen Phase-1 contract.
Recommendations are in §10; the three that should happen before Phase 2 are the
licence, the stale-comment correction, and a decision on how test-support grows.

---

## 2. What is already genuinely Odin

Claims below are labelled by evidence class: **[STATED]** by the maintainers,
**[CORE]** observed in the pinned toolchain's `core/`, or **[INFERENCE]** mine.

### 2.1 Procedural, no simulated OOP

Odin's FAQ is explicit: *"We believe that data and code should be separate
concepts; data should not have 'behaviour'. Use a procedure."* **[STATED]**
Druse has no methods, no builders, no fluent chains, no interfaces. Every
operation is a free procedure taking its subject as the first argument:
`web.get(&app, ...)`, `web.ok(ctx, value)`. This is not a near-miss; it is the
stated rule applied literally.

### 2.2 `app()` / `destroy(&app)` matches the standard library's own pattern

The construction/teardown pair was worth checking rather than assuming, because
it is the API's most visible shape. In `core/` **both** forms exist and are
deliberately paired **[CORE]**:

* value-returning constructor: `strings.builder_make` (`core/strings/builder.odin:37`)
* pointer-taking initializer: `strings.builder_init` (`:118`)
* destructor mirroring the stem, taking a pointer: `strings.builder_destroy` (`:217`)

`web.app() -> App` plus `web.destroy(&app)` is exactly the `builder_make` /
`builder_destroy` shape. **[INFERENCE]** The rule that actually holds in core is
not "always return by value" but "the destructor mirrors the constructor's name
and takes a pointer" — which Druse follows.

### 2.3 Omitting `#optional_ok` is the core-aligned choice, not a quirk

ADR-002 forbids `#optional_ok` on value-producing extractors, so dropping `ok`
is a compile error. I checked whether that matches core practice: `#optional_ok`
occurs **43 times across all of `core/`**, against roughly 15,075 procedure
declarations **[CORE]**. It is reserved for lookups whose failure is ordinary and
whose zero value is safe (`slice.min`, `lru.get`, `bit_array.get`). Operations
that can fail for an interesting reason — everything in `net`, `os`, `bufio`,
`encoding` — deliberately force the caller to bind the result.

A failed extraction commits a 400. That is an interesting failure. Omitting the
directive is the core-consistent decision, and it is the reason this mistake is
caught at compile time:

```
$ odin build …
Error: Assignment count mismatch '1' = '2'
	id := web.path_int(ctx, "id")
	^
```

### 2.4 One canonical way, no aliases

FAQ: *"Minimal: there ought to be one way to write something"* and *"A huge
aspect of the design of Odin is to minimize (not eliminate) the possibility of
dialects."* **[STATED]** The 34-symbol ledger contains no synonym pair. `ok` and
`created` are exact delegations to `json`, proven byte-identical by
`tests/wp6-internal/wp6_internal_test.odin::wp6_ok_is_byte_identical_to_json_ok`
— convenience without a second dialect.

### 2.5 Naming

Ada_Case types, snake_case procedures, SCREAMING_SNAKE constants. Verified
against core, where the convention holds at ~84% for structs and ~90% for enums
by raw count, and effectively ~100% once C/OS/file-format bindings that
intentionally mirror foreign identifiers are excluded **[CORE]**. Druse
complies without exception.

### 2.6 Small core, dependencies out of core

FAQ, on why things are missing from the standard library: *"when it is complete,
it will remain small"* **[STATED]**. Druse's instinct to keep the public
surface at 34 symbols and push middleware, uploads and OpenAPI outward is the
same instinct, applied at framework scale.

Worth recording plainly: **`core:net/http` does not exist**, neither in the
pinned toolchain nor in the current official package index. `core/net/` is
Berkeley sockets, DNS and URL parsing; `core/nbio/` is a non-blocking IO event
loop. Neither contains HTTP **[CORE]**. Phase-5 planning must treat the official
adapter as an unscheduled hypothesis, not a pending delivery.

### 2.7 Costs are visible and pay-for-what-you-use

Measured on the lab programs (debug builds, bytes):

| Program | Size | Delta |
|---|---|---|
| hello (text only) | 868,016 | baseline |
| + JSON responder | 908,776 | +40,760 |
| + `path_int` | 913,312 | +4,536 |
| + query extractors | 913,376 | **+64** |
| + JSON body binding | 1,039,016 | +171,000 |
| full CRUD | 1,054,136 | +186,120 |

The extractors are essentially free because they allocate nothing and return
views. The two large numbers are `core:encoding/json` marshal and unmarshal —
the cost of the standard library facility being used, not framework overhead.
The test-support machinery links only when `test_request` is called, and the
backend only when `serve` is reachable (WP11 measured 0/11 and 0/7 symbols
respectively).

**Phase-2 additions (WP24 measurement, debug builds, bytes).** Same method,
against a hello-world baseline built from the same tree:

| Program | Size | Delta vs baseline | Delta vs previous row |
|---|---|---|---|
| hello (text only) | 876,616 | baseline | — |
| + `use` / `next` (one no-op middleware) | 885,064 | +8,448 | +8,448 |
| + `header` / `bearer_token` in the handler | 885,216 | +8,600 | **+152** |
| + `request_id` | 885,520 | +8,904 | +456 |
| + `Router` / `mount` | 889,488 | +12,872 | +3,968 |
| + `logger` | 889,472 | +12,856 | +4,408 |
| + `request_id` **and** `logger` | 889,968 | +13,352 | — |

**The noise floor is ~100 bytes and it is stated rather than hidden.** Three
builds of the IDENTICAL baseline tree produced 876,616 / 876,552 / 876,544
bytes: this toolchain does not build reproducibly (see `planning/phase-2-plan.md`
WP22 Amendment 1). Any delta below ~100 bytes in this table means "no
measurable cost", not a precise figure.

Reading the table:

* **`header` and `bearer_token` are free** (+152, at the noise floor). They
  allocate nothing and return views over headers the transport had already
  materialised — WP19 turned an existing cost into a used one rather than
  adding one.
* **`request_id` is nearly free** (+456) because it imports nothing: no clock,
  no CSPRNG, no formatter. That number is the whole reason the ASLR-seed design
  was chosen over `base:intrinsics` or `core:time`.
* **The middleware mechanism is the one real cost** (+8,448), paid once by any
  application that calls `use` at all, and **not paid** by one that never does.
* **`logger` costs +4,408 when used and 0 when not** — an application that
  never names `web.logger` links zero of its symbols, proven with `nm` and a
  positive control in `build/check_wp22_controls.sh`.

---

## 3. Concrete frictions

### F-1 — `test_request` cannot carry a body, so body handlers are untestable in memory

**Classification: FRICTION, P1, PHASE_2.**

`test_request :: proc(a: ^App, method: Method, path: string) -> Recorded_Response`
has no body and no headers parameter. Reproduced:

```odin
web.post(&app, "/users", create)          // create calls web.body
res := web.test_request(&app, .POST, "/users")
// -> status=Bad_Request
//    body={"error":{"code":"invalid_json","message":"Request body must be valid JSON"}}
```

There is no way for a user to reach the success path of a body-binding handler
without opening a socket. The framework's own tests reach it only by *copying
`web/*.odin` into a throwaway package* (`build/check.sh:104`), which a user
cannot do for their own handlers.

The repository is honest about this — `tests/wp7-public-surface/contract_test.odin:65`
states the signature "is frozen at method + path" and `:80` marks the canonical
body shape "Unreachable via `test_request`". So this is a known, documented
limitation rather than a hidden defect. It is nonetheless the single friction
most likely to be felt by a real user, because body binding is a headline
Phase-1 feature.

**Not a CORRECTION**: nothing is incorrect, and no frozen contract is violated.
It is a capability gap whose resolution belongs to the first Phase-2 WP that
needs it. See §10 R-2 for the recommended shape.

### F-2 — Supporting apparatus is as large as the framework

**Classification: FRICTION, P2, PHASE_2.**

| | Lines |
|---|---|
| Framework (`web/`, `web/testing/`, `web/internal/`) | 3,273 |
| Gate (`build/check*.sh`) | 3,319 |

Ratio 1.01. `build/check_public_api.sh` alone is 1,151 lines. Comment density in
`web/`:

| File | Non-blank | Comment | % |
|---|---|---|---|
| `context.odin` | 114 | 96 | **84%** |
| `app.odin` | 119 | 95 | **79%** |
| `headers.odin` | 57 | 40 | 70% |
| `test_support.odin` | 112 | 79 | 70% |
| `request_arena.odin` | 84 | 55 | 65% |
| `errors.odin` | 632 | 303 | 47% |
| `dispatch_match.odin` | 313 | 150 | 47% |

Expressed as comment-to-code ratio, `context.odin` is **5.33:1** (96 comment
lines to 18 of code) and `app.odin` is **3.96:1** (95 to 24). Across `web/` the
ratio is 1.20:1 — 1,631 comment lines to 1,360 of code — with **150 `WP<n>`
references and 41 `ADR-nnn` references** in comments.

The distribution is inverted: the two files with the *least* logic
(`context.odin`, `app.odin`, both nearly pure declarations) carry the most
commentary, while the two with the most actual logic — `web/testing/recorder.odin`
(0.46:1) and `web/internal/transport/odin_http_adapter.odin` (0.45:1) — carry
the least. Much of the bulk is *construction history* rather than explanation of
the code as it stands; `dispatch_table.odin:9-18` and `request_arena.odin:7-14`
are near-identical ten-line essays making the same argument about why a
subpackage was rejected.

This is a real cost and also a real asset: the reasoning is preserved and it is
genuinely good reasoning. The judgement is not "delete the comments" but that the
ratio should stop growing, that the argument should live once in an ADR rather
than twice in production source, and that the files carrying real logic deserve
more explanation than the files carrying declarations. **[INFERENCE]**

### F-3 — About a third of the gate pins implementation text, not contract

**Classification: FRICTION, P1, PHASE_2.**

The gate is 3,331 lines against 1,360 lines of framework code (2.4:1). Only
`odin check` / `odin test` / `odin doc` / `nm` are semantic; the rest is textual
pattern matching against sources. The following all fail on **behaviour-preserving
refactors**:

| Refactor | Fails at | Why |
|---|---|---|
| rename the param `res` → `response` in `response_commit` | `check_public_api.sh:705` | asserts the exact declaration line |
| rename the param `a` → `app` in `dispatch` | `check_public_api.sh:763` | exact line; `check_wp3_mutations.sh:135` then reports a *misleading* "mutation was ACCEPTED" because its `sed` no longer matches |
| rename the param `name` → `key` on `web.query` | `check_public_api.sh:845-861` | six exact extractor declaration lines |
| split the 705-line `errors.odin` | `check_public_api.sh:306-314`, `:874-882` | permitted filenames are an exact set, and the json-importer set is pinned by filename |
| rename `odin_http_adapter.odin` | `check_public_api.sh:349-357` | the natural first step of swapping the backend |
| move `Status` out of `respond.odin` | `check_docs.sh:157,164` | the **docs** checker awks that specific file |
| change the Quick Start port to 3000 | `check_docs.sh:263` | greps for `web.serve(&app, 8080)` |
| reformat `destroy` in `app.odin` | `check_g11_teardown.sh:145-149` | a three-line exact-whitespace Python match |

Two deserve separate mention. The vendor security patches are asserted by
**code-shape greps** (`check_public_api.sh:1105-1113`, e.g.
`grep -qE 'if len\(token\) != 0 \{'`): a correct re-application written as
`if len(token) > 0 {` fails, while an unrelated matching line elsewhere in the
file satisfies it. The real evidence is the raw-wire corpus, so these greps add
fragility without assurance. And `check_public_api.sh:1144` asserts on the *text
of its own caller* (`build/check.sh`).

The ledger diff, the `odin doc` signature snapshot, the compile probes and the
mutation suite are genuinely strong and mutation-verified — that part should not
be touched. The problem is the text-pinning third, made worse by failure messages
framed as policy violations ("this requires a spec amendment, not a snapshot
refresh"), so a maintainer doing a legitimate rename is accused rather than
informed. That is how a gate stops teaching and starts obstructing.

### F-7 — The transport keeps package-level globals; two servers cross-wire

**Classification: DESIGN_RISK, P1, PHASE_4 (documentation in PHASE_2).**

`web/internal/transport/odin_http_adapter.odin` holds
`g_server: ^http.Server` (`:26`) and `g_config: Config` (`:29`), assigned at
`:42` and `:45`. Consequences, verified by reading:

* A second `serve(&app2, 8081)` on another thread **overwrites `g_config`**.
  In-flight requests on the *first* server then dispatch through the second
  app's route table and handlers — port 8080 answered by app2's routes. There is
  no guard, no error return, and `web.serve`'s doc comment does not warn.
* `g_server = &s` stores the address of a **stack local of `serve`** (`:44-45`).
  After `http.serve` returns at `:73`, `g_server` briefly points into a dying
  frame. Reads and writes are plain, not atomic, although the comment at `:79-81`
  describes `request_stop` as "idempotent and thread-safe" — the *backend's*
  shutdown is thread-safe; the pointer load is not.

Not P0: reaching it requires an application to deliberately start two servers on
two threads, which nothing in Phase 1 encourages or documents. The source
comment (`:21-24`) acknowledges the single-server assumption; nothing enforces
it.

Related and separate: **there is no public stop or shutdown at all**. `serve`
"blocks until the server stops" with no documented way to make it stop; a Phase-1
application's only exit is a signal. That is stated Phase-4 scope and is a
legitimate limitation — but the `serve` doc comment should say so.

### F-8 — Response-buffer safety rests on six hand-written guards

**Classification: DESIGN_RISK, P1, PHASE_2.**

Three request-local scratch arrays on `Context_Internal` — `allow_buffer`,
`response_headers`, `error_buffer` (`web/context.odin:78, 91, 109`) — are
**aliased by the committed response**. `response_commit` does not protect them.
Safety rests entirely on six independently hand-written `if committed { return }`
guards placed *before* each buffer write (`respond.odin:71`, `:124`,
`errors.odin:50`, `:290`, `:489`, `:512`).

`errors.odin:273-278` documents exactly why: writing before consulting the guard
would silently rewrite bytes the first response still points at, yielding a
response that reports status X while serving body Y. All six are correct today.
The invariant is *conventional, not structural* — a seventh responder added in
Phase 2 that writes scratch before checking `committed` reintroduces the bug, and
no gate check would catch it.

### F-9 — Comments assert that shipped features are still stubs

**Classification: CORRECTION (comments only), P1, requires a separate small WP.**

These state something **false about the current code**. Verified by reading:

| Location | Claims | Reality |
|---|---|---|
| `web/extract.odin:1-2` | "body binding is still the WP7 stub" | `web.body` is implemented at `:287` — same file |
| `web/errors.odin:82-85` | responders "stay inert stubs"; no generic renderer, no envelope type, no code enum | all four live at `:31-62`, `:511`, `:472`, `:402` |
| `web/internal/transport/boundary.odin:13-14` | "WP8 RED: `serve`/`request_stop` are stubs" | implemented at adapter `:41`, `:82` |
| `web/app.odin:73-74` | error bodies "EMPTY until WP6" | constants at `errors.odin:427-436` |
| `web/app.odin:121-122` | "no production transport or allocator to release" | WP7 and WP8 shipped |
| `web/context.odin:48-49` | "no allocator wired yet" | contradicted by `request_arena` at `:123` |
| `web/app.odin:100-108` | — | the same WP4 paragraph appears **verbatim twice** |
| `web/test_support.odin:71-106` | — | numbered steps run 1, 2-3, 4, 5, **7** |

I did **not** fix these. They live in production `.odin` files, and this PR is
documentation-only by mandate. They are unambiguous, behaviour-free, and reopen
no ADR, so they belong in a small dedicated correction WP before Phase 2 (R-8).

### F-10 — Per-request work that is provably unnecessary

**Classification: FRICTION, P1/P2, PHASE_3.**

* **The inbound header array is built and never read (P1).** `serve.odin:129-130`
  allocates `[]Header_Pair` and copies every inbound header into it. Nothing in
  `web/` reads `ctx.request.headers` — Phase 1 ships no header accessor by
  design, and `check_public_api.sh:731` forbids one. Every request with headers
  therefore pays an allocation plus N struct copies to populate a field no
  Phase-1 code path can observe. Deferring it is a pure internal change with
  **zero public effect**.
* **Static response headers are cloned every request (P2).**
  `response.odin:164-166` states that every name and value is a static string,
  yet `odin_http_adapter.odin:186-189` and `recorder.odin:76-79` `strings.clone`
  both halves of every pair. Only the `Allow` *value* (a view into
  `allow_buffer`) genuinely needs copying.
* **`Header_Pair` and `transport.Header` are structurally identical**
  (`headers.odin:46-49` vs `boundary.odin:21-24`), but the one-way boundary
  forbids sharing the type, so each request pays two O(n) conversions
  (`serve.odin:125-134`, `:140-152`). This is the measurable price of ADR-009 as
  implemented — worth stating honestly, not worth reversing.

Registration-time allocation is already minimal and correct: one `make` on the
first route plus one `strings.clone` per route, freed once.

### F-4 — No licence, and no product-track files at all

**Classification: CORRECTION (non-code), P1, PHASE_2 or sooner.**

`LICENSE`, `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md` are all absent from
the repository root. The tree vendors MIT-licensed code (`vendor/odin-http`) and
correctly preserves that licence, but Druse itself grants no rights. Under
default copyright a public repository without a licence is "all rights
reserved": nobody may legally use it. **[INFERENCE, but the legal default is not
in dispute.]**

This blocks external adoption completely and independently of technical
quality. It requires an owner decision (which licence), not an engineering one.

### F-5 — Vendored backend carries five local patches

**Classification: FRICTION, P2, PHASE_4.**

`vendor/odin-http/VENDOR.md` records five local patches, all security-motivated
(WP9 framing and method-semantics fixes). Updating to a newer upstream commit
requires re-applying all five by hand and re-running the wire corpus. The
adapter surface is small — 18 distinct `http.*` symbols touched in
`web/internal/transport/odin_http_adapter.odin` — so swapping backends is
plausible, and the boundary genuinely holds. But a patched vendor with no
upstreaming path drifts toward a permanent fork.

### F-6 — The zero value of `App` is safe but not useful

**Classification: FRICTION, P3, PHASE_2.**

Odin's philosophy is that *"the zero value should be useful"* **[STATED]**, and
core documents zero-value validity where it holds (`core/bytes/buffer.odin:12`,
`core/sync/primitives_atomic.odin:13`) **[CORE]**. Measured behaviour:

```odin
app: web.App                                  // never constructed
res := web.test_request(&app, .GET, "/x")     // -> 500 internal_error
web.destroy(&app)                             // survives, no crash
```

So a zero `App` is *safe* — `destroy` on it is a no-op and nothing corrupts —
but it dispatches to 500 rather than behaving like `bare()`. That is defensible
(a zero App has no routes and no policy), and it refutes the stronger worry that
the zero value silently behaves like `bare()`. It is undocumented, though, and
core's habit is to state the zero-value contract explicitly.

---

## 4. Principles matrix

| # | Principle | Favourable evidence | Friction | User impact | Maintainer impact | Confidence | Recommendation | Owning phase |
|---|---|---|---|---|---|---|---|---|
| 1 | Simplicity / readability | Hello World = 6 concepts, 9 lines | comment density (F-2) | low | medium | High | keep; cap comment growth | 2 |
| 2 | One canonical way | no aliases in 34 symbols; `ok`/`created` proven exact delegations | — | low | low | High | preserve in Phase 2 | 2 |
| 3 | Orthogonality | responders, extractors, routing independent | — | low | low | High | preserve | — |
| 4 | Procedural design | no methods anywhere; matches FAQ literally | — | low | low | High | preserve | — |
| 5 | Data separate from code | `Request`/`Context` are plain data; behaviour in procs | — | low | low | High | preserve | — |
| 6 | Predictable costs | extractors +64 B; pay-per-feature table §2.7 | body binding +171 KB (stdlib json) | low | low | High | document the json cost | 2 |
| 7 | Understandable ownership | one `defer web.destroy`; views documented | copy-then-destroy segfaults (§5) | medium | low | High | document; same as core | 2 |
| 8 | Allocators / context | arena is request-scoped; nothing global | no public allocator control | low | medium | Medium | Advanced API only | 3 |
| 9 | Useful zero values | zero `App` is safe | dispatches 500, undocumented (F-6) | low | low | High | document the contract | 2 |
| 10 | Data-oriented internals | contiguous route table, slice views, no map on hot path | linear scan (deliberate, Phase 3) | low | low | High | keep until measured | 3 |
| 11 | No ceremonial abstraction | no metaprogramming; `$T` only where core uses it | — | low | low | High | preserve | — |
| 12 | Clear diagnostics | dropped `ok` → exact line + message | copy hazard invisible (language limit) | medium | low | High | document | 2 |
| 13 | Fast iteration | examples build in ~2.2–2.5 s; in-memory tests 537 µs | full gate ~2 min | low | medium | High | watch gate growth | 2 |
| 14 | Small reproducible deps | 15 direct imports; one vendored MIT dep | five local patches (F-5) | low | high | High | upstreaming policy | 4 |
| 15 | Interop without leakage | zero backend symbols in public API | — | low | low | High | preserve | — |
| 16 | Joy / flow | CRUD = 14 concepts, 32 lines, one cleanup | F-1 blocks natural test flow | medium | low | Medium | fix F-1 | 2 |

---

## 5. Usage laboratory

Ten programs written from public documentation only, compiled with the pinned
toolchain. All prototypes lived in `/tmp/fit-lab` and are not versioned.

| # | Task | Result | Concepts | Lines |
|---|---|---|---|---|
| 1 | Hello World | compiles | 6 | 9 |
| 2 | JSON endpoint | compiles | 6 | 9 |
| 3 | `:param` route | compiles | 7 | 13 |
| 4 | optional query | compiles | 8 | 14 |
| 5 | JSON body | compiles | 7 | 13 |
| 6 | domain error mapping | compiles | 9 | 23 |
| 7 | small CRUD (5 routes) | compiles | 14 | 32 |
| 8 | test without sockets | **2 tests pass in 537 µs** | 8 | 22 |
| 9 | ownership mistake | see below | — | — |
| 10 | extractor mistake | see below | — | — |

Observations:

* A complete five-route CRUD service needs **14 framework concepts, 32 lines and
  exactly one cleanup call** (`defer web.destroy(&app)`).
* Mapping a domain error to HTTP is a plain `switch` over the application's own
  enum — the framework imposes no error type. This is the Odin-shaped answer and
  it required no framework concepts beyond the responders.
* Writing prototype 8, I guessed the expected JSON body from intuition and it
  matched byte-for-byte. That is a meaningful predictability signal, though a
  single author is not a user study (§13).
* Documentation was consulted for exactly one thing: whether `query_int_or`
  returns `(value, ok)` or just a value.

**Prototype 10 — dropping `ok`** (the mistake the design anticipates):

```
Error: Assignment count mismatch '1' = '2'
	id := web.path_int(ctx, "id")
	^
```

Exact line, exact cause. ADR-002 delivers precisely what it promised.

**Prototype 9 — copying the App** (the mistake the design cannot prevent):

```odin
app := web.app()
web.get(&app, "/users/:id", h)
copy_of_app := app          // compiles silently
web.destroy(&app)
web.destroy(&copy_of_app)   // Segmentation fault
```

No diagnostic, no warning, hard crash. **But the identical experiment on
`core:strings.Builder` produces the identical segfault**:

```odin
b := strings.builder_make(); strings.write_string(&b, "hello")
c := b
strings.builder_destroy(&b)
strings.builder_destroy(&c)   // Segmentation fault
```

This is Odin's ownership model, not a Druse defect. See §11 (REJECTED_CONCERN).

Operations impossible in Phase 1, discovered by trying: reading a request
header, setting a response header, sending a body or headers via `test_request`,
and any form of shutdown. All are documented as later phases.

---

## 6. Extractor contract comparison (question C)

Four designs were considered; two were compiled against the real frozen API.

| Design | Handler lines | Imports | Envelope consistency | Can forget to respond? |
|---|---|---|---|---|
| **1. Current** — extractor commits the 400 | **5** | 1 | guaranteed identical across all apps | no — extractor already responded |
| 4. Fully explicit parse in handler | 7 | 2 | each app invents its own message | yes |

Designs 2 (extractor returns an error) and 3 (handler returns an error) were not
compiled: design 3 would change the frozen `Handler` shape (ADR-011) and design
2 collapses into design 4 in practice.

The current contract is *more* implicit, and that implicitness buys a real
property: every Druse service in the world returns the same
`invalid_path_parameter` envelope, with no effort. The explicit alternative
costs two lines per extraction and hands error-message design to every
application author.

The safety net is real and tested: a handler that returns without responding is
finalized to 500 rather than hanging
(`tests/wp8-internal/wp8_internal_test.odin::wp8_uncommitted_response_is_finalized_to_500`).

**Recommendation: keep the current contract.** ADR-002 and ADR-011 should not be
reopened — no materially superior alternative was found, and the compile-time
enforcement is stronger than the alternatives'.

---

## 7. Maintenance laboratory

What it costs to change the framework, traced concretely.

* **Adding a private helper to `web/extract.odin`**: compiles freely; the public
  ledger is unchanged, so the surface gate passes. Low friction.
* **Renaming a private field in `Context_Internal`**: `check_public_api.sh`
  asserts specific private identifiers exist, so a legitimate rename can fail the
  gate and require editing the checker in the same change. Medium friction, and
  the direction that worries me (F-3).
* **Adding a file to `web/`**: the checker permits an explicit list of filenames;
  a new file requires editing the gate. This was a deliberate WP4/WP7 decision
  and it is defensible, but it does not scale to Phase 2's middleware files.
* **Adding a test**: easy for public behaviour. For *internal* behaviour the gate
  copies `web/*.odin` into a throwaway package (`build/check.sh:104`) because
  Odin requires `@(test)` procedures to compile as part of the package under
  test. It works and it is cleaned up, but it is machinery a newcomer must
  understand before writing an internal test.
* **Gate runtime**: ~2 minutes, run on every push by the pre-push hook. Fine
  today; worth watching as phases add suites.

---

## 8. Ownership and costs

The contract in three sentences, which is itself evidence of fitness:

1. `App` is yours: create with `app()`, pass `&app`, destroy exactly once, never
   copy it.
2. Everything reachable from `ctx.request` is a view over transport memory —
   copy it if you want to keep it.
3. Everything you pass to a responder is copied or owned by the framework; you
   do not free anything.

Measured allocation behaviour: the extractors allocate nothing (hence the +64
byte cost of adding both query extractors); decoded body data lives in a
request-scoped arena released at request teardown; rendered response bodies are
owned by the internal `Response` and released after capture or write; route
patterns are cloned into the `App` at registration.

---

## 9. Phases 2–5 assessed against Odin fit

Classification per the audit scheme. No future signature is frozen here.

| Item | Phase | Class | Reasoning |
|---|---|---|---|
| `web.header`, `web.bearer_token` | 2 | **ODIN_NATIVE** | plain lookup procs returning `(value, ok)`; mirrors core lookup idiom |
| Recovery middleware default-on in `app()` | 2 | **ACCEPTABLE_WITH_GUARDRAILS** | must be lazily linked and absent from `bare()`; measure the cost |
| Request ID, logger | 2 | **ACCEPTABLE_WITH_GUARDRAILS** | keep out of the hot path; no global state |
| `web.use` / middleware chain | 2 | **NEEDS_PROTOTYPE** | the onion/`next` cursor is the single biggest foreign-abstraction risk in the roadmap |
| Onion post-`next` semantics | 2 | **FOREIGN_ABSTRACTION_RISK** | an unwind machine is exactly the "hidden control flow" Odin's exception FAQ argues against; prototype before committing |
| Groups / `mount` / prefixes | 2 | **ACCEPTABLE_WITH_GUARDRAILS** | flatten at registration so dispatch stays flat data |
| Typed error observer | 2 | **ODIN_NATIVE** | a closed event struct, never `any` — matches the no-`any` rule |
| Auth via `require_auth` + typed extraction | 2 | **ODIN_NATIVE** | avoids `user_data`/`map[string]any` entirely |
| Radix / compact router | 3 | **NEEDS_PROTOTYPE** | representation must follow measurement, not preference |
| Params without a map | 3 | **ODIN_NATIVE** | contiguous small storage is the data-oriented answer |
| Precomputed chains | 3 | **ODIN_NATIVE** | work moved to registration; classic Odin trade |
| Typed application state | 3 | **NEEDS_PROTOTYPE** | must not become a context extension bag |
| Configurable limits / timeouts | 3 | **ACCEPTABLE_WITH_GUARDRAILS** | an options struct with a package default constant, as `net.DEFAULT_TCP_OPTIONS` does — not a builder |
| Shutdown with deadline | 4 | **ODIN_NATIVE** | explicit lifecycle proc; currently absent entirely |
| Trusted proxies | 4 | **ACCEPTABLE_WITH_GUARDRAILS** | must preserve the original peer; ADR-013 still PROPOSED |
| CORS, secure headers, cookies | 4 | **ACCEPTABLE_WITH_GUARDRAILS** | candidates for an optional package rather than core |
| Uploads / multipart | 4 | **SHOULD_BE_OPTIONAL_PACKAGE** | temp files and lifetimes do not belong in a 34-symbol core |
| Static files | 4 | **SHOULD_BE_OPTIONAL_PACKAGE** | traversal/symlink/ranges is a security surface of its own |
| Observability | 4 | **ACCEPTABLE_WITH_GUARDRAILS** | must use low-cardinality route identity, per OpenTelemetry HTTP conventions — never raw paths |
| TLS in-process | 4/5 | **SHOULD_BE_OPTIONAL_PACKAGE** | do not assume the framework must terminate TLS; reverse-proxy termination is the common deployment and costs the core nothing |
| `core:net/http` adapter | 5 | **NEEDS_PROTOTYPE** | **the package does not exist** — treat as unscheduled |
| OpenAPI / auto-docs | 5 | **SHOULD_BE_OPTIONAL_PACKAGE** | layer over route info; never a generator requirement |
| Validation | 5 | **NEEDS_PROTOTYPE** | tag-based validation edges toward the type-system cleverness Odin avoids |
| WebSocket, HTTP/2, streaming | 5 | **SHOULD_BE_OPTIONAL_PACKAGE** | separate packages; each is its own protocol surface |
| Templates, DB integration | 5 | **REJECT** (for core) | belongs to the ecosystem; Odin has no official package manager by design |

---

## 10. Prioritised recommendations

Each states the concrete problem, the change, the cheaper alternative, and
whether it needs a human decision. **None changes a frozen Phase-1 signature.**

### R-1 — Add a LICENSE (P1, owner decision required)

*Problem:* no licence file; the repository is legally unusable by others (F-4).
*Change:* add `LICENSE` at the root; MIT is the low-friction choice and matches
the vendored dependency.
*Cheaper alternative:* none — this cannot be deferred past any public release.
*Risk:* choosing a licence is irreversible in practice.
*Owner:* pre-Phase-2 housekeeping. **Requires human approval (licence choice).**

### R-2 — Decide how test-support grows, before the first Phase-2 WP needs it (P1)

*Problem:* body-binding handlers cannot be tested in memory (F-1).
*Change:* adopt an **explicit procedure group**, the shape core uses for exactly
this situation — `strings.builder_make`, `net.dial_tcp`, `net.recv` are all
`proc{...}` groups **[CORE]**. A body-carrying variant added to a
`test_request :: proc{...}` group adds capability without creating a second
canonical name, which is what the no-aliases rule actually forbids.
*Alternatives considered:* extending the existing signature (breaks the frozen
symbol); a request-builder type (adds a lifetime and a second mental model);
enriching `Recorded_Response` (orthogonal — that is about responses, not
requests); leaving advanced tests internal-only (leaves users stuck).
*Recommendation:* procedure group. **Do not implement now** — reserve the
decision for the first Phase-2 WP that needs it, with a compile-cost measurement
and an explicit test-support ledger entry.
*Owner:* Phase 2, first WP touching test-support. **Requires human approval
(test-support ledger grows from 2).**

### R-3 — Document the ownership contract's sharp edge (P2)

*Problem:* copying `App` and destroying both segfaults with no diagnostic (§5).
*Change:* add a short, explicit statement to `docs/canonical-patterns.md` and the
`App` doc comment: never copy an `App`; it owns heap memory exactly like
`strings.Builder`, and destroying a copy is a double free. Naming the standard
library analogy is the useful part — it tells an Odin programmer they already
know this rule.
*Cheaper alternative:* doc comment only.
*Risk:* none.
*Owner:* Phase 2 documentation WP. No API change, no approval needed.

### R-4 — Document the zero-value `App` contract (P3)

*Problem:* a zero `App` is safe but dispatches 500, and this is unstated (F-6).
Core states zero-value contracts explicitly where they hold **[CORE]**.
*Change:* one sentence in the `App` doc comment.
*Owner:* Phase 2 documentation WP. No approval needed.

### R-5 — Budget for gate evolution in Phase 2 (P2)

*Problem:* the checker enumerates permitted filenames and specific private
identifiers, so legitimate refactors edit the gate (F-3), and the gate already
equals the framework in size (F-2).
*Change:* make the Phase-2 planning include an explicit WP for gate
restructuring — prefer deriving the permitted file set from the package rather
than listing it, keeping the *ledger* assertions exact.
*Cheaper alternative:* accept the edits and require reviewer attention on any
diff that touches a checker.
*Risk:* a more permissive gate is a weaker gate; this must not relax the
32+2 ledger assertions, which are the part that actually protects the freeze.
*Owner:* Phase 2. No API change.

### R-6 — Set a vendor upstreaming policy (P2)

*Problem:* five local security patches with no upstreaming path (F-5).
*Change:* attempt to upstream the five WP9 patches; record the outcome in
`VENDOR.md`; define who checks upstream for security fixes and how often.
*Cheaper alternative:* keep patching locally but add a scheduled review.
*Owner:* Phase 4, or earlier if a CVE lands. No API change.

### R-8 — Correct the stale "still a stub" comments in a dedicated WP (P1)

*Problem:* eight comment sites assert that shipped features are unbuilt (F-9).
The worst tells a reader that body binding is a stub in the very file that
implements it.
*Change:* a small correction WP touching comments only — no behaviour, no
signature, no ADR reopened — plus a doc-comment sentence for `serve` stating
that Phase 1 has no stop.
*Cheaper alternative:* fix opportunistically when each file is next touched;
rejected, because `extract.odin:1` actively misleads anyone reading the package
today.
*Risk:* touching production files requires the full gate to re-run; that is the
whole cost.
*Owner:* pre-Phase-2 correction WP. No approval needed beyond scheduling.

### R-9 — Make the response-commit invariant structural, not conventional (P1)

*Problem:* six hand-written guards are the only thing preventing a committed
response's aliased scratch buffer from being overwritten (F-8).
*Change:* when Phase 2 adds responders, route scratch writes through a single
helper that consults `committed` first, so a new responder cannot get the order
wrong; or add a gate assertion that every responder checks `committed` before
writing scratch.
*Cheaper alternative:* a prominent comment plus a review checklist item.
*Risk:* none to the public API — this is entirely internal.
*Owner:* Phase 2, first WP adding a responder. No API change.

### R-10 — Document the single-server constraint now, enforce it in Phase 4 (P1)

*Problem:* two concurrent `serve` calls cross-wire dispatch through package
globals (F-7).
*Change:* Phase 2 documentation states that exactly one server per process is
supported in Phase 1. Phase 4, which owns lifecycle, replaces the globals with
per-server state and adds the stop API.
*Cheaper alternative:* documentation only until Phase 4 — acceptable, since
triggering the bug requires deliberately starting two servers.
*Risk:* leaving it undocumented is the actual risk.
*Owner:* Phase 2 docs, Phase 4 implementation. **Phase-4 change will add public
surface (a stop procedure) — requires human approval then.**

### R-11 — Drop the per-request work that nothing reads (P2)

*Problem:* inbound headers are allocated and copied per request but unreadable
by any Phase-1 path; static response headers are cloned needlessly (F-10).
*Change:* defer inbound header materialisation until a header accessor exists
(Phase 2); mark static header pairs so they are not cloned.
*Cheaper alternative:* leave until Phase 3 benchmarking quantifies it.
*Risk:* none — internal only, no observable behaviour change. Must be measured
rather than assumed, per Phase-3 discipline.
*Owner:* Phase 2 (headers become readable) / Phase 3 (allocation work). No API
change.

### R-12 — Replace vendor patch greps with corpus assertions (P2)

*Problem:* the five security patches are verified by code-shape greps that a
correct re-application can fail and an unrelated line can satisfy (F-3, F-5).
*Change:* delete the greps; rely on `tests/wp9-wire/`, which is the real
evidence, and add an assertion that the corpus covers each patch's case.
*Cheaper alternative:* keep the greps and add a comment explaining they are a
tripwire, not proof.
*Risk:* removing a check feels like weakening; it is not, because the corpus
tests behaviour and the greps test spelling.
*Owner:* Phase 4 vendor-maintenance WP. No API change.

### R-7 — Cap commentary growth; move history to ADRs (P3)

*Problem:* `context.odin` 84% comment, `app.odin` 79%, much of it construction
history (F-2).
*Change:* when a file is next touched, move "why the plan changed" narration into
the relevant ADR and leave the rule the code implements. Do not do a sweeping
comment purge — the reasoning is valuable and a mass edit would risk deleting
the wrong things.
*Owner:* opportunistic, Phase 2 onward. No approval needed.

---

## 11. Concerns investigated and rejected

* **REJECTED_CONCERN — "`App` copyable-but-not-copyable is un-Odin."** The
  standard library's own `strings.Builder` has the same hazard with the same
  segfault, verified by execution (§5). Odin has no move semantics, no
  destructors and no borrow checking by explicit design **[STATED]**. The
  correct response is documentation (R-3), not a design change. Proposing RAII,
  a borrow checker or smart pointers here would import a foreign abstraction.
* **REJECTED_CONCERN — "the API is AI-shaped rather than human-shaped."** The
  project's guidelines do contain an explicit "AI-Friendly API Rules" section,
  which invited this suspicion. But its rules — one canonical name per
  operation, no aliases, no `any`-dependent overloads, every public procedure
  has a compiling example — are the same rules Odin's FAQ states for humans
  ("there ought to be one way to write something", "minimize the possibility of
  dialects") **[STATED]**. Measured human-facing result: CRUD in 14 concepts and
  32 lines. The two objectives coincided rather than conflicted.
* **REJECTED_CONCERN — "the zero value silently behaves like `bare()`."**
  Measured: it returns 500, not a `bare()`-style 404 (F-6). The stronger worry
  does not hold; only the documentation gap does.
* **REJECTED_CONCERN — "extractors that respond are too implicit."** Compiled
  comparison (§6) shows the explicit alternative costs more lines and loses
  envelope consistency, and the "forgot to respond" case is caught and finalized
  to 500. Keep as is.
* **REJECTED_CONCERN — "the internals are not really data-oriented."**
  Checked directly: the route table is a flat `[dynamic]Route_Entry` on the App
  (`web/dispatch_table.odin:53-59`) with no nodes and **no map anywhere on the
  hot path**; matching walks both strings in place with no allocation
  (`dispatch_match.odin:120-167`); the captured param is two views plus a bool;
  `Header_View` is a pure slice view that copies nothing. The one pointer
  dereference is a `^Route_Entry` into the table, used immediately. Precedence
  comes from a `has_param` flag rather than registration order. This is the
  data-oriented answer, and the linear scan is a deliberate interim structure
  that Phase 3 may replace without any public change.
* **REJECTED_CONCERN — "sensitive data could leak into logs."** The only logging
  path in `web/` is `framework_report` (`errors.odin:675-705`). It takes a
  `typeid` and a closed enum — never a value — and emits one of six
  compile-time constant strings. It does not import `core:fmt` or `core:log`,
  and never formats or interpolates. No path, query, body, header or payload can
  reach a log line. There is no `log.` or `fmt.print` call anywhere in `web/`,
  `web/testing/` or `web/internal/transport/`.
* **REJECTED_CONCERN — "the body cap can be bypassed."** Verified ordering in
  `web.body` (`extract.odin:287-329`): single-consumer check first, then empty
  → 400 with no arena, then `> BODY_LIMIT` → 413 with no arena, and only then is
  the arena created and the parser run. The adapter *also* caps while reading
  (`odin_http_adapter.odin:110`), so an over-limit body is never fully buffered.
* **REJECTED_CONCERN — "the framework is a Go/Express port."** No methods, no
  `interface{}`/`any` context bag, no `http.ResponseWriter` equivalent, no
  middleware in Phase 1, no struct tags driving behaviour, handler returns
  nothing. The shapes match `core:strings` and `core:net`, not `net/http`.

---

## 12. Open questions

Recorded, not decided. None blocks Phase 2 planning.

1. Should `Recorded_Response` ever carry headers? Needed to test CORS, cookies
   and cache validators — all Phase 4. Decide when Phase 4 needs it, not before.
2. Should middleware support post-`next` (onion) semantics at all, or only
   pre-order? Prototype-gated; the biggest Odin-fit risk in Phase 2.
3. Should configurable limits be an options struct with a package default
   constant (the `net.DEFAULT_TCP_OPTIONS` shape) or individual setter procs?
   Prefer the former on core precedent; confirm in Phase 3.
4. Does the framework ever terminate TLS, or is reverse-proxy termination the
   documented deployment? Affects Phase 4 scope materially.
5. What is the supported-Odin-version policy, given the toolchain is a pinned
   nightly and `core:os` is mid-redesign in this very build?
6. Is `ops/ci` project infrastructure or should it move to `tools/`? The local
   cleanup plan leaves this open.

---

## 13. Proposed user study (not executed)

No user testing has been done, and nothing in this document should be read as
evidence about how other people experience the API — §5 records one author's
session, which is a predictability signal, not a study.

Proposed before any 1.0 stability commitment:

* **Participants:** 3–5 Odin programmers, including at least one newcomer to the
  language and one experienced systems programmer. None involved in Druse.
* **Materials:** `docs/quick-start.md` and the three examples only. No access to
  `web/` sources — needing to read internals is itself a finding.
* **Tasks:** (1) hello world; (2) JSON endpoint; (3) `:param` route with integer
  validation; (4) POST with a JSON body; (5) map a domain error to a 404;
  (6) write one test.
* **Measure:** time per task; compile errors hit and whether the message was
  sufficient; documentation lookups; whether they attempted to copy the `App`;
  whether they tried to test a body handler (F-1); unprompted questions.
* **Acceptance:** all five complete tasks 1–4 without reading framework sources;
  no participant creates a double-free; every compile error encountered is
  self-explanatory. Any participant blocked on F-1 confirms R-2's priority.

---

## 14. Sources

Official Odin sources, all accessed 2026-07-19:

| Source | Used for |
|---|---|
| https://odin-lang.org/ | stated principles: simplicity, readability, orthogonality, joy |
| https://github.com/odin-lang/odin-lang.org/blob/master/content/docs/faq.md | no methods; one way to write something; no dialects; zero value useful; no destructors/RVO; core stays small; no official package manager |
| https://odin-lang.org/docs/overview/ | multiple return values; comma-ok idiom; `or_else`, `or_return` |
| https://pkg.odin-lang.org/core/ | official package index — confirms no `net/http` |
| https://odin-lang.org/news/ | `core:os` redesign in flight |
| https://github.com/odin-lang/Odin/wiki/naming-convention | naming conventions (wiki, semi-official) |

Primary source inspected directly: the pinned toolchain's own `core/` tree at
`/tmp/druse-toolchain/core/` — `strings/builder.odin`, `net/`, `os/`,
`bufio/`, `container/`, `slice/`, `mem/virtual/`. Where this document says
**[CORE]**, the claim was verified against those files, not recalled.

Evidence labelling used throughout: **[STATED]** = maintainer statement with
quote; **[CORE]** = idiom observed in the pinned standard library;
**[INFERENCE]** = the author's reasoning. No forum opinion, slogan or popularity
claim is treated as normative, and no comparison framework's published
benchmarks are cited as evidence about Druse.
