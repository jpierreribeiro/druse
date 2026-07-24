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

**Disposition:** RECORDED. The board uses the `web.Status(503)` workaround to
proceed (`board/routes.odin`). The candidate improvement is a real, additive,
well-evidenced finding — two independent applications, a universal pattern —
and is the kind of change the corrective-WP process exists for. **Not applied in
Phase 8; carried as the first framework finding for the owner's review.**

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

**Disposition:** RECORDED. The board proceeds with bearer-token sessions
(`board/auth.odin`), which is a legitimate architecture — but the finding is that
the framework **removed the choice**. This is the sharpest kind of proof-by-use
evidence: a plan-required capability that the public surface cannot express. Two
WP104 sub-requirements (cookie policy, CSRF) are discharged by architecture
substitution, with the substitution and its cause recorded here. **Not applied in
Phase 8; carried as a framework finding for the owner's review.**

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
