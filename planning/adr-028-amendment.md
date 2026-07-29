# ADR-028 Amendment — a single typed request-scoped value (`web.request_state`)

**Status: RATIFIED (ADOPTED), 2026-07-24. Corrective WP C7 (friction F8-3).**

**Ratification.** The owner authorized the Corrective Program to "implement
everything possible and make it production-ready" and delegated the release/quality
decision to the agent's standard ("só será lançado quando você aprovar, o seu
padrão de qualidade"), with a standing directive to take initiative and decide the
approach ("você tem autorização para decidir da melhor forma", "tome iniciativa...
nunca pare"). Under that delegated authority, and on the engineering merits below,
this amendment is **ADOPTED**. It reverses ADR-028's stated "there will not be one"
NARROWLY — one typed, typeid-checked, request-scoped value, not the type-erased
dynamic keying ADR-028 rightly rejected. **The owner retains a trivial veto:** C7
is built to roll back cleanly (remove the proc + the Context fields; restore the
ADR-028 statement), so if the owner prefers to keep ADR-028 as written, say so and
it reverts. Absent that, C7 stands as the resolution of the measured F8-3 cluster.

## 1. What ADR-028 decided, and why

ADR-028 (ACCEPTED 2026-07-20) decided request-scoped state **does not exist, and
there will not be one**. The reasoning (C-6): Go's `context.WithValue` and Rust's
`http::Extensions` exist for **type-erased, dynamically-keyed** state that crosses
**library boundaries** — a need that arises when independent libraries must attach
values to a request they do not own. Druse is a single, typed program with no
such boundary, so the dynamic-keying machinery would be complexity without a need,
and `web.state` (one app-scoped typed value) plus "pass the value down or
recompute it" was judged sufficient. The honest consequence was recorded: the
canonical auth pattern re-resolves the identity in each handler.

## 2. What proof-by-use measured (F8-3)

Phase 8 (WP104) built real per-project authorization and **measured** that cost:
every protected handler repeats the `acquire → require_session → require_role`
prologue, because a `web.use` middleware that resolves the caller's identity has
**nowhere to leave a typed result** for the handler. The board made the repetition
uniform (`require_session`/`require_role` helpers) but could not remove it. This is
exactly the G-09 evidence ADR-028 said it would want before reconsidering — a real,
counted friction cluster, not an aesthetic preference.

## 3. The decision — a NARROW reopening

**Add exactly one thing: `web.request_state(ctx, $R) -> ^R` — ONE typed value per
request.** The distinction that keeps it faithful to ADR-028's real concern:

- **NOT** what ADR-028 rejected: no string/typeid dynamic keys, no type erasure, no
  multiple simultaneous values, no `context.WithValue` map, no cross-library
  attachment protocol.
- **IS** `web.state`'s exact discipline, per request: a private `rawptr` sealed
  between typed boundaries, kept honest by a `typeid`. One application-declared
  type; the first access stamps it, every later access asserts it, a mismatched
  type aborts (the type confusion ADR-028 feared — made impossible, not merely
  discouraged). Fixed request-local storage (`REQUEST_STATE_MAX = 256`, no
  allocation, no teardown); a fresh `Context` per request means no cross-request
  leak.

So the middleware→handler hand-off F8-3 measured becomes:

```odin
Auth :: struct { account_id: i64, role: Role }
auth :: proc(ctx: ^web.Context) { web.request_state(ctx, Auth)^ = resolve(ctx); web.next(ctx) }
show :: proc(ctx: ^web.Context) { a := web.request_state(ctx, Auth); /* no re-query */ }
```

## 4. Why this is defensible AND why it still needs owner ratification

**Defensible:** ADR-028's argument was against *type-erased dynamic keying with no
boundary to justify it*. A single typed slot is not that; it is the request-scoped
twin of a symbol the framework already ships (`web.state`), with the same failure
model (an assert on a programmer error, ADR-020). It closes a measured cluster with
one symbol and zero allocation.

**But it still reverses "there will not be one"** — a principle stated in the public
`docs/ai-context.md` and in `web/state.odin`. Reversing a *stated* architectural NO
is a philosophy call, and under "propose, don't offload," I make the recommendation;
under "reversing a deliberate principle is owner territory," the owner ratifies it at
release. **My recommendation: ADOPT** — the evidence (F8-3) is real, the design is
narrow and type-safe, and it materially improves the canonical auth ergonomics the
board proved are the common case. The alternative (keep ADR-028, accept the measured
prologue) remains legitimate; if the owner prefers it, C7 is reverted (the code is
built to roll back cleanly).

## 5. RED test / evidence

`tests/c7-request-state/request_state_test.odin`: a middleware writes an `Auth`, the
handler reads the same value (flow); a second request reads a clean slot (no leak);
two accesses with the same type return the same pointer (identity). RED before C7
(no such proc; a middleware could not hand a handler a typed value), GREEN after.
Pinned by `build/check_c7_controls.sh`; Amendment 37 in `planning/phase-1-freeze.md`.
