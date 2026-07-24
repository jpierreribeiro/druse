# Phase 8 — friction ledger

**Status: LIVE.** The evidence instrument of proof-by-use
(`planning/phase-8-plan.md` §2). Every friction the reference application
(`uruquim-board`) hits against the **public** framework surface is recorded here
with all nine fields. A core/Crystal change happens only in a separately
reviewed corrective WP with its original gates — this ledger is a **veto and
evidence source, not an accretion exception.**

`application-specific?` = the friction is the app's own design problem, not the
framework's. Only non-application-specific items are candidate framework
findings.

---

## F8-1 — the public `web.Status` enum has no 503 (nor 429)

| Field | Value |
|---|---|
| **1. Task attempted** | A `/ready` readiness endpoint that answers **503 Service Unavailable** when the database pool is exhausted or the database is unreachable — the universal Kubernetes/load-balancer readiness pattern (WP103). |
| **2. Public API used** | `web.text(ctx, status, body)`; the public `web.Status` enum. |
| **3. Boilerplate / concepts** | The application must **cast a raw integer**: `web.text(ctx, web.Status(503), ...)`. There is no named member. |
| **4. Safety / ownership problem** | The cast defeats the enum's purpose — the type exists so a status is a checked, named value, and `web.Status(503)` bypasses that. Any typo (`web.Status(530)`) compiles. It is also **undiscoverable**: nothing in the public surface tells a new contributor that 503 must be spelled as a cast. |
| **5. Workaround** | `web.Status(503)` — a raw int cast. It works because `web.Status` is `enum int` and the respond path forwards the numeric value. |
| **6. Application-specific?** | **No.** 503 (readiness, pool exhaustion, backpressure) and 429 (rate limiting) are needed by essentially every production service. The framework's OWN reference app already reaches for `web.Status(503)` — `crystals examples/notes/notes.odin:356` — for the identical bounded-pool case. Two independent applications hit it. |
| **7. Smallest candidate improvement** | Add the operationally-essential codes the enum omits to the public `web.Status` enum: **`Service_Unavailable = 503`** and **`Too_Many_Requests = 429`** (and, on the same review, consider `Conflict = 409` — already needed by the unique-violation path — and `Payload_Too_Large = 413`, currently a private value). No behaviour change; a name for a number applications already produce. |
| **8. Public cost / reversibility** | Additive to a frozen public enum — a ledger-growing change (the Phase-1 freeze evidence-matrix ritual), but purely additive: no existing member moves, no signature changes, fully reversible before any release. Enum additions do not break existing `case` matches on the current members. |
| **9. RED test** | A public-surface test that asserts `web.Status.Service_Unavailable == 503` and that `web.text(ctx, .Service_Unavailable, "x")` produces a `503` status line on the wire — RED today (the member does not exist), GREEN after the addition. It distinguishes *improvement* (a named 503 exists and works) from *preference* (nothing about the cast is a matter of taste — the cast is unsafe and undiscoverable). |

**Disposition:** **RESOLVED by corrective WP C1 (2026-07-24).** `web.Status` now
carries `Conflict=409`, `Payload_Too_Large=413`, `Too_Many_Requests=429`,
`Service_Unavailable=503` as named members; the framework's own body-too-large
path returns the named `.Payload_Too_Large` (the private `Status(413)` cast
removed). Pinned by `tests/c1-status-codes` + `build/check_c1_controls.sh`, with
the full freeze ritual (Amendment 32) and the re-aimed mutation probes. The board
drops the `web.Status(503)`/`(409)`/`(413)` casts for the named members at its
next re-pin. (Originally RECORDED in Phase 8 as the first, most-corroborated
finding — three independent applications.)

---

## F8-2 — no public way to set a response header, so an application cannot emit `Set-Cookie`

| Field | Value |
|---|---|
| **1. Task attempted** | Cookie-based browser sessions (WP104): on login, set an `HttpOnly; Secure; SameSite` session cookie via a `Set-Cookie` response header; and the CSRF double-submit cookie that browser-mutation protection needs. |
| **2. Public API used** | The public response helpers — `web.text`, `web.json`, `web.ok`, `web.created`, `web.no_content`, and the error helpers. None take headers. `web.response_commit`/`response_commit_owned` (the only paths that accept `[]Header_Pair`) are `@(private)` to package `web`, and the `response_*_headers` builders are private too. |
| **3. Boilerplate / concepts** | There is **no public path at all**. An application cannot append a single response header of its own; `Content-Type`, `X-Request-Id`, the secure-headers set and CORS are all framework-set through private funnels. `web/response.odin` states it outright: *"There is NO public header API ... an application that needs something else is asking for a Phase-2 feature."* Phase 2+ never added one (verified against the current `closure` tree). |
| **4. Safety / ownership problem** | Not a safety hole — a hard capability gap. The single most common browser-auth mechanism (a session cookie) is **inexpressible** through public contracts. So is any custom header an app legitimately needs (`Set-Cookie`, `Cache-Control`, `Content-Disposition` for downloads — the last already looming for WP106 attachments, `Location` for a 201 redirect). |
| **5. Workaround** | Change the security architecture: use **opaque bearer tokens** instead of cookies. Login returns the token in the JSON body; the client sends `Authorization: Bearer <token>` (read via the public `web.bearer_token`). CSRF then does not apply (it exploits ambient cookie credentials; a token JS must read and attach is not ambient), so the CSRF requirement is discharged by *removing its precondition*, not by implementing it. This is what the board does (`board/identity/token.odin`, `board/auth.odin`). It is a viable, arguably-more-robust design for an API — but it was **forced, not chosen**, and it forecloses any browser that wants a cookie. |
| **6. Application-specific?** | **No.** Setting a response header is a universal server capability. Two of the plan's own WP104 requirements — "cookie policy at the proxy/application boundary" and "CSRF policy for browser mutations" — are **not implementable** as written through the public surface. WP106 (`Content-Disposition`) will hit the same wall from a different direction. |
| **7. Smallest candidate improvement** | A minimal public header-append: e.g. `web.set_header(ctx, name, value)` that writes into the existing request-local `response_headers` array before commit (the array already reserves `RESPONSE_HEADER_MAX = 12` slots, most unused), rejecting the framework-reserved names. Optionally a `web.set_cookie(ctx, Cookie{...})` convenience over it. No new allocation model — the storage and the commit funnel already exist; only a guarded public writer is missing. |
| **8. Public cost / reversibility** | Additive: one (or two) new public procs, no signature change to existing responders, no behaviour change to any current path. Ledger-growing (the freeze evidence-matrix ritual). The design cost is the reserved-name policy (an app must not clobber `Content-Type`/`X-Request-Id`/CORS/secure headers) — a small, decidable rule. Fully reversible before release. |
| **9. RED test** | A public-surface test: a handler calls `web.set_header(ctx, "Set-Cookie", "sid=x; HttpOnly")` then `web.text(ctx, .OK, "")`, and the recorded response carries that exact header on the wire — RED today (no such proc), GREEN after. It distinguishes *improvement* (an app can emit a header) from *preference* (bearer-vs-cookie is a real design axis, but "an app cannot set **any** header" is a capability gap, not a taste). |

**Disposition:** **RESOLVED by corrective WP C2 (2026-07-24).** `web.set_header(ctx,
name, value) -> bool` is now the public path to set any application response header
(`Set-Cookie`, `Cache-Control`, `Content-Disposition`, `Location`, …), rejecting
CR/LF/NUL injection, framework-owned names, over-commit and over-budget. Cookie
sessions and CSRF are now expressible; the board keeps bearer tokens (a legitimate
choice) but the framework **no longer removes the choice**. Pinned by
`tests/c2-response-surface` + `check_c2_controls.sh`, Amendment 33. (Originally
RECORDED in Phase 8: the framework had removed a plan-required capability.)

---

## F8-3 — no request-scoped typed state, so every protected handler repeats the auth resolve

| Field | Value |
|---|---|
| **1. Task attempted** | Authenticate once per request and make the caller's identity (and, for a mutation, their project role) available to the handler — the ordinary "auth middleware populates `request.user`" shape (WP104). |
| **2. Public API used** | `web.use` (middleware), `web.bearer_token`, `web.state` (the app's *global* `App_State`), and the per-handler DB path (`pg.acquire` → `pg.query_one`). |
| **3. Boilerplate / concepts** | ADR-028 is explicit that the application must **not** smuggle an extension bag into `Context`, and there is no public request-scoped typed slot. Middleware (`web.use`) can run before a handler but has **nowhere to hand a typed result forward** — it cannot deposit the resolved `Identity` where the handler will read it. So authentication is resolved *inside each protected handler*: `acquire → require_session → (require_role) → work → release`. The board measures this: **4 protected handlers** (`/me`, `/logout`, `/projects/:id`, `/projects/:id/members`, plus `POST /projects`) each repeat the acquire+resolve prologue; the two mutation handlers add the role prologue. |
| **4. Safety / ownership problem** | No unsafety — the repetition is honest and typed. The cost is (a) DX: the same 6–10 lines open every protected handler; (b) an **extra pooled connection round-trip** where auth and the handler's own work can't share one acquisition cleanly (`create_project` releases the auth connection before opening its transaction — two acquisitions for one request); (c) the risk that a new protected handler simply *forgets* the prologue, with no framework check that it didn't. |
| **5. Workaround** | Encapsulate the prologue in `require_session(ctx, ^Conn) -> (Identity, bool)` and `require_role(ctx, ^Conn, project, account, need) -> bool`, each of which commits its own 401/403 and returns `ok=false` so the handler's check is one `if !ok { return }` line (`board/auth.odin`, `board/authz.odin`). This makes the repetition uniform and auditable, but it does not remove it — it is a convention, not a guarantee. |
| **6. Application-specific?** | **Partly.** That auth *lives in the application* is a correct framework stance (identity is not core's job — WP104's whole premise). What is not application-specific is the absence of any typed way for a `web.use` middleware to pass a computed value to the handler it guards: every app doing per-request auth will re-derive this same pattern. This is exactly the evidence ADR-028 said it wanted before reconsidering request-scoped state. |
| **7. Smallest candidate improvement** | The decision is ADR-028's to reopen, not this ledger's to pre-empt. The evidence to weigh: a *typed, application-owned* request slot (not an untyped `Context` bag) that middleware writes and the handler reads — e.g. a generic `web.request_state(ctx, $T)` backed by request-local storage the app sizes, mirroring how `web.state` gives typed access to `App_State`. The bar is G-09 (a real friction cluster), and this is one data point toward it, not a mandate. |
| **8. Public cost / reversibility** | If ADR-028 is reopened: a new public generic and a request-local storage slot — additive, but a genuine surface and lifetime commitment (who owns the value, when it is cleared), so **not** a trivial add. Recorded here as evidence toward that decision, deliberately **not** proposed as a Phase-8 change. |
| **9. RED test** | Deferred until/unless ADR-028 reopens: a test where a `web.use` middleware resolves an identity, stores it via the candidate typed slot, and a downstream handler reads the *same typed value* without re-querying — RED today (no such slot), GREEN after. Until then this is an evidence entry, not a change request. |

**Disposition:** RECORDED as **measured boilerplate** (the plan's WP104 mandate:
"Measure repeated auth/authorization boilerplate ... this is the evidence ADR-028
requires; the application does not smuggle an extension bag into `Context`"). The
board honors ADR-028 — no `Context` bag — and pays the repetition explicitly.
One data point toward reopening ADR-028; **not** a Phase-8 change. Revisit when
WP105–108 add more protected handlers and the cluster is larger.

---

## F8-4 — no buffered binary response body, so an authenticated file download is not expressible

| Field | Value |
|---|---|
| **1. Task attempted** | Serve a task attachment's bytes for download (WP106): `GET /attachments/:id`, authorized by project role, returning the stored file with its `Content-Type` and a safe `Content-Disposition: attachment; filename="…"`. |
| **2. Public API used** | The public responders `web.json`/`web.text`/`web.ok`/`web.created`/`web.no_content`; `web.stream`; `web.static`. |
| **3. Boilerplate / concepts** | There is **no buffered binary responder**. `web.text` sends `text/plain` and copies a *string*; `web.json` marshals a value; neither emits arbitrary bytes with a chosen media type. The only way to put non-JSON/non-text bytes on the wire is `web.stream`, which is the **SSE/chunked** substrate: it commits **200 only** (no 404/403 on the stream head), sets **no `Content-Length`** (always chunked), enforces a **bounded queue** (`stream_send` returns `Full` — designed for backpressured feeds, not a bulk file), and — like every path — **cannot set `Content-Disposition`** (friction F8-2). `web.static` serves a directory of files but has **no authorization hook** and no per-file disposition, so it cannot gate a download by project role. |
| **4. Safety / ownership problem** | A file download that cannot set `Content-Disposition: attachment` invites the browser to render attacker-controlled content **inline** (an HTML/SVG attachment becomes stored XSS on the app's origin) and loses the download filename. And an authorized download cannot be built on `web.static` at all (no auth). So the safe, ordinary shape — auth-gated bytes with a disposition — has no public expression. |
| **5. Workaround** | **None acceptable.** The board serves attachment **metadata** as JSON (`GET /attachments/:id` returns id/filename/content_type/byte_size/…) and records this finding rather than mislead. Considered and rejected: (a) `web.stream` — misframes a bulk download as a chunked feed, can't set the filename, and its `Full` backpressure would truncate or wedge a handler lane on a large file; (b) `web.static` over the storage dir — bypasses the whole WP104 authorization model and exposes the generated storage names. |
| **6. Application-specific?** | **No.** Returning bytes with a content type (a PDF, an image, a CSV export) is a universal server capability, needed by essentially every application that stores files or generates reports. The board's own WP106 attachment feature — a core plan requirement ("static download policy and safe content disposition") — is **half-built**: upload works end-to-end (buffered and spool), download does not. |
| **7. Smallest candidate improvement** | Two additions, composable with F8-2's `web.set_header`: (a) a buffered binary responder, e.g. `web.bytes(ctx, status, content_type, data)` — the exact shape of `web.text` but with a caller-chosen media type and a `[]u8` body (the `Response` already owns an arbitrary `[]u8`; only the public entry point is missing); (b) the header API of F8-2 so `Content-Disposition` (and `Cache-Control`) can be set. With both, an auth-gated download is `require_role(...); web.set_header(ctx, "Content-Disposition", …); web.bytes(ctx, .OK, ct, data)`. |
| **8. Public cost / reversibility** | Additive: one new responder over the existing owned-body commit path, no change to any current responder or to the ownership model (`response_commit_owned` already frees a `[]u8`). Ledger-growing (freeze evidence-matrix ritual). Fully reversible before release. The design question is only the content-type validation policy (reject CR/LF injection into the header), a small decidable rule. |
| **9. RED test** | A public-surface test: a handler calls `web.bytes(ctx, .OK, "application/pdf", data)` and the recorded response has that exact `Content-Type` and the exact bytes on the wire — RED today (no such responder), GREEN after. It distinguishes *improvement* (an app can emit a typed binary body) from *preference* (there is nothing subjective about "an app cannot return a PDF"). |

**Disposition:** **RESOLVED by corrective WP C2 (2026-07-24)**, paired with F8-2.
`web.bytes(ctx, status, content_type, data)` is now the buffered binary responder:
a caller-chosen `Content-Type` (validated against control bytes) and a `[]u8` body
the `Response` owns like `web.text`'s. With `web.set_header` (F8-2) it makes an
auth-gated file download expressible — `set_header(ctx, "Content-Disposition", …);
bytes(ctx, .OK, ct, data)` — so the board can serve attachment bytes at its next
re-pin instead of only metadata. Pinned by `tests/c2-response-surface` +
`check_c2_controls.sh`, Amendment 33. (Originally RECORDED in Phase 8 as the
confirmation of F8-2's prediction: no public way to emit typed bytes.)

---

## F8-5 — no client-disconnect signal for a stream, so a subscriber registry leaks until it next sends

| Field | Value |
|---|---|
| **1. Task attempted** | A live board (WP107): a per-project SSE subscription registry (the hub) that fans task changes out to connected browsers, and **prunes a browser that has gone away** so its slot and memory are reclaimed and the open-stream cap is not exhausted by ghosts. |
| **2. Public API used** | `web.stream`/`stream_send`/`stream_close`; crystals `web/sse` `open`/`send`/`last_event_id`. |
| **3. Boilerplate / concepts** | A stream is opened in a handler that then returns; the app sends to the token later. There is **no disconnect callback and no "is this stream still connected" query** — the ONLY way the application learns a client left is that a subsequent `send`/`stream_send` returns `Closed`. So the hub can prune a departed client **only when it next publishes to that project**. A project with no activity accumulates dead subscribers indefinitely; each holds a slot against the framework's open-stream cap. Detecting-and-pruning an idle-but-gone client requires the app to send something on a timer — a **heartbeat** — which in turn requires a periodic background task the app must build and shut down itself: the framework offers no ticker, and none that is coordinated with `web`'s drain. |
| **4. Safety / ownership problem** | No unsafety — `stream_send`/`stream_close` are documented safe from any thread and are idempotent on a stale token. The cost is a **resource leak that the application cannot close through the public surface alone**: without an app-run heartbeat thread, ghosts occupy the bounded stream capacity, and the framework's own cap (`DEFAULT_MAX_STREAMS`) is then consumed by clients that left. The app must additionally coordinate that thread's shutdown with the framework drain, which has no public hook for "drain starting". |
| **5. Workaround** | The board prunes **on publish** (a `Closed` send drops the subscriber — implemented in `board/hub.odin hub_publish`) and closes every remaining stream at `application_destroy`. Idle-subscriber pruning via a heartbeat thread is a **recorded follow-up**, deferred because it needs its own `core:thread` + a shutdown handshake the framework does not expose. Reconnect is handled by nudging a Last-Event-ID client to refetch (`hub_resync`), not by replaying an event log. |
| **6. Application-specific?** | **Split, stated honestly.** The heartbeat *interval and content* are legitimately application policy (the framework should not dictate them). What is **not** application-specific is (a) the absence of any disconnect signal or liveness query on a stream — every streaming app that keeps a registry hits this — and (b) the absence of a drain-coordinated periodic hook, so the required heartbeat thread must reinvent shutdown coordination each time. |
| **7. Smallest candidate improvement** | Either (a) a **disconnect callback / liveness predicate** on a stream, so a registry can prune without sending — e.g. `web.stream_live(s) -> bool` backed by the state `stream_send` already checks; and/or (b) a documented, drain-aware **periodic-task hook** (a callback the framework invokes on an interval on a framework-managed lane, stopped as part of drain), which the heartbeat and other housekeeping would use. (a) is the smaller, more targeted add and directly closes the leak. |
| **8. Public cost / reversibility** | `web.stream_live` is additive and cheap — it reads liveness the stream layer already tracks, no new lifetime. A periodic-task hook is larger (a scheduling and drain-ordering commitment) and should not be rushed. Recorded as evidence; the targeted `stream_live` is the reversible, low-cost half. |
| **9. RED test** | For the targeted half: open a stream, simulate the peer's disconnect, and assert `web.stream_live(s) == false` **without** a prior `send` — RED today (no such predicate; disconnect is observable only through a failed send), GREEN after. It distinguishes *improvement* (a registry can prune a gone client proactively) from *preference* (heartbeat cadence, which stays app policy). |

**Disposition:** RECORDED as an evidence/DX finding (kin to F8-3). The board's
publish-time pruning is correct and sufficient for an active board; the leak is
real only for idle projects, and closing it fully needs either a small framework
predicate (`stream_live`) or an app heartbeat thread the framework does not help
build. **Not applied in Phase 8**; the targeted `stream_live` is offered as the
cheap, reversible improvement for the owner's review.

---

## F8-6 — no optional TYPED query parameter: `query_int` 400s on absence, `query_int_or` can't report presence

| Field | Value |
|---|---|
| **1. Task attempted** | An OPTIONAL typed filter on the task list — `GET /projects/:id/tasks?assignee=<int>` narrows to that assignee, and its ABSENCE means "no assignee filter" (WP106 dynamic filters). |
| **2. Public API used** | `web.query` (string, soft), `web.query_int` (typed, required), `web.query_int_or` (typed, with default). |
| **3. Boilerplate / concepts** | Neither typed reader expresses "optional typed". `web.query_int` is the REQUIRED reader: on absence it **commits a 400** `invalid_query_parameter: '<name>' is required` and returns ok=false — so merely *reading* an optional filter that the client did not send fails the whole request. `web.query_int_or(name, default)` does not commit on absence, but it returns **ok=true for BOTH absent (→default) and present-valid**, so the handler cannot tell "filter with value D" from "no filter". The only way to get optional-typed is to combine two calls: `web.query` (presence) then `web.query_int_or` (to still 400 a present-but-malformed value). |
| **4. Safety / ownership problem** | No unsafety, but a **live bug that shipped**: the board used `web.query_int("assignee")` for the optional filter, so EVERY unfiltered task list returned `400 "'assignee' is required"` — caught only by the deployment-#2 smoke test against real query strings, not by any typecheck. The sharp edge is that `query_int`'s auto-commit-on-absence is invisible at the call site; it reads like a soft typed getter and is not. |
| **5. Workaround** | `if _, has := web.query(ctx, "assignee"); has { a, ok := web.query_int_or(ctx, "assignee", 0); if !ok { return }; use a }` — presence via the string reader, value+malformed-400 via `query_int_or`. Implemented in `board/tasks.odin list_tasks`. Correct, but two calls and a non-obvious idiom for what reads like a one-liner. |
| **6. Application-specific?** | **No.** Optional typed query parameters (`?limit=`, `?after=`, `?assignee=`, `?since=`) are universal in list/filter endpoints. The `query`/`query_int`/`query_int_or` trio is deliberately designed (ADR-002 forbids `#optional_ok`), and the design is defensible — but it has **no member for the most common case**, and the closest-named one (`query_int`) fails closed in a way that silently breaks an optional read. |
| **7. Smallest candidate improvement** | Either (a) a soft typed reader that reports presence distinctly, e.g. `web.query_int_opt(ctx, name) -> (value: int, present: bool, ok: bool)` — present=false on absence (no commit), ok=false only on a present-but-malformed value (commits the 400); or (b) documentation that names the `web.query` + `query_int_or` pairing as THE optional-typed idiom, with a compiling example. (a) removes the foot-gun; (b) is the zero-code minimum. |
| **8. Public cost / reversibility** | (a) is additive — one new public proc, no change to the existing three, fully reversible; it must not itself grow an `#optional_ok` (the ADR-002 line). (b) is docs-only. Recorded as evidence; the board ships the two-call workaround, so nothing is blocked. |
| **9. RED test** | For (a): `GET /list` with no `assignee` → the handler reads `web.query_int_opt(ctx,"assignee")`, gets `present=false, ok=true`, and returns 200 with no filter — RED today (no such proc; the nearest, `query_int`, 400s on absence), GREEN after. It distinguishes *improvement* (an optional typed read exists) from *preference* (the required/`_or` split is a real design, but there is no optional-typed member at all). |

**Disposition:** **RESOLVED by corrective WP C3 (2026-07-24).** `web.query_int_opt(ctx,
name) -> (value: int, present: bool, ok: bool)` is the soft typed reader that
reports presence: ABSENT (`present=false, ok=true`, no commit), PRESENT+valid
(both true), PRESENT+malformed (`ok=false`, a 400). The board drops the
`web.query` + `query_int_or` two-call workaround for the single call at its next
re-pin. Pinned by `tests/c3-query-opt` + `check_c3_controls.sh`, Amendment 34.
(Originally RECORDED in Phase 8 with live-bug provenance — the wrong call
`query_int` for an optional filter 400'd production traffic until the smoke test
caught it.)

---

## F8-7 — `Expect: 100-continue` is answered `417`, so large uploads from default clients fail

| Field | Value |
|---|---|
| **1. Task attempted** | Upload an attachment larger than `max_body` (the Phase-7 spool path) with an ordinary HTTP client (curl) — `POST /tasks/:id/attachments` with a 5 MiB body (WP106). |
| **2. Public API used** | The request path into `web.enable_upload`/`web.upload`; no application call is at fault — this is the framework's HTTP/1.1 request handling. |
| **3. Boilerplate / concepts** | curl (and python-requests, and other clients) automatically add `Expect: 100-continue` for a large request body, then wait for a `100 Continue` interim response before sending the body. The framework answers **`417` (Expectation Failed) with an empty body** and never reads the body, so the upload fails before the handler runs. The application cannot fix this — it is below the handler, in the wire protocol. |
| **4. Safety / ownership problem** | A hard interop gap: the **exact feature the large-body spool exists to serve** is unreachable from a default-configured mainstream client. `100-continue` is the universal HTTP/1.1 mechanism precisely for large uploads (let the server reject on headers before the body is sent), so failing it hits the large-upload path hardest. It is silent to the application (no handler diagnostic — the smoke's large-file step just got a bare 417). |
| **5. Workaround** | Strip the header client-side: curl `-H "Expect:"`. With it removed, the same 5 MiB upload returns `201` with `spooled=true` — the spool path itself is correct and proven live. The workaround is client-side only; a browser `fetch`/`XMLHttpRequest` does not send `Expect`, so browsers are unaffected, but server-to-server and CLI clients are. Documented in `ops/deploy-runbook.md`. |
| **6. Application-specific?** | **No.** `Expect: 100-continue` handling is framework/transport behaviour, identical for every application. RFC 9110 §10.1.1 lets a server that cannot meet the expectation respond `417`, so this is not a spec violation — but the pragmatic norm is to **ignore an unsupported `Expect` and read the body anyway** (what most servers do), because a hard `417` breaks large uploads from default clients. |
| **7. Smallest candidate improvement** | Treat `Expect: 100-continue` as ignorable: either send the `100 Continue` interim and read the body, or drop the expectation and read the body regardless — instead of `417`. Even the minimal "ignore the header, read the body" (no interim response) restores default-client large uploads and stays within the RFC. |
| **8. Public cost / reversibility** | No public API change — it is internal request handling, behaviour-only. The cost is transport work (recognize the header; optionally emit a `100 Continue` line). Reversible; no signature moves. It should be measured against the C-0x wire tests so the interim response does not disturb the single-commit/response model. |
| **9. RED test** | A raw-wire test: send `POST` with `Expect: 100-continue` and a body over `max_body`; assert the server reads the body and the handler runs (spool created), rather than answering `417` — RED today (`417`, body unread), GREEN after. It distinguishes *improvement* (default clients can upload large bodies) from *preference* (whether a real `100 Continue` interim is sent is a sub-choice; either honoring or ignoring passes). |

**Disposition:** RECORDED with **live provenance** — found proving the spool path
on deployment #2 (a 5 MiB curl upload got `417`; the same upload with `-H
"Expect:"` got `201 spooled=true`). The spool path is correct; the gap is the
transport's hard `417` to a universal expectation. Browsers are unaffected; CLI
and server-to-server clients need the header stripped. **Not applied in Phase 8;
carried for the owner's review** as a transport-level robustness fix.

---

## F8-8 — no typed timestamp/date input: writing a `timestamptz` is undocumented text-cast, and a malformed date is a 500 (found by all 3 WP112 agents)

| Field | Value |
|---|---|
| **1. Task attempted** | Add an optional `due_date` (`timestamptz`) to tasks — the WP112 usability task: accept it on create and in the three-state PATCH, store it in the column (WP112 / plan §WP112 "add a validated field through migration, SQL, handler"). |
| **2. Public API used** | `crystals:db/postgres` param builders (`arg_text`/`arg_i64`/`arg_bool`/`arg_null`) and row readers (`row_text`/`row_opt_text`/…); `crystals:validate`. |
| **3. Boilerplate / concepts** | The param builders cover text, int, bool, bytes, null — there is **no `arg_timestamp`/`arg_date`/`arg_timestamptz`**. Reading a timestamp is shown everywhere (the `created_at::text` cast idiom), but **nothing shows how to WRITE one**: the working idiom is to bind the value as `arg_text` and add an explicit `$N::timestamptz` cast in the SQL. Separately, `crystals:validate` offers `not_empty`/`string_length`/`int_range`/`one_of` but **no date/timestamp validator**, so a malformed input string is not caught at the boundary. |
| **4. Safety / ownership problem** | No unsafety, two DX gaps: (a) the write-a-timestamp idiom is **inferred from convention, documented nowhere** — every contributor must reverse-engineer it from the read-side `::text` casts; (b) a malformed `due_date` (e.g. `"not-a-date"`) is not a `400` — it reaches Postgres, fails as a generic `Query_Failed`, and `respond_db_error`'s `#partial switch` has no case for it, so it becomes **`web.internal_error` = 500**. A user's bad input reads as a server fault. |
| **5. Workaround** | Bind `arg_text(iso_string)` and cast in SQL (`$N::timestamptz`), mirroring the read-side `::text` pattern — which is exactly, and independently, what all three WP112 agents did, and it compiles and works. For the 500-vs-400: either parse with `core:time` in the handler (app-level) and reject with `400` before the query, or map the timestamp-format `Query_Failed` sqlstate to a domain `400` — neither is provided. The board currently accepts the same untyped-text risk posture the rest of the codebase has. |
| **6. Application-specific?** | **No.** Timestamps/dates are in essentially every schema (`due_date`, `scheduled_at`, `expires_at`). The absence of a typed input builder and a date validator is a framework/Crystal surface gap, hit identically by three independent implementations. |
| **7. Smallest candidate improvement** | Two additive, independent pieces: (a) a typed input builder in `db/postgres`, e.g. `arg_timestamptz(t: time.Time)` (or an `arg_typed(text, oid)` that names the cast), so writing a timestamp does not depend on an unwritten convention; (b) a date/timestamp validator in `crystals:validate` (e.g. `validate.rfc3339(&v, path, value)`) so a malformed value is a boundary `400`. Even docs-only — spelling out the `arg_text` + `$N::timestamptz` write idiom next to the read idiom — closes half of (a). |
| **8. Public cost / reversibility** | Both additive: a new param builder and a new validator, no change to existing signatures. `arg_timestamptz` pulls `core:time` into the param surface (a small dependency decision). Reversible. Recorded as evidence; the board ships the text-cast workaround, so nothing is blocked. |
| **9. RED test** | For (a): a test binds a timestamp through the candidate `arg_timestamptz` and reads it back equal — RED today (no such builder), GREEN after. For (b): `validate.rfc3339` rejects `"not-a-date"` with a field error, so the handler returns `400` not `500` — RED today, GREEN after. Each distinguishes *improvement* (a typed, validated timestamp path) from *preference* (the text-cast works; the gap is discoverability + the 500-on-bad-input). |

**Disposition:** RECORDED with the **strongest provenance in the ledger — three
independent WP112 coding agents (2× sonnet, 1× opus), in isolated copies, each
surfaced BOTH facets unprompted** while converging on the same canonical
implementation (see `planning/phase-8-wp112-usability-study.md`). That the
usability instrument itself produced a framework finding is proof the proof-by-use
loop holds even inside the study. **Not applied in Phase 8; carried for the
owner's review**, likely paired with F8-1 (the enum) as a batch of small,
additive Crystal/enum completions.
