# Phase-3 specification — the observable-semantics decisions

**Status: two decisions ACCEPTED by the owner on 2026-07-20.** Both are the
SPEC halves of work packages whose implementations come later, and both required
owner approval because they change observable HTTP semantics.

They are recorded here **before** the route representation shootout (WP28) on
purpose. `planning/phase-3-plan.md` §2 explains why: path normalisation decides
which paths are *equal*, and OPTIONS decides which methods the table must
*answer*. Deciding them after the shootout gives two bad outcomes and no good
one — either WP29 is rewritten, or the semantics get silently constrained by a
representation chosen without knowing about them, which is a design decision
made by scheduling accident.

| Spec | Work package | Implementation |
|---|---|---|
| §1 Path normalisation | WP31a | WP31b, after WP29 |
| §2 HEAD, OPTIONS and 501 | WP32a | WP32b, after WP29 |

**Neither spec constrains the shootout.** Both checks sit *before* route
matching, so WP28 may proceed against any representation. That is stated here so
nobody treats these as blockers a second time.

---

# §1 — Path normalisation: reject, do not transform (WP31a)

## The decision

**Druse normalises nothing, and rejects the paths where the absence of
normalisation would be dangerous.** A path carrying a dot segment, an interior
empty segment, or a percent-encoded slash is answered `400` and never reaches
route matching. Everything else passes through byte-exact and undecoded, exactly
as Phase 1 ships it.

## Why reject rather than normalise, and why not silence either

Path normalisation is where directory-traversal and route-confusion bugs live.
Every normalisation rule is an opportunity for two components to disagree about
what a path means, and the component that disagrees with you is usually a proxy
you do not control.

The two rejected alternatives, and the reason each loses:

* **Normalise (RFC 3986: decode, resolve dot segments, collapse slashes).**
  Most ergonomic, most dangerous. It maximises the number of ways Druse's view
  of a path can differ from the proxy's, and every such difference is a
  potential authorization bypass — the request the proxy authorised is not the
  request the framework routed.
* **Ratify the absence and stay silent.** Safe in the sense that nothing is
  transformed: `/users/../admin` matches no pattern and becomes a `404`. But the
  disagreement with a normalising proxy stays **invisible**. The proxy sees
  `/admin`, applies `/admin`'s policy, forwards `/users/../admin`, and Druse
  answers 404 — or, with a differently-shaped route table, answers something
  else entirely. A 404 is not a diagnosis.

Rejecting makes the disagreement **loud**. A request whose meaning depends on
who is normalising is answered `400` by the framework, once, at the boundary,
before any route or middleware can act on an ambiguous path. This is the same
shape as ADR-019's fail-closed ordering guard: when the framework cannot be sure
what was meant, it refuses rather than guesses.

## The rules

A path is **rejected with `400`** when any of the following holds. The list is
exhaustive; anything not listed here is passed through unchanged.

**R1 — a dot segment.** Any segment equal to `.` or `..`.
`/users/../admin`, `/a/./b`, `/..` → 400.

**R2 — an interior empty segment.** Two consecutive slashes anywhere except the
end: `/users//42`, `//admin` → 400.

**R3 — a percent-encoded slash.** `%2F` or `%2f` anywhere in the path.
`/files/a%2Fb` → 400.

**R4 — a percent-encoded NUL.** `%00` anywhere in the path.

### THE TRAILING SLASH IS NOT AN EMPTY SEGMENT

This is the trap, and it is called out because the obvious implementation of R2
falls into it.

`/users/` splits into `["users", ""]` — a trailing empty segment. If R2 were
written as "reject any empty segment", `/users/` would start answering `400`,
and **that would break every application that registered `/users/`**, which is a
legal and distinct Phase-1 pattern today.

**The trailing slash keeps its Phase-1 meaning exactly:** `/users` and `/users/`
remain two different paths, matched literally, neither normalised into the
other. R2 concerns *interior* empty segments only. WP31b must have a test for
`/users/` returning whatever its route table says, and a test for `/users//`
returning 400, or R2 is not implemented correctly.

## What is deliberately NOT decided here

* **Percent-decoding in general.** `%41` is not decoded and does not match `A`.
  A path containing ordinary percent-encoding is neither rejected nor
  transformed — it is matched byte-exact, as today. Only the two encodings that
  change a path's *structure* (R3, R4) are rejected.
* **Query-string normalisation.** Out of scope. The query is a separate
  component with separate extractors.
* **Case sensitivity.** Paths remain case-sensitive.

## Implementation constraints for WP31b

1. **The check sits on the shared dispatch path**, not in `serve`. ADR-019's
   lesson, verbatim: both transports must reject identically, so `test_request`
   and a socket give the same answer.
2. **It runs before route matching**, so it constrains no representation.
3. **It uses the existing `bad_request` envelope.** No new error code, no second
   error machine.
4. **It is not a framework failure.** Like a 404, a rejected path is a normal
   outcome of a client's request and emits **no** `Framework_Event`. Phase 2
   already pins the analogous distinction
   (`wp20_public_a_404_is_not_a_framework_failure`).
5. **It must be measured against the WP26 baseline.** A per-request scan of the
   path is new hot-path work. FINDING-E's ±57.6% noise floor means it will not
   be visible as a timing change; it must be justified as bounded, allocation-free
   work — and it is: a single pass over bytes the router will walk anyway, with
   no allocation.
6. **Negative control required.** A mutation that skips the check must turn a
   test red, or the check is not proven to run.

---

# §2 — HEAD, OPTIONS and 501 (WP32a)

## The decision

**Automatic HEAD, automatic OPTIONS, no 501, and no change to the `Method`
enum.** Handlers never see either method. An unrecognised method keeps its
current answer: `405` with the exact `Allow` header.

## Why HEAD is not optional

C-1 records that HEAD is effectively mandatory, and today it is **broken**:
`Method` is `{UNKNOWN, GET, POST, PUT, PATCH, DELETE}`, so `HEAD /users` maps to
`.UNKNOWN` and matches no route. Health checkers, proxies and monitoring systems
send HEAD. This is a defect, not a missing feature.

## The rules

**HEAD.** A HEAD request is matched as though it were GET. The registered GET
handler runs, the response is committed normally, and **the body is suppressed
at commit**. Status and headers — including `Content-Type` — are those the GET
would have produced. If no GET route matches, HEAD gets the same answer GET
would have got.

The handler is never told it was a HEAD. That is not a limitation, it is the
RFC's own requirement: a HEAD response must be identical to the GET response
except for the body, and a handler that could distinguish them could violate
that.

**OPTIONS.** An OPTIONS request to a path that matches at least one registered
route is answered `204 No Content` with an `Allow` header, built by **the same
machinery a 405 already uses** — the byte-exact value and ordering ratified by
WP4 D4 and pinned by the gate. There is no second Allow machine.

An OPTIONS request to a path matching **no** route gets the ordinary miss answer
(`404`), not an empty `Allow`. A path that does not exist does not acquire an
options list.

**No `Allow: OPTIONS, HEAD` addition.** The `Allow` value stays byte-identical
to what the gate pins today. Adding the automatically-handled methods to it
would change a ratified, pinned string for cosmetic RFC alignment, and would
have to be a separate decision with its own evidence.

**No 501.** An unrecognised method continues to answer `405` with the exact
`Allow`. 501 is a SHOULD, and 405-with-Allow is the more useful answer: it tells
the client what it *can* do, where 501 only says the server will not. `.UNKNOWN`
already exists in the enum, so this remains reversible at any time.

**The `Method` enum does not change.** It stays six members, byte-for-byte as
the freeze gate pins it. HEAD and OPTIONS are resolved before a `Method` value
reaches a handler, so no public symbol grows, no freeze amendment is needed, and
none of FINDING-D's concept budget is spent.

## The consequence, stated rather than discovered later

**An application cannot override HEAD or OPTIONS through the routing table.**
For HEAD that is correct and intended. For OPTIONS it is a real constraint, and
the case that will eventually meet it is **CORS preflight**, which needs
application-specific OPTIONS responses.

CORS is explicitly outside the core (**G-07** names it among the features that
do not enter the package), so the intended answer is that a CORS middleware
handles preflight. **WP32b must verify this actually works** rather than assume
it: a middleware that commits a response before the automatic OPTIONS answer
should short-circuit it through the existing single-commit guard, exactly as a
middleware can already answer before a 404.

That is stated as a **requirement to verify, not a fact**. If the miss chain
does not give middleware that opportunity, automatic OPTIONS would close a door
the ecosystem needs, and the decision would have to be revisited — which is
cheaper to discover in WP32b than after something depends on it.

## Implementation constraints for WP32b

1. **Both live on the shared dispatch path.** `test_request` and a socket must
   answer identically.
2. **HEAD's body suppression happens at commit**, so every responder is covered
   by one rule rather than each learning about HEAD.
3. **OPTIONS reuses the existing `Allow` construction.** If WP32b finds itself
   writing a second one, the design is wrong.
4. **The vendored backend's HEAD handling** is currently held under core control
   by a patch the wire corpus pins (`check_public_api.sh`). WP32b must confirm
   the automatic HEAD does not fight it.
5. **Negative controls required**, one per behaviour: a HEAD that leaks a body,
   and an OPTIONS whose `Allow` differs from the 405's, must each turn a test
   red.
