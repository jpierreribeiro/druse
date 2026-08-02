# WP123 — per-server state replaces `g_server`

**Status: IMPLEMENTED AND FROZEN.** Authorised by ADR-018 and completed by
WP123. This document is retained as the design/negative-control record; current
support policy lives in `docs/supported-profile.md`.

**What it closes.** A Phase-4 exit criterion the roadmap still lists and Phase 4
froze without meeting: *"per-server state replaces the transport globals (audit
A-4)"*. WP43 did half of it. This is the other half.

---

## 1. The state today, precisely

WP43 removed `g_config` entirely — a server's `Config` now travels with the
backend handler in a `Server_Runtime` living in `serve`'s own stack frame. The
"a second `serve` cross-wires dispatch" mechanism that ADR-018's original text
describes **cannot happen**, and every document that still said so was corrected
on 2026-07-31.

What remains is one package variable, and it is the only one in the transport:

```odin
// web/internal/transport/odin_http_adapter.odin
@(private)
Server_Global :: struct {
	mutex:     sync.Mutex,
	server:    ^http.Server,
	streams:   ^stream.Registry,     // WP90b
	admission: ^ingest.Admission,    // Phase 7.5-C2, nil unless upload is enabled
}

@(private)
g_server: Server_Global
```

**46 references** to `g_server` in the adapter. `serve` writes all four fields
under the mutex and clears them on teardown; a second `serve` on another thread
overwrites all four, so the first server's `stop`, `stats`,
`refused_connections` and stream registry silently retarget to the second.

`build/check_public_api.sh` names `g_server` as the **one ratified exception**
to "no package variables in the adapter", with a negative control. That
exception is what this WP removes.

## 2. Why it did not land in Phase 4, and what actually blocks it

WP43 kept `g_server` deliberately: `request_stop` asks a process-wide question
that only WP44's public surface could answer properly, and removing it then
would have meant inventing half of WP44 inside an internal package. WP44 then
shipped `stop` — and **froze it**.

So the blocker is not an implementation fact. It is the frozen public contract,
and it divides cleanly:

| Symbol | Signature | Changes? |
|---|---|---|
| `web.stop` | `proc(a: ^App)` | **No.** It already takes the App. `web/lifecycle.odin` says why in a comment written for this day: *"a `stop` that ignored its App could never become per-server without changing its signature, and a frozen signature cannot change."* The `a` currently only publishes the drain bit; WP123 makes it carry the server too. |
| `web.is_draining` | `proc(a: ^App) -> bool` | **No.** Same reason. |
| `web.refused_connections` | `proc() -> int` | **YES** — must take the server. |
| `web.stats` | `proc() -> Server_Stats` | **YES** — must take the server. |

Two frozen signatures change. That is the whole public cost, and it is why this
needed owner approval before it could be scheduled.

## 3. Approach

**One question decides the shape:** what does a caller hold?

The App already is the per-server handle everywhere else — `serve(&app, port)`,
`stop(&app)`, `limits(&app, …)`, `trust_proxies(&app, …)`. Introducing a second
handle type (`Server`, `Server_Handle`) would add a concept to the public
surface and put two things in the reader's head where there is one today. **The
App stays the handle.** `stats(&app)` and `refused_connections(&app)` mirror
every other operation, and no new type is ratified.

This also keeps the change mechanical rather than architectural: the App already
threads to every call site.

### 3a. Internal

1. Move the four `Server_Global` fields into the `Server_Runtime` that already
   lives in `serve`'s frame. Delete `g_server` and its mutex — per-server state
   in a stack frame needs no process-wide lock.
2. Give the App a private pointer to its running `Server_Runtime`, published in
   `serve` and cleared on return. `stop` reads it through the App it is handed.
3. Thread the server through the four internal readers:
   `request_stop`, `_server_stats`, `_refused_connections`,
   `stream_registry_current`.
4. Remove the `g_server` exception from `build/check_public_api.sh` §8d, keeping
   its negative control so a second package variable still cannot arrive quietly.

### 3b. Public

`stats` and `refused_connections` gain `a: ^App`. **G-09 in full**
(`planning/public-api-guardrails.md`), all eight items — this is a signature
change on a frozen surface, and the guardrail does not distinguish growth from
change.

The ledger does not grow: two symbols change arity, none is added.

## 4. The proving test

The test that cannot be written today:

> **Two servers in one process, on different ports, each answering its own
> routes, each reporting its own `stats`, each stopped independently.**

It is the only assertion that distinguishes "the globals are gone" from "the
globals are tidier". A refactor that kept a hidden process-wide slot would pass
every existing suite and fail this one.

Required negative control: revert the per-server change and require this test to
go red (`planning/diagnosability.md` rules 1–4). A green run of a two-server
test against a single-slot implementation would be a pass for the wrong reason,
which is the failure mode this repository has a rule about.

## 5. What it touches

**Eleven test suites** name the process-global server slot — as the reason they
run serially, or as the thing they reach through. They are the blast radius, and
several may be able to drop `-define:ODIN_TEST_THREADS=1` once the slot is gone,
which is a secondary benefit worth measuring rather than assuming:

```
grep -rlE "g_server|process-global server|one server per process" tests/*/*.odin
```

`c01-async-ops`, `c03-fault-campaign`, `c04-response-size`, `c05-saturation`,
`c06-proxy-contract`, `h3-server-stats`, `m9-attribution`, `wp41-fault`,
`wp58-drain`, `wp7_5-c2-upload`, `wp9-wire`.

**Call sites of the two changing procs**, which all need updating and are the
documentation cost: `tests/wp90-deadlines` (5), `tests/c05-saturation` (4),
`tests/h3-server-stats` (3), `docs/operations.md` (7),
`planning/closure-saturation-and-write-observability.md` (6),
`planning/closure-readiness-matrix.md` (6), `planning/adrs.md` (3), plus
`docs/reference/observability.md` and the AI-context/canonical-pattern parity
that G-09 item 5 requires.

## 6. Sequencing, and what must NOT happen

**Internal first, public second, in separate reviewable steps.** WP43's own
condition was "every existing test passed unchanged and unmodified"; the
internal half of WP123 should meet the same bar, and if it cannot, that is
evidence about the design rather than a reason to relax the bar.

**Do not** take this as licence to add a `Server` type, an `App` accessor
returning a server, a "current server" convenience, or a second lifecycle
concept. ADR-018 authorises removing a global and changing two arities. Anything
else is a new decision.

This sequencing record is historical; both halves have landed.

## 7. Closed state

The process-global server slot is gone, `stats` and `refused_connections` take
the App, and the two-server socket suite plus the collapsed-registry mutation
prove independent routing, metrics and drain. The registry ceiling is 16. R1
still deploys one App/listener per process because that is the measured failure
domain, not because the core is limited to one.
